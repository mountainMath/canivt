# list_ivt_cache(): enumerate the ivt + data-parquet caches, enriched with the
# catalogue. Uses temporary cache dirs and synthetic files (no network).

# populate a temp ivt + data cache; returns the two dir paths
seed_cache <- function(env = parent.frame()) {
  ivtd  <- withr::local_tempdir(.local_envir = env)
  datad <- withr::local_tempdir(.local_envir = env)
  withr::local_options(list(canivt.ivt_cache = ivtd, canivt.data_cache = datad),
                       .local_envir = env)
  # a raw .ivt in a per-table subfolder (file named differently from the folder)
  dir.create(file.path(ivtd, "98-10-0241"))
  writeBin(as.raw(c(4, 0, 32, 0)),
           file.path(ivtd, "98-10-0241", "98100241.ivt"))
  # a flat .ivt at the cache root
  writeBin(as.raw(c(4, 0, 32, 0)), file.path(ivtd, "local1.ivt"))
  # data parquets: en/fr tables, a member sidecar, an old unmarked table, the
  # catalogue cache (the last two-plus-sidecar handling is what we assert)
  if (requireNamespace("arrow", quietly = TRUE)) {
    for (nm in c("98100241_en.parquet", "98100241_fr.parquet",
                 "98100241_members.parquet", "oldtable.parquet",
                 "statcan_ivt_catalogue.parquet"))
      arrow::write_parquet(data.frame(a = 1L), file.path(datad, nm))
  }
  list(ivt = ivtd, data = datad)
}

test_that("list_ivt_cache lists ivt + data parquets, excluding sidecar/catalogue", {
  skip_if_not_installed("arrow")
  seed_cache()
  tab <- list_ivt_cache()
  expect_setequal(names(tab), c("kind", "key", "language", "catalogue", "title",
                                "census_year", "topic", "bytes", "modified", "path"))
  # 2 ivt + 3 data parquets (en, fr, old); sidecar + catalogue cache excluded
  expect_equal(sum(tab$kind == "ivt"), 2L)
  expect_equal(sum(tab$kind == "parquet"), 3L)
  expect_false(any(grepl("_members\\.parquet$", tab$path)))
  expect_false(any(basename(tab$path) == "statcan_ivt_catalogue.parquet"))
})

test_that("list_ivt_cache derives keys and parses the language marker", {
  skip_if_not_installed("arrow")
  seed_cache()
  tab <- list_ivt_cache()
  # ivt key is the per-table FOLDER, or the file stem for a flat file
  ivt <- tab[tab$kind == "ivt", ]
  expect_setequal(ivt$key, c("98-10-0241", "local1"))
  expect_true(all(is.na(ivt$language)))            # .ivt has no language
  # parquet key + language from <key>[_en|_fr].parquet
  pq <- tab[tab$kind == "parquet", ]
  expect_equal(pq$language[pq$key == "98100241"], c("en", "fr"))  # sorted
  expect_true(is.na(pq$language[pq$key == "oldtable"]))            # unmarked = old
})

test_that("list_ivt_cache enriches from a catalogue by normalised key", {
  skip_if_not_installed("arrow")
  seed_cache()
  catl <- tibble::tibble(catalogue = "98-10-0241-01", title = "Housing",
                         census_year = 2021L, topic = "Housing and dwellings")
  tab <- list_ivt_cache(catalogue = catl)
  # both the folder-key (98-10-0241) and the parquet key (98100241) match by prefix
  hit <- tab[tab$key %in% c("98-10-0241", "98100241"), ]
  expect_true(all(hit$catalogue == "98-10-0241-01"))
  expect_true(all(hit$title == "Housing"))
  expect_true(all(hit$census_year == 2021L))
  # a key with no catalogue match stays NA
  expect_true(all(is.na(tab$title[tab$key %in% c("local1", "oldtable")])))
})

test_that("list_ivt_cache tolerates a malformed / missing catalogue", {
  skip_if_not_installed("arrow")
  seed_cache()
  # the seeded catalogue cache has the wrong schema -> enrichment skipped, no error
  expect_warning(tab <- list_ivt_cache(), NA)
  expect_true(all(is.na(tab$title)))
})

test_that("list_ivt_cache returns a typed empty tibble for empty caches", {
  ivtd <- withr::local_tempdir(); datad <- withr::local_tempdir()
  withr::local_options(list(canivt.ivt_cache = ivtd, canivt.data_cache = datad))
  tab <- list_ivt_cache()
  expect_equal(nrow(tab), 0L)
  expect_true(all(c("kind", "key", "language", "catalogue", "bytes", "path") %in%
                    names(tab)))
})
