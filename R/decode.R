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

# The highest page-directory entry index any container can address: every entry is
# 8 bytes and is reached as `idx0 + 8L * k` in 32-bit integer arithmetic, so a
# cartesian past this is not merely absent from the file, it is unrepresentable.
IVT_MAX_DIR_ENTRIES <- .Machine$integer.max %/% 8L

# Is entry index `k` reachable as a byte offset from directory base `idx0`? The
# same bound as `IVT_MAX_DIR_ENTRIES`, less the base the offset is measured from.
# `k` must be passed as a DOUBLE: the index a layout addresses is a product of
# member counts and strides, and on a misread descriptor that product exceeds
# 2^31 -- computed in integer it silently becomes NA (warning "NAs produced by
# integer overflow"), which then propagates into the directory read as
# "NA/NaN argument" and turns the detection gate's verdict into an ERROR.
# Alternative.cfm_PID_1195_EXT_IVT is the case in point: its descriptor reads out
# to an outer cartesian of 113,514,643,456 entries, ~440x the addressable extent.
ivt_entry_addressable <- function(k, idx0) {
  is.finite(k) && k >= 0 && k <= (.Machine$integer.max - idx0) %/% 8L
}

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
# exact-fit; see ivt_page_preflight() and ivt-format.md.
#
# `ivt_f2_marker_b3` is the observed SPAN of that 32-byte-block count, not a
# sparse enumeration: 0x0b/0x0d/0x0e were added for the SLID-era income lineage
# (SP3_RHUXA9 103/404/405/501/701/703), where the head grows with the geography
# dimension's slot allocation. Those files over-allocate every page (1,528-2,344
# bytes of slack on b3 = 0x0a/0x0c pages too), so the page-size equation only
# BOUNDS them -- the head length is validated at the data level instead: on
# SP3_RHUXA9_404 all 14,520 age-additivity groups reconcile, and a cell decoded
# only because of this widening supplies exactly the residual the published
# total requires (decode-history.md). An unrecognised width code, high nibble or
# b3 aborts: decoding with a guessed value-run start would silently yield
# garbage values.
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

