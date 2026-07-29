# Read a Beyond 20/20 IVT file

Parses a Statistics Canada Beyond 20/20 `.ivt` table straight from its
bytes: both the data cells and the codebook (dimension members,
geographic identifiers, footnotes). No companion CSV or metadata
download is required.

## Usage

``` r
read_ivt(path, geo_attributes = FALSE, missing = FALSE, complete = TRUE)
```

## Arguments

- path:

  Path to an `.ivt` file.

- geo_attributes:

  For the large chunked family-2 tables only: if `TRUE`, decode the full
  geography attribute table (names, level/type, geocodes, data-quality
  flag, non-response rate) from the codebook so
  [`ivt_tidy()`](https://mountainmath.github.io/canivt/reference/ivt_tidy.md)
  can label geographies by name. This adds a codebook block-scan (tens
  of seconds); the default `FALSE` keeps those tables keyed by DGUID.
  Small schema'd tables and the pre-DGUID (inline-codebook) tables
  already carry their full attribute set on the default metadata path.
  Ignored for family-1 tables.

- missing:

  If `TRUE` (default `FALSE`) also return the flagged cells on their
  own, as a `missing` tibble: the same member-id columns as `cells`, no
  `value`, plus `symbol` and `status`. On the completed table (the
  default) this is simply the `is.na(value)` rows, so it is a
  convenience view rather than extra work; with `complete = FALSE` it is
  decoded separately and is the only place the file's missing-value
  statement appears.

- complete:

  If `TRUE` (default) return the **published table**: one row per real
  grid coordinate, matching what StatCan's own CSV download publishes.
  Absent cells the file says nothing about become the published zero;
  cells the file flags carry `value = NA` plus the `symbol` and `status`
  it declares for them. `FALSE` returns the raw store instead – only the
  cells that carry a stored value, no `symbol`/`status` columns – which
  is smaller and faster but is *not* a table you can complete to a full
  grid yourself without turning every suppressed cell into a zero.
  Completion is refused above `getOption("canivt.max_cells", 1e8)` grid
  cells.

## Value

An object of class `ivt`: a list with `cells` (a tibble of one cell per
row, keyed by 1-based member-id columns matching the StatCan metadata
Member IDs; under the default `complete = TRUE` it spans the whole grid
and carries `symbol`/`status` factors beside `value`), and `metadata`
(table identity, `dimensions`, `geographies`, and `footnotes`).
`metadata$geographies` carries, per member and where the vintage stores
them: the bilingual display label (`geo_label`, `geo_label_fr`) and name
(`geo_name`, `geo_name_fr` – on pre-DGUID tables the EN/FR halves of the
stored bilingual label), `geo_uid` (DGUID, or the bare GEOUID on
pre-DGUID tables), the aggregation level (`geo_level`), the label
hierarchy (`geo_depth`, `geo_parent_id` – the indentation the display
label carries, turned into a depth and the `member_id` of each member's
nearest shallower ancestor; both absent when the geography axis is
flat), the geography type / municipal status (`geo_type`,
`geo_type_abbr`), province abbreviation and codes (`prov_abbr`,
`alt_geo_code`, `pr_code`), the data-quality flag (`dqf_code`, with
`dqf_note` and the table-level `dqf_legend`), and the total non-response
rate (`tnr_short_form`).

Where `dqf_note` is present it is accompanied by a `dqf_note_truncated`
logical flag: StatCan's writer stores each note in a single-byte-length
record, so notes longer than 252 characters are truncated **in the
source file** (2,448 of 63,404 geographies in 98-10-0129, 90 of 6,297 in
98-10-0478). The read is byte-exact – this is a container limitation,
not a decode gap, and there is no continuation to recover – but the flag
marks the affected members and a classed `canivt_dqf_note_truncated`
warning is raised so the loss is never silent. (Unlike a heuristic
fallback it is *not* upgraded to an error by
`options(canivt.strict = TRUE)`: the bytes are exactly what the file
holds.) The truncation is a container limit of the `.ivt` export only –
StatCan's authoritative metadata (the WDS `getCubeMetadata`
`geoAttribute` or the CSV-download metadata) stores the full untruncated
note, so a consumer who needs the complete text can recover it there.

Each footnote in `metadata$footnotes` carries a `scope` (`"table"`,
`"dimension"` or `"member"`), the owning `dimension` name and, for
member notes, the `member_id`(s) it annotates – `member_id` for a single
member and `member_refs` for the full set (geography counts as a
dimension). This matches StatCan's own footnote linkage on the modern
tables; on the pre-DGUID profiles the same linkage is recovered from the
`(N)` reference markers embedded in the member labels (a note there can
be cited by many members, so `member_refs` lists them all).

