#' Family-2 codebook: geography DGUIDs and data-dimension member labels
#'
#' The family-2 codebook (e.g. table 98-10-0023) lives in the last ~18 MB of the
#' file. Geography attributes (name, DGUID, level, classification code, ...) are
#' stored in member-ordered chunks of 256, with a full English copy followed by a
#' French copy, grouped by member range. The two data dimensions (Age, Gender)
#' sit at the very end as clean single blocks (EN and FR), each followed by a
#' "1..n" member-ordinal block.
#'
#' We extract three things here:
#' - the geography **DGUID** array, in 1-based member-id order (a fast vectorised
#'   scan; the canonical StatCan geography key);
#' - the **member labels** for each data dimension (Age, Gender);
#' - the full **geography attribute table** (name, level, type, geocodes, the
#'   data-quality flag and non-response rate) via `ivt_f2_geo_attributes()`, by
#'   parsing the attribute-major group structure of the codebook.
#'
#' All are validated cell-for-cell against the StatCan metadata for 98-10-0023:
#' every attribute (DGUID, name, level, type + type abbreviation, geocodes, quality
#' flag + note, non-response rate) and the Age/Gender labels are exact for all
#' 63,404 geographies. `dqf_note` (DQF_NOTE) is recovered via its 1:1 relationship
#' with DQF_CODE (`ivt_f2_derive_text()`) because its long concatenated text spans
#' multiple codebook blocks.
#'
#' @keywords internal
#' @noRd
NULL

# Member-ordered geography DGUIDs, extracted by a fast vectorised scan for the
# Pascal-prefixed "2021..." strings. DGUIDs are globally unique and laid down in
# member order (the EN copy first, then an identical FR copy, plus per-chunk
# repeats), so first-appearance de-duplication yields the geographies in 1-based
# member-id order. Returns a character vector (length = number of geographies).
ivt_f2_geo_dguids <- function(raw) {
  v <- as.integer(raw)
  n <- length(v)
  if (n < 5L) return(character(0))
  # positions where the bytes spell "2021"
  hit <- which(v[1:(n - 4L)] == 0x32L & v[2:(n - 3L)] == 0x30L &
               v[3:(n - 2L)] == 0x32L & v[4:(n - 1L)] == 0x31L)
  if (!length(hit)) return(character(0))
  len <- v[hit - 1L]            # Pascal length byte
  c5  <- v[hit + 4L]            # 5th character (a level letter, e.g. A/S)
  ok <- !is.na(len) & len >= 9L & len <= 20L &
        !is.na(c5) & c5 >= 65L & c5 <= 90L & (hit - 1L) >= 1L
  hit <- hit[ok]; len <- len[ok]
  out <- character(length(hit)); k <- 0L
  seen <- new.env(hash = TRUE, parent = emptyenv(), size = 80000L)
  for (idx in seq_along(hit)) {
    i <- hit[idx]; L <- len[idx]
    if (i - 1L + L > n) next
    s <- intToUtf8(v[i:(i - 1L + L)])
    if (!is.null(seen[[s]])) next                 # already seen this DGUID
    if (!grepl("^2021[A-Z][0-9A-Z]+$", s)) next   # reject stray "2021 ..." prose
    seen[[s]] <- TRUE
    k <- k + 1L; out[k] <- s
  }
  out[seq_len(k)]
}

# Member labels for the (non-geography) data dimensions. Each such dimension ends
# the file as an EN label block immediately followed by its "1..n" ordinal block;
# the EN block sits right after its FR twin, so the block directly preceding the
# ordinal block is the English member list. We scan only the tail (cheap) and
# return a list keyed by member count, e.g. `[["128"]]` = Age, `[["3"]]` = Gender.
ivt_f2_dim_member_labels <- function(raw, tail_bytes = 400000L) {
  start <- max(0L, length(raw) - tail_bytes)
  blocks <- ivt_find_member_blocks(raw, start, min_records = 3L)
  if (!length(blocks)) return(list())
  ord <- order(vapply(blocks, function(b) b$start, 1))
  B <- blocks[ord]
  out <- list()
  for (i in seq_along(B)) {
    t <- B[[i]]$texts
    nt <- length(t)
    if (nt < 3L || i == 1L) next
    if (!identical(t, as.character(seq_len(nt)))) next   # an "1..n" ordinal block
    cand <- B[[i - 1L]]$texts
    if (length(cand) != nt) next
    key <- as.character(nt)
    if (is.null(out[[key]])) out[[key]] <- cand          # keep first (member order)
  }
  out
}

