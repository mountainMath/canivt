#' IVT cell decode (unified, descriptor-driven)
#'
#' Both Beyond 20/20 container families decoded by this package are the **same**
#' power-of-two-nested positional layout; the historical "family 1 / family 2"
#' split is just *which dimension straddles the page boundary*. The model:
#'
#' - Nest every dimension power-of-two-positionally, **data dimensions innermost**
#'   (header descriptor order, last dimension fastest) and **geography outermost**
#'   (geography is the first descriptor dimension, identified positionally).
#' - Each page carries a fixed **`IVT_PRES_BITS`-bit (256-byte) presence record**,
#'   filled from the innermost dimension outward.
#' - Exactly **one dimension straddles** the 2048-bit boundary: its in-page part
#'   (`ipc = floor(2048 / inner_block_bits)` members) stays in the presence
#'   bitmap; the remainder becomes directory-paged "windows"
#'   (`window_count = ceil(count / ipc)`). Every dimension *outside* the straddle
#'   is addressed positionally by the page-directory entry index, with
#'   power-of-two-nested strides in 8-byte entry units (window innermost).
#'
#' When the straddle is a **data** dimension, geography is pushed fully into the
#' directory: one page per (geography, outer-data-coordinate), a per-geography
#' directory block (the historical "family 1", e.g. 98-10-0241/0077/0662). When
#' the data dimensions fit in <=2048 bits, **geography itself straddles**:
#' `gpp = 2048 / data_bits` geographies share each page's presence record and the
#' directory is a flat list of geography-window pages (the historical "family 2",
#' e.g. 98-10-0023/0129/1991). One `ivt_layout()` + `ivt_decode()` handles both,
#' and reproduces the two former decoders cell-for-cell on all six reference
#' tables.
#'
#' Presence is byte-pair-swapped then read MSB-first (`ivt_f2_record_present()`);
#' per-page value width/type and the value-run start come from the page marker.
#' Only non-zero cells are stored (StatCan publishes the zeros).
#'
#' @keywords internal
#' @noRd
NULL

# Fixed page presence capacity: 2048 bits = 256 bytes. The nested dimensions fill
# it innermost-first; the first dimension that overflows it straddles.
IVT_PRES_BITS  <- 2048L
IVT_PRES_BYTES <- IVT_PRES_BITS %/% 8L

# Bytes between the end of the presence record and the dense value run, derived
# structurally from the marker's third and fourth bytes (`b2`, `b3`), which
# ENCODE it:
#
#   trailer = 0                                        when b2 == 0x00
#           = 2*(b2 >> 4) + 2*(low nibble(b2) > 0)     otherwise
#   head    = 32 * (b3 - 8)                            (the auxiliary head block)
#
# i.e. b2's high nibble counts 2-byte pad units (realised as a 0xFF run), a
# non-zero low nibble appends one further 2-byte field, and b3 counts 32-byte
# auxiliary head units. The b2 formula is derived from 98-10-0013, whose 22
# pages carry 18 distinct b2 values (0x2a..0x63, trailers 6..14, each anchored
# byte-exact against the StatCan CSV); it reproduces the formerly hard-coded
# six-marker constants exactly (88/20 -> 4, a8/41 -> 10, 84/40 -> 8,
# 82/80 -> 16, a4/82 -> 18 -- the old "32/width | 64/width + 2" width formula
# only coincided because b2 was constant per marker family). The b3 head term
# generalises what used to be a hard-coded "+32 on 0xa2 pages": across the
# whole corpus every 0xa2 page is `a2 01 03 09` and every other supported-table
# page is b3 = 0x08, so the two rules are observationally identical there --
# but the 2006 census vintage (97-563-XCB2006072) carries b3 = 0x0a/0x0c pages
# (64/128-byte heads) on 0x82/0x84 markers, byte-verified against the page-size
# equation on all 14,381 of its pages. Those pages also append per-(geo,
# outer-dim) suppression-mask records AFTER the value run, so they are not
# exact-fit; see ivt_page_preflight() and ivt-format.md. An unrecognised width
# code, high nibble or b3 aborts: decoding with a guessed value-run start would
# silently yield garbage values.
ivt_value_trailer <- function(b0, b2, b3 = 0x08L) {
  w <- bitwAnd(b0, 0x0FL)
  hi <- bitwAnd(b0, 0xF0L)
  if (!w %in% IVT_MARKER_WIDTHS || !hi %in% c(0x80L, 0xa0L) ||
      !b3 %in% ivt_f2_marker_b3) {
    cli::cli_abort(
      "Unrecognised IVT page marker bytes {.val {sprintf('0x%02x .. 0x%02x', b0, b3)}}: cannot derive the value-run start.",
      class = "canivt_unknown_marker")
  }
  head <- 32L * (b3 - 8L)
  if (b2 == 0x00L) return(head)
  2L * (b2 %/% 16L) + 2L * as.integer(bitwAnd(b2, 0x0FL) > 0L) + head
}

