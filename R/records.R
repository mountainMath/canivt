# Zero-suppressed fixed-width records: the storage of every `81 01` / `81 02`
# block the master directory lists (ivt-format.md, "Zero-suppressed records").
#
#     81 01 <u16 nbytes>               <mask> <stored bytes>    one record
#     81 02 <u16 nrec> <u16 recbytes>  <mask> <stored bytes>    nrec records
#
# The mask carries one bit per record byte (`nrec * recbytes` of them), in the
# same order as the presence bitmap of a value page: bytes PAIR-SWAPPED, bits
# MSB-first, the mask padded to a whole number of 16-bit words. A set bit means
# the byte is stored; a clear bit means the byte is zero and was not written. The
# stored bytes follow the mask in record order.
#
# So a block's length is a function of its content, and three things can be
# checked exactly: the padding bits past the last record byte are zero, no
# stored byte is zero (it would have been suppressed), and the block ends where
# its directory entry says. Over the corpus all 790 such blocks fit (313 `81 02`,
# 477 `81 01`).
#
# What looked like free-form text with irregular framing is this storage seen
# without its mask: a title block's three strings run together because the NULs
# between them are suppressed; a dimension record's "doubled name" is two
# separate fixed fields; a u16-looking count is a u32 whose high bytes are zero;
# the "missing `01` separator" of a geography record is a flag field that is 0.

# Unpack `nbytes` zero-suppressed bytes whose mask starts at 0-based `off`.
# Returns list(bytes = <integer nbytes>, end = <0-based offset past the stored
# bytes>), or NULL when the block does not fit exactly (truncated, a padding bit
# set, or a stored zero).
ivt_zs_unpack <- function(raw, off, nbytes) {
  n <- length(raw)
  if (is.na(off) || is.na(nbytes) || off < 0L || nbytes < 1L) return(NULL)
  mlen <- 2L * as.integer(ceiling(nbytes / 16))
  if (off + mlen > n) return(NULL)
  m <- as.integer(raw[(off + 1L):(off + mlen)])
  m <- m[bitwXor(seq_along(m) - 1L, 1L) + 1L]              # pair-swap
  bits <- as.integer(rbind(m %/% 128L %% 2L, m %/% 64L %% 2L, m %/% 32L %% 2L,
                           m %/% 16L %% 2L, m %/% 8L %% 2L, m %/% 4L %% 2L,
                           m %/% 2L %% 2L, m %% 2L))        # MSB-first
  if (length(bits) > nbytes && any(bits[-seq_len(nbytes)] == 1L)) return(NULL)
  bits <- bits[seq_len(nbytes)]
  k <- sum(bits)
  if (off + mlen + k > n) return(NULL)
  out <- integer(nbytes)
  if (k > 0L) {
    st <- as.integer(raw[(off + mlen + 1L):(off + mlen + k)])
    if (any(st == 0L)) return(NULL)
    out[bits == 1L] <- st
  }
  list(bytes = out, end = off + mlen + k)
}

# The record block at 0-based `off`: list(kind = 1|2, nrec, recbytes, m = integer
# matrix [recbytes x nrec], end), or NULL when `off` does not open an `81 01` /
# `81 02` block that unpacks exactly. `max_bytes` bounds the declared size so a
# stray `81 0x` cannot allocate megabytes.
ivt_zs_block <- function(raw, off, max_bytes = 65536L) {
  n <- length(raw)
  if (is.null(off) || is.na(off) || off < 0L || off + 6L > n) return(NULL)
  if (raw[off + 1L] != as.raw(0x81)) return(NULL)
  kind <- as.integer(raw[off + 2L])
  if (kind == 1L) {
    nrec <- 1L; recbytes <- rd_u16(raw, off + 2L); hdr <- 4L
  } else if (kind == 2L) {
    nrec <- rd_u16(raw, off + 2L); recbytes <- rd_u16(raw, off + 4L); hdr <- 6L
  } else return(NULL)
  if (is.na(nrec) || is.na(recbytes) || nrec < 1L || recbytes < 1L ||
      as.numeric(nrec) * recbytes > max_bytes) return(NULL)
  u <- ivt_zs_unpack(raw, off + hdr, nrec * recbytes)
  if (is.null(u)) return(NULL)
  list(kind = kind, nrec = nrec, recbytes = recbytes,
       m = matrix(u$bytes, nrow = recbytes), end = u$end)
}

