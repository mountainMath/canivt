# canivt

**canivt** downloads and parses [Statistics Canada *Beyond 20/20* `.ivt`
data tables](https://www.statcan.gc.ca/en/public/beyond20-20) straight
from their bytes — into tidy data frames, Parquet, or CSV — and extracts
the table metadata that is *not* part of the data itself: dimension
members, geographic identifiers (names + DGUIDs/GEOUIDs), and footnotes.

No companion CSV or metadata download is needed: everything, including
the codebook, is decoded from the single `.ivt` file.

## Documentation

Please consult the [documentation and example
articles](https://mountainmath.github.io/canivt/) for further
information.

## Installation

``` r

# install.packages("remotes")
remotes::install_github("mountainMath/canivt")
```

`arrow` (for Parquet) and `readr` (faster CSV) are optional and used if
present.

## Usage

[`read_ivt()`](https://mountainmath.github.io/canivt/reference/read_ivt.md)
is the core: point it at an `.ivt` file (local or freshly downloaded)
and it returns a decoded table with both the cells and the codebook.

``` r

library(canivt)

# Read a local .ivt file
tab <- read_ivt("path/to/98100241.ivt")

# ...or download by StatCan product id first, then read
tab <- read_ivt(ivt_download("98100241"))
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
meta$geographies$geo_uid[1:3]
#> "2021A000011124" "2021A000210" "2021S0504015"
```

`ivt_read_table("98100241")` is a one-shot shortcut for
`read_ivt(ivt_download(...))`.

### Finding a table (catalogue lookup)

If you don’t already know the product id, scrape the StatCan census
datasets index into a searchable catalogue (cached as Parquet after the
first call):

``` r

catl <- statcan_ivt_catalogue()              # every census version, one row each
subset(catl, grepl("tenure", title, ignore.case = TRUE))
# then read the table you picked
tab <- read_ivt(ivt_download("98100241"))
```

For repeated/programmatic access,
[`get_statcan_ivt()`](https://mountainmath.github.io/canivt/reference/get_statcan_ivt.md)
downloads, decodes and **caches** in one call (accepting a catalogue
number, a Borealis id, or a local id), returning an
[`arrow`](https://arrow.apache.org/docs/r/) dataset connection:

``` r

ds <- get_statcan_ivt("98-10-0241")          # cached; second call is instant
```

## What works

**Every `.ivt` in the tested corpus decodes** — there are no unsupported
files. A single descriptor-driven decoder handles them all, and
[`read_ivt()`](https://mountainmath.github.io/canivt/reference/read_ivt.md)
auto-detects the layout:

- **2016–2021 census tables** (DGUID codebook), the reference table
  [98-10-0241](https://www150.statcan.gc.ca/t1/tbl1/en/tv.action?pid=9810024101)
  validated exact against the StatCan CSV (all 166 geographies,
  7,489,464 cells), and the large geography-straddle tables down to
  dissemination areas
  ([98-10-0023](https://www150.statcan.gc.ca/t1/tbl1/en/tv.action?pid=9810002301):
  63,404 geographies, 14.5 M cells exact).
- **Pre-DGUID layouts** — 1981/1991 census profiles and the 1991
  single-year-of- age tables (inline bilingual codebook, `int16`/`int32`
  value pages).
- 2001/2006 F-series, large 2016 `98-400-X` crosstabs, residence→work
  commuting- flow tables, and custom Borealis/order extracts.
- From the codebook: dimension member labels (with hierarchy
  indentation), bilingual geography names and identifiers (**DGUIDs** or
  pre-2016 GEOUIDs), geography attributes (level/type, geocodes,
  data-quality flags, non-response rates), and footnotes with
  table/dimension/member scope.

## How it works

See
[`inst/notes/ivt-format.md`](https://mountainmath.github.io/canivt/inst/notes/ivt-format.md)
for the reverse-engineered file format, and
[`CLAUDE.md`](https://mountainmath.github.io/canivt/CLAUDE.md) for the
code map and dev workflow.

## License

MIT
