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

# A minimal page: the four marker bytes `[b0][01][b2][b3]` the recognizer reads.
# 0x88 = width code 8 (float64), b3 = 0x08 = no head block.
suba_plant_page <- function(raw, off) {
  raw[off + 1L] <- as.raw(0x88L)
  raw[off + 2L] <- as.raw(0x01L)
  raw[off + 3L] <- as.raw(0x00L)
  raw[off + 4L] <- as.raw(0x08L)
  raw
}

# Build a raw file carrying a page directory at `idx0` whose populated entry
# slots are exactly `slots` (0-based). Every populated slot points at its own
# 256-byte page; every other slot is an unwritten (all-zero) record.
suba_fake_dir <- function(slots, idx0 = 131072L, n_entries = max(slots) + 1L,
                          n = 262144L) {
  raw <- as.raw(rep(0L, n))
  page0 <- 1024L
  for (i in seq_along(slots)) {
    off <- page0 + (i - 1L) * 256L
    raw <- suba_plant_page(raw, off)
    o <- idx0 + slots[i] * 8L
    raw[o + 1L] <- as.raw(bitwAnd(off, 0xffL))
    raw[o + 2L] <- as.raw(bitwAnd(bitwShiftR(off, 8L), 0xffL))
    raw[o + 3L] <- as.raw(bitwAnd(bitwShiftR(off, 16L), 0xffL))
    raw[o + 4L] <- as.raw(bitwAnd(bitwShiftR(off, 24L), 0xffL))
    raw[o + 5L] <- as.raw(0x00L); raw[o + 6L] <- as.raw(0x01L)   # size = 256
    raw[o + 7L] <- as.raw(0x00L); raw[o + 8L] <- as.raw(0x01L)
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

test_that("an empty directory yields no stride", {
  raw <- as.raw(rep(0L, 262144L))
  expect_null(ivt_f2_suba_dir_stride(raw, 131072L, 13L))
})
