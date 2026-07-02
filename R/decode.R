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
# structurally from the marker rather than a per-marker lookup. The marker's
# third byte (`b2`) gates it: 0x00 -> the value run starts immediately (the
# directory's page size is then exactly `4 + rec_bytes + nv*width`). Otherwise
# the first byte's high nibble selects the pad size in value-slot units:
#
#   0x8*  ->  32 / width      (0x88 -> 4, 0x84 -> 8, 0x82 -> 16)
#   0xa*  ->  64 / width + 2  (0xa8 -> 10, 0xa4 -> 18, 0xa2 -> 34)
#
# i.e. the 0x8 pages reserve 4 value slots of pad, the 0xa pages 8 slots plus
# 2 bytes (some tables realise it as a 0xFF run, others as fixed padding -- all
# land at the same offset). The formula reproduces the formerly hard-coded
# six-marker table exactly and holds with zero violations on every page of every
# supported table in the local corpus (~148,000 pages). An unrecognised width
# code or high nibble aborts: decoding with a guessed trailer would silently
# yield garbage values.
ivt_value_trailer <- function(b0, b2) {
  if (b2 == 0x00L) return(0L)
  w <- bitwAnd(b0, 0x0FL)
  hi <- bitwAnd(b0, 0xF0L)
  if (!w %in% c(2L, 4L, 8L) || !hi %in% c(0x80L, 0xa0L)) {
    cli::cli_abort(
      "Unrecognised IVT page marker byte {.val {sprintf('0x%02x', b0)}}: cannot derive the value-run start.",
      class = "canivt_unknown_marker")
  }
  if (hi == 0x80L) 32L %/% w else 64L %/% w + 2L
}

# Derive the full layout from the header descriptor: how the dimensions split into
# in-page / straddle / paged roles, the in-page presence bit grid, the directory
# entry strides, and the per-page presence record size. Geography is dimension 1
# (descriptor order) and participates in the nesting like any other dimension.
ivt_layout <- function(raw) {
  d <- ivt_f2_descriptor(raw)
  if (is.null(d) || length(d$dims) < 2L)
    cli::cli_abort("IVT descriptor has too few dimensions to decode.")
  cnt <- vapply(d$dims, `[[`, 1L, "count")
  m <- length(cnt)
  dd <- ivt_f2_data_dims(raw)
  slugs <- c("geo", dd$slugs)                       # dim 1 = geography (structural)

  # Nest innermost (dim m) outward; find the dimension that overflows the record.
  blk <- 1L; straddle <- NA_integer_; inner_block <- 1L
  for (j in m:1L) {
    need <- ivt_f2_nextpow2(cnt[j] * blk)
    if (need > IVT_PRES_BITS) { straddle <- j; inner_block <- blk; break }
    blk <- need
  }
  if (is.na(straddle)) {
    # The whole table fits one presence record ("no-straddle"). Every validated
    # table has exactly one straddling dimension; the only corpus file reaching
    # this branch is the incompatible 2001 "F"-series variant (97F0020XCB2001070,
    # 14 geographies x 32 data bits), whose pages then decode to garbage
    # (reverse-ordered directory, b2 == 0x00 pages that do not fit their
    # directory size). Until a genuine no-straddle table validates this layout,
    # abort rather than risk silently wrong values.
    cli::cli_abort(
      "No dimension straddles the {IVT_PRES_BITS}-bit page record; this layout is unvalidated.",
      class = "canivt_no_straddle")
  }
  ipc_straddle <- IVT_PRES_BITS %/% inner_block
  win <- as.integer(ceiling(cnt[straddle] / ipc_straddle))
  inpage_idx <- straddle:m
  ipc <- cnt[inpage_idx]; ipc[1L] <- ipc_straddle   # cap the straddle dimension
  lay  <- ivt_f2_bit_layout(ipc)
  grid <- ivt_f2_cell_grid(ipc, lay$stride)

  # Paged dimensions, innermost-first: the straddle window, then every dimension
  # outside the straddle toward geography. When geography straddles, this is just
  # the geography window (a flat, contiguous directory).
  ent_idx <- straddle; ent_counts <- win
  if (straddle > 1L) for (j in (straddle - 1L):1L) {
    ent_idx <- c(ent_idx, j); ent_counts <- c(ent_counts, cnt[j])
  }
  estride <- integer(length(ent_counts)); eb <- 1L
  for (t in seq_along(ent_counts)) { estride[t] <- eb; eb <- ivt_f2_nextpow2(ent_counts[t] * eb) }

  list(counts = cnt, slugs = slugs, n_dim = m,
       straddle = straddle, ipc = ipc, window_count = win,
       inpage_idx = inpage_idx, grid = grid, rec_bytes = lay$rec_bytes,
       ent_idx = ent_idx, ent_counts = ent_counts, estride = estride,
       geo_in_page = straddle == 1L)
}

# Decode one page at 0-based byte offset `off`: returns the present cells' in-page
# tuples (1-based member ids, one column per in-page dimension in descriptor
# order) and their values, or NULL if the page is empty. `size` is the page's
# allocated byte length from its directory entry (the two agreeing u16 fields):
# the computed value run must fit inside it -- across the whole local corpus
# `4 + rec_bytes + trailer + nv*width <= size` holds on every page (and exactly,
# with equality, on the trailer-less b2 == 0x00 pages), so an overrun means the
# marker was misread (wrong width or trailer) and the values would be garbage.
ivt_decode_page <- function(raw, off, lay, size = NA_integer_) {
  b0 <- as.integer(raw[off + 1L]); b2 <- as.integer(raw[off + 3L])
  w <- bitwAnd(b0, 0x0FL)
  if (!w %in% c(2L, 4L, 8L)) {
    cli::cli_abort(
      "Unrecognised IVT page marker byte {.val {sprintf('0x%02x', b0)}}: unknown value-width code.",
      class = "canivt_unknown_marker")
  }
  width <- w
  is_float <- w == 8L
  vstart <- 4L + lay$rec_bytes + ivt_value_trailer(b0, b2)

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

#' Decode every cell of an IVT into a tibble of one value per row.
#'
#' Columns: `geo` (1-based geography member id) plus one 1-based member-id column
#' per data dimension (named by its structural slug, descriptor order), and
#' `value`. Only non-zero cells are stored.
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
  skipped <- 0L; skipped_ex <- character()
  for (r in seq_len(nrow(coord))) {
    o <- idx0 + eidx[r] * 8L
    if (o + 8L > n) next
    off <- rd_u32(raw, o); s1 <- rd_u16(raw, o + 4L); s2 <- rd_u16(raw, o + 6L)
    if (s1 != s2 || s1 <= 0L || off < 1L || off + 4L > n) next
    if (!ivt_f2_is_marker(raw, off)) {
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
    # the straddle's windows over-cover its member count; drop the padding tail
    keep <- md[, straddle] <= lay$counts[straddle]
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

  if (ci == 0L) {
    out <- tibble::tibble(geo = integer(0))
    for (j in 2:m) out[[lay$slugs[j]]] <- integer(0)
    out$value <- numeric(0)
    return(out)
  }
  cols <- do.call(rbind, md_acc[seq_len(ci)])
  out <- tibble::tibble(geo = cols[, 1L])
  for (j in 2:m) out[[lay$slugs[j]]] <- cols[, j]
  out$value <- unlist(v_acc[seq_len(ci)], use.names = FALSE)
  out
}
