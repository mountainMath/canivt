#' Read a family-2 Beyond 20/20 IVT file
#'
#' The second container family (single contiguous page directory; e.g. the 2021
#' table 98-10-0023, Age x Gender across Canada down to dissemination areas).
#' This reader decodes every cell exactly (validated cell-for-cell against the
#' StatCan CSV for all 63,404 geographies of 98-10-0023) and attaches the table
#' identity, dimension names, geography DGUIDs and the data-dimension member
#' labels from the codebook (~18 MB from EOF). Geography *names* are not yet
#' decoded for this family, so [ivt_tidy()] labels geography by its DGUID (the
#' canonical StatCan geography key) and labels Age/Gender by their member names.
#'
#' @keywords internal
#' @noRd
NULL

# Parse the header "Variable List" into (name, count) pairs (modern format only;
# the legacy format has none). The Variable List is in DISPLAY order, which need
# not match the descriptor's storage order (in 98-10-0241 they differ), so it is
# matched to descriptor dimensions by count, not position. Names can themselves
# contain commas (e.g. "Age (in single years), average age and median age (128)"),
# but each entry ends in a "(<count>[<flags>])" hint (e.g. "(13)", "(3C)"), so we
# split only after those hints and read the count from each. Returns a data frame
# (name, count) or NULL when there is no inline Variable List.
ivt_f2_vl_pairs <- function(raw) {
  head <- ivt_header_text(raw)
  m <- regmatches(head, regexec("Variable List:?[ \t]*([^\r\n]+)", head))[[1]]
  if (length(m) < 2L) return(NULL)
  marked <- gsub("(\\([0-9]+[A-Za-z]*\\))[ \t]*,[ \t]*", "\\1@@DIM@@", m[2])
  parts <- trimws(strsplit(marked, "@@DIM@@", fixed = TRUE)[[1]])
  parts <- parts[nzchar(parts)]
  if (!length(parts)) return(NULL)
  count <- suppressWarnings(as.integer(
    sub(".*\\(([0-9]+)[A-Za-z]*\\)[ \t]*$", "\\1", parts)))
  name <- trimws(sub("[ \t]*\\([0-9]+[A-Za-z]*\\)[ \t]*$", "", parts))
  data.frame(name = name, count = count, stringsAsFactors = FALSE)
}

# Full display name for a descriptor dimension. Geography is always "Geography";
# every other dimension takes the Variable-List entry whose count uniquely matches
# (the VL is the only source of the untruncated name), falling back to the
# descriptor's own (possibly truncated) display name when there is no inline VL or
# the count match is ambiguous.
ivt_f2_dim_name <- function(dim, is_geo, vl) {
  if (is_geo) return("Geography")
  if (!is.null(vl)) {
    hit <- which(vl$count == dim$count)
    if (length(hit) == 1L) return(vl$name[hit])
  }
  dim$name
}

# Uniform dimension model, driven by the header descriptor (present in BOTH
# formats). Every dimension is described the same way: `name`, `count`, `type`
# (0x07 age-type, 0x02 gender/sex-type; geography is the first dimension,
# identified positionally rather than by type byte), `is_geography`, and, for
# the non-geography data dimensions, the decoded member `members` (labels). The
# member labels are attached by matching the descriptor's member count to the
# label blocks (`ivt_f2_dim_member_labels()`), so 98-10-0241's six data dimensions,
# Age/Gender (2021) and Age/Sex (1991) are handled identically. Full dimension
# names come from the Variable List (by count) when present, otherwise the
# descriptor's (truncated) display name.
ivt_f2_dimensions <- function(raw) {
  d <- ivt_f2_descriptor(raw)
  if (is.null(d) || !length(d$dims)) return(list())
  want <- vapply(d$dims[-1L], `[[`, 1L, "count")
  labels <- ivt_f2_dim_member_labels(raw, want = want)        # count-keyed fallback
  # prefer the name-anchored marker labels so two dimensions of the same member
  # count (e.g. 98-10-0662's 6-member "French used at work" / "English used at
  # work") get their own labels rather than collapsing onto one count key.
  by_name <- ivt_f2_marker_labels(raw)
  name_lut <- stats::setNames(lapply(by_name, `[[`, "labels"),
                              vapply(by_name, `[[`, "", "name"))
  vl <- ivt_f2_vl_pairs(raw)
  lapply(seq_along(d$dims), function(i) {
    dim <- d$dims[[i]]
    is_geo <- i == 1L                       # geography is the first dimension
    members <- if (is_geo) NULL else {
      m <- name_lut[[dim$name]]
      if (is.null(m)) labels[[as.character(dim$count)]] else m
    }
    list(name = ivt_f2_dim_name(dim, is_geo, vl), count = dim$count,
         type = dim$type, is_geography = is_geo, members = members)
  })
}