# THE CONTAINER IS THE THIRD COUNT WITNESS. The descriptor states each dimension's
# member count and the codebook states it again (`ivt_f2_dim_count_reconcile()`);
# the PAGE DIRECTORY states it a third time, and it is the only witness that
# cannot be short: a member with data has a page, and that page has a directory
# entry at the index the nesting puts it. So when the entry ONE PAST the
# outermost dimension's declared extent still resolves to a page that decodes
# with data, the declared count is short -- those cells exist in the file and
# would otherwise be silently dropped.
#
# The Business-Register `CDCSDNAIC3dec2006` is the case in point: its CD/CSD
# record declares 5,914 members, its codebook holds 5,927 label records, and the
# directory carries decodable pages through geography 5,927 and exactly one
# entry of zeroes after -- the 13 missing members are BC's last census divisions
# and the three territories'. (Validated: with the container's count every
# census division equals the sum of its census subdivisions, 142,948 rows exact.)
#
# Gated hard, because a directory legitimately holds EMPTY pages in the slots
# past the real counts (the padding to the declared slot allocation):
#   * only the OUTERMOST paged dimension -- the one whose entries are strided
#     furthest apart -- is probed, where an extension cannot be confused with an
#     inner dimension's padding;
#   * each probed entry must be a real page that DECODES AND CARRIES CELLS under
#     the same layout, so allocation slack (empty pages) stops the walk at once;
#   * the walk is contiguous from the declared extent and capped at the level's
#     power-of-two allocation -- it can only RAISE a count, never lower one.
# LOUD (`canivt_container_count`).
ivt_dir_outer_count <- function(raw, dims) {
  lay <- tryCatch(ivt_layout_impl(raw, d = list(dims = dims)), error = function(e) NULL)
  if (is.null(lay)) return(NULL)
  t <- length(lay$ent_counts)
  # t == 1 means the only paged level is the straddle dimension's WINDOW level,
  # whose entries count windows, not members -- not a member-count witness.
  if (t < 2L) return(NULL)
  jo <- lay$ent_idx[t]                       # the outermost paged dimension
  n0 <- as.integer(lay$ent_counts[t]); stride <- as.numeric(lay$estride[t])
  if (is.na(n0) || n0 < 1L || !is.finite(stride) || stride < 1) return(NULL)
  if (!identical(as.integer(lay$counts[jo]), n0)) return(NULL)   # slot holes: leave alone
  cap <- ivt_f2_nextpow2(n0)                 # the level's own allocated capacity
  if (cap <= n0) return(NULL)
  idx0 <- tryCatch(ivt_idx0(raw), error = function(e) NA_integer_)
  if (is.na(idx0)) return(NULL)
  n <- length(raw); got <- n0
  # Scan the whole allocated capacity and take the LAST member with data. The walk
  # cannot stop at the first gap: a geography with no stored cells (wholly
  # suppressed, or simply empty) is a real member whose entry is zero or a minimal
  # empty page, and `CDCSDNAIC3dec2006` has two of those inside its 13 undeclared
  # members. Only entries that DECODE AND CARRY CELLS extend the count; everything
  # between is skipped, and a garbage entry (an offset that cannot be a page) ends
  # the scan.
  for (i in n0:(cap - 1L)) {
    k <- i * stride
    if (!ivt_entry_addressable(k, idx0)) break
    o <- idx0 + 8L * as.integer(k)
    if (o + 8L > n) break
    off <- rd_u32(raw, o); size <- rd_u16(raw, o + 4L)
    if (is.na(off) || is.na(size)) break
    if (off == 0L || size == 0L) next                      # unallocated slot
    if (off < 1L || size < 4L || off + size > n) break     # not a page: stop
    pg <- tryCatch(ivt_quietly(ivt_decode_page(raw, off, lay, size)),
                   error = function(e) NULL)
    if (!is.null(pg) && nrow(pg$tuples)) got <- i + 1L
  }
  if (got > n0) list(dim = jo, count = as.integer(got)) else NULL
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
  # Each dimension's DECLARED slot allocation (the u16 of its codebook
  # member-code / time-table block, `ivt_f2_dim_slot_alloc()`): the container
  # pads every nesting level -- presence bits and directory strides alike -- to
  # this allocated capacity. It is nextpow2(extent) for almost every table
  # (making the padded geometry identical to the pow2 model), but can exceed it
  # (Table-023's Hours allocates 32 slots for 10 members), and a dimension whose
  # codebook is chunked past its block allocation declares none that can hold
  # its members -- `pad` then falls back to the extent (nextpow2-padded by the
  # nesting below, exact for the chunked layouts). `slots_tbl` is passed down so
  # the read never re-enters the descriptor parse (the `02 00 20 00` count probe
  # calls this while the descriptor compute is in flight).
  slots_tbl <- ivt_f2_dim_slots(raw, m = m)
  alloc <- vapply(seq_len(m), function(j)
    ivt_f2_dim_slot_alloc(raw, j, ext[j], slots_tbl), integer(1))
  pad <- ifelse(is.na(alloc), ext, alloc)

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
    need <- ivt_f2_nextpow2(pad[j] * blk)
    if (need > IVT_PRES_BITS || j == 1L) { straddle <- j; inner_block <- blk; break }
    blk <- need
  }
  ipc_straddle <- IVT_PRES_BITS %/% inner_block
  win <- as.integer(ceiling(ext[straddle] / ipc_straddle))
  inpage_idx <- straddle:m
  ipc <- cnt[inpage_idx]; ipc[1L] <- ipc_straddle   # cap the straddle dimension
  # bit strides span the declared slot ALLOCATIONS; the grid enumerates real
  # MEMBERS, each member's bit taken from its slot position (dense when no slot
  # table)
  ipc_ext <- pad[inpage_idx]; ipc_ext[1L] <- ipc_straddle
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
  # the geography window (a flat, contiguous directory). Entry counts are the
  # REAL member cartesian (what the decode enumerates); the strides pad each
  # level to the dimension's DECLARED slot allocation -- the straddle window
  # level to `alloc / ipc` window slots (its members' windows over the allocated
  # slot capacity), every outer dimension to its own allocation. With the
  # near-universal `alloc == nextpow2(extent)` this is byte-for-byte the pow2
  # model; Table-023's Hours (alloc 32, 10 members, ipc 4) makes the window
  # level 8 slots where the pow2 model said 4 -- the "doubled-window directory"
  # formerly inferred by a page-size probe (`ivt_survey_double()`, retired
  # 2026-07-23), now read from the file's own allocation. Slots past the real
  # counts hold minimal empty pages (verified: every larger-than-minimal page in
  # Table-023's directory sits inside the real cartesian).
  ws <- ivt_f2_nextpow2(win)
  if (!is.na(alloc[straddle]))
    ws <- max(ws, alloc[straddle] %/% ipc_straddle)
  # The type-00 sub-A Business-Patterns cluster carries a non-declared physical
  # outer stride (`suba.R`); when the descriptor annotation measured it from the
  # page directory, honour it (the DIVISIONS files use one window per geography
  # but still stride by the full allocation).
  # `exact = TRUE`: `attr()` partial-matches by default, and the sibling
  # `suba_unverified` flag shares this prefix.
  suba <- attr(d, "suba", exact = TRUE)
  if (!is.null(suba) && !is.null(suba$stride)) ws <- max(ws, as.integer(suba$stride))
  ent_idx <- straddle; ent_counts <- win; ent_pad <- ws
  if (straddle > 1L) for (j in (straddle - 1L):1L) {
    ent_idx <- c(ent_idx, j); ent_counts <- c(ent_counts, ext[j])
    ent_pad <- c(ent_pad, pad[j])
  }
  # Entry strides are accumulated in DOUBLE precision and checked against the
  # addressable directory extent before use. A misread descriptor (a garbage member
  # count on an alien container) can multiply out past 2^31, where the integer
  # product silently becomes NA -- the NA stride then reached `ivt_page_preflight()`
  # and aborted the whole detection gate with "NA/NaN argument" instead of returning
  # a clean unsupported verdict. Only strides that are actually USED are checked
  # (the accumulator's final value is discarded), so every layout that resolved
  # before still resolves to the identical strides.
  estride <- integer(length(ent_counts)); eb <- 1
  for (t in seq_along(ent_counts)) {
    if (!is.finite(eb) || eb > IVT_MAX_DIR_ENTRIES)
      stop("page-directory cartesian exceeds the addressable directory extent ",
           "(", format(eb, scientific = FALSE), " entries) -- descriptor misread")
    estride[t] <- as.integer(eb)
    eb <- 2^ceiling(log2(max(as.numeric(ent_pad[t]) * eb, 1)))
  }

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
ivt_decode_page <- function(raw, off, lay, size = NA_integer_, pres = NULL,
                            nvf = NULL) {
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

  # The value run is as long as the presence record says (`ivt_f2_record_popcount()`
  # -- the WHOLE record), which is what the page's byte extent must be measured
  # against. The grid's own popcount only says how many of those values this
  # layout has a cell for; the two agree everywhere the members fill their
  # declared slot allocation, so the extra popcount is the only cost paid there.
  if (is.null(nvf)) nvf <- ivt_f2_record_popcount(raw, off + 4L, lay$rec_bytes)
  if (nvf == 0L) return(NULL)
  # The cell-status read (`missing = TRUE`) has already unpacked this page's
  # presence record; taking it from the caller saves a second pass over the
  # bitmap on every page of every completed table.
  if (is.null(pres))
    pres <- ivt_f2_record_present(raw, off + 4L, lay$rec_bytes, lay$grid$bit)
  nv <- sum(pres)
  vend <- vstart + nvf * width
  if ((!is.na(size) && vend > size) || off + vend > length(raw)) {
    cli::cli_abort(c(
      "IVT page at byte {off}: the computed value run ends at page byte {vend} but the directory allocates {size} bytes.",
      i = "The page marker ({sprintf('%02x %02x %02x %02x', as.integer(raw[off + 1L]), as.integer(raw[off + 2L]), as.integer(raw[off + 3L]), as.integer(raw[off + 4L]))}) was likely misread (wrong value width or trailer)."
    ), class = "canivt_page_overrun")
  }
  if (nv == 0L && nvf == nv) return(NULL)
  bytes <- raw[(off + vstart + 1L):(off + vend)]
  vals <- if (is_float) {
    readBin(bytes, "double", n = nvf, size = 8L, endian = "little")
  } else {
    as.numeric(readBin(bytes, "integer", n = nvf, size = width, signed = TRUE, endian = "little"))
  }
  if (nvf == nv)                                   # every stored value is a cell
    return(list(tuples = lay$grid$tuples[pres, , drop = FALSE], vals = vals,
                rows = which(pres), extra = 0L, extra_nz = 0L))
  # The record flags positions the grid does not model, so a value's index in the
  # run is its RANK AMONG ALL PRESENT BITS, not among the modelled ones. Take that
  # rank explicitly rather than assuming the unmodelled bits sit past the last
  # modelled one (they do on the one corpus file that has any, but nothing in the
  # container guarantees it, and getting it wrong would shift a whole page).
  full <- ivt_f2_record_present(raw, off + 4L, lay$rec_bytes,
                                seq.int(0L, lay$rec_bytes * 8L - 1L))
  vi <- cumsum(full)[lay$grid$bit[pres] + 1L]
  keepv <- logical(nvf); keepv[vi] <- TRUE      # `-vi` would empty an all-extra page
  list(tuples = lay$grid$tuples[pres, , drop = FALSE], vals = vals[vi],
       rows = which(pres), extra = nvf - nv, extra_nz = sum(vals[!keepv] != 0))
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
  # A dense page has no presence record, so it cannot flag an undeclared slot:
  # it stores one value per GRID position and the run past `ngrid` is padding.
  list(tuples = lay$grid$tuples[seq_len(k), , drop = FALSE][keep, , drop = FALSE],
       vals = vals[keep], rows = which(keep), extra = 0L, extra_nz = 0L)
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
    # The extent is measured against the run the PRESENCE RECORD declares (its
    # full popcount); the grid's popcount is only how many of those values this
    # layout claims a cell for, and it is the capacity bound below. Measuring the
    # extent against the grid instead made a page carrying values at undeclared
    # member slots look like a 44-byte trailing gap and rejected the whole file
    # (the Business-Register PRSIC2june2001).
    nvf <- ivt_f2_record_popcount(raw, off + 4L, lay$rec_bytes)
    if (nvf == 0L) next
    nv <- sum(ivt_f2_record_present(raw, off + 4L, lay$rec_bytes, lay$grid$bit))
    end <- 4L + lay$rec_bytes + tr + nvf * w
    if (end > s1 || off + end > n || nv > cap) return(FALSE)
    # Exact fit is the norm for pages that carry no auxiliary head and no
    # suppression tail: b2 == 0 (no trailer) AND b3 == 0x08 (head = 0). Pages
    # with a head block (b3 >= 0x09) may append a per-(geo, outer-dim) missing-
    # cell mask / allocation slack after the dense value run, so only the <=
    # extent bound applies -- the 2006 census vintage (97-563) does this on its
    # b3 >= 0x0a pages, and the 2001 profile lineage (95F0490) already on its
    # b3 == 0x09 pages (8-80 byte tails). Even some b2==0/b3==08 pages carry a
    # small ALLOCATION-PADDING tail: the 04-gen UCR survey crosstab lineage
    # (table_5_c-ivt-2008) 32-byte-aligns each page, leaving a 0-32 byte gap after
    # the value run. So require no overrun and only a modest (<= 32 byte)
    # undershoot rather than strict equality. Decoding stays presence-
    # authoritative (exactly popcount values read from vstart), so the tail never
    # affects it, and the bound keeps a misread width/count (which throws `end`
    # far off, or overruns) still caught.
    if (b2 == 0x00L && b3 <= 0x08L && (end > s1 || s1 - end > 32L)) return(FALSE)
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
  # The top of that range is computed in DOUBLE and checked for addressability
  # before use: a descriptor misread into a cartesian past 32-bit byte addressing
  # cannot be a directory this container holds, so it is a clean unsupported
  # verdict -- not an integer-overflow NA propagating into `ivt_dir_entry()`.
  ktop <- as.numeric(ocount) * as.numeric(ostride) - 1
  if (!ivt_entry_addressable(ktop, idx0)) return(FALSE)
  ktop <- as.integer(ktop)
  hi_k <- -1L
  for (k in ktop:max(0L, ktop - 65535L)) {
    en <- ivt_dir_entry(raw, idx0 + 8L * k, n)
    if (!is.null(en) && en$marker) { hi_k <- k; break }
  }
  if (!(hi_k >= 0L && (hi_k %/% ostride + 1L) * 2L > ocount)) return(FALSE)
  # Extent guard against an UNMODELLED directory that overshoots the layout's
  # cartesian. The highest entry index the model can address is the outermost
  # dimension's last member at its stride; a directory that carries valid entries
  # at DOUBLE that (a directory whose window packing this layout does not model,
  # e.g. a multi-in-page-dim straddle) would otherwise silently decode only the
  # first half. Probe the doubled outer corner: a valid marker there means the
  # nesting is wrong -> reject as unsupported (a directory padded past the pow2
  # cartesian by a DECLARED slot allocation already carries those slots in
  # `estride`, so its doubled-again corner is past the real directory and stays
  # clear).
  # The doubled corner is by construction past the modelled cartesian, so it can
  # itself be unaddressable on a legitimately large layout; that is not evidence
  # against the nesting -- it means there is no entry there, exactly as a NULL
  # read below.
  kp <- 2 * (as.numeric(ocount) - 1) * as.numeric(ostride)
  if (ivt_entry_addressable(kp, idx0)) {
    ov <- ivt_dir_entry(raw, idx0 + 8L * as.integer(kp), n)
    if (!is.null(ov) && ov$marker) return(FALSE)
  }
  TRUE
}

