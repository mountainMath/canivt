# Integration tests for the family-2 container (single contiguous page
# directory), e.g. StatCan table 98-10-0023 (Age x Gender, down to dissemination
# areas). Point CANIVT_SAMPLE_IVT_F2 at a copy of 98100023.ivt to run these; they
# skip otherwise.
sample_ivt_f2 <- function() {
  p <- Sys.getenv("CANIVT_SAMPLE_IVT_F2", "")
  if (nzchar(p) && file.exists(p)) return(p)
  guess <- path.expand("/tmp/t23/98100023.ivt")
  if (file.exists(guess)) return(guess)
  ""
}

test_that("family-2 files are detected as family 2", {
  p <- sample_ivt_f2()
  skip_if(p == "", "no family-2 sample (set CANIVT_SAMPLE_IVT_F2)")
  raw <- readBin(p, "raw", n = file.info(p)$size)
  expect_equal(ivt_family(raw), 2L)
  expect_true(ivt_is_supported(raw))
  # geography layout + count come from the header, not the codebook
  expect_false(ivt_f2_geo_is_inline(raw))      # modern DGUID layout
  expect_equal(ivt_f2_header_geo_count(raw), 63404L)
})

test_that("family-2 directory enumerates the expected geographies", {
  p <- sample_ivt_f2()
  skip_if(p == "", "no family-2 sample (set CANIVT_SAMPLE_IVT_F2)")
  raw <- readBin(p, "raw", n = file.info(p)$size)
  dir <- ivt_f2_find_directory(raw)
  expect_equal(dir$n_pages, 15851L)
  expect_equal(dir$n_pages * 4L, 63404L)
  expect_equal(dir$offsets[1], 554596)  # first directory entry = Canada's page
})

test_that("header dimension descriptor decodes dimension counts and types", {
  p <- sample_ivt_f2()
  skip_if(p == "", "no family-2 sample (set CANIVT_SAMPLE_IVT_F2)")
  raw <- readBin(p, "raw", n = file.info(p)$size)
  d <- ivt_f2_descriptor(raw)
  expect_equal(d$n_dim, 3L)
  expect_equal(vapply(d$dims, function(x) x$count, 1L), c(63404L, 128L, 3L))
  expect_equal(vapply(d$dims, function(x) x$type, 1L), c(0x10L, 0x07L, 0x02L))
  expect_equal(d$dims[[1]]$name, "Geography")
  expect_match(d$title, "average age and median age")
})

test_that("family-2 metadata reports identity and dimensions", {
  p <- sample_ivt_f2()
  skip_if(p == "", "no family-2 sample (set CANIVT_SAMPLE_IVT_F2)")
  m <- ivt_metadata(p)
  expect_equal(m$product_id, "98100023")
  expect_equal(length(m$dimension_names), 3L)
  expect_equal(m$dimension_names[1], "Geography")
  expect_equal(m$dimension_names[3], "Gender")
  expect_equal(m$n_geographies, 63404L)
})

test_that("family-2 codebook decodes DGUIDs and member labels", {
  p <- sample_ivt_f2()
  skip_if(p == "", "no family-2 sample (set CANIVT_SAMPLE_IVT_F2)")
  m <- ivt_metadata(p)

  # geography uids (DGUIDs), member-ordered (1-based)
  expect_equal(length(m$geographies$geo_uid), 63404L)
  expect_equal(m$geographies$geo_uid[1], "2021A000011124")  # Canada
  expect_equal(m$geographies$geo_uid[2], "2021A000210")     # Newfoundland and Labrador
  expect_equal(m$geographies$geo_uid[63404], "2021S051262080015")

  # uniform dimension model (driven by the header descriptor)
  expect_equal(m$dimension_counts, c(63404L, 128L, 3L))
  expect_false(m$dimensions[[1]]$is_geography == FALSE)  # geography is dim 1
  age <- trimws(m$dimensions[[2]]$members)
  gender <- trimws(m$dimensions[[3]]$members)
  expect_equal(length(age), 128L)
  expect_equal(age[c(1, 2, 127, 128)],
               c("Total - Age", "0 to 14 years", "Average age", "Median age"))
  expect_equal(gender, c("Total - Gender", "Men+", "Women+"))
})

