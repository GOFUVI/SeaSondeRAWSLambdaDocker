temp_dir <- "/tmp/runtime"
temp_input_files_dir <- file.path(temp_dir,"input_files")
temp_output_files_dir <- file.path(temp_dir,"output_files")


process_task <- function(task_index,taskIds,s3Keys,s3BucketArns){
  
 
  taskId <- taskIds[task_index]
  s3Key <- s3Keys[task_index]
  s3BucketArn <- s3BucketArns[task_index]
  
  # Copy files
  m <- regexec(":::(.*?)$",s3BucketArn)
  bucket  <- regmatches(s3BucketArn,m)[[1]][2]
  


  command <- paste("s3","cp --only-show-errors",paste0("s3://",bucket,"/",s3Key),temp_input_files_dir)
  
  out <- tryCatch({
    
    x <- system2("aws", command,stdout =  file.path(temp_dir,"sys.log"), stderr = file.path(temp_dir,"sys.log"), wait = TRUE)
    
    
    
    x == 0 || stop(paste0("Error while reading from S3. Reason: ",readLines("/tmp/runtime/sys.log")))
    
    file_to_read <- file.path(temp_input_files_dir,basename(s3Key))
    
    
    if (grepl("\\.gz$", file_to_read)) {
      # Descomprimir el fichero
      decompressed_file <- R.utils::gunzip(file_to_read, remove = FALSE, overwrite = TRUE)
      
      # Borrar el fichero comprimido
      file.remove(file_to_read)
      
      # Actualizar la ruta del fichero
      file_to_read <- decompressed_file
    }
    if(file.info(file_to_read)$size == 0){
      stop(paste0("File: '",s3Key,"' has size 0."))
    } 
    SeaSondeR::seasonder_disableMessages()
    

    
    seasonder_apm_obj <- SeaSondeR::seasonder_readSeaSondeRAPMFile("MeasPattern.txt")
    

    cs <- SeaSondeR::seasonder_createSeaSondeRCS(file_to_read, seasonder_apm_object = seasonder_apm_obj)                              
    
    file.remove(file_to_read)
    
    
    FOS <-   list(nsm = as.integer(Sys.getenv("SEASONDER_NSM")),
                    fdown = as.numeric(Sys.getenv("SEASONDER_FDOWN")),
                    flim = as.numeric(Sys.getenv("SEASONDER_FLIM")),
                    noisefact = as.numeric(Sys.getenv("SEASONDER_NOISEFACT")),
                    currmax = as.numeric(Sys.getenv("SEASONDER_CURRMAX")),
                    reject_distant_bragg =  as.logical(Sys.getenv("SEASONDER_REJECT_DISTANT_BRAGG")),
                    reject_noise_ionospheric = as.logical(Sys.getenv("SEASONDER_REJECT_NOISE_IONOSPHERIC")),
                    
                    reject_noise_ionospheric_threshold = as.numeric(Sys.getenv("SEASONDER_REJECT_NOISE_IONOSPHERIC_THRESHOLD"))
      )
    

    
    cs <- SeaSondeR::seasonder_computeFORs(cs, method = "SeaSonde", FOR_control = FOS)
  

    cs <- SeaSondeR::seasonder_runMUSIC_in_FOR(cs, 
    doppler_interpolation = as.integer(Sys.getenv("SEASONDER_DOPPLER_INTERPOLATION")),
    options = list(PPMIN = as.numeric(Sys.getenv("SEASONDER_PPMIN")), PWMAX = as.numeric(Sys.getenv("SEASONDER_PWMAX")))
    )
    
    # Save to AWS
    
    s3_path <- Sys.getenv("SEASONDER_S3_OUTPUT_PATH")
   
    # CS object
    
    outfile_name <- paste0(basename(tools::file_path_sans_ext(file_to_read)),".RData")
    
    outfile <- file.path(temp_output_files_dir,outfile_name)
    
    
    save(cs, file = outfile)
    
    outfile <- R.utils::gzip(outfile,overwrite = TRUE)
    outfile_name <- basename(outfile)
    
    s3_destination <- paste0("s3://",bucket,"/",s3_path,"/CS_Objects/")
    cs_object_s3_path <- paste0(s3_destination,outfile_name)
    command <- paste("s3","cp --only-show-errors",outfile,s3_destination)

    x <- system2("aws", command,stdout =  file.path(temp_dir,"sys.log"), stderr = file.path(temp_dir,"sys.log"), wait = TRUE)
    
    
    
    x == 0 || stop(paste0("Error while writing to S3. Reason: ",readLines("/tmp/runtime/sys.log")))
    
    file.remove(outfile)
   
   # Radial Metrics

    outfile_name <- paste0(basename(tools::file_path_sans_ext(file_to_read)),".ruv")
    
    outfile <- file.path(temp_output_files_dir,outfile_name)

    seasonder_exportLLUVRadialMetrics(cs, outfile)

outfile <- R.utils::gzip(outfile,overwrite = TRUE)
    outfile_name <- basename(outfile)
    
    s3_destination <- paste0("s3://",bucket,"/",s3_path,"/Radial_Metrics/")
    radial_metrics_s3_path <- paste0(s3_destination,outfile_name)
    command <- paste("s3","cp --only-show-errors",outfile,s3_destination)

    x <- system2("aws", command,stdout =  file.path(temp_dir,"sys.log"), stderr = file.path(temp_dir,"sys.log"), wait = TRUE)
    
    
    
    x == 0 || stop(paste0("Error while writing to S3. Reason: ",readLines("/tmp/runtime/sys.log")))
    
    file.remove(outfile)

    output <- 
      list(input_file = s3Key,                  
           CS_object_path = cs_object_s3_path,
           Radial_Metrics_path = radial_metrics_s3_path
      )
    
    
    
    output <- as.character(jsonlite::toJSON(
      output,auto_unbox = T))
    
    list(taskId=taskId,
         resultCode = "Succeeded",
         resultString= output
         
    )
  },
  error=function(e){
    
    list(taskId=taskId,
         resultCode = "PermanentFailure",
         resultString= as.character(jsonlite::toJSON(
           list(input_file=s3Key,
                error=conditionMessage(e)),
           auto_unbox = T))
    )
  })
  
  
  
  
  return(out)
  
  
}

run_tasks <- function(invocationSchemaVersion, invocationId, job, tasks,log=T) {
  
  dir.create(temp_dir,showWarnings = F)
  dir.create(temp_input_files_dir,showWarnings = F)   
  dir.create(temp_output_files_dir,showWarnings = F)   
  #Copy file
  if(log){
    print(invocationSchemaVersion)
    print(invocationId)
    print(job)
    print(tasks)
    print(class(tasks))
  }
  taskIds <- tasks$taskId
  s3Keys <- tasks$s3Key
  s3BucketArns <- tasks$s3BucketArn
  
  
  
  processed_tasks <- lapply(seq_along(taskIds), process_task,taskIds=taskIds,s3Keys=s3Keys,s3BucketArns=s3BucketArns)
  
  
  out <- list(invocationSchemaVersion=invocationSchemaVersion,
              treatMissingKeysAs = "PermanentFailure",
              invocationId=invocationId,
              results=processed_tasks
  )
  
  if(log){
    print(processed_tasks)
    
    print(jsonlite::toJSON(out))
  }
  
  
  return(out)
}

if(Sys.getenv("AWS_LAMBDA_RUNTIME_API")!=""){
  
  lambdr::start_lambda()
  
}