# --- Full geography attribute table ------------------------------------------
#
# Each geography member carries 11 attributes, stored in the codebook as
# member-ordered chunks of 256 grouped attribute-major: groups grow in size
# (1, 1, 2, 4, 8, ... 256-member chunks), and within a group every attribute is
# laid down as G English blocks (chunk 0..G-1) then G French blocks, in a fixed
# slot order. DGUID is slot 5, so a group's first block (NAME English chunk 0) is
# at `dguid_chunk0_block - 10*G`. Validated exact vs the StatCan metadata.

# Slot order of the 11 geography attributes (0-indexed); DGUID is slot 5.
IVT_F2_ATTR_SLOTS <- c(
  geo_name = 0L, geo_type = 1L, geo_type_abbr = 2L, geo_level = 3L,
  prov_abbr = 4L, dguid = 5L, alt_geo_code = 6L, pr_code = 7L,
  dqf_code = 8L, dqf_note = 9L, tnr_short_form = 10L)

# Clean attribute blocks from the codebook tail: member arrays only — drop the
# tiny garbage byte-runs the block scanner picks up and the consecutive-integer
# member-ordinal delimiter blocks, both of which would shift positional indexing.
ivt_f2_codebook_blocks <- function(raw, tail_bytes = 20000000L) {
  start <- max(0L, length(raw) - tail_bytes)
  blocks <- ivt_find_member_blocks(raw, start, min_records = 3L)
  is_ord <- function(t) {
    iv <- suppressWarnings(as.integer(t))
    !anyNA(iv) && length(iv) >= 3L && all(diff(iv) == 1L)
  }
  keep <- vapply(blocks, function(b) {
    t <- b$texts
    length(t) >= 150L && mean(grepl("[½¾¼÷×Þþ{}]", t)) < 0.3 &&
      !is_ord(t)
  }, logical(1))
  blocks <- blocks[keep]
  blocks[order(vapply(blocks, function(b) b$start, 1))]
}

# Segment the codebook into attribute groups using the DGUID blocks. Each group's
# DGUID blocks are G chunk-starts ascending (English) then the same G (French);
# returns a list of list(d0 = first DGUID-EN block index, G, starts = member ids).
ivt_f2_geo_groups <- function(blocks, dguids) {
  id_by_dg <- new.env(hash = TRUE, parent = emptyenv())
  for (i in seq_along(dguids)) assign(dguids[i], i, envir = id_by_dg)
  is_dg <- vapply(blocks, function(b)
    length(b$texts) >= 2L && all(grepl("^2021[A-Z][0-9]", b$texts)), logical(1))
  dgi <- which(is_dg)
  ms <- vapply(dgi, function(j) {
    f <- blocks[[j]]$texts[1]
    if (exists(f, envir = id_by_dg, inherits = FALSE)) get(f, envir = id_by_dg) else NA_integer_
  }, integer(1))
  ok <- !is.na(ms); dgi <- dgi[ok]; ms <- ms[ok]
  n <- length(ms); groups <- list(); pos <- 1L
  while (pos <= n) {
    e <- pos
    while (e + 1L <= n && ms[e + 1L] > ms[e]) e <- e + 1L
    G <- e - pos + 1L
    paired <- (e + G) <= n && all(ms[(e + 1L):(e + G)] == ms[pos:e])
    groups[[length(groups) + 1L]] <- list(d0 = dgi[pos], G = G, starts = ms[pos:e])
    pos <- pos + if (paired) 2L * G else G
  }
  groups
}

