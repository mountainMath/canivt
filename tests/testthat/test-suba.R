# Unit tests for the type-00 sub-A stride measurement (R/suba.R).
#
# In this cluster the outer directory stride is a NON-DECLARED physical constant:
# nothing in the file states it, so it has to be measured from the page directory
# itself, and an unmeasurable stride is a refusal. `ivt_f2_suba_dir_stride()`
# measures it from the directory's TILING -- every geography occupies S
# consecutive entry slots and writes the SAME window residues inside them --
# which is what lets it read a run that does not start at window 0.
#
# These build synthetic directories so the rule can be exercised on shapes the
# corpus does not contain (and so a corpus-free checkout still covers it).

# A minimal page: the four marker bytes `[b0][01][b2][b3]` the recognizer reads,
# followed by the fixed 256-byte presence record. 0x88 = width code 8 (float64),
# b3 = 0x08 = no head block. `blank` writes the presence record all-zero -- a page
# that is written but carries no cells.
suba_plant_page <- function(raw, off, blank = FALSE) {
  raw[off + 1L] <- as.raw(0x88L)
  raw[off + 2L] <- as.raw(0x01L)
  raw[off + 3L] <- as.raw(0x00L)
  raw[off + 4L] <- as.raw(0x08L)
  if (!blank) raw[off + 5L] <- as.raw(0x80L)          # one present bit
  raw
}

# Build a raw file carrying a page directory at `idx0` whose populated entry
# slots are exactly `slots` (0-based). Every populated slot points at its own
# page (4 marker bytes + a 256-byte presence record = 260); every other slot is an
# unwritten (all-zero) record. `blank` names the entry slots whose page carries no
# present bits.
suba_fake_dir <- function(slots, idx0 = 131072L, n = 262144L,
                          blank = integer(0)) {
  raw <- as.raw(rep(0L, n))
  page0 <- 1024L
  for (i in seq_along(slots)) {
    off <- page0 + (i - 1L) * 512L
    raw <- suba_plant_page(raw, off, blank = slots[i] %in% blank)
    o <- idx0 + slots[i] * 8L
    raw[o + 1L] <- as.raw(bitwAnd(off, 0xffL))
    raw[o + 2L] <- as.raw(bitwAnd(bitwShiftR(off, 8L), 0xffL))
    raw[o + 3L] <- as.raw(bitwAnd(bitwShiftR(off, 16L), 0xffL))
    raw[o + 4L] <- as.raw(bitwAnd(bitwShiftR(off, 24L), 0xffL))
    raw[o + 5L] <- as.raw(0x04L); raw[o + 6L] <- as.raw(0x01L)   # size = 260
    raw[o + 7L] <- as.raw(0x04L); raw[o + 8L] <- as.raw(0x01L)
  }
  raw
}

# The window slots `geo_count` geographies populate at stride `S`.
suba_tile <- function(geo_count, S, windows, skip = integer(0)) {
  g <- setdiff(seq_len(geo_count) - 1L, skip)
  sort(as.integer(outer(windows, g * S, "+")))
}

test_that("the stride is measured from a directory whose windows start at 0", {
  raw <- suba_fake_dir(suba_tile(13L, 8L, 0:5))
  got <- ivt_f2_suba_dir_stride(raw, 131072L, 13L)
  expect_equal(got$stride, 8L)
  expect_equal(got$windows, 0:5)
})

test_that("a BLANK-LED window run is measured, not refused", {
  # `PROVSIC4dec1997`'s shape: 11 windows per province at entry slots 3..13 of a
  # 16-slot group. Window 0 is unwritten, which is precisely what defeated the
  # old progression-based rule -- the stride was 16 all along.
  raw <- suba_fake_dir(suba_tile(13L, 16L, 3:13))
  got <- ivt_f2_suba_dir_stride(raw, 131072L, 13L)
  expect_equal(got$stride, 16L)
  expect_equal(got$windows, 3:13)
})

