#' IVT family-2 presence + value decode (n-dimensional)
#'
#' Each geography's presence is a fixed-size record holding a **power-of-two
#' nested positional bitmap** over the table's data dimensions (every dimension
#' after Geography). The data dimensions nest outermost-to-innermost in header
#' descriptor order; each level is padded to the next power of two of (its member
#' count x the inner block size), and the innermost dimension occupies the low
#' bits. The record is stored **byte-pair-swapped** (swap each adjacent byte
#' pair) and read **MSB-first**. This reproduces the original 3-dimension layout
#' as a special case:
#'
#' - 98-10-0023 `Geography x Age(128) x Gender(3)`: Gender pads to 4 bits, Age to
#'   128*4 = 512 bits -> a 64-byte record, one nibble per Age with the three
#'   genders Total/Men/Women at bits 3/2/1 (the historical "nibble per member").
#' - 98-10-0129 `Geography x Gender(3) x Marital(13) x Age(16)`: Age pads to 16,
#'   Marital to 13*16 = 208 -> 256, Gender to 3*256 = 768 -> 1024 bits -> a
#'   128-byte record (strides 256 / 16 / 1).
#'
#' Values are a dense little-endian run over the present cells, in the same order
#' the bitmap is walked (descriptor order, innermost dimension fastest), one
#' geography after another within the page. Per-page value width / type and the
#' value-run start come from the page marker (see `container-f2.R`). The store
#' keeps only **non-zero** cells; absent cells (and entirely empty geographies)
#' are published as zero in the StatCan CSV.
#'
#' @keywords internal
#' @noRd
NULL

# Next power of two >= x (x >= 1).
ivt_f2_nextpow2 <- function(x) as.integer(2^ceiling(log2(pmax(as.numeric(x), 1))))

# Power-of-two nested bit layout for the data dimensions (member `counts` in
# descriptor order, outermost first). Returns the per-dimension `stride` (bits
# advanced per unit increment of that dimension's index) and the whole record
# size `rec_bytes`.
ivt_f2_bit_layout <- function(counts) {
  k <- length(counts)
  if (k == 0L) return(list(stride = integer(0), rec_bytes = 0L))
  block <- integer(k)
  block[k] <- ivt_f2_nextpow2(counts[k])
  if (k > 1L) for (i in (k - 1L):1L) block[i] <- ivt_f2_nextpow2(counts[i] * block[i + 1L])
  stride <- integer(k); stride[k] <- 1L
  if (k > 1L) for (i in seq_len(k - 1L)) stride[i] <- block[i + 1L]
  list(stride = stride, rec_bytes = block[1L] %/% 8L)
}

# Enumerate every cell (the cartesian product of the data dimensions) in dense
# value order -- descriptor order, innermost dimension varying fastest -- and
# precompute each cell's bit index in the presence record. Returns the 1-based
# `tuples` matrix (one column per data dimension) and the integer `bit` vector.
ivt_f2_cell_grid <- function(counts, stride) {
  k <- length(counts); N <- prod(counts)
  tuples <- matrix(0L, N, k); rin <- 1L
  for (i in k:1L) {
    tuples[, i] <- rep(rep.int(0:(counts[i] - 1L), rep.int(rin, counts[i])), length.out = N)
    rin <- rin * counts[i]
  }
  list(tuples = tuples + 1L, bit = as.integer(tuples %*% stride))
}

# Decode the presence of a single record at 0-based offset `ps`: byte-pair-swap
# the `rec_bytes`-byte record, then read each precomputed cell `bit` MSB-first.
# Returns a logical vector aligned with the cell grid (TRUE = cell present).
ivt_f2_record_present <- function(raw, ps, rec_bytes, bit) {
  rec <- as.integer(raw[(ps + 1L):(ps + rec_bytes)])
  ev <- seq.int(1L, rec_bytes, 2L); od <- ev + 1L
  sw <- rec; sw[ev] <- rec[od]; sw[od] <- rec[ev]
  bitwAnd(bitwShiftR(sw[bit %/% 8L + 1L], 7L - (bit %% 8L)), 1L) == 1L
}

