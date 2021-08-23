"""
    synthesize_spectra(spec, disk; seed_rng=false, verbose=true, top=NaN)

Synthesize spectra given parameters in `spec` and `disk` instances.

# Arguments
- `spec::SpecParams`: SpecParams instance
- `disk::DiskParams`: DiskParams instance
"""
function synthesize_spectra(spec::SpecParams, disk::DiskParams;
                            seed_rng::Bool=false, verbose::Bool=true,
                            top::Float64=NaN)
    # allocate memory for synthesis
    Nλ = length(spec.lambdas)
    prof = ones(Nλ)
    outspec = zeros(Nλ, disk.Nt)

    # run the simulation (outspec modified in place)
    disk_sim(spec, disk, prof, outspec, seed_rng=seed_rng, verbose=verbose, top=top)
    return spec.lambdas, outspec./maximum(outspec, dims=1)
end

# line loop function, update prof in place
function line_loop(prof::AA{T,1}, mid::T, depth::T,
                   rot_shift::T, conv_blueshift::T,
                   lambdas::AA{T,1}, wsp::SynthWorkspace{T}; top::T=NaN) where T<:AF
    # first trim the bisectors to the correct depth
    trim_bisector_chop!(depth, wsp.wavt, wsp.bist, wsp.dept, wsp.widt, top=top)

    # update the line profile
    line_profile!(mid, rot_shift, conv_blueshift, lambdas, prof, wsp)
    return nothing
end

# TODO: @code_warntype
function time_loop(t_loop::Int, prof::AA{T,1}, rot_shift::T,
                   key::Tuple{Symbol, Symbol}, liter::UnitRange{Int},
                   spec::SpecParams{T}, wsp::SynthWorkspace{T}; top::T=NaN) where T<:AF
    # some assertions
    @assert all(prof .== one(T))

    # get views needed for line synthesis
    wsp.wavt .= view(spec.soldata.wav[key], :, t_loop)
    wsp.bist .= view(spec.soldata.bis[key], :, t_loop)
    wsp.dept .= view(spec.soldata.dep[key], :, t_loop)
    wsp.widt .= view(spec.soldata.wid[key], :, t_loop)

    # loop over specified synthetic lines
    for l in liter
        wsp.wavt .*= spec.variability[l]
        line_loop(prof, spec.lines[l], spec.depths[l], rot_shift,
                  spec.conv_blueshifts[l], spec.lambdas, wsp, top=top)
    end
    return nothing
end

function generate_indices(Nt::Integer, len::Integer)
    # start at random index less than len and go to len
    start = Iterators.take(rand(1:len):len, Nt)

    # return if that's all that's needed
    if length(start) == Nt
        return Iterators.flatten(start)
    end

    # find out how many more cycles are needed
    niter = ceil(Int, (Nt - length(start))/len)

    # make vector of iterators and
    inds = Vector{Base.Iterators.Take{UnitRange{Int64}}}(undef, niter + 1)
    inds[1] = start
    for i in 2:(length(inds)-1)
        inds[i] = Iterators.take(1:len, len)
    end

    # ensure the last one only takes the the remainder
    ind_lens = length.(inds)
    ind_sums = sum(ind_lens[1:end-1])
    inds[end] = Iterators.take(1:len, Nt - ind_sums)

    # return flattened iterator
    @assert sum(length.(inds)) == Nt
    return Iterators.flatten(inds)
end

function disk_sim(spec::SpecParams{T}, disk::DiskParams{T,Int64}, prof::AA{T,1},
                  outspec::AA{T,2}; top::T=NaN, seed_rng::Bool=false,
                  verbose::Bool=true) where T<:AF
    # make grid
    grid = make_grid(N=disk.N)

    # set pre-allocations and make generator that will be re-used
    outspec .= zero(T)
    wsp = SynthWorkspace(ndepths=100)
    liter = 1:length(spec.lines)

    # seeding rng
    if seed_rng
        if verbose println("Seeding RNG") end
        Random.seed!(42)
    end

    # loop over grid positions
    for i in grid
        for j in grid
            # move to next iteration if off grid
            # TODO: area weighting for pixels that aren't fully in ??
            (i^2 + j^2) > one(T) && continue

            # get input data for place on disk
            key = get_key_for_pos(i, j)
            len = spec.soldata.len[key]

            # get redshift z and norm term for location on disk
            rot_shift = patch_velocity_los(i, j, pole=disk.pole)
            norm_term = calc_norm_term(i, j, disk)

            # loop over time, starting at random epoch
            inds = generate_indices(disk.Nt, len)
            for (t, t_loop) in enumerate(inds)
                # update profile in place
                prof .= one(T)
                time_loop(t_loop, prof, rot_shift, key, liter, spec, wsp, top=top)

                # apply normalization term and add to outspec
                # TODO: sqrt for variance spectrum
                outspec[:,t] .+= (prof .* norm_term)
            end
        end
    end
    return nothing
end
