# ivt_members() / collect_ivt(): full-level factor conversion for tidy /
# Parquet output. The unit tests run on a synthetic ivt object (no sample file
# needed); the ordinal-parsing integration test needs CANIVT_SAMPLE_IVT.

fake_ivt <- function() {
  cells <- tibble::tibble(geo = c(1L, 1L, 2L),
                          age = c(1L, 2L, 1L),
                          value = c(10, 20, 5))
  dims <- list(
    list(name = "Geography", count = 2L, type = 0x10L, is_geography = TRUE,
         members = NULL, ordinal = NULL),
    list(name = "Age (in single years)", name_fr = "Âge", count = 3L,
         type = 0x07L, is_geography = FALSE,
         members = c("Total - Age", "  0 to 14 years", "  15 years and over"),
         members_fr = c("Total - Âge", "  0 à 14 ans", "  15 ans et plus"),
         ordinal = 1:3))
  meta <- list(
    product_id = "test-0001", title_en = "Test table", title_fr = "Table test",
    universe = NA_character_,
    dimensions = dims,
    dimension_names = c("Geography", "Age (in single years)"),
    dimension_counts = c(2L, 3L),
    geographies = list(geo_name = c("Canada", "Ontario"),
                       geo_uid = c("2021A000011124", "2021A000235"),
                       member_id = 1:2),
    n_geographies = 2L, footnotes = list(), dqf_legend = NULL)
  structure(list(cells = cells, metadata = meta, path = "fake", family = 2L),
            class = "ivt")
}

# the fake table's single data dimension: terse slug (default) vs full label
age_col <- "Age (in single years)"

test_that("ivt_members builds the full level table in ordinal order", {
  m <- ivt_members(fake_ivt())
  # data column defaults to the structural slug; geography columns unchanged
  expect_setequal(unique(m$column), c("age", "geo_name", "geo_uid"))
  age <- m[m$column == "age", ]
  expect_equal(age$member_id, 1:3)
  expect_equal(age$ordinal, 1:3)
  expect_equal(age$dimension, rep(age_col, 3))          # full EN dimension name
  expect_equal(age$dimension_fr, rep("Âge", 3))         # full FR dimension name
  expect_equal(age$label[2], "  0 to 14 years")     # raw label keeps indentation
  expect_equal(age$level[2], "0 to 14 years")       # level is trimmed like ivt_tidy
  expect_equal(age$level_fr, c("Total - Âge", "0 à 14 ans", "15 ans et plus"))
  expect_equal(age$depth, c(0L, 1L, 1L))
  geo <- m[m$column == "geo_uid", ]
  expect_equal(geo$level, c("2021A000011124", "2021A000235"))
  expect_equal(unique(geo$dimension), "Geography")
  # dim_names = "label" names the data column by the full dimension label
  expect_setequal(unique(ivt_members(fake_ivt(), dim_names = "label")$column),
                  c(age_col, "geo_name", "geo_uid"))
})

test_that("collect_ivt on an ivt object yields factors with ALL member levels", {
  x <- fake_ivt()
  df <- collect_ivt(x)
  expect_s3_class(df$age, "factor")                 # slug column by default
  # the third member never occurs in the cells but is still a level
  expect_equal(levels(df$age),
               c("Total - Age", "0 to 14 years", "15 years and over"))
  expect_equal(as.character(df$age),
               c("Total - Age", "0 to 14 years", "Total - Age"))
  # geography stays character by default, converts on request
  expect_type(df$geo_name, "character")
  df2 <- collect_ivt(x, geography = TRUE)
  expect_s3_class(df2$geo_name, "factor")
  expect_equal(levels(df2$geo_name), c("Canada", "Ontario"))
})

test_that("collect_ivt language = 'fr' yields French levels (and French labels)", {
  # slug columns by default, but the levels are French
  df <- collect_ivt(fake_ivt(), language = "FR")   # upper-case normalises
  expect_true("age" %in% names(df))
  expect_s3_class(df$age, "factor")
  expect_equal(levels(df$age), c("Total - Âge", "0 à 14 ans", "15 ans et plus"))
  # dim_names = "label" + fr names the column by the French dimension name
  df2 <- collect_ivt(fake_ivt(), dim_names = "label", language = "fr")
  expect_true("Âge" %in% names(df2))
  expect_equal(levels(df2[["Âge"]]),
               c("Total - Âge", "0 à 14 ans", "15 ans et plus"))
})

test_that("collect_ivt dim_names = 'label' names the data column by its label", {
  df <- collect_ivt(fake_ivt(), dim_names = "label")
  expect_s3_class(df[[age_col]], "factor")
  expect_equal(levels(df[[age_col]]),
               c("Total - Age", "0 to 14 years", "15 years and over"))
})

test_that("collect_ivt maps the compact integer-id table through member ids", {
  x <- fake_ivt()
  df <- collect_ivt(x, labels = FALSE)
  expect_s3_class(df$age, "factor")
  expect_equal(as.integer(df$age), c(1L, 2L, 1L))   # ordinal order == id order
  expect_equal(levels(df$age),
               c("Total - Age", "0 to 14 years", "15 years and over"))
  expect_type(df$geo, "integer")                    # the id key is left alone
})

