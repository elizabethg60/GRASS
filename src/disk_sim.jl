# line loop function, update prof in place
function line_loop_cpu(prof::AA{T,1}, λΔD::T, depth::T, lambdas::AA{T,1},
                       wsp::SynthWorkspace{T}) where T<:AF
    # first trim the bisectors to the correct depth
    trim_bisector!(depth, wsp.bist, wsp.intt)

    # update the line profile in place
    line_profile_cpu!(λΔD, lambdas, prof, wsp)
    return nothing
end

function time_loop_cpu(tloop::Int, prof::AA{T,1}, z_rot::T, z_cbs::T,
                       z_cbs_avg::T, key::Tuple{Symbol, Symbol},
                       liter::UnitRange{Int}, spec::SpecParams{T},
                       soldata::SolarData, wsp::SynthWorkspace{T}) where T<:AF
    # reset prof
    prof .= one(T)

    # loop over lines
    for l in liter
        # get views needed for line synthesis
        wsp.bist .= copy(view(soldata.bis[key], :, tloop))
        wsp.intt .= copy(view(soldata.int[key], :, tloop))
        wsp.widt .= copy(view(soldata.wid[key], :, tloop))

        # calculate the position of the line center
        extra_z = spec.conv_blueshifts[l] - z_cbs_avg
        λΔD = spec.lines[l] * (1.0 + z_rot) * (1.0 + z_cbs .* spec.variability[l]) * (1.0 + extra_z)

        # get rid of bisector and fix width if variability is turned off
        wsp.bist .*= spec.variability[l]
        if !spec.variability[l]
            wsp.widt .= view(soldata.wid[key], :, 1)
        end

        # get depth to trim to from depth contrast
        dtrim = spec.depths[l] * soldata.dep_contrast[key]

        # synthesize the line
        line_loop_cpu(prof, λΔD, dtrim, spec.lambdas, wsp)
    end
    return nothing
end

function precompute_quantities(wsp::SynthWorkspace{T}, disk::DiskParams{T}, soldata::SolarData{T},
                               disc_mu::AA{T,1}, disc_ax::AA{Int,1}) where T<:AF
    # calculate normalization terms and get convective blueshifts
    numer = 0
    denom = 0
    for i in eachindex(disk.ϕc)
        for j in eachindex(disk.θc)
            # calculate mu
            μc = calc_mu(disk.ϕc[i], disk.θc[j], R_θ=disk.R_θ, O⃗=disk.O⃗)

            # move to next iteration if patch element is not visible
            μc < zero(T) && continue

            # get input data for place on disk
            key = get_key_for_pos(μc, disk.ϕc[i], disk.θc[j], disc_mu, disc_ax, R_θ=disk.R_θ)

            # calc limb darkening normalization term
            ld = quad_limb_darkening(μc, disk.u1, disk.u2)
            dA = calc_projected_area_element(disk.ϕc[i], disk.θc[j], disk)
            numer += soldata.cbs[key] * (ld * dA)
            denom += ld * dA

            # get rotational velocity for location on disk
            z_rot = patch_velocity_los(disk.ϕc[i], disk.θc[j], disk)

            # copy to workspace
            wsp.dA[i,j] = dA
            wsp.μs[i,j] = μc
            wsp.ld[i,j] = ld
            wsp.z_rot[i,j] = z_rot
            wsp.keys[i,j] = key
        end
    end
    return numer/denom, denom
end

function disk_sim_3d(spec::SpecParams{T}, disk::DiskParams{T}, soldata::SolarData{T},
                     wsp::SynthWorkspace, prof::AA{T,1}, outspec::AA{T,2},
                     tloop::AA{Int,2}; verbose::Bool=true,
                     skip_times::BitVector=falses(disk.Nt)) where T<:AF
    # set pre-allocations and make generator that will be re-used
    outspec .= zero(T)
    liter = 1:length(spec.lines); @assert length(liter) >= 1

    # get sorted mu and axis values
    disc_mu, disc_ax = sort_mu_and_ax(soldata)

    # get intensity-weighted disk-avereged convective blueshift
    z_cbs_avg, sum_norm_terms = precompute_quantities(wsp, disk, soldata, disc_mu, disc_ax)

    # loop over grid positions
    for i in eachindex(disk.ϕc)
        for j in eachindex(disk.θc)
            # calculate mu
            μc = calc_mu(disk.ϕc[i], disk.θc[j], R_θ=disk.R_θ, O⃗=disk.O⃗)

            # move to next iteration if patch element is not visible
            μc < zero(T) && continue

            # get input data for place on disk
            key = wsp.keys[i,j]
            len = soldata.len[key]

            # get total doppler shift for the line, and norm_term
            z_cbs = soldata.cbs[key]

            # get ld and projected area element
            ld = wsp.ld[i,j]
            dA = wsp.dA[i,j]
            z_rot = wsp.z_rot[i,j]

            # loop over time
            for t in 1:disk.Nt
                # check that tloop hasn't exceeded number of epochs
                if tloop[i,j] > len
                    tloop[i,j] = 1
                end

                # if skip times is true, continue to next iter
                if skip_times[t]
                    tloop[i,j] += 1
                    continue
                end

                # update profile in place
                time_loop_cpu(tloop[i,j], prof, z_rot, z_cbs, z_cbs_avg, key, liter, spec, soldata, wsp)

                # apply normalization term and add to outspec
                outspec[:,t] .+= (prof .* ld * dA)

                # iterate tloop
                tloop[i,j] += 1
            end
        end
    end

    # divide by sum of weights
    outspec ./= sum_norm_terms

    # set instances of outspec where skip is true to 0 and return
    outspec[:, skip_times] .= zero(T)
    return nothing
end
