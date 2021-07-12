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
function line_loop(i::T, j::T, prof::AA{T,1}, line::T,
                   depth::T, blueshift::T, lambdas::AA{T,1},
                   wsp::SynthWorkspace{T}; top::T=NaN,
                   pole::Tuple{T,T,T}=(zero(T),one(T),zero(T))) where T<:AF
    # first trim the bisectors to the correct depth
    trim_bisector_chop!(depth, wsp.wavt, wsp.bist, wsp.dept, wsp.widt, top=top)

    # update the line profile
    line_profile!(i, j, line, blueshift, lambdas, prof, wsp, pole=pole)
    return nothing
end

# TODO: @code_warntype
function time_loop(i::T, j::T, t_loop::Int, prof::AA{T,1},
                   key::Tuple{Symbol, Symbol}, liter::UnitRange{Int},
                   spec::SpecParams{T}, wsp::SynthWorkspace{T}; top::T=NaN,
                   pole::Tuple{T,T,T}=(zero(T),one(T),zero(T))) where T<:AF
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
        line_loop(i, j, prof, spec.lines[l], spec.depths[l],
                  spec.blueshifts[l], spec.lambdas, wsp,
                  pole=pole, top=top)
    end
    return nothing
end

function disk_sim(spec::SpecParams{T}, disk::DiskParams{T,Int64}, prof::AA{T,1},
                  outspec::AA{T,2}; top::T=NaN, seed_rng::Bool=false,
                  verbose::Bool=true) where T<:AF
    # make grid
    grid = make_grid(N=disk.N)
    Nt = disk.Nt

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

            # loop over time, starting at random epoch
            t = 0

            # TODO: this is weird, breaks overall seeding
            # Random.seed!(abs(rand(Int)))
            t_loop = rand(0:len-1)
            cont = true
            while cont
                # iterate counting var, change cont -> false if on penultimate
                t += 1
                cont *= (t <= (Nt - 1))

                # update profile in place
                prof .= one(T)
                time_loop(i, j, t_loop + 1, prof, key,
                          liter, spec, wsp, top=top,
                          pole=disk.pole)

                # apply normalization term and add to outspec
                # TODO: sqrt for variance spectrum
                outspec[:,t] .+= (prof .* norm_term(i, j, disk))

                # iterate t_loop
                t_loop = mod(t_loop + 1, len-1)
            end
        end
    end
    return nothing
end
