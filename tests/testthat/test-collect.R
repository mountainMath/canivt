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
  # data column defaults to the structural slug; geography is not levelled
  expect_setequal(unique(m$column), "age")
  age <- m[m$column == "age", ]
  expect_equal(age$member_id, 1:3)
  expect_equal(age$ordinal, 1:3)
  expect_equal(age$dimension, rep(age_col, 3))          # full EN dimension name
  expect_equal(age$dimension_fr, rep("Âge", 3))         # full FR dimension name
  expect_equal(age$label[2], "  0 to 14 years")     # raw label keeps indentation
  expect_equal(age$level[2], "0 to 14 years")       # level is trimmed like ivt_tidy
  expect_equal(age$level_fr, c("Total - Âge", "0 à 14 ans", "15 ans et plus"))
  expect_equal(age$depth, c(0L, 1L, 1L))
  # the two indented members roll up to the depth-0 "Total" (member 1)
  expect_equal(age$parent_id, c(NA_integer_, 1L, 1L))
  # dim_names = "label" names the data column by the full dimension label
  expect_setequal(unique(ivt_members(fake_ivt(), dim_names = "label")$column),
                  age_col)
})

test_that("ivt_label_parent turns indentation into a parent/child tree", {
  labs <- c("Total - Income groups",   #  depth 0  (1)
            "  Without income",        #  depth 1  (2) -> parent 1
            "  With income",           #  depth 1  (3) -> parent 1
            "    Under $10,000",       #  depth 2  (4) -> parent 3
            "    $10,000 and over",    #  depth 2  (5) -> parent 3
            "  Median income $")       #  depth 1  (6) -> parent 1 (back up a level)
  expect_equal(ivt_label_depth(labs), c(0L, 1L, 1L, 2L, 2L, 1L))
  expect_equal(ivt_label_parent(labs), c(NA, 1L, 1L, 3L, 3L, 1L))
  # a depth skip (0 -> 2) still resolves to the nearest shallower member
  skip_lab <- c("Root", "    Deep child")
  expect_equal(ivt_label_parent(skip_lab), c(NA_integer_, 1L))
  # a flat list (no indentation) has no parents
  expect_equal(ivt_label_parent(c("a", "b", "c")), rep(NA_integer_, 3))
})

test_that("ivt_label_indent_unit reads spaces-per-level off the labels", {
  two <- c("Total", "  A", "    B")
  expect_equal(ivt_label_indent_unit(ivt_label_indent(two)), 2L)
  # the census-of-agriculture geography axis indents ONE space per level, where
  # a fixed unit of 2 collapses Canada/province/CAR/CD/CCS into three levels
  one <- c("Canada", " Newfoundland", "  CAR 1", "   Division No. 1",
           "    Division No. 1, Subdivision C")
  expect_equal(ivt_label_indent_unit(ivt_label_indent(one)), 1L)
  expect_equal(ivt_label_depth(one), c(0L, 0L, 1L, 1L, 2L))       # fixed unit
  expect_equal(ivt_label_depth(one, unit = 1L), 0:4)              # inferred
  expect_equal(ivt_label_parent(one, unit = 1L), c(NA, 1L, 2L, 3L, 4L))
  # a flat set declares no unit, and unit 0 means no hierarchy
  expect_equal(ivt_label_indent_unit(ivt_label_indent(c("a", "b"))), 0L)
  expect_equal(ivt_label_depth(c("a", " b"), unit = 0L), c(0L, 0L))
})

test_that("ivt_label_depth/parent treat NA and empty labels as top-level", {
  # an aggregate member with no name (e.g. geography member 26 on 98-10-0662)
  # arrives as NA; it must map to depth 0 with no parent, not crash the tree
  # walk with a "missing value where TRUE/FALSE needed" error.
  labs <- c("Total", "  A", NA, "", "  B")
  expect_equal(ivt_label_depth(labs), c(0L, 1L, 0L, 0L, 1L))
  expect_equal(ivt_label_parent(labs), c(NA, 1L, NA, NA, 4L))
})

test_that("ivt_tidy(depth = TRUE) adds a <col>_depth column per data dimension", {
  x <- fake_ivt()
  # default output is unchanged: no depth columns
  expect_false(any(grepl("_depth$", names(ivt_tidy(x)))))
  # opt-in: a depth column sits right after its dimension, mapping member -> depth
  d <- ivt_tidy(x, depth = TRUE)
  expect_equal(match("age_depth", names(d)), match("age", names(d)) + 1L)
  # cells age ids 1,2,1 -> depths 0,1,0 (Total, "  0 to 14 years", Total)
  expect_equal(d$age_depth, c(0L, 1L, 0L))
  # the id path (labels = FALSE) recomputes depth from the member list too
  idp <- ivt_tidy(x, labels = FALSE, depth = TRUE)
  expect_equal(match("age_depth", names(idp)), match("age", names(idp)) + 1L)
  expect_equal(idp$age_depth, c(0L, 1L, 0L))
  # dim_names = "label" carries the depth column onto the full-label name
  dl <- ivt_tidy(x, depth = TRUE, dim_names = "label")
  expect_true(paste0(age_col, "_depth") %in% names(dl))
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
  # geography is an identity axis, never levelled -- it stays character
  expect_type(df$geo_name, "character")
  expect_false(any(vapply(df[grep("^geo", names(df))], is.factor, logical(1))))
})

test_that("ivt_members emits no geography rows", {
  m <- ivt_members(fake_ivt())
  expect_false("Geography" %in% m$dimension)
  expect_false(any(grepl("^geo", m$column)))
  expect_true("age" %in% m$column)
})

