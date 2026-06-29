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

# Full dimension names from the header "Variable List" (modern format only; the
# legacy format has none). Dimension names can themselves contain commas (e.g.
# "Age (in single years), average age and median age (128)"), but each ends in a
# "(<count>)" hint, so split only after those hints. Returns the full names
# (incl. a leading "Geography") or NULL when there is no inline Variable List.
ivt_f2_variable_list_names <- function(raw) {
  head <- ivt_header_text(raw)
  m <- regmatches(head, regexec("Variable List:?\\s*([^\r\n]+)", head))[[1]]
  if (length(m) < 2L) return(NULL)
  marked <- gsub("(\\([0-9]+\\))\\s*,\\s*", "\\1@@DIM@@", m[2])
  parts <- trimws(strsplit(marked, "@@DIM@@", fixed = TRUE)[[1]])
  parts <- parts[nzchar(parts)]
  c("Geography", sub("\\s*\\([0-9]+\\)\\s*$", "", parts))
}

# Uniform dimension model, driven by the header descriptor (present in BOTH
# formats). Every dimension is described the same way: `name`, `count`, `type`
# (0x10 geography, 0x07 age-type, 0x02 gender/sex-type), `is_geography`, and, for
# the non-geography data dimensions, the decoded member `members` (labels). The
# member labels are attached by matching the descriptor's member count to the
# label blocks (`ivt_f2_dim_member_labels()`), so Age/Gender (2021) and Age/Sex
# (1991) are handled identically. Full dimension names come from the Variable List
# when present, otherwise the descriptor's (truncated) display name.
ivt_f2_dimensions <- function(raw) {
  d <- ivt_f2_descriptor(raw)
  if (is.null(d) || !length(d$dims)) return(list())
  labels <- ivt_f2_dim_member_labels(raw)
  vl <- ivt_f2_variable_list_names(raw)
  lapply(seq_along(d$dims), function(i) {
    dim <- d$dims[[i]]
    is_geo <- dim$type == 0x10L
    name <- if (!is.null(vl) && i <= length(vl)) vl[i] else dim$name
    list(name = name, count = dim$count, type = dim$type, is_geography = is_geo,
         members = if (is_geo) NULL else labels[[as.character(dim$count)]])
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

ivt_f2_metadata <- function(raw, dir = NULL) {
  if (is.null(dir)) dir <- ivt_f2_find_directory(raw)
  inline <- ivt_f2_geo_is_inline(raw)
  info <- if (inline) ivt_f2_legacy_identity(raw) else ivt_table_info(raw)
  dims <- ivt_f2_dimensions(raw)
  n_geo <- ivt_f2_geo_count(raw)
  if (inline) {
    # legacy: no fast geography uid (no DGUID pattern); key by member id only.
    # read_ivt(geo_attributes = TRUE) attaches names/GEOUIDs via ivt_f2_geographies().
    geographies <- list(member_id = seq_len(if (is.na(n_geo)) 0L else n_geo))
  } else {
    dguids <- ivt_f2_geo_dguids(raw)
    ivt_f2_check_geo_count(raw, length(dguids))
    geographies <- list(geo_uid = dguids, member_id = seq_along(dguids))
  }
  list(
    product_id        = info$product_id,
    title_en          = info$title_en,
    title_fr          = info$title_fr,
    universe          = info$universe,
    dimensions        = dims,                                  # uniform per-dim model
    dimension_names   = vapply(dims, `[[`, "", "name"),
    dimension_counts  = vapply(dims, `[[`, NA_integer_, "count"),
    geographies       = geographies,
    n_geographies     = if (!is.na(n_geo)) n_geo else ivt_f2_geography_count(raw, dir),
    footnotes         = if (inline) ivt_f2_legacy_footnotes(raw)
                        else ivt_footnotes(raw, max(0L, length(raw) - 200000L))
  )
}

# Label a family-2 cell table: geography by DGUID, each data dimension by its
# member name. Cells are keyed by 1-based member ids (`geo`, plus one column per
# data dimension), so labels join by direct indexing.
ivt_f2_tidy <- function(x, trim_labels = TRUE) {
  cells <- x$cells
  meta <- x$metadata
  fix <- if (trim_labels) trimws else identity
  geo <- meta$geographies
  # geography columns, included only when decoded: `geo_name` + `geo_level` come
  # from the full attribute table (read_ivt(geo_attributes = TRUE)), `geo_uid` from
  # the light path (DGUID; legacy files have none until geo_attributes = TRUE). If
  # nothing is available, fall back to the bare member id.
  out <- tibble::tibble(.rows = nrow(cells))
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

ivt_f2_read <- function(raw, path = NULL, geo_attributes = FALSE) {
  dir <- ivt_f2_find_directory(raw)
  if (is.null(dir)) cli::cli_abort("No family-2 page directory found in IVT file.")
  cells <- ivt_f2_decode(raw, dir)
  meta <- ivt_f2_metadata(raw, dir)
  if (isTRUE(geo_attributes)) meta$geographies <- ivt_f2_geographies(raw)
  structure(list(cells = cells, metadata = meta, path = path, family = 2L),
            class = "ivt")
}