# Tell a directory entry that points at a REAL value page we cannot decode
# (genuine data loss -- warn loudly) apart from one whose bytes only
# COINCIDENTALLY parse as an entry. The latter arises when a SPARSE directory is
# over-walked: cartesian coordinates for absent (geography, data) combinations
# resolve, via `ivt_dir_entry()`'s size-agreement test, onto codebook blocks or
# member-label text elsewhere in the file. The Canadian Business Patterns CDNAIC
# location crosstabs are the case in point (e.g. CDNAIC3_LOC-1: 314 geographies x
# 209 sub-sector windows = 65 626 coordinates over a directory only ~282 pages
# deep -- 20 523 coordinates land on `01 01`/`81 01`/text bytes, only 644 distinct
# offsets, NONE a real page; verified via byte-exact employment-size additivity).
# The four marker bytes alone cannot separate them: a codebook `84 01 00 02`
# shares b0/b1 with an int32 value page, and BOTH a codebook block and a page with
# a novel/doctored head byte have a b3 outside {08..0e}. So validate the PAGE
# GEOMETRY instead -- the target must be a value page in b0 (recognised width
# nibble, page high nibble) and b1, whose fixed presence record AND its tightest
# possible value run (trailer/head = 0) fit the entry's allocated size. A real
# page fits by construction (its full `4 + rec_bytes + trailer + head + nv*width`
# is <= size, so the minimal bound holds a fortiori) even when its marker is
# unrecognised; a codebook block does not (its allocation is far below
# `4 + rec_bytes`, or the presence bits overrun it). This keeps the loud
# `canivt_skipped_pages` tripwire for a genuinely undecodable page (the doctored
# 98-400-X2016203 test) while silencing the sparse-directory false alarms.
ivt_skip_is_lost_page <- function(raw, off, size, lay, n = length(raw)) {
  if (as.integer(raw[off + 2L]) != 0x01L) return(FALSE)      # not a page/block head
  b0 <- as.integer(raw[off + 1L])
  w <- bitwAnd(b0, 0x0FL); hi <- bitwAnd(b0, 0xF0L)
  if (!(w %in% IVT_MARKER_WIDTHS) || !(hi %in% c(0x80L, 0xa0L))) return(FALSE)
  rb <- lay$rec_bytes
  if (off + 4L + rb > n || 4L + rb > size) return(FALSE)      # presence record must fit
  nv <- sum(ivt_f2_record_present(raw, off + 4L, rb, lay$grid$bit))
  nv > 0L && 4L + rb + nv * w <= size                         # tightest value run fits
}

