# Zero-suppressed fixed-width records (R/records.R): the storage of the
# `81 01` / `81 02` master-directory blocks. Synthetic blocks are packed here by
# the inverse of the reader, so the tests state the storage rule independently
# of any corpus file; the bundled sample table checks the rule against real
# bytes.

# Pack integer bytes `b` the way the writer does: a mask (one bit per byte,
# MSB-first, padded to 16-bit words, bytes pair-swapped) then the non-zero bytes.
zs_pack <- function(b) {
  nb <- length(b)
  mlen <- 2L * as.integer(ceiling(nb / 16))
  bits <- c(as.integer(b != 0L), integer(mlen * 8L - nb))
  m <- colSums(matrix(bits, nrow = 8L) * 2L^(7:0))
  m <- m[bitwXor(seq_along(m) - 1L, 1L) + 1L]
  as.raw(c(m, b[b != 0L]))
}
u32 <- function(x) as.integer(c(x %% 256, (x %/% 256) %% 256,
                                 (x %/% 65536) %% 256, (x %/% 16777216) %% 256))
field <- function(s, w) c(as.integer(charToRaw(s)), integer(w - nchar(s)))
dimrec <- function(count, type, flag, short, desc, tail = 0L)
  c(u32(count), u32(type), u32(flag), field(short, 16L), field(desc, 50L), u32(tail))

test_that("a zero-suppressed record round-trips and is gated exactly", {
  set.seed(1)
  b <- sample(c(0L, 0L, 1:255), 77L, replace = TRUE)
  raw <- c(as.raw(c(9, 9, 9)), zs_pack(b), as.raw(c(7, 7)))
  u <- ivt_zs_unpack(raw, 3L, 77L)
  expect_identical(u$bytes, b)
  expect_identical(u$end, length(raw) - 2L)

  # a truncated block does not fit
  expect_null(ivt_zs_unpack(raw[seq_len(length(raw) - 10L)], 3L, 77L))
  # a set padding bit (bit 78 of an 80-bit mask) is not this storage
  bad <- raw; bad[3L + 9L] <- as.raw(bitwOr(as.integer(bad[3L + 9L]), 1L))
  expect_null(ivt_zs_unpack(bad, 3L, 77L))
  # a stored zero would have been suppressed
  bad <- raw; bad[3L + 10L + 1L] <- as.raw(0)
  expect_null(ivt_zs_unpack(bad, 3L, 77L))
})

test_that("the 81 01 / 81 02 framings give a record matrix and an exact end", {
  b <- c(5L, 0L, 0L, 200L, 0L, 1L)
  one <- c(as.raw(c(0x81, 0x01, 6, 0)), zs_pack(b))
  x <- ivt_zs_block(one, 0L)
  expect_identical(c(x$kind, x$nrec, x$recbytes), c(1L, 1L, 6L))
  expect_identical(x$m[, 1L], b)
  expect_identical(x$end, length(one))

  two <- c(as.raw(c(0x81, 0x02, 2, 0, 6, 0)), zs_pack(c(b, rev(b))))
  y <- ivt_zs_block(two, 0L)
  expect_identical(dim(y$m), c(6L, 2L))
  expect_identical(y$m[, 2L], rev(b))
  expect_null(ivt_zs_block(as.raw(c(0x82, 0x02, 2, 0, 6, 0, 0, 0)), 0L))
})

test_that("a dimension's name is chosen from the record's own two text fields", {
  recs <- c(
    dimrec(53488L, 16L, 0L, "Geography", "Geography"),
    # the census record: the short name is the first 15 characters of the name
    dimrec(3L, 2L, 1L, "Household Size ", "Household Size (3)"),
    # a custom extract: a display name beside an unrelated description
    dimrec(5L, 3L, 1L, "Housing Tenure", "Housing tenure (5)"),
    # a survey variable beside its label
    dimrec(13L, 4L, 1L, "REGION", "Canada, Provinces and Territories"),
    # stale bytes after the terminator are not part of the name
    c(u32(1041L), u32(13L), u32(1L),
      c(as.integer(charToRaw("Geography")), 0L, as.integer(charToRaw("ens (p"))),
      field("Geography", 50L), u32(0L)))
  blk <- c(as.raw(c(0x81, 0x02, 5, 0, 82, 0)), zs_pack(recs))
  b <- ivt_zs_block(blk, 0L)
  expect_identical(b$end, length(blk))
  d <- ivt_f2_dimrec_dims(blk, b)
  expect_identical(vapply(d, `[[`, "", "name"),
                   c("Geography", "Household Size (3)", "Housing Tenure",
                     "REGION", "Geography"))
  expect_identical(vapply(d, `[[`, 1L, "count"), c(53488L, 3L, 5L, 13L, 1041L))
  expect_identical(vapply(d, `[[`, 1L, "type"), c(16L, 2L, 3L, 4L, 13L))
  expect_identical(d[[4L]]$description, "Canada, Provinces and Territories")
})

test_that("the bundled table's descriptor and title come from its record blocks", {
  f <- system.file("extdata", "98100044.ivt", package = "canivt")
  skip_if(!nzchar(f))
  raw <- readBin(f, "raw", file.size(f))
  b <- ivt_f2_dimrec_block(raw)
  expect_false(is.null(b))
  expect_identical(b$recbytes, 82L)
  d <- ivt_f2_descriptor(raw)
  expect_true(isTRUE(d$declared))
  expect_identical(length(d$dims), b$nrec)
  expect_identical(vapply(d$dims, `[[`, 1L, "count"),
                   as.integer(vapply(seq_len(b$nrec), function(k)
                     ivt_zs_u32(b$m[1:4, k]), 0)))
  # the same block is found from the descriptor offset, without the directory
  b2 <- ivt_f2_dimrec_block(raw, ivt_f2_descriptor_offset(raw))
  expect_identical(b2$m, b$m)
  tb <- ivt_f2_title_blocks(raw)
  expect_gte(length(tb), 1L)
  expect_match(tb[[1L]]$signature, "^FACET0[0-9]$")
  expect_identical(d$title, tb[[1L]]$title)
  expect_false(is.na(d$title))
})
