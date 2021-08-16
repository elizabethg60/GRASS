# imports
using Pkg; Pkg.activate(".")
using GRASS
using Statistics

# plotting
using LaTeXStrings
import PyPlot; plt = PyPlot; mpl = plt.matplotlib; plt.ioff()
using PyCall; animation = pyimport("matplotlib.animation");
mpl.style.use(GRASS.moddir * "figures/fig.mplstyle")

# define rms loop function
include(GRASS.moddir * "figures/rms_loop.jl")

# set boolean for writing plot
write = true
grassdir, plotdir, datadir = check_plot_dirs()

# figure 1b -- input bisectors w/ variability
function plot_input_variability()
    # get input data
    bisinfo = GRASS.SolarData(relative=true)

    # initialize plot objects
    fig, ax1 = plt.subplots()

    # loop and plot
    keyz = [(:c, :mu10), (:w, :mu06), (:w, :mu03)]
    labels = [L"\mu = 1.0", L"\mu = 0.6", L"\mu = 0.3"]
    for (i, key) in enumerate(keyz)
        # find average and std
        avg_bis = mean(bisinfo.bis[key], dims=2)
        avg_wav = mean(bisinfo.wav[key], dims=2)
        std_bis = std(bisinfo.bis[key], dims=2)
        std_wav = std(bisinfo.wav[key], dims=2)

        # convert to doppler velocity
        restwav = 5434.5232                         # angstroms
        avg_wav = avg_wav ./ restwav .* GRASS.c_ms
        std_wav = std_wav ./ restwav .* GRASS.c_ms

        # cut off top portion, where uncertainty is large
        ind = findfirst(avg_bis .> 0.86)[1]
        avg_bis = avg_bis[1:ind]
        avg_wav = avg_wav[1:ind]
        std_bis = std_bis[1:ind]
        std_wav = std_wav[1:ind]

        # fix dimensions
        y = reshape(avg_bis, length(avg_bis))
        x1 = reshape(avg_wav .+ std_wav, length(avg_bis))
        x2 = reshape(avg_wav .- std_wav, length(avg_bis))

        # plot the curve
        ax1.fill_betweenx(y, x1, x2, color="C"*string(i-1), alpha=0.5)
        ax1.plot(avg_wav, avg_bis, color="C"*string(i-1), label=labels[i])
    end
    ax1.legend(loc="upper right")
    ax1.set_xlabel(L"{\rm Doppler\ Velocity\ (ms}^{-1} {\rm )}")
    ax1.set_ylabel(L"{\rm Normalized\ Flux}")

    # write the file or show it
    if write
        fig.savefig(plotdir * "fig1b.pdf")
        plt.clf(); plt.close()
        println(">>> Figure written to: " * plotdir * "fig1b.pdf")
    else
        plt.show()
        plt.clf(); plt.close()
    end
    return nothing
end

plot_input_variability()
