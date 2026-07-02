#' Header per-dimension directory slot table
#'
#' The fixed header carries one 14-byte record per descriptor dimension (in
#' descriptor order, geography = dimension 1) at `@824 + 14*(k-1)`:
#'
#'     [u32 dir_ptr][u32 ?][u32 n_entries][2 bytes]
#'
#' `dir_ptr` points at that dimension's **block directory** -- a table of the
#' familiar 8-byte entries `[u32 off][u16 len][u16 len]` (the same shape as the
#' page directory) -- either directly, or (the big chunked geography directories,
#' e.g. 98-10-0023's 6,244 entries) via a small struct whose first u32 is the
#' directory pointer. `n_entries` is the entry count (the decoded table may run
#' up to a few entries short when null slots are skipped), which makes the slot
#' self-validating.
#'
#' Each dimension's directory lists that dimension's complete codebook in
#' LOGICAL order with exact offsets and lengths: its dictionary/schema block,
#' member-id table, member-ordinal block, the `81 02 02 00` doubled-name marker
#' block, then the EN member-label block, the FR member-label block, and that
#' dimension's footnotes (EN/FR pairs). This is the structure the tail-window
#' scans (`ivt_f2_marker_labels()`, `ivt_footnotes()`) reconstruct by content;
#' reading it positionally needs no windows and no adjacency heuristics, and
#' attributes each footnote to its owning dimension. Decoded and validated on
#' 98-10-0241, 98-10-0077 (7 dims), 98-10-0129 (4), 98-10-0023 and the 1991
#' legacy 1003011 (3): every data-dimension label block byte-identical to the
#' marker-anchored reader, every footnote set equal to the tail scan.
#'
#' The old `IVT_F2_DIR_SLOTS = c(824, 572, 712)` guesses were partial hits on
#' this table: `@824` is dimension 1 (geography); `@852` is dimension 3 (the
#' 4-byte-aligned probing missed the odd 14-byte-strided slots in between).
#'
#' @keywords internal
#' @noRd
NULL

IVT_HDR_DIM_SLOT0  <- 824L  # first per-dimension slot (dimension 1 = geography)
IVT_HDR_DIM_STRIDE <- 14L   # 14-byte slot records

# The per-dimension slot records, one per descriptor dimension. Returns a list of
# list(dim, slot, ptr, n_entries), or NULL when there is no descriptor / the
# header is too short.
ivt_f2_dim_slots <- function(raw) {
  d <- ivt_f2_descriptor(raw)
  # the 32-dim cap mirrors ivt_f2_decodable(): unsupported container variants
  # misread the descriptor as hundreds of dimensions.
  if (is.null(d) || is.na(d$n_dim) || d$n_dim < 1L || d$n_dim > 32L) return(NULL)
  n <- length(raw)
  out <- vector("list", d$n_dim)
  for (k in seq_len(d$n_dim)) {
    s <- IVT_HDR_DIM_SLOT0 + (k - 1L) * IVT_HDR_DIM_STRIDE
    if (s + 12L > n) return(NULL)
    out[[k]] <- list(dim = k, slot = s, ptr = rd_u32(raw, s),
                     n_entries = rd_u32(raw, s + 8L))
  }
  out
}

# Resolve dimension k's block directory from its header slot. The slot's
# `n_entries` field validates the decode: the parsed table must reach it (up to
# 4 skipped null slots) and not run past it, so a slot whose pointer means
# something else on some layout is rejected rather than misread. Tries the two
# indirection depths (slot -> directory, and slot -> struct -> directory).
# Returns the (off, len) entry matrix, or NULL.
ivt_f2_dim_dir <- function(raw, k, slots = NULL) {
  if (is.null(slots)) slots <- ivt_f2_dim_slots(raw)
  if (is.null(slots) || k < 1L || k > length(slots)) return(NULL)
  sl <- slots[[k]]
  if (is.na(sl$ptr) || sl$ptr < 1 || is.na(sl$n_entries) ||
      sl$n_entries < 1 || sl$n_entries > 1e6) return(NULL)
  want <- as.integer(sl$n_entries)
  ok <- function(d) !is.null(d) && nrow(d) <= want && nrow(d) >= max(1L, want - 4L)
  d <- ivt_f2_read_dir_at(raw, sl$ptr, max_entries = want + 4L)
  if (ok(d)) return(d)
  d <- ivt_f2_read_dir_at(raw, rd_u32(raw, sl$ptr), max_entries = want + 4L)
  if (ok(d)) d else NULL
}

