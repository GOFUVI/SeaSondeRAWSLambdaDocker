#' Main Script for REST API and Configuration Handling
#'
#' This script loads necessary packages, reads and updates configurations,
#' processes input files, and defines REST endpoints via the plumber framework.

# Load the yaml package
if (!require("yaml", quietly = TRUE)) {
    install.packages("yaml", repos = "https://cran.r-project.org")
    library("yaml") # Load YAML support for reading configuration files
}
# Install and load the plumber package for REST API
if (!require("plumber", quietly = TRUE)) {
    install.packages("plumber", repos = "https://cran.r-project.org")
    library("plumber") # Load plumber for exposing REST endpoints
}

# Paths to the configuration files
config_path <- "settings.yaml"          # User configuration file path
default_config_path <- "settings.default.yaml"  # Default configuration file path

SeaSondeR::seasonder_disableMessages()

#' Read configuration from YAML files
#'
#' Reads the default configuration file and overrides it with the user configuration if provided.
#'
#' @param path Character. Path for the user configuration YAML file.
#' @param defaultPath Character. Path for the default configuration YAML file.
#' @return List. A combined configuration list.
read_configuration <- function(path = config_path, defaultPath = default_config_path) {
    config <- list()
    # Load default configuration if exists
    if (file.exists(defaultPath)) {
        config <- yaml::read_yaml(defaultPath)
    } else {
        cat("The default configuration file does not exist.\n")
    }
    
    # Override defaults with user configuration if available
    if (file.exists(path)) {
        user_config <- yaml::read_yaml(path)
        config <- modifyList(config, user_config)
    } else {
        cat("The user configuration file does not exist. Using default configuration.\n")
    }
    return(config)
}

#' Save configuration to a YAML file
#'
#' Saves the provided configuration settings (only non-defaults) to the YAML file.
#'
#' @param config List. The configuration settings to be saved.
#' @param path Character. Path to the YAML file.
#' @return NULL.
save_configuration <- function(config, path = config_path) {
    yaml::write_yaml(config, path)
}

#' Update a configuration option and save changes
#'
#' Updates the specified configuration key with a new value and writes the updated configuration to the file.
#'
#' @param key Character. The configuration key to update.
#' @param value Character. The new value for the key.
#' @param path Character. Path to the user configuration YAML file.
#' @return NULL.
update_configuration <- function(key, value, path = config_path) {
    # Read the current configuration if available
    user_config <- list()
    if (file.exists(path)) {
        user_config <- yaml::read_yaml(path)
    }
    # Process values for specific keys by trimming and splitting by comma
    if(key == "MUSIC_parameters"){
        value <- stringr::str_trim(unlist(strsplit(value, ",")))
    }
    if(key == "discard"){
        value <- stringr::str_trim(unlist(strsplit(value, ",")))
    }
    user_config[[key]] <- value
    save_configuration(user_config, path)
    cat(sprintf("The key '%s' has been updated to '%s'.\n", key, toString(value)))
}

# If the default configuration file does not exist, generate a default configuration.
if (!file.exists(default_config_path)) {
    config <- c(SeaSondeR:::seasonder_defaultFOR_parameters(), 
                SeaSondeR:::seasonder_defaultMUSIC_options(), 
                list(COMPUTE_FOR = F))
}

