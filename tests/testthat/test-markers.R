# Marker-catalog validation (inst/notes/markers.md + helper-markers.R).
#
# Three layers:
#   1. RECOGNIZERS -- each documented marker's recognizer matches its byte pattern
#      and rejects near-misses (synthetic bytes; always runs).
#   2. CATALOG <-> CODE -- the documented byte SETS equal the code constants, so
#      markers.md cannot silently drift from R/ (always runs).
#   3. CORPUS INVENTORY -- opt-in sweep asserting every marker each .ivt exercises
#      is catalogued; a new vintage with an un-catalogued marker fails loudly.

# ---- 1. recognizers ---------------------------------------------------------

test_that("page-marker recognizer matches the documented [b0] 01 [b2] [b3]", {
  for (b0 in IVT_MARKER_SET$page_b0)
    for (b3 in IVT_MARKER_SET$page_b3)
      expect_true(ivt_f2_is_marker(mk_page(b0, 0x00L, b3), 0L),
                  info = sprintf("b0=0x%02x b3=0x%02x", b0, b3))
  # dense variant: [b0] 01 [u16 count>0], no b3 constraint
  for (b0 in IVT_MARKER_SET$page_b0_dense)
    expect_true(ivt_f2_is_marker(as.raw(c(b0, 0x01L, 0x05L, 0x00L)), 0L))
  # near-misses
  expect_false(ivt_f2_is_marker(mk_page(0x83L, 0x00L, 0x08L), 0L))  # bad width nibble
  expect_false(ivt_f2_is_marker(mk_page(0x84L, 0x00L, 0x0fL), 0L))  # b3 above the set
  expect_false(ivt_f2_is_marker(as.raw(c(0x84L, 0x02L, 0x00L, 0x08L)), 0L)) # byte1 != 01
  expect_false(ivt_f2_is_marker(as.raw(c(0x04L, 0x01L, 0x00L, 0x00L)), 0L)) # dense count 0
})

test_that("ivt_value_trailer decodes the documented b2/b3 formula and aborts on unknowns", {
  expect_equal(ivt_value_trailer(0x82L, 0x00L, 0x08L), 0L)          # b2==0 -> 0 head
  expect_equal(ivt_value_trailer(0x82L, 0x80L, 0x08L), 16L)         # 2*(8) + 0
  expect_equal(ivt_value_trailer(0x88L, 0x20L, 0x08L), 4L)          # 2*(2) + 0
  expect_equal(ivt_value_trailer(0x82L, 0x00L, 0x0aL), 64L)         # head 32*(0x0a-8)
  expect_error(ivt_value_trailer(0x83L, 0x00L, 0x08L), class = "canivt_unknown_marker")
  expect_error(ivt_value_trailer(0x82L, 0x00L, 0x0fL), class = "canivt_unknown_marker")
  expect_error(ivt_value_trailer(0x82L, 0x00L, 0x07L), class = "canivt_unknown_marker")
})

test_that("descriptor-signature recognizer accepts b9 in {03, ff} only", {
  # a descriptor is never at file offset 0 (the recognizer guards off < 1), so
  # test at off = 1 behind a pad byte.
  at1 <- function(sig) c(as.raw(0x00L), sig)
  expect_true(ivt_f2_is_descriptor(at1(mk_descriptor(0x03L)), 1L))   # standard
  expect_true(ivt_f2_is_descriptor(at1(mk_descriptor(0xffL)), 1L))   # Business Patterns
  expect_false(ivt_f2_is_descriptor(at1(mk_descriptor(0x04L)), 1L))  # unknown terminator
  bad <- mk_descriptor(0x03L); bad[1] <- as.raw(0x80L)              # wrong lead byte
  expect_false(ivt_f2_is_descriptor(at1(bad), 1L))
})

test_that("directory text-block vs member-array recognizer (already in decode-f2) is catalog-consistent", {
  # the §F footnote text blob matches; a plain member array does not.
  expect_true(ivt_f2_dir_is_text_block(mk_text_block(), 0L, length(mk_text_block())))
  ma <- mk_member_array()
  expect_false(ivt_f2_dir_is_text_block(ma, 0L, length(ma)))
})

test_that("footnote member bitmap recognizer reads set bits, rejects non-bitmaps", {
  # all bits set over 8 members -> members 1..8 (pair-swap/MSB-first is identity on 0xff)
  expect_equal(ivt_f2_footnote_bitmap(mk_footnote_bitmap(8L)), 1:8)
  expect_equal(ivt_f2_footnote_bitmap(mk_member_array()), integer(0))  # 01 01, not 84 01
})

