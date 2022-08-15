using Pkg; Pkg.activate(".")
using CSV
using HDF5
using Glob
using DataFrames
using Statistics
using GRASS

import PyPlot; plt = PyPlot; mpl = plt.matplotlib; plt.ioff()
using LaTeXStrings
# mpl.style.use(GRASS.moddir * "figures1/fig.mplstyle")

# set LARS spectra absolute dir and read line info file
const data_dir = "/storage/group/ebf11/default/mlp95/lars_spectra/"
const line_info = CSV.read(GRASS.soldir * "line_info.csv", DataFrame)

# function to write line parameters file
function write_line_params(line_df::DataFrame)
    # read in the IAG data and isolate the line
    iag_wavs, iag_flux = read_iag(isolate=true, airwav=line_df.air_wav[1])
    iag_depth = 1.0 - minimum(iag_flux)

    # get the filename
    line_dir = GRASS.soldir * line_df.name[1] * "/"
    prop_file =  line_dir * line_df.name[1] * "_line_properties.h5"

    # write the line properties file
    println(">>> Writing " * line_df.name[1] * "_line_properties.h5")
    h5open(prop_file, "w") do fid
        create_group(fid, "properties")
        g = fid["properties"]

        # fill out attributes
        attr = attributes(g)
        for n in names(line_df)
            if ismissing(line_df[!, n][1])
                attr[n] = NaN
            else
                attr[n] = line_df[!, n][1]
            end
        end
        attr["depth"] = iag_depth
    end
    return nothing
end

function preprocess_line(line_name::String)
    # create subdirectory structure if it doesn't already exist
    if !isdir(GRASS.soldir * line_name)
        mkdir(GRASS.soldir * line_name)
    end

    # find row with line info and write the line_params file
    line_df = subset(line_info, :name => x -> x .== line_name)
    write_line_params(line_df)

    # find all the spectra files associated with this line
    fits_files = Glob.glob("*.fits", data_dir * line_df.spectra_dir[1] * "/")

    # read in the spectrum and bin into 15-second bins
    for f in fits_files
        # get spec parameters
        # params = GRASS.extract_line_params(f)
        params = GRASS.extract_line_params(fits_files[1])

        # wavs, flux = GRASS.bin_spectrum(GRASS.read_spectrum(f)...)
        wavs, flux = GRASS.bin_spectrum(GRASS.read_spectrum(fits_files[1])...)

        # normalize the spectra
        flux ./= maximum(flux, dims=1)

        # loop over epochs in data
        for t in 1:size(wavs, 2)
            # refine the location of the minimum
            idx = findfirst(x -> x .>= line_df.air_wav[1], wavs[:,t])
            min = argmin(flux[idx-50:idx+50, t]) + idx - 50

            # isolate the line
            idx1 = findfirst(x -> x .>= wavs[min - 75, t], wavs[:, t])
            idx2 = findfirst(x -> x .>= wavs[min + 75, t], wavs[idx1:end, t]) + idx1
            wavs_iso = wavs[idx1:idx2]
            flux_iso = flux[idx1:idx2]

            # measure a bisector
            wav, bis = GRASS.measure_bisector(wavs_iso, flux_iso, interpolate=false)
            wid, dep = GRASS.measure_width_loop(wavs_iso, flux_iso)

        end


        break


    end


    return nothing
end

function main()

    return
end