# Extract one attribute (English) across all members, given the parsed groups.
ivt_f2_extract_attr <- function(blocks, groups, slot, n_geo, tnr = FALSE,
                                group1_name = FALSE) {
  out <- rep(NA_character_, n_geo)
  ng <- length(groups)
  for (gi in seq_len(ng)) {
    g <- groups[[gi]]; G <- g$G
    glo <- g$d0 - 10L * G
    base <- glo + slot * 2L * G
    # group 1 carries an extra leading NAME pair (header table of contents), so
    # its counted NAME English block sits at +G.
    if (group1_name && gi == 1L) base <- glo + G
    bis <- base + seq_len(G) - 1L
    if (tnr) {
      # DQF_NOTE (the slot before TNR) splits long text across a variable number
      # of blocks, so locate TNR by content: blocks of decimal-point numbers.
      bis <- integer(0); bi <- glo + 18L * G; lim <- glo + 26L * G
      while (length(bis) < G && bi <= length(blocks) && bi <= lim) {
        t <- blocks[[bi]]$texts
        if (mean(grepl("^[0-9]+\\.[0-9]+$", t)) > 0.5) bis <- c(bis, bi)
        bi <- bi + 1L
      }
    }
    for (c in seq_len(G)) {
      bi <- bis[c]
      if (is.na(bi) || bi < 1L || bi > length(blocks)) next
      t <- trimws(blocks[[bi]]$texts)
      s <- g$starts[c]
      idx <- s:(s + length(t) - 1L)
      good <- idx >= 1L & idx <= n_geo
      out[idx[good]] <- t[good]
    }
  }
  out
}

#' Full geography attribute table for a family-2 IVT (member-ordered).
#'
#' Returns a tibble with one row per geography (1-based member id) and columns for
#' the decoded codebook attributes: `geo_name`, `dguid`, `geo_level`,
#' `geo_type_abbr`, `prov_abbr`, `alt_geo_code`, `pr_code`, `dqf_code`
#' (data-quality flag) and `tnr_short_form` (total non-response rate). Validated
#' exact vs the StatCan metadata for all 63,404 geographies of 98-10-0023.
#'
#' This parses the codebook block structure and is slower than the DGUID-only
#' path (a few seconds of block scanning); call it only when geography labels are
#' wanted.
#'
#' @keywords internal
#' @noRd
ivt_f2_geo_attributes <- function(raw) {
  dguids <- ivt_f2_geo_dguids(raw)
  n_geo <- length(dguids)
  ivt_f2_check_geo_count(raw, n_geo)
  blocks <- ivt_f2_codebook_blocks(raw)
  groups <- ivt_f2_geo_groups(blocks, dguids)
  pull <- function(name, ...) ivt_f2_extract_attr(blocks, groups, IVT_F2_ATTR_SLOTS[[name]], n_geo, ...)
  dqf_code <- pull("dqf_code")
  # DQF_NOTE is a long concatenation of suppression statements that spans several
  # codebook blocks, so its direct slot extraction is only ~99.8%. It is a 1:1
  # function of DQF_CODE (decoded exactly), so recover it by per-key majority vote
  # over the raw extraction (`ivt_f2_derive_text()`) and look it up from the code.
  # (geo_type needs no such fix-up: accepting Windows-1252 label bytes in
  # `is_label_byte` makes its direct slot extraction exact.)
  dqf_note <- ivt_f2_derive_text(pull("dqf_note"), dqf_code)
  tibble::tibble(
    member_id      = seq_len(n_geo),
    geo_name       = pull("geo_name", group1_name = TRUE),
    dguid          = dguids,
    geo_level      = pull("geo_level"),
    geo_type       = pull("geo_type"),
    geo_type_abbr  = pull("geo_type_abbr"),
    prov_abbr      = pull("prov_abbr"),
    alt_geo_code   = pull("alt_geo_code"),
    pr_code        = pull("pr_code"),
    dqf_code       = dqf_code,
    dqf_note       = dqf_note,
    tnr_short_form = pull("tnr_short_form", tnr = TRUE)
  )
}

# Recover a text attribute that is a 1:1 function of a reliable key, by per-key
# majority vote over the (mostly-correct) raw extraction.
ivt_f2_derive_text <- function(raw_vals, key) {
  ok <- !is.na(key) & !is.na(raw_vals) & nzchar(raw_vals)
  if (!any(ok)) return(raw_vals)
  lut <- tapply(raw_vals[ok], key[ok], function(x) names(which.max(table(x))))
  out <- as.character(lut[key])             # plain vector (drops the array dim/names)
  miss <- is.na(out)
  out[miss] <- raw_vals[miss]               # fall back to raw where no key
  out
}

