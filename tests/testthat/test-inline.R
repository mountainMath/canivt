# Unit tests for the inline combined-record parser and the bilingual name
# split -- pure functions, no sample .ivt needed.

test_that("ivt_f2_parse_inline captures name/code/flag/type/tnr per form", {
  v <- c(
    "Canada (01)   20000 (  5.1%)",                        # 2016: flag + tnr
    "Portugal Cove South (1001105) T 01000",               # 2006: type token
    "Newfoundland | Terre-Neuve (10)   00000",             # 1991: bilingual name
    "0001.00 (0010001.00)   01000",                        # 2011: dotted CT codes
    "Central Kootenay D (5903039), CSD 01010 ( 14.4%)",    # ord: inverted order
    "East Kootenay, RD (5901)",                            # cro: code-trailing form
    "not a member record"
  )
  p <- ivt_f2_parse_inline(v)
  expect_equal(p$name[1], "Canada")
  expect_equal(p$code[1], "01")
  expect_equal(p$flag[1], "20000")
  expect_equal(p$tnr[1], "5.1")
  expect_equal(p$type[2], "T")
  expect_equal(p$code[3], "10")
  expect_equal(p$code[4], "0010001.00")
  # inverted ord form: type from the token position, no leading space
  expect_equal(p$name[5], "Central Kootenay D")
  expect_equal(p$type[5], "CSD")
  expect_equal(p$tnr[5], "14.4")
  # code-trailing cro form: type read from the ", <ABBR>" name suffix, the
  # display name keeps its suffix; no flag / tnr on this form
  expect_equal(p$name[6], "East Kootenay, RD")
  expect_equal(p$type[6], "RD")
  expect_true(is.na(p$flag[6]))
  expect_true(is.na(p$code[7]))
  # the French copies store a comma decimal
  expect_equal(ivt_f2_parse_tnr("  5,1 %"), "5.1")
  expect_true(is.na(ivt_f2_parse_tnr("some note")))
})

test_that("the code-first form parses, and only where the code is unambiguous", {
  # the Business-Register CD/CSD lineage (CDCSDNAIC3dec2006) writes "<code> - <name>";
  # every code-trailing form is tried first, so this pass only ever sees leftovers
  v <- c(
    "1001101 - Division No.  1, Subd. V",   # code-first: 7-digit CSD
    "3520 - Toronto Division",              # code-first: 4-digit CD
    "Region 1 - North",                     # NOT a code: 1 digit, name keeps the dash
    "Sault Ste. Marie - Wawa",              # NOT a code: no leading digits at all
    "East Kootenay, RD (5901)"              # code-trailing wins, untouched
  )
  p <- ivt_f2_parse_inline(v)
  expect_equal(p$code[1], "1001101")
  expect_equal(p$name[1], "Division No.  1, Subd. V")
  expect_equal(p$code[2], "3520")
  expect_equal(p$name[2], "Toronto Division")
  expect_true(is.na(p$code[3]))
  expect_true(is.na(p$code[4]))
  expect_equal(p$code[5], "5901")
  expect_equal(p$name[5], "East Kootenay, RD")
})

test_that("ivt_f2_split_bilingual splits language pairs, not dual English names", {
  nm <- c(
    "Newfoundland | Terre-Neuve",                          # 1991 "|": always split
    "Prince Edward Island / Île-du-Prince-Édouard",
    "New Brunswick / Nouveau-Brunswick",
    "Northwest Territories / Territoires du Nord-Ouest",
    "Kootenay Boundary E / West Boundary, RDA",            # ONE English dual name
    "Greater Sudbury / Grand Sudbury",                     # language-neutral pair
    "Ottawa - Gatineau (Ontario part / partie de l'Ontario)",  # sep inside parens
    "Division No. 1"                                       # no separator
  )
  s <- ivt_f2_split_bilingual(nm)
  expect_equal(s$en[1], "Newfoundland")
  expect_equal(s$fr[1], "Terre-Neuve")
  expect_equal(s$en[2], "Prince Edward Island")
  expect_equal(s$fr[2], "Île-du-Prince-Édouard")
  expect_equal(s$en[3], "New Brunswick")
  expect_equal(s$fr[3], "Nouveau-Brunswick")
  expect_equal(s$en[4], "Northwest Territories")
  expect_equal(s$fr[4], "Territoires du Nord-Ouest")
  # a "/" split needs POSITIVE French evidence: dual English names and
  # language-neutral pairs stay combined (both halves = the whole string)
  expect_equal(s$en[5], nm[5])
  expect_equal(s$fr[5], nm[5])
  expect_equal(s$en[6], nm[6])
  expect_equal(s$fr[6], nm[6])
  expect_equal(s$en[7], nm[7])
  expect_equal(s$en[8], nm[8])
})