test_that("time-series member table (81 02 <alloc> 00 08 00) decodes flags, slots and dates", {
  # tb611996's block verbatim: alloc 4, raw flags e0 e0 e0 00 (pair-swapped ->
  # slots {1,2,4}, a deleted hole at 3), three u24 dates = Jan 1 of 1996/1997/1995
  # (days since 0000-03-01: 728965 / 729331 / 728600)
  blk <- as.raw(c(0x81, 0x02, 0x04, 0x00, 0x08, 0x00,
                  0xe0, 0xe0, 0xe0, 0x00,
                  0x85, 0x1f, 0x0b,  0xf3, 0x20, 0x0b,  0x18, 0x1e, 0x0b))
  dir <- matrix(c(0L, length(blk)), 1L, 2L, dimnames = list(NULL, c("off", "len")))
  tm <- ivt_f2_time_members(blk, dir)
  expect_equal(tm$count, 3L)
  expect_equal(tm$slots, c(1L, 2L, 4L))
  expect_equal(tm$labels, c("1996", "1997", "1995"))
  expect_equal(format(tm$dates, "%Y-%m-%d"),
               c("1996-01-01", "1997-01-01", "1995-01-01"))
  # a clipped LEADING date (h2530002 stores n-1 of n) is extrapolated by the step
  blk2 <- as.raw(c(0x81, 0x02, 0x04, 0x00, 0x08, 0x00,
                   0xe0, 0xe0, 0xe0, 0x00,
                   0xff,                                  # clipped fragment
                   0xab, 0x1c, 0x0b,  0x18, 0x1e, 0x0b)) # 728235 / 728600 = 1994 / 1995
  dir2 <- matrix(c(0L, length(blk2)), 1L, 2L, dimnames = list(NULL, c("off", "len")))
  tm2 <- ivt_f2_time_members(blk2, dir2)
  expect_equal(tm2$count, 3L)
  expect_equal(tm2$labels, c("1993", "1994", "1995"))
  # a name marker (56 00) is not a time table; garbage dates keep the count only
  nm <- as.raw(c(0x81, 0x02, 0x02, 0x00, 0x56, 0x00, 0x41, 0x42, 0x43, 0x44))
  dirn <- matrix(c(0L, length(nm)), 1L, 2L, dimnames = list(NULL, c("off", "len")))
  expect_null(ivt_f2_time_members(nm, dirn))
  bad <- as.raw(c(0x81, 0x02, 0x02, 0x00, 0x08, 0x00, 0xe0, 0xe0,
                  0x01, 0x00, 0x00,  0x02, 0x00, 0x00)) # dates out of range
  dirb <- matrix(c(0L, length(bad)), 1L, 2L, dimnames = list(NULL, c("off", "len")))
  tmb <- ivt_f2_time_members(bad, dirb)
  expect_equal(tmb$count, 2L)
  expect_null(tmb$labels)
})

test_that("slot-aware cell grid maps member bits through slot positions", {
  # 2 x 3 grid; the inner dimension's members sit at slots {1,2,4} (0-based {0,1,3})
  lay <- ivt_f2_bit_layout(c(2L, 4L))               # extents: inner padded to 4
  g_dense <- ivt_f2_cell_grid(c(2L, 3L), lay$stride)
  g_slot  <- ivt_f2_cell_grid(c(2L, 3L), lay$stride, pos = list(NULL, c(0L, 1L, 3L)))
  expect_identical(g_dense$tuples, g_slot$tuples)   # member ids unchanged
  expect_equal(g_dense$bit, c(0L, 1L, 2L, 4L, 5L, 6L))
  expect_equal(g_slot$bit,  c(0L, 1L, 3L, 4L, 5L, 7L))
})

# ---- 2. catalog <-> code constants ------------------------------------------

test_that("documented marker byte sets equal the R/ code constants", {
  expect_setequal(IVT_MARKER_SET$page_b0,       ivt_f2_marker_b0)
  expect_setequal(IVT_MARKER_SET$page_b0_dense, ivt_f2_marker_b0_dense)
  expect_setequal(IVT_MARKER_SET$page_b3,       ivt_f2_marker_b3)
  expect_setequal(IVT_MARKER_SET$widths,        IVT_MARKER_WIDTHS)
  # the plain page b0 set IS the width x {0x80, 0xa0} outer sum documented in §C
  expect_setequal(IVT_MARKER_SET$page_b0,
                  as.integer(outer(IVT_MARKER_SET$widths, c(0x80L, 0xa0L), "+")))
})

# ---- 3. corpus inventory (opt-in) -------------------------------------------

corpus_dir <- Sys.getenv("CANIVT_IVT_CACHE")
corpus_on <- nzchar(Sys.getenv("CANIVT_CORPUS_TESTS")) &&
  nzchar(corpus_dir) && dir.exists(corpus_dir)
mk_corpus_file <- function(key) {
  hit <- list.files(file.path(corpus_dir, key), pattern = "\\.ivt$",
                    ignore.case = TRUE, full.names = TRUE)
  if (length(hit)) hit[[1L]] else NA_character_
}
mk_ledger <- utils::read.csv(testthat::test_path("fixtures", "corpus-ledger.csv"),
                             stringsAsFactors = FALSE)

for (i in seq_len(nrow(mk_ledger))) {
  row <- mk_ledger[i, ]
  test_that(paste0("markers: ", row$key), {
    skip_if(!corpus_on, "marker corpus sweep is opt-in: set CANIVT_CORPUS_TESTS=1 (and CANIVT_IVT_CACHE)")
    f <- mk_corpus_file(row$key)
    skip_if(is.na(f), paste0("table ", row$key, " not in the local corpus"))
    raw <- readBin(f, "raw", file.size(f))
    obs <- suppressWarnings(ivt_marker_observe(raw))
    rm(raw); gc(verbose = FALSE)
    # every marker this file exercises must be in the catalog
    expect_identical(ivt_marker_violations(obs), character(0))
    # the file signature is always an IVT one for a corpus table: shared tail
    # `00 20 00`, byte 0 the generation tag (0x04 modern, 0x02 older survey)
    expect_identical(obs$file_sig[2:4], IVT_MARKER_SET$file_sig_tail)
    expect_true(obs$file_sig[1L] %in% IVT_MARKER_SET$file_sig_b0)
    # a supported table's descriptor signature byte (when it HAS a descriptor block)
    # must be catalogued. The no-descriptor-block survey lineage (LFHR / criminal
    # justice, `ivt_f2_descriptor_from_slots()`) has no signature at all, so
    # descriptor_b9 is legitimately NA there -- only assert catalogue membership when
    # a signature is present.
    if (isTRUE(row$supported) && !is.na(obs$descriptor_b9))
      expect_true(obs$descriptor_b9 %in% IVT_MARKER_SET$descriptor_b9)
  })
}