# Derive the full layout from the header descriptor: how the dimensions split into
# in-page / straddle / paged roles, the in-page presence bit grid, the directory
# entry strides, and the per-page presence record size. Geography is dimension 1
# (descriptor order) and participates in the nesting like any other dimension.
ivt_layout <- function(raw)
  ivt_memo(raw, "layout", function() ivt_layout_impl(raw))

# `d` overrides the file's descriptor -- used by the `02 00 20 00` count probe
# (`ivt_f2_descriptor_02()`), which builds a candidate descriptor and tests its
# layout against the value pages without going through the memoized descriptor
# (which would recurse). Data-dimension slugs are derived straight from `d` here
# (not via the descriptor-fetching `ivt_f2_data_dims()`) for the same reason.
ivt_layout_impl <- function(raw, d = NULL) {
  if (is.null(d)) d <- ivt_f2_descriptor(raw)
  if (is.null(d) || length(d$dims) < 2L)
    cli::cli_abort("IVT descriptor has too few dimensions to decode.")
  cnt <- vapply(d$dims, `[[`, 1L, "count")
  m <- length(cnt)
  # Per-dimension member SLOT positions (1-based), when the codebook declares
  # them (the survey generations' time-series member table can carry deleted
  # holes -- tb611996's periods occupy slots {1,2,4}). The bitmap and the
  # directory address members by SLOT, so all GEOMETRY below (nesting widths,
  # window counts, strides) uses the slot EXTENT, while member counts keep
  # sizing the cell grid; `slot_pos` lets the decode map slot -> member id.
  slot_pos <- lapply(d$dims, function(x) {
    s <- x$slots
    if (is.null(s) || !length(s) || identical(as.integer(s), seq_along(s)))
      NULL else as.integer(s)
  })
  ext <- cnt
  for (j in seq_len(m)) if (!is.null(slot_pos[[j]])) ext[j] <- max(slot_pos[[j]])
  # the geography dimension (dimension 1 outside the profile lineage) only
  # determines the "geo" slug and the geo_in_page provenance tag -- the nesting
  # below treats every dimension identically by position.
  gd <- ivt_f2_geo_dim_index(raw, d)
  didx <- setdiff(seq_along(d$dims), gd)
  dnms <- vapply(d$dims[didx], function(x)
    if (is.null(x$name) || is.na(x$name)) NA_character_ else as.character(x$name), "")
  slugs <- character(m); slugs[gd] <- "geo"
  if (length(didx)) slugs[didx] <- ivt_dim_slugs(dnms, didx)

  # Nest innermost (dim m) outward; find the dimension that overflows the record.
  # Dimension 1 (geography) ALWAYS takes the straddle role when nothing inner
  # overflows: the page presence record is a fixed IVT_PRES_BITS regardless of
  # how little of it the table needs, so a table whose dimensions all fit one
  # record (98-10-0044: 14 geographies x 32 data bits = 512 bits) is simply the
  # trivial case of the geography-straddle layout -- ipc = 2048/inner exceeds
  # the geography count and there is a single directory window. (Validated
  # cell-exact vs the B2020 viewer on 98-10-0044; decoding it with a record
  # sized to the used bits, 64 bytes, misaligns the value run.)
  blk <- 1L; straddle <- NA_integer_; inner_block <- 1L
  for (j in m:1L) {
    need <- ivt_f2_nextpow2(ext[j] * blk)
    if (need > IVT_PRES_BITS || j == 1L) { straddle <- j; inner_block <- blk; break }
    blk <- need
  }
  ipc_straddle <- IVT_PRES_BITS %/% inner_block
  win <- as.integer(ceiling(ext[straddle] / ipc_straddle))
  inpage_idx <- straddle:m
  ipc <- cnt[inpage_idx]; ipc[1L] <- ipc_straddle   # cap the straddle dimension
  # bit strides span the slot EXTENTS; the grid enumerates real MEMBERS, each
  # member's bit taken from its slot position (dense when no slot table)
  ipc_ext <- ext[inpage_idx]; ipc_ext[1L] <- ipc_straddle
  lay  <- ivt_f2_bit_layout(ipc_ext)
  # per-in-page-dim 0-based bit positions; the straddle's in-page part stays
  # window-dense (slot-aware straddles are mapped window-side in ivt_decode)
  pos1 <- vector("list", length(inpage_idx))
  if (length(inpage_idx) > 1L) for (t in 2:length(inpage_idx)) {
    p <- slot_pos[[inpage_idx[t]]]
    if (!is.null(p)) pos1[[t]] <- p - 1L
  }
  grid <- ivt_f2_cell_grid(ipc, lay$stride, pos = pos1)

  # Paged dimensions, innermost-first: the straddle window, then every dimension
  # outside the straddle toward geography. When geography straddles, this is just
  # the geography window (a flat, contiguous directory). Entry spans and strides
  # cover the slot EXTENT of each paged dimension.
  ent_idx <- straddle; ent_counts <- win
  if (straddle > 1L) for (j in (straddle - 1L):1L) {
    ent_idx <- c(ent_idx, j); ent_counts <- c(ent_counts, ext[j])
  }
  estride <- integer(length(ent_counts)); eb <- 1L
  for (t in seq_along(ent_counts)) { estride[t] <- eb; eb <- ivt_f2_nextpow2(ent_counts[t] * eb) }

  list(counts = cnt, slugs = slugs, n_dim = m, geo_dim = gd,
       straddle = straddle, ipc = ipc, window_count = win,
       inpage_idx = inpage_idx, grid = grid, rec_bytes = lay$rec_bytes,
       ent_idx = ent_idx, ent_counts = ent_counts, estride = estride,
       slot_pos = slot_pos,
       geo_in_page = straddle == gd)
}

