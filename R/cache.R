#' canivt cache directories
#'
#' canivt uses two optional cache locations, each controlled by an R option (or
#' the matching environment variable, which is read into the option when the
#' package loads so it can be set in `.Renviron`):
#'
#' - **`ivt`** — raw downloaded `.ivt` files, option `canivt.ivt_cache` (env var
#'   `CANIVT_IVT_CACHE`). When unset, downloads go to a per-session [tempdir()]
#'   folder and are discarded at the end of the session.
#' - **`data`** — parsed Parquet data and metadata that should persist across
#'   sessions, option `canivt.data_cache` (env var `CANIVT_DATA_CACHE`). When
#'   unset, parsed output goes to [tempdir()] (and is lost when the session ends;
#'   a one-time startup message points this out).
#'
#' Set them either as options (e.g. in `.Rprofile`):
#' `options(canivt.data_cache = "~/canivt-cache")`, or as environment variables
#' (e.g. in `.Renviron`): `CANIVT_DATA_CACHE=~/canivt-cache`.
#'
#' @param which Which cache to resolve: `"ivt"` (raw downloads) or `"data"`
#'   (parsed Parquet + metadata).
#' @param create Create the directory if it does not exist? Default `TRUE`.
#' @return The cache directory path (a `tempdir()` subfolder when the option is
#'   unset).
#' @export
ivt_cache_dir <- function(which = c("ivt", "data"), create = TRUE) {
  which <- match.arg(which)
  opt <- getOption(IVT_CACHE_OPTIONS[[which]])
  dir <- if (!is.null(opt) && nzchar(opt)) {
    path.expand(opt)
  } else {
    file.path(tempdir(), paste0("canivt_", which, "_cache"))
  }
  if (isTRUE(create)) dir.create(dir, showWarnings = FALSE, recursive = TRUE)
  normalizePath(dir, winslash = "/", mustWork = FALSE)
}

# Option name for each cache, and the environment variable that seeds it.
IVT_CACHE_OPTIONS <- c(ivt = "canivt.ivt_cache", data = "canivt.data_cache")
IVT_CACHE_ENVVARS <- c(canivt.ivt_cache = "CANIVT_IVT_CACHE",
                       canivt.data_cache = "CANIVT_DATA_CACHE")

# TRUE when a cache is backed by a user-set option (persistent), FALSE when it
# falls back to tempdir().
ivt_cache_is_set <- function(which) {
  opt <- getOption(IVT_CACHE_OPTIONS[[which]])
  !is.null(opt) && nzchar(opt)
}
