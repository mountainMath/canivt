# The structural page-marker model (decode.R) and the loud-fallback machinery
# (fallback.R). Pure unit tests -- no sample file needed.

test_that("the value trailer is derived structurally from the marker's b2 byte", {
  # b2 == 0x00: the value run starts immediately after the presence record
  expect_equal(ivt_value_trailer(0x84L, 0x00L), 0L)
  expect_equal(ivt_value_trailer(0x88L, 0x00L), 0L)
  # trailer = 2*(b2 >> 4) + 2*(low nibble > 0): the historically constant pairs
  expect_equal(ivt_value_trailer(0x88L, 0x20L), 4L)   # float64
  expect_equal(ivt_value_trailer(0x84L, 0x40L), 8L)   # int32
  expect_equal(ivt_value_trailer(0x82L, 0x80L), 16L)  # int16
  expect_equal(ivt_value_trailer(0xa8L, 0x41L), 10L)  # float64
  expect_equal(ivt_value_trailer(0xa4L, 0x82L), 18L)  # int32
  # ... and 98-10-0013's varying b2 values (each anchored vs the StatCan CSV)
  expect_equal(ivt_value_trailer(0xa8L, 0x2aL), 6L)
  expect_equal(ivt_value_trailer(0xa8L, 0x30L), 6L)
  expect_equal(ivt_value_trailer(0xa8L, 0x31L), 8L)
  expect_equal(ivt_value_trailer(0xa8L, 0x4eL), 10L)
  expect_equal(ivt_value_trailer(0xa8L, 0x53L), 12L)
  expect_equal(ivt_value_trailer(0xa8L, 0x60L), 12L)
  expect_equal(ivt_value_trailer(0xa8L, 0x63L), 14L)
  # the 0xa2 int16 pages carry a fixed 32-byte auxiliary block before the run
  expect_equal(ivt_value_trailer(0xa2L, 0x03L), 34L)
  # unknown width code or high nibble: abort rather than decode garbage
  expect_error(ivt_value_trailer(0x86L, 0x01L), class = "canivt_unknown_marker")
  expect_error(ivt_value_trailer(0x81L, 0x01L), class = "canivt_unknown_marker")
  expect_error(ivt_value_trailer(0x48L, 0x01L), class = "canivt_unknown_marker")
})

test_that("ivt_fallback warns with a classed condition", {
  expect_warning(ivt_fallback("test fallback engaged"), class = "canivt_fallback")
  expect_warning(ivt_fallback("pages missing", class = "canivt_skipped_pages"),
                 class = "canivt_skipped_pages")
})

test_that("strict mode turns fallbacks into classed errors", {
  withr::local_options(canivt.strict = TRUE)
  expect_error(ivt_fallback("test fallback engaged"), class = "canivt_fallback_error")
  expect_error(ivt_fallback("pages missing", class = "canivt_skipped_pages"),
               class = "canivt_skipped_pages_error")
})

test_that("ivt_quietly muffles fallback conditions for detection probes", {
  expect_no_warning(v <- ivt_quietly({ ivt_fallback("probe"); 42L }))
  expect_equal(v, 42L)
  # under strict mode the refused fallback reads as "not found", not an error
  withr::local_options(canivt.strict = TRUE)
  expect_no_error(v2 <- ivt_quietly({ ivt_fallback("probe"); 42L }))
  expect_null(v2)
})
