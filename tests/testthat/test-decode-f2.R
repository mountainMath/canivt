# Integration tests for the family-2 container (single contiguous page
# directory), e.g. StatCan table 98-10-0023 (Age x Gender, down to dissemination
# areas). Point CANIVT_SAMPLE_IVT_F2 at a copy of 98100023.ivt to run these; they
# skip otherwise.
# locate_sample_ivt() lives in helper-samples.R (shared across test files).
sample_ivt_f2 <- function() {
  locate_sample_ivt("CANIVT_SAMPLE_IVT_F2", "98100023",
                    legacy = "/tmp/t23/98100023.ivt")
}

# A 4-dimension family-2 table (98-10-0129: Geography x Gender x Marital status x
# Age), used to test the n-dimensional decoder (2 geos/page, marker 0xa4, a
# power-of-two-nested presence bitmap deeper than Age x Gender). Point
# CANIVT_SAMPLE_IVT_F2_4D at a copy of 98100129.ivt to run; skips otherwise.
sample_ivt_f2_4d <- function() {
  locate_sample_ivt("CANIVT_SAMPLE_IVT_F2_4D", "98100129",
                    legacy = "/tmp/t129/98100129.ivt")
}

# A 2021 aggregate-dissemination-area table (98-10-0013). Its last chunk group
# ends in a 71-member partial, and its attribute-schema dictionary sits ~14 KB
# before the codebook pointer -- both edge cases the parser must handle. Point
# CANIVT_SAMPLE_IVT_ADA at a copy of 98100013.ivt to run; skips otherwise.
sample_ivt_ada <- function() {
  locate_sample_ivt("CANIVT_SAMPLE_IVT_ADA", "98100013",
                    legacy = "/tmp/valtables/98100013/98100013.ivt")
}

# Pre-DGUID modern-export tables whose geography uses the inline "name (code) flag"
# codebook with character GEOUIDs: a 2011 census-tract table (dotted CTUIDs, e.g.
# "0010001.00") and a 2006 dissemination-area table. Point CANIVT_SAMPLE_IVT_2011 /
# CANIVT_SAMPLE_IVT_2006 at copies to run; skip otherwise.
sample_ivt_2011 <- function() {
  locate_sample_ivt("CANIVT_SAMPLE_IVT_2011", "98-312-XCB2011033",
                    file = "98-312-XCB2011033.IVT",
                    legacy = "/tmp/ivt2/98-312-XCB2011033.IVT")
}
sample_ivt_2006 <- function() {
  locate_sample_ivt("CANIVT_SAMPLE_IVT_2006", "97-563-XCB2006072",
                    file = "97-563-XCB2006072.IVT",
                    legacy = "/tmp/ivt2/97-563-XCB2006072.IVT")
}
# A small single-block 2016 table (98-400-X2016387: the 2016 twin of 98-10-0077 —
# 174 geographies, a "Census year (2)" reference period). No schema and no DGUID:
# geography is the inline combined block whose entry carries a trailing non-response
# "(pct%)" the older tables lack, and the uid is the bare geographic code.
sample_ivt_2016 <- function() {
  locate_sample_ivt("CANIVT_SAMPLE_IVT_2016", "98-400-X2016387",
                    file = "98-400-X2016387.IVT",
                    legacy = "/tmp/ivt2/98-400-X2016387.IVT")
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

  # the geography block directory resolves even on this big tail-codebook table,
  # where the header slot points at a struct whose first u32 is the directory
  # (one indirection deeper than the small tables), so the schema comes from the
  # directory, not the codebook-window scan.
  d <- ivt_f2_geo_block_dir(raw)
  expect_false(is.null(d))
  expect_true(ivt_f2_dir_has_geo(raw, d))
  expect_equal(ivt_f2_geo_schema(raw)[1:3],
               c("GEO_NAME", "GEO_TYPE_DESC", "GEO_TYPE_ABBR"))
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
  # default: data columns named by the terse structural slug
  td <- ivt_tidy(x)
  expect_equal(names(td), c("geo_uid", "age", "gender", "value"))
  # dim_names = "label" uses the full English dimension labels
  expect_equal(names(ivt_tidy(x, dim_names = "label")),
               c("geo_uid", "Age (in single years), average age and median age",
                 "Gender", "value"))

  can <- td[x$cells$geo == 1L, ]
  expect_equal(unique(can$geo_uid), "2021A000011124")
  pick <- function(a, g) can$value[trimws(can$age) == a & trimws(can$gender) == g]
  expect_equal(pick("Total - Age", "Total - Gender"), 36991980)
  expect_equal(pick("Total - Age", "Men+"), 18226240)
  expect_equal(pick("Average age", "Total - Gender"), 41.9)
})

test_that("the header dimension slot table resolves every dimension's directory", {
  p <- sample_ivt_f2()
  skip_if(p == "", "no family-2 sample (set CANIVT_SAMPLE_IVT_F2)")
  raw <- readBin(p, "raw", n = file.info(p)$size)
  # one 14-byte slot per descriptor dimension at @824 + 14*(k-1), each holding a
  # pointer to that dimension's block directory plus the directory's entry count
  # (the geography slot routes through the extra struct indirection on this file).
  slots <- ivt_f2_dim_slots(raw)
  expect_equal(length(slots), 3L)
  d_geo <- ivt_f2_dim_dir(raw, 1L, slots)
  expect_equal(nrow(d_geo), 6244L)                  # the chunked geography codebook
  expect_identical(d_geo, ivt_f2_geo_block_dir(raw))
  # the data-dimension directories carry the label pairs positionally: reading
  # them needs no tail-window scan and reproduces the marker-anchored labels.
  lab <- ivt_f2_dim_dir_labels(raw)
  expect_null(lab[[1L]])                            # geography has no member labels
  expect_equal(length(lab[[2L]]$en), 128L)
  expect_equal(trimws(lab[[3L]]$en), c("Total - Gender", "Men+", "Women+"))
  # French labels are read from the same slot directory (Desc Français block)
  expect_equal(trimws(lab[[3L]]$fr), c("Total - Genre", "Hommes+", "Femmes+"))
  expect_equal(length(lab[[2L]]$fr), 128L)
})