# --- Inline-codebook geography (pre-DGUID layout, e.g. 1991 table 1003011) ----
#
# Tables older than the 2016 DGUID store geography differently from 98-10-0023:
# instead of a separate DGUID array plus a slotted attribute table, one block type
# per chunk packs everything into each entry as
#     "<name> (<GEOUID>)   <dqf_code>"
# where <name> is the bilingual label ("English | French"), <GEOUID> is the bare
# geographic code (a shortened DGUID without the year and statistical-area-type
# prefix that 2016+ tables carry), and <dqf_code> is the 5-digit data-quality flag.
# These blocks repeat per chunk and per language; the GEOUID is unique, so
# first-appearance de-duplication yields the geographies in member order.
# Validated exact for all 41,859 geographies of 1003011 (1991 census, E9101).

# Fixed-header field offsets (0-based). The header carries a dimension descriptor
# pointer and, in the legacy export format, out-of-line title-string pointers.
IVT_HDR_DESCRIPTOR_PTR <- 32L   # u32 → dimension descriptor block
IVT_HDR_TITLE_FR_PTR   <- 40L   # u32 → French title (0 in the modern inline format)
IVT_HDR_TITLE_EN_PTR   <- 48L   # u32 → English title (0 in the modern inline format)
IVT_DESC_GEO_COUNT     <- 52L   # u16 within the descriptor: geography member count

# Fixed header offsets (0-based) that map the file layout. Validated on the modern
# (98-10-0023) and legacy (1003011) reference tables.
IVT_HDR_GEO_FIELDS   <- 552L   # u32: geography field/attribute count (11 / 12)
IVT_HDR_CODEBOOK_PTR <- 572L   # u32: codebook region start

#' Map the file layout from the header alone (no marker scanning).
#'
#' The fixed header points at every major section, so the whole layout can be read
#' up front. Returns a list with the format `version` ("modern" 2016+/DGUID vs
#' "legacy" pre-DGUID, signalled by whether the out-of-line title pointers are
#' set), and byte offsets for the dimension `descriptor`, EN/FR `title` blocks
#' (legacy only), the geography `field_count`, the page `directory`, the
#' `value_pages` start, the `codebook` region, and `eof`. The variable section
#' table that follows (codebook sub-blocks, dimension member blocks, the notes
#' block) tags entries with a type byte (16 = member/data block, 15 = notes); those
#' offsets are format-specific and not part of this fixed-offset map.
#'
#' @keywords internal
#' @noRd
ivt_f2_header_layout <- function(raw) {
  n <- length(raw)
  fr <- rd_u32(raw, IVT_HDR_TITLE_FR_PTR)
  en <- rd_u32(raw, IVT_HDR_TITLE_EN_PTR)
  legacy <- (!is.na(en) && en != 0) || (!is.na(fr) && fr != 0)
  dir <- ivt_f2_find_directory(raw)
  list(
    version         = if (legacy) "legacy" else "modern",
    descriptor      = rd_u32(raw, IVT_HDR_DESCRIPTOR_PTR),
    title_en        = if (legacy) en else NA_real_,
    title_fr        = if (legacy) fr else NA_real_,
    field_count     = rd_u32(raw, IVT_HDR_GEO_FIELDS),
    directory       = rd_u16(raw, IVT_HDR_DIR_PTR),
    n_pages         = if (!is.null(dir)) dir$n_pages else NA_integer_,
    value_pages     = if (!is.null(dir)) min(dir$offsets) else NA_real_,
    codebook        = rd_u32(raw, IVT_HDR_CODEBOOK_PTR),
    eof             = n
  )
}

