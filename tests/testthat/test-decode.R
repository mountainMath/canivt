# Integration tests against a real sample IVT. The .ivt files are large and not
# shipped with the package; point CANIVT_SAMPLE_IVT at a copy of 98100241.ivt
# (StatCan table 98-10-0241) to run these. They skip otherwise.
sample_ivt <- function() {
  locate_sample_ivt("CANIVT_SAMPLE_IVT", "98100241",
                    legacy = path.expand("~/projects/censusmapper-import/data/raw/98100241/98100241.ivt"))
}

# A second family-1 table with different (and more) dimensions: 98-10-0077,
# "Economic family income by family structure", which spans the 2021 AND 2016
# censuses and so carries a reference-period dimension ("Year (2)"). Point
# CANIVT_SAMPLE_IVT_F1_077 at a copy of 98100077.ivt to run; skips otherwise.
sample_ivt_077 <- function() {
  locate_sample_ivt("CANIVT_SAMPLE_IVT_F1_077", "98100077")
}

test_that("the header descriptor decodes all family-1 dimensions (incl. type 0x08 geography)", {
  p <- sample_ivt()
  skip_if(p == "", "no sample IVT (set CANIVT_SAMPLE_IVT)")
  raw <- readBin(p, "raw", n = file.info(p)$size)
  d <- ivt_f2_descriptor(raw)
  expect_equal(d$n_dim, 7L)
  expect_equal(length(d$dims), 7L)
  expect_equal(vapply(d$dims, function(x) x$count, 1L),
               c(166L, 9L, 16L, 13L, 3L, 6L, 7L))
  # geography is the first dimension with a non-0x10 type byte in this layout
  expect_equal(d$dims[[1]]$type, 0x08L)
  expect_equal(d$dims[[1]]$name, "Geography")
  expect_equal(ivt_f2_geo_count(raw), 166L)   # positional, not the 16383 fixed-offset misread
})

test_that("the descriptor recovers the reference-period (facet) dimension of 98-10-0077", {
  p <- sample_ivt_077()
  skip_if(p == "", "no 98-10-0077 sample (set CANIVT_SAMPLE_IVT_F1_077)")
  raw <- readBin(p, "raw", n = file.info(p)$size)
  expect_equal(ivt_family(raw), 1L)
  d <- ivt_f2_descriptor(raw)
  # 7 dimensions; the 7th ("Year (2)") was dropped by the old type-then-01 scan
  # because its record is type-first with a doubled 0x01 separator.
  expect_equal(d$n_dim, 7L)
  expect_equal(length(d$dims), 7L)
  expect_equal(vapply(d$dims, function(x) x$count, 1L),
               c(174L, 9L, 5L, 18L, 6L, 22L, 2L))
  year <- d$dims[[7L]]
  expect_equal(year$type, 0x0eL)             # reference-period / facet type byte
  expect_equal(year$count, 2L)
  expect_match(year$name, "^Year")
  # the descriptor geography count is 174. Year is the innermost *in-page*
  # dimension (the value run carries the 2020 and 2015 values consecutively),
  # NOT a geography facet -- so the uniform decoder keys 174 geographies. (The
  # retired legacy 0x1000-stride counter read 348 here, an artefact of striding
  # a directory whose real per-geography stride is 0x2000 -- ivt_layout() now
  # computes the stride per table.)
  expect_equal(ivt_f2_geo_count(raw), 174L)
})

test_that("all six 98-10-0077 data dimensions label, incl. Ages and Year", {
  p <- sample_ivt_077()
  skip_if(p == "", "no 98-10-0077 sample (set CANIVT_SAMPLE_IVT_F1_077)")
  raw <- readBin(p, "raw", n = file.info(p)$size)
  dims <- ivt_f2_dimensions(raw)
  data_dims <- Filter(function(d) !d$is_geography, dims)
  # every data dimension has a full member-label list (the codebook doubled-name
  # markers anchor them by name). Ages-18 (English block carries 2 leading framing
  # records) and Year-2 (reference period, no trailing ordinal block) were the two
  # formerly-empty dimensions; they now label like the rest.
  nlab <- vapply(data_dims, function(d) length(d$members), 1L)
  expect_equal(nlab, vapply(data_dims, function(d) as.integer(d$count), 1L))
  ages <- data_dims[[which(vapply(data_dims, function(d) d$count, 1L) == 18L)]]
  expect_equal(length(ages$members), 18L)
  expect_match(trimws(ages$members[1]), "^Total - Economic families by number")
  year <- data_dims[[which(vapply(data_dims, function(d) d$count, 1L) == 2L)]]
  expect_equal(trimws(year$members), c("2020", "2015"))
})