# Decode one page at 0-based byte offset `off`: returns the present cells' in-page
# tuples (1-based member ids, one column per in-page dimension in descriptor
# order) and their values, or NULL if the page is empty. `size` is the page's
# allocated byte length from its directory entry (the two agreeing u16 fields):
# the computed value run must fit inside it -- across the whole local corpus
# `4 + rec_bytes + trailer + head + nv*width <= size` holds on every page (and
# exactly, with equality, on the trailer-less b2 == 0x00 pages with b3 <= 0x09;
# the b3 >= 0x0a pages append suppression-mask records after the run), so an
# overrun means the marker was misread (wrong width, trailer or head) and the
# values would be garbage.
ivt_decode_page <- function(raw, off, lay, size = NA_integer_) {
  b0 <- as.integer(raw[off + 1L]); b2 <- as.integer(raw[off + 3L])
  b3 <- as.integer(raw[off + 4L])
  w <- bitwAnd(b0, 0x0FL)
  if (!w %in% IVT_MARKER_WIDTHS) {
    cli::cli_abort(
      "Unrecognised IVT page marker byte {.val {sprintf('0x%02x', b0)}}: unknown value-width code.",
      class = "canivt_unknown_marker")
  }
  width <- w
  is_float <- w == 8L
  if (b0 < 0x80L) return(ivt_decode_page_dense(raw, off, lay, size, width, is_float))
  vstart <- 4L + lay$rec_bytes + ivt_value_trailer(b0, b2, b3)

  pres <- ivt_f2_record_present(raw, off + 4L, lay$rec_bytes, lay$grid$bit)
  nv <- sum(pres)
  if (nv == 0L) return(NULL)
  vend <- vstart + nv * width
  if ((!is.na(size) && vend > size) || off + vend > length(raw)) {
    cli::cli_abort(c(
      "IVT page at byte {off}: the computed value run ends at page byte {vend} but the directory allocates {size} bytes.",
      i = "The page marker ({sprintf('%02x %02x %02x %02x', as.integer(raw[off + 1L]), as.integer(raw[off + 2L]), as.integer(raw[off + 3L]), as.integer(raw[off + 4L]))}) was likely misread (wrong value width or trailer)."
    ), class = "canivt_page_overrun")
  }
  bytes <- raw[(off + vstart + 1L):(off + vend)]
  vals <- if (is_float) {
    readBin(bytes, "double", n = nv, size = 8L, endian = "little")
  } else {
    as.numeric(readBin(bytes, "integer", n = nv, size = width, signed = TRUE, endian = "little"))
  }
  list(tuples = lay$grid$tuples[pres, , drop = FALSE], vals = vals)
}

