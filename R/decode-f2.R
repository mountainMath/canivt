#' IVT family-2 presence + value decode
#'
#' Each geography's presence is a fixed 64-byte record. The record is stored
#' **byte-pair-swapped** (the same principle as family 1's `bitwXor(housing, 1)`,
#' here at byte granularity): swapping each adjacent byte pair recovers a
#' positional nibble-per-member bitmap. Member `m` (1-based) is nibble `m`; within
#' a nibble the three genders Total / Men / Women occupy bits 3 / 2 / 1 (bit 0 is
#' padding), so the all-present marker is `0xE`. Values are dense little-endian
#' float64 over the present `(member, gender)` cells, in member-major,
#' gender-inner order. The store keeps only **non-zero** cells; absent cells are
#' published as zero in the StatCan CSV. See `container-f2.R` for the page layout.
#'
#' @keywords internal
#' @noRd
NULL

# Decode one 64-byte presence record at 0-based offset `ps` into the present
# (member, gender) cells, in dense value order (member 1..128 outer, gender
# Total=1, Men=2, Women=3 inner). Returns integer vectors `member` and `gender`.
ivt_f2_decode_record <- function(raw, ps) {
  rec <- as.integer(raw[(ps + 1L):(ps + IVT_F2_REC_BYTES)])
  a <- rec[seq(1L, IVT_F2_REC_BYTES, by = 2L)]   # 32 even-index bytes
  b <- rec[seq(2L, IVT_F2_REC_BYTES, by = 2L)]   # 32 odd-index bytes
  # swap each pair (a, b) -> nibbles [b>>4, b&0xf, a>>4, a&0xf]; member m = nib[m]
  nmem <- 2L * IVT_F2_REC_BYTES                  # 128 member nibbles
  nib <- integer(nmem)
  nib[seq(1L, nmem, by = 4L)] <- bitwShiftR(b, 4L)
  nib[seq(2L, nmem, by = 4L)] <- bitwAnd(b, 0x0FL)
  nib[seq(3L, nmem, by = 4L)] <- bitwShiftR(a, 4L)
  nib[seq(4L, nmem, by = 4L)] <- bitwAnd(a, 0x0FL)

  # genders Total/Men/Women at bits 3/2/1; flatten member-major, gender-inner
  pres <- rbind(bitwAnd(bitwShiftR(nib, 3L), 1L),   # Total
                bitwAnd(bitwShiftR(nib, 2L), 1L),   # Men
                bitwAnd(bitwShiftR(nib, 1L), 1L))   # Women
  present <- as.logical(pres)                       # column-major: m1T,m1M,m1W,...
  list(member = rep(seq_len(nmem), each = 3L)[present],
       gender = rep.int(1:3, nmem)[present])
}

# Decode every geography of a family-2 file into a tibble of one value per row,
# keyed by 1-based member ids: `geo` (geography), `age` (the inner data member),
# `gender`, plus `value`. (98-10-0023 is Geography x Age x Gender; the middle
# dimension is named generically `age` here but is whatever the file's second
# dimension is.)
#' @keywords internal
#' @noRd
ivt_f2_decode <- function(raw, dir = NULL) {
  if (is.null(dir)) dir <- ivt_f2_find_directory(raw)
  if (is.null(dir)) cli::cli_abort("No family-2 page directory found.")
  offsets <- dir$offsets
  P <- length(offsets)

  geo_l <- vector("list", P)
  age_l <- vector("list", P)
  gen_l <- vector("list", P)
  val_l <- vector("list", P)

  geo <- 1L
  for (p in seq_len(P)) {
    po <- offsets[p]
    m0 <- as.integer(raw[po + 1L])
    pp <- ivt_f2_page_params(m0)
    voff <- po + pp$vstart
    g_p <- integer(0); a_p <- integer(0); s_p <- integer(0); v_p <- numeric(0)
    for (i in 0:(IVT_F2_GEOS_PER_PAGE - 1L)) {
      d <- ivt_f2_decode_record(raw, po + 4L + IVT_F2_REC_BYTES * i)
      nv <- length(d$member)
      if (nv > 0L) {
        bytes <- raw[(voff + 1L):(voff + nv * pp$width)]
        vals <- if (pp$float) {
          readBin(bytes, "double", n = nv, size = 8L, endian = "little")
        } else {
          as.numeric(readBin(bytes, "integer", n = nv, size = pp$width,
                             signed = TRUE, endian = "little"))
        }
        g_p <- c(g_p, rep.int(geo, nv)); a_p <- c(a_p, d$member)
        s_p <- c(s_p, d$gender);          v_p <- c(v_p, vals)
        voff <- voff + nv * pp$width
      }
      geo <- geo + 1L
    }
    geo_l[[p]] <- g_p; age_l[[p]] <- a_p; gen_l[[p]] <- s_p; val_l[[p]] <- v_p
  }

  tibble::tibble(
    geo    = unlist(geo_l, use.names = FALSE),
    age    = unlist(age_l, use.names = FALSE),
    gender = unlist(gen_l, use.names = FALSE),
    value  = unlist(val_l, use.names = FALSE)
  )
}
