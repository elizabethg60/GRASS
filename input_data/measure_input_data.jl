using Pkg; Pkg.activate(".")
using CSV
using HDF5
using Glob
using DataFrames
using Statistics
using GRASS

import PyPlot; plt = PyPlot; mpl = plt.matplotlib; plt.ioff()
using LaTeXStrings
mpl.style.use(GRASS.moddir * "figures1/fig.mplstyle")

# set LARS spectra absolute dir and read line info file
const data_dir = "/storage/group/ebf11/default/mlp95/lars_spectra/"
const line_info = CSV.read(GRASS.soldir * "line_info.csv", DataFrame)

# output directories for misc stuff
const grassdir, plotdir, datadir = GRASS.check_plot_dirs()
if !isdir(plotdir * "spectra_fits")
    mkdir(plotdir * "spectra_fits")
end

function preprocess_line(line_name::String; verbose::Bool=true, debug::Bool=false)
    # create subdirectory structure if it doesn't already exist
    if !isdir(GRASS.soldir * line_name)
        mkdir(GRASS.soldir * line_name)
    end

    # find row with line info and write the line_params file
    line_df = subset(line_info, :name => x -> x .== line_name)
    if !debug
        write_line_params(line_df)
    end

    # find all the spectra files associated with this line
    fits_files = Glob.glob("*.fits", data_dir * line_df.spectra_dir[1] * "/")

    # read in the spectrum and bin into 15-second bins
    for i in eachindex(fits_files)
        # debugging block
        if debug && i > 1
            break
        end

        # print the filename
        if verbose
            println("\t >>> " * splitdir(fits_files[i])[end])
        end

        # get spec parameters
        fparams = GRASS.extract_line_params(fits_files[i])
        wavs, flux = GRASS.bin_spectrum(GRASS.read_spectrum(fits_files[i])...)

        # normalize the spectra
        flux ./= maximum(flux, dims=1)

        # allocate memory for input data
        wav = zeros(100, size(wavs,2))
        bis = zeros(100, size(wavs,2))
        wid = zeros(100, size(wavs,2))
        dep = zeros(100, size(wavs,2))

        # loop over epochs in spectrum file
        for t in 1:size(wavs, 2)
            # debugging block
            if debug && t > 1
                break
            end

            # get view of this time slice
            wavst = view(wavs, :, t)
            fluxt = view(flux, :, t)
            if debug
                fig, (ax1, ax2) = plt.subplots(1,2, figsize=(9,6))
                ax1.plot(wavst, fluxt, c="k", label="raw spec")
            end

            # refine the location of the minimum
            idx = findfirst(x -> x .>= line_df.air_wavelength[1], wavst)
            min = argmin(fluxt[idx-50:idx+50]) + idx - 50
            bot = fluxt[min]
            depth = 1.0 - bot

            # isolate the line
            idx1, idx2 = GRASS.find_wing_index(0.95, fluxt, min=min)
            wavs_iso = copy(view(wavst, idx1:idx2))
            flux_iso = copy(view(fluxt, idx1:idx2))

            # fit the line wings
            fit = GRASS.fit_line_wings(wavs_iso, flux_iso)

            # pad the spectrum if line is close to edge of spectral region
            buff = 1.25
            if wavst[min] - first(wavst) < buff
                wavs_pad = range(first(wavst) - buff, first(wavst), step=minimum(diff(wavst)))
                wavs_meas = vcat(wavs_pad[1:end-1], wavst)
                flux_meas = vcat(ones(length(wavs_pad)-1), fluxt)
            elseif last(wavst) - wavst[min] < buff
                wavs_pad = range(last(wavst), last(wavst) + buff, step=minimum(diff(wavst)))
                wavs_meas = vcat(wavst, wavs_pad[2:end])
                flux_meas = vcat(fluxt, ones(length(wavs_pad)-1))
            else
                wavs_meas = wavst
                flux_meas = fluxt
            end

            # replace the line wings above val% continuum
            val = 0.9 #* depth + bot
            if debug
                idxl, idxr = GRASS.find_wing_index(val, flux_meas, min=min)
                ax1.axhline(flux_meas[idxl], c="k", ls="--", alpha=0.5)
                ax1.axhline(flux_meas[idxr], c="k", ls="--", alpha=0.5)
                ax1.plot(wavs_meas, GRASS.fit_voigt(wavs_meas, fit.param), c="tab:purple", label="model")
            end
            GRASS.replace_line_wings(fit, wavs_meas, flux_meas, min, val, debug=debug)

            # TODO REVIEW BISECTOR CODE
            # measure the bisector and width function
            wav[:,t], bis[:,t] = GRASS.measure_bisector_interpolate(wavs_meas, flux_meas, top=0.999)
            dep[:,t], wid[:,t] = GRASS.measure_width_interpolate(wavs_meas, flux_meas, top=0.999)

            # debug plottings
            if debug
                ax1.plot(wavs_meas, flux_meas, c="tab:orange", ls="--", label="cleaned")
                ax1.plot(wav[:,t], bis[:,t], c="tab:blue", label="bisector")
                ax1.set_xlabel("Wavelength")
                ax1.set_ylabel("Normalized Intensity")
                ax1.legend()

                ax2.plot(dep[:,t], wid[:,t])
                ax2.set_xlabel("Normalized Intensity")
                ax2.set_ylabel("Width across line")
                fig.suptitle("\${\\rm " * replace(line_df.name[1], "_" => "\\ ") * "}\$")
                fig.savefig(plotdir * "spectra_fits/" * line_df.name[1] * ".pdf")
                plt.clf(); plt.close()
            end
        end

        # write input data to disk
        if !debug
            write_input_data(line_name, line_df.air_wavelength[1], fparams, wav, bis, dep, wid)
        end
    end
    return nothing
end

function main()
    for name in line_info.name
        # skip the "hard" lines for now
        name == "CI_5380" && continue
        name == "FeI_5382" && continue
        name == "NaI_5896" && continue
        name == "FeII_6149" && continue

        # print the line name and preprocess it
        println(">>> Processing " * name)
        preprocess_line(name, debug=true)
    end
    return nothing
end

main()
