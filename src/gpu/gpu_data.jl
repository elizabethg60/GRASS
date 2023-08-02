function sort_data_for_gpu(soldata::SolarData{T}) where T<:AbstractFloat
    # collect attributes that are 1D arrays
    len = collect(values(soldata.len))
    cbs = collect(values(soldata.cbs))
    dep_contrast = collect(values(soldata.dep_contrast))

    # allocate memory for bisector + width data
    npositions = length(len)
    bis = zeros(100, maximum(len), npositions)
    int = zeros(100, maximum(len), npositions)
    wid = zeros(100, maximum(len), npositions)
    for (ind,(key,val)) in enumerate(soldata.len)
        bis[:, 1:val, ind] .= soldata.bis[key]
        int[:, 1:val, ind] .= soldata.int[key]
        wid[:, 1:val, ind] .= soldata.wid[key]
    end

    # get the value of mu and ax codes
    disc_ax = parse_ax_string.(getindex.(keys(soldata.len),1))
    disc_mu = parse_mu_string.(getindex.(keys(soldata.len),2))

    # get indices to sort by mus
    inds_mu = sortperm(disc_mu)
    disc_mu .= disc_mu[inds_mu]
    disc_ax .= disc_ax[inds_mu]

    # get the arrays in mu sorted order
    len .= len[inds_mu]
    cbs .= cbs[inds_mu]
    dep_contrast .= dep_contrast[inds_mu]
    bis .= view(bis, :, :, inds_mu)
    int .= view(int, :, :, inds_mu)
    wid .= view(wid, :, :, inds_mu)

    # get indices to sort by axis within mu sort
    for mu_val in unique(disc_mu)
        inds1 = (disc_mu .== mu_val)
        inds2 = sortperm(disc_ax[inds1])
        disc_mu[inds1] .= disc_mu[inds1][inds2]
        disc_ax[inds1] .= disc_ax[inds1][inds2]

        len[inds1] .= len[inds1][inds2]
        cbs[inds1] .= cbs[inds1][inds2]
        dep_contrast[inds1] .= dep_contrast[inds1][inds2]
        bis[:, :, inds1] .= bis[:, :, inds1][:, :, inds2]
        int[:, :, inds1] .= int[:, :, inds1][:, :, inds2]
        wid[:, :, inds1] .= wid[:, :, inds1][:, :, inds2]
    end
    return disc_mu, disc_ax, len, cbs, dep_contrast, bis, int, wid
end

function find_nearest_ax_gpu(x::T, y::T) where T<:AbstractFloat
    if (CUDA.iszero(x) & CUDA.iszero(y))
        return 0 # center
    elseif y >= CUDA.abs(x)
        return 1 # north
    elseif y <= -CUDA.abs(x)
        return 2 # south
    elseif x <= -CUDA.abs(y)
        return 3 # east
    elseif x >= CUDA.abs(y)
        return 4 # west
    else
        return 0
    end
end

function find_data_index_gpu(μ, x, y, disc_mu, disc_ax)
    # find the nearest mu ind and ax code
    mu_ind = searchsortednearest_gpu(disc_mu, μ)
    ax_val = find_nearest_ax_gpu(x, y)

    # find the first index of disc_mu with that discrete mu val
    i = 1
    while disc_mu[i] != disc_mu[mu_ind]
        i += 1
    end
    mu_ind = i

    # calculate the data index
    if mu_ind == CUDA.length(disc_mu)
        # return immediately if nearest mu is disk center
        return CUDA.length(disc_mu)
    else
        # otherwise we need the right axis value
        mu_ind_orig = mu_ind
        mu_val_orig = disc_mu[mu_ind_orig]
        while ((disc_ax[mu_ind] != ax_val) & (disc_mu[mu_ind] == mu_val_orig))
            mu_ind += 1
        end

        # check that we haven't overflowed into the next batch of mus
        if disc_mu[mu_ind] == mu_val_orig
            return mu_ind
        else
            return mu_ind_orig
        end
    end
    return nothing
end

