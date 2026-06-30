#' Write an IVT table to Parquet
#'
#' @param x An `ivt` object from [read_ivt()].
#' @param path Output `.parquet` path. Defaults to `<product_id>.parquet` in the
#'   data cache ([ivt_cache_dir("data")][ivt_cache_dir], i.e. option
#'   `canivt.data_cache` or [tempdir()] when unset).
#' @param labels Passed to [ivt_tidy()]: write labelled columns (`TRUE`,
#'   default) or the compact integer-id table (`FALSE`).
#' @param ... Passed to [arrow::write_parquet()].
#' @return `path`, invisibly.
#' @export
ivt_write_parquet <- function(x, path = NULL, labels = TRUE, ...) {
  if (!requireNamespace("arrow", quietly = TRUE)) {
    cli::cli_abort("Package {.pkg arrow} is required to write Parquet.")
  }
  if (is.null(path)) path <- ivt_data_cache_file(x, ".parquet")
  arrow::write_parquet(ivt_tidy(x, labels = labels), path, ...)
  invisible(path)
}

#' Write an IVT table to CSV
#'
#' @inheritParams ivt_write_parquet
#' @param path Output `.csv` path. Defaults to `<product_id>.csv` in the data
#'   cache ([ivt_cache_dir("data")][ivt_cache_dir]).
#' @param ... Passed to the CSV writer ([readr::write_csv()] if available, else
#'   [utils::write.csv()]).
#' @return `path`, invisibly.
#' @export
ivt_write_csv <- function(x, path = NULL, labels = TRUE, ...) {
  if (is.null(path)) path <- ivt_data_cache_file(x, ".csv")
  df <- ivt_tidy(x, labels = labels)
  if (requireNamespace("readr", quietly = TRUE)) {
    readr::write_csv(df, path, ...)
  } else {
    utils::write.csv(df, path, row.names = FALSE, ...)
  }
  invisible(path)
}

#' Write the table metadata (codebook + footnotes) to disk
#'
#' Emits the parts of an IVT that are not the data table itself: the dimension
#' members, the geographic identifiers (names + DGUIDs) and the footnotes, as a
#' set of CSV files in `dir`.
#'
#' @param x An `ivt` object or a metadata list from [ivt_metadata()].
#' @param dir Output directory (created if needed). Defaults to
#'   `<product_id>_metadata` in the data cache
#'   ([ivt_cache_dir("data")][ivt_cache_dir]).
#' @return The output directory, invisibly.
#' @export
ivt_write_metadata <- function(x, dir = NULL) {
  meta <- if (inherits(x, "ivt")) x$metadata else x
  if (is.null(dir)) dir <- ivt_data_cache_file(meta, "_metadata")
  dir.create(dir, showWarnings = FALSE, recursive = TRUE)

  wr <- function(df, name) utils::write.csv(df, file.path(dir, name),
                                            row.names = FALSE)

  members <- do.call(rbind, lapply(meta$dimensions, function(d) {
    if (!length(d$members)) return(NULL)
    data.frame(dimension = d$name, member_id = seq_along(d$members),
               label = trimws(d$members),
               depth = ivt_label_depth(d$members))
  }))
  wr(members, "dimension_members.csv")

  geos <- meta$geographies
  geo_df <- data.frame(member_id = geos$member_id)
  if (!is.null(geos$geo_name)) geo_df$name <- geos$geo_name
  if (!is.null(geos$geo_uid))  geo_df$uid  <- geos$geo_uid
  wr(geo_df, "geographies.csv")

  if (length(meta$footnotes)) {
    fn <- do.call(rbind, lapply(meta$footnotes, function(f)
      data.frame(language = f$language, number = f$number, text = f$text)))
    wr(fn, "footnotes.csv")
  }

  wr(data.frame(field = c("product_id", "title_en", "title_fr", "universe"),
                value = c(meta$product_id, meta$title_en, meta$title_fr,
                          meta$universe)),
     "table_info.csv")
  invisible(dir)
}

# Default output path in the data cache for an ivt object (or metadata list),
# named by its StatCan product id. `suffix` is the extension (".parquet"/".csv")
# or a directory suffix ("_metadata"). Falls back to "table" when no product id.
ivt_data_cache_file <- function(x, suffix) {
  meta <- if (inherits(x, "ivt")) x$metadata else x
  pid <- meta$product_id
  if (is.null(pid) || is.na(pid) || !nzchar(pid)) pid <- "table"
  file.path(ivt_cache_dir("data"), paste0(pid, suffix))
}

# Hierarchy depth implied by the leading-space indentation of a member label.
ivt_label_depth <- function(labels) {
  lead <- nchar(labels) - nchar(sub("^ +", "", labels))
  as.integer(lead %/% 2L)
}