test_that("family-2 ivt_tidy labels geography by DGUID and ages/genders", {
  p <- sample_ivt_f2()
  skip_if(p == "", "no family-2 sample (set CANIVT_SAMPLE_IVT_F2)")
  x <- read_ivt(p)
  td <- ivt_tidy(x)
  expect_equal(names(td), c("geo_uid", "age", "gender", "value"))

  can <- td[x$cells$geo == 1L, ]
  expect_equal(unique(can$geo_uid), "2021A000011124")
  pick <- function(a, g) can$value[trimws(can$age) == a & trimws(can$gender) == g]
  expect_equal(pick("Total - Age", "Total - Gender"), 36991980)
  expect_equal(pick("Total - Age", "Men+"), 18226240)
  expect_equal(pick("Average age", "Total - Gender"), 41.9)
})

test_that("family-2 decodes the full geography attribute table", {
  p <- sample_ivt_f2()
  skip_if(p == "", "no family-2 sample (set CANIVT_SAMPLE_IVT_F2)")
  raw <- readBin(p, "raw", n = file.info(p)$size)
  ga <- ivt_f2_geo_attributes(raw)
  expect_equal(nrow(ga), 63404L)
  expect_true(all(c("geo_name", "dguid", "geo_level", "geo_type_abbr", "prov_abbr",
                    "alt_geo_code", "pr_code", "dqf_code", "tnr_short_form") %in% names(ga)))

  # Canada (member 1) — every attribute
  ca <- ga[ga$member_id == 1L, ]
  expect_equal(ca$geo_name, "Canada")
  expect_equal(ca$dguid, "2021A000011124")
  expect_equal(ca$geo_level, "Country")
  expect_equal(ca$pr_code, "01")
  expect_equal(ca$dqf_code, "20000")        # data-quality flag
  expect_equal(ca$tnr_short_form, "3.1")     # non-response rate
  expect_equal(ca$geo_type, "Country")
  expect_match(ca$dqf_note, "Excludes census data")
  expect_equal(ga$geo_type[ga$member_id == 6L], "Town")  # abbr "T"

  # geographies whose type description contains a Windows-1252 byte (curly
  # apostrophe 0x92) or whose neighbours do — these split the array before the
  # is_label_byte fix; they must now decode exactly.
  expect_equal(ga$geo_type[ga$dguid == "2021A00055927802"], "Tla’amin Lands")
  expect_equal(ga$geo_type[ga$dguid == "2021A00055927806"], "Indian government district")
  expect_equal(ga$geo_name[ga$dguid == "2021A00056104006"], "Sambaa K’e")  # was NA

  # named places and codes elsewhere in the file
  expect_equal(ga$geo_name[ga$member_id == 2L], "Newfoundland and Labrador")
  expect_equal(ga$prov_abbr[ga$member_id == 2L], "N.L.")
  expect_equal(ga$geo_name[ga$member_id == 6L], "Portugal Cove South")
  expect_equal(ga$alt_geo_code[ga$member_id == 6L], "1001105")
})

test_that("family-2 ivt_tidy labels geography by name when requested", {
  p <- sample_ivt_f2()
  skip_if(p == "", "no family-2 sample (set CANIVT_SAMPLE_IVT_F2)")
  x <- read_ivt(p, geo_attributes = TRUE)
  expect_false(is.null(x$metadata$geographies$geo_name))
  td <- ivt_tidy(x)
  expect_equal(names(td), c("geo_name", "geo_uid", "geo_level", "age", "gender", "value"))
  can <- td[x$cells$geo == 1L, ]
  expect_equal(unique(can$geo_name), "Canada")
  expect_equal(unique(can$geo_uid), "2021A000011124")
  expect_equal(unique(can$geo_level), "Country")
})