#' Decode every cell of an IVT into a tibble of one value per row.
#'
#' One 1-based member-id column per dimension in descriptor order (named by the
#' structural slugs; the geography dimension's column is `geo`, which need not
#' be first -- the 1981 profile stores geography last), and `value`. Only
#' non-zero cells are stored.
#'
#' `missing = TRUE` additionally reads each page's cell-status tail (`status.R`)
#' and returns, as the `"missing"` attribute, the coordinates of the cells the
#' file marks as NOT AVAILABLE -- the absent cells its 1-bit mask does *not*
#' flag as genuine zeros. Off by default: it costs a second presence read per
#' page, and its completeness depends on the vintage (pages with no tail, with a
#' `0xa` reason-code array, or with an unaccountable tail contribute nothing, and
#' say so loudly).
#'
#' `complete = TRUE` (which implies `missing`) returns the **published table**
#' instead of the store: one row per real grid coordinate, with `value` carrying
#' the published zero where a cell is absent and the file says nothing about it,
#' `NA` where the file states a reason, and `symbol` / `status` naming that
#' reason. See `ivt_complete_cells()` (`complete.R`) for the classification.
#' @keywords internal
#' @noRd
ivt_decode <- function(raw, lay = NULL, missing = FALSE, complete = FALSE) {
  if (is.null(lay)) lay <- ivt_layout(raw)
  if (isTRUE(complete)) {
    missing <- TRUE                 # the tail is what separates zero from missing
    ivt_complete_budget(lay)
  }
  n <- length(raw); idx0 <- ivt_idx0(raw)
  m <- lay$n_dim; straddle <- lay$straddle; ipc1 <- lay$ipc[1L]
  ne <- length(lay$ent_counts)

  # Same addressability check the pre-flight makes, before the cartesian is
  # materialised: `ivt_decode()` is reachable without the gate (directly, or via
  # a caller that supplies `lay`), and an unaddressable layout would otherwise
  # coerce to NA in `eidx` below and read the directory at an NA offset.
  if (!ivt_entry_addressable(
        sum((as.numeric(lay$ent_counts) - 1) * as.numeric(lay$estride)), idx0))
    stop("page-directory cartesian exceeds the addressable directory extent ",
         "-- descriptor misread")

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

  # Map a page's in-page `tuples` to full member-id coordinates for directory
  # entry `r`. Straddle / paged coordinates are SLOT ids at this point (the
  # in-page grid already maps slots to member ids through its bit positions), so
  # this also returns the `keep` mask -- slot-aware dimensions' deleted holes and
  # padding fall out as NA -- and, per slot-aware dimension, which rows were bad,
  # so the caller can tally the values lost at deleted slots.
  coords_of <- function(tuples, r) {
    np <- nrow(tuples)
    md <- matrix(0L, np, m)
    for (t in seq_along(inpage_dim)) {
      di <- inpage_dim[t]
      md[, di] <- if (di == straddle) win_col[r] * ipc1 + tuples[, t] else tuples[, t]
    }
    if (length(paged_dim)) for (t in seq_along(paged_dim))
      md[, paged_dim[t]] <- paged_member[r, t] + 1L
    keep <- rep(TRUE, np); bads <- list()
    for (j in unique(c(straddle, paged_dim))) {
      sp <- lay$slot_pos[[j]]
      if (!is.null(sp)) {
        mid <- match(md[, j], sp)
        bad <- is.na(mid)
        if (any(bad)) bads[[length(bads) + 1L]] <- bad
        keep <- keep & !bad
        md[, j] <- ifelse(bad, 1L, mid)             # placeholder; rows filtered by keep
      } else if (j == straddle) {
        # drop the straddle's window-padding tail beyond its member count
        keep <- keep & md[, j] <= lay$counts[j]
      }
    }
    list(md = md, keep = keep, bads = bads)
  }

  # The `keep` half of `coords_of()` alone, for complete mode: the window block
  # has already resolved which grid rows this entry keeps, and `ent_ok` the
  # paged half, so no coordinate matrix has to be built to find out.
  keep_of <- function(rows, r) {
    if (!ent_ok[r]) return(logical(length(rows)))
    win_blk[[win_col[r] + 1L]]$pos[rows] > 0L
  }

  md_acc <- vector("list", nrow(coord)); v_acc <- vector("list", nrow(coord)); ci <- 0L
  ncoord <- nrow(coord)
  unclassified <- 0
  gtup <- lay$grid$tuples; ngrid <- nrow(gtup)

  # --- complete mode: the published grid is known before a page is read -------
  # Every directory entry contributes the SAME block of grid rows, differing only
  # by which straddle window it carries and by one scalar member id per paged
  # dimension. So there are `window_count` distinct coordinate blocks, not one
  # per entry, and the whole output can be sized and allocated up front -- the
  # entry loop then only scatters values into it. (Recomputing the block per
  # entry, which is what `coords_of()` does, was a quarter of the runtime and
  # held two copies of the coordinate columns at once.)
  win_blk <- NULL; pg_val <- NULL; ent_ok <- NULL; ent_base <- NULL
  out_v <- NULL; out_cd <- NULL; n_pt <- 0L; blk_len <- 0L; ok_pt <- NULL
  if (complete) {
    win_blk <- lapply(seq_len(lay$ent_counts[1L]) - 1L, function(w) {
      md <- matrix(0L, ngrid, m)
      for (t in seq_along(inpage_dim)) {
        di <- inpage_dim[t]
        md[, di] <- if (di == straddle) w * ipc1 + gtup[, t] else gtup[, t]
      }
      # Same test `coords_of()` applies to the straddle: a declared slot map
      # resolves bit positions to member ids, otherwise the window's padding tail
      # past the member count falls away.
      sp <- lay$slot_pos[[straddle]]
      if (!is.null(sp)) {
        mid <- match(md[, straddle], sp)
        keep <- !is.na(mid)
        md[, straddle] <- ifelse(keep, mid, 1L)
      } else {
        keep <- md[, straddle] <= lay$counts[straddle]
      }
      rows <- which(keep)
      pos <- integer(ngrid); pos[rows] <- seq_along(rows)
      # A window that keeps the whole grid -- every full window of an unpadded
      # straddle, i.e. most pages of most tables -- needs no position lookup at
      # all: a grid row IS its offset in the block.
      list(n = length(rows), pos = pos, full = length(rows) == ngrid,
           # A row the straddle's SLOT MAP drops sits at a deleted slot; one the
           # member-count cap drops is window padding. Only the former is a hole,
           # so only the former can lose a value worth reporting.
           bad = if (!is.null(sp)) !keep else NULL,
           cols = lapply(inpage_dim, function(di) md[rows, di]))
    })
    # The paged dimensions contribute one member id per entry, so their validity
    # is an entry-level yes/no -- resolved for the whole cartesian at once.
    ent_ok <- rep(TRUE, ncoord); ent_bad <- integer(ncoord)
    if (length(paged_dim)) {
      pg_val <- matrix(0L, ncoord, length(paged_dim))
      for (t in seq_along(paged_dim)) {
        v <- paged_member[, t] + 1L
        sp <- lay$slot_pos[[paged_dim[t]]]
        if (!is.null(sp)) {
          mid <- match(v, sp)
          ent_ok <- ent_ok & !is.na(mid)
          ent_bad <- ent_bad + is.na(mid)         # holes counted per dimension
          v <- ifelse(is.na(mid), 1L, mid)
        }
        pg_val[, t] <- v
      }
    }
    # The entry cartesian runs the straddle window FASTEST, so the emitted rows
    # are the same window run -- every window's block, in order -- repeated once
    # per paged-member tuple. An entry's output offset is therefore arithmetic,
    # and the coordinate columns are plain `rep()` patterns built once at the
    # end: nothing about a coordinate has to be written per entry, per page or
    # per cell. The loop only scatters the cells that are NOT the published zero.
    nwin <- lay$ent_counts[1L]
    nblk <- vapply(win_blk, `[[`, 0L, "n")
    win_off <- c(0L, cumsum(nblk))[seq_len(nwin)]
    blk_len <- sum(nblk)
    # A paged tuple's validity does not depend on the window, so it is one bit
    # per tuple; an invalid tuple emits nothing and the rest close up behind it.
    ok_pt <- ent_ok[seq.int(1L, ncoord, by = nwin)]
    n_pt <- sum(ok_pt)
    nout <- as.numeric(blk_len) * n_pt
    ent_base <- (cumsum(ok_pt) - 1L)[(seq_len(ncoord) - 1L) %/% nwin + 1L] *
      as.numeric(blk_len) + win_off[win_col + 1L]
    # Integer offsets where the grid fits one, so the scatter below indexes with
    # an integer vector rather than paying a double-to-index conversion per cell.
    if (nout <= .Machine$integer.max) ent_base <- as.integer(ent_base)
    out_v <- numeric(nout); out_cd <- integer(nout)
  }
  skipped_off <- integer(0); skipped_ex <- character(); hole_vals <- 0L
  extra_vals <- 0L; extra_nz <- 0L
  miss_acc <- list(); miss_st <- list(); miss_sy <- list(); mi <- 0L
  st_tally <- c(mask = 0L, none = 0L, status = 0L, unreadable = 0L,
                extra = 0L, nan_words = 0L, contradictory = 0L, beyond = 0L,
                status_unread = 0L, status_unknown = 0L)
  unk_tal <- integer(IVT_STATUS_NCODE)         # cells per UNINTERPRETED code
  # What the file itself says its reason codes mean. The numbering is per-file,
  # so this -- not a constant -- is what names a code; the NDM vocabulary is
  # kept only as a loud fallback for a file that declares no legend.
  leg <- if (missing) ivt_f2_status_legend(raw) else NULL
  leg_declared <- !is.null(leg)
  if (!leg_declared) leg <- list(text_en = IVT_STATUS_VOCAB,
                                 symbol = IVT_STATUS_SYMBOLS)
  leg_txt <- leg$text_en; leg_sym <- leg$symbol
  for (r in seq_len(nrow(coord))) {
    # Complete mode has to emit a row for every coordinate this entry covers even
    # when the entry carries no page at all -- a geography the file never wrote
    # is still published, as zeros. So the per-entry body runs inside a
    # single-pass `repeat`, where the old `next` becomes `break`, and the grid
    # rows are emitted afterwards from whatever the body managed to establish:
    # `pg` (the values), `fr`/`fc` (the reason-coded rows), `unk` (a page whose
    # own statement we could not read, so its absences are not classified).
    pg <- NULL; fr <- integer(0); fc <- integer(0); undet <- FALSE
    pres <- NULL                      # the status read's presence record, reused
    nvf <- NULL                       # ... and its popcount
    repeat {
    en <- ivt_dir_entry(raw, idx0 + eidx[r] * 8L, n)
    if (is.null(en)) break
    off <- en$off; s1 <- en$size
    if (!en$marker) {
      # A directory entry whose target is a REAL value page we cannot decode is
      # genuine data loss and must warn loudly. But a sparse, over-modelled
      # directory (the CDNAIC location crosstabs) resolves absent coordinates onto
      # codebook/text bytes that only coincidentally parse as an entry; those are
      # NOT lost pages. Count an entry only when its target validates as a page by
      # GEOMETRY (`ivt_skip_is_lost_page()`), and dedupe by offset so the tally is
      # distinct lost pages, not the (many) coordinates that address each one.
      if (ivt_skip_is_lost_page(raw, off, s1, lay, n) && !(off %in% skipped_off)) {
        skipped_off <- c(skipped_off, off)
        ex <- paste(sprintf("%02x", as.integer(raw[off + 1:4])), collapse = " ")
        if (!ex %in% skipped_ex) skipped_ex <- c(skipped_ex, ex)
        undet <- TRUE                 # a real page we cannot read says nothing
      }
      break
    }
    # The cell-status tail, read BEFORE the value decode: a wholly-suppressed
    # page carries no values at all (`ivt_decode_page()` returns NULL) yet its
    # mask still says which of its absent cells are missing rather than zero.
    if (missing) {
      # Counted once per page and handed to both readers: the status tail and
      # the value run are both sized by the presence record's popcount.
      if (as.integer(raw[off + 1L]) >= 0x80L)
        nvf <- ivt_f2_record_popcount(raw, off + 4L, lay$rec_bytes)
      st <- ivt_page_status(raw, off, lay, s1, nvf = nvf)
      st_tally[[st$kind]] <- st_tally[[st$kind]] + 1L
      st_tally[["extra"]] <- st_tally[["extra"]] + st$extra_words
      st_tally[["nan_words"]] <- st_tally[["nan_words"]] + st$nan_words
      if (st$kind == "mask") {
        mb <- ivt_mask_bits(st$mask_bytes, lay$grid$bit)
        pres <- ivt_f2_record_present(raw, off + 4L, lay$rec_bytes, lay$grid$bit)
        pr <- pres
        # A masked cell that CARRIES a value contradicts the model (masked means
        # "absent and a genuine zero"). On float64 pages it is the x87 quieting
        # artefact -- the destroyed bit sits in a NaN-shaped word -- and the page
        # is still usable, one status bit poorer. Anywhere else the mask is not
        # what we think it is, so the page contributes nothing.
        if (any(mb & pr) && st$nan_words == 0L) {
          st_tally[["contradictory"]] <- st_tally[["contradictory"]] + 1L
          undet <- TRUE
        } else {
          rows <- which(!pr & !mb)
          # -1 is "missing, reason unstated": the mask says a cell is not a zero,
          # never why. It is a code slot no legend can occupy, so it cannot
          # collide with a stated reason.
          if (complete) { fr <- rows; fc <- rep(-1L, length(rows)) }
          if (length(rows)) {
            # Complete mode carries the same cells in the grid itself, so it
            # takes the tallies and skips the second copy -- and with them the
            # coordinate build, since the window block already knows which grid
            # rows this entry keeps.
            kp <- if (complete) keep_of(rows, r) else NULL
            cc <- if (complete) NULL
                  else coords_of(lay$grid$tuples[rows, , drop = FALSE], r)
            if (is.null(kp)) kp <- cc$keep
            if (any(kp)) {
              if (!complete) {
                mi <- mi + 1L
                miss_acc[[mi]] <- cc$md[kp, , drop = FALSE]
                # The mask says a cell is missing, never WHY.
                miss_st[[mi]] <- rep(NA_character_, sum(kp))
                miss_sy[[mi]] <- rep(NA_character_, sum(kp))
              }
              st_tally[["beyond"]] <- st_tally[["beyond"]] +
                sum(lay$grid$bit[rows][kp] >= st$covered_bits)
            }
          }
        }
      } else if (st$kind == "status" && !is.null(st$codes)) {
        pres <- ivt_f2_record_present(raw, off + 4L, lay$rec_bytes, lay$grid$bit)
        pr <- pres
        # A cell that CARRIES a value must be code 0: it is neither a filler nor
        # missing. Anywhere else the array is not what we think it is, so the
        # page contributes nothing (0 pages corpus-wide).
        if (any(st$codes[pr] != 0L)) {
          st_tally[["contradictory"]] <- st_tally[["contradictory"]] + 1L
          undet <- TRUE
        } else {
          # Code 1 says "nothing here" and the GRID says which nothing: at a
          # padded position it is filler, at a real cell it is `..`. That is
          # exactly the test `coords_of()` already applies, so the two separate
          # themselves without the codes being read a second time.
          rows <- which(!pr & st$codes > 0L)
          if (complete) { fr <- rows; fc <- st$codes[rows] }
          if (length(rows)) {
            kp <- if (complete) keep_of(rows, r) else NULL
            cc <- if (complete) NULL
                  else coords_of(lay$grid$tuples[rows, , drop = FALSE], r)
            if (is.null(kp)) kp <- cc$keep
            if (any(kp)) {
              cd <- st$codes[rows][kp]
              md <- if (complete) NULL else cc$md[kp, , drop = FALSE]
              # Codes the legend does not name are counted, never guessed at:
              # they contribute no missing cell and are reported loudly.
              unk <- cd > length(leg_txt) | is.na(leg_txt[cd])
              if (any(unk)) {
                st_tally[["status_unknown"]] <-
                  st_tally[["status_unknown"]] + sum(unk)
                unk_tal <- unk_tal + tabulate(cd[unk] + 1L, IVT_STATUS_NCODE)
                cd <- cd[!unk]
                if (!complete) md <- md[!unk, , drop = FALSE]
              }
              if (length(cd) && !complete) {
                mi <- mi + 1L
                miss_acc[[mi]] <- md
                miss_st[[mi]] <- leg_txt[cd]
                miss_sy[[mi]] <- leg_sym[cd]
              }
            }
          }
        }
      } else if (st$kind == "status") {
        st_tally[["status_unread"]] <- st_tally[["status_unread"]] + 1L
        undet <- TRUE
      } else if (st$kind == "unreadable") {
        undet <- TRUE
      }
    }
    pg <- ivt_decode_page(raw, off, lay, size = s1, pres = pres, nvf = nvf)
    if (is.null(pg)) break
    extra_vals <- extra_vals + pg$extra; extra_nz <- extra_nz + pg$extra_nz
    # Complete mode addresses the grid by position, so it never builds the
    # per-page coordinate matrix -- it only needs the same deleted-slot tally,
    # which the window block and the entry's paged members already carry.
    if (complete) {
      if (ent_bad[r] > 0L)
        hole_vals <- hole_vals + ent_bad[r] * sum(pg$vals != 0)
      hb <- win_blk[[win_col[r] + 1L]]$bad
      if (!is.null(hb)) hole_vals <- hole_vals + sum(pg$vals[hb[pg$rows]] != 0)
      break
    }
    # A value at a deleted slot would be a format misunderstanding -- counted
    # and reported loudly below.
    cc <- coords_of(pg$tuples, r)
    md <- cc$md; keep <- cc$keep; vv <- pg$vals
    for (bad in cc$bads) hole_vals <- hole_vals + sum(vv[bad] != 0)
    if (!all(keep)) { md <- md[keep, , drop = FALSE]; vv <- vv[keep] }
    if (!nrow(md)) break
    ci <- ci + 1L; md_acc[[ci]] <- md; v_acc[[ci]] <- vv
    break
    }
    if (complete && ent_ok[r]) {
      blk <- win_blk[[win_col[r] + 1L]]
      nb <- blk$n
      if (nb > 0L) {
        # `out_v` opens as zeros -- the published value of an absent, unremarked
        # cell -- so only the stored values and the flagged cells are written.
        b <- ent_base[r]; nknown <- 0L
        if (!is.null(pg)) {
          if (blk$full) {
            out_v[b + pg$rows] <- pg$vals; nknown <- nknown + length(pg$rows)
          } else {
            pp <- blk$pos[pg$rows]; ok <- pp > 0L
            out_v[b + pp[ok]] <- pg$vals[ok]; nknown <- nknown + sum(ok)
          }
        }
        if (length(fr)) {
          # Only the reason code is scattered; a flagged cell never carries a
          # value, so `value = NA` follows from `code != 0` and is written for
          # the whole grid in one pass after the loop.
          if (blk$full) {
            out_cd[b + fr] <- fc; nknown <- nknown + length(fr)
          } else {
            pf <- blk$pos[fr]; ok <- pf > 0L
            out_cd[b + pf[ok]] <- fc[ok]; nknown <- nknown + sum(ok)
          }
        }
        if (undet) {
          # The page wrote a statement we could not read, so its absences are
          # published as zeros without the file having said so -- counted here
          # and reported loudly, never folded in silently.
          unclassified <- unclassified + (nb - nknown)
        }
      }
    }
  }
  skipped <- length(skipped_off)
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
  # Values the presence records flagged at slots BEYOND the members the codebook
  # declares -- never-allocated positions with no member id, no code and no label,
  # so there is no cell to put them in. They are dropped, loudly: an undeclared
  # slot carrying data could equally mean the member count was read short.
  if (extra_vals > 0L) {
    ivt_fallback(paste(
      "{extra_vals} stored value{?s} ({extra_nz} non-zero) sat at member slots the",
      "codebook does not declare; {?it was/they were} dropped."),
      class = "canivt_undeclared_slot")
  }

  if (complete) {
    if (unclassified > 0)
      ivt_fallback(paste(
        "{unclassified} absent cell{?s} sit{?s/} on pages whose own cell-status",
        "statement could not be read; {?it is/they are} published as zeros",
        "without the file having said so."),
        class = "canivt_absent_unclassified")
    # The coordinates, at last: an in-page dimension repeats its window run once
    # per emitted paged tuple, a paged dimension holds one member id for a whole
    # run. Neither depends on anything a page said, so both are built here in one
    # `rep()` each rather than accumulated a page at a time.
    out_v[out_cd != 0L] <- NA_real_        # every flagged cell, in one pass
    out_cols <- vector("list", m)
    for (t in seq_along(inpage_dim)) {
      v <- unlist(lapply(win_blk, function(b) b$cols[[t]]), use.names = FALSE)
      out_cols[[inpage_dim[t]]] <- rep(if (is.null(v)) integer(0) else v,
                                       times = n_pt)
    }
    for (t in seq_along(paged_dim))
      out_cols[[paged_dim[t]]] <-
        rep(pg_val[seq.int(1L, ncoord, by = lay$ent_counts[1L]), t][ok_pt],
            each = blk_len)
    return(ivt_complete_cells(out_cols, out_v, out_cd, lay, st_tally,
                              unk_tal, leg_declared,
                              if (leg_declared) leg else NULL))
  }
  if (ci == 0L) {
    out <- tibble::tibble(.rows = 0L)
    for (j in seq_len(m)) out[[lay$slugs[j]]] <- integer(0)
    out$value <- numeric(0)
  } else {
    cols <- do.call(rbind, md_acc[seq_len(ci)])
    out <- tibble::tibble(.rows = nrow(cols))
    for (j in seq_len(m)) out[[lay$slugs[j]]] <- cols[, j]
    out$value <- unlist(v_acc[seq_len(ci)], use.names = FALSE)
  }
  if (missing)
    attr(out, "missing") <-
      ivt_missing_cells(miss_acc, miss_st, miss_sy, mi, lay, st_tally, unk_tal,
                        leg_declared, if (leg_declared) leg else NULL)
  out
}

