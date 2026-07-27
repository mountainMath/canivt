# The page cell-status tail (R/status.R): which absent cells are genuine ZEROS
# and which are MISSING.
#
# The store keeps only non-zero cells, so absence covers both. The 1-bit absent
# mask separates them -- masked absent = a genuine zero, UNMASKED absent =
# missing -- and it is written as a sparse array of value-width words addressed
# by an index bitmap occupying the WHOLE pre-value region (b2 trailer + the
# 32*(b3-8) head). The length invariant `popcount(index) * width == tail length`
# is the gate, and it is what the corpus sweep below re-measures.

test_that("ivt_mask_bits reads MSB-first and does NOT pair-swap", {
  # the mask is the one bitmap in the container that is not byte-pair-swapped:
  # byte 0 bit 0 (MSB) is grid bit 0, byte 1 bit 0 is grid bit 8.
  b <- c(0x80L, 0x01L, 0x00L, 0x00L)
  expect_identical(ivt_mask_bits(b, 0:15),
                   c(TRUE, rep(FALSE, 14), TRUE))
  # ... which is exactly where it differs from the presence convention
  expect_false(identical(ivt_mask_bits(b, 0:15),
                         ivt_bits_pairswap_msb(b, 0:15)))
})

test_that("the bundled table decodes its mask and reports no missing cells", {
  path <- system.file("extdata", "98100044.ivt", package = "canivt")
  x <- read_ivt(path, missing = TRUE)
  expect_s3_class(x$missing, "tbl_df")
  # same coordinate columns as `cells`, minus the value
  expect_identical(names(x$missing), setdiff(names(x$cells), "value"))
  expect_identical(nrow(x$missing), 0L)
  tally <- attr(x$missing, "pages")
  expect_gt(tally[["mask"]], 0L)
  expect_identical(tally[["unreadable"]], 0L)
  expect_identical(tally[["contradictory"]], 0L)
})

test_that("missing = FALSE (the default) leaves cells and the object untouched", {
  path <- system.file("extdata", "98100044.ivt", package = "canivt")
  a <- read_ivt(path)
  b <- read_ivt(path, missing = TRUE)
  expect_null(a$missing)
  expect_null(attr(a$cells, "missing", exact = TRUE))
  expect_null(attr(b$cells, "missing", exact = TRUE))   # moved onto x$missing
  expect_equal(a$cells, b$cells)
})

test_that("a page with no readable tail contributes nothing, loudly", {
  # A no-tail page must NOT read as "every absent cell is missing": the
  # lineages that write no tail at all (Business Patterns, the type-00 sub-A
  # cluster) would otherwise report their whole grid missing.
  lay <- list(rec_bytes = 4L, grid = list(bit = 0:7))
  # a 4-byte page header + presence record and nothing beyond it
  raw <- as.raw(c(0x84, 0x01, 0x00, 0x08, 0xff, 0x00, 0x00, 0x00))
  st <- ivt_page_status(raw, 0L, lay, size = 8L)
  expect_identical(st$kind, "none")
  # and with no size at all there is nothing to measure the tail against
  expect_identical(ivt_page_status(raw, 0L, lay)$kind, "none")
})

# --- corpus sweep (opt-in) -----------------------------------------------------
#
# Same opt-in contract as test-corpus.R. fixtures/status-ledger.csv records, per
# table with any page tail, the measured page tally and missing-cell counts. The
# two structural columns are the ones that must never move:
#
#   * `unreadable` == 0 everywhere -- the index accounts for the tail byte-exactly
#     on all 1,342,037 mask pages of the corpus;
#   * `contradictory` == 0 everywhere -- outside the NaN-shaped words no mask bit
#     ever lands on a cell that carries a value.
#
# `n_beyond` is the honest caveat column: those missing cells sit past the last
# mask word their page writes, so they are unmasked for want of a word rather
# than by the file's own statement.

corpus_dir <- Sys.getenv("CANIVT_IVT_CACHE")
corpus_on <- nzchar(Sys.getenv("CANIVT_CORPUS_TESTS")) &&
  nzchar(corpus_dir) && dir.exists(corpus_dir)

status_ledger <- utils::read.csv(
  testthat::test_path("fixtures", "status-ledger.csv"), stringsAsFactors = FALSE)

status_probe <- function(row) {
  hit <- list.files(file.path(corpus_dir, row$key), pattern = "\\.ivt$",
                    ignore.case = TRUE, full.names = TRUE)
  if (!length(hit)) return(list(key = row$key, absent = TRUE))
  cap <- ivt_test_capture(read_ivt(hit[[1L]], missing = TRUE))
  out <- list(key = row$key, absent = FALSE, error = cap$error)
  if (!is.null(cap$value)) {
    out$n_missing <- nrow(cap$value$missing)
    out$tally <- attr(cap$value$missing, "pages")
  }
  gc(verbose = FALSE)
  out
}

test_that("the corpus cell-status tallies match the ledger", {
  skip_if(!corpus_on, "corpus tests are opt-in: set CANIVT_CORPUS_TESTS=1 (and CANIVT_IVT_CACHE)")
  got <- ivt_test_pmap(split(status_ledger, seq_len(nrow(status_ledger))),
                       status_probe)
  for (r in got) {
    row <- status_ledger[status_ledger$key == r$key, ]
    if (isTRUE(r$absent)) { skip(paste("not in cache:", r$key)); next }
    expect_null(r$error, info = r$key)
    t <- r$tally
    expect_identical(t[["unreadable"]], 0L, info = r$key)
    expect_identical(t[["contradictory"]], 0L, info = r$key)
    expect_identical(t[["mask"]], as.integer(row$mask_pages), info = r$key)
    expect_identical(t[["none"]], as.integer(row$no_tail_pages), info = r$key)
    expect_identical(t[["status"]], as.integer(row$status_pages), info = r$key)
    expect_identical(t[["extra"]], as.integer(row$extra_words), info = r$key)
    expect_identical(t[["nan_words"]], as.integer(row$nan_words), info = r$key)
    expect_identical(t[["beyond"]], as.integer(row$n_beyond), info = r$key)
    expect_identical(r$n_missing, as.integer(row$n_missing), info = r$key)
  }
})