# The DENSE page variant (marker high nibble 0x0; the 1991 profile tables
# 98F0172X / 95F0170X): `[b0][01][u16 count]` then `count` values, one per
# in-page grid position IN GRID ORDER, with absent cells stored as literal
# zeros -- no presence record, no trailer. `count` covers at least the real
# grid positions and may run past them as zero padding (observed counts
# 2048/2080/2112/2176 against a 2048-position window; the trailing extras are
# all zero, and the last window's positions past the straddle count are zero
# too). Every dense corpus page fits its directory entry EXACTLY
# (4 + count*width == size). Zero values are dropped -- the store keeps only
# non-zero cells, so a dense zero and an absent sparse cell mean the same
# published 0.
ivt_decode_page_dense <- function(raw, off, lay, size, width, is_float) {
  cnt <- rd_u16(raw, off + 2L)
  vend <- 4L + cnt * width
  if ((!is.na(size) && vend > size) || off + vend > length(raw)) {
    cli::cli_abort(c(
      "IVT dense page at byte {off}: the value run ends at page byte {vend} but the directory allocates {size} bytes.",
      i = "The page marker ({sprintf('%02x %02x %02x %02x', as.integer(raw[off + 1L]), as.integer(raw[off + 2L]), as.integer(raw[off + 3L]), as.integer(raw[off + 4L]))}) was likely misread."
    ), class = "canivt_page_overrun")
  }
  ngrid <- nrow(lay$grid$tuples)
  k <- min(cnt, ngrid)
  if (k == 0L) return(NULL)
  bytes <- raw[(off + 4L + 1L):(off + 4L + k * width)]
  vals <- if (is_float) {
    readBin(bytes, "double", n = k, size = 8L, endian = "little")
  } else {
    as.numeric(readBin(bytes, "integer", n = k, size = width, signed = TRUE, endian = "little"))
  }
  keep <- vals != 0
  if (!any(keep)) return(NULL)
  list(tuples = lay$grid$tuples[seq_len(k), , drop = FALSE][keep, , drop = FALSE],
       vals = vals[keep])
}

