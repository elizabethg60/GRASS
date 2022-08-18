using Pkg; Pkg.activate(".")
using CSV
using HDF5
using Glob
using LsqFit
using DataFrames
using Statistics
using Polynomials
using GRASS

import PyPlot; plt = PyPlot; mpl = plt.matplotlib; plt.ioff()
using LaTeXStrings
mpl.style.use(GRASS.moddir * "figures1/fig.mplstyle")

# set LARS spectra absolute dir and read line info file
const data_dir = "/storage/group/ebf11/default/mlp95/lars_spectra/"
const line_info = CSV.read(GRASS.soldir * "line_info.csv", DataFrame)

# function to write line parameters file
function write_line_params(line_df::DataFrame; clobber::Bool=false)
    # get the filename
    line_dir = GRASS.soldir * line_df.name[1] * "/"
    prop_file =  line_dir * line_df.name[1] * "_line_properties.h5"

    # don't bother if the file already exists
    if isfile(prop_file) & !clobber
        println("\t >>> " * splitdir(prop_file)[end] * " already exists...")
        return nothing
    end

    # read in the IAG data and isolate the line
    iag_wavs, iag_flux = read_iag(isolate=true, airwav=line_df.air_wavelength[1])
    iag_depth = 1.0 - minimum(iag_flux)

    # write the line properties file
    println("\t >>> Writing " * line_df.name[1] * "_line_properties.h5")
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

function write_input_data(line_name, air_wavelength, fparams, wav, bis, dep, wid)
    # create output file name
    new_file = line_name * "_" * string(fparams[3]) * "_" * fparams[5] * "_" * fparams[6] * "_input.h5"

    # write the input data to the file
    h5open(GRASS.soldir * line_name * "/" * new_file, "w") do fid
        # create the group
        create_group(fid, "input_data")
        g = fid["input_data"]

        # fill out the datasets
        g["wavelengths"] = wav
        g["bisectors"] = bis
        g["depths"] = dep
        g["widths"] = wid

        # make attributes
        attr = attributes(g)
        attr["datetime"] = string(fparams[3])
        attr["air_wavelength"] = air_wavelength

        # convert mu to number
        mu_num = []
        for ch in fparams[5]
            push!(mu_num, tryparse(Int64, string(ch)))
        end

        new_string = prod(string.(mu_num[.!isnothing.(mu_num)]))
        if new_string[1] == '1'
            attr["mu"] = 1.0
            attr["axis"] = "c"
        elseif new_string[1] == '0'
            attr["mu"] = parse(Float64, "0." * new_string[2:end])
            attr["axis"] = fparams[6]
        end
    end
    return nothing
end

function find_wing_index(val, arr; min=argmin(arr))
    lidx = min - findfirst(x -> x .>= val, reverse(arr[1:min]))
    ridx = findfirst(x -> x .>= val, arr[min:end]) + min
    return lidx, ridx
end


function fit_line_wings(wavs_iso, flux_iso)
    # get indices and values for minimum, depth, and bottom
    min = argmin(flux_iso)
    bot = flux_iso[min]
    depth = 1.0 - bot

    # get wing indices for various percentage depths into line
    lidx50, ridx50 = find_wing_index(0.5 * depth + bot, flux_iso, min=min)
    lidx60, ridx60 = find_wing_index(0.6 * depth + bot, flux_iso, min=min)
    lidx70, ridx70 = find_wing_index(0.7 * depth + bot, flux_iso, min=min)
    lidx80, ridx80 = find_wing_index(0.8 * depth + bot, flux_iso, min=min)
    lidx90, ridx90 = find_wing_index(0.9 * depth + bot, flux_iso, min=min)

    # isolate the line wings and mask area around line core for fitting
    Δbot = 2
    core = min-Δbot:min+Δbot
    lwing = lidx90:lidx50
    rwing = ridx50:ridx90
    wavs_fit = vcat(wavs_iso[lwing], wavs_iso[core], wavs_iso[rwing])
    flux_fit = vcat(flux_iso[lwing], flux_iso[core], flux_iso[rwing])

    # set boundary conditions and initial guess
    # GOOD FOR FeI 5434 + others
    lb = [0.0, wavs_iso[min], 0.0, 0.0]
    ub = [1.0, wavs_iso[min], 0.5, 0.5]
    p0 = [1.0 - depth, wavs_iso[min], 0.02, 0.01]
    # GOOD FOR FeI 5434 + others

    # perform the fit
    fit = curve_fit(GRASS.fit_voigt, wavs_fit, flux_fit, p0, lower=lb, upper=ub)
    @show fit.param
    return fit
end

