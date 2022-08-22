abstract type AbstractSolarData end
struct SolarData{T1<:AF} <: AbstractSolarData
    bis::Dict{Tuple{Symbol,Symbol}, AbstractArray{T1,2}}
    int::Dict{Tuple{Symbol,Symbol}, AbstractArray{T1,2}}
    wid::Dict{Tuple{Symbol,Symbol}, AbstractArray{T1,2}}
    len::Dict{Tuple{Symbol,Symbol}, Int}
    ax::Array{Symbol,1}
    mu::Array{Symbol,1}
end

"""
    SolarData(; dir=soldir, relative=true, ...)

Construct a `SpecParams` composite type instance.

# Arguments
- `dir::String=soldir`: Directory containing the pre-processed input data. Default directory is set in src/config.jl
- `relative::Bool=true`: Set whether wavelengths are on absolute scale or expressed relative to rest wavelength.
"""
function SolarData(;fname::String="", relative::Bool=true, fixed_width::Bool=false,
                   fixed_bisector::Bool=false, extrapolate::Bool=true,
                   contiguous_only::Bool=false, adjust_mean::Bool=true)
    if isempty(fname)
        fname = GRASS.soldir * "FeI_5434.h5"
    end
    return SolarData(fname, relative=relative, fixed_width=fixed_width,
                     fixed_bisector=fixed_bisector, extrapolate=extrapolate,
                     contiguous_only=contiguous_only, adjust_mean=adjust_mean)
end

function SolarData(fname::String; relative::Bool=true, fixed_width::Bool=false,
                   fixed_bisector::Bool=false, extrapolate::Bool=false,
                   contiguous_only::Bool=false, adjust_mean::Bool=true)
    # make sure the file exists
    @assert isfile(fname)

    # initialize data structure for input data
    bisdict = Dict{Tuple{Symbol,Symbol}, AA{Float64,2}}()
    intdict = Dict{Tuple{Symbol,Symbol}, AA{Float64,2}}()
    widdict = Dict{Tuple{Symbol,Symbol}, AA{Float64,2}}()
    lengths = Dict{Tuple{Symbol,Symbol}, Int}()
    axs = []
    mus = []

    # open the file
    h5open(fname, "r") do f
        # get rest wavelength for line
        attr = HDF5.attributes(f)
        λrest = read(attr["air_wavelength"])

        # loop over the keys corresponding to disk positions
        for k in keys(f)
            # get the axis and mu values
            attr = HDF5.attributes(f[k])
            ax = read(attr["axis"])
            mu = read(attr["mu"])

            # only read in the first set of observations
            if contiguous_only
                t = first(keys(f[k]))
                bis = read(f[k][t]["bisectors"])
                int = read(f[k][t]["intensities"])
                wid = read(f[k][t]["widths"])
            # stitch together all observations of given disk position
            else
                # get total number of epochs
                ntimes = zeros(Int, length(f[k]))
                for (i, t) in enumerate(keys(f[k]))
                    ntimes[i] = read(HDF5.attributes(f[k][t])["length"])
                end

                # allocate memory
                bis = zeros(100, sum(ntimes))
                int = zeros(100, sum(ntimes))
                wid = zeros(100, sum(ntimes))

                # read in
                for (i, t) in enumerate(keys(f[k]))
                    bis[:, sum(ntimes[1:i-1])+1:sum(ntimes[1:i])] = read(f[k][t]["bisectors"])
                    int[:, sum(ntimes[1:i-1])+1:sum(ntimes[1:i])] = read(f[k][t]["intensities"])
                    wid[:, sum(ntimes[1:i-1])+1:sum(ntimes[1:i])] = read(f[k][t]["widths"])
                end

                # match the means of the various datasets
                if adjust_mean
                    adjust_data_mean(bis, ntimes)
                end
            end

            # clean the input data
            # TODO: revisit this
            bis, int, wid = clean_input(bis, int, wid)

            # extrapolate over data where uncertainty explodes
            if extrapolate
                for i in 1:size(bis,2)
                    # take a slice for one time snapshot
                    bist = view(bis, :, i)
                    intt = view(int, :, i)

                    # fix the bottom
                    idx1 = searchsortedfirst(intt, minimum(intt) + 0.1)
                    idx2 = searchsortedfirst(intt, minimum(intt) + 0.2)
                    fit = pfit(intt[idx1:idx2], bist[idx1:idx2], 1)
                    bist[1:idx1] .= evalpoly.(intt[1:idx1], tuple(coeffs(fit)))

                    # find indices, fit the data, and replace with fit
                    idx1 = searchsortedfirst(intt, 0.7)
                    idx2 = searchsortedfirst(intt, 0.8)
                    fit = pfit(intt[idx1:idx2], bist[idx1:idx2], 1)
                    bist[idx2:end] .= evalpoly.(intt[idx2:end], tuple(coeffs(fit)))
                end
            end

            # express bisector wavelengths relative to λrest
            if relative
                relative_bisector_wavelengths(bis, λrest)
            end

            # assign input data to dictionary
            lengths[Symbol(ax), Symbol(mu)] = size(bis, 2)
            bisdict[Symbol(ax), Symbol(mu)] = (bis .* !fixed_bisector) .+ (λrest .* fixed_bisector * !relative)
            intdict[Symbol(ax), Symbol(mu)] = int
            if !fixed_width
                widdict[Symbol(ax), Symbol(mu)] = wid
            else
                wid .= wid[:,1]
                widdict[Symbol(ax), Symbol(mu)] = wid
            end
            push!(axs, ax)
            push!(mus, mu)
        end
    end
    axs = Symbol.(unique(axs))
    mus = Symbol.(sort!(unique(mus)))
    return SolarData(bisdict, intdict, widdict, lengths, axs, mus)
end
