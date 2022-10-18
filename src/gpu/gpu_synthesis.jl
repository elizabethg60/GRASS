function fill_workspaces!(line, extra_z, grid, tloop, data_inds, z_rot,
                          z_cbs, bisall, intall, widall, allwavs, allints)
    # get indices from GPU blocks + threads
    idx = threadIdx().x + blockDim().x * (blockIdx().x-1)
    sdx = blockDim().x * gridDim().x
    idy = threadIdx().y + blockDim().y * (blockIdx().y-1)
    sdy = blockDim().y * gridDim().y
    idz = threadIdx().z + blockDim().z * (blockIdx().z-1)
    sdz = blockDim().z * gridDim().z

    # parallelized loop over grid
    for i in idx:sdx:CUDA.length(grid)
        for j in idy:sdy:CUDA.length(grid)
            # find position on disk and move to next iter if off disk
            x = grid[i]
            y = grid[j]
            r2 = calc_r2(x, y)
            if r2 > 1.0
                continue
            end

            # calculate shifted line center
            λΔD = line * (1.0 + z_rot[i,j]) * (1.0 + z_cbs[i,j]) * (1.0 + extra_z)

            # slice out the correct views of the input data for position
            bist = CUDA.view(bisall, :, tloop[i,j], data_inds[i,j])
            widt = CUDA.view(widall, :, tloop[i,j], data_inds[i,j])
            intt = CUDA.view(intall, :, tloop[i,j], data_inds[i,j])

            # get length of input data arrays
            lent = CUDA.length(intt)

            # slice out the correct views of the input data for position
            for k in idz:sdz:lent
                # right side of line, indexing from middle left to right
                @inbounds allwavs[i,j,k+lent] = (λΔD + (0.5 * widt[k] + bist[k]))
                @inbounds allints[i,j,k+lent] = intt[k]

                # left sight of line, indexing from middle right to left
                @inbounds allwavs[i,j,k] = (λΔD - (0.5 * widt[lent - (k - 1)] - bist[lent - (k - 1)]))
                @inbounds allints[i,j,k] = intt[lent - (k - 1)]
            end
        end
    end
    return nothing
end


function line_profile_gpu!(star_map, grid, lambdas, allwavs, allints)
    # get indices from GPU blocks + threads
    idx = threadIdx().x + blockDim().x * (blockIdx().x-1)
    sdx = blockDim().x * gridDim().x
    idy = threadIdx().y + blockDim().y * (blockIdx().y-1)
    sdy = blockDim().y * gridDim().y
    idz = threadIdx().z + blockDim().z * (blockIdx().z-1)
    sdz = blockDim().z * gridDim().z

    # parallelized loop over grid
    for i in idx:sdx:CUDA.length(grid)
        for j in idy:sdy:CUDA.length(grid)
            # set intensity to zero and go to next iter if off grid
            x = grid[i]
            y = grid[j]
            r2 = calc_r2(x, y)
            if r2 > 1.0
                continue
            end

            # take view of arrays to pass to interpolater
            allwavs_ij = CUDA.view(allwavs, i, j, :)
            allints_ij = CUDA.view(allints, i, j, :)

            # set up interpolator
            itp = linear_interp(allwavs_ij, allints_ij, bc=1.0)

            # loop over wavelengths
            for k in idz:sdz:CUDA.length(lambdas)
                @inbounds star_map[i,j,k] *= itp(lambdas[k])
            end
        end
    end
    return nothing
end