# Resolve everything needed to decode a file's cells from the header descriptor:
# the data-dimension member `counts` + column `slugs`, the precomputed cell
# `grid`, the presence-record size `rec_bytes`, and the geographies-per-page
# `gpp`. Driven entirely by metadata, so it adapts to any dimensionality.
ivt_f2_decode_spec <- function(raw, dir = NULL) {
  if (is.null(dir)) dir <- ivt_f2_find_directory(raw)
  dd <- ivt_f2_data_dims(raw)
  lay <- ivt_f2_bit_layout(dd$counts)
  grid <- ivt_f2_cell_grid(dd$counts, lay$stride)
  gpp <- ivt_f2_geos_per_page(raw, dir)
  list(counts = dd$counts, slugs = dd$slugs, grid = grid,
       rec_bytes = lay$rec_bytes, gpp = gpp)
}

# Decode every geography of a family-2 file into a tibble of one value per row.
# Columns: `geo` (1-based geography member id), one 1-based member-id column per
# data dimension (named by its slug, in descriptor order), and `value`.
#' @keywords internal
#' @noRd
ivt_f2_decode <- function(raw, dir = NULL) {
  if (is.null(dir)) dir <- ivt_f2_find_directory(raw)
  if (is.null(dir)) cli::cli_abort("No family-2 page directory found.")
  spec <- ivt_f2_decode_spec(raw, dir)
  if (!length(spec$counts)) cli::cli_abort("No data dimensions found in the header descriptor.")

  offsets <- dir$offsets; P <- length(offsets)
  grid <- spec$grid; gpp <- spec$gpp
  rec_bytes <- spec$rec_bytes; presence_len <- rec_bytes * gpp
  k <- length(spec$counts)

  geo_l <- vector("list", P)
  col_l <- vector("list", P)   # each element: an n_present x k member-id matrix
  val_l <- vector("list", P)

  geo <- 1L
  for (p in seq_len(P)) {
    po <- offsets[p]
    m0 <- as.integer(raw[po + 1L])
    pp <- ivt_f2_page_params(m0, presence_len)
    voff <- po + pp$vstart
    g_acc <- integer(0); v_acc <- numeric(0)
    col_acc <- vector("list", gpp); ci <- 0L
    for (i in seq_len(gpp)) {
      ps <- po + 4L + rec_bytes * (i - 1L)
      pres <- ivt_f2_record_present(raw, ps, rec_bytes, grid$bit)
      nv <- sum(pres)
      if (nv > 0L) {
        bytes <- raw[(voff + 1L):(voff + nv * pp$width)]
        vals <- if (pp$float) {
          readBin(bytes, "double", n = nv, size = 8L, endian = "little")
        } else {
          as.numeric(readBin(bytes, "integer", n = nv, size = pp$width,
                             signed = TRUE, endian = "little"))
        }
        g_acc <- c(g_acc, rep.int(geo, nv))
        ci <- ci + 1L; col_acc[[ci]] <- grid$tuples[pres, , drop = FALSE]
        v_acc <- c(v_acc, vals)
        voff <- voff + nv * pp$width
      }
      geo <- geo + 1L
    }
    geo_l[[p]] <- g_acc
    col_l[[p]] <- if (ci) do.call(rbind, col_acc[seq_len(ci)]) else matrix(0L, 0L, k)
    val_l[[p]] <- v_acc
  }

  cols <- do.call(rbind, col_l)
  out <- tibble::tibble(geo = unlist(geo_l, use.names = FALSE))
  for (j in seq_len(k)) out[[spec$slugs[j]]] <- cols[, j]
  out$value <- unlist(val_l, use.names = FALSE)
  out
}