# Member labels for one data dimension, read positionally from its slot
# directory. The directory lists (among framing/separator entries) the
# dimension's doubled-name marker block followed by the EN then FR member
# blocks, so the labels are the first two member-array entries after the marker
# entry: each candidate's trailing `count` records are taken (the EN block can
# carry a couple of leading framing bytes the Pascal scan misreads as records,
# e.g. 98-10-0077's Ages), and English is picked per pair by `ivt_f2_frscore()`
# over the members where the two differ (a tie means the pair is identical,
# e.g. the numeric reference-period years). The marker entry is matched to the
# dimension NAME (prefix match, as `ivt_f2_match_dim()`), so a directory that
# belongs to something else on an unknown layout yields NULL rather than wrong
# labels. Returns the label vector (untrimmed, as stored) or NULL.
ivt_f2_dim_dir_label1 <- function(raw, dim, dir) {
  cnt <- as.integer(dim$count)
  if (is.na(cnt) || cnt < 1L) return(NULL)
  nm <- dim$name
  if (is.null(nm) || is.na(nm) || !nzchar(nm)) return(NULL)
  # locate the doubled-name marker entry (81 02 02 00 + this dimension's name)
  mk <- 0L
  for (r in seq_len(nrow(dir))) {
    len <- dir[r, "len"]
    if (len < 12L || len > 4000L) next
    win <- raw[(dir[r, "off"] + 1L):min(length(raw), dir[r, "off"] + len)]
    m <- ivt_f2_codebook_dim_markers(win, 0L)
    hit <- which(vapply(m$name, function(x) {
      if (is.na(x)) return(FALSE)
      j <- min(nchar(x), nchar(nm))
      j >= 4L && substr(x, 1L, j) == substr(nm, 1L, j)
    }, logical(1)))
    if (length(hit)) { mk <- r; break }
  }
  if (mk == 0L || mk >= nrow(dir)) return(NULL)
  # the EN/FR member blocks are the first two member-array entries after it
  cand <- list()
  for (r in (mk + 1L):nrow(dir)) {
    len <- dir[r, "len"]
    if (len <= 8L || len < cnt + 4L) next          # separators / tiny framing
    win <- raw[(dir[r, "off"] + 1L):min(length(raw), dir[r, "off"] + len)]
    b <- ivt_find_member_blocks(win, 0L, min_records = 1L)
    if (!length(b)) next
    sz <- vapply(b, function(x) length(x$texts), 1L)
    bi <- which(sz >= cnt & sz <= cnt + 8L)        # the member block (+ slack for
    if (!length(bi)) next                          #   leading framing misreads)
    t <- b[[bi[length(bi)]]]$texts
    t <- t[(length(t) - cnt + 1L):length(t)]       # trailing `count` records
    if (identical(t, as.character(seq_len(cnt)))) next   # an ordinal block
    if (any(grepl("[[:cntrl:]]", t)) || !all(nzchar(t))) next  # framing garbage
    cand[[length(cand) + 1L]] <- t
    if (length(cand) == 2L) break
  }
  if (!length(cand)) return(NULL)
  if (length(cand) == 1L) return(cand[[1L]])
  diff <- which(cand[[1L]] != cand[[2L]])
  if (ivt_f2_frscore(cand[[1L]][diff]) <= ivt_f2_frscore(cand[[2L]][diff]))
    cand[[1L]] else cand[[2L]]
}

# Member labels for every dimension, read from the header slot table. Returns a
# list parallel to the descriptor dimensions (element k = dimension k's label
# vector; geography and unresolved dimensions are NULL), or NULL when the slot
# table itself is absent. Unresolved dimensions fall back to the marker/count
# scans in `ivt_f2_dimensions()`.
ivt_f2_dim_dir_labels <- function(raw) {
  d <- ivt_f2_descriptor(raw)
  if (is.null(d) || length(d$dims) < 2L) return(NULL)
  slots <- ivt_f2_dim_slots(raw)
  if (is.null(slots)) return(NULL)
  out <- vector("list", length(d$dims))
  for (k in 2:length(d$dims)) {
    dir <- ivt_f2_dim_dir(raw, k, slots)
    if (is.null(dir)) next
    out[[k]] <- ivt_f2_dim_dir_label1(raw, d$dims[[k]], dir)
  }
  out
}

# Byte span [start, end) covered by the geography dimension's block directory --
# the metadata-declared bound of the whole geography codebook (dictionary, member
# ids, ordinals, marker, label/attribute blocks, footnotes). Used to bound the
# content scans (`ivt_f2_geo_marker_region()`, and through it the DGUID byte scan)
# by the file's own metadata instead of a marker-to-marker window. Returns
# c(start, end) or NULL when dimension 1's directory does not resolve.
ivt_f2_geo_dir_span <- function(raw) {
  d <- ivt_f2_dim_dir(raw, 1L)
  if (is.null(d)) return(NULL)
  c(min(d[, "off"]), min(length(raw), max(d[, "off"] + d[, "len"])))
}

# Footnotes read from the per-dimension slot directories, each attributed to its
# owning dimension (`dimension` = the full display name when `dim_names` is
# given, else the descriptor name). Every footnote is stored as an entry of the
# directory of the dimension it annotates -- the linkage the tail text-scan
# cannot provide. `number` keeps the established semantics (position within its
# language, here in slot/directory order). Returns NULL when the slot table is
# absent (caller falls back to the tail scan); an empty list when the
# directories resolve but carry no footnotes.
ivt_f2_dir_footnotes <- function(raw, dim_names = NULL) {
  slots <- ivt_f2_dim_slots(raw)
  if (is.null(slots)) return(NULL)
  if (is.null(dim_names)) {
    d <- ivt_f2_descriptor(raw)
    dim_names <- vapply(d$dims, function(x) x$name, "")
  }
  counts <- c(en = 0L, fr = 0L)
  out <- list()
  resolved <- FALSE
  for (k in seq_along(slots)) {
    dir <- ivt_f2_dim_dir(raw, k, slots)
    if (is.null(dir)) next
    resolved <- TRUE
    for (r in seq_len(nrow(dir))) {
      len <- dir[r, "len"]
      if (len < 24L) next                          # too short to frame a footnote
      win <- raw[(dir[r, "off"] + 1L):min(length(raw), dir[r, "off"] + len)]
      # cheap byte prefilter: the text-run isolation is too slow to run over every
      # entry of a 6,000-block geography directory.
      if (!length(grepRaw("Footnote", win, fixed = TRUE)) &&
          !length(grepRaw("Renvoi", win, fixed = TRUE))) next
      fns <- ivt_footnote_texts(raw, dir[r, "off"], dir[r, "off"] + len)
      for (f in fns) {
        counts[f$language] <- counts[f$language] + 1L
        out[[length(out) + 1L]] <- list(
          language = f$language, number = counts[[f$language]], text = f$text,
          dimension = if (k <= length(dim_names)) dim_names[[k]] else NA_character_)
      }
    }
  }
  if (!resolved) return(NULL)
  out
}