function iterate_tloop_gpu!(tloop, data_inds, lenall, grid)
    # get indices from GPU blocks + threads
    idx = threadIdx().x + blockDim().x * (blockIdx().x-1)
    sdx = blockDim().x * gridDim().x
    idy = threadIdx().y + blockDim().y * (blockIdx().y-1)
    sdy = blockDim().y * gridDim().y

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

            # check that tloop didn't overshoot the data and iterate
            ntimes = lenall[data_inds[i,j]]
            if tloop[i,j] < ntimes
                @inbounds tloop[i,j] += 1
            else
                @inbounds tloop[i,j] = 1
            end
        end
    end
    return nothing
end

function calc_mu_gpu(xyz, O⃗)
    dp = xyz[1] * O⃗[1] + xyz[2] * O⃗[2] + xyz[3] * O⃗[3]
    n1 = CUDA.sqrt(O⃗[1]^2.0 + O⃗[2]^2.0 + O⃗[3]^2.0)
    n2 = CUDA.sqrt(xyz[1]^2.0 + xyz[2]^2.0 + xyz[3]^2.0)
    return dp / (n1 * n2)
end

function sphere_to_cart_gpu!(xyz, ρs, ϕc, θc)
    # compute trig quantities
    sinϕ = CUDA.sin(ϕc)
    sinθ = CUDA.sin(θc)
    cosϕ = CUDA.cos(ϕc)
    cosθ = CUDA.cos(θc)

    # now get cartesian coords
    x = ρs * cosϕ * cosθ
    y = ρs * cosϕ * sinθ
    z = ρs * sinϕ

    # dot product for rotation matrix
    @inbounds xyz[1] = x #* R_θ[1,1] + x * R_θ[1,2] + x * R_θ[1,3]
    @inbounds xyz[2] = y #* R_θ[2,1] + y * R_θ[2,2] + y * R_θ[2,3]
    @inbounds xyz[3] = z #* R_θ[3,1] + z * R_θ[3,2] + z * R_θ[3,3]
    return nothing
end

function rotate_vector_gpu!(xyz, R_θ)
    x = xyz[1]
    y = xyz[2]
    z = xyz[3]
    @inbounds xyz[1] = x * R_θ[1,1] + x * R_θ[1,2] + x * R_θ[1,3]
    @inbounds xyz[2] = y * R_θ[2,1] + y * R_θ[2,2] + y * R_θ[2,3]
    @inbounds xyz[3] = z * R_θ[3,1] + z * R_θ[3,2] + z * R_θ[3,3]
    return nothing
end

function rotation_period_gpu(ϕ, A, B, C)
    sinϕ = sin(ϕ)
    return 360.0/(A + B * sinϕ^2.0 + C * sinϕ^4.0)
end


