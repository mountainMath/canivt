# canivt <a href="https://mountainmath.github.io/canivt/"><img src="man/figures/logo.png" align="right" height="120" alt="canivt website" /></a>

<!-- badges: start -->
<!-- badges: end -->

**canivt** downloads and parses [Statistics Canada *Beyond 20/20* `.ivt` data
tables](https://www.statcan.gc.ca/en/public/beyond20-20) straight from their bytes — into tidy data frames, Parquet, or CSV — and
extracts the table metadata that is *not* part of the data itself: dimension
members, geographic identifiers (names + DGUIDs/GEOUIDs), and footnotes.

No companion CSV or metadata download is needed: everything, including the
codebook, is decoded from the single `.ivt` file.

## Documentation
Please consult the [documentation and example articles](https://mountainmath.github.io/canivt/) for further information.

## Installation

```r
# install.packages("remotes")
remotes::install_github("mountainMath/canivt")
```

`arrow` (for Parquet) and `readr` (faster CSV) are optional and used if present.

## Usage

The recommended way to access IVT tables is to parse them to Parquet, with the
download (if needed) and parsing handled under the hood. IVT tables can be
addressed by their StatCan catalogue number, a Borealis id, or a local file id.

```r
library(canivt)

# read data for StatCan catalogue number 98-10-0241
ds <- get_statcan_ivt("98-10-0241")
```

For finer control there is a range of functions that handle the different
aspects of the download and parsing process.

`read_ivt()` is the core: point it at an `.ivt` file (local or freshly
downloaded) and it returns a decoded table with both the cells and the codebook.

```r
library(canivt)

# Read a local .ivt file
tab <- read_ivt("path/to/98100241.ivt")

# ...or download by StatCan product id first, then read
tab <- read_ivt(ivt_download("98100241"))
tab
#> ── IVT table 98100241 ──
#> Housing indicators by tenure ... period of construction: Canada, provinces ...
#> 7489464 cells | 166 geographies | 7 dimensions | 20 footnotes
#> geography labelled by name + uid

# Tidy, labelled long table (one value per row)
ivt_tidy(tab)
ivt_tidy(tab, language = "fr")                # French labels where the file has them

# Dimension members as factors carrying the FULL member list as levels,
# so members filtered out of the data still show up in tables/plots
collect_ivt(tab)

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

If you don't already know the product id, scrape the StatCan census datasets
index into a searchable catalogue (cached as Parquet after the first call):

```r
catl <- statcan_ivt_catalogue()              # every census version, one row each
subset(catl, grepl("tenure", title, ignore.case = TRUE))
# then read the table you picked
tab <- read_ivt(ivt_download("98100241"))
```

For repeated/programmatic access, `get_statcan_ivt()` downloads, decodes and
**caches** in one call (accepting a catalogue number, a Borealis id, or a local
id), returning an [`arrow`](https://arrow.apache.org/docs/r/) dataset connection:

```r
ds <- get_statcan_ivt("98-10-0241")          # cached; second call is instant
```

## Coverage

The package is designed with the goal of handling all IVT files. It has been
tested and validated against a sizeable corpus of standard- and custom-release
IVT files. But given the undocumented nature of the format and its versions it
may well not be comprehensive, and there may be IVT format vintages that it
currently does not cover. If you run across one of these please
[open an issue](https://github.com/mountainMath/canivt/issues) with a link to
the offending IVT and a brief description of the failure.

## How it works

The [file format article](https://mountainmath.github.io/canivt/articles/ivt-format.html)
walks through the reverse-engineered format and how the package maps onto it;
`vignette("ivt-format", package = "canivt")` is the same text offline. The
authoritative byte-level spec and the byte-marker catalog ship with the package as
`system.file("notes/ivt-format.md", package = "canivt")` and
`system.file("notes/markers.md", package = "canivt")`. See
[`CLAUDE.md`](CLAUDE.md) for the code map and dev workflow.

## Related packages

There are several packages that perform related tasks accessing StatCan data.

The [cansim package](https://mountainmath.github.io/cansim/) is designed to retrieve and work with public Statistics Canada data tables via the New Dissemination Model (NDM) API interface. This is the preferred method to access these tables, but only tables from the 2021 census and newer are available via this interface. The **cansim** package is available on CRAN and on [Github](https://github.com/mountainMath/cansim).

The [cancensus package](https://mountainmath.github.io/cancensus/) ties into the [CensusMapper](https://censusmapper.ca) data API to retrieve Statistics Canada census profile data. It provides more pinpointed data access than pulling entire tables, and it provides access to the Statistics Canada API for census data that serves newer vintage census data, albeit with several downsides. The **cancensus** package is available on CRAN and on [Github](https://github.com/mountainMath/cancensus).

The [statcanXtabs](https://mountainmath.github.io/statcanXtabs/) package is a fairly rough package that provides an interface to intermediate year StatCan census data tables that are available in CSV or SDXML format. The package is functional but data processing is somewhat limited.


## License

MIT