test_that("family-2 decodes Canada and a sparse geography cell-exact", {
  p <- sample_ivt_f2()
  skip_if(p == "", "no family-2 sample (set CANIVT_SAMPLE_IVT_F2)")
  x <- read_ivt(p)
  expect_equal(x$family, 2L)
  expect_equal(names(x$cells), c("geo", "age", "gender", "value"))

  # Canada (geo 1) is fully present: 128 age members x 3 genders.
  canada <- x$cells[x$cells$geo == 1L, ]
  expect_equal(nrow(canada), 384L)
  val <- function(g, a, gen) {
    canada$value[canada$age == a & canada$gender == gen]
  }
  expect_equal(val(1, 1, 1), 36991980)  # Total - Age, Total gender
  expect_equal(val(1, 1, 2), 18226240)  # Men+
  expect_equal(val(1, 1, 3), 18765745)  # Women+
  expect_equal(val(1, 127, 1), 41.9)    # average age (float64 statistic)

  # geo 153 sits on an `a8` (float64) page; geo 44463 on an `a2` (int16) page.
  expect_equal(sum(x$cells$geo == 153L), 162L)
  g44463 <- x$cells[x$cells$geo == 44463L, ]
  expect_equal(nrow(g44463), 64L)
  expect_equal(head(g44463$value, 8), c(75, 45, 30, 15, 10, 5, 5, 5))
})

# Inline-codebook geography for the pre-DGUID 1991 layout (table 1003011 / E9101).
# Point CANIVT_SAMPLE_IVT_1991 at a copy of 1003011.IVT to run; skips otherwise.
sample_ivt_1991 <- function() {
  p <- Sys.getenv("CANIVT_SAMPLE_IVT_1991", "")
  if (nzchar(p) && file.exists(p)) return(p)
  guess <- path.expand("~/projects/censusmapper-import/data/raw/1003011.IVT")
  if (file.exists(guess)) return(guess)
  ""
}

test_that("1991 inline geography codebook decodes GEOUIDs and bilingual names", {
  p <- sample_ivt_1991()
  skip_if(p == "", "no 1991 sample (set CANIVT_SAMPLE_IVT_1991)")
  raw <- readBin(p, "raw", n = file.info(p)$size)
  expect_equal(ivt_family(raw), 2L)          # same container family as 2021
  expect_true(ivt_f2_geo_is_inline(raw))     # but pre-DGUID inline codebook (from header)
  expect_equal(ivt_f2_header_geo_count(raw), 41859L)

  # the header descriptor declares the dimensions even without an inline Variable List
  d <- ivt_f2_descriptor(raw)
  expect_equal(vapply(d$dims, function(x) x$count, 1L), c(41859L, 110L, 3L))
  expect_match(d$title, "1991 Census")

  g <- ivt_f2_geo_inline(raw)
  expect_equal(nrow(g), 41859L)
  expect_equal(names(g), c("member_id", "geo_name", "geouid", "dqf_code"))

  # GEOUIDs are bare codes (no year/area-type DGUID prefix); names are bilingual.
  expect_equal(g$geouid[1], "00")
  expect_equal(g$geo_name[1], "Canada")
  expect_equal(g$geouid[2], "10")
  expect_equal(g$geo_name[2], "Newfoundland | Terre-Neuve")
  # an enumeration area: name equals its code
  ea <- g[g$geouid == "10002257", ]
  expect_equal(ea$geo_name, "10002257")

  # the unified, metadata-driven dispatcher returns the same leading schema as the
  # 2021 path (member_id, geo_name, geo_uid) and matches the header-declared count
  gg <- ivt_f2_geographies(raw)
  expect_equal(names(gg)[1:3], c("member_id", "geo_name", "geo_uid"))
  expect_equal(nrow(gg), ivt_f2_header_geo_count(raw))
  expect_equal(gg$geo_uid[1:2], c("00", "10"))

  # Age(110)/Sex(3) labels carry over unchanged from the 2021 reader
  labs <- ivt_f2_dim_member_labels(raw)
  age <- trimws(labs[["110"]]); sex <- trimws(labs[["3"]])
  expect_equal(length(age), 110L)
  expect_equal(age[c(1, 2, 110)], c("Total - Age Groups", "0-4 years", "90 and over"))
  expect_equal(sex, c("Total - Sex", "Male", "Female"))
})

