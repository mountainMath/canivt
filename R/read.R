# Identify the Beyond 20/20 container family from the raw bytes. Both families
# share the `04 00 20 00` signature; they differ in how page directories are
# stored. Returns 1 (per-geography directories at a fixed stride, e.g. 98-10-0241),
# 2 (single contiguous directory, e.g. 98-10-0023), or NA when unrecognised.
ivt_family <- function(raw) {
  if (length(raw) < 8L) return(NA_integer_)
  if (!identical(as.integer(raw[1:4]), c(4L, 0L, 32L, 0L))) return(NA_integer_)
  # The cell decode is unified (see decode.R); `family` now only selects the
  # metadata path. The two differ in *which dimension straddles* the 2048-bit page
  # boundary: when the data dimensions alone overflow it a data dimension
  # straddles and geography is paged per-geography (the "family 1" metadata:
  # geography names via the inline codebook); when they fit, geography itself
  # straddles and packs several geographies per page (the "family 2" metadata:
  # DGUIDs + descriptor-driven members). `geo_in_page` (straddle == geography)
  # discriminates cleanly and, unlike the legacy 0x1000-stride probe, also handles
  # small tables (e.g. 98-10-0662) whose per-geography directory stride is not 0x1000.
  if (ivt_f2_decodable(raw)) {
    lay <- tryCatch(ivt_layout(raw), error = function(e) NULL)
    if (!is.null(lay) && !lay$geo_in_page && ivt_idx0(raw) != IVT_IDX0_DEFAULT)
      return(1L)
  }
  if (length(raw) >= IVT_IDX0_DEFAULT + 16L && ivt_geography_count(raw) > 0L) return(1L)
  # family 2 requires both a page directory and a descriptor the decoder can use;
  # other `04 00 20 00` products expose a directory but an undecoded descriptor.
  # The probe runs quietly: a fallback engaging during detection of a file that
  # is then rejected anyway is noise, not a read.
  if (!is.null(ivt_quietly(ivt_f2_find_directory(raw))) && ivt_f2_decodable(raw))
    return(2L)
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
#' Every primary read is positional (header pointers, block directories, framed
#' value entries). When one does not resolve and a content-heuristic fallback
#' supplies values instead -- or when directory entries point at page variants
#' that cannot be decoded -- a classed warning (`canivt_fallback` /
#' `canivt_skipped_pages`) is raised naming the affected read. Set
#' `options(canivt.strict = TRUE)` to turn these into errors: on a file layout
#' this package has not been validated against, the fallback paths are the ones
#' most likely to misread silently.
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
  # One decode path and one metadata path for every family (the "family" now only
  # tags provenance / the geography attribute option). The full geography attribute
  # table is only available for the large family-2 tables whose names are not in the
  # cheap single-block codebook; the family-1 tables already carry names by default.
  cells <- ivt_decode(raw)
  meta <- ivt_f2_metadata(raw)
  if (isTRUE(geo_attributes) && family == 2L)
    meta$geographies <- ivt_f2_geographies(raw)
  structure(list(cells = cells, metadata = meta, path = path, family = family),
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
  ivt_f2_metadata(raw)
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
  if (!labels) return(x$cells)
  ivt_f2_tidy(x, trim_labels)
}

#' @export
print.ivt <- function(x, ...) {
  m <- x$metadata
  cli::cli_h1("IVT table {m$product_id}")
  cli::cli_text(m$title_en)
  cli::cli_text("{nrow(x$cells)} cells | {m$n_geographies} geographies | {length(m$dimensions)} dimensions | {length(m$footnotes)} footnotes")
  geo_msg <- if (!is.null(m$geographies[["geo_name"]]))
      "geography labelled by name + uid"
    else if (!is.null(m$geographies[["geo_uid"]]))
      "geography labelled by uid (read_ivt(geo_attributes=TRUE) for names)"
    else
      "geography keyed by member id (read_ivt(geo_attributes=TRUE) for names)"
  cli::cli_text(cli::col_grey(geo_msg))
  invisible(x)
}