ivt_f2_dimension_names <- function(raw) {
  dims <- ivt_f2_dimensions(raw)
  if (length(dims)) vapply(dims, `[[`, "", "name") else "Geography"
}

# Table identity for the legacy format, read from the out-of-line title blocks
# that header u32 @48/@40 point at (framing `01 01 <u16 len>` then
# "<product_id>\r\n<title>"). The modern format keeps this inline (ivt_table_info).
ivt_f2_legacy_identity <- function(raw) {
  rd <- function(ptr) {
    off <- rd_u32(raw, ptr)
    if (is.na(off) || off < 1 || off + 4 > length(raw)) return(NA_character_)
    len <- rd_u16(raw, as.integer(off) + 2L)
    if (len < 1L || off + 4L + len > length(raw)) return(NA_character_)
    raw_to_latin1(raw[(as.integer(off) + 5L):(as.integer(off) + 4L + len)])
  }
  split2 <- function(t) {
    if (is.na(t)) return(c(NA_character_, NA_character_))
    p <- strsplit(t, "\r\n", fixed = TRUE)[[1]]
    c(if (length(p) >= 1) trimws(p[1]) else NA_character_,
      if (length(p) >= 2) trimws(p[2]) else NA_character_)
  }
  e <- split2(rd(IVT_HDR_TITLE_EN_PTR)); f <- split2(rd(IVT_HDR_TITLE_FR_PTR))
  list(product_id = e[1], title_en = e[2], title_fr = f[2], universe = NA_character_)
}

# Footnotes for the legacy format. Unlike the modern framed "Footnote N" / "Renvoi
# N" records, the legacy notes block is one text blob (header `01 01 <u16 len>`,
# running to EOF) with sections; the footnotes are "(N) <text>" lines under a
# "Footnotes" section header, ending at the next section header ("Abbreviations").
# Validated against 1003011 (40 footnotes, numbered 1..40).
ivt_f2_legacy_footnotes <- function(raw, tail_bytes = 200000L) {
  start <- max(1L, length(raw) - tail_bytes + 1L)
  lines <- strsplit(raw_to_latin1(raw[start:length(raw)]), "\r\n", fixed = TRUE)[[1]]
  lines <- trimws(lines)
  fh <- which(lines == "Footnotes")
  if (!length(fh)) return(list())
  out <- list()
  for (i in (fh[length(fh)] + 1L):length(lines)) {
    L <- lines[i]
    if (!nzchar(L)) next
    m <- regmatches(L, regexec("^\\(([0-9]+)\\)\\s*(.*)$", L))[[1]]
    if (length(m) != 3L) break             # reached the next section header
    out[[length(out) + 1L]] <- list(language = "en",
                                    number = as.integer(m[2]), text = trimws(m[3]))
  }
  out
}