#' Process CSS file and generate radial metrics
#'
#' Processes the uploaded CSS file using the provided configuration options and returns the path to the radial metrics file.
#'
#' @param css_path Character. The path of the CSS file to process.
#' @param options List. The configuration options.
#' @return Character. File path to the generated radial metrics file.
process <- function(css_path, options){
    # Process the APM file and create a CS object
    seasonder_apm_obj <- SeaSondeR::seasonder_readSeaSondeRAPMFile(
        options$pattern_path
    )
    
    seasonder_cs_obj <- SeaSondeR::seasonder_createSeaSondeRCS(css_path, seasonder_apm_object = seasonder_apm_obj)
    
    # Validate parameters and set defaults
    options <- c(SeaSondeR:::seasonder_validateFOR_parameters(seasonder_cs_obj, list()), 
                 SeaSondeR:::seasonder_defaultMUSIC_options(), 
                 list(COMPUTE_FOR = F))
    
    # Define FOR (Frequency of Operation Ratio) parameters
    FOS <- list(
        nsm = as.integer(options$nsm),
        fdown = as.numeric(options$fdown),
        flim = as.numeric(options$flim),
        noisefact = as.numeric(options$noisefact),
        currmax = as.numeric(options$currmax),
        reject_distant_bragg = as.logical(options$reject_distant_bragg),
        reject_noise_ionospheric = as.logical(options$reject_noise_ionospheric),
        reject_noise_ionospheric_threshold = as.numeric(options$reject_noise_ionospheric_threshold)
    )
      
    seasonder_cs_obj <- SeaSondeR::seasonder_setFOR_parameters(seasonder_cs_obj, FOS)
    
    # Optionally compute FOR values
    if(options$COMPUTE_FOR){
      seasonder_cs_obj <- SeaSondeR::seasonder_computeFORs(seasonder_cs_obj, method = "SeaSonde")
    }
    
    # Prepare MUSIC (Multiple Signal Classification) options
    MUSIC_options <- list(
        PPMIN = options$PPMIN, 
        PWMAX = options$PPMAX, 
        smoothNoiseLevel = options$smoothNoiseLevel,
        discard = options$discard,
        doppler_interpolation = options$doppler_interpolation,
        MUSIC_parameters = options$MUSIC_parameters
    )
    
    seasonder_cs_obj <- SeaSondeR::seasonder_runMUSIC_in_FOR(seasonder_cs_obj, options = MUSIC_options)
    
    # Export radial metrics to a temporary file
    rm_file <- tempfile(fileext = ".ruv")
    radial_metrics <- SeaSondeR::seasonder_exportLLUVRadialMetrics(seasonder_cs_obj, rm_file)
    
    return(rm_file)
}

#* @put /config
#' Update configuration endpoint
#'
#' Updates a configuration key with a new value provided as query parameters.
#'
#' @param key Query string. Configuration key to update.
#' @param value Query string. New value for the key.
#' @response 200 Returns a confirmation message with updated key and value.
function(key, value) {
    update_configuration(key, value)
    return(list(status = "success", key = key, newValue = value))
}

# Code to start the REST server if desired:
# pr <- plumber::plumb("run.R")
# pr$run(port = 8000)

#* @post /process_css
#' Process CSS file endpoint
#'
#' Processes an uploaded CSS file and returns the computed radial metrics.
#'
#' @serializer contentType list(type="text/plain")
#' @param req Request object containing the uploaded file.
#' @response 200 Returns the contents of the radial metrics file.
function(req) {
    # Validate that a file has been uploaded
    if (!(length(req$body) > 0 && !is.null(req$body[[1]]$name) && !is.null(req$body[[1]]$filename))) {
        return(list(status = "error", message = "No file has been uploaded"))
    }
    file <- req$body[[1]]
    tmp <- tempfile()
    writeBin(file$value, tmp)
    
    options <- read_configuration()
    
    if(is.null(options$pattern_path)){
        return(list(status = "error", message = "No pattern file has been uploaded"))
    }
    
    rm_file <- process(tmp, options)
    readBin(rm_file, "raw", n = file.info(rm_file)$size)    
}

#* @post /upload_pattern
#' Upload pattern file endpoint
#'
#' Handles the upload of a pattern file, saves it on the server, and updates the configuration.
#'
#' @param req Request object containing the uploaded pattern file.
#' @response 200 Returns a success message if the file is processed correctly.
function(req) {
    save(req, file = "req.RData")
    
    # Validate file upload presence
    if (!(length(req$body) > 0 && !is.null(req$body[[1]]$name) && !is.null(req$body[[1]]$filename))) {
        return(list(status = "error", message = "No file uploaded."))
    }
    file <- req$body[[1]]
    
    # Create uploads directory if it does not exist
    uploads_dir <- "pattern"
    if (!dir.exists(uploads_dir)) {
        dir.create(uploads_dir)
    }
    
    tmp <- tempfile(fileext = ".txt")
    writeBin(file$value, tmp)
    
    # Try to read the pattern file as an APM file; handle errors if any
    apm_object <- try(SeaSondeR::seasonder_readSeaSondeRAPMFile(tmp), silent = TRUE) 
    if(inherits(apm_object, "try-error")) {
        return(list(status = "error", message = "Error reading the APM file."))
    }
    
    # Define destination path and copy the file there
    destination <- file.path(uploads_dir, file$filename)
    file.copy(tmp, destination)
    
    # Update configuration with the new pattern file path
    update_configuration("pattern_path", destination)
    
    return(list(status = "success"))
}