test_that("codebook parses identity, members and geo DGUIDs", {
  p <- sample_ivt()
  skip_if(p == "", "no sample IVT (set CANIVT_SAMPLE_IVT)")
  m <- ivt_metadata(p)
  expect_equal(m$product_id, "98100241")
  expect_equal(length(m$geographies$geo_name), 166L)
  expect_equal(m$geographies$geo_name[1], "Canada")
  # geography is parsed schema-driven (content-free): the name is the file's named
  # GEO_NAME field -- the canonical short name "Corner Brook", not the long display
  # label "Corner Brook (CA), N.L." the old content-sniffing path returned.
  expect_equal(trimws(m$geographies$geo_name[3]), "Corner Brook")
  expect_equal(m$geographies$geo_uid[1], "2021A000011124")
  expect_equal(m$geographies$geo_uid[166], "2021A000262")
  expect_true(all(nzchar(m$geographies$geo_uid)))
  # member labels for the data dimensions come from the generic descriptor-driven
  # codebook path (no hard-coded dimension table); geography has no member labels.
  counts <- vapply(m$dimensions[-1L], function(d) length(d$members), 1L)
  expect_equal(counts, c(9L, 16L, 13L, 3L, 6L, 7L))
  expect_equal(unname(m$dimension_counts), c(166L, 9L, 16L, 13L, 3L, 6L, 7L))
})

test_that("geography is parsed from the file's attribute schema, content-free", {
  p <- sample_ivt()
  skip_if(p == "", "no sample IVT (set CANIVT_SAMPLE_IVT)")
  raw <- readBin(p, "raw", n = file.info(p)$size)
  # the geography attribute schema is read from the file (the named field list),
  # not hard-coded -- it names each attribute array so DGUID/GEO_NAME are addressed
  # by name rather than by sniffing a "2021..." prefix or a "Canada" first entry.
  schema <- ivt_f2_geo_schema(raw)
  expect_true(all(c("GEO_NAME", "DGUID") %in% schema))
  expect_equal(schema[1], "GEO_NAME")
  s <- ivt_f2_geo_simple(raw, ivt_f2_geo_count(raw))
  expect_equal(length(s$name), 166L)
  expect_equal(length(s$dguid), 166L)
  # DGUIDs are byte-identical to the legacy "2021..."-content scan, but located
  # purely by the schema's DGUID slot (no year literal).
  expect_equal(s$dguid, ivt_f2_geo_dguids(raw))
  expect_false(anyNA(s$name))
})

test_that("the header dimension slot table drives labels and footnotes", {
  p <- sample_ivt()
  skip_if(p == "", "no sample IVT (set CANIVT_SAMPLE_IVT)")
  raw <- readBin(p, "raw", n = file.info(p)$size)
  # one 14-byte slot per descriptor dimension at @824 + 14*(k-1); each resolves
  # to that dimension's block directory (dictionary, ordinals, doubled-name
  # marker, EN/FR member blocks, footnotes), validated by the slot's entry count.
  slots <- ivt_f2_dim_slots(raw)
  expect_equal(length(slots), 7L)
  expect_equal(nrow(ivt_f2_dim_dir(raw, 1L, slots)), 58L)   # geography codebook
  lab <- ivt_f2_dim_dir_labels(raw)
  expect_null(lab[[1L]])
  expect_equal(vapply(lab[-1L], function(x) length(x$en), 1L),
               c(9L, 16L, 13L, 3L, 6L, 7L))
  # the positional read is byte-identical to the marker-anchored scan
  dims <- ivt_f2_dimensions(raw)
  for (i in 2:7) expect_identical(lab[[i]]$en, dims[[i]]$members)
  # footnotes come from the slot directories, attributed to their dimension
  fn <- ivt_f2_dir_footnotes(raw)
  expect_equal(length(fn), 20L)
  expect_true(all(nzchar(vapply(fn, `[[`, "", "dimension"))))
})