# Geography member count, read straight from the header dimension descriptor
# (no need to count by parsing the codebook). Validated: 63,404 (98-10-0023),
# 41,859 (1003011).
ivt_f2_header_geo_count <- function(raw) {
  desc <- rd_u32(raw, IVT_HDR_DESCRIPTOR_PTR)
  if (is.na(desc) || desc < 1 || desc + IVT_DESC_GEO_COUNT + 2 > length(raw)) return(NA_integer_)
  rd_u16(raw, as.integer(desc) + IVT_DESC_GEO_COUNT)
}

# Does this file use the inline (pre-DGUID) geography codebook? This is read from
# the file header, not inferred from the codebook: the modern DGUID-era export
# inlines its identity text ("Product ID:", "Reference Period:") in the header and
# leaves the out-of-line title-string pointers (header u32 @40/@48) zero, whereas
# the legacy export stores titles out-of-line (those pointers are non-zero) and
# uses the inline "name (GEOUID) flag" geography codebook. Confirmed on both
# reference tables (98-10-0023 modern; 1003011 legacy).
ivt_f2_geo_is_inline <- function(raw) {
  if (length(raw) < IVT_HDR_TITLE_EN_PTR + 4L) return(FALSE)
  rd_u32(raw, IVT_HDR_TITLE_EN_PTR) != 0 || rd_u32(raw, IVT_HDR_TITLE_FR_PTR) != 0
}

IVT_F2_INLINE_PAT <- "^(.*) \\(([0-9A-Za-z]+)\\)\\s+([0-9]+)\\s*$"

#' Geography table for an inline-codebook (pre-DGUID) family-2 IVT.
#'
#' Returns a tibble with one row per geography (member order) and columns
#' `geo_name` (bilingual "EN | FR" label), `geouid` (bare geographic code) and
#' `dqf_code` (data-quality flag). Validated exact vs the StatCan member metadata
#' for the 1991 table 1003011.
#'
#' @keywords internal
#' @noRd
ivt_f2_geo_inline <- function(raw, tail_bytes = 8000000L) {
  start <- max(0L, length(raw) - tail_bytes)
  blocks <- ivt_find_member_blocks(raw, start, min_records = 3L)
  blocks <- blocks[order(vapply(blocks, function(b) b$start, 1))]
  pat <- IVT_F2_INLINE_PAT
  is_inline <- vapply(blocks, function(b)
    length(b$texts) >= 16L && mean(grepl(pat, b$texts)) > 0.8, logical(1))
  seen <- new.env(hash = TRUE, parent = emptyenv())
  nm <- character(0); cd <- character(0); fl <- character(0)
  for (b in blocks[is_inline]) {
    m <- regmatches(b$texts, regexec(pat, b$texts))
    for (gg in m) {
      if (length(gg) < 4L) next
      code <- gg[3]
      if (!is.null(seen[[code]])) next
      seen[[code]] <- TRUE
      nm <- c(nm, gg[2]); cd <- c(cd, code); fl <- c(fl, gg[4])
    }
  }
  g <- tibble::tibble(member_id = seq_along(cd), geo_name = trimws(nm),
                      geouid = cd, dqf_code = fl)
  ivt_f2_check_geo_count(raw, nrow(g))
  g
}

# Validate a decoded geography count against the header's declared count. The
# header dimension descriptor states the geography member count explicitly
# (`ivt_f2_header_geo_count()`), so we never have to trust the parser's own tally:
# a mismatch means the codebook stitch dropped or duplicated a chunk.
ivt_f2_check_geo_count <- function(raw, got) {
  want <- ivt_f2_geo_count(raw)
  if (!is.na(want) && !is.na(got) && got != want) {
    cli::cli_warn(c(
      "Decoded {got} geographies but the header declares {want}.",
      i = "The geography codebook stitch may have dropped or duplicated a chunk."
    ))
  }
  invisible(want)
}

