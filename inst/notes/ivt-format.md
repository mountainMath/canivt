# StatCan Beyond 20/20 `.ivt` file format

Reverse-engineered specification for the Statistics Canada *Beyond 20/20*
`.ivt` data tables that `canivt` decodes. This document is self-contained; it is
the reference for anyone (human or agent) maintaining the parser.

Reference table: **98-10-0241** (`98100241.ivt`, 57 MB) — "Housing indicators by
tenure … by household type and period of construction". 7 dimensions:
Geography(166) × Age of HH maintainer(9) × Household type(16) × Period of
construction(13) × Statistics(3) × Housing indicators(6) × Tenure(7) =
235,872 cells per geography.

Downloads:
- IVT: `https://www150.statcan.gc.ca/n1/en/tbl/b2020/98100241.zip`
- Data + metadata CSV (ground truth): `https://www150.statcan.gc.ca/n1/tbl/csv/98100241-eng.zip`
  → `98100241.csv` (1.5 GB, all geos; each row has a `Coordinate` member-id tuple
  and a `DGUID`) + `98100241_MetaData.csv` (full dimension/member tables).

## File-level layout

```
[0]            header: table identity (Product ID, EN/FR title, universe,
               Variable List) + doubled dimension names ("GeographyGeography").
               Starts with signature 04 00 20 00. Contains embedded NULs.
[37167]        GEOGRAPHY INDEX: per-geography page directories (see below).
~1.08M..~55.4M PAGE DATA: one ~contiguous block of pages per geography.
~56.93M        FOOTNOTE legend (EN "Footnote N", FR "Renvoi N"; irregular framing).
~56.94M..EOF   CODEBOOK: member-ordered label arrays per dimension (Pascal strings).
```

`canivt` uses the header (identity), the index (page directories), the pages
(cell values) and the codebook (labels, DGUIDs, footnotes). After the 0x1000
stride fix below, ~98% of the file is page data and only ~0.8% is unused.

## Geography index

- Per-geography page directories start at `IVT_IDX0 = 37167`, stride
  `IVT_IDX_STRIDE = 0x1000` (4096 bytes). Directory `n` (0-based) is metadata
  **Member ID `n + 1`** — i.e. geographies are in metadata member order.
- ⚠️ **Critical gotcha:** the directories are grouped 8 per `0x8000` region (the
  first 288 of each 0x1000 slot are used, the rest is zero padding). An early
  version strided by `0x8000` and so read only every 8th geography (21 of 166).
  The correct stride is `0x1000` → **166 geographies**.
- Each directory holds up to `IVT_PAGES_PER_GEO = 288` entries
  `[u32 offset][u16 size][u16 size]` (the two size fields are equal). An entry is
  valid when the sizes agree and `1e6 < offset < filesize`.

## Pages (positional coordinate)

Directory entry `k` (0-based) maps positionally to the outer dimensions:

```
age    = k %/% 32
hh     = (k %/% 2) %% 16        # household type
window = k %% 2                 # 0 -> Period members 0..7, 1 -> 8..12
```

A page is `[4-byte header][presence bitmap (256 B)][dense value array]`.

Header byte 0 encodes the value layout:
- low nibble `0x4` → int32 cells, `0x2` → int16 cells;
- high nibble `0x8` → values follow the presence bitmap directly, `0xa` → a
  `0xFF` separator run + a 2-byte prefix precede the values.
- Seen: `84` int32/plain, `a4` int32/sep, `a2` int16/sep, `82` int16/plain.

## Presence bitmap + value codec

The 256-byte presence bitmap is a positional, dimension-**padded** map:

- 32-byte rows = one Period (row `r` → period `window*8 + r`).
- Within a row: Statistics at byte `stat*8` (stat 3 slot is padding); within that
  8-byte block Housing indicators 0..5 (6,7 are padding), **but the two bytes of
  each adjacent housing pair are stored swapped** — read the presence byte at
  `stat*8 + bitwXor(housing, 1)`.
- Each presence byte's bits 7..1 flag Tenure members 0..6 (bit 0 is pad);
  `0xFE` = all 7 tenure present. popcount = number of stored values for the group.

Values are **dense over present cells**, unaligned little-endian int16/int32 per
the header. The value stream is in plain `(period, stat, housing, tenure)` order;
only the presence *bytes* are pair-swapped, not the values. Iterate groups
period-outer → stat → housing-inner, and within a group tenure `t = 0..6` using
bit `7 - t`.

General principle (also seen in the 1991 format): presence granularity = the
innermost dimension; the "present" marker is `2^n − 2` over that bit-width
(Tenure n=7 → byte `0xFE`); the bitmap is padded to fixed per-dimension strides.

## Codebook (labels, geo ids, footnotes)

At the end of the file, each dimension stores several parallel, member-ordered
arrays of length-prefixed ("Pascal": 1 length byte, then that many text bytes,
0x00-separated) **latin-1** strings. For each dimension: member ordinals, the
member name (EN then FR). For Geography additionally: level name, abbreviations,
classification code, and the full **DGUID** (`2021A000011124` = Canada,
`2021A000210` = Newfoundland and Labrador, …) — these are the canonical
geographic identifiers and align with the geography index order.

- Member names carry **leading-space hierarchy indentation** (`  Owner`,
  `    With mortgage`); `canivt` exposes the raw label and a derived `depth`.
- English member-name blocks start with `Total - <dimension>` (except Statistics,
  whose first member is `Number of private households`); `canivt` selects the
  English block by that keyword + the expected member count.
- Footnotes use irregular framing and are extracted best-effort by anchoring on
  the `Footnote N` (EN) / `Renvoi N` (FR) markers.

## Validation

`tests/testthat/test-decode.R` checks (against the StatCan CSV/known values):
166 geographies, all DGUIDs present, dimension member counts `166,9,16,13,3,6,7`,
7,489,464 decoded cells, and Canada's published tenure totals
`14687350, 9787420, 5870875, 3916550, 4899925, 576625, 4323300`. The pure-R
decode of the whole file takes ~4–5 s.

## Other format variants (not yet implemented)

The **1991 census** Beyond 20/20 format is the same container *family* but with
different constants: page marker `82 01 80 08` (vs the 2021 page headers),
1-byte note-length prefixes (2021 uses 2-byte), geography codes stored inline in
the member label as `"(code)"` (2021 stores DGUIDs in a separate array), and a
presence map keyed to Sex(3) (nibble `0xE`). Its value codec is the same
(unaligned LE int, dense over present cells, age-major/sex-inner). `read_ivt()`
rejects unrecognised files via `ivt_is_supported()`; add a format detector +
variant decoder to extend support.
