function trim_bisector_chop!(depth::T, wavt::AA{T,1}, bist::AA{T,1},
                             dept::AA{T,1}, widt::AA{T,1};
                             top::T=NaN) where T<:AF
    # # replace spurious measurements at top of bisector
    # ind1 = searchsortedfirst(bist, one(T) - depth)

    # if !isnan(top)
    #     ind2 = searchsortedfirst(bist, top)
    #     wavt[ind2:end] .= wavt[ind2]
    # end

    # # set up interpolant
    # xs = view(bist, ind1:length(bist))
    # ys = view(wavt, ind1:length(wavt))
    # itp1 = linear_interp(xs, ys)

    # create interpolator
    itp1 = linear_interp(bist, wavt)

    # get new grid of depths, interpolate the data, and return
    dept .= range((one(T) - depth), one(T), length=length(dept))
    wavt .= itp1.(dept)
    bist .= dept
    return nothing
end
