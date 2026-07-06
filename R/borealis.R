borealis_ivt_catalogue <- function(temporal = NULL, refresh=FALSE, quiet = FALSE) {
  if (Sys.getenv("BOREALIS_DATAVERSE_KEY")=="") {
    stop(paste0("A borealis dataverse API key needs to be set as environment variable.","\n",
                "Set it in your .Renviron as\n",
                "BOREALIS_DATAVERSE_KEY = 'xxxx'\n",
                "If you don't have an API or borealis account create one at\n",
                "https://borealisdata.ca/dataverseuser.xhtml?selectTab=apiTokenTab"))
  }
  i = 0
  page_size <- 1000
  borealis_raw <- NULL
  borealis_new <- NULL
  while (i==0 || nrow(borealis_new)==page_size) {
    borealis_new <- dataverse::dataverse_search(c(name="\\.IVT"),
                                                type="file",
                                                key = Sys.getenv("BOREALIS_DATAVERSE_KEY"),
                                                server = "borealisdata.ca",
                                                start = i * page_size,
                                                per_page=page_size,
                                                verbose=FALSE)
    borealis_raw <- bind_rows(borealis_raw,borealis_new)
    i <- i+1
    if (!quiet) {
      message("Catalogue query bactch ",i," completed.")
    }
  }
  
  borealis_raw |>
    as_tibble()
}


download_borealis_ivt <- function(){
  
}
