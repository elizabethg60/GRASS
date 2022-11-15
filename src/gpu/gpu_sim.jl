function disk_sim_gpu(spec::SpecParams{T}, disk::DiskParams{T}, soldata::SolarData{T},
                      gpu_allocs::GPUAllocs, outspec::AA{T,2}; verbose::Bool=false,
                      seed_rng::Bool=false, precision::DataType=Float64,
                      skip_times::BitVector=BitVector(zeros(disk.Nt))) where T<:AF
    # set single or double precision
    prec = precision

    # get dimensions for memory alloc
    N = disk.N # convert(Int32, disk.N)
    Nt = disk.Nt # convert(Int32, disk.Nt)
    Nλ = length(spec.lambdas) # convert(Int32, length(spec.lambdas))

    # get pole component vectors and limb darkening parameters
    polex = convert(prec, disk.pole[1])
    poley = convert(prec, disk.pole[2])
    polez = convert(prec, disk.pole[3])
    u1 = convert(prec, disk.u1)
    u2 = convert(prec, disk.u2)

    # sort the input data for use on GPU
    sorted_data = sort_data_for_gpu(soldata)
    disc_mu_cpu = sorted_data[1]
    disc_ax_cpu = sorted_data[2]
    lenall_cpu = sorted_data[3]
    cbsall_cpu = sorted_data[4]
    bisall_cpu = sorted_data[5]
    intall_cpu = sorted_data[6]
    widall_cpu = sorted_data[7]

    # move input data to gpu
    @cusync begin
        disc_mu_gpu = CuArray{prec}(disc_mu_cpu)
        disc_ax_gpu = CuArray{Int32}(disc_ax_cpu)
        lenall_gpu = CuArray{Int32}(lenall_cpu)
        cbsall_gpu = CuArray{prec}(cbsall_cpu)
        bisall_gpu = CuArray{prec}(bisall_cpu)
        intall_gpu = CuArray{prec}(intall_cpu)
        widall_gpu = CuArray{prec}(widall_cpu)
    end

    # allocate arrays for fresh copy of input data to copy to each loop
    @cusync begin
        bisall_gpu_loop = CUDA.copy(bisall_gpu)
        intall_gpu_loop = CUDA.copy(intall_gpu)
    end

    # parse out composite type
    grid = gpu_allocs.grid
    lambdas = gpu_allocs.lambdas
    tloop = gpu_allocs.tloop
    data_inds = gpu_allocs.data_inds
    norm_terms = gpu_allocs.norm_terms
    z_rot = gpu_allocs.z_rot
    z_cbs = gpu_allocs.z_cbs
    starmap = gpu_allocs.starmap
    allwavs = gpu_allocs.allwavs
    allints = gpu_allocs.allints

    # reset init values for synthesis allocs
    @cusync begin
        allwavs .= 0.0
        allints .= 0.0
    end

    # set number of threads and blocks for trimming functions
    threads1 = (22,22)
    blocks1 = cld.(lenall_cpu .* 100, prod(threads1))

    # set number of threads and blocks for N*N matrix gpu functions
    threads2 = (16,16)
    blocks2 = cld(N^2, prod(threads2))

    # set number of threads and blocks for N*N*Nλ matrix gpu functions
    threads3 = (4,4,18)
    blocks3 = cld(N^2 * Nλ, prod(threads3))

    # set number of threads and blocks for N*N*100 matrix gpu functions
    threads4 = (4,4,16)
    blocks4 = cld(N^2 * 100, prod(threads4))

    # initialize values for data_inds, tloop, dop_shifts, and norm_terms
    @cusync @cuda threads=threads2 blocks=blocks2 initialize_arrays_for_gpu(tloop, data_inds, norm_terms,
                                                                            z_rot, z_cbs, grid, disc_mu_gpu,
                                                                            disc_ax_gpu, lenall_gpu, cbsall_gpu,
                                                                            u1, u2, polex, poley, polez)

    # get weighted disk average cbs
    @cusync z_cbs_avg = CUDA.sum(z_cbs .* norm_terms) / CUDA.sum(norm_terms)

    # loop over time
    for t in 1:Nt
        # don't do all this work if skip_times is true, but iterate t indices
        if skip_times[t]
            @cusync @captured @cuda threads=threads2 blocks=blocks2 iterate_tloop_gpu!(tloop, data_inds, lenall_gpu, grid)
            continue
        end

        # initialize starmap with fresh copy of weights
        @cusync starmap .= norm_terms

        # loop over lines to synthesize
        for l in eachindex(spec.lines)
            # pre-trim the data, loop over all disk positions
            for n in eachindex(lenall_cpu)
                epoch_range = 1:lenall_cpu[n]
                @cusync begin
                    # view of unaltered input data
                    bisall_gpu_in = CUDA.view(bisall_gpu, :, epoch_range, n) .* spec.variability[l]
                    intall_gpu_in = CUDA.view(intall_gpu, :, epoch_range, n)

                    # view of arrays to put modified bisectors in
                    bisall_gpu_out = CUDA.view(bisall_gpu_loop, :, epoch_range, n)
                    intall_gpu_out = CUDA.view(intall_gpu_loop, :, epoch_range, n)
                end

                # do the trim
                @cusync @captured @cuda threads=threads1 blocks=blocks1[n] trim_bisector_gpu!(spec.depths[l],
                                                                                              bisall_gpu_out,
                                                                                              intall_gpu_out,
                                                                                              bisall_gpu_in,
                                                                                              intall_gpu_in)
            end

            # calculet how much extra shift is needed
            extra_z = spec.conv_blueshifts[l] - z_cbs_avg

            # assemble line shape on even int grid
            @cusync @captured @cuda threads=threads4 blocks=blocks4 fill_workspaces!(spec.lines[l], extra_z, grid,
                                                                                     tloop, data_inds, z_rot, z_cbs,
                                                                                     bisall_gpu_loop, intall_gpu_loop,
                                                                                     widall_gpu, allwavs, allints)

            # do the line synthesis, interp back onto wavelength grid
            @cusync @captured @cuda threads=threads3 blocks=blocks3 line_profile_gpu!(starmap, grid, lambdas, allwavs, allints)
        end

        # do array reduction and move data from GPU to CPU
        @cusync @inbounds outspec[:,t] .*= dropdims(Array(CUDA.sum(starmap, dims=(1,2))), dims=(1,2))

        # iterate tloop
        @cusync @captured @cuda threads=threads2 blocks=blocks2 iterate_tloop_gpu!(tloop, data_inds, lenall_gpu, grid)
    end

    # ensure normalization
    @cusync outspec ./= CUDA.sum(norm_terms)
    return nothing
end