function replace_line_wings(fit, wavst, fluxt, min, val; debug=false)
    # get line model for all wavelengths in original spectrum
    flux_new = GRASS.fit_voigt(wavst, fit.param)

    # do a quick "normalization"
    flux_new ./= maximum(flux_new)

    # find indices
    idxl, idxr = find_wing_index(val, fluxt, min=min)
    if debug
        plt.axhline(fluxt[idxl], c="k", ls="--", alpha=0.5)
        plt.axhline(fluxt[idxr], c="k", ls="--", alpha=0.5)
        plt.plot(wavst, flux_new, c="tab:purple", label="model")
    end

    # replace wings with model
    fluxt[1:idxl] .= flux_new[1:idxl]
    fluxt[idxr:end] .= flux_new[idxr:end]
    return nothing
end

function preprocess_line(line_name::String; verbose::Bool=true, debug::Bool=false)
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
    for i in eachindex(fits_files)
        # debugging block
        if debug && i > 1
            break
        end

        # print the filename
        if verbose
            println("\t >>> Processing " * splitdir(fits_files[i])[end])
        end

        # get spec parameters
        fparams = GRASS.extract_line_params(fits_files[i])
        wavs, flux = GRASS.bin_spectrum(GRASS.read_spectrum(fits_files[i])...)

        # normalize the spectra
        flux ./= maximum(flux, dims=1)

        # debugging plot
        if debug
            plt.plot(wavs[:,1], flux[:,1], c="k", label="raw spec")
        end

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

            # refine the location of the minimum
            idx = findfirst(x -> x .>= line_df.air_wavelength[1], wavst)
            min = argmin(fluxt[idx-50:idx+50]) + idx - 50
            bot = fluxt[min]
            depth = 1.0 - bot

            # isolate the line
            idx1, idx2 = find_wing_index(0.95, fluxt, min=min)
            wavs_iso = copy(view(wavst, idx1:idx2))
            flux_iso = copy(view(fluxt, idx1:idx2))

            # fit the line wings
            fit = fit_line_wings(wavs_iso, flux_iso)

            # replace the line wings above val% continuum
            val = 0.9 #* depth + bot
            replace_line_wings(fit, wavst, fluxt, min, val, debug=debug)

            # oversample it to get better precision in wings
            # itp = GRASS.linear_interp(wavs[:,t], flux[:,t])
            # wavs_meas = range(first(wavs[:,t]), last(wavs[:,t]), step=wavs[min,t]/1.5e6)
            # flux_meas = itp.(wavs_meas)

            # TODO REVIEW BISECTOR CODE
            # measure the bisector and width function
            wav[:,t], bis[:,t] = GRASS.measure_bisector_interpolate(wavst, fluxt, top=0.99)
            dep[:,t], wid[:,t] = GRASS.measure_width_interpolate(wavst, fluxt, top=0.99)

            # # set any widths less than zero to 0
            # idx = findall(x -> x .< 0.0, view(wid, :, t))
            # wid[idx,t] .= 0.0

            # # polyfit the last three points and extrapolate to continuum
            # idx8 = findfirst(x -> x .>= 0.8, dep[:,t])
            # idx9 = findfirst(x -> x .>= 0.9, dep[:,t])
            # pfit = Polynomials.fit(dep[idx9-10:idx9,t], wid[idx9-10:idx9,t], 2)
            # wid[idx9:end, t] = pfit.(dep[idx9:end, t])

            # DEBUGGING STUFF
            if debug
                plt.plot(wavst, fluxt, c="tab:orange", ls="--", label="cleaned")
                plt.plot(wav[:,t], bis[:,t], c="tab:blue")
                plt.legend()
                plt.show()

                plt.plot(dep[:,t], wid[:,t])
            end

            # plt.plot(dep[:,t], wid[:,t]); plt.show()

            # plt.plot(dep[1:idx9,t], wid[1:idx9,t], c="k", label="original")
            # plt.plot(dep[idx9:end,t], wid[idx9:end,t], label="extrap")
            # DEBUGGING STUFF
        end

        # DEBUGGING STUFF
        # lambdas = range(5433, 5436, step=5434.5/1e6)
        # prof = ones(length(lambdas))
        # lwavgrid = zeros(100)
        # rwavgrid = zeros(100)
        # allwavs = zeros(200)
        # allints = zeros(200)
        # GRASS.extrapolate_bisector(view(wav,:,1:1), view(bis,:,1:1))
        # GRASS.extrapolate_width(view(dep,:,1:1), view(wid,:,1:1))
        # plt.plot(wav[:,1], bis[:,1], c="tab:orange", ls="--")
        # GRASS.line_profile_cpu!(5434.535, lambdas, prof, wav[:,1] .- mean(wav[:,1]), dep[:,1], wid[:,1], lwavgrid, rwavgrid, allwavs, allints)

        # plt.plot(lambdas, prof, c="k", ls="--")
        # plt.show()
        # DEBUGGING STUFF

        # write input data to disk
        write_input_data(line_name, line_df.air_wavelength[1], fparams, wav, bis, dep, wid)
    end
    return nothing
end

function main()
    for name in line_info.name
        if name == "FeI_5434"
            println(">>> Processing " * name * "...")
            preprocess_line(name, debug=true)
        end
    end
    return nothing
end

main()
