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
  x <- read_ivt(path, missing = TRUE, complete = FALSE)
  expect_s3_class(x$missing, "tbl_df")
  # same coordinate columns as `cells`, minus the value, plus the reason
  expect_identical(names(x$missing),
                   c(setdiff(names(x$cells), "value"), "symbol", "status"))
  # the file's own reason-code legend travels with the table
  leg <- attr(x$missing, "legend")
  expect_s3_class(leg, "tbl_df")
  # verbatim from the file -- the census lineage writes `X` where the published
  # legend prints `x`, and canivt reports what the bytes say
  expect_identical(leg$symbol, c("..", "X", "...", "F", "0 s"))
  expect_identical(leg$code, 1:5)
  expect_identical(nrow(x$missing), 0L)
  tally <- attr(x$missing, "pages")
  expect_gt(tally[["mask"]], 0L)
  expect_identical(tally[["unreadable"]], 0L)
  expect_identical(tally[["contradictory"]], 0L)
})

test_that("missing = FALSE (the default) leaves cells and the object untouched", {
  path <- system.file("extdata", "98100044.ivt", package = "canivt")
  a <- read_ivt(path, complete = FALSE)
  b <- read_ivt(path, missing = TRUE, complete = FALSE)
  expect_null(a$missing)
  expect_null(attr(a$cells, "missing", exact = TRUE))
  expect_null(attr(b$cells, "missing", exact = TRUE))   # moved onto x$missing
  expect_equal(a$cells, b$cells)
})

test_that("covered_bits is the index's REACH, not the last word written", {
  # A dropped all-zero word inside the index's span is the file stating "no
  # genuine zeros here", so the cells it covers are missing and must NOT be
  # counted as beyond the mask. Only a word the index has no bit for is a gap.
  #
  # One 8-bit grid, width 2, rec_bytes 4 (2 mask words), b2 = 0x10 -> a 2-byte
  # trailer = 16 index bits, so the index reaches both mask words. The page
  # writes only word 0 (index bit 0 set, pair-swapped: byte 1 bit 7).
  lay <- list(rec_bytes = 4L, grid = list(bit = 0:7))
  raw <- as.raw(c(0x82, 0x01, 0x10, 0x08,      # marker: width 2, trailer 2
                  0x00, 0x00, 0x00, 0x00,      # presence record (4 bytes, empty)
                  0x00, 0x80,                  # index: word 0 only
                  0xff, 0x00))                 # the one written mask word
  st <- ivt_page_status(raw, 0L, lay, size = 12L)
  expect_identical(st$kind, "mask")
  expect_identical(st$covered_bits, 32L)       # both words, not just the written one
  expect_identical(st$extra_words, 0L)
  expect_true(all(ivt_mask_bits(st$mask_bytes, 0:7)))

  # Halve the index (b2 = 0x00 -> a 1-byte... trailer of 0 is rejected; use a
  # width that makes the mask span more words than the index can address).
  lay8 <- list(rec_bytes = 64L, grid = list(bit = 0:7))
  raw8 <- as.raw(c(0x82, 0x01, 0x10, 0x08, rep(0x00, 64), 0x00, 0x80, 0xff, 0x00))
  st8 <- ivt_page_status(raw8, 0L, lay8, size = 4L + 64L + 2L + 2L)
  expect_identical(st8$kind, "mask")
  # 16 index bits address 16 of the mask's 32 words -> the mask stops at bit 256
  expect_identical(st8$covered_bits, 256L)
})

test_that("the 0xa status array decodes at W = 2", {
  # Same sparse-word rebuild as the mask, then a self-describing header:
  #   [form][02][W]  (+ [u16] when form 02)  [01][W]  <W-bit codes>
  # with the code array starting at byte 5 (form 01) and addressed at the same
  # padded presence-grid bit as the presence record.
  lay <- list(rec_bytes = 4L, grid = list(bit = 0:7))
  raw <- as.raw(c(
    0xa2, 0x01, 0x10, 0x08,                        # 0xa marker, width 2, trailer 2
    0x00, 0x80, 0x00, 0x00,                        # presence: cell 0 only
    0x00, 0xf0,                                    # index: words 0-3 written
    0x01, 0x00,                                    # the one stored value
    0x01, 0x02, 0x02, 0x01, 0x02, 0x1b, 0x0b, 0x00 # the tail words
  ))
  st <- ivt_page_status(raw, 0L, lay, size = 20L)
  expect_identical(st$kind, "status")
  expect_identical(st$status_form, 1L)
  expect_identical(st$status_width, 2L)
  # 0 value/genuine zero, 1 nothing-here, 2 = `x` suppressed, 3 = `...` n/a
  expect_identical(st$codes, c(0L, 1L, 2L, 3L, 0L, 0L, 2L, 3L))
  # the one cell that carries a value is code 0, as the model requires
  expect_identical(st$codes[[1L]], 0L)
})