`metadata$geographies$has_data` flags which geographies carry a
published non-zero value; on the pre-DGUID tables
`metadata$geographies$dqf_code` (the per-geography data-quality flag
from the codebook) corroborates it (e.g. on the 2016 income table
98-400-X2016120 the flag's last digit is `9` exactly for the 888
geographies with no stored cells, which the Beyond 20/20 viewer renders
as suppressed).

## Details

Every primary read is positional (header pointers, block directories,
framed value entries). When one does not resolve and a content-heuristic
fallback supplies values instead – or when directory entries point at
page variants that cannot be decoded – a classed warning
(`canivt_fallback` / `canivt_skipped_pages`) is raised naming the
affected read. Set `options(canivt.strict = TRUE)` to turn these into
errors: on a file layout this package has not been validated against,
the fallback paths are the ones most likely to misread silently.

## Missing values

Only non-zero cells are stored, so absence covers **both** genuine zeros
and true missings (`x` suppressed, `...`/`N` not available). The two are
separated by a block each page appends after its dense value run, in one
of two forms selected by the page marker: a 1-bit **absent mask** – a
strict subset of the absent cells, where masked means a genuine zero and
*unmasked* means missing – or a self-describing **reason-code array**
carrying the `..` / `x` / `...` distinction itself. Both are decoded, at
every code width; only the array states a reason, so mask-derived rows
carry `status = NA`.

That block is what makes the default `complete = TRUE` output safe. The
rule it licenses, read off the file rather than off any published CSV,
is: an absent cell is the **published zero** unless its page's
cell-status block says otherwise. A page that writes no tail at all is a
page with nothing to flag – validated cell-for-cell against StatCan's
published CSVs on tables covering every page class – while a page whose
tail cannot be read has its absences published as zeros *and counted*
(`canivt_absent_unclassified`), never folded in silently.

The reason codes are **numbered by the file, not by the format**: each
table declares its own legend – symbol plus bilingual wording, in code
order – and the same symbol sits at different codes in different
lineages (`x` is code 2 in the NDM census tables and code 3 in the 2016
`98-400-X` crosstabs). `status` is read from that declaration, so it
names whatever the file names, including symbols outside the census
vocabulary (`F` too unreliable to be published, `0 s` rounded to zero,
`®` not released yet, `z` frozen series). A code the legend does not
name, or a table that declares no legend, is reported rather than
guessed at (`canivt_status_code_unknown`, `canivt_status_legend`).

Two limits are reported rather than hidden. On float64 pages a mask word
of mostly-ones is NaN-shaped and the writer's x87 quieting overwrites
one status bit per such word **in the source file**; those cells read as
zeros and cannot be recovered (`canivt_status_nan_quieted`). And on a
few 2001/2006 vintages the page's word index also addresses a second,
undecoded block past the mask (`canivt_status_extra_block`).

The status travels out of the package with the data:
[`ivt_tidy_missing()`](https://mountainmath.github.io/canivt/reference/ivt_tidy_missing.md)
labels the missing-cell table exactly as
[`ivt_tidy()`](https://mountainmath.github.io/canivt/reference/ivt_tidy.md)
labels the values,
[`ivt_write_parquet()`](https://mountainmath.github.io/canivt/reference/ivt_write_parquet.md)
/
[`ivt_write_csv()`](https://mountainmath.github.io/canivt/reference/ivt_write_csv.md)
write it beside the data table as a `_missing` sidecar,
[`get_statcan_ivt()`](https://mountainmath.github.io/canivt/reference/get_statcan_ivt.md)
caches it under `missing = TRUE`, and
[`ivt_missing()`](https://mountainmath.github.io/canivt/reference/ivt_missing.md)
gets it back from any of those forms. Under `complete = FALSE` that
sidecar is essential: the exported table then holds only the cells that
have a value, so reconstructing the full grid from it alone fills every
suppressed cell with a zero.

## Examples

``` r
# A small real table (StatCan 98-10-0044) is bundled for examples/tests.
path <- system.file("extdata", "98100044.ivt", package = "canivt")
ivt <- read_ivt(path)
ivt
#> 
#> ── IVT table 98100044 ──────────────────────────────────────────────────────────
#> Type of collective dwelling and collective dwellings occupied by usual
#> residents and population in collective dwellings: Canada, provinces and
#> territories
#> 448 cells | 14 geographies | 3 dimensions | 10 footnotes
#> geography labelled by name + uid
#> published grid: 448 values, 0 flagged as missing
head(ivt$cells)
#> # A tibble: 6 × 6
#>     geo  type collective  value symbol status
#>   <int> <int>      <int>  <dbl> <fct>  <fct> 
#> 1     1     1          1  24140 NA     NA    
#> 2     1     1          2 657920 NA     NA    
#> 3     1     2          1  13020 NA     NA    
#> 4     1     2          2 485320 NA     NA    
#> 5     1     3          1    300 NA     NA    
#> 6     1     3          2  11125 NA     NA    
```
