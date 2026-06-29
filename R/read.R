# Short, tidy column names for each IVT dimension (in declaration order).
IVT_DIM_COLS <- c("geography", "age", "household_type", "period_of_construction",
                  "statistic", "housing_indicator", "tenure")

# Identify the Beyond 20/20 container family from the raw bytes. Both families
# share the `04 00 20 00` signature; they differ in how page directories are
# stored. Returns 1 (per-geography directories at a fixed stride, e.g. 98-10-0241),
# 2 (single contiguous directory, e.g. 98-10-0023), or NA when unrecognised.
ivt_family <- function(raw) {
  if (length(raw) < 8L) return(NA_integer_)
  if (!identical(as.integer(raw[1:4]), c(4L, 0L, 32L, 0L))) return(NA_integer_)
  if (length(raw) >= IVT_IDX0 + 16L && ivt_geography_count(raw) > 0L) return(1L)
  # family 2 requires both a page directory and a descriptor the decoder can use;
  # other `04 00 20 00` products expose a directory but an undecoded descriptor.
  if (!is.null(ivt_f2_find_directory(raw)) && ivt_f2_decodable(raw)) return(2L)
  NA_integer_
}

# A file is supported when it belongs to a recognised container family.
ivt_is_supported <- function(raw) !is.na(ivt_family(raw))

#' Read a Beyond 20/20 IVT file
#'
#' Parses a Statistics Canada Beyond 20/20 `.ivt` table straight from its bytes:
#' both the data cells and the codebook (dimension members, geographic
#' identifiers, footnotes). No companion CSV or metadata download is required.
#'
#' @param path Path to an `.ivt` file.
#' @param geo_attributes For family-2 tables only: if `TRUE`, decode the full
#'   geography attribute table (names, level/type, geocodes, data-quality flag,
#'   non-response rate) from the codebook so [ivt_tidy()] can label geographies by
#'   name. This adds a codebook block-scan (tens of seconds); the default `FALSE`
#'   keeps geographies keyed by DGUID. Ignored for family-1 tables.
#' @return An object of class `ivt`: a list with `cells` (a tibble of one value
#'   per row, keyed by 1-based member-id columns matching the StatCan metadata
#'   Member IDs), and `metadata` (table identity, `dimensions`, `geographies`
#'   with names and DGUIDs, and `footnotes`).
#' @export
read_ivt <- function(path, geo_attributes = FALSE) {
  raw <- readBin(path, "raw", n = file.info(path)$size)
  family <- ivt_family(raw)
  if (is.na(family)) {
    cli::cli_abort(c(
      "Unsupported or unrecognised IVT format in {.path {path}}.",
      i = "This package decodes the two 2021-era Beyond 20/20 container families."
    ))
  }
  if (family == 2L) return(ivt_f2_read(raw, path, geo_attributes = geo_attributes))
  meta <- ivt_read_codebook(raw)
  ng <- ivt_geography_count(raw)
  parts <- lapply(0:(ng - 1L), function(g) ivt_decode_geography(raw, g))
  cells <- do.call(rbind, parts)
  structure(list(cells = cells, metadata = meta, path = path, family = 1L),
            class = "ivt")
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
  family <- ivt_family(raw)
  if (is.na(family)) {
    cli::cli_abort("Unsupported or unrecognised IVT format in {.path {path}}.")
  }
  if (family == 2L) return(ivt_f2_metadata(raw))
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
  if (isTRUE(x$family == 2L)) return(ivt_f2_tidy(x, trim_labels))

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
  if (isTRUE(x$family == 2L)) {
    cli::cli_text("{nrow(x$cells)} cells | {m$n_geographies} geographies | {length(m$dimension_names)} dimensions | {length(m$footnotes)} footnotes")
    geo_msg <- if (!is.null(m$geographies[["geo_name"]]))
      "family 2 (geography labelled by name + uid)"
    else if (!is.null(m$geographies[["geo_uid"]]))
      "family 2 (geography labelled by DGUID; read_ivt(geo_attributes=TRUE) for names)"
    else
      "family 2 (geography keyed by member id; read_ivt(geo_attributes=TRUE) for names)"
    cli::cli_text(cli::col_grey(geo_msg))
  } else {
    cli::cli_text("{nrow(x$cells)} cells | {length(m$geographies$name)} geographies | {length(m$dimensions)} dimensions | {length(m$footnotes)} footnotes")
  }
  invisible(x)
}
