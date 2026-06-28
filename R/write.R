#' Write an IVT table to Parquet
#'
#' @param x An `ivt` object from [read_ivt()].
#' @param path Output `.parquet` path.
#' @param labels Passed to [ivt_tidy()]: write labelled columns (`TRUE`,
#'   default) or the compact integer-id table (`FALSE`).
#' @param ... Passed to [arrow::write_parquet()].
#' @return `path`, invisibly.
#' @export
ivt_write_parquet <- function(x, path, labels = TRUE, ...) {
  if (!requireNamespace("arrow", quietly = TRUE)) {
    cli::cli_abort("Package {.pkg arrow} is required to write Parquet.")
  }
  arrow::write_parquet(ivt_tidy(x, labels = labels), path, ...)
  invisible(path)
}

#' Write an IVT table to CSV
#'
#' @inheritParams ivt_write_parquet
#' @param path Output `.csv` path.
#' @param ... Passed to the CSV writer ([readr::write_csv()] if available, else
#'   [utils::write.csv()]).
#' @return `path`, invisibly.
#' @export
ivt_write_csv <- function(x, path, labels = TRUE, ...) {
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
#' @param dir Output directory (created if needed).
#' @return The output directory, invisibly.
#' @export
ivt_write_metadata <- function(x, dir) {
  meta <- if (inherits(x, "ivt")) x$metadata else x
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

  wr(data.frame(member_id = meta$geographies$member_id,
                name = meta$geographies$name,
                dguid = meta$geographies$dguid),
     "geographies.csv")

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

# Hierarchy depth implied by the leading-space indentation of a member label.
ivt_label_depth <- function(labels) {
  lead <- nchar(labels) - nchar(sub("^ +", "", labels))
  as.integer(lead %/% 2L)
}