test_that("1991 cell decode is exact (int32 dense and int16 sparse pages)", {
  p <- sample_ivt_1991()
  skip_if(p == "", "no 1991 sample (set CANIVT_SAMPLE_IVT_1991)")
  raw <- readBin(p, "raw", n = file.info(p)$size)
  cells <- ivt_f2_decode(raw)
  expect_equal(max(cells$geo), 41859L)

  # Canada (geo 1) is on a 0x84 int32 page, all 110 ages present (330 cells)
  ca <- cells[cells$geo == 1L, ]
  expect_equal(nrow(ca), 330L)
  v <- function(a, g) ca$value[ca$age == a & ca$gender == g]
  expect_equal(v(1, 1), 27296860)   # Total - Age, Total - Sex
  expect_equal(v(1, 2), 13454580)   # Male
  expect_equal(v(1, 3), 13842280)   # Female
  expect_equal(v(2, 1), 1906500)    # 0-4 years, Total

  # geo 6 sits on a 0x82 int16 page and is sparse (drops zero cells)
  expect_equal(sum(cells$geo == 6L), 279L)
})

test_that("read_ivt() handles the legacy 1991 table end-to-end", {
  p <- sample_ivt_1991()
  skip_if(p == "", "no 1991 sample (set CANIVT_SAMPLE_IVT_1991)")
  x <- read_ivt(p)
  expect_equal(x$family, 2L)
  expect_equal(x$metadata$product_id, "1003011")          # from out-of-line title
  expect_match(x$metadata$title_en, "Population by Single Years of Age")
  expect_equal(x$metadata$dimension_counts, c(41859L, 110L, 3L))
  expect_equal(x$metadata$n_geographies, 41859L)

  # legacy "(N) text" footnotes (one notes blob, not framed "Footnote N" records)
  fn <- x$metadata$footnotes
  expect_equal(length(fn), 40L)
  expect_equal(vapply(fn, function(f) f$number, 1L), 1:40)
  expect_match(fn[[1]]$text, "first five months")

  # default tidy keys geography by member id (no fast uid in the legacy format)
  td <- ivt_tidy(x)
  expect_equal(names(td), c("geo", "age", "gender", "value"))
  ca <- td[td$geo == 1L, ]
  expect_equal(ca$value[ca$age == "Total - Age Groups" & ca$gender == "Total - Sex"], 27296860)
  expect_equal(ca$value[ca$age == "Total - Age Groups" & ca$gender == "Male"], 13454580)

  # geo_attributes = TRUE labels geography by name + GEOUID
  x2 <- read_ivt(p, geo_attributes = TRUE)
  td2 <- ivt_tidy(x2)
  expect_true(all(c("geo_name", "geo_uid") %in% names(td2)))
  expect_equal(unique(td2$geo_name[x2$cells$geo == 1L]), "Canada")
  expect_equal(unique(td2$geo_uid[x2$cells$geo == 1L]), "00")
})

test_that("the whole file layout maps from the header", {
  p <- sample_ivt_f2()
  if (p != "") {
    L <- ivt_f2_header_layout(readBin(p, "raw", n = file.info(p)$size))
    expect_equal(L$version, "modern")        # inline identity, DGUID codebook
    expect_equal(L$field_count, 11)          # geography attributes
    expect_equal(L$directory, 35950)
    expect_equal(L$value_pages, 167038)
    expect_equal(L$n_pages, 15851L)
    expect_true(is.na(L$title_en))           # titles inline in the modern format
  }
  q <- sample_ivt_1991()
  if (q != "") {
    L <- ivt_f2_header_layout(readBin(q, "raw", n = file.info(q)$size))
    expect_equal(L$version, "legacy")        # out-of-line titles, pre-DGUID
    expect_equal(L$field_count, 12)
    expect_equal(L$directory, 2019)
    expect_equal(L$value_pages, 133107)
    expect_false(is.na(L$title_en))          # legacy stores titles out of line
  }
})

test_that("the page directory is located from the header pointer (no marker scan)", {
  for (p in c(sample_ivt_f2(), sample_ivt_1991())) {
    if (p == "") next
    raw <- readBin(p, "raw", n = file.info(p)$size)
    # the header pointer is the directory start; it must equal the grown directory
    # `lo` that the (fallback) marker scan also resolves to.
    hdr <- ivt_f2_dir_anchor_header(raw)
    expect_false(is.null(hdr))
    expect_equal(ivt_f2_find_directory(raw)$lo, hdr)
  }
})