#' Decode the geography table, driven by the header metadata.
#'
#' Single metadata-driven entry point that consolidates the two codebook layouts:
#' it reads the layout flag and the declared geography count from the file header,
#' dispatches to the modern DGUID attribute parser (`ivt_f2_geo_attributes()`) or
#' the pre-DGUID inline parser (`ivt_f2_geo_inline()`), validates the row count
#' against the header, and returns a tibble whose leading columns are always
#' `member_id`, `geo_name` and `geo_uid` (the DGUID for 2016+ tables, the bare
#' GEOUID for older ones), followed by any layout-specific attribute columns.
#'
#' @keywords internal
#' @noRd
ivt_f2_geographies <- function(raw) {
  if (ivt_f2_geo_is_inline(raw)) {
    g <- ivt_f2_geo_inline(raw)
    names(g)[names(g) == "geouid"] <- "geo_uid"
  } else {
    g <- ivt_f2_geo_attributes(raw)
    names(g)[names(g) == "dguid"] <- "geo_uid"
  }
  front <- intersect(c("member_id", "geo_name", "geo_uid"), names(g))
  g[, c(front, setdiff(names(g), front))]
}

# --- Header dimension descriptor ----------------------------------------------
#
# The fixed header field @32 (u32) points at a descriptor block that explicitly
# declares the table's dimensions — present in BOTH the modern and legacy formats,
# so it is the reliable source of dimension metadata (the legacy format has no
# inline "Variable List" text). Layout of the descriptor:
#   +16 u16  number of dimensions
#   +52      first dimension record, then one record per dimension:
#            [count][marker = <type> 01][doubled name]
#            • <type> byte: 0x10 = geography, 0x07 = the age-type dimension,
#              0x02 = the gender/sex-type dimension (others occur in other tables)
#            • count: u16 for geography (always > 255), u8 for the rest
#            • name is stored twice back-to-back ("GeographyGeography"); the
#              0x01 marker byte never occurs inside a name, so markers delimit
#              records unambiguously
#   later    "FACET04" + the English title (the legacy file appends "1991 Census…")
# Validated on 98-10-0023 (63404 / 128 / 3) and 1003011 (41859 / 110 / 3).

# Dimension type bytes seen in the descriptor marker "<type> 01".
IVT_F2_DESC_TYPES <- c(0x10L, 0x07L, 0x02L, 0x03L, 0x04L, 0x05L, 0x06L, 0x08L, 0x09L)

#' Parse the header dimension descriptor.
#' @return list(n_dim, dims = list(name, count, type), title) or NULL.
#' @keywords internal
#' @noRd
ivt_f2_descriptor <- function(raw) {
  n <- length(raw)
  D <- rd_u32(raw, IVT_HDR_DESCRIPTOR_PTR)
  if (is.na(D) || D < 1 || D + 18 > n) return(NULL)
  ndim <- rd_u16(raw, as.integer(D) + 16L)
  win <- min(as.integer(D) + 4000L, n)
  v <- as.integer(raw[(as.integer(D) + 1L):win])   # v[k] is byte D+k-1
  # the dimension records sit between the fixed header and the "FACET04" title;
  # bound the marker search there so stray 0x01 bytes in later binary do not match.
  txt_all <- intToUtf8(ifelse(v >= 32L & v <= 126L, v, 46L))
  facet <- regexpr("FACET04", txt_all)
  Lend <- if (facet > 0) facet - 1L else length(v)
  L <- min(Lend, length(v) - 2L)
  # marker positions: v[k] a known type, v[k+1] == 0x01, v[k+2] an upper-case letter
  mk <- which(v[seq_len(L)] %in% IVT_F2_DESC_TYPES &
              v[seq_len(L) + 1L] == 0x01L &
              v[seq_len(L) + 2L] >= 65L & v[seq_len(L) + 2L] <= 90L)
  if (!length(mk)) return(list(n_dim = ndim, dims = list(), title = NA_character_))
  mk <- head(mk, ndim)                       # the first n_dim are the real records
  dims <- vector("list", length(mk))
  for (i in seq_along(mk)) {
    k <- mk[i]; type <- v[k]
    count <- if (type == 0x10L) v[k - 2L] + v[k - 1L] * 256L else v[k - 1L]
    # the name is stored twice back-to-back; read the printable run and recover the
    # single name as the longest period p with run[1:p] == run[(p+1):2p] (this
    # ignores any per-dimension metadata bytes that trail the doubled name).
    name_start <- k + 2L
    e <- name_start
    while (e <= length(v) && v[e] >= 32L && v[e] <= 126L) e <- e + 1L
    run <- v[name_start:(e - 1L)]
    rl <- length(run); name <- intToUtf8(run)
    for (p in seq.int(rl %/% 2L, 1L)) {
      if (identical(run[1:p], run[(p + 1L):(2L * p)])) { name <- intToUtf8(run[1:p]); break }
    }
    dims[[i]] <- list(name = trimws(name), count = count, type = type)
  }
  txt <- intToUtf8(ifelse(v >= 32L & v <= 126L, v, 46L))
  title <- regmatches(txt, regexpr("FACET04[^.]*", txt))
  title <- if (length(title)) trimws(sub("FACET04", "", title)) else NA_character_
  list(n_dim = ndim, dims = dims, title = title)
}

