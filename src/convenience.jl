"""
    synthesize_spectra(spec, disk; seed_rng=false, verbose=true, top=NaN)

Synthesize spectra given parameters in `spec` and `disk` instances.

# Arguments
- `spec::SpecParams`: SpecParams instance
- `disk::DiskParams`: DiskParams instance
"""
function synthesize_spectra(spec::SpecParams{T}, disk::DiskParams{T};
                            seed_rng::Bool=false, verbose::Bool=true,
                            use_gpu::Bool=false, precision::DataType=Float64,
                            skip_times::BitVector=falses(disk.Nt)) where T<:AF
    # call appropriate simulation function on cpu or gpu
    if use_gpu
        return synth_gpu(spec, disk, seed_rng, verbose, precision, skip_times)
    else
        return synth_cpu(spec, disk, seed_rng, verbose, skip_times)
    end
end

function synth_cpu(spec::SpecParams{T}, disk::DiskParams{T}, seed_rng::Bool,
                   verbose::Bool, skip_times::BitVector) where T<:AF
    # parse out dimensions for memory allocation
    N = disk.N
    Nt = disk.Nt
    Nλ = length(spec.lambdas)

    # allocate memory for time indices
    tloop = zeros(Int, size(disk.θc))
    tloop_init = zeros(Int, size(tloop))

    # allocate memory for synthsis
    prof = ones(Nλ)
    outspec = ones(Nλ, Nt)
    outspec_temp = zeros(Nλ, Nt)

    # pre-allocate memory and pre-compute geometric quantities
    wsp = GRASS.SynthWorkspace(disk, verbose=verbose)

    # get number of calls to disk_sim needed
    templates = unique(spec.templates)

    # run the simulation (outspec modified in place)
    for (idx, file) in enumerate(templates)
        # get temporary specparams with lines for this run
        spec_temp = SpecParams(spec, file)

        # load in the appropriate input data
        if verbose
            println("\t>>> Template: " * splitdir(file)[end])
        end
        soldata = SolarData(fname=file)

        # get conv. blueshift and keys from input data
        get_keys_and_cbs!(wsp, soldata)

        # re-seed the rng
        if seed_rng
            Random.seed!(42)
        end

        # generate or copy tloop
        if (idx > 1) && in_same_group(templates[idx - 1], templates[idx])
            tloop .= tloop_init
        else
            generate_tloop!(tloop_init, wsp, soldata)
            tloop .= tloop_init
        end

        # re-set array to 0s
        outspec_temp .= 0.0

        # run the simulation and multiply outspec by this spectrum
        disk_sim(spec_temp, disk, soldata, wsp, prof, outspec_temp,
                 tloop, skip_times=skip_times, verbose=verbose)
        outspec .*= outspec_temp
    end
    return spec.lambdas, outspec
end

function synth_gpu(spec::SpecParams{T}, disk::DiskParams{T}, seed_rng::Bool,
                   verbose::Bool, precision::DataType, skip_times::BitVector) where T<:AF
    # make sure there is actually a GPU to use
    @assert CUDA.functional()

    # warn user if precision is single
    if precision <: Float32
       @warn "Single-precision GPU implementation produces large flux and velocity errors!"
    end

    # parse out dimensions for memory allocation
    N = disk.N
    Nt = disk.Nt
    Nλ = length(spec.lambdas)

    # allocate memory
    outspec = ones(Nλ, Nt)

    # get number of calls to disk_sim needed
    templates = unique(spec.templates)

    # pre-allocate memory for gpu and pre-compute geometric quantities
    gpu_allocs = GPUAllocs(spec, disk, precision=precision, verbose=verbose)

    # allocate additional memory if generating random numbers on the cpu
    if seed_rng
        tloop_init = zeros(Int, size(disk.θc))
        keys_cpu = repeat([(:off,:off)], size(disk.θc)...)
        @cusync μs_cpu = Array(gpu_allocs.μs)
        @cusync cbs_cpu = Array(gpu_allocs.z_cbs)
        @cusync ax_codes_cpu = convert.(Int64, Array(gpu_allocs.ax_codes))
    else
        tloop_init = gpu_allocs.tloop_init
    end

    # run the simulation and return
    for (idx, file) in enumerate(templates)
        # get temporary specparams with lines for this run
        spec_temp = SpecParams(spec, file)

        # load in the appropriate input data
        if verbose
            println("\t>>> Template: " * splitdir(file)[end])
        end
        soldata_cpu = SolarData(fname=file)
        soldata = GPUSolarData(soldata_cpu, precision=precision)

        # get conv. blueshift and keys from input data
        get_keys_and_cbs_gpu!(gpu_allocs, soldata)

        # generate or copy tloop
        if (idx > 1) && in_same_group(templates[idx - 1], templates[idx])
            @cusync CUDA.copyto!(gpu_allocs.tloop, tloop_init)
        else
            # generate either seeded rngs, or don't seed them on gpu
            if seed_rng
                # seed and generate the random number on the cpu
                Random.seed!(42)
                get_keys_and_cbs!(keys_cpu, μs_cpu, cbs_cpu, ax_codes_cpu, soldata_cpu)
                generate_tloop!(tloop_init, μs_cpu, keys_cpu, soldata_cpu.len)
            else
                # generate the random numbers on the gpu
                generate_tloop_gpu!(tloop_init, gpu_allocs, soldata)
            end

            # copy the random indices to GPU
            @cusync CUDA.copyto!(gpu_allocs.tloop, tloop_init)
        end

        # run the simulation and multiply outspec by this spectrum
        disk_sim_gpu(spec_temp, disk, soldata, gpu_allocs, outspec,
                     verbose=verbose, skip_times=skip_times)
    end
    return spec.lambdas, outspec
end
