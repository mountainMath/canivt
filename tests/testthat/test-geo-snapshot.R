# Geography read snapshot -- the byte-identical net for the §7 geography
# consolidation (refactor-plan.md §7). Opt-in exactly like the corpus ledger
# (needs the local .ivt corpus), driven off the same ledger keys.
#
#   CANIVT_CORPUS_TESTS=1 CANIVT_IVT_CACHE=~/data/ivt_raw \
#     Rscript -e 'devtools::test(filter = "geo-snapshot")'
#
# For each corpus table it re-reads geography through both paths (light always,
# full for GEO_SNAP_FULL) and asserts the deterministic hash of the returned
# object AND the ordered canivt_* warning set match fixtures/geo-snapshot.csv.
# A hash change = the geography read drifted; a warning change = a loud fallback
# appeared or vanished. Regenerate the fixture (only when a change is intended
# and reviewed) with geo_snapshot_regen() below.

corpus_dir <- Sys.getenv("CANIVT_IVT_CACHE")
corpus_on <- nzchar(Sys.getenv("CANIVT_CORPUS_TESTS")) &&
  nzchar(corpus_dir) && dir.exists(corpus_dir)

geo_snap_file <- function(key) {
  hit <- list.files(file.path(corpus_dir, key), pattern = "\\.ivt$",
                    ignore.case = TRUE, full.names = TRUE)
  if (length(hit)) hit[[1L]] else NA_character_
}

geo_snap_fixture_path <- testthat::test_path("fixtures", "geo-snapshot.csv")
geo_snap_fixture <- if (file.exists(geo_snap_fixture_path)) {
  utils::read.csv(geo_snap_fixture_path, stringsAsFactors = FALSE,
                  colClasses = "character", na.strings = "NA")
} else {
  data.frame()   # absent only mid-regen (see geo_snapshot_regen below)
}

for (i in seq_len(nrow(geo_snap_fixture))) {
  row <- geo_snap_fixture[i, ]
  test_that(paste0("geo-snapshot: ", row$key), {
    skip_if(!corpus_on, "geo-snapshot tests are opt-in: set CANIVT_CORPUS_TESTS=1 (and CANIVT_IVT_CACHE)")
    f <- geo_snap_file(row$key)
    skip_if(is.na(f), paste0("table ", row$key, " not in the local corpus"))
    raw <- readBin(f, "raw", file.size(f))
    do_full <- !is.na(row$full_hash)
    got <- geo_snap_digest(geo_snap_one(raw, do_full = do_full))
    rm(raw); gc(verbose = FALSE)

    expect_identical(got$light_hash, row$light_hash)
    expect_identical(geo_snap_nastr(got$light_warnings), geo_snap_nastr(row$light_warnings))
    if (do_full) {
      expect_identical(got$full_hash, row$full_hash)
      expect_identical(geo_snap_nastr(got$full_warnings), geo_snap_nastr(row$full_warnings))
    }
  })
}

# Regenerate fixtures/geo-snapshot.csv from the current code. Run ONLY when a
# geography read change is intended and reviewed -- the fixture is the frozen
# baseline the refactor steps must reproduce. Uses the corpus ledger's key list
# so it excludes stray folders.
#
#   CANIVT_IVT_CACHE=~/data/ivt_raw Rscript -e \
#     'devtools::load_all("."); source("tests/testthat/test-geo-snapshot.R"); geo_snapshot_regen()'
geo_snapshot_regen <- function(
    corpus_dir = Sys.getenv("CANIVT_IVT_CACHE", "~/data/ivt_raw"),
    out = "tests/testthat/fixtures/geo-snapshot.csv") {
  corpus_dir <- path.expand(corpus_dir)
  ledger <- utils::read.csv(
    file.path("tests", "testthat", "fixtures", "corpus-ledger.csv"),
    stringsAsFactors = FALSE)
  rows <- list()
  for (key in ledger$key) {
    hit <- list.files(file.path(corpus_dir, key), pattern = "\\.ivt$",
                      ignore.case = TRUE, full.names = TRUE)
    if (!length(hit)) { message("skip (absent): ", key); next }
    message("regen: ", key)
    raw <- readBin(hit[[1L]], "raw", file.size(hit[[1L]]))
    d <- geo_snap_digest(geo_snap_one(raw, do_full = key %in% GEO_SNAP_FULL))
    rows[[length(rows) + 1L]] <- data.frame(
      key = key, n_geo = d$n_geo,
      light_hash = d$light_hash, light_warnings = d$light_warnings,
      full_hash = d$full_hash, full_warnings = d$full_warnings,
      stringsAsFactors = FALSE)
    rm(raw); gc(verbose = FALSE)
  }
  df <- do.call(rbind, rows)
  utils::write.csv(df, out, row.names = FALSE, na = "NA")
  message("wrote ", out, " (", nrow(df), " rows)")
  invisible(df)
}