test_that("footnotes are read from the slot directories and attributed", {
  p <- sample_ivt_f2()
  skip_if(p == "", "no family-2 sample (set CANIVT_SAMPLE_IVT_F2)")
  m <- ivt_metadata(p)
  # every footnote is stored as an entry of the directory of the dimension it
  # annotates, so the metadata carries the dimension attribution the old tail
  # text-scan could not provide.
  expect_equal(length(m$footnotes), 8L)
  dims <- vapply(m$footnotes, `[[`, "", "dimension")
  expect_setequal(unique(dims),
                  c("Age (in single years), average age and median age", "Gender"))
  langs <- vapply(m$footnotes, `[[`, "", "language")
  expect_equal(sum(langs == "en"), 4L)
  expect_equal(sum(langs == "fr"), 4L)
})

test_that("geography attribute group chunk-sizes follow the doubling rule", {
  # 1,1,2,4,8,... doubling, last group trimmed to the remaining chunks.
  expect_equal(ivt_f2_geo_group_sizes(63404L), c(1, 1, 2, 4, 8, 16, 32, 64, 120))
  expect_equal(ivt_f2_geo_group_sizes(6297L),  c(1, 1, 2, 4, 8, 9))     # 98-10-0478
  expect_equal(sum(ivt_f2_geo_group_sizes(63404L)) * 256L, 63488L)      # >= n_geo
  expect_equal(ivt_f2_geo_group_sizes(256L), 1L)                        # single chunk
  expect_equal(ivt_f2_geo_group_sizes(300L), c(1, 1))                   # two chunks
})

test_that("family-2 geography attributes come from the directory-driven read", {
  p <- sample_ivt_f2()
  skip_if(p == "", "no family-2 sample (set CANIVT_SAMPLE_IVT_F2)")
  raw <- readBin(p, "raw", n = file.info(p)$size)
  # the block directory resolves and lists the codebook regularly, so the
  # positional (stride-free) reader is the one that runs -- not the fallback.
  dir_tbl <- ivt_f2_geo_attrs_dir(raw)
  expect_false(is.null(dir_tbl))
  expect_identical(dir_tbl, ivt_f2_geo_attributes(raw))
})

