# Offline tests for the internal HTML ground-truth scraper. The live functions
# (ivt_gt_viewer_url, ivt_gt_slice, ivt_ground_truth over the network) are
# exercised manually; here we test the URL + parsing logic against a fixture.

test_that("ivt_gt_set_params replaces existing params and adds new ones", {
  u <- "https://x/Rp.cfm?LANG=E&GID=0&PID=85"
  expect_equal(ivt_gt_set_params(u, list(GID = 2)),
               "https://x/Rp.cfm?LANG=E&GID=2&PID=85")
  expect_equal(ivt_gt_set_params(u, list(d1 = 3)),
               "https://x/Rp.cfm?LANG=E&GID=0&PID=85&d1=3")
  expect_equal(ivt_gt_set_params(u, list()), u)
})

test_that("ivt_gt_slug mirrors the decoder's leading-word convention", {
  expect_equal(ivt_gt_slug("Single Years of Age (110)"), "single")
  expect_equal(ivt_gt_slug("Sex (3)"), "sex")
  expect_equal(ivt_gt_unique_slugs(c("Sex (3)", "Sex at birth")),
               c("sex", "sex1"))
})

test_that("the viewer table parses into a tidy ground-truth tibble", {
  skip_if_not_installed("rvest")
  skip_if_not_installed("xml2")
  doc <- xml2::read_html(test_path("fixtures", "viewer-sample.html"))

  geo <- ivt_gt_geographies(doc)
  expect_equal(geo$gid, c("1", "2"))
  expect_equal(geo$label[1], "Canada")

  fx <- ivt_gt_fixed_dims(doc)
  expect_equal(fx$param, "d1")
  expect_equal(fx$name, "Sex (3)")
  expect_equal(fx$member_id, 1L)          # value 0 -> 1-based position 1
  expect_equal(fx$member_label, "Total - Sex")

  gt <- ivt_gt_parse_table(doc)
  expect_equal(nrow(gt), 4L)
  expect_setequal(
    names(gt),
    c("gid", "geo", "single", "single_id", "region", "region_id",
      "sex", "sex_id", "value"))
  # geography + fixed dim folded in as constants
  expect_true(all(gt$gid == "1"))
  expect_true(all(gt$geo == "Canada"))
  expect_true(all(gt$sex == "Total - Sex"))
  expect_true(all(gt$sex_id == 1L))
  # displayed dims carry member positions from the cell titles
  top <- gt[gt$single_id == 1 & gt$region_id == 1, ]
  expect_equal(top$value, 27296860)
  expect_equal(top$single, "Total - Age Groups")
  # suppression symbol ".." -> NA
  supp <- gt[gt$single_id == 2 & gt$region_id == 2, ]
  expect_true(is.na(supp$value))
})
