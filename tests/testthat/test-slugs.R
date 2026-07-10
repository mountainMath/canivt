# Data-dimension column slugs (codebook-f2.R). Pure unit tests -- no sample
# file needed.

test_that("ivt_dim_slug takes the lower-cased leading word, else dim<i>", {
  expect_equal(ivt_dim_slug("Marital status", 2L), "marital")
  expect_equal(ivt_dim_slug("Age (in single years)", 3L), "age")
  expect_equal(ivt_dim_slug("2021 Household Income (3)", 4L), "household")
  expect_equal(ivt_dim_slug("(!!)", 5L), "dim5")
  expect_equal(ivt_dim_slug(NA_character_, 6L), "dim6")
})

test_that("slugs are unique against the reserved output columns geo/value", {
  # `ivt_decode()` assigns "geo" to the geography column and appends "value";
  # a dimension slugging to either ("Value of dwelling" is a real census
  # dimension) must not collide -- the value column would silently overwrite
  # the member-id column and ivt_f2_tidy() would drop the dimension.
  s <- ivt_dim_slugs(c("Value of dwelling", "Tenure"), idx = c(2L, 3L))
  expect_equal(s, c("value1", "tenure"))
  s <- ivt_dim_slugs(c("Geo classification", "Age"), idx = c(2L, 3L))
  expect_equal(s, c("geo1", "age"))
  # ... and against each other, as before
  s <- ivt_dim_slugs(c("Age of maintainer", "Age at immigration"), idx = c(2L, 3L))
  expect_equal(s, c("age", "age1"))
  # non-colliding slugs are untouched
  s <- ivt_dim_slugs(c("Tenure", "Statistics"), idx = c(2L, 3L))
  expect_equal(s, c("tenure", "statistics"))
})