# Assemble the missing-cell coordinates and report, loudly, everything the read
# could NOT account for. The status tail is the file's own statement of which
# absent cells are zeros, so a page that does not yield one leaves its absent
# cells UNCLASSIFIED -- silently returning "no missings there" would be exactly
# the false "absent implies zero" model this decode exists to correct.
ivt_missing_cells <- function(miss_acc, miss_st, miss_sy, mi, lay, tally,
                              unk_tal = integer(IVT_STATUS_NCODE),
                              leg_declared = TRUE, legend = NULL) {
  m <- lay$n_dim
  if (mi == 0L) {
    out <- tibble::tibble(.rows = 0L)
    for (j in seq_len(m)) out[[lay$slugs[j]]] <- integer(0)
    out$symbol <- character(0); out$status <- character(0)
  } else {
    cols <- do.call(rbind, miss_acc[seq_len(mi)])
    out <- tibble::tibble(.rows = nrow(cols))
    for (j in seq_len(m)) out[[lay$slugs[j]]] <- cols[, j]
    # The REASON, where the file states one: only the `0xa` status array carries
    # reason codes, so a mask-derived missing is NA -- missing, cause unstated.
    out$symbol <- unlist(miss_sy[seq_len(mi)], use.names = FALSE)
    out$status <- unlist(miss_st[seq_len(mi)], use.names = FALSE)
  }
  ivt_status_report(tally, unk_tal, leg_declared, nrow(out))
  attr(out, "pages") <- tally
  attr(out, "legend") <- legend
  out
}