# Cheap structural pre-flight for the decodability gate: the first few
# non-empty data pages must be geometry-consistent under the derived layout.
# Three per-page rules, each holding on every page of every validated table:
#
# - the presence count, trailer and value width must fit the page's
#   directory-allocated size (`4 + rec_bytes + trailer + nv*width <= size`);
# - a trailer-less page (marker b2 == 0x00) must fit it EXACTLY;
# - the presence count must not exceed the page's REAL cell capacity
#   (`min(ipc1, straddle count) * prod(inner counts)`): a set bit at a padding
#   position -- a straddle slot beyond the dimension's member count -- can
#   correspond to no real cell, so any excess means the nesting is wrong.
#
# A wrong layout, or an incompatible container that happens to parse, fails
# here and the file is rejected as unsupported instead of decoding unvalidated
# values: the 2001 "F"-series 97F0020XCB2001070 fits its pages exactly but
# carries 1124 presence bits against a 448-cell capacity (its data must be
# nested differently), and the 98-400-X2016203 variant carries non-exact
# b2 == 0 pages. Checks up to `max_pages` non-empty pages.
ivt_page_preflight <- function(raw, lay = NULL, max_pages = 8L) {
  if (is.null(lay)) lay <- tryCatch(ivt_layout(raw), error = function(e) NULL)
  if (is.null(lay)) return(FALSE)
  n <- length(raw); idx0 <- ivt_idx0(raw)
  cap <- min(lay$ipc[1L], lay$counts[lay$straddle]) * prod(lay$ipc[-1L])
  seen <- 0L; valid <- 0L
  for (k in 0:4095) {
    o <- idx0 + 8L * k
    if (o + 8L > n) break
    en <- ivt_dir_entry(raw, o, n)
    if (is.null(en) || !en$marker) next
    off <- en$off; s1 <- en$size
    valid <- valid + 1L
    b0 <- as.integer(raw[off + 1L]); b2 <- as.integer(raw[off + 3L])
    b3 <- as.integer(raw[off + 4L])
    w <- bitwAnd(b0, 0x0FL)
    if (!w %in% IVT_MARKER_WIDTHS) return(FALSE)
    if (b0 < 0x80L) {
      # dense variant: `count` positional values right after the 4-byte header,
      # and the page fits its directory allocation EXACTLY (every dense corpus
      # page does); a mismatch means the count field / width was misread.
      cnt <- rd_u16(raw, off + 2L)
      if (4L + cnt * w != s1 || off + 4L + cnt * w > n) return(FALSE)
      seen <- seen + 1L
      if (seen >= max_pages) break
      next
    }
    tr <- tryCatch(ivt_value_trailer(b0, b2, b3), error = function(e) NULL)
    if (is.null(tr)) return(FALSE)
    nv <- sum(ivt_f2_record_present(raw, off + 4L, lay$rec_bytes, lay$grid$bit))
    if (nv == 0L) next
    end <- 4L + lay$rec_bytes + tr + nv * w
    if (end > s1 || off + end > n || nv > cap) return(FALSE)
    # Exact fit is required ONLY for pages that carry no auxiliary head and no
    # suppression tail: b2 == 0 (no trailer) AND b3 == 0x08 (head = 0). Pages
    # with a head block (b3 >= 0x09) may append a per-(geo, outer-dim) missing-
    # cell mask / allocation slack after the dense value run, so only the <=
    # extent bound applies -- the 2006 census vintage (97-563) does this on its
    # b3 >= 0x0a pages, and the 2001 profile lineage (95F0490) already on its
    # b3 == 0x09 pages (8-80 byte tails). Decoding stays presence-authoritative
    # (exactly popcount values read from vstart), so the tail never affects it.
    if (b2 == 0x00L && b3 <= 0x08L && end != s1) return(FALSE)
    seen <- seen + 1L
    if (seen >= max_pages) break
  }
  # no counterexample is not enough: at least one real page must have validated,
  # else a wrong directory base (e.g. the historical idx0 fallback constant on a
  # file it does not fit) would pass vacuously.
  if (valid == 0L) return(FALSE)
  # the directory must SPAN the layout's entry cartesian: walking backward from
  # the end of the outer dimension's entry range, the highest valid entry must
  # fall in the outer dimension's UPPER HALF. Wholly-empty trailing members are
  # normal in moderation (98-10-0174's last ~4% of geography windows carry no
  # entries), but a directory confined to the first outer member means the
  # nesting is wrong: the 1981 profile variant (97-570-X1981004) parses into a
  # geography-first layout whose directory covers only outer member 1 of 32 --
  # its data is actually nested geography-LAST, and decoding it would silently
  # return 1/32 of the table with geography mislabelled.
  # Span the OUTERMOST entry dimension that actually has >1 member. A
  # single-member outer dimension -- a one-geography custom crosstab such as
  # CRO0166131_CT.1.1, whose only geography is "Vancouver CMA" -- spans nothing:
  # its stride would push the search window past the real directory extent, so
  # fall back inward to the outermost dimension that has a range to span. When
  # every entry dimension is a single member there is nothing to span.
  gt1 <- which(lay$ent_counts > 1L)
  if (!length(gt1)) return(TRUE)
  j <- max(gt1)
  ostride <- lay$estride[j]; ocount <- lay$ent_counts[j]
  hi_k <- -1L
  for (k in (ocount * ostride - 1L):max(0L, ocount * ostride - 65536L)) {
    en <- ivt_dir_entry(raw, idx0 + 8L * k, n)
    if (!is.null(en) && en$marker) { hi_k <- k; break }
  }
  hi_k >= 0L && (hi_k %/% ostride + 1L) * 2L > ocount
}

