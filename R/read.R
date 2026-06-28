# Short, tidy column names for each IVT dimension (in declaration order).
IVT_DIM_COLS <- c("geography", "age", "household_type", "period_of_construction",
                  "statistic", "housing_indicator", "tenure")

# The 2021 Beyond 20/20 layout this package decodes begins with this signature
# and exposes a valid geography index. Other variants (e.g. the 1991 census
# format) are not yet supported.
ivt_is_supported <- function(raw) {
  if (length(raw) < IVT_IDX0 + 16L) return(FALSE)
  sig <- as.integer(raw[1:4]) # 04 00 20 00
  identical(sig, c(4L, 0L, 32L, 0L)) && ivt_geography_count(raw) > 0L
}

#' Read a Beyond 20/20 IVT file
#'
#' Parses a Statistics Canada Beyond 20/20 `.ivt` table straight from its bytes:
#' both the data cells and the codebook (dimension members, geographic
#' identifiers, footnotes). No companion CSV or metadata download is required.
#'
#' @param path Path to an `.ivt` file.
#' @return An object of class `ivt`: a list with `cells` (a tibble of one value
#'   per row, keyed by 1-based member-id columns matching the StatCan metadata
#'   Member IDs), and `metadata` (table identity, `dimensions`, `geographies`
#'   with names and DGUIDs, and `footnotes`).
#' @export
read_ivt <- function(path) {
  raw <- readBin(path, "raw", n = file.info(path)$size)
  if (!ivt_is_supported(raw)) {
    cli::cli_abort(c(
      "Unsupported or unrecognised IVT format in {.path {path}}.",
      i = "This package currently decodes the 2021-era Beyond 20/20 layout."
    ))
  }
  meta <- ivt_read_codebook(raw)
  ng <- ivt_geography_count(raw)
  parts <- lapply(0:(ng - 1L), function(g) ivt_decode_geography(raw, g))
  cells <- do.call(rbind, parts)
  structure(list(cells = cells, metadata = meta, path = path), class = "ivt")
}

#' Read only the metadata of an IVT file (no value decoding)
#'
#' Much faster than [read_ivt()] when you only need the codebook: table
#' identity, dimension members, geographic identifiers (names + DGUIDs) and
#' footnotes.
#'
#' @param path Path to an `.ivt` file.
#' @return A list of metadata (see [read_ivt()]).
#' @export
ivt_metadata <- function(path) {
  raw <- readBin(path, "raw", n = file.info(path)$size)
  if (!ivt_is_supported(raw)) {
    cli::cli_abort("Unsupported or unrecognised IVT format in {.path {path}}.")
  }
  ivt_read_codebook(raw)
}

#' Tidy an `ivt` object into a labelled data frame
#'
#' Joins the decoded cells to the codebook so each dimension column holds its
#' member label (and geography gains a `dguid` column), producing a long table
#' analogous to the StatCan CSV download.
#'
#' @param x An `ivt` object from [read_ivt()].
#' @param labels If `TRUE` (default) replace member-id columns with member
#'   labels; if `FALSE` return the compact integer-id table unchanged.
#' @param trim_labels If `TRUE` (default) strip the hierarchy-indentation spaces
#'   from member labels.
#' @return A tibble.
#' @export
ivt_tidy <- function(x, labels = TRUE, trim_labels = TRUE) {
  stopifnot(inherits(x, "ivt"))
  cells <- x$cells
  if (!labels) return(cells)

  meta <- x$metadata
  fix <- if (trim_labels) trimws else identity
  geo_name <- fix(meta$geographies$name)
  dguid <- meta$geographies$dguid
  out <- tibble::tibble(
    geography = geo_name[cells$geo],
    dguid = if (length(dguid)) dguid[cells$geo] else NA_character_
  )
  # dimension id columns in cells, in declaration order after geography
  idcols <- c("age", "hh", "period", "stat", "hi", "tenure")
  for (i in seq_along(idcols)) {
    dim_members <- fix(meta$dimensions[[i + 1L]]$members)
    out[[IVT_DIM_COLS[i + 1L]]] <- dim_members[cells[[idcols[i]]]]
  }
  out$value <- cells$value
  out
}

#' @export
print.ivt <- function(x, ...) {
  m <- x$metadata
  cli::cli_h1("IVT table {m$product_id}")
  cli::cli_text(m$title_en)
  cli::cli_text("{nrow(x$cells)} cells | {length(m$geographies$name)} geographies | {length(m$dimensions)} dimensions | {length(m$footnotes)} footnotes")
  invisible(x)
}
