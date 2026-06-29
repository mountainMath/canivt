# Package load/attach hooks: bridge the CANIVT_* environment variables (which can
# be set in .Renviron) onto the canivt.* options, and warn once at attach time if
# the persistent data cache has not been configured.

.onLoad <- function(libname, pkgname) {
  # Seed each cache option from its environment variable, but never override an
  # option the user has already set (e.g. in .Rprofile). This lets the caches be
  # configured via options() OR via .Renviron.
  to_set <- list()
  for (opt in names(IVT_CACHE_ENVVARS)) {
    if (is.null(getOption(opt))) {
      val <- Sys.getenv(IVT_CACHE_ENVVARS[[opt]], unset = "")
      if (nzchar(val)) to_set[[opt]] <- val
    }
  }
  if (length(to_set)) options(to_set)
  invisible()
}

.onAttach <- function(libname, pkgname) {
  if (!ivt_cache_is_set("data")) {
    packageStartupMessage(
      "canivt: 'canivt.data_cache' is not set — parsed Parquet data and ",
      "metadata will be written to a temporary directory and lost when the R ",
      "session ends.\n",
      "  Set options(canivt.data_cache = \"/path/to/cache\") in .Rprofile, or ",
      "CANIVT_DATA_CACHE=/path/to/cache in .Renviron, to persist them."
    )
  }
}
