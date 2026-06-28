# canivt

<!-- badges: start -->
<!-- badges: end -->

**canivt** downloads and parses Statistics Canada *Beyond 20/20* `.ivt` data
tables straight from their bytes — into tidy data frames, Parquet, or CSV — and
extracts the table metadata that is *not* part of the data itself: dimension
members, geographic identifiers (names + DGUIDs), and footnotes.

No companion CSV or metadata download is needed: everything, including the
codebook, is decoded from the single `.ivt` file.

## Installation

```r
# install.packages("remotes")
remotes::install_github("mountainMath/canivt")
```

`arrow` (for Parquet) and `readr` (faster CSV) are optional and used if present.

## Usage

```r
library(canivt)

# Download + parse a table by StatCan product id (8-digit table id)
tab <- ivt_read_table("98100241")
tab
#> ── IVT table 98100241 ──
#> Housing indicators by tenure ... period of construction: Canada, provinces ...
#> 7489464 cells | 166 geographies | 7 dimensions | 20 footnotes

# Tidy, labelled long table (one value per row)
ivt_tidy(tab)

# Write outputs
ivt_write_parquet(tab, "98100241.parquet")   # ~17 MB
ivt_write_csv(tab, "98100241.csv")           # labelled long CSV
ivt_write_metadata(tab, "98100241_metadata") # dimension_members / geographies /
                                             # footnotes / table_info CSVs

# Just the metadata (fast — no value decoding)
meta <- ivt_metadata(ivt_download("98100241"))
meta$geographies$dguid[1:3]
#> "2021A000011124" "2021A000210" "2021S0504015"
```

You can also read a local file directly with `read_ivt("path/to/file.ivt")`.

## What works

- The **2021-era Beyond 20/20 layout** (reference table
  [98-10-0241](https://www150.statcan.gc.ca/t1/tbl1/en/tv.action?pid=9810024101))
  is fully decoded and validated: all 166 geographies, 7,489,464 cells, exact
  against the StatCan CSV download.
- Dimension member labels (with hierarchy indentation), geography names and full
  **DGUIDs**, and footnotes (all 10 EN + 10 FR for the reference table, matching
  the StatCan metadata exactly) are read from the codebook.

## Not yet supported

- Older layouts such as the **1991 census** Beyond 20/20 format use a different
  container and presence encoding; `read_ivt()` errors clearly on unrecognised
  files. See `inst/notes/ivt-format.md` for the format spec and what differs.

## How it works

See [`inst/notes/ivt-format.md`](inst/notes/ivt-format.md) for the reverse-engineered
file format, and [`CLAUDE.md`](CLAUDE.md) for the code map and dev workflow.

## License

MIT