# A NUL-terminated string field of an unpacked record (Windows-1252 text).
ivt_zs_string <- function(b) {
  z <- which(b == 0L)
  if (length(z)) b <- b[seq_len(z[1L] - 1L)]
  if (!length(b)) return("")
  trimws(raw_to_latin1(as.raw(b)))
}

ivt_zs_u32 <- function(b) sum(b * 256^(0:3))

# ---- the title block ---------------------------------------------------------
#
# One `81 01` record: a 7-byte signature string ("FACET04" on the `04`
# generation; the `02 00 20 00` survey generation writes its own), then three
# fixed text fields -- the table title, the source ("Statistics Canada"), and the
# series / survey name. Two record sizes exist, one per container generation:
#
#     772 bytes   sig[7]  title[255]  source[255]  series[255]
#     195 bytes   sig[7]  title[60]   source[64]   series[64]
#
# The master directory lists it twice, English first and French second (rows [1]
# and [8]/[9]).
IVT_TITLE_LAYOUTS <- list(
  `772` = c(7L, 255L, 255L, 255L),
  `195` = c(7L, 60L, 64L, 64L)
)

# Every title block the master directory lists, in directory order: a list of
# list(off, signature, title, source, series). Empty when there is no master
# directory or it names no title block. Each is accepted only when the block
# unpacks to end exactly where its directory entry ends.
ivt_f2_title_blocks <- function(raw)
  ivt_memo(raw, "title_blocks", function() ivt_f2_title_blocks_impl(raw))

ivt_f2_title_blocks_impl <- function(raw) {
  md <- tryCatch(ivt_f2_master_dir(raw), error = function(e) NULL)
  out <- list()
  if (is.null(md)) return(out)
  n <- length(raw)
  for (r in seq_len(nrow(md))) {
    off <- as.integer(md[r, "off"]); len <- as.integer(md[r, "len"])
    if (is.na(off) || is.na(len) || off < 0L || off + 4L > n) next
    if (raw[off + 1L] != as.raw(0x81) || raw[off + 2L] != as.raw(0x01)) next
    lay <- IVT_TITLE_LAYOUTS[[as.character(rd_u16(raw, off + 2L))]]
    if (is.null(lay)) next
    b <- ivt_zs_block(raw, off)
    if (is.null(b) || b$end != off + len) next
    ends <- cumsum(lay); starts <- ends - lay + 1L
    f <- vapply(seq_along(lay),
                function(i) ivt_zs_string(b$m[starts[i]:ends[i], 1L]), "")
    f[!nzchar(f)] <- NA_character_
    out[[length(out) + 1L]] <- list(off = off, signature = f[1L], title = f[2L],
                                    source = f[3L], series = f[4L])
  }
  out
}

# The table title as the title block declares it: list(en, fr), each NA when the
# file names no such block. The first block is English, the second French.
ivt_f2_declared_title <- function(raw) {
  tb <- ivt_f2_title_blocks(raw)
  list(en = if (length(tb) >= 1L) tb[[1L]]$title else NA_character_,
       fr = if (length(tb) >= 2L) tb[[2L]]$title else NA_character_)
}

# ---- the dimension records block ---------------------------------------------
#
# One `81 02 <nrec> 52 00` block of 82-byte records, one per dimension, in
# descriptor order:
#
#     bytes  0- 3   u32   member count
#     bytes  4- 5   u16   type tag (a storage / classification tag, not identity)
#     bytes  6- 7   u16   class word: 0 on almost every record; where it is set
#                         it is 1 on a geography and 2 on a time dimension (28
#                         corpus dimensions). Carried as `class`, read by
#                         nothing: most geographies leave it 0, so it cannot
#                         identify one.
#     bytes  8-11   u32   flag (1 on most records, 0 on some geographies)
#     bytes 12-27   char  short name, NUL-terminated (so at most 15 characters)
#     bytes 28-77   char  description, NUL-terminated
#     bytes 78-81   u32   (unidentified)
IVT_DIMREC_BYTES <- 82L

