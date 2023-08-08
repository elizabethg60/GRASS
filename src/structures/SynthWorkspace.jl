struct SynthWorkspace{T<:AF}
    lwavgrid::AA{T,1}
    rwavgrid::AA{T,1}
    allwavs::AA{T,1}
    allints::AA{T,1}
    bist::AA{T,1}
    intt::AA{T,1}
    widt::AA{T,1}
    xyz::Matrix{Vector{T}}
    μs::AA{T,2}
    ld::AA{T,2}
    dA::AA{T,2}
    z_rot::AA{T,2}
    keys::AA{Tuple{Symbol, Symbol},2}
end

function SynthWorkspace(disk::DiskParams; ndepths::Integer=100)
    # allocate the needed memory for synthesis
    lwavgrid = zeros(ndepths)
    rwavgrid = zeros(ndepths)
    allwavs  = zeros(2 * ndepths)
    allints  = zeros(2 * ndepths)
    bist     = zeros(ndepths)
    intt     = zeros(ndepths)
    widt     = zeros(ndepths)

    # allocate the memory for keys, velocities, ld, etc.
    μs = zeros(size(disk.θc))
    ld = zeros(size(disk.θc))
    dA = zeros(size(disk.θc))
    z_rot = zeros(size(disk.θc))
    keys = repeat([(:off,:off)], size(disk.θc)...)
    xyz = repeat([zeros(3)], disk.Nsubgrid, disk.Nsubgrid)

    return SynthWorkspace(lwavgrid, rwavgrid, allwavs,
                          allints, bist, intt, widt, xyz,
                          μs, ld, dA, z_rot, keys)
end
