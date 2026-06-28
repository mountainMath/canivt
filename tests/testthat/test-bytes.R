test_that("little-endian integer readers work at unaligned offsets", {
  # bytes: [pad] 01 00 | 00 01 | ff ff ff 7f
  raw <- as.raw(c(0x99, 0x01, 0x00, 0x00, 0x01, 0xff, 0xff, 0xff, 0x7f))
  expect_equal(rd_u16(raw, 1), 1L)        # 0x0001
  expect_equal(rd_u16(raw, 3), 256L)      # 0x0100
  expect_equal(rd_u32(raw, 5), 2147483647) # 0x7fffffff
})

test_that("rd_int_run reads signed runs", {
  raw <- as.raw(c(0xff, 0xff, 0x05, 0x00))  # int16: -1, 5
  expect_equal(rd_int_run(raw, 0, 2, 2), c(-1L, 5L))
})

test_that("rd_pascal reads length-prefixed latin-1 strings", {
  raw <- as.raw(c(0x06, utf8ToInt("Canada")))
  rec <- rd_pascal(raw, 0)
  expect_equal(rec$text, "Canada")
  expect_equal(rec$end, 7)
  # non-text bytes are rejected
  expect_null(rd_pascal(as.raw(c(0x02, 0x01, 0x02)), 0))
})

test_that("pid normalisation drops version digits", {
  expect_equal(ivt_pid8("98100241"), "98100241")
  expect_equal(ivt_pid8(9810024101), "98100241")
  expect_equal(ivt_pid8("9810024101"), "98100241")
  expect_error(ivt_pid8("123"))
})

test_that("label depth follows indentation", {
  expect_equal(ivt_label_depth(c("Total", "  Owner", "    With mortgage")),
               c(0L, 1L, 2L))
})
