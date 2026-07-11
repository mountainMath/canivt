# Read a Beyond 20/20 IVT file

Parses a Statistics Canada Beyond 20/20 `.ivt` table straight from its
bytes: both the data cells and the codebook (dimension members,
geographic identifiers, footnotes). No companion CSV or metadata
download is required.

## Usage

``` r
read_ivt(path, geo_attributes = FALSE)
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

## Value

An object of class `ivt`: a list with `cells` (a tibble of one value per
row, keyed by 1-based member-id columns matching the StatCan metadata
Member IDs), and `metadata` (table identity, `dimensions`,
`geographies`, and `footnotes`). `metadata$geographies` carries, per
member and where the vintage stores them: the bilingual display label
(`geo_label`, `geo_label_fr`) and name (`geo_name`, `geo_name_fr` – on
pre-DGUID tables the EN/FR halves of the stored bilingual label),
`geo_uid` (DGUID, or the bare GEOUID on pre-DGUID tables), the
aggregation level (`geo_level`), the geography type / municipal status
(`geo_type`, `geo_type_abbr`), province abbreviation and codes
(`prov_abbr`, `alt_geo_code`, `pr_code`), the data-quality flag
(`dqf_code`, with `dqf_note` and the table-level `dqf_legend`), and the
total non-response rate (`tnr_short_form`).

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

The value store keeps only non-zero cells, so a cell absent from `cells`
is a **zero** – *within a geography that carries any data*. A geography
with no stored cells at all is either wholly suppressed or wholly empty,
and the cell store cannot distinguish the two:
`metadata$geographies$has_data` flags which geographies carry data, and
on the pre-DGUID tables `metadata$geographies$dqf_code` (the
per-geography data-quality flag from the codebook) corroborates it (e.g.
on the 2016 income table 98-400-X2016120 the flag's last digit is `9`
exactly for the 888 geographies with no stored cells, which the Beyond
20/20 viewer renders as suppressed).

## Details

Every primary read is positional (header pointers, block directories,
framed value entries). When one does not resolve and a content-heuristic
fallback supplies values instead – or when directory entries point at
page variants that cannot be decoded – a classed warning
(`canivt_fallback` / `canivt_skipped_pages`) is raised naming the
affected read. Set `options(canivt.strict = TRUE)` to turn these into
errors: on a file layout this package has not been validated against,
the fallback paths are the ones most likely to misread silently.