# Locate and unpack the dimension records block. `D` is the descriptor offset
# when the caller has one. Three places, each exact:
#
#   1. a master-directory row that IS such a block and ends where its entry ends
#      (the normal case -- row [2]);
#   2. where the descriptor head at `D` ends (the head is itself an `81 01`
#      record of 32 bytes, so its end is computed, not assumed);
#   3. a block that ends exactly at `D` (the inverted layout, records first).
#
# Returns the `ivt_zs_block()` list or NULL.
ivt_f2_dimrec_block <- function(raw, D = NULL) {
  n <- length(raw)
  is_rec <- function(o)
    !is.na(o) && o >= 0L && o + 6L <= n && raw[o + 1L] == as.raw(0x81) &&
      raw[o + 2L] == as.raw(0x02) && rd_u16(raw, o + 4L) == IVT_DIMREC_BYTES &&
      rd_u16(raw, o + 2L) >= 1L && rd_u16(raw, o + 2L) <= 32L
  if (is.null(D)) {
    md <- tryCatch(ivt_f2_master_dir(raw), error = function(e) NULL)
    if (is.null(md)) return(NULL)
    for (r in seq_len(nrow(md))) {
      off <- as.integer(md[r, "off"]); len <- as.integer(md[r, "len"])
      if (!is_rec(off)) next
      b <- ivt_zs_block(raw, off)
      if (!is.null(b) && b$end == off + len) return(b)
    }
    return(NULL)
  }
  if (is.na(D) || D < 1L) return(NULL)
  D <- as.integer(D)
  if (ivt_f2_is_descriptor(raw, D)) {
    head <- ivt_zs_block(raw, D)
    if (!is.null(head) && is_rec(head$end)) {
      b <- ivt_zs_block(raw, head$end)
      if (!is.null(b)) return(b)
    }
  }
  # inverted: the smallest block is header 6 + mask 12 + a few stored bytes; the
  # largest (32 records, every byte stored) is under 3 KB
  lo <- max(0L, D - 3000L)
  if (D - lo < 20L) return(NULL)
  idx <- lo:(D - 20L)
  idx <- idx[raw[idx + 1L] == as.raw(0x81) & raw[idx + 2L] == as.raw(0x02) &
             raw[idx + 5L] == as.raw(IVT_DIMREC_BYTES) & raw[idx + 6L] == as.raw(0)]
  for (o in rev(idx)) {
    if (!is_rec(o)) next
    b <- ivt_zs_block(raw, o)
    if (!is.null(b) && b$end == D) return(b)
  }
  NULL
}

# The dimensions as the records block declares them: a list of
# list(name, count, type, double01 = FALSE, short_name, description), or NULL
# when a record carries no usable name or count.
#
# `name` is chosen from the record's own two text fields, by their relation and
# nothing else:
#   * the description, when the short name is a leading copy of it -- the
#     ordinary census record, whose short name is the first 15 characters of the
#     full name ("Household Size " / "Household Size (3)");
#   * otherwise the short name -- a custom extract's display name beside an
#     unrelated description ("CondoStat/Type" / "Condominium status and
#     structural type"), or a survey variable beside its label ("REGION" /
#     "Canada, Provinces and Territories"). A short name that fills its field
#     (15 characters) may be cut; the dimension's slot-directory name marker
#     completes it when it begins with the same 15 characters.
ivt_f2_dimrec_dims <- function(raw, b) {
  if (is.null(b) || b$recbytes != IVT_DIMREC_BYTES) return(NULL)
  slots <- NULL
  dims <- vector("list", b$nrec)
  for (k in seq_len(b$nrec)) {
    r <- b$m[, k]
    count <- ivt_zs_u32(r[1:4])
    # the type field is two u16 words: the storage tag the byte walk knew, and a
    # class word above it (see the record layout)
    type <- r[5L] + 256L * r[6L]; class <- r[7L] + 256L * r[8L]
    if (count > .Machine$integer.max) return(NULL)
    short <- ivt_zs_string(r[13:28]); desc <- ivt_zs_string(r[29:78])
    if (!nzchar(short) && !nzchar(desc)) return(NULL)
    name <- if (!nzchar(short)) desc
            else if (nzchar(desc) && startsWith(desc, short)) desc
            else short
    if (identical(name, short) && sum(r[13:28] != 0L) >= 15L) {
      if (is.null(slots)) slots <- ivt_f2_dim_slots(raw, m = 32L)
      mk <- tryCatch(ivt_f2_dim_marker_name(raw, k, slots),
                     error = function(e) NA_character_)
      if (!is.null(mk) && !is.na(mk) && nchar(mk) > nchar(short) &&
          startsWith(mk, short)) name <- trimws(mk)
    }
    dims[[k]] <- list(name = name, count = as.integer(count),
                      type = as.integer(type), class = as.integer(class),
                      double01 = FALSE,
                      short_name = if (nzchar(short)) short else NA_character_,
                      description = if (nzchar(desc)) desc else NA_character_)
  }
  dims
}