test_that("collect_ivt ignores the geography rows of an older sidecar", {
  # a member table written before geography was dropped: geo_uid must not
  # become a factor just because a stale cache still levels it
  x <- fake_ivt()
  m <- ivt_members(x)
  old <- rbind(m, tibble::tibble(
    column = "geo_name", dimension = "Geography", dimension_fr = NA_character_,
    member_id = 1:2, ordinal = 1:2, label = c("Canada", "Ontario"),
    level = c("Canada", "Ontario"), level_fr = NA_character_,
    depth = 0L, parent_id = NA_integer_,
    description = NA_character_, description_fr = NA_character_))
  df <- collect_ivt(x, members = old)
  expect_type(df$geo_name, "character")
  expect_s3_class(df$age, "factor")
  # and the attached table is the one actually used, geography stripped
  expect_false("Geography" %in% attr(df, "members", exact = TRUE)$dimension)
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

test_that("label_ivt_columns works either side of collect_ivt", {
  skip_if_not_installed("arrow")
  skip_if_not_installed("dplyr")
  x <- fake_ivt()
  path <- withr::local_tempfile(fileext = ".parquet")
  ivt_write_parquet(x, path = path)                 # slug columns
  ds <- arrow::open_dataset(path)
  attr(ds, "path") <- path

  lvl <- c("Total - Age", "0 to 14 years", "15 years and over")
  # before: rename lazily on the connection, then collect -- the member table
  # still finds the column through the dimension name, so the levels survive
  before <- collect_ivt(label_ivt_columns(ds))
  expect_true(age_col %in% names(before))
  expect_s3_class(before[[age_col]], "factor")
  expect_equal(levels(before[[age_col]]), lvl)

  # after: collect first, then rename the collected data frame
  after <- label_ivt_columns(collect_ivt(ds))
  expect_true(age_col %in% names(after))
  expect_s3_class(after[[age_col]], "factor")
  expect_equal(levels(after[[age_col]]), lvl)

  expect_equal(as.data.frame(before), as.data.frame(after))
})

test_that("collect_ivt attaches the member table it used", {
  skip_if_not_installed("arrow")
  skip_if_not_installed("dplyr")
  x <- fake_ivt()
  path <- withr::local_tempfile(fileext = ".parquet")
  ivt_write_parquet(x, path = path)
  df <- collect_ivt(path)
  # the collected frame knows where its levels came from: no sidecar lookup and
  # no connection needed to relabel it later
  expect_s3_class(attr(df, "members", exact = TRUE), "data.frame")
  expect_equal(attr(df, "path", exact = TRUE), path)
  expect_equal(ivt_parquet_language(df), "en")
  lab <- label_ivt_columns(df)
  expect_true(age_col %in% names(lab))
  # ... and the labelled result stays self-describing
  expect_s3_class(attr(lab, "members", exact = TRUE), "data.frame")
  # an ivt object carries the member table too (it has no Parquet path)
  di <- collect_ivt(x)
  expect_s3_class(attr(di, "members", exact = TRUE), "data.frame")
  expect_null(attr(di, "path", exact = TRUE))
})

test_that("collect_ivt dim_names = 'label' applies to Arrow/Parquet too", {
  skip_if_not_installed("arrow")
  skip_if_not_installed("dplyr")
  x <- fake_ivt()
  base <- withr::local_tempdir()
  en <- file.path(base, "t_en.parquet")
  fr <- file.path(base, "t_fr.parquet")
  ivt_write_parquet(x, path = en, language = "en")
  ivt_write_parquet(x, path = fr, language = "fr")

  # the argument used to be silently ignored on this path
  df <- collect_ivt(en, dim_names = "label")
  expect_true(age_col %in% names(df))
  expect_false("age" %in% names(df))
  expect_s3_class(df[[age_col]], "factor")
  expect_equal(levels(df[[age_col]]),
               c("Total - Age", "0 to 14 years", "15 years and over"))
  # default is unchanged
  expect_true("age" %in% names(collect_ivt(en)))
  # the label language follows the Parquet's own marker
  dffr <- collect_ivt(fr, dim_names = "label")
  expect_true("Âge" %in% names(dffr))
  expect_equal(levels(dffr[["Âge"]]),
               c("Total - Âge", "0 à 14 ans", "15 ans et plus"))
  # and it is idempotent: already-labelled columns are left alone
  ds <- arrow::open_dataset(en)
  attr(ds, "path") <- en
  twice <- collect_ivt(label_ivt_columns(ds), dim_names = "label")
  expect_true(age_col %in% names(twice))
  expect_equal(levels(twice[[age_col]]), levels(df[[age_col]]))
})

test_that("ivt_member_col_map falls back to the dimension name, without stealing", {
  m <- ivt_members(fake_ivt())                       # column = "age"
  # the written name wins
  expect_equal(unname(ivt_member_col_map(m, c("age", "geo_uid"))[["age"]]), "age")
  # renamed to the full label: recovered through `dimension`
  expect_equal(unname(ivt_member_col_map(m, c(age_col, "geo_uid"))[["age"]]),
               age_col)
  # French label, recovered through `dimension_fr`
  expect_equal(unname(ivt_member_col_map(m, "Âge", language = "fr")[["age"]]),
               "Âge")
  # neither present -> NA, and factorizing is then a no-op rather than an error
  expect_true(is.na(ivt_member_col_map(m, c("something_else"))[["age"]]))
  # a label match never claims a column an exact slug match already owns
  m2 <- rbind(m, transform(m[m$column == "age", ], column = "other",
                           dimension = "age"))
  mp <- ivt_member_col_map(m2, c("age", "geo_uid"))
  expect_equal(unname(mp[["age"]]), "age")
  expect_true(is.na(mp[["other"]]))
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