# Geography member count, from the descriptor's geography record (type 0x10).
# This is reliable for any dimensionality; the fixed-offset u16
# `ivt_f2_header_geo_count()` is only correct for 3-dimension tables (it reads
# 16320 instead of 63404 for the 4-dimension 98-10-0129). Falls back to the
# fixed-offset reader when the descriptor cannot be parsed.
ivt_f2_geo_count <- function(raw) {
  d <- ivt_f2_descriptor(raw)
  if (is.null(d) || !length(d$dims)) return(ivt_f2_header_geo_count(raw))
  geo <- Filter(function(x) x$type == 0x10L, d$dims)
  if (!length(geo)) return(ivt_f2_header_geo_count(raw))
  as.integer(geo[[1]]$count)
}

# The non-geography data dimensions, in descriptor (outer -> inner) order: their
# member `counts` (which drive the presence-bitmap nesting and the dense value
# order) and a short column `slug` for each. The two universal census dimensions
# get a canonical slug from their descriptor type byte -- 0x02 -> "gender" (the
# gender/sex-type dimension, whether the table labels it "Gender" or "Sex") and
# 0x07 -> "age" (the age-type dimension, whose descriptor name is sometimes
# truncated, e.g. "Single Years of") -- so the column name is stable across
# tables. Any other dimension takes the lower-cased leading word of its name
# (e.g. "Marital status" -> "marital"), falling back to "dim<i>"; slugs are made
# unique. Returns empty vectors when no descriptor.
ivt_f2_data_dims <- function(raw) {
  d <- ivt_f2_descriptor(raw)
  if (is.null(d) || !length(d$dims)) return(list(counts = integer(0), slugs = character(0)))
  data <- Filter(function(x) x$type != 0x10L, d$dims)
  if (!length(data)) return(list(counts = integer(0), slugs = character(0)))
  counts <- vapply(data, `[[`, 1L, "count")
  slug <- function(dim, i) {
    if (identical(dim$type, 0x02L)) return("gender")
    if (identical(dim$type, 0x07L)) return("age")
    w <- tolower(sub("^[^A-Za-z]*([A-Za-z]+).*$", "\\1", dim$name))
    if (!nzchar(w) || !grepl("^[a-z]+$", w)) paste0("dim", i) else w
  }
  slugs <- vapply(seq_along(data), function(i) slug(data[[i]], i), "")
  if (anyDuplicated(slugs)) slugs <- make.unique(slugs, sep = "")
  list(counts = as.integer(counts), slugs = slugs)
}

# Is this a family-2 file the decoder can actually handle? Several other Beyond
# 20/20 products (the "F"-series, 1981 census, custom CT extracts) share the
# `04 00 20 00` signature and even expose a page-directory-like structure, but
# their header descriptor is a different, undecoded layout: `ivt_f2_descriptor()`
# then reads a garbage dimension count (hundreds/thousands) and recovers zero data
# dimensions. Require a plausible descriptor with at least one positively-sized
# data dimension, so such files are rejected cleanly rather than crashing the
# decoder on an empty dimension list.
ivt_f2_decodable <- function(raw) {
  d <- ivt_f2_descriptor(raw)
  if (is.null(d) || is.na(d$n_dim) || d$n_dim < 2L || d$n_dim > 32L) return(FALSE)
  dd <- ivt_f2_data_dims(raw)
  length(dd$counts) >= 1L && all(!is.na(dd$counts) & dd$counts >= 1L)
}