test_that("all 98-10-0077 dimensions label from the slot directories, incl. Ages and Year", {
  p <- sample_ivt_077()
  skip_if(p == "", "no 98-10-0077 sample (set CANIVT_SAMPLE_IVT_F1_077)")
  raw <- readBin(p, "raw", n = file.info(p)$size)
  lab <- ivt_f2_dim_dir_labels(raw)
  expect_equal(vapply(lab[-1L], function(x) length(x$en), 1L),
               c(9L, 5L, 18L, 6L, 22L, 2L))
  # Ages' EN block carries 2 leading framing records (only its trailing 18 are
  # labels) and Year is a 2-member reference period whose EN/FR blocks are
  # identical -- both read correctly by position.
  expect_match(trimws(lab[[4L]]$en[1]), "^Total - Economic families by number")
  expect_equal(trimws(lab[[7L]]$en), c("2020", "2015"))
  expect_equal(trimws(lab[[7L]]$fr), c("2020", "2015"))   # Year: identical EN/FR
  dims <- ivt_f2_dimensions(raw)
  for (i in 2:7) expect_identical(lab[[i]]$en, dims[[i]]$members)
})

test_that("footnotes are extracted in both languages", {
  p <- sample_ivt()
  skip_if(p == "", "no sample IVT (set CANIVT_SAMPLE_IVT)")
  m <- ivt_metadata(p)
  langs <- vapply(m$footnotes, function(f) f$language, "")
  expect_equal(sum(langs == "en"), 10L)
  expect_equal(sum(langs == "fr"), 10L)
  en <- vapply(m$footnotes[langs == "en"], function(f) f$text, "")
  # whole footnote bodies are captured (one maximal text run each), incl. a long
  # multi-paragraph one and a short one-liner
  expect_true(any(grepl("^Includes data up to May 11, 2021\\.$", en)))
  expect_true(any(grepl("Dwelling condition.*Housing suitability", en)))
  expect_true(all(nchar(en) > 0L))
})

test_that("footnotes are attributed to a scope (dimension / member) via the member bitmap", {
  p <- sample_ivt()
  skip_if(p == "", "no sample IVT (set CANIVT_SAMPLE_IVT)")
  m <- ivt_metadata(p)
  # every record carries the uniform field set
  for (f in m$footnotes)
    expect_true(all(c("scope", "dimension", "member_id") %in% names(f)))
  # collapse the English footnotes to their (dimension, member) targets and match
  # them against StatCan's own WDS footnote links for 98-10-0241 -- exact set.
  en <- Filter(function(f) f$language == "en", m$footnotes)
  targets <- unique(vapply(en, function(f)
    sprintf("%s|%s", f$dimension,
            if (is.na(f$member_id)) "dim" else f$member_id), ""))
  dn <- m$dimension_names
  expect_setequal(targets, c(
    sprintf("%s|dim", dn[2]), sprintf("%s|1",  dn[2]),   # Age dim + maintainer (m1)
    sprintf("%s|dim", dn[3]), sprintf("%s|1",  dn[3]),   # Household type dim + m1
    sprintf("%s|dim", dn[4]), sprintf("%s|13", dn[4]),   # Period dim + "2016 to 2021" (m13)
    sprintf("%s|dim", dn[6]), sprintf("%s|1",  dn[6]),   # Housing dim + m1
    sprintf("%s|5",  dn[6]),                             # Housing member 5 (non-Total)
    sprintf("%s|1",  dn[7])))                            # Tenure member 1 (no dim note)
  # the member-note member ids come from the 84 01 bitmap (pair-swap, MSB-first)
  bitmapped <- sort(unique(vapply(Filter(function(f) f$scope == "member", en),
                                  function(f) f$member_id, 1L)))
  expect_equal(bitmapped, c(1L, 5L, 13L))
})

