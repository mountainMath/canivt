# Identify the Beyond 20/20 container family from the raw bytes. Both families
# share the `04 00 20 00` signature; they differ in how page directories are
# stored. Returns 1 (per-geography directories at a fixed stride, e.g. 98-10-0241),
# 2 (single contiguous directory, e.g. 98-10-0023), or NA when unrecognised.
ivt_family <- function(raw) {
  if (length(raw) < 8L) return(NA_integer_)
  # Byte 0 is a container-generation tag: `04` is the modern census/custom
  # lineage, `02` the older survey products (Health Statistics 1999, Census of
  # Agriculture 1996, Small Area Business 1996) -- same header field layout and
  # page/value model, a different descriptor bounding (no FACET04) handled in
  # `ivt_f2_descriptor()`. The three trailing signature bytes (`00 20 00`) are
  # shared; `ivt_f2_decodable()` still gates alien files.
  if (!identical(as.integer(raw[2:4]), c(0L, 32L, 0L)) ||
      !as.integer(raw[1L]) %in% c(2L, 4L)) return(NA_integer_)
  # The cell decode is unified (see decode.R); `family` now only selects the
  # metadata path. The two differ in *which dimension straddles* the 2048-bit page
  # boundary: when the data dimensions alone overflow it a data dimension
  # straddles and geography is paged per-geography (the "family 1" metadata:
  # geography names via the inline codebook); when they fit, geography itself
  # straddles (`geo_in_page`, possibly trivially -- ipc can exceed the geography
  # count, e.g. the one-page 98-10-0044) and packs several geographies per page
  # (the "family 2" metadata: DGUIDs + descriptor-driven members).
  # `ivt_f2_decodable()` is the whole gate: a plausible descriptor, a resolvable
  # layout AND the structural page pre-flight (`ivt_page_preflight()`), which
  # rejects same-signature containers whose pages are inconsistent with the
  # layout (the 2001 "F"-series, the 98-400-X2016203 variant). The legacy
  # 0x1000-stride probe is gone from detection -- it granted family 1 to any
  # file with marker-shaped bytes at the 98-10-0241 offsets, bypassing every
  # validation.
  if (ivt_f2_decodable(raw)) {
    lay <- tryCatch(ivt_layout(raw), error = function(e) NULL)
    if (!is.null(lay)) return(if (lay$geo_in_page) 2L else 1L)
  }
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
#' @param geo_attributes For the large chunked family-2 tables only: if `TRUE`,
#'   decode the full geography attribute table (names, level/type, geocodes,
#'   data-quality flag, non-response rate) from the codebook so [ivt_tidy()]
#'   can label geographies by name. This adds a codebook block-scan (tens of
#'   seconds); the default `FALSE` keeps those tables keyed by DGUID. Small
#'   schema'd tables and the pre-DGUID (inline-codebook) tables already carry
#'   their full attribute set on the default metadata path. Ignored for
#'   family-1 tables.
#' @param missing If `TRUE` (default `FALSE`) also decode each page's **cell
#'   status tail** and return, in a `missing` tibble, the coordinates of the
#'   cells the file marks as *not available* rather than zero (same member-id
#'   columns as `cells`, no `value`, plus `symbol` and `status` columns carrying
#'   the reason **in the file's own words** -- the legend it declares in its
#'   header, e.g. `x` / "Suppressed to meet the confidentiality requirements of
#'   the Statistics Act" -- or `NA` where the page carries only the bare absent
#'   mask). The legend itself travels as `attr(x$missing, "legend")`. Off by
#'   default because it costs a second presence read per page and its
#'   completeness is vintage-dependent: pages with no tail at all, pages whose
#'   tail the word index does not account for, and cells carrying a reason code
#'   the file's legend does not name all contribute nothing -- each reported
#'   with a classed warning rather than assumed to hold no missings. See the
#'   "Missing values" section.
#' @section Missing values:
#'   Only non-zero cells are stored, so absence covers **both** genuine zeros
#'   and true missings (`x` suppressed, `...`/`N` not available). The two are
#'   separated by a block each page appends after its dense value run, in one of
#'   two forms selected by the page marker: a 1-bit **absent mask** -- a strict
#'   subset of the absent cells, where masked means a genuine zero and
#'   *unmasked* means missing -- or a self-describing **reason-code array**
#'   carrying the `..` / `x` / `...` distinction itself. `missing = TRUE`
#'   decodes both, at every code width; only the array states a reason, so
#'   mask-derived rows carry `status = NA`.
#'
#'   The reason codes are **numbered by the file, not by the format**: each
#'   table declares its own legend -- symbol plus bilingual wording, in code
#'   order -- and the same symbol sits at different codes in different lineages
#'   (`x` is code 2 in the NDM census tables and code 3 in the 2016
#'   `98-400-X` crosstabs). `status` is read from that declaration, so it names
#'   whatever the file names, including symbols outside the census vocabulary
#'   (`F` too unreliable to be published, `0 s` rounded to zero, `®` not
#'   released yet, `z` frozen series). A code the legend does not name, or a
#'   table that declares no legend, is reported rather than guessed at
#'   (`canivt_status_code_unknown`, `canivt_status_legend`).
#'
#'   Two limits are reported rather than hidden. On float64 pages a mask word of
#'   mostly-ones is NaN-shaped and the writer's x87 quieting overwrites one
#'   status bit per such word **in the source file**; those cells read as zeros
#'   and cannot be recovered (`canivt_status_nan_quieted`). And on a few
#'   2001/2006 vintages the page's word index also addresses a second, undecoded
#'   block past the mask (`canivt_status_extra_block`).
#' @return An object of class `ivt`: a list with `cells` (a tibble of one value
#'   per row, keyed by 1-based member-id columns matching the StatCan metadata
#'   Member IDs), and `metadata` (table identity, `dimensions`, `geographies`,
#'   and `footnotes`). `metadata$geographies` carries, per member and where the
#'   vintage stores them: the bilingual display label (`geo_label`,
#'   `geo_label_fr`) and name (`geo_name`, `geo_name_fr` -- on pre-DGUID tables
#'   the EN/FR halves of the stored bilingual label), `geo_uid` (DGUID, or the
#'   bare GEOUID on pre-DGUID tables), the aggregation level (`geo_level`), the
#'   label hierarchy (`geo_depth`, `geo_parent_id` -- the indentation the display
#'   label carries, turned into a depth and the `member_id` of each member's
#'   nearest shallower ancestor; both absent when the geography axis is flat),
#'   the geography type / municipal status (`geo_type`, `geo_type_abbr`), province
#'   abbreviation and codes (`prov_abbr`, `alt_geo_code`, `pr_code`), the
#'   data-quality flag (`dqf_code`, with `dqf_note` and the table-level
#'   `dqf_legend`), and the total non-response rate (`tnr_short_form`).
#'
#'   Where `dqf_note` is present it is accompanied by a `dqf_note_truncated`
#'   logical flag: StatCan's writer stores each note in a single-byte-length
#'   record, so notes longer than 252 characters are truncated **in the source
#'   file** (2,448 of 63,404 geographies in 98-10-0129, 90 of 6,297 in
#'   98-10-0478). The read is byte-exact -- this is a container limitation, not a
#'   decode gap, and there is no continuation to recover -- but the flag marks the
#'   affected members and a classed `canivt_dqf_note_truncated` warning is raised
#'   so the loss is never silent. (Unlike a heuristic fallback it is *not* upgraded
#'   to an error by `options(canivt.strict = TRUE)`: the bytes are exactly what the
#'   file holds.) The truncation is a container limit of the `.ivt` export only --
#'   StatCan's authoritative metadata (the WDS `getCubeMetadata` `geoAttribute` or
#'   the CSV-download metadata) stores the full untruncated note, so a consumer who
#'   needs the complete text can recover it there.
#'
#'   Each footnote in `metadata$footnotes` carries a `scope` (`"table"`,
#'   `"dimension"` or `"member"`), the owning `dimension` name and, for member
#'   notes, the `member_id`(s) it annotates -- `member_id` for a single member and
#'   `member_refs` for the full set (geography counts as a dimension). This matches
#'   StatCan's own footnote linkage on the modern tables; on the pre-DGUID profiles
#'   the same linkage is recovered from the `(N)` reference markers embedded in the
#'   member labels (a note there can be cited by many members, so `member_refs`
#'   lists them all).
#'
#'   The value store keeps only non-zero cells, so a cell absent from `cells`
#'   is a **zero** -- *within a geography that carries any data*. A geography
#'   with no stored cells at all is either wholly suppressed or wholly empty,
#'   and the cell store cannot distinguish the two: `metadata$geographies$has_data`
#'   flags which geographies carry data, and on the pre-DGUID tables
#'   `metadata$geographies$dqf_code` (the per-geography data-quality flag from
#'   the codebook) corroborates it (e.g. on the 2016 income table
#'   98-400-X2016120 the flag's last digit is `9` exactly for the 888
#'   geographies with no stored cells, which the Beyond 20/20 viewer renders
#'   as suppressed).
#' @examples
#' # A small real table (StatCan 98-10-0044) is bundled for examples/tests.
#' path <- system.file("extdata", "98100044.ivt", package = "canivt")
#' ivt <- read_ivt(path)
#' ivt
#' head(ivt$cells)
#' @export
read_ivt <- function(path, geo_attributes = FALSE, missing = FALSE) {
  raw <- readBin(path, "raw", n = file.info(path)$size)
  # the per-file parse memo (memo.R) is warm for the duration of this read and
  # dropped on exit, so the file's bytes are not retained afterwards.
  on.exit(ivt_memo_clear(), add = TRUE)
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
  cells <- ivt_decode(raw, missing = missing)
  miss <- attr(cells, "missing", exact = TRUE)
  attr(cells, "missing") <- NULL
  meta <- ivt_f2_metadata(raw)
  if (isTRUE(geo_attributes) && family == 2L)
    meta$geographies <- ivt_f2_geographies(raw)
  # Per-geography PRESENCE summary: the value store keeps only non-zero cells,
  # so within a geography that carries any data an absent cell is a true zero
  # -- but a geography with NO stored cells at all is either wholly suppressed
  # or wholly empty, and the cell store cannot tell which (validated on
  # 98-400-X2016120: every viewer-blank/suppressed cell belongs to a
  # zero-stored-cell geography, and published geographies' absent cells all
  # render as 0). `has_data` exposes that distinction; on the pre-DGUID tables
  # the per-geography `dqf_code` flag corroborates it (last digit 9 =
  # suppressed on the 2016 income table).
  n_geo <- length(meta$geographies$member_id)
  if (n_geo > 0L && nrow(cells) > 0L)
    meta$geographies$has_data <- tabulate(cells$geo, nbins = n_geo) > 0L
  out <- list(cells = cells, metadata = meta, path = path, family = family)
  if (isTRUE(missing)) out$missing <- miss
  structure(out, class = "ivt")
}

#' Read only the metadata of an IVT file (no value decoding)
#'
#' Much faster than [read_ivt()] when you only need the codebook: table
#' identity, dimension members, geographic identifiers (names + DGUIDs) and
#' footnotes.
#'
#' @param path Path to an `.ivt` file.
#' @return A list of metadata (see [read_ivt()]).
#' @examples
#' path <- system.file("extdata", "98100044.ivt", package = "canivt")
#' meta <- ivt_metadata(path)
#' meta$dimensions
#' @export
ivt_metadata <- function(path) {
  raw <- readBin(path, "raw", n = file.info(path)$size)
  on.exit(ivt_memo_clear(), add = TRUE)
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
#'   labels; if `FALSE` return the compact integer-id table (member ids).
#' @param trim_labels If `TRUE` (default) strip the hierarchy-indentation spaces
#'   from member labels.
#' @param dim_names How to name the data-dimension columns: `"slug"` (default)
#'   uses the terse structural slug (e.g. `age`), which is compact and
#'   language-neutral; `"label"` uses the full dimension name (e.g.
#'   `Age of primary household maintainer`, or its French equivalent when
#'   `language = "fr"`). Slug output can be labelled afterwards with
#'   [label_ivt_columns()]. The choice applies to both `labels` values.
#' @param language Output language for labels and label-derived column names:
#'   `"en"` (default) or `"fr"`. Also accepts `"eng"`/`"fra"` and any case (it is
#'   lower-cased). French falls back to English wherever the file carries no
#'   French copy (e.g. the language-neutral `geo_uid`, or a dimension with no
#'   French name).
#' @param depth If `TRUE` (default `FALSE`) add a `<col>_depth` integer column
#'   after each data-dimension column giving that member's hierarchy depth (read
#'   from the label indentation, the same measure carried by [ivt_members()]).
#'   Opt-in, so the default output -- and hence the Parquet written by
#'   [ivt_write_parquet()] -- is unchanged.
#' @return A tibble.
#' @examples
#' path <- system.file("extdata", "98100044.ivt", package = "canivt")
#' ivt <- read_ivt(path)
#' ivt_tidy(ivt)
#' ivt_tidy(ivt, dim_names = "label")
#' @export
ivt_tidy <- function(x, labels = TRUE, trim_labels = TRUE,
                     dim_names = c("slug", "label"), language = "en",
                     depth = FALSE) {
  stopifnot(inherits(x, "ivt"))
  dim_names <- match.arg(dim_names)
  language <- ivt_norm_lang(language)
  if (!labels) {
    cells <- x$cells
    datacols <- setdiff(names(cells), c("geo", "value"))
    out_names <- ivt_data_colnames(datacols, x$metadata, dim_names, language)
    names(cells)[match(datacols, names(cells))] <- out_names
    if (depth) cells <- ivt_tidy_add_depth(cells, out_names, x$metadata, language)
    return(cells)
  }
  ivt_f2_tidy(x, trim_labels, dim_names, language, depth)
}

# On the compact id path (`labels = FALSE`) there is no member label in the
# output to read indentation from, so recompute depth from each dimension's
# member list and insert a `<col>_depth` column immediately after its column,
# matching the labelled path. `data_cols`/`out_names` are aligned to the
# non-geography dimensions in declaration order.
ivt_tidy_add_depth <- function(cells, out_names, meta, language) {
  data_dims <- Filter(function(d) !d$is_geography, meta$dimensions)
  id_cols <- setdiff(names(cells), c("geo", "value"))
  for (j in seq_along(id_cols)) {
    d <- if (j <= length(data_dims)) data_dims[[j]] else NULL
    if (is.null(d)) next
    labs <- if (language == "fr" && !is.null(d$members_fr) &&
                length(d$members_fr) == length(d$members)) d$members_fr
            else d$members
    if (is.null(labs)) next
    dcol <- paste0(out_names[j], "_depth")
    cells[[dcol]] <- ivt_label_depth(labs)[cells[[id_cols[j]]]]
    # move the depth column to sit right after its dimension column
    ord <- names(cells)
    ord <- ord[ord != dcol]
    at <- match(out_names[j], ord)
    cells <- cells[, append(ord, dcol, after = at)]
  }
  cells
}

#' @export
print.ivt <- function(x, ...) {
  m <- x$metadata
  cli::cli_h1("IVT table {m$product_id}")
  cli::cli_text(m$title_en)
  cli::cli_text("{nrow(x$cells)} cells | {m$n_geographies} geographies | {length(m$dimensions)} dimensions | {length(m$footnotes)} footnotes")
  geo_msg <- if (length(m$geographies$member_id) == 0L)
      "no geography dimension (all dimensions are ordinary data dimensions)"
    else if (!is.null(m$geographies[["geo_name"]]))
      "geography labelled by name + uid"
    else if (!is.null(m$geographies[["geo_uid"]]))
      "geography labelled by uid (read_ivt(geo_attributes=TRUE) for names)"
    else
      "geography keyed by member id (read_ivt(geo_attributes=TRUE) for names)"
  cli::cli_text(cli::col_grey(geo_msg))
  invisible(x)
}
