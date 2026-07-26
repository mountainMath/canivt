# Unit tests for the directory-base helpers and the chunk-run count arithmetic --
# pure functions, no sample .ivt needed.

test_that("ivt_dir_entry_blank recognises only the all-zero 8-byte record", {
  blank <- as.raw(rep(0L, 8L))
  expect_true(ivt_dir_entry_blank(blank, 0L))
  # a real entry: u32 offset + two u16 sizes
  ent <- as.raw(c(0x00, 0x08, 0x00, 0x00, 0x10, 0x00, 0x10, 0x00))
  expect_false(ivt_dir_entry_blank(ent, 0L))
  # a zero offset with a non-zero size is NOT blank -- blankness is all eight bytes
  half <- as.raw(c(0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00))
  expect_false(ivt_dir_entry_blank(half, 0L))
  # past the end of the buffer
  expect_false(ivt_dir_entry_blank(as.raw(rep(0L, 4L)), 0L))
})

test_that("ivt_f2_dir_first_entry skips leading blanks but stays bounded", {
  # a page at 4096 with a `88 01 20 08` marker, reached past three blank slots
  page <- 4096L
  raw <- as.raw(rep(0L, 8192L))
  raw[page + 1:4] <- as.raw(c(0x88, 0x01, 0x20, 0x08))
  put_entry <- function(raw, o, off, len) {
    raw[o + 1:4] <- as.raw(c(bitwAnd(off, 255L), bitwAnd(bitwShiftR(off, 8), 255L),
                             bitwAnd(bitwShiftR(off, 16), 255L), bitwShiftR(off, 24)))
    raw[o + 5:6] <- as.raw(c(bitwAnd(len, 255L), bitwShiftR(len, 8)))
    raw[o + 7:8] <- raw[o + 5:6]
    raw
  }
  raw <- put_entry(raw, 24L, page, 256L)          # entry slot 3 (bytes 24..31)

  # the base itself is blank, so the strict validator finds nothing there
  expect_false(ivt_f2_entry_valid(raw, 0L, length(raw)))
  # ... but the tolerant walk reaches slot 3
  expect_equal(ivt_f2_dir_first_entry(raw, 0L, length(raw)), 24L)
  # starting AT the populated slot returns it unchanged
  expect_equal(ivt_f2_dir_first_entry(raw, 24L, length(raw)), 24L)
  # an all-blank region declines rather than running off
  expect_null(ivt_f2_dir_first_entry(as.raw(rep(0L, 4096L)), 0L))
  # a non-blank, non-valid record stops the walk immediately (not a directory)
  junk <- as.raw(rep(0L, 64L)); junk[1:8] <- as.raw(rep(0x7f, 8L))
  expect_null(ivt_f2_dir_first_entry(junk, 0L))
  # the bound is what keeps header padding from being walked into a stray marker
  expect_true(IVT_DIR_LEAD_BLANK_MAX >= 1L && is.finite(IVT_DIR_LEAD_BLANK_MAX))
})

test_that("ivt_f2_slot_chunk_multiset resolves a run with a LEADING partial", {
  # SP_VB0LLW_PROVSIC4dec1997's SIC-4 industry codebook, EN + FR copies:
  # [94][256][256][256][256][137] per copy = 1255 members
  sizes <- rep(c(94L, 256L, 256L, 256L, 256L, 137L), each = 2L)
  expect_equal(ivt_f2_slot_chunk_multiset(sizes), 1255L)
  # order within the directory must not matter -- it is a multiset
  expect_equal(ivt_f2_slot_chunk_multiset(sample(sizes)), 1255L)

  # a monolingual run (R == 1) declines: the partition is not over-determined
  expect_true(is.na(ivt_f2_slot_chunk_multiset(c(94L, 256L, 256L, 137L))))
  # an unbalanced multiset declines (gcd 1)
  expect_true(is.na(ivt_f2_slot_chunk_multiset(c(94L, 94L, 256L, 256L, 256L, 137L, 137L))))
  # fewer than two full chunks per copy: not a chunked dimension
  expect_true(is.na(ivt_f2_slot_chunk_multiset(c(94L, 94L, 256L, 256L))))
  # no partial at all: nothing pins the tail
  expect_true(is.na(ivt_f2_slot_chunk_multiset(rep(256L, 6L))))
  # a plain bilingual dimension never fires
  expect_true(is.na(ivt_f2_slot_chunk_multiset(c(40L, 40L))))
  expect_true(is.na(ivt_f2_slot_chunk_multiset(c(256L, 256L))))
  expect_true(is.na(ivt_f2_slot_chunk_multiset(integer(0))))
})

test_that("ivt_gcd is the plain gcd over positive integers", {
  expect_equal(ivt_gcd(c(2L, 8L, 2L)), 2L)
  expect_equal(ivt_gcd(c(6L, 9L)), 3L)
  expect_equal(ivt_gcd(c(7L)), 7L)
  expect_equal(ivt_gcd(c(3L, 5L)), 1L)
  expect_true(is.na(ivt_gcd(integer(0))))
  expect_true(is.na(ivt_gcd(c(NA_integer_, 0L))))
})