test_that("table-level (cube) footnotes are recovered from the master-directory blob", {
  p <- sample_ivt_077()
  skip_if(p == "", "no 98-10-0077 sample (set CANIVT_SAMPLE_IVT_F1_077)")
  m <- ivt_metadata(p)
  tbl <- Filter(function(f) identical(f$scope, "table"), m$footnotes)
  expect_equal(length(tbl), 2L)                          # EN + FR
  expect_true(all(is.na(vapply(tbl, function(f) f$member_id, 1L))))
  expect_true(any(grepl("^Historical comparison of geographic areas",
                        vapply(tbl, function(f) f$text, ""))))
  # 98-10-0077 also carries member notes on the non-Total members 7 and 8 of the
  # Economic family structure dimension (bitmap {1,7,8}).
  en <- Filter(function(f) f$language == "en", m$footnotes)
  mem <- sort(unique(vapply(Filter(function(f) identical(f$scope, "member") &&
    identical(f$dimension, m$dimension_names[2]), en), function(f) f$member_id, 1L)))
  expect_equal(mem, c(1L, 7L, 8L))
})

test_that("Canada decodes to the published tenure totals", {
  p <- sample_ivt()
  skip_if(p == "", "no sample IVT (set CANIVT_SAMPLE_IVT)")
  tab <- read_ivt(p, complete = FALSE)
  expect_equal(nrow(tab$cells), 7489464L)
  # by default data columns are named by the terse structural slug (descriptor order)
  td <- ivt_tidy(tab)
  geo_cols <- c("geo_label", "geo_name", "geo_uid", "geo_level", "value")
  expect_equal(setdiff(names(td), geo_cols),
               c("age", "household", "period", "statistics", "housing", "tenure"))
  # the light metadata path carries the full attribute table for the small
  # schema'd tables, so tidy fronts the display label and aggregation level too
  expect_true(all(c("geo_label", "geo_level") %in% names(td)))
  # dim_names = "label" uses the full English dimension labels
  expect_equal(setdiff(names(ivt_tidy(tab, dim_names = "label")), geo_cols),
               c("Age of primary household maintainer",
                 "Household type including census family structure",
                 "Period of construction", "Statistics", "Housing indicators",
                 "Tenure including presence of mortgage payments and subsidized housing"))
  row <- td[td$geo_uid == "2021A000011124" &
    td$age == "Total - Age of primary household maintainer" &
    td$household ==
      "Total - Household type including census family structure" &
    td$period == "Total - Period of construction" &
    td$statistics == "Number of private households" &
    td$housing == "Total - Housing indicators", ]
  expect_equal(row$value,
               c(14687350L, 9787420L, 5870875L, 3916550L, 4899925L,
                 576625L, 4323300L))
})

test_that("dimensions carry French labels + a French dimension name", {
  p <- sample_ivt()
  skip_if(p == "", "no sample IVT (set CANIVT_SAMPLE_IVT)")
  m <- ivt_metadata(p)
  ten <- m$dimensions[[7]]                          # Tenure
  expect_equal(ten$name, "Tenure including presence of mortgage payments and subsidized housing")
  expect_equal(ten$name_fr,
               "Mode d'occupation incluant la présence de paiements hypothécaires et le logement subventionné")
  expect_equal(length(ten$members_fr), length(ten$members))
  expect_equal(trimws(ten$members[2]), "Owner")
  expect_equal(trimws(ten$members_fr[2]), "Propriétaire")
  # the Statistics dimension has no "Total - ..." member, so no French name
  expect_true(is.na(m$dimensions[[5]]$name_fr))
  # exposed on the metadata list
  expect_equal(m$dimension_names_fr[7], ten$name_fr)
})