# Everything the cell-status read could not account for, reported loudly. Shared
# by the sparse (`missing = TRUE`) and complete paths so the two can never
# disagree about what was left unsaid. `unclassified` selects the wording: the
# sparse path leaves a tail-less page's absences UNCLASSIFIED, while the complete
# path has already published them as zeros (validated against StatCan's own CSV:
# a page writes no tail exactly when it has nothing to flag) and reports only the
# pages whose written statement could not be read.
ivt_status_report <- function(tally, unk_tal, leg_declared, n_missing,
                              unclassified = TRUE) {
  # A `0xa` array whose meaning the file does not state. The NDM vocabulary is
  # right for the census lineage and demonstrably wrong for others (the 2016
  # `98-400-X` legend shifts every symbol by one), so naming a code from it is
  # a guess and says so.
  if (!leg_declared && tally[["status"]] > 0L) {
    ivt_fallback(paste(
      "the file declares no cell-status legend (header slot 698), so the",
      "{tally[['status']]} self-describing (0xa) status array{?s} {?was/were}",
      "named from the validated NDM census vocabulary; another lineage numbers",
      "the same symbols differently, so treat `status` as unconfirmed."),
      class = "canivt_status_legend")
  }
  n_un <- tally[["none"]] + tally[["unreadable"]] + tally[["contradictory"]]
  if (unclassified && n_un > 0L) {
    ivt_fallback(paste(
      "{n_un} page{?s} carr{?ies/y} no readable cell-status tail",
      "({tally[['none']]} with no tail, {tally[['unreadable']]} whose index does",
      "not account for the tail, {tally[['contradictory']]} whose status bits",
      "contradict the values); their absent cells are NOT classified, so the",
      "missing-cell list is",
      "incomplete for {?that page/those pages}."),
      class = "canivt_status_unreadable")
  }
  if (tally[["status_unread"]] > 0L) {
    ivt_fallback(paste(
      "{tally[['status_unread']]} of {tally[['status']]} self-describing (0xa)",
      "cell-status array{?s} carr{?ies/y} a header this reader does not",
      "recognise; {?it was/they were} not read, so {?that page contributes/those",
      "pages contribute} no missing cells."),
      class = "canivt_status_unread")
  }
  # Reason codes above the validated vocabulary. The addressing is sound (they
  # sit at real absent cells, on pages whose present cells all read code 0), but
  # what they SAY is unknown, so they are counted and named rather than folded
  # into `status` under a guessed label.
  if (tally[["status_unknown"]] > 0L) {
    inv <- paste0(which(unk_tal > 0L) - 1L, ": ", unk_tal[unk_tal > 0L],
                  collapse = ", ")
    ivt_fallback(paste(
      "{tally[['status_unknown']]} absent cell{?s} carr{?ies/y} a (0xa) reason",
      "code the file's own status legend does not name, so {?it is/they are}",
      "NOT interpreted and {?is/are} absent from the missing-cell list; codes",
      "seen (code: cells): {inv}."), class = "canivt_status_code_unknown")
  }
  if (tally[["extra"]] > 0L) {
    ivt_fallback(paste(
      "{tally[['extra']]} tail word{?s} sit past the absent mask (a second,",
      "UNDECODED block that shares the page's word index); {?it was/they were}",
      "ignored."), class = "canivt_status_extra_block")
  }
  if (tally[["beyond"]] > 0L) {
    ivt_fallback(paste(
      "{tally[['beyond']]} of the {n_missing} missing cell{?s} sit{?s/} past the",
      "reach of {?its/their} page's word INDEX: the file has no bit with which to",
      "classify {?it/them}, so {?it is/they are} reported missing without the file",
      "saying so -- treat {?this cell/these cells} as unconfirmed."),
      class = "canivt_status_beyond_mask")
  }
  # A faithful read of a source-side loss, not a heuristic: the writer's x87
  # quieting destroyed one mask bit per NaN-shaped word IN THE FILE, so up to
  # that many missing cells read as genuine zeros and cannot be recovered.
  if (tally[["nan_words"]] > 0L) {
    ivt_source_truncation(paste(
      "{tally[['nan_words']]} absent-mask word{?s} {?is/are} NaN-shaped in the",
      "page's value type: the writer quiets signalling NaNs, which overwrites one",
      "status bit per such word in the SOURCE FILE. Up to {tally[['nan_words']]}",
      "cell{?s} may be missing rather than zero and cannot be told apart."),
      class = "canivt_status_nan_quieted")
  }
  invisible(NULL)
}