function initialize_arrays_for_gpu(vec1, vec2, vec3, ρs, ϕc, θc, R_θ, O⃗, μs,
                                   tloop, data_inds,
                                   norm_terms, z_rot, z_cbs, disc_mu,
                                   disc_ax, lenall, cbsall, A, B, C, u1, u2)
    # get indices from GPU blocks + threads
    idx = threadIdx().x + blockDim().x * (blockIdx().x-1)
    sdx = blockDim().x * gridDim().x
    idy = threadIdx().y + blockDim().y * (blockIdx().y-1)
    sdy = blockDim().y * gridDim().y

    # get grid steps
    dϕ = ϕc[2] - ϕc[1]
    dθ = θc[2] - θc[1]

    # parallelized loop over grid
    for i in idx:sdx:CUDA.length(ϕc)
        for j in idy:sdy:CUDA.length(θc)
            # take view of pre-allocated memory
            xyz = CUDA.view(vec1, i, j, :)
            abc = CUDA.view(vec2, i, j, :)
            def = CUDA.view(vec3, i, j, :)

            # get cartesian coords in star frame
            sphere_to_cart_gpu!(xyz, ρs, ϕc[i], θc[j])

            # get vector from spherical circle center to surface patch
            abc[1] = xyz[1]
            abc[2] = xyz[2]
            abc[3] = 0.0

            # take cross product to get vector in direction of rotation
            def[1] = abc[2] * ρs
            def[2] = - abc[1] * ρs
            def[3] = 0.0

            # make it a unit vector
            def_norm = CUDA.sqrt(def[1]^2.0 + def[2]^2.0 + def[3]^2.0)
            def[1] /= def_norm
            def[2] /= def_norm

            # set magnitude by differentiak rotation
            rp = (0.000168710673 / rotation_period_gpu(ϕc[i], A, B, C))
            def[1] *= rp
            def[2] *= rp

            # rotate it by inclination
            rotate_vector_gpu!(xyz, R_θ)
            rotate_vector_gpu!(def, R_θ)

            # get vector pointing from observer to surface patch
            abc[1] = xyz[1] - O⃗[1]
            abc[2] = xyz[2] - O⃗[2]
            abc[3] = xyz[3] - O⃗[3]

            # get angle between them
            n1 = CUDA.sqrt(abc[1]^2.0 + abc[2]^2.0 + abc[3]^2.0)
            n2 = CUDA.sqrt(def[1]^2.0 + def[2]^2.0 + def[3]^2.0)
            angle = (abc[1] * def[1] + abc[2] * def[2] + abc[3] * def[3])
            angle /= (n1 * n2)

            # project it
            z_rot[i,j] = n2 * angle

            # get cartesian coords in star frame and rotate
            sphere_to_cart_gpu!(xyz, ρs, ϕc[i], θc[j])
            rotate_vector_gpu!(xyz, R_θ)

            # calculate mu
            @inbounds μs[i,j] = calc_mu_gpu(xyz, O⃗)
            if μs[i,j] <= 0.0
                continue
            end

            # find the correct data index and
            idx = find_data_index_gpu(μs[i,j], xyz[1], xyz[2], disc_mu, disc_ax)
            @inbounds data_inds[i,j] = idx

            # initialize tloop value if not already set by CPU
            if CUDA.iszero(tloop[i,j])
                @inbounds tloop[i,j] = CUDA.floor(Int32, rand() * lenall[idx]) + 1
            elseif tloop[i,j] > lenall[idx]
                @inbounds tloop[i,j] = 1
            end

            # calculate the limb darkening
            ld = quad_limb_darkening(μs[i,j], u1, u2)

            # calculate the surface element and project along line of sight
            dA = calc_dA(ρs, ϕc[i], dϕ, dθ)
            @inbounds abc[1] = xyz[1] - O⃗[1]
            @inbounds abc[2] = xyz[2] - O⃗[2]
            @inbounds abc[3] = xyz[3] - O⃗[3]
            dp = CUDA.abs(abc[1] * xyz[1] + abc[2] * xyz[2] + abc[3] * xyz[3])

            # set norm term as product of limb darkening and projected dA
            @inbounds norm_terms[i,j] = ld * dA * dp

            # # calculate the rotational velocity along LOS
            # # get vector pointing from star origin to spherical circle height
            # @inbounds xyz[3] = [0]

            # # set abc as pole vector in star frame


            # # velocity magnitude at equator, in Rsol/day/c_ms
            # v0 = 0.000168710673

            # # get velocity vector direction and set magnitude
            # vel = cross(C⃗, P⃗)
            # vel /= norm(vel)
            # vel *= (v0 / rotation_period(ϕ; A=disk.A, B=disk.B, C=disk.C))

            # # rotate by stellar inclination
            # xyz .= disk.R_θ * xyz
            # vel .= disk.R_θ * vel

            # # find get vector from observer to surface patch, return projection
            # O⃗_surf = xyz .- disk.O⃗
            # angle = dot(O⃗_surf, vel) / (norm(O⃗_surf) * norm(vel))
            # return norm(vel) * angle

            # # calculate the rotational and convective doppler shift
            # @inbounds z_rot[i,j] = patch_velocity_los_gpu(x, y, rstar, polex, poley, polez)
            # @inbounds z_cbs[i,j] = cbsall[idx]
        end
    end
    return nothing
end
