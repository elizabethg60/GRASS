struct SolarData{T1<:AF}
    bis::Dict{Tuple{Symbol,Symbol}, AbstractArray{T1,2}}
    int::Dict{Tuple{Symbol,Symbol}, AbstractArray{T1,2}}
    wid::Dict{Tuple{Symbol,Symbol}, AbstractArray{T1,2}}
    top::Dict{Tuple{Symbol,Symbol}, AbstractArray{T1,1}}
    len::Dict{Tuple{Symbol,Symbol}, Int}
    ax::Array{Symbol,1}
    mu::Array{Symbol,1}
end

"""
    SolarData(; dir=soldir, relative=true, ...)

Construct a `SpecParams` composite type instance.

# Arguments
- `dir::String=soldir`: Directory containing the pre-processed input data. Default directory is set in src/config.jl
- `relative::Bool=true`: Set whether bisectors are measured on absolute wavelength scale or expressed relative to rest wavelength of the line.
"""
function SolarData(;fname::String="", relative::Bool=true, extrapolate::Bool=true,
                    adjust_mean::Bool=true, contiguous_only::Bool=false,
                    fixed_width::Bool=false, fixed_bisector::Bool=false,)
    if isempty(fname)
        fname = GRASS.soldir * "FeI_5434.h5"
    end
    return SolarData(fname, relative=relative, extrapolate=extrapolate,
                     adjust_mean=adjust_mean, contiguous_only=contiguous_only,
                     fixed_width=fixed_width, fixed_bisector=fixed_bisector)
end

function SolarData(fname::String; relative::Bool=true, extrapolate::Bool=true,
                    adjust_mean::Bool=true, contiguous_only::Bool=false,
                    fixed_width::Bool=false, fixed_bisector::Bool=false,)
    # make sure the file exists
    @assert isfile(fname)

    # initialize data structure for input data
    topdict = Dict{Tuple{Symbol,Symbol}, AA{Float64,1}}()
    bisdict = Dict{Tuple{Symbol,Symbol}, AA{Float64,2}}()
    intdict = Dict{Tuple{Symbol,Symbol}, AA{Float64,2}}()
    widdict = Dict{Tuple{Symbol,Symbol}, AA{Float64,2}}()
    lengths = Dict{Tuple{Symbol,Symbol}, Int}()
    axs = []
    mus = []

    # set top buffer
    # blend_lines = ["CaI_6169.0", "FeI_5250.6", "FeI_5383",
    #                "FeI_5432", "FeI_5434", "NiI_5435",
    #                "NiI_5578", "FeI_6301"]
    blend_lines = ["FeI_5434"]
    if any(map(x -> contains(fname, x), blend_lines))
        top_buff = 0.0 # 0.075
    else
        top_buff = 0.0
    end


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
                # get key and length of data set
                t = first(keys(f[k]))
                ntimes = [read(HDF5.attributes(f[k][t])["length"])]

                # read in
                top = read(f[k[t]]["top_ints"])
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
                top = zeros(sum(ntimes))
                bis = zeros(100, sum(ntimes))
                int = zeros(100, sum(ntimes))
                wid = zeros(100, sum(ntimes))

                # read in
                for (i, t) in enumerate(keys(f[k]))
                    top[sum(ntimes[1:i-1])+1:sum(ntimes[1:i])] = read(f[k][t]["top_ints"])
                    bis[:, sum(ntimes[1:i-1])+1:sum(ntimes[1:i])] = read(f[k][t]["bisectors"])
                    int[:, sum(ntimes[1:i-1])+1:sum(ntimes[1:i])] = read(f[k][t]["intensities"])
                    wid[:, sum(ntimes[1:i-1])+1:sum(ntimes[1:i])] = read(f[k][t]["widths"])
                end
            end

            # identify bad columns and strip them out
            badcols = identify_bad_cols(bis, int, wid)

            if sum(badcols) > 0
                top = strip_columns(top, badcols)
                bis = strip_columns(bis, badcols)
                int = strip_columns(int, badcols)
                wid = strip_columns(wid, badcols)
            end

            # match the means of the various datasets
            if adjust_mean && !contiguous_only
                # fix ntimes to deal with removed columns
                inds = findall(badcols)
                ntimes_cum = cumsum(ntimes)
                for i in inds
                    idx = findfirst(x -> x .>= i, ntimes_cum)
                    ntimes[idx] -= 1
                end

                # now adjust the mean
                adjust_data_mean(bis, ntimes)
            end

            if extrapolate
                # deal with blends in a couple lines
                top .-= top_buff

                # extrapolate over data where uncertainty explodes
                for i in 1:size(bis,2)
                    # take a slice for one time snapshot
                    bist = view(bis, :, i)
                    intt = view(int, :, i)
                    widt = view(wid, :, i)

                    # fit the bottom bisector area and replace with model fit
                    idx1 = searchsortedfirst(intt, minimum(intt) + 0.05)
                    idx2 = searchsortedfirst(intt, minimum(intt) + 0.15)
                    bfit = pfit(view(intt, idx1:idx2), view(bist, idx1:idx2), 1)
                    bist[1:idx1] .= bfit.(view(intt, 1:idx1))

                    # fit the top bisector area and replace with model fit
                    idx1 = searchsortedfirst(intt, top[i] - 0.1)
                    idx2 = searchsortedfirst(intt, top[i])
                    bfit = pfit(view(intt, idx1:idx2), view(bist, idx1:idx2), 1)
                    bist[idx2:end] .= bfit.(view(intt, idx2:length(intt)))

                    # extrapolate the width up to the continuum
                    # TODO revisit this
                    idx1 = length(widt) - 1
                    wfit = pfit(view(intt, idx1:length(intt)), view(widt, idx1:length(intt)), 1)
                    widt[idx1:end] .= wfit.([intt[idx1], 1.0])
                    intt[end] = 1.0
                end
            end

            # express bisector wavelengths relative to λrest
            if relative
                relative_bisector_wavelengths(bis, λrest)
            end

            # assign input data to dictionary
            lengths[Symbol(ax), Symbol(mu)] = size(bis, 2)
            topdict[Symbol(ax), Symbol(mu)] = top
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
    return SolarData(bisdict, intdict, widdict, topdict, lengths, axs, mus)
end