test_that("a directory that RESUMES past the extent rejects the too-small stride", {
  # Fully-populated groups of 8. At the candidate S = 4 the tiling test alone
  # passes -- 13 groups, residues {0,1,2,3} in every one -- so only the entries
  # beyond `geo_count * S` reveal that S is half the real stride. This is
  # `PRNAIC6dec2000`, which the old rule reported as 4.
  raw <- suba_fake_dir(suba_tile(13L, 8L, 0:7))
  got <- ivt_f2_suba_dir_stride(raw, 131072L, 13L)
  expect_equal(got$stride, 8L)
  expect_equal(got$windows, 0:7)
})

test_that("wholly-empty geographies are tolerated, but only a couple", {
  # A geography with no cells at all writes no entries -- suppression is
  # whole-geography here, so a missing group is data, not a broken tiling.
  raw <- suba_fake_dir(suba_tile(13L, 16L, 2:9, skip = c(4L, 7L)))
  got <- ivt_f2_suba_dir_stride(raw, 131072L, 13L)
  expect_equal(got$stride, 16L)
  expect_equal(got$windows, 2:9)

  # Five missing groups is no longer a tiling we can trust.
  raw2 <- suba_fake_dir(suba_tile(13L, 16L, 2:9, skip = c(1L, 4L, 6L, 7L, 10L)))
  expect_null(ivt_f2_suba_dir_stride(raw2, 131072L, 13L))
})

test_that("a ragged residue set is not a tiling", {
  # One geography populating a different window set than its peers.
  slots <- c(suba_tile(12L, 16L, 0:5), 12L * 16L + c(0L, 1L, 9L))
  expect_null(ivt_f2_suba_dir_stride(raw <- suba_fake_dir(sort(slots)), 131072L, 13L))
})

test_that("a single outer member has no stride to measure", {
  # `EDDTAB16`: with one geography there is no periodicity, so the rule declines
  # rather than inventing one -- the caller leaves such files alone.
  raw <- suba_fake_dir(0:9)
  expect_null(ivt_f2_suba_dir_stride(raw, 131072L, 1L))
  expect_null(ivt_f2_suba_dir_stride(raw, 131072L, NA_integer_))
})

test_that("a page with no present bits does not witness the tiling", {
  # `PRVNAIC1dec1998`: three of thirteen provinces carry an EXTRA directory entry
  # at window slot 8 whose page has an all-zero presence record -- written, but
  # carrying no cells. Counted, it makes those three groups' residue sets differ
  # from the other ten and NO stride confirms; ignored, the tiling is the plain
  # {0, 10} every geography shares.
  stubs <- c(5L, 6L, 12L) * 16L + 8L
  slots <- sort(c(suba_tile(13L, 16L, c(0L, 10L)), stubs))
  expect_null(ivt_f2_suba_dir_stride(
    suba_fake_dir(slots), 131072L, 13L))               # stubs counted: no tiling
  got <- ivt_f2_suba_dir_stride(
    suba_fake_dir(slots, blank = stubs), 131072L, 13L)
  expect_equal(got$stride, 16L)
  expect_equal(got$windows, c(0L, 10L))
})

test_that("ivt_f2_page_blank() reads the presence record, not the entry", {
  raw <- suba_fake_dir(c(0L, 1L), blank = 1L)
  expect_false(ivt_f2_page_blank(raw, 1024L, 260L))
  expect_true(ivt_f2_page_blank(raw, 1024L + 512L, 260L))
  # a page too short to hold a full presence record is not judged blank
  expect_false(ivt_f2_page_blank(raw, 1024L + 512L, 12L))
  expect_false(ivt_f2_page_blank(raw, length(raw) - 8L, 260L))
})

test_that("an empty directory yields no stride", {
  raw <- as.raw(rep(0L, 262144L))
  expect_null(ivt_f2_suba_dir_stride(raw, 131072L, 13L))
})
