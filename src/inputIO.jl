function parse_mu_string(s::String)
    s = s[3:end]
    return tryparse(Float64, s[1] * "." * s[2:end])
end

function parse_mu_string(s::Symbol)
    return parse_mu_string(string(s))
end

function parse_ax_string(s::String)
    if s == "c"; return 0; end;
    if s == "n"; return 1; end;
    if s == "s"; return 2; end;
    if s == "e"; return 3; end;
    if s == "w"; return 4; end;
end

function parse_ax_string(s::Symbol)
    return parse_ax_string(string(s))
end

function adjust_data_mean(arr::AA{T,2}, ntimes::Vector{Int64}) where T<:Real
    # get the mean of the first dataset
    group1 = view(arr, :, 1:ntimes[1])
    meangroup1 = dropdims(mean(group1, dims=2), dims=2)

    # loop over the nth datasets
    for i in 2:length(ntimes)
        # get the mena
        groupn = view(arr, :, sum(ntimes[1:i-1])+1:sum(ntimes[1:i]))
        meangroupn = dropdims(mean(groupn, dims=2), dims=2)

        # find the distance between the means and correct by it
        meandist = meangroupn - meangroup1
        groupn .-= meandist
    end
    return nothing
end

function clean_input(bisall::AA{T,2}, intall::AA{T,2}, widall::AA{T,2}) where T<:AF
    @assert size(bisall) == size(intall) == size(widall)

    # make boolean array (column will be stripped if badcol[i] == true)
    badcols = zeros(Bool, size(bisall,2))

    # find standarad deviation of data
    bis_std = std(bisall, dims=2)
    wid_std = std(widall, dims=2)

    # find mean and median of data
    bis_avg = mean(bisall, dims=2)
    wid_avg = mean(widall, dims=2)
    bis_med = median(bisall, dims=2)
    wid_med = median(widall, dims=2)

    # loop through checking for bad columns
    for i in 1:size(bisall,2)
        bist = view(bisall, :, i)
        intt = view(intall, :, i)
        widt = view(widall, :, i)

        # check for monotinicity in measurements
        if !ismonotonic(widt)
            badcols[i] = true
        end

        if !ismonotonic(intt)
            badcols[i] = true
        end

        # check for skipped epochs in preprocessing
        if all(iszero.(intt))
            badcols[i] = true
        end

        # remove data that is significant outlier
        idx = searchsortedfirst(intt, 0.9)
        bis_cond = any(abs.(bis_avg[1:idx] .- bist[1:idx]) .> (5.0 .* bis_std[1:idx]))
        wid_cond = any(abs.(wid_avg[1:idx] .- widt[1:idx]) .> (5.0 .* wid_std[1:idx]))
        if bis_cond | wid_cond
            badcols[i] = true
        end
    end

    # strip the bad columns and return new arrays
    return strip_columns(bisall, badcols), strip_columns(intall, badcols), strip_columns(widall, badcols)
end

function relative_bisector_wavelengths(bis::AA{T,2}, λrest::T) where T<:AF
    λgrav = (635.0/c_ms) * λrest
    for i in 1:size(bis,2)
        bis[:,i] .-= (λrest .+ λgrav)
    end
    return nothing
end