test_that("ivt_tidy language = 'fr' emits French labels and column names", {
  p <- sample_ivt()
  skip_if(p == "", "no sample IVT (set CANIVT_SAMPLE_IVT)")
  tab <- read_ivt(p, complete = FALSE)
  # default slug columns, but French member values (mixed-case language normalises)
  fr <- ivt_tidy(tab, language = "Fra")
  expect_true(all(c("age", "tenure") %in% names(fr)))
  expect_true(all(c("Propriétaire", "Avec hypothèque") %in% fr$tenure))
  expect_true("Total - Âge du principal soutien du ménage" %in% fr$age)
  # dim_names = "label" + fr names the columns by the French dimension names
  frl <- ivt_tidy(tab, dim_names = "label", language = "fr")
  ten_fr <- "Mode d'occupation incluant la présence de paiements hypothécaires et le logement subventionné"
  expect_true(ten_fr %in% names(frl))
  expect_false("Tenure including presence of mortgage payments and subsidized housing" %in%
                 names(frl))
  # the Statistics dimension has no French name -> English column name fallback
  expect_true("Statistics" %in% names(frl))
  expect_error(ivt_tidy(tab, language = "de"), "language")
})

test_that("98-10-0662 is detected as family 1 and decodes (small file, mixed int16/int32, Health straddle)", {
  p <- locate_sample_ivt("CANIVT_SAMPLE_IVT_F1_662", "98100662")
  skip_if(p == "", "no 98-10-0662 sample (set CANIVT_SAMPLE_IVT_F1_662)")
  raw <- readBin(p, "raw", n = file.info(p)$size)
  # 5 dims; the full data-dim bitmap (32768 bits) far exceeds the 2048-bit page
  # cap, so Health straddles and the file is family 1 -- even though it is small
  # (page offsets < 1e6) and its per-geography directory stride is 0x80, not
  # 0x1000. Both used to misroute it to family 2 (which decoded garbage).
  expect_equal(ivt_family(raw), 1L)
  L <- ivt_layout(raw)
  expect_equal(L$slugs[L$straddle], "health")
  expect_equal(L$ipc, c(32L, 6L, 6L))         # capped health, then french, english
  expect_equal(L$window_count, 2L)
  # paged dims, innermost-first: health-window, first-official-language, geography
  expect_equal(L$ent_counts, c(2L, 5L, 91L))
  expect_equal(L$estride, c(1L, 2L, 16L))     # geography stride 16 entries x 8 = 0x80/geo
  expect_false(L$geo_in_page)                 # a data dim straddles -> geography paged
  tab <- read_ivt(p, complete = FALSE)
  expect_equal(tab$family, 1L)
  expect_false(anyNA(tab$cells$value))        # the family-2 misroute produced NaNs
  expect_equal(sort(unique(tab$cells$geo)), 1:91)
  # the two 6-member language dimensions ("French used at work" / "English used at
  # work") share a member count, so a count-keyed label store collapses them onto
  # one key; the name-anchored marker labels keep them distinct.
  dims <- ivt_f2_dimensions(raw)
  fr <- Filter(function(d) grepl("^French", d$name), dims)[[1]]
  en <- Filter(function(d) grepl("^English", d$name), dims)[[1]]
  expect_match(trimws(fr$members[1]), "French used at work")
  expect_match(trimws(en$members[1]), "English used at work")

  # member 26 ("Canada outside Quebec and New Brunswick") is a derived aggregate
  # with NO geography attributes: an explicit empty record (00 00) in the plain
  # member arrays and skipped entirely in the bit-headed dense arrays. The
  # positional directory read keeps the member slots aligned -- the run-scanner
  # split the arrays at the empty record, shifting every uid after member 25 by
  # one and dropping the count to 90 (which also warned). Validated exact vs the
  # StatCan metadata CSV on all 11 attributes for all 91 members.
  # member 26 has no schema GEO_NAME, so ivt_f2_geo_fill_label() backfills its
  # geo_name from the display label -- a loud canivt_fallback.
  ws <- testthat::capture_warnings(m <- ivt_f2_metadata(raw))
  expect_match(ws, "aggregate", all = FALSE)   # cli may wrap the phrase across lines
  expect_warning(ivt_f2_metadata(raw), class = "canivt_fallback")
  expect_equal(length(m$geographies$geo_uid), 91L)
  expect_equal(length(m$geographies$geo_name), 91L)
  expect_true(is.na(m$geographies$geo_uid[26]))
  # member 26 carries no schema GEO_NAME (a true NA hole in the attribute table
  # below), but the metadata path fills geo_name from the display Member Name
  # (geo_label), which every member carries, for such synthetic aggregates.
  expect_equal(m$geographies$geo_name[26], "Canada outside Quebec and New Brunswick")
  expect_equal(m$geographies$geo_label[26], "Canada outside Quebec and New Brunswick")
  # accepted by design: an aggregate has no DGUID and no aggregation level in the
  # file -- both genuinely absent, so they stay NA (the name is the only recoverable
  # attribute, and it comes from the display label, not a synthesized value).
  expect_true(is.na(m$geographies$geo_level[26]))
  expect_equal(m$geographies$geo_uid[27], "2021A000210")  # Newfoundland and Labrador
  at <- ivt_f2_geo_attributes(raw)
  expect_equal(nrow(at), 91L)
  expect_true(all(is.na(unlist(at[26, c("geo_name", "dguid", "geo_type_abbr", "pr_code")]))))
  expect_equal(at$geo_label[26], "Canada outside Quebec and New Brunswick")
})

