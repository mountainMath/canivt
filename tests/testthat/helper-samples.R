# Locate a sample .ivt for the integration tests. Resolution order: an explicit
# environment variable, then the package's own IVT cache (option
# `canivt.ivt_cache`, where downloads and the test corpus are kept, laid out as
# `<cache>/<id>/<file>`), then the tiny sample shipped in `inst/extdata`, then an
# optional legacy path. Returns "" when none is found, so the calling test skips.
# Most .ivt files are large and not shipped; the one bundled sample
# (98100044.ivt) lets the tests keyed on it run everywhere, including on CRAN.
locate_sample_ivt <- function(envvar, id, file = paste0(id, ".ivt"),
                              legacy = NULL) {
  if (nzchar(envvar)) {
    p <- Sys.getenv(envvar, "")
    if (nzchar(p) && file.exists(p)) return(p)
  }
  cached <- file.path(ivt_cache_dir("ivt", create = FALSE), id, file)
  if (file.exists(cached)) return(cached)
  bundled <- system.file("extdata", file, package = "canivt")
  if (nzchar(bundled) && file.exists(bundled)) return(bundled)
  if (!is.null(legacy) && file.exists(legacy)) return(legacy)
  ""
}