# Read the full codebook metadata for ANY supported family. The descriptor-driven
# dimension model and the codebook member/footnote scans are format-agnostic; only
# the geography layout differs, and that is keyed off the header (`inline` for the
# pre-DGUID legacy layout) and the geography codebook's shape:
#   - inline (legacy, e.g. 1991): no DGUID array; key by member id only. Names and
#     GEOUIDs come from read_ivt(geo_attributes = TRUE) via ivt_f2_geographies().
#   - single clean codebook (the small family-1 reference tables, e.g. 166
#     geographies in 98-10-0241): names + DGUIDs are one block each (`geo_simple`).
#   - chunked codebook (the large family-2 tables): DGUIDs via the fast scan, names
#     only via read_ivt(geo_attributes = TRUE).
# `geographies` is a uniform list with `member_id`, an optional `geo_name`, and an
# optional `geo_uid` (the DGUID, or the bare GEOUID for pre-DGUID tables).
ivt_f2_metadata <- function(raw, dir = NULL) {
  # `inline` (the out-of-line title pointers) tags the legacy *export* format, which
  # only governs identity/footnote storage; geography is resolved uniformly below
  # (`ivt_f2_geo_light()`), since the pre-DGUID inline geography codebook also occurs
  # in modern-export files (e.g. the 2006/2011 census tables).
  inline <- ivt_f2_geo_is_inline(raw)
  info <- if (inline) ivt_f2_legacy_identity(raw) else ivt_table_info(raw)
  dims <- ivt_f2_dimensions(raw)
  n_geo <- ivt_f2_geo_count(raw)
  g <- ivt_f2_geo_light(raw, n_geo)
  ivt_f2_check_geo_count(raw, length(g$geo_uid))
  geographies <- list(geo_name = g$geo_name, geo_uid = g$geo_uid,
                      member_id = seq_along(g$geo_uid))
  list(
    product_id        = info$product_id,
    title_en          = info$title_en,
    title_fr          = info$title_fr,
    universe          = info$universe,
    dimensions        = dims,                                  # uniform per-dim model
    dimension_names   = vapply(dims, `[[`, "", "name"),
    dimension_counts  = vapply(dims, `[[`, NA_integer_, "count"),
    geographies       = geographies,
    n_geographies     = if (!is.na(n_geo)) n_geo else {
                          if (is.null(dir)) dir <- ivt_f2_find_directory(raw)
                          ivt_f2_geography_count(raw, dir)
                        },
    footnotes         = if (inline) ivt_f2_legacy_footnotes(raw)
                        else ivt_footnotes(raw, max(0L, length(raw) - 200000L))
  )
}

# Label a decoded cell table (any family): geography by name and/or uid, each data
# dimension by its member name. Cells are keyed by 1-based member ids (`geo`, plus
# one column per data dimension), so labels join by direct indexing.
ivt_f2_tidy <- function(x, trim_labels = TRUE) {
  cells <- x$cells
  meta <- x$metadata
  fix <- if (trim_labels) trimws else identity
  geo <- meta$geographies
  # geography columns, included only when decoded: `geo_label` (display Member
  # Name), `geo_name` (schema GEO_NAME) + `geo_level` come from the full attribute
  # table (read_ivt(geo_attributes = TRUE)), `geo_uid` from the light path (DGUID;
  # legacy files have none until geo_attributes = TRUE). If nothing is available,
  # fall back to the bare member id.
  out <- tibble::tibble(.rows = nrow(cells))
  if (!is.null(geo[["geo_label"]])) out$geo_label <- fix(geo[["geo_label"]])[cells$geo]
  if (!is.null(geo[["geo_name"]]))  out$geo_name  <- fix(geo[["geo_name"]])[cells$geo]
  if (!is.null(geo[["geo_uid"]]))   out$geo_uid   <- geo[["geo_uid"]][cells$geo]
  if (!is.null(geo[["geo_level"]])) out$geo_level <- fix(geo[["geo_level"]])[cells$geo]
  if (ncol(out) == 0L) out$geo <- cells$geo
  # the non-geography data columns of `cells` line up with the non-geography
  # dimensions in declaration order; label each from its dimension's member list.
  datacols <- setdiff(names(cells), c("geo", "value"))
  data_dims <- Filter(function(d) !d$is_geography, meta$dimensions)
  for (j in seq_along(datacols)) {
    col <- datacols[j]
    labs <- if (j <= length(data_dims)) data_dims[[j]]$members else NULL
    out[[col]] <- if (!is.null(labs)) fix(labs)[cells[[col]]] else cells[[col]]
  }
  out$value <- cells$value
  out
}