test_that("the same array decodes at W = 4 -- the width is storage, not dialect", {
  # A page uses the narrowest width that holds its largest code, so W carries no
  # meaning of its own (two corpus files mix W = 2 and W = 4 pages). Codes past
  # the validated vocabulary still come back as codes; refusing to TRANSLATE
  # them is the caller's job, not this reader's.
  lay <- list(rec_bytes = 4L, grid = list(bit = 0:7))
  raw <- as.raw(c(
    0xa2, 0x01, 0x10, 0x08,                        # 0xa marker, width 2, trailer 2
    0x00, 0x00, 0x00, 0x00,                        # nothing present
    0x00, 0xf8,                                    # index: words 0-4 written
    0x01, 0x02, 0x04, 0x01, 0x04,                  # form 01, W = 4, `[01][W]` intro
    0x01, 0x23, 0x45, 0x78, 0x00                   # eight 4-bit codes
  ))
  st <- ivt_page_status(raw, 0L, lay, size = 20L)
  expect_identical(st$kind, "status")
  expect_identical(st$status_width, 4L)
  expect_identical(st$codes, c(0L, 1L, 2L, 3L, 4L, 5L, 7L, 8L))
})

test_that("a 0xa page whose header is not the known form decodes nothing", {
  lay <- list(rec_bytes = 4L, grid = list(bit = 0:7))
  raw <- as.raw(c(
    0xa2, 0x01, 0x10, 0x08,
    0x00, 0x00, 0x00, 0x00,
    0x00, 0xf0,
    0x01, 0x02, 0x02, 0x01, 0x03, 0x1b, 0x0b, 0x00 # intro says W = 3, header W = 2
  ))
  st <- ivt_page_status(raw, 0L, lay, size = 18L)
  expect_identical(st$kind, "status")
  expect_null(st$codes)

  # a width the array cannot be written at is refused outright
  raw3 <- raw; raw3[13L] <- as.raw(0x03); raw3[15L] <- as.raw(0x03)
  st3 <- ivt_page_status(raw3, 0L, lay, size = 18L)
  expect_identical(st3$kind, "status")
  expect_null(st3$codes)
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

# --- the export path -----------------------------------------------------------
#
# The data table carries only the cells that HAVE a value, so on its own it
# cannot say which of the rest are zeros; the cell-status sidecar is what makes
# an exported table complete. These check that it travels -- labelled exactly
# like the data, so the two join -- and that a table decoded without it exports
# no sidecar rather than an empty one.

test_that("ivt_tidy_missing labels the coordinates exactly like ivt_tidy", {
  path <- system.file("extdata", "98100044.ivt", package = "canivt")
  x <- read_ivt(path, missing = TRUE, complete = FALSE)
  m <- ivt_tidy_missing(x)
  # the value column is replaced by the reason; everything else lines up
  expect_identical(names(m), c(setdiff(names(ivt_tidy(x)), "value"),
                               "symbol", "status"))
  expect_identical(names(ivt_tidy_missing(x, dim_names = "label")),
                   c(setdiff(names(ivt_tidy(x, dim_names = "label")), "value"),
                     "symbol", "status"))
  # the compact id form keeps the member-id coordinates, not labels
  expect_identical(names(ivt_tidy_missing(x, labels = FALSE)),
                   c(setdiff(names(x$cells), "value"), "symbol", "status"))
  # the file's legend rides along
  expect_identical(attr(m, "legend"), attr(x$missing, "legend"))
  # and a table read without `missing` says so rather than returning nothing
  expect_error(ivt_tidy_missing(read_ivt(path)), "no cell-status table")
})

test_that("the cell-status sidecar is written, found and read back", {
  skip_if_not_installed("arrow")
  path <- system.file("extdata", "98100044.ivt", package = "canivt")
  dir <- withr::local_tempdir()
  x <- read_ivt(path, missing = TRUE, complete = FALSE)
  pq <- ivt_write_parquet(x, file.path(dir, "t_en.parquet"))
  side <- ivt_missing_path(pq)
  # unlike the member sidecar this keeps the language marker: it is labelled
  # like the data it accompanies, so there is one per language
  expect_identical(basename(side), "t_en_missing.parquet")
  expect_true(file.exists(side))
  expect_identical(names(tibble::as_tibble(arrow::read_parquet(side))),
                   names(ivt_tidy_missing(x)))
  # ivt_missing() resolves the sidecar from the data path alone
  expect_s3_class(ivt_missing(pq), "Dataset")
  # a table decoded without the status block writes no sidecar and reports none
  y <- read_ivt(path)
  pq2 <- ivt_write_parquet(y, file.path(dir, "u_en.parquet"))
  expect_false(file.exists(ivt_missing_path(pq2)))
  expect_null(ivt_missing(y))
  expect_null(ivt_missing(pq2))
})

# --- corpus sweep (opt-in) -----------------------------------------------------
#
# Same opt-in contract as test-corpus.R. fixtures/status-ledger.csv records, per
# table with any page tail, the measured page tally and missing-cell counts. The
# two structural columns are the ones that must never move:
#
#   * `unreadable` == 0 everywhere -- the index accounts for the tail byte-exactly
#     on all 1,810,626 mask and 1,273,173 status-array pages of the corpus;
#   * `contradictory` == 0 everywhere -- outside the NaN-shaped words no mask bit
#     ever lands on a cell that carries a value, and no present cell ever carries
#     a non-zero reason code.
#
# `status_unread_pages` counts `0xa` arrays whose header this reader does not
# recognise; `n_unknown` counts absent cells carrying a reason code the file's
# OWN legend does not name. Both are reported and contribute no missing cell,
# and both are 0 for every corpus table.
#
# `legend_codes` is how many reason codes the file declares at header slot 698
# (0 = none). It is the third structural column: a table with `0xa` pages and no
# legend would fall back to a guessed vocabulary, so `status_pages > 0` must
# always come with `legend_codes > 0`.
#
# `n_beyond` counts missing cells past the reach of their page's word INDEX --
# cells the file has no bit with which to classify. It is 0 for every corpus
# table: the index always spans the whole grid, so an unwritten mask word is the
# file declaring that word all-zero, not a mask that stopped short.

corpus_dir <- Sys.getenv("CANIVT_IVT_CACHE")
corpus_on <- nzchar(Sys.getenv("CANIVT_CORPUS_TESTS")) &&
  nzchar(corpus_dir) && dir.exists(corpus_dir)

status_ledger <- utils::read.csv(
  testthat::test_path("fixtures", "status-ledger.csv"), stringsAsFactors = FALSE)

status_probe <- function(row) {
  hit <- list.files(file.path(corpus_dir, row$key), pattern = "\\.ivt$",
                    ignore.case = TRUE, full.names = TRUE)
  if (!length(hit)) return(list(key = row$key, absent = TRUE))
  cap <- ivt_test_capture(read_ivt(hit[[1L]], missing = TRUE, complete = FALSE))
  out <- list(key = row$key, absent = FALSE, error = cap$error)
  if (!is.null(cap$value)) {
    out$n_missing <- nrow(cap$value$missing)
    out$tally <- attr(cap$value$missing, "pages")
    leg <- attr(cap$value$missing, "legend", exact = TRUE)
    out$legend <- if (is.null(leg)) 0L else nrow(leg)
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
    expect_identical(t[["status_unread"]], as.integer(row$status_unread_pages),
                     info = r$key)
    expect_identical(t[["status_unknown"]], as.integer(row$n_unknown),
                     info = r$key)
    expect_identical(t[["extra"]], as.integer(row$extra_words), info = r$key)
    expect_identical(t[["nan_words"]], as.integer(row$nan_words), info = r$key)
    expect_identical(t[["beyond"]], as.integer(row$n_beyond), info = r$key)
    expect_identical(r$n_missing, as.integer(row$n_missing), info = r$key)
    expect_identical(r$legend, as.integer(row$legend_codes), info = r$key)
    # a `0xa` array is only ever named from the file's own declaration
    if (t[["status"]] > 0L) expect_gt(r$legend, 0L)
  }
})