#' Decode every cell of an IVT into a tibble of one value per row.
#'
#' One 1-based member-id column per dimension in descriptor order (named by the
#' structural slugs; the geography dimension's column is `geo`, which need not
#' be first -- the 1981 profile stores geography last), and `value`. Only
#' non-zero cells are stored.
#' @keywords internal
#' @noRd
ivt_decode <- function(raw, lay = NULL) {
  if (is.null(lay)) lay <- ivt_layout(raw)
  n <- length(raw); idx0 <- ivt_idx0(raw)
  m <- lay$n_dim; straddle <- lay$straddle; ipc1 <- lay$ipc[1L]
  ne <- length(lay$ent_counts)

  # Every directory-entry coordinate (cartesian over the paged dimensions,
  # innermost-first): its entry index (-> byte offset) and the member id it
  # contributes to each non-window paged dimension.
  coord <- as.matrix(expand.grid(lapply(lay$ent_counts, function(c) 0:(c - 1L)),
                                 KEEP.OUT.ATTRS = FALSE))
  eidx <- as.integer(coord %*% lay$estride)
  win_col <- coord[, 1L]                              # straddle window per entry
  paged_member <- if (ne > 1L) coord[, -1L, drop = FALSE] else NULL
  paged_dim    <- if (ne > 1L) lay$ent_idx[-1L] else integer(0)
  inpage_dim   <- lay$inpage_idx

  md_acc <- vector("list", nrow(coord)); v_acc <- vector("list", nrow(coord)); ci <- 0L
  skipped <- 0L; skipped_ex <- character(); hole_vals <- 0L
  for (r in seq_len(nrow(coord))) {
    en <- ivt_dir_entry(raw, idx0 + eidx[r] * 8L, n)
    if (is.null(en)) next
    off <- en$off; s1 <- en$size
    if (!en$marker) {
      # A valid directory entry (agreeing sizes, in-range offset) that does not
      # point at a known page marker is a page variant we cannot decode -- on
      # every validated table this never happens (0 entries corpus-wide except
      # the 98-400-X2016203 `a2 01 03 0a` pages), so it must not pass silently:
      # each skipped entry is a block of cells missing from the output.
      skipped <- skipped + 1L
      ex <- paste(sprintf("%02x", as.integer(raw[off + 1:4])), collapse = " ")
      if (!ex %in% skipped_ex) skipped_ex <- c(skipped_ex, ex)
      next
    }
    pg <- ivt_decode_page(raw, off, lay, size = s1)
    if (is.null(pg)) next
    np <- length(pg$vals)
    md <- matrix(0L, np, m)
    for (t in seq_along(inpage_dim)) {
      di <- inpage_dim[t]
      md[, di] <- if (di == straddle) win_col[r] * ipc1 + pg$tuples[, t] else pg$tuples[, t]
    }
    if (length(paged_dim)) for (t in seq_along(paged_dim))
      md[, paged_dim[t]] <- paged_member[r, t] + 1L
    # Straddle / paged coordinates are SLOT ids at this point (the in-page grid
    # already maps slots to member ids through its bit positions). Map slot ->
    # member id for slot-aware straddle/paged dimensions (deleted holes and
    # padding fall out as NA), and drop the straddle's window-padding tail
    # beyond its member count. A value at a deleted slot would be a format
    # misunderstanding -- counted and reported loudly below.
    keep <- rep(TRUE, np)
    for (j in unique(c(straddle, paged_dim))) {
      sp <- lay$slot_pos[[j]]
      if (!is.null(sp)) {
        mid <- match(md[, j], sp)
        bad <- is.na(mid)
        if (any(bad)) { hole_vals <- hole_vals + sum(pg$vals[bad] != 0) }
        keep <- keep & !bad
        md[, j] <- ifelse(bad, 1L, mid)               # placeholder; rows filtered by keep
      } else if (j == straddle) {
        keep <- keep & md[, j] <= lay$counts[j]
      }
    }
    if (!all(keep)) { md <- md[keep, , drop = FALSE]; pg$vals <- pg$vals[keep] }
    if (!nrow(md)) next
    ci <- ci + 1L; md_acc[[ci]] <- md; v_acc[[ci]] <- pg$vals
  }
  if (skipped > 0L) {
    ivt_fallback(paste(
      "{skipped} page-directory entr{?y/ies} point{?s/} at unrecognised page",
      "markers ({.val {skipped_ex}}); the cells of {skipped} page{?s} are",
      "MISSING from the decode."), class = "canivt_skipped_pages")
  }
  if (hole_vals > 0L) {
    ivt_fallback(paste(
      "{hole_vals} non-zero value{?s} sat at DELETED member slots (the codebook",
      "slot table marks those positions as holes); {?it was/they were} dropped."),
      class = "canivt_slot_hole")
  }

  if (ci == 0L) {
    out <- tibble::tibble(.rows = 0L)
    for (j in seq_len(m)) out[[lay$slugs[j]]] <- integer(0)
    out$value <- numeric(0)
    return(out)
  }
  cols <- do.call(rbind, md_acc[seq_len(ci)])
  out <- tibble::tibble(.rows = nrow(cols))
  for (j in seq_len(m)) out[[lay$slugs[j]]] <- cols[, j]
  out$value <- unlist(v_acc[seq_len(ci)], use.names = FALSE)
  out
}