test_that("collect_ivt honours a non-identity ordinal order", {
  x <- fake_ivt()
  x$metadata$dimensions[[2]]$ordinal <- c(3L, 1L, 2L)
  df <- collect_ivt(x)
  expect_equal(levels(df$age),
               c("0 to 14 years", "15 years and over", "Total - Age"))
})

test_that("collect_ivt round-trips through the Parquet sidecar and keeps filtered levels", {
  skip_if_not_installed("arrow")
  skip_if_not_installed("dplyr")
  x <- fake_ivt()
  path <- withr::local_tempfile(fileext = ".parquet")
  ivt_write_parquet(x, path = path)                 # slug columns by default
  expect_true(file.exists(ivt_members_path(path)))

  # a bare path
  df <- collect_ivt(path)
  expect_equal(levels(df$age),
               c("Total - Age", "0 to 14 years", "15 years and over"))

  # an arrow dataset with attributes (as get_statcan_ivt attaches them)
  ds <- arrow::open_dataset(path)
  attr(ds, "path") <- path
  attr(ds, "members") <- ivt_read_members(ivt_members_path(path))
  df <- collect_ivt(ds)
  expect_s3_class(df$age, "factor")

  # a dplyr query that filters a member out entirely: its level survives
  q <- dplyr::filter(ds, age == "Total - Age")
  df <- collect_ivt(q)
  expect_equal(as.character(unique(df$age)), "Total - Age")
  expect_equal(levels(df$age),
               c("Total - Age", "0 to 14 years", "15 years and over"))
})

test_that("label_ivt_columns renames slug columns to full labels on the connection", {
  skip_if_not_installed("arrow")
  skip_if_not_installed("dplyr")
  x <- fake_ivt()
  path <- withr::local_tempfile(fileext = ".parquet")
  ivt_write_parquet(x, path = path)
  ds <- arrow::open_dataset(path)
  attr(ds, "path") <- path
  # rename lazily on the connection, then collect
  lab <- label_ivt_columns(ds)
  expect_true(age_col %in% names(lab))
  expect_false("age" %in% names(lab))
  df <- dplyr::collect(lab)
  expect_true(age_col %in% names(df))
  # explicit French labels
  labfr <- label_ivt_columns(ds, language = "fr")
  expect_true("Âge" %in% names(labfr))
  # geography columns are left untouched
  expect_true("geo_name" %in% names(lab))
})

test_that("ivt_parquet_language reads the file-name marker", {
  expect_equal(ivt_parquet_language("/x/98100241_en.parquet"), "en")
  expect_equal(ivt_parquet_language("/x/98100241_fr.parquet"), "fr")
  expect_equal(ivt_parquet_language("/x/98100241.parquet"), "en")   # no marker
})

test_that("English and French Parquets coexist and share one sidecar", {
  skip_if_not_installed("arrow")
  base <- withr::local_tempdir()
  en <- file.path(base, "t_en.parquet")
  fr <- file.path(base, "t_fr.parquet")
  ivt_write_parquet(fake_ivt(), path = en, language = "en")
  ivt_write_parquet(fake_ivt(), path = fr, language = "fr")
  expect_true(file.exists(en) && file.exists(fr))
  # the language marker is stripped -> one shared sidecar
  expect_equal(ivt_members_path(en), ivt_members_path(fr))
  expect_true(file.exists(ivt_members_path(en)))
  # collect auto-detects fr from the path and factors on French levels
  df <- collect_ivt(fr)
  expect_equal(levels(df$age), c("Total - Âge", "0 à 14 ans", "15 ans et plus"))
})

test_that("collect_ivt aborts helpfully without a member table", {
  skip_if_not_installed("arrow")
  skip_if_not_installed("dplyr")
  x <- fake_ivt()
  path <- withr::local_tempfile(fileext = ".parquet")
  ivt_write_parquet(x, path = path, members = FALSE)
  expect_false(file.exists(ivt_members_path(path)))
  ds <- arrow::open_dataset(path)
  expect_error(collect_ivt(ds), "member-level")
  # but an explicit member table always works
  df <- collect_ivt(ds, members = ivt_members(x))
  expect_s3_class(df$age, "factor")
})

test_that("the member-ordinal blocks parse from the sample IVT", {
  p <- locate_sample_ivt("CANIVT_SAMPLE_IVT", "98100241",
                         legacy = path.expand("~/projects/censusmapper-import/data/raw/98100241/98100241.ivt"))
  skip_if(p == "", "no sample IVT (set CANIVT_SAMPLE_IVT)")
  raw <- readBin(p, "raw", n = file.info(p)$size)
  ords <- ivt_f2_dim_dir_ordinals(raw)
  d <- ivt_f2_descriptor(raw)
  expect_length(ords, length(d$dims))
  expect_null(ords[[1]])                        # geography is skipped
  # every data dimension of 98-10-0241 stores an identity ordinal block
  for (k in 2:length(d$dims)) {
    expect_equal(ords[[k]], seq_len(d$dims[[k]]$count), info = paste("dim", k))
  }
  # and the dimension model carries them through
  dims <- ivt_f2_dimensions(raw)
  for (k in 2:length(dims)) {
    expect_equal(dims[[k]]$ordinal, seq_len(dims[[k]]$count))
  }
})
