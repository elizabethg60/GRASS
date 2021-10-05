function ismonotonic(A::AA{T,1}) where T<:AF
    return (all(diff(A) .>= zero(T)) | all(diff(A) .<= zero(T)))
end

function strip_columns(A::AA{T,2}, cols::AA{Bool,1}) where T<:AF
    @assert length(cols) == size(A,2)
    return A[:, .!cols]
end

# credit: traktofon @ https://discourse.julialang.org/t/findnearest-function/4143/4
function searchsortednearest(a::AbstractVector{T}, x::T) where T
    idx = searchsortedfirst(a,x)
    if (idx==1); return idx; end
    if (idx>length(a)); return length(a); end
    if (a[idx]==x); return idx; end
    if (abs(a[idx]-x) < abs(a[idx-1]-x))
        return idx
    else
        return idx-1
    end
end

function searchsortednearest(x::T, a::AbstractVector{T}) where T
    return searchsortednearest(a, x)
end

"""
    calc_rms(A)

Calculate the RMS of given data about the observed mean.

# Arguments
- `A::AbstractArray{Float64,1}`: 1D array containing data for RMS calculation
"""
function calc_rms(A::AA{T,1}) where T<:AF
    return sqrt(sum((A.-mean(A)).^2)/length(A))
end

# function calc_rms(A::AA{T,N}; dims::Integer) where {T,N}
#     1 <= dims <= N || throw(ArgumentError("dimension $dims out of range (1:$N)"))
#     r = axes(A)
#     r0 = ntuple(i -> i == dims ? UnitRange(1, last(r[i]) - 1) : UnitRange(r[i]), N)
#     r1 = ntuple(i -> i == dims ? UnitRange(2, last(r[i])) : UnitRange(r[i]), N)
#     return sqrt(sum((A.-mean(A)).^2)/length(A))
# end

function strip_nans_by_column(A::AA{T,1}) where T<:AF
    nans = isnan.(A)
    return A[.!vec(nans)]
end

function strip_nans_by_column(A::AA{T,2}) where T<:AF
    nancols = all(isnan.(A), dims=1)
    return A[:,.!vec(nancols)]
end

function strip_nans_by_row(A::AA{T,2}) where T<:AF
    nanrows = all(isnan.(A), dims=2)
    return A[.!vec(nanrows),:]
end

function findnearest(A::AA{T,1}, t) where T<:Real
    return findmin(abs.(A.-t))[2]
end