test_that("the uniform family-1 decoder derives the 98-10-0241 page geometry", {
  p <- sample_ivt()
  skip_if(p == "", "no sample IVT (set CANIVT_SAMPLE_IVT)")
  raw <- readBin(p, "raw", n = file.info(p)$size)
  L <- ivt_layout(raw)
  # straddle = Period (descriptor dim 4): 8 of 13 periods fit a 256-byte presence
  # record, so 2 windows; in-page Period/Stat/Housing/Tenure; geography is paged.
  expect_equal(L$straddle, 4L)
  expect_false(L$geo_in_page)
  expect_equal(L$ipc, c(8L, 3L, 6L, 7L))      # capped period, then stat/housing/tenure
  expect_equal(L$window_count, 2L)
  expect_equal(L$rec_bytes, 256L)
  # paged dims, innermost-first: period-window, household, age, geography
  expect_equal(L$ent_counts, c(2L, 16L, 9L, 166L))
  expect_equal(L$estride, c(1L, 2L, 32L, 512L))  # geography stride 512 entries = 0x1000/geo
})

test_that("98-10-0077 decodes cell-exact (uniform family-1 decoder)", {
  p <- sample_ivt_077()
  skip_if(p == "", "no 98-10-0077 sample (set CANIVT_SAMPLE_IVT_F1_077)")
  raw <- readBin(p, "raw", n = file.info(p)$size)
  L <- ivt_layout(raw)
  # straddle = Ages (descriptor dim 4): 4 of 18 fit, 5 windows; in-page Ages/
  # Earners/Income/Year; paged Structure/FamilySize/window/geography.
  expect_equal(L$straddle, 4L)
  expect_false(L$geo_in_page)
  expect_equal(L$ipc, c(4L, 6L, 22L, 2L))
  expect_equal(L$window_count, 5L)
  # paged dims, innermost-first: ages-window, family size, structure, geography
  expect_equal(L$ent_counts, c(5L, 5L, 9L, 174L))
  expect_equal(L$estride, c(1L, 8L, 64L, 1024L))  # geography stride 1024 entries = 0x2000/geo

  expect_equal(L$slugs, c("geo", "economic", "family", "ages", "number", "economic1", "year"))

  cells <- ivt_decode(raw, L)
  expect_equal(sort(unique(cells$geo)), 1:174)
  # Canada (geo 1) grand total for both years: coordinate 1.1.1.1.1.1 carries the
  # 2020 then 2015 value consecutively (Year is the innermost in-page dimension).
  ca <- cells[cells$geo == 1L & cells$economic == 1L & cells$family == 1L &
                cells$ages == 1L & cells$number == 1L & cells$economic1 == 1L, ]
  expect_equal(ca$value[order(ca$year)], c(10117305, 9688845))
})