test_that("family-2 decodes the full geography attribute table", {
  p <- sample_ivt_f2()
  skip_if(p == "", "no family-2 sample (set CANIVT_SAMPLE_IVT_F2)")
  raw <- readBin(p, "raw", n = file.info(p)$size)
  ga <- ivt_f2_geo_attributes(raw)
  expect_equal(nrow(ga), 63404L)
  expect_true(all(c("geo_label", "geo_label_fr", "geo_name", "geo_name_fr", "dguid",
                    "geo_level", "geo_type_abbr", "prov_abbr", "alt_geo_code",
                    "pr_code", "dqf_code", "tnr_short_form") %in% names(ga)))

  # display Member Name (geo_label) + its French twin. On this dissemination-area
  # table the display label equals the schema GEO_NAME (they diverge only on tables
  # whose GEO_NAME is a bare code, e.g. census tracts), so both read "Canada".
  expect_equal(ga$geo_label[ga$member_id == 1L], "Canada")
  expect_equal(ga$geo_label[ga$member_id == 2L], "Newfoundland and Labrador")
  expect_equal(ga$geo_label_fr[ga$member_id == 2L], "Terre-Neuve-et-Labrador")
  expect_equal(ga$geo_name_fr[ga$member_id == 6L], "Portugal Cove South")

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

test_that("chunked geography is marker+schema anchored, not year-locked", {
  p <- sample_ivt_f2()
  skip_if(p == "", "no family-2 sample (set CANIVT_SAMPLE_IVT_F2)")
  raw <- readBin(p, "raw", n = file.info(p)$size)

  # attribute slots come from the file's schema field list, reproducing the fixed
  # fallback order exactly (so no hard-coded slot table drives the read).
  slots <- ivt_f2_geo_slot_map(raw)
  expect_equal(slots, IVT_F2_ATTR_SLOTS)
  schema <- ivt_f2_geo_schema(raw)                 # readable despite the ~18 MB tail
  expect_equal(schema[1], "GEO_NAME")
  expect_true("DGUID" %in% schema)

  # groups are segmented structurally (contiguous DGUID-block runs) with
  # deterministic member ids — no DGUID array, no "2021" content anchor.
  blocks <- ivt_f2_codebook_blocks(raw)
  groups <- ivt_f2_geo_groups_chunked(blocks)
  expect_true(length(groups) >= 1L)
  expect_equal(groups[[1]]$starts[1], 1L)
  # group sizes double then take the remainder; member ids are 256-chunk spaced.
  gsz <- vapply(groups, `[[`, integer(1), "G")
  expect_equal(gsz[1:2], c(1L, 1L))
  expect_equal(groups[[2]]$starts[1], 257L)

  # the DGUID column now falls out of its own schema slot and is byte-identical to
  # the fast (de-year-locked) DGUID scan.
  dg_slot <- ivt_f2_extract_attr(blocks, groups, slots[["dguid"]],
                                 ivt_f2_geo_count(raw), dguid_slot = slots[["dguid"]])
  expect_equal(dg_slot, ivt_f2_geo_dguids(raw))
})

test_that("DGUID shape admits dotted census-tract codes but not bare numbers", {
  # census-tract DGUIDs embed the dotted CT number (e.g. 98-10-0478's
  # `2021S05079320001.00`); the shape must accept the dot, while the numeric
  # attribute codes (ALT_GEO_CODE / PR_CODE) must never be mistaken for a DGUID.
  expect_true(grepl(IVT_F2_DGUID_RE, "2021S05079320001.00"))   # dotted CT DGUID
  expect_true(grepl(IVT_F2_DGUID_RE, "2021A000011124"))        # plain DGUID
  expect_true(grepl(IVT_F2_DGUID_RE, "2021A000210"))           # short DGUID
  expect_false(grepl(IVT_F2_DGUID_RE, "9320001.00"))           # bare CT code
  expect_false(grepl(IVT_F2_DGUID_RE, "1001105"))              # ALT_GEO_CODE
})

test_that("a trailing partial chunk is not dropped (98-10-0013 ADA)", {
  p <- sample_ivt_ada()
  skip_if(p == "", "no ADA sample (set CANIVT_SAMPLE_IVT_ADA)")
  raw <- readBin(p, "raw", n = file.info(p)$size)
  n_geo <- ivt_f2_geo_count(raw)
  expect_equal(n_geo, 5447L)

  # the schema dictionary is located by following the file's own metadata directory
  # (a header pointer -> a table of block offsets/lengths), confirmed by its field
  # name -- not by a fixed window. On this table the directory lists the dictionary
  # block directly.
  blk <- ivt_f2_geo_dict_block(raw)
  expect_false(is.null(blk))
  expect_true(grepl("GEO_NAME_EN",
                    raw_to_latin1(raw[(blk[["off"]] + 1L):(blk[["off"]] + blk[["len"]])]),
                    fixed = TRUE))
  schema <- ivt_f2_geo_schema(raw)
  expect_false(is.null(schema))
  expect_equal(schema[1], "GEO_NAME")
  expect_true("DGUID" %in% schema)

  # the last chunk group ends in a 71-member partial. It was silently dropped by the
  # >=150-record block floor (decoding 5,376 of 5,447); the trailing-partial rescue
  # must recover every geography, DGUID and all, in member order. On this table the
  # block directory lists the codebook irregularly, so the read goes through the
  # legacy stride path, and the schema names only 8 of the 11 attributes, so the
  # slot map falls back to the fixed order -- both must announce themselves.
  ws <- testthat::capture_warnings(ga <- ivt_f2_geo_attributes(raw))
  expect_length(ws, 2L)
  expect_true(any(grepl("stride", ws)))
  expect_true(any(grepl("slot order", ws)))
  expect_equal(nrow(ga), 5447L)
  expect_equal(sum(!is.na(ga$dguid)), 5447L)
  expect_equal(length(unique(ga$dguid)), 5447L)
  expect_equal(ga$dguid[1], "2021A000011124")           # Canada
  expect_equal(ga$dguid[2], "2021A000210")              # Newfoundland and Labrador
  expect_equal(ga$dguid[5447], "2021S051662080008")     # last member of the 71-partial

  # the root chunk (members 1..256) is reverse-stored, so the byte-ascending stride
  # walk cannot label it: it leaves the NAME attributes NA and scrambles
  # prov_abbr / alt_geo_code / pr_code. The whole chunk is overridden by the
  # positional read from the header block directory (offsets/lengths + schema order),
  # so every attribute is correct and matches the published Member Name.
  expect_equal(sum(!is.na(ga$geo_label)), 5447L)
  expect_equal(ga$geo_label[1], "Canada")
  expect_equal(ga$geo_label[2], "Newfoundland and Labrador")
  expect_equal(ga$geo_label[3], "10010001")             # first code-only root ADA
  expect_equal(ga$geo_label_fr[1], "Canada")
  expect_equal(ga$geo_name[1], "Canada")
  # non-name root attributes, previously NA or scrambled, are now exact
  expect_equal(sum(!is.na(ga$geo_type[1:256])), 256L)
  expect_equal(ga$geo_type[1:3],
               c("Country", "Province", "Aggregate Dissemination Area"))
  expect_equal(ga$geo_type_abbr[1:3], c("Country", "PR", "ADA"))
  expect_equal(ga$prov_abbr[2], "N.L.")                 # was a code before
  expect_equal(ga$alt_geo_code[1:3], c("01", "10", "10010001"))
  # a data-group member (outside the root chunk) is untouched by the override
  expect_equal(ga$geo_type[300], "Aggregate Dissemination Area")
})

test_that("family-2 ivt_tidy labels geography by name when requested", {
  p <- sample_ivt_f2()
  skip_if(p == "", "no family-2 sample (set CANIVT_SAMPLE_IVT_F2)")
  x <- read_ivt(p, geo_attributes = TRUE)
  expect_false(is.null(x$metadata$geographies$geo_name))
  td <- ivt_tidy(x)                                # slug data columns by default
  expect_equal(names(td),
               c("geo_label", "geo_name", "geo_uid", "geo_level",
                 "age", "gender", "value"))
  can <- td[x$cells$geo == 1L, ]
  expect_equal(unique(can$geo_label), "Canada")
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

test_that("family-2 decodes a 4-dimension table (98-10-0129) cell-exact", {
  p <- sample_ivt_f2_4d()
  skip_if(p == "", "no 4-dim family-2 sample (set CANIVT_SAMPLE_IVT_F2_4D)")
  raw <- readBin(p, "raw", n = file.info(p)$size)

  # descriptor-driven layout: 4 dims, 63404 geographies, 2 geos per page
  expect_equal(ivt_f2_geo_count(raw), 63404L)
  expect_equal(ivt_f2_geos_per_page(raw), 2L)
  dd <- ivt_f2_data_dims(raw)
  expect_equal(dd$counts, c(3L, 13L, 16L))      # Gender x Marital x Age
  expect_equal(dd$slugs, c("gender", "marital", "age"))

  # power-of-two-nested presence record: Age 16, Marital 13->16 (256 bits),
  # Gender 3->4 (1024 bits) = 128 bytes
  lay <- ivt_f2_bit_layout(dd$counts)
  expect_equal(lay$stride, c(256L, 16L, 1L))
  expect_equal(lay$rec_bytes, 128L)

  cells <- ivt_decode(raw)
  expect_equal(names(cells), c("geo", "gender", "marital", "age", "value"))
  # every non-zero cell across all 63,404 geographies (the last two are genuinely
  # empty geographies, so the max present geo id is 63402)
  expect_equal(nrow(cells), 15685859L)
  expect_true(all(cells$geo >= 1L & cells$geo <= 63404L))

  # Canada (geo 1) is fully present: 3 x 13 x 16 = 624 cells minus 12 zero cells
  canada <- cells[cells$geo == 1L, ]
  expect_equal(nrow(canada), 612L)
  v <- function(g, m, a) {
    canada$value[canada$gender == g & canada$marital == m & canada$age == a]
  }
  expect_equal(v(1, 1, 1), 30979185)   # Total gender, Total marital, Total age
  expect_equal(v(1, 1, 2),  2012975)   # ... age member 2
  expect_equal(v(2, 1, 1), 15139730)   # Men+
  expect_equal(v(1, 2, 1), 17626005)   # Married or living common law
})

# Inline-codebook geography for the pre-DGUID 1991 layout (table 1003011 / E9101).
# Point CANIVT_SAMPLE_IVT_1991 at a copy of 1003011.IVT to run; skips otherwise.
sample_ivt_1991 <- function() {
  locate_sample_ivt("CANIVT_SAMPLE_IVT_1991", "1003011", file = "1003011.IVT",
                    legacy = path.expand("~/projects/censusmapper-import/data/raw/1003011.IVT"))
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

test_that("1991 inline geography is read positionally from the block directory", {
  p <- sample_ivt_1991()
  skip_if(p == "", "no 1991 sample (set CANIVT_SAMPLE_IVT_1991)")
  raw <- readBin(p, "raw", n = file.info(p)$size)

  # the directory-driven read resolves (schema-absent layout + dim-1 directory)
  g <- ivt_f2_geo_inline_dir(raw)
  expect_false(is.null(g))
  expect_equal(nrow(g), 41859L)
  expect_identical(g, ivt_f2_geo_inline(raw))          # and is the primary path

  # the tail chunks are stored out of byte order; the old byte-ascending scan +
  # first-appearance dedup misordered members 39425..41859. The directory order
  # matches the StatCan Beyond 20/20 viewer's member list (all 41,859 validated).
  expect_equal(g$geouid[39425], "59020114")
  expect_equal(g$geouid[39432], "59020151")
  expect_equal(g$geouid[41859], "61002216")
  # display names keep their accents (parsed from the combined block, not the
  # accent-stripped search-name array)
  expect_equal(g$geo_name[904],
               "Prince Edward Island | Île-du-Prince-Édouard")
  expect_equal(g$dqf_code[1], "00000")
  expect_false(anyNA(g$geo_name))
})

test_that("1991 cell decode is exact (int32 dense and int16 sparse pages)", {
  p <- sample_ivt_1991()
  skip_if(p == "", "no 1991 sample (set CANIVT_SAMPLE_IVT_1991)")
  raw <- readBin(p, "raw", n = file.info(p)$size)
  cells <- ivt_decode(raw)
  expect_equal(max(cells$geo), 41859L)

  # Canada (geo 1) is on a 0x84 int32 page, all 110 ages present (330 cells)
  ca <- cells[cells$geo == 1L, ]
  expect_equal(nrow(ca), 330L)
  # data-dim columns are named by their metadata-derived slugs: "Single Years of
  # Age" -> "single", "Sex" -> "sex" (no name/type special-casing in the decoder).
  v <- function(a, g) ca$value[ca$single == a & ca$sex == g]
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

  # default tidy now labels geography from the marker-anchored inline codebook
  # (name + character GEOUID), the same content-free path used for 2006/2011
  td <- ivt_tidy(x, dim_names = "slug")
  expect_equal(names(td), c("geo_name", "geo_uid", "single", "sex", "value"))
  expect_type(td$geo_uid, "character")
  ca <- td[td$geo_name == "Canada", ]
  expect_equal(ca$value[ca$single == "Total - Age Groups" & ca$sex == "Total - Sex"], 27296860)
  expect_equal(ca$value[ca$single == "Total - Age Groups" & ca$sex == "Male"], 13454580)
  expect_equal(unique(ca$geo_uid), "00")

  # geo_attributes = TRUE labels geography by name + GEOUID
  x2 <- read_ivt(p, geo_attributes = TRUE)
  td2 <- ivt_tidy(x2)
  expect_true(all(c("geo_name", "geo_uid") %in% names(td2)))
  expect_equal(unique(td2$geo_name[x2$cells$geo == 1L]), "Canada")
  expect_equal(unique(td2$geo_uid[x2$cells$geo == 1L]), "00")
})

test_that("pre-DGUID geography is parsed from the dimension marker, content-free", {
  # The 2006/2011 census tables have no DGUID attribute schema; geography is the
  # inline "name (code) flag" codebook. It must be located by the geography
  # dimension's own 81 02 02 00 marker (like every data dimension), NOT by sniffing
  # the file for a "Canada"/"2021" entry, and the GEOUID must stay character (the
  # 2011 census-tract codes are dotted, e.g. "0010001.00").
  p11 <- sample_ivt_2011()
  if (p11 != "") {
    raw <- readBin(p11, "raw", n = file.info(p11)$size)
    m <- ivt_f2_metadata(raw)
    expect_equal(m$n_geographies, 5447L)                 # type-0x0d u16 count
    expect_equal(length(m$geographies$geo_uid), 5447L)
    expect_equal(length(m$geographies$geo_name), 5447L)
    expect_type(m$geographies$geo_uid, "character")
    expect_true(any(grepl("\\.", m$geographies$geo_uid)))  # dotted census-tract codes
    expect_equal(m$geographies$geo_uid[1], "001")          # St. John's CMA
  }
  p06 <- sample_ivt_2006()
  if (p06 != "") {
    raw <- readBin(p06, "raw", n = file.info(p06)$size)
    m <- ivt_f2_metadata(raw)
    expect_equal(m$n_geographies, 57523L)
    expect_equal(length(m$geographies$geo_uid), 57523L)
    expect_type(m$geographies$geo_uid, "character")
    expect_equal(m$geographies$geo_name[1], "Canada")
    expect_equal(m$geographies$geo_uid[1], "01")
  }
  # 2016 single-block table: no schema, no DGUID; the combined block adds a trailing
  # non-response "(pct%)". The uid is the bare geographic code, still character.
  p16 <- sample_ivt_2016()
  if (p16 != "") {
    raw <- readBin(p16, "raw", n = file.info(p16)$size)
    m <- ivt_f2_metadata(raw)
    expect_equal(m$n_geographies, 174L)
    expect_equal(length(m$geographies$geo_uid), 174L)
    expect_type(m$geographies$geo_uid, "character")
    expect_equal(m$geographies$geo_name[1], "Canada")
    expect_equal(m$geographies$geo_uid[1], "01")             # bare code, not a DGUID
    expect_false(any(grepl("^2016[A-Z]", m$geographies$geo_uid)))  # no DGUID present
  }
  if (p11 == "" && p06 == "" && p16 == "")
    skip("no pre-DGUID sample (set CANIVT_SAMPLE_IVT_2011 / _2006 / _2016)")
})

test_that("pre-DGUID geography is read positionally from the block directory", {
  # The regex fallback scans blocks in BYTE order and dedups on first appearance,
  # which scrambles chunks stored out of byte order: it silently misordered 2,435
  # members on 1003011, 18,432 on the 2006 table and 1,351 on the 2011 table. The
  # directory read follows the member order; every pin below is validated against
  # the Beyond 20/20 viewer's geography member list.
  p11 <- sample_ivt_2011()
  if (p11 != "") {
    raw <- readBin(p11, "raw", n = file.info(p11)$size)
    g <- ivt_f2_geo_inline_dir(raw)
    expect_false(is.null(g))
    expect_identical(g, ivt_f2_geo_inline(raw))        # and it is the primary path
    expect_equal(nrow(g), 5447L)
    expect_false(anyNA(g$geouid))
    # in the tail range the byte-order scan misordered (its final 71-member
    # partial chunk is also a bit-headed dense block the run-scanner fragments)
    expect_equal(g$geouid[4097], "7050100.05")
    expect_equal(g$geouid[5447], "9700103.00")
  }
  p06 <- sample_ivt_2006()
  if (p06 != "") {
    raw <- readBin(p06, "raw", n = file.info(p06)$size)
    g <- ivt_f2_geo_inline_dir(raw)
    expect_false(is.null(g))
    expect_equal(nrow(g), 57523L)
    expect_false(anyNA(g$geouid))
    # the 2006 vintage has NO separate code array (3 runs per group; the uid is
    # the combined block's parsed code) and stores the last group's partial chunk
    # FIRST within each run
    expect_equal(g$geouid[9473], "24470100247")
    expect_equal(g$geo_name[9473], "24470247")
    expect_equal(g$geouid[57523], "62080870017")
  }
  p16 <- sample_ivt_2016()
  if (p16 != "") {
    raw <- readBin(p16, "raw", n = file.info(p16)$size)
    g <- ivt_f2_geo_inline_dir(raw)
    expect_false(is.null(g))                           # extra leading run tolerated
    expect_equal(nrow(g), 174L)
    expect_equal(g$geouid[c(1L, 174L)], c("01", "62"))
  }
  if (p11 == "" && p06 == "" && p16 == "")
    skip("no pre-DGUID sample (set CANIVT_SAMPLE_IVT_2011 / _2006 / _2016)")
})

test_that("the master directory and DQF legend read from their header slots", {
  p <- sample_ivt_f2()
  skip_if(p == "", "no family-2 sample (set CANIVT_SAMPLE_IVT_F2)")
  raw <- readBin(p, "raw", n = file.info(p)$size)
  # @544 -> the master (whole-file section) directory at offset 992; one of its
  # entries is the dimension descriptor block (the @32 pointer targets the same
  # block, 14 framing bytes before the directory-listed start)
  md <- ivt_f2_master_dir(raw)
  expect_false(is.null(md))
  expect_gte(nrow(md), 9L)
  expect_true(any(abs(md[, "off"] - rd_u32(raw, 32L)) <= 16L))
  # @712 -> the data-quality-flag legend (EN/FR pairs per code letter)
  lg <- ivt_f2_dqf_legend(raw)
  expect_false(is.null(lg))
  expect_equal(lg$code, c("A", "B", "C", "D", "E", "R", "P"))
  expect_equal(lg$text_en[1], "Data quality: excellent")
  expect_match(lg$text_fr[1], "excellente")
  expect_equal(lg$text_en[7], "Preliminary")
  # and it is exposed on the metadata
  m <- ivt_f2_metadata(raw)
  expect_identical(m$dqf_legend, lg)
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

test_that("the 1991 legacy file carries the same dimension slot table", {
  p <- sample_ivt_1991()
  skip_if(p == "", "no 1991 sample (set CANIVT_SAMPLE_IVT_1991)")
  raw <- readBin(p, "raw", n = file.info(p)$size)
  slots <- ivt_f2_dim_slots(raw)
  expect_equal(length(slots), 3L)
  # geography's slot directory lists the inline pre-DGUID codebook blocks
  expect_equal(nrow(ivt_f2_dim_dir(raw, 1L, slots)), 1097L)
  # the master directory resolves too; the pre-DGUID @712 slot is a stub (no legend)
  expect_gte(nrow(ivt_f2_master_dir(raw)), 9L)
  expect_null(ivt_f2_dqf_legend(raw))
  # Age (110) and Sex (3) label positionally, byte-identical to the marker scan
  lab <- ivt_f2_dim_dir_labels(raw)
  expect_equal(length(lab[[2L]]$en), 110L)
  expect_equal(trimws(lab[[2L]]$en[1]), "Total - Age Groups")
  expect_equal(trimws(lab[[3L]]$en), c("Total - Sex", "Male", "Female"))
  expect_identical(lab[[3L]]$en, ivt_f2_dimensions(raw)[[3L]]$members)
  # bilingual: the French block reads from the same directory (schema-ordered)
  expect_equal(trimws(lab[[3L]]$fr), c("Total - Sexe", "Masculin", "Féminin"))
  expect_identical(lab[[3L]]$fr, ivt_f2_dimensions(raw)[[3L]]$members_fr)
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

test_that("small files' page directories are not truncated by an offset floor", {
  # 98-400-X2016387's pages start at ~7 KB; the old hard-coded `off >= 1e5` entry
  # floor rejected the (valid) header pointer and the marker-scan fallback then
  # found only the 6 of 22 pages above 100 KB.
  p <- locate_sample_ivt("", "98-400-X2016387", "98-400-X2016387.IVT")
  skip_if(p == "", "no 98-400-X2016387 sample in the ivt cache")
  raw <- readBin(p, "raw", n = file.info(p)$size)
  expect_false(is.null(ivt_f2_dir_anchor_header(raw)))   # header pointer validates
  d <- ivt_f2_find_directory(raw)
  expect_equal(d$n_pages, 22L)                           # ceiling(174 geos / 8 per page)
  expect_equal(d$lo, ivt_idx0(raw))
})

test_that("directory entries with unrecognised page markers are skipped LOUDLY", {
  # 98-400-X2016203 is SUPPORTED since the descriptor type 0x0a u16 width fix
  # (its "Selected characteristics" dimension is 825 members; the u8 misread 57
  # mis-nested the layout, which is what had made its b2 == 0 pages look
  # non-exact-fit) -- viewer-validated cell-exact. To exercise the loud-skip
  # machinery, doctor one page's b3 to the genuinely unknown 0x0b: the entry
  # must be dropped with a classed warning -- silently missing cells read as
  # zeros downstream.
  p <- locate_sample_ivt("", "98-400-X2016203", "98-400-X2016203.IVT")
  skip_if(p == "", "no 98-400-X2016203 sample in the ivt cache")
  raw <- readBin(p, "raw", n = file.info(p)$size)
  expect_true(ivt_is_supported(raw))
  cells <- ivt_decode(raw)                 # a2 01 03 0a pages decode via b3
  expect_gt(nrow(cells), 0L)
  # doctor a LATER entry's page marker (the FIRST entry anchors ivt_idx0()'s
  # pointer-unwrap validation -- breaking it re-anchors the whole directory
  # instead of exercising the per-entry skip)
  idx0 <- ivt_idx0(raw)
  off <- NA_integer_
  for (k in 1:200) {
    o <- idx0 + 8L * k
    if (rd_u16(raw, o + 4L) == rd_u16(raw, o + 6L) && rd_u16(raw, o + 4L) > 0L &&
        ivt_f2_is_marker(raw, rd_u32(raw, o))) { off <- rd_u32(raw, o); break }
  }
  expect_false(is.na(off))
  doctored <- raw
  doctored[off + 4L] <- as.raw(0x0b)
  expect_warning(cells2 <- ivt_decode(doctored), class = "canivt_skipped_pages")
  expect_lt(nrow(cells2), nrow(cells))
  withr::local_options(canivt.strict = TRUE)
  expect_error(ivt_decode(doctored), class = "canivt_skipped_pages_error")
})

test_that("incompatible same-signature containers fail the page pre-flight", {
  # The 2001 "F"-series variant (97F0020XCB2001070) parses to a resolvable
  # layout (all dimensions fit one presence record) and its pages even fit
  # their directory sizes EXACTLY -- but they carry 1124 presence bits against
  # a 448-real-cell capacity (the data is nested differently), so the
  # pre-flight rejects the file instead of decoding garbage.
  p <- locate_sample_ivt("", "97F0020XCB2001070", "97F0020XCB2001070.IVT")
  skip_if(p == "", "no 97F0020XCB2001070 sample in the ivt cache")
  raw <- readBin(p, "raw", n = file.info(p)$size)
  expect_false(is.null(ivt_layout(raw)))
  expect_false(ivt_page_preflight(raw))
  expect_false(ivt_is_supported(raw))
})

test_that("the 1981 profile variant decodes: geography LAST, count-reconciled Values(1)", {
  # 97-570-X1981004's descriptor stores Values(1) x Profile(79) x
  # Geography(5989) -- geography is the LAST descriptor dimension. The "Values"
  # placeholder's double-01 record reads a bogus count of 32 unless reconciled
  # against its slot-directory member block (1 slot, 1 member); with the true
  # counts the ordinary unified layout describes the file exactly: geography
  # straddles the presence record (3 windows of 2048), Profile is
  # directory-paged at stride 4, Values(1) is the trivial outermost entry
  # dimension. Viewer-validated: all 5,989 geography members in order and
  # 1,264/1,264 sampled cells exact (incl. the window boundaries 2048/2049 and
  # 4096/4097 and the last member).
  p <- locate_sample_ivt("", "97-570-X1981004", "97-570-X1981004.ivt")
  skip_if(p == "", "no 97-570-X1981004 sample in the ivt cache")
  raw <- readBin(p, "raw", n = file.info(p)$size)
  d <- ivt_f2_descriptor(raw)
  expect_equal(vapply(d$dims, `[[`, 1L, "count"), c(1L, 79L, 5989L))
  expect_equal(ivt_f2_geo_dim_index(raw, d), 3L)
  lay <- ivt_layout(raw)
  expect_equal(lay$straddle, 3L)                  # geography straddles ...
  expect_true(lay$geo_in_page)                    # ... so geo is in-page
  expect_equal(lay$slugs, c("values", "profile", "geo"))
  expect_equal(lay$window_count, 3L)              # ceiling(5989 / 2048)
  expect_true(ivt_page_preflight(raw))
  expect_true(ivt_is_supported(raw))
  x <- read_ivt(p)
  expect_equal(nrow(x$cells), 418400L)
  # Canada, "Population, 1981" -- the published 1981 census total
  can <- x$cells[x$cells$geo == 1L & x$cells$profile == 2L, ]
  expect_equal(can$value, 24343181)
  g <- x$metadata$geographies
  expect_equal(length(g$member_id), 5989L)
  expect_equal(g$geo_name[1], "CANADA")
  expect_equal(g$geo_uid[1], "00")
  expect_equal(length(x$metadata$footnotes), 10L) # FOOTNOTE:/RENVOI : framing
  expect_equal(x$metadata$product_id, "97-570-X1981004")  # master-dir identity
})

test_that("the header directory pointer unwraps past 64 KiB (98-10-0013 cells)", {
  # @558 stores the directory offset's LOW 16 BITS; 98-10-0013's directory sits
  # at 44761 + 65536. Under the plain u16 read idx0 fell back to the 98-10-0241
  # constant and the cell decode was silently EMPTY (0 pages). All 22 pages now
  # decode -- including 18 distinct marker b2 values whose trailers the b2
  # formula must reproduce (validated cell-exact vs the StatCan CSV, 37,587
  # comparable cells).
  p <- sample_ivt_ada()
  skip_if(p == "", "no ADA sample (set CANIVT_SAMPLE_IVT_ADA)")
  raw <- readBin(p, "raw", n = file.info(p)$size)
  expect_equal(ivt_idx0(raw), 44761L + 65536L)
  cells <- ivt_decode(raw)
  expect_equal(nrow(cells), 36491L)
  expect_equal(cells$value[cells$geo == 1L & cells[[2]] == 1L], 36991981)
})

test_that("a table that fits one presence record decodes (98-10-0044 no-straddle)", {
  # 14 geographies x 32 data bits = 512 bits: nothing overflows the 2048-bit
  # record, geography takes the straddle role trivially (ipc 64 > 14, one
  # window). Validated cell-exact vs the official StatCan CSV (448/448).
  p <- locate_sample_ivt("", "98-10-0044", "98100044.ivt")
  skip_if(p == "", "no 98-10-0044 sample in the ivt cache")
  raw <- readBin(p, "raw", n = file.info(p)$size)
  expect_equal(ivt_family(raw), 2L)
  lay <- ivt_layout(raw)
  expect_true(lay$geo_in_page)
  expect_equal(lay$window_count, 1L)
  expect_equal(lay$ipc[1L], 64L)
  cells <- ivt_decode(raw)
  expect_equal(nrow(cells), 399L)
  expect_equal(cells$value[cells$geo == 1L & cells[[2]] == 1L], c(24140, 657920))
})

test_that("the 1996 census tables decode (viewer-validated)", {
  # 94F0009XDB96078: 13 geographies, 5 dims incl. a Years(2) facet -- 572/572
  # cells exact vs the B2020 viewer across all geographies. 95F0250XDB96001:
  # its "1995 Household Income (3)" dimension name starts with a DIGIT, which
  # the uppercase-only descriptor anchor dropped (the resulting 2-dim layout
  # decoded misindexed cells); 72/72 viewer-exact with 3 dims. 95F0223XDB96001:
  # 5,007 geographies, duplicate member labels under two parents (1134/1134).
  p <- locate_sample_ivt("", "94F0009XDB96078", "94F0009XDB96078.ivt")
  if (p != "") {
    raw <- readBin(p, "raw", n = file.info(p)$size)
    expect_equal(ivt_family(raw), 1L)
    d <- ivt_f2_descriptor(raw)
    expect_equal(vapply(d$dims, `[[`, 1L, "count"), c(13L, 4L, 9L, 22L, 2L))
    expect_equal(nrow(ivt_decode(raw)), 16004L)
  }
  p <- locate_sample_ivt("", "95F0250XDB96001", "95F0250XDB96001.ivt")
  if (p != "") {
    raw <- readBin(p, "raw", n = file.info(p)$size)
    d <- ivt_f2_descriptor(raw)
    expect_equal(length(d$dims), 3L)
    # digit-led; the FIRST stored copy truncates at the ~15-byte cap and the
    # descriptor read recovers the complete SECOND copy
    expect_equal(d$dims[[2L]]$name, "1995 Household Income (3)")
    expect_equal(vapply(d$dims, `[[`, 1L, "count"), c(5544L, 3L, 3L))
    expect_equal(ivt_idx0(raw), 22330L + 2L * 65536L)   # unwrapped pointer
    cells <- ivt_decode(raw)
    expect_equal(nrow(cells), 41081L)
    m <- suppressWarnings(ivt_f2_metadata(raw))
    expect_equal(m$geographies$geo_name[1], "Canada")
    expect_equal(length(m$geographies$geo_uid), 5544L)
  }
  p <- locate_sample_ivt("", "95F0223XDB96001", "95F0223XDB96001.ivt")
  if (p != "") {
    raw <- readBin(p, "raw", n = file.info(p)$size)
    cells <- ivt_decode(raw)
    expect_equal(nrow(cells), 643900L)
    # Canada x Total age x Total sex, immigrant members 6 (Immigrants > US) and
    # 22 (Non-permanent residents > US) -- the duplicate-label pair
    can <- cells[cells$geo == 1L & cells$age == 1L & cells$sex == 1L, ]
    expect_equal(can$value[can$immigrant == 6L], 244695)
    expect_equal(can$value[can$immigrant == 22L], 16375)
  }
  p <- locate_sample_ivt("", "95F0200XDB96003", "95F0200XDB96003.IVT")
  if (p != "") {
    raw <- readBin(p, "raw", n = file.info(p)$size)
    expect_equal(ivt_family(raw), 2L)                   # 43,234 EAs, geo straddles
    expect_equal(ivt_f2_geo_count(raw), 43234L)
  }
})

test_that("large 2016 98-400-X crosstabs decode in the supported container", {
  # 98-400-X2016328 (18.7 MB, 5-dim, 4,868 geographies) and 98-400-X2016261
  # (86.8 MB, 6-dim) are ordinary family-1 layouts: every page satisfies the
  # geometry invariants and the cells validate exact against the B2020 viewer
  # (360/360 and 154/154 on the leading geographies; 1,680/1,680 on deep-tail
  # geographies at member positions 3000+/4860+, confirming member order).
  p <- locate_sample_ivt("", "98-400-X2016328", "98-400-X2016328.ivt")
  skip_if(p == "", "no 98-400-X2016328 sample in the ivt cache")
  raw <- readBin(p, "raw", n = file.info(p)$size)
  expect_equal(ivt_family(raw), 1L)
  expect_equal(ivt_f2_geo_count(raw), 4868L)
  lay <- ivt_layout(raw)
  expect_false(lay$geo_in_page)
  expect_equal(lay$window_count, 6L)
  cells <- ivt_decode(raw)
  expect_equal(nrow(cells), 2912227L)
  # Canada x all-total coordinates: total commuters (viewer-validated)
  tot <- cells[cells$geo == 1L & cells$commuting == 1L & cells$time == 1L &
                 cells$main == 1L & cells$distance == 1L, ]
  expect_equal(tot$value, 13891675)
  m <- ivt_f2_metadata(raw)
  expect_equal(m$n_geographies, 4868L)
  expect_equal(m$geographies$geo_name[1], "Canada")
  expect_equal(m$geographies$geo_uid[1:2], c("01", "10"))
})

test_that("the 2016 income table decodes, with suppression as ABSENT cells", {
  # 98-400-X2016120 (Income Sources and Taxes x Income Statistics, 4,868 geos,
  # all-float64 pages): viewer-validated 510/510 numeric cells on the leading
  # geographies and 1,432/1,432 on deep-tail villages, with ZERO mismatches.
  # Every viewer-blank (suppressed / not-applicable) cell is simply ABSENT from
  # the value store -- this container carries no suppression sentinels (the
  # b3 = 0x0a "-1" pages are unique to the rejected 98-400-X2016203).
  p <- locate_sample_ivt("", "98-400-X2016120", "98-400-X2016120.ivt")
  skip_if(p == "", "no 98-400-X2016120 sample in the ivt cache")
  raw <- readBin(p, "raw", n = file.info(p)$size)
  expect_equal(ivt_family(raw), 2L)
  expect_equal(ivt_f2_geo_count(raw), 4868L)
  lay <- ivt_layout(raw)
  expect_true(lay$geo_in_page)
  expect_equal(lay$window_count, 1217L)     # 4 geographies per float64 page
  cells <- ivt_decode(raw)
  expect_equal(nrow(cells), 634119L)
  # Canada x Total income sources: the five income statistics (viewer-validated)
  can <- cells[cells$geo == 1L & cells$income == 1L, ]
  expect_equal(can$value, c(28643015, 27489395, 96, 47487, 1305380183))

  # the geography reads positionally despite two odd-sized auxiliary blocks
  # BEFORE the group runs (the walk skips leading non-conforming blocks);
  # member order == the viewer d0 list, 4,868/4,868
  gd <- ivt_f2_geo_inline_dir(raw)
  expect_equal(nrow(gd), 4868L)
  expect_equal(gd$geo_name[1], "Canada")

  # suppression is exposed through PRESENCE + the per-geography flag: the 888
  # geographies with no stored cells (has_data FALSE) are exactly the 888 whose
  # inline dqf flag ends in 9 (validated vs the viewer: every blank/suppressed
  # cell belongs to such a geography; published geographies' absent cells all
  # render as 0)
  x <- read_ivt(p)
  g <- x$metadata$geographies
  expect_true(all(c("dqf_code", "has_data") %in% names(g)))
  expect_equal(sum(!g$has_data), 888L)
  expect_identical(!g$has_data, substr(g$dqf_code, 5L, 5L) == "9")
  expect_equal(g$geo_name[which(!g$has_data)[1]], "Portugal Cove South")
})
