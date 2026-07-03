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

### Detailed byte-region map (family 2, table 98-10-0023, 142,016,485 bytes)

Empirically measured regions (every byte accounted for; "→" = decoded by canivt):

```
byte range                 size     contents
0          .. 2,499        2.5 KB → header, English identity (signature 04 00 20 00;
                                     Product ID, EN title, universe, Variable List,
                                     doubled dimension names), embedded NULs.
2,500      .. 3,181        ~680 B → header, French identity (titre, période, enquête,
                                     Sujets/Corrections/Renvois labels).
3,182      .. 35,949       ~32 KB ✗ ZERO PADDING (reserved space before the directory).
35,950     .. 162,750      127 KB → page directory: 15,851 × 8-byte records
                                     [u32 page_offset][u16 size][u16 size].
167,038    .. 124,562,k    119 MB → value pages (one per directory record; physically
                                     UNSORTED — directory[1]=Canada is at 554,596 while
                                     the lowest page sits at 167,038). Each page:
                                     marker, 64-byte presence records, 0xFF trailer,
                                     dense value run. Inter-page gap min 812 B.
124,290,k  .. 141,896,k    17.6 MB → geography codebook: 11 attributes × member chunks
                                     of 256, attribute-major in growing groups.
141,896,k  .. 142,016,485  120 KB → Age (128) and Gender (3) dimension blocks
                                     (FR labels, EN labels, "1..n" ordinal), then EOF.
```

The footnote legend (EN "Footnote N" / FR "Renvoi N") is embedded near the start of
the codebook region rather than in a separate block; `ivt_footnotes()` recovers it
from the last 200 KB.

### Header layout map (`ivt_f2_header_layout()`)

The whole file layout reads from **fixed header offsets**, uniform across both the
modern and legacy formats — no marker scanning:

```
u32 @32   → dimension descriptor block (per-dim count/type/name + title)
u32 @40   → French title block, OUT OF LINE  ┐ both 0 in the modern format,
u32 @48   → English title block, OUT OF LINE ┘ both set in the legacy format
            ⇒ the format VERSION indicator: modern (2016+/DGUID, inline identity)
              vs legacy (pre-DGUID, out-of-line "<id>\r\n<title>" blocks)
u32 @552  → geography field/attribute count (11 modern / 12 legacy)
u16 @558  → page directory start, LOW 16 BITS ONLY (35,950 / 2,019): the true
            start is `u16 + k·65536` for the smallest k whose entry validates
            (k=0 when the directory sits below 64 KiB — every early reference
            table — but 98-10-0013 needs k=1 and 95F0250XDB96001 k=2; under the
            plain u16 read 0013's cell decode was silently EMPTY).
            u32 @558 = value-pages start − 16 on the reference tables.
u32 @572  → codebook region start (~124.31M / 22.75M)
```

`ivt_f2_header_layout()` returns these plus `value_pages` (= `min` page offset),
`n_pages`, and `eof`. The page directory then lists every value page
(`[u32 offset][u16 size][u16 size]`), so all data blocks are located from the
header without marker scanning.

A **section-pointer region** follows (≈ `@544..1080`), now decoded and wired —
every pointer resolves to a block directory of the same 8-byte entry shape
(`[u32 off][u16 len][u16 len]`) as the page directory:

```
u32 @544  → the MASTER directory (at offset 992; ~10 entries covering the whole
            file: FACET04 titles EN/FR, the dimension descriptor, the EN/FR
            identity/notes blobs — the legacy out-of-line title+footnotes blocks
            are entries here — the product id, and a 15-byte EOF trailer)
u32 @712  → the DATA-QUALITY-FLAG legend (15 entries on 2021 tables: EN/FR
            records per code A..E/R/P, framed [82 01][u16][flags][02][code][00]
            [u16 len][text]; a 1-entry stub on pre-DGUID tables)
@824+14·(k−1) → dimension k's codebook block directory (14-byte slot records
            [u32 dir_ptr][u32 ?][u32 n_entries][2B]; see dimdir.R) — the
            member-label blocks, ordinals, doubled-name marker and per-dimension
            footnotes are all read positionally from these
```

So the codebook, the notes and the legends are located **from the header**, with
the bounded tail scans surviving only as fallbacks for layouts whose directories
do not resolve.

### Undecoded / unused pockets

What is **not** consumed or not fully understood (small; the bulk of the file is
fully decoded):

- **Header zero-padding** (bytes ~3,182..35,949, ~32 KB of `00`). Reserved/fixed
  alignment before the page directory; carries no observed information.
- **The doubled directory size field.** Each 8-byte directory record stores the page
  byte-length **twice** (`[u32 off][u16 size][u16 size]`, the two `size`s identical).
  The size is the page's **allocated** length and upper-bounds its content: on every
  page of every supported table `4 + presence + trailer + n_values*width <= size`,
  with **equality** on the trailer-less `b2 == 0x00` pages. The decoder enforces
  this per page (`canivt_page_overrun`), so a misread marker aborts rather than
  decoding garbage values. The second copy's purpose (redundancy?) is unproven.
- **Per-page header bytes.** The page marker is `[b0] 01 [b2] [b3]` with the value-
  width in `b0`'s low nibble and `b3 ∈ {08,09}`; **`b2` encodes the trailer**:
  `b2 == 0x00` means "no trailer" (the value run starts right after the presence
  section, and the page size fits exactly), otherwise
  `trailer = 2·(b2 >> 4) + 2·(low nibble(b2) > 0)` bytes (plus a fixed 32-byte
  auxiliary block on `0xa2` int16 pages). Derived from 98-10-0013, whose 22
  pages carry 18 distinct `b2` values (`0x2a`..`0x63`, trailers 6–14, each
  anchored byte-exact against the StatCan CSV); on the tables where `b2` never
  varies it reproduces the historical per-marker constants. What the trailing
  2-byte field (low-nibble flag) holds is unknown (`00 e0` on 0013's first
  page). A **`b3 = 0x0a` page variant** exists (369 `a2 01 03 0a` pages on
  98-400-X2016203; int16 values all -1, presumably suppression sentinels):
  **undecoded**, skipped **loudly** (`canivt_skipped_pages`).
- **Label encoding is Windows-1252.** Labels use the cp1252 `0x80-0x9F` punctuation
  block (e.g. `0x92` = the curly apostrophe in `Tla’amin Lands` / `Sambaa K’e`,
  `0x93/0x94` quotes, `0x96/0x97` dashes). `is_label_byte()` must accept these
  (everything `≥ 0x20` except `0x7F`) — rejecting them makes `rd_pascal` fail on
  such a label and split the member array mid-stream, scrambling that chunk. This
  was the cause of the former `GEO_TYPE_DESC`/`GEO_NAME` residuals; with it fixed,
  every geography attribute except `DQF_NOTE` decodes exact. `DQF_NOTE` (a long
  concatenation of suppression statements) still spans multiple blocks and is
  recovered via its 1:1 relationship with `DQF_CODE`.
- **Doubled dimension names** in the header (`"GeographyGeography"`) — cosmetic, the
  duplication is stripped, reason unknown.
- Family-1 vs family-2 use different geography-id storage (separate DGUID array vs the
  attribute-major codebook); the per-table value-**type** byte beyond the marker low
  nibble is inferred, not located as a standalone field.

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

### Value-entry block framings (strict positional parse)

Each codebook value block (one attribute × one 256-member chunk × one language,
addressed exactly by its dimension's block directory entry — see the header
section-pointer table) carries one of two byte framings, decoded by
`ivt_f2_dir_entry_members()`:

- **Plain member array** — `[01 01][u16 payload_len][u16 n_slots]` then exactly
  `n_slots` records `[len][text][00]`. `payload_len` = entry length − 4;
  `n_slots` is the chunk size **padded to a power of two** (a 91-member chunk
  stores 128 slots, a full chunk 256), the pad being **empty records** `00 00`.
  An **absent member** (one carrying no value, e.g. 98-10-0662's derived
  aggregate "Canada outside Quebec and New Brunswick") is likewise an explicit
  empty record, keeping every member at its positional slot. A record's `len` is
  a single byte, so values are **capped at 252 bytes** (`0xFC`; longer texts —
  some `DQF_NOTE` suppression notes — are stored truncated in the file itself).
- **Bit-headed dense array** — `[81 01][u16 nbits][bitstream][80|01]` then
  **unterminated** records `[len][text]`. The bitstream occupies
  `2*ceil(nbits/16)` bytes (u16-padded); its per-member coding is not yet
  decoded. Absent members are **skipped** in the record run, so the values must
  be re-aligned using the empty-slot pattern of a plain sibling block from the
  same chunk.

The generic run-scanner (`ivt_find_member_blocks()`) mis-handles both: it splits
a plain array at every empty record (an absent member or the pow-2 pad) and
fragments long records, and it cannot know a dense array skips members. The
strict parse is therefore the primary read wherever a block directory addresses
the entry; the scanner remains the classifier and the fallback.

### Footnotes

Footnotes live just before the member arrays. Each is framed as
`00? 01 01 <u16 length LE> [01] <text>` — the text is the footnote prose, the
`<length>` is its byte length (±1), and the language is given by the leading
`Footnote N` (EN) / `Renvoi N` (FR) marker (the `N` is always `1` and is **not**
the StatCan Note ID; the IVT does not record the Note ID per footnote).

NULs do **not** reliably separate footnotes — consecutive ones can be back to
back with only `\r\n` + framing between them. Instead, the robust delimiter is
that **footnote prose contains only "text bytes"** (printable ASCII, `\t\r\n`,
or latin-1 `0xA0..0xFF`), while every record's framing contains a NUL or a
sub-`0x09` control byte. So `canivt` extracts footnotes as **maximal runs of
text bytes** (`is_text_byte()` + `rle()`), keeping the runs that begin — after
optional leading whitespace — with a `Footnote`/`Renvoi` marker. The leading
whitespace tolerance matters because the length prefix's high byte is itself a
text byte when it is `\t`/`\n`/`\r` (e.g. a 2571-byte footnote has high byte
`0x0a`), which prepends a stray newline to the run.

This recovers all 10 EN + 10 FR footnotes for the reference table, each matching
the StatCan metadata `Note` text exactly. Footnotes are returned in file order
within each language (`number` = that position), since the IVT order differs from
the metadata Note IDs (footnotes are stored next to their dimensions).

## Validation

`tests/testthat/test-decode.R` checks (against the StatCan CSV/known values):
166 geographies, all DGUIDs present, dimension member counts `166,9,16,13,3,6,7`,
7,489,464 decoded cells, and Canada's published tenure totals
`14687350, 9787420, 5870875, 3916550, 4899925, 576625, 4323300`. The pure-R
decode of the whole file takes ~4–5 s.

## The 1991 census variant (E9101 / `1003011.IVT`) — partial

The **1991 census** Beyond 20/20 format is the same container *family* as 2021.
Reference table here is **E9101** (`1003011.IVT`, 26 MB) — "Population by Single
Years of Age (110), Showing Sex (3)". 3 dimensions: Geography(41,859, incl.
enumeration areas) × Age(110) × Sex(3) = 330 cells per geography. `read_ivt()`
rejects it today via `ivt_is_supported()`. The status below was established by
direct analysis against scraped per-geography ground truth (Canada + provinces,
GIDs 1,2,3,9,10,11,13,14 — see the sibling `censusmapper-import` repo).

### What is solved & verified
- **Container / page directory.** Pages begin with marker `82 01 80 08` (a
  sub-record marker `84 01 40 08` also occurs). The page directory lives at byte
  **2023**: 8-byte records `[u16 size][u16 dup][u32 offset]` (sizes equal),
  ~10,169 pages. Each page packs **~4 geographies** (not one geo per page as in
  2021); their value runs are concatenated.
- **Codebook.** Same end-of-file Pascal-string member arrays as 2021. Table
  identity, the 3 dimension declarations, and all geography members decode;
  geography **codes are inline** in the label as `"(code)"` + a trailing flag
  (2021 stores DGUIDs in a separate array).
- **Footnotes are a single text blob** (`ivt_f2_legacy_footnotes()`), not the modern
  framed `Footnote N` / `Renvoi N` records. The notes block (header `01 01 <u16 len>`,
  running to EOF, referenced from the header section table) holds sections
  Note / Footnotes / Abbreviations / Special Notes; the footnotes are `(N) <text>`
  lines under the **"Footnotes"** header, ending at the next section header.
  Validated: 40 footnotes (1..40) for 1003011. `ivt_f2_metadata()` uses this for the
  legacy format and the framed parser for the modern one.
- **Geography codebook PORTED to canivt (`ivt_f2_geo_inline()`), validated exact
  for all 41,859 geographies.** Each entry packs `"<name> (<GEOUID>)   <dqf_code>"`:
  a **bilingual** name (`"English | French"`, e.g. `Newfoundland | Terre-Neuve`),
  the bare **GEOUID** (a shortened DGUID — the 2016+ DGUID prepends a year and a
  statistical-area-type/schema prefix that pre-2016 tables lack; e.g. 1991 `10` ↔
  2021 `2021A000210`), and the 5-digit **data-quality flag**. First-appearance
  de-duplication on the unique GEOUID yields member order (the same idea as the
  2021 DGUID stitch). For enumeration areas the name equals the code.

#### The geography layout is declared in the header (not inferred)

The codebook layout (DGUID arrays vs the inline `"name (GEOUID) flag"` form) does
**not** have to be guessed by parsing the codebook — the fixed header signals it
explicitly. Header layout (0-based, little-endian):

```
@0   u32  04 00 20 00 signature
@32  u32  → dimension descriptor block. The descriptor stores, per dimension, the
          member count + the (doubled) dimension name; the geography member count
          is the u16 at descriptor+52 (63,404 for 98-10-0023, 41,859 for 1003011).
@40  u32  → French title string, OUT OF LINE (0 in the modern format)
@48  u32  → English title string, OUT OF LINE (0 in the modern format)
```

- **Modern (2016+/DGUID) export** (98-10-0023): identity is **inline text** in the
  header (`Product ID:`, `Reference Period: 2021-01-01`, titles); the out-of-line
  title pointers `@40`/`@48` are **0**. → DGUID attribute-table codebook.
- **Legacy (pre-DGUID) export** (1003011): no inline `Reference Period` text; titles
  are stored **out of line** with `@40`/`@48` **non-zero** (e.g. `1942`/`1458`,
  pointing at `01 01 <len> 00 "1003011\r\nE9101 - Population…"`). → inline GEOUID
  codebook.

`ivt_f2_geo_is_inline()` reads this header field (`@48`/`@40 != 0`); the geography
member count comes from `ivt_f2_header_geo_count()` (descriptor+52). Both validated
on the two reference tables; the discriminator is a header-format-version signal
that co-varies with the geography codebook layout (confirm against further vintages
before relying on it beyond these two eras).

#### The dimension descriptor (`ivt_f2_descriptor()`) — all dimensions

The descriptor block (header `@32`) declares **every** dimension, in both formats,
so it is the file's own statement of the dimension structure (the legacy format
has no inline "Variable List" to parse). Layout:

```
desc+16  u16   number of dimensions (3 / 3)
desc+52        one record per dimension, back to back:
               [count][marker = <type> 0x01][name][name]
               • <type>: 0x10 = geography, 0x07 = the age-type dimension,
                 0x02 = the gender/sex-type dimension
               • count: u16 for geography (> 255), u8 otherwise
               • the dimension name is stored TWICE and TRUNCATED to a fixed
                 display width (~14 chars), so "Age (in single years)…" appears as
                 "Age (in singleAge (in single"; 0x01 never occurs inside a name,
                 so the markers delimit records unambiguously
later    "FACET04" + the English title (legacy file appends e.g. "1991 Census …")
```

Decoded exact for both tables: counts `63404/128/3` (98-10-0023) and
`41859/110/3` (1003011), the type markers, and the title (which gives the legacy
file its **census year**). Names are the truncated display form; full names come
from the Variable List (2021) or the codebook. `ivt_f2_descriptor()` returns
`n_dim`, per-dimension `name`/`count`/`type`, and `title`.

#### Metadata-driven geography parser (`ivt_f2_geographies()`)

Because the header declares the geography **layout** (`ivt_f2_geo_is_inline()`) and
**count** (`ivt_f2_header_geo_count()`), the two codebook parsers are consolidated
behind one entry point: `ivt_f2_geographies()` dispatches to the DGUID attribute
parser or the inline parser, returns a uniform table led by `member_id`,
`geo_name`, `geo_uid` (DGUID or GEOUID), and validates the decoded row count
against the header via `ivt_f2_check_geo_count()` — so a dropped/duplicated codebook
chunk is caught against the file's own declared count rather than trusted blindly.
`ivt_tidy()` and the metadata both key geography on the unified `geo_uid`.

#### How much of the 2021 code carries over (geography)

| component | carries over? |
|---|---|
| `ivt_family()` / `ivt_f2_find_directory()` (container detection) | **yes** — 1991 is detected as family 2, directory found (10,465 pages, marker `82 01 80 08`) |
| `ivt_find_member_blocks()` (Pascal block scanner) | **yes** — reused unchanged |
| first-appearance de-dup → member order | **yes** — concept reused (GEOUID instead of DGUID) |
| `ivt_f2_geo_dguids()` (the `2021…` pattern scan) | **no** — pre-DGUID, returns empty; `ivt_f2_geo_is_inline()` routes to the inline parser |
| `ivt_f2_geo_attributes()` (slotted DGUID-anchored group parser) | **no** — 1991 packs name+code+flag into one block, so a much simpler inline parser is used |
| bilingual handling | **new** — 1991 names are one `"EN | FR"` string; 2021 stores EN and FR as separate blocks |
| `ivt_f2_descriptor()` (header dimension metadata) | **yes** — same descriptor in both; gives 1991 its dimension counts/names/title without a Variable List |
| `ivt_f2_dim_member_labels()` (Age/Sex labels) | **yes, unchanged** — 1991 Age(110)/Sex(3) labels decode exact (EN block precedes the `1..n` ordinal, same as 2021) |
- **Value codec — same as 2021, PORTED to canivt and validated.** Dense little-
  endian integers, age-major / sex-inner (`[Total, Male, Female]` per age). Cell
  width is per-page via the marker low nibble: `0x84` → int32 (vstart 268), `0x82`
  → int16 (vstart 276) — added to `IVT_F2_PAGE_PARAMS`. The generic `ivt_f2_decode`
  (byte-pair-swap presence, 128-nibble record + presence filter) handles the
  110-age record and the `{0..53,55}` pad with **no changes**. Validated **330/330
  exact for all 8 scraped ground-truth geographies** (dense int32 + sparse int16);
  the whole 1003011 file decodes to 8.67M non-zero cells in ~3 s.
- **Dense geographies decode exactly.** Geos with all 330 cells present (Canada
  and the largest provinces) are simply 330 consecutive ints and reproduce the
  ground truth byte-for-byte (e.g. Canada int32 @316623 → 27,296,860 / …).
  Consecutive dense geos are packed back-to-back with no inter-geo header.
- **Dense presence bitmap.** For all-present geos the presence map is a positional
  **64-byte block**, nibble-per-age, marker `0xE` (= 2^4−2; Sex padded to a
  nibble, bit0 pad — the same "2^n−2 over the innermost dim" principle as 2021's
  `0xFE` tenure byte). Data nibbles occupy byte positions **{0..53, 55}** within
  the block; bytes **{54, 56..63}** are zero padding (an interspersed pad byte at
  54, then 8 trailing). All-present blocks are all-`0xee`.

### The open problem: sparse-geo cell presence (NOT yet cracked)
Sparse geographies (every province that has *any* zero cell — i.e. most of them,
GIDs 9/10/11/13/14 — and all enumeration areas) store **only their nonzero cells**
(verified: GID9 = 279/330, GID11 = 222/330, GID10 = 55/330, each found as an exact
contiguous int16 run). Reconstructing them into the 330-cell grid needs to know
*which* cells are present, and that encoding is **not a verbatim positional
bitmap**. Exhaustive search rules out the obvious models — for each sparse geo's
known present-pattern, no match is found under: contiguous nibble-per-age (any
bit assignment, hi/lo nibble order, age-pair swap); the 64-byte interspersed-pad
layout learned from the dense blocks; tight 3-bit-per-age packing; nibble-padded
packing.

**This was the wrong frame — sparse presence is CRACKED.** It is positional all
along; the records are **byte-pair-swapped** (the same rule as 98100023 below). Each
geo gets a 64-byte record (consecutive in the page's presence section, ages at byte
positions {0..53,55}, marker `0xE`). Swap adjacent bytes (`B0↔B1, B2↔B3, …`), then
read positional nibble-per-age with Sex bits `Total/Male/Female = 3/2/1`, `0` =
absent. Verified against the 8 scraped GIDs: GID13/14 exact; GID9/10/11 (records at
314297/314361/314425, 64 bytes apart) exact except the very last age (idx 109) — an
off-by-one because 1991's odd byte-55 data byte lands in byte 54 *after* the swap (do
the `{0..53,55}` byte-position mapping AFTER swapping). With that, every geo decodes.

## 1991 vs 2021 — similarities & differences

| aspect | 2021 (`98100241`) | 1991 (`1003011` / E9101) |
|---|---|---|
| file signature | `04 00 20 00` | `04 00 20 00` (**same**) |
| dimensions | 7 (Geo×Age×HHtype×Period×Stat×HI×Tenure) | 3 (Geo×Age(110)×Sex(3)) |
| geographies | 166 | 41,859 (incl. EAs) |
| cells / geo | 235,872 | 330 |
| codebook | Pascal strings, member-ordered, doubled dim names | **same** structure |
| geo identifiers | DGUIDs in a separate array | inline `"(code)"` in the label + flag |
| footnote length prefix | 2 bytes | 1 byte |
| geo index | fixed table @37167, stride `0x1000`, one page-dir per geo | page directory @**2023**, `[u16 size][u16 dup][u32 off]`, ~10,169 pages |
| page → geo | one page per (geo, age, hh, window) slice | one page packs ~4 geos, values concatenated |
| page marker | header byte nibbles `84/a4/a2/82` | literal `82 01 80 08` (+ sub-marker `84 01 40 08`) |
| value codec | unaligned LE int, base-5, dense over present | **same** |
| cell width | per-page int16/int32 | per-geo int16/int32 |
| innermost dim / presence unit | Tenure(7) → 1 byte, marker `0xFE` | Sex(3) → 1 nibble, marker `0xE` (**same 2^n−2 principle**) |
| presence map (dense) | positional padded 256-byte bitmap | positional padded **64-byte** block, nibbles at bytes {0..53,55} |
| presence (sparse) | n/a — every geo positional | positional **after byte-pair-swap** (only nonzero cells stored as values) |

The 1991 sparse-presence "blocker" is resolved: the records are positional once you
**swap adjacent bytes** — the same trick family-1 uses on its presence bytes
(`bitwXor(housing,1)`) and the same rule that decodes 98100023 (next section). Both
the 1991 file and the 2021 family-2 table now decode end-to-end.

`read_ivt()` rejects unrecognised files via `ivt_is_supported()`; adding a format
detector + dense-only 1991 decoder is straightforward, but a *complete* 1991
decoder is blocked on the sparse-presence encoding above.

## Two B2020 container families (important)

There are (at least) **two distinct container families** under the shared
`04 00 20 00` signature:

1. **Per-geo-directory family** — table **98-10-0241** (the one canivt decodes).
   Per-geography page directories at `IVT_IDX0 + n*0x1000`; page header byte 0 is
   the layout code (`84/a4/a2/82`); presence is a **positional padded bitmap** for
   *every* geo, so all geos decode.
2. **Single-directory / `XX 01 YY 08` family** — the 1991 table `1003011` **and**
   the 2021 table **98-10-0023** ("Age (single years) (128) × Gender (3)"). One
   contiguous page directory of `[u32 off][u16 size][u16 size]` records (98100023:
   bytes 35950..162750, 15,851 pages, in geography member-id order); pages start
   with markers `82/84/88/a2/a4/a8 01 .. 08|09` and pack **4 geos each**. Presence
   is **positional after a byte-pair-swap** — fully cracked and ported (see below).

`98100023` was pulled specifically to crack the family-2 presence with good ground
truth (its companion CSV has an exact `Coordinate` = `geo.age` tuple per row and
inline gender values — blanks/zeros give exact cell presence; 23k+ geos available).
Findings (substantially revised — two earlier claims here were **wrong** and are
corrected below):

- **Values are ALL IEEE float64 LE** (the earlier "mix of int + float64" claim was
  wrong). Verified exact by byte-search: Canada's 126 integer members form a
  contiguous float64 run at file offset 554860, and 200 sparse geos were each
  located by their float64 value stream. Values are **dense over present cells**, in
  member-id order, gender-inner (`Total, Men, Women`). The Age dimension's member
  ids are **1 = "Total - Age"**, **2..126 = single years 0..124**, **127 = Average
  age**, **128 = Median age** — i.e. ids 127/128 are float *statistics* sharing the
  same float64 storage as the counts.
- **Page layout**: marker `88 01 20 08` (3rd byte `20` constant), then the presence
  section, then an `ff ff[ ff ff]` separator, then the contiguous float64 value
  runs. **Geos-per-page varies**: most pages hold 4 geos (256-byte presence section
  = 4 × 64-byte records), but some pack ~150 geos (~9.6 KB presence). Presence-record
  order == value-run order, so the *first* 64-byte record after a marker pairs with
  the *first* value run after the separator.
- **Presence records are ≈64 bytes** and use the **same gender-nibble scheme as the
  decoded present/missing** (Gender(3) padded into a nibble; `Total,Men,Women` at
  bits 3,2,1; `0xe` = 1110 = all three; the `2^n−2` principle). They store the
  gender nibble of each **present** member **in member order**, with absent members
  compressed out. Confirmed by: per-record present-member **count matches ground
  truth exactly** (record 0 ↔ geo 229 = 104; geo 9 = 62), and the present-nibble
  **sequence matches gt in order** (random rounding flips a handful of gender nibbles
  → noise).
- **Sparse presence is positional after a BYTE-PAIR-SWAP** (CRACKED). Each geo gets a
  fixed **64-byte presence record**; the records sit back-to-back in a page's presence
  section, one per geo, in value-run order. To decode a record: **swap adjacent bytes**
  (`B0↔B1, B2↔B3, …`), then read it as a positional nibble-per-member bitmap — member
  `m` (1..128) is nibble `m`, gender `Total/Men/Women` at bits `3/2/1`, nibble `0` =
  member absent. This is the same pair-swap principle as family-1 (`bitwXor(housing,1)`),
  just at byte granularity (each 4-member / 2-byte group has its two bytes swapped, i.e.
  stored as `[m3,m4,m1,m2],[m7,m8,m5,m6],…`). Recovered via an empirical position→member
  correlation over 48 geos (perfectly regular, 48/48). Earlier "non-positional / RLE"
  notes were **wrong** — purely an artifact of reading the bytes unswapped.

**Family-2 now decodes end-to-end** (validated on 98100023): page directory →
per-geo 64-byte presence record (byte-swap → positional gender nibbles) → dense
float64 value run assigned to the present `(member, gender)` cells in member-major /
gender-inner order. Exact vs ground truth: 48/48 geos' presence (0 diffs), and a full
cell decode of geo 9 = 133 cells, all 133 float64 values exact.

### Family-2 fully decoded and ported to `canivt` (98100023, validated cell-exact)

`canivt` decodes family 2 end-to-end (`R/container-f2.R`, `R/decode-f2.R`,
`R/read-f2.R`; auto-detected by `ivt_family()`). Validated **cell-for-cell against
the StatCan CSV for all 63,404 geographies** of 98-10-0023 (presence membership and
every value, float64 and int16). The complete spec:

- **Page directory.** One contiguous run of 8-byte records
  `[u32 page_offset][u16 size][u16 size]` (98100023: bytes 35950..162750, 15,851
  records; `size` = the whole page's byte length, incl. trailing padding). The
  directory is in **geography member-id order**, and each entry is a page holding a
  fixed **4 geographies** → 15,851 × 4 = 63,404 geos. Locate the directory by
  finding any page marker and the record that points at it, then growing the
  maximal contiguous run of valid records (`ivt_f2_find_directory`).
- **Page markers and the value-type code.** Markers are `[b0] 01 [b2] [b3]` with
  `b0` ∈ `{0x82,0x84,0x88,0xa2,0xa4,0xa8}` and `b3` ∈ `{0x08,0x09}`. The marker's
  **low nibble is the value-width code** (exactly the per-table type marker that had
  to exist): `0x8` → 8-byte **float64**, `0x4` → int32, `0x2` → **int16** (the int
  pages are base-5 random-rounded counts). 98100023 uses `88` (float64), `a8`
  (float64) and `a2` (int16).
- **Page layout.** `[4-byte marker][256-byte presence section][0xFF trailer][dense
  value run]`. The presence section is 4 × 64-byte records (one per geo, in value
  order). The trailer is **encoded in the marker's `b2` byte**
  (`ivt_value_trailer()`, decode.R): `b2 == 0x00` → no trailer; otherwise
  `2·(b2 >> 4) + 2·(low nibble(b2) > 0)` bytes, plus a fixed 32-byte auxiliary
  block on `0xa2` int16 pages. This reproduces the six historically constant
  pairs (`88/20`→4, `a8/41`→10, `84/40`→8, `82/80`→16, `a4/82`→18, `a2/03`→34 —
  which had made the trailer look like a per-width constant) and the 18 varying
  `b2` values of 98-10-0013 (each anchored byte-exact vs the StatCan CSV); an
  unrecognised width code or high nibble aborts (`canivt_unknown_marker`)
  instead of decoding with a guessed layout. Values are dense in the page's
  width, one per present cell, in the presence order; the page is then
  zero-padded up to `size`, and the computed value run must fit `size` (checked
  per page, `canivt_page_overrun`).
- **Presence record (the byte-pair-swap).** Each 64-byte record is **byte-pair
  swapped** (`B0↔B1, B2↔B3, …` — the same principle as family 1's `bitwXor(housing,
  1)`, at byte granularity), after which it is a positional nibble-per-member bitmap:
  member `m` (1..128) is nibble `m`, genders `Total/Men/Women` at bits `3/2/1`, `0` =
  absent, `0xE` = all three. Cells are emitted member-major, gender-inner.
- **Only non-zero cells are stored** (the StatCan CSV publishes the zeros), so an
  absent cell means a value of 0.

**Family-2 codebook (last ~18 MB).** Geography attributes are stored in
**member-ordered chunks of 256**, grouped attribute-major by member range, with a
full **English copy followed by an identical-keyed French copy**. The two data
dimensions (Age, Gender) sit at the very end as clean single blocks — an EN block,
its FR twin, then a `1..n` member-ordinal block. `R/codebook-f2.R` decodes:

- **Geography DGUIDs** — a fast vectorised scan for the Pascal-prefixed `2021…`
  strings, deduplicated by first appearance (DGUIDs are globally unique and laid
  down in member order, so this yields the geographies in 1-based member-id order).
  Validated **exact for all 63,404** geographies vs the metadata (`DGUID`, attr 16).
- **Age (128) / Gender (3) member labels** — the EN block is the one immediately
  preceding each dimension's `1..n` ordinal block (a cheap tail scan). Validated
  exact vs the metadata.

So `ivt_tidy()` now returns `dguid, age, gender, value` for family 2 (geography
labelled by its DGUID — the canonical StatCan key).

### The geography attribute schema (fully mapped)

Each geography member carries **11 attributes**, identified by value-matching every
codebook block against the StatCan metadata. In IVT declaration order the metadata
lists them as `17;3;4;5;9;10;14;15;12;13;16`; the binary lays them out per group in
this fixed order (text attributes as an **EN block then an FR block**, numeric/coded
attributes as **two identical blocks**):

| # | key | attribute | example (Canada) | notes |
|---|-----|-----------|------------------|-------|
| 1 | 12 | `GEO_NAME` | `Canada` | text for named places; **equals the geocode for DAs** |
| 2 | 15 | `GEO_TYPE_DESC` | `Country` | EN+FR; small controlled vocab |
| 3 | 5  | `GEO_TYPE_ABBR` | `Country`→`PR`/`DA` | EN+FR |
| 4 | 4  | `GEO_LEVEL_DESC` | `Country` | EN+FR |
| 5 | 9  | `PROV_ABBR` | `...`/`N.L.` | EN+FR |
| 6 | 16 | `DGUID` | `2021A000011124` | unique; **decoded, 100 %** |
| 7 | 3  | `ALT_GEO_CODE` | `01`/`1001105` | the classification geocode |
| 8 | 10 | `PR_CODE` | `01`/`10` | province/territory geocode |
| 9 | 13 | `DQF_CODE` | `20000` | **data-quality flag** (5-digit; `00000` = best) |
| 10| 14 | `DQF_NOTE` | `Excludes census data…` | EN+FR data-quality note |
| 11| 17 | `TNR_SHORT_FORM` | `3.1` | **total non-response rate %** (decimal `.` EN / `,` FR) |

So the codebook encodes the geography **names, two geocodes, the geographic
level/type (EN+FR), per-member data-quality flags and non-response rates** — all
present and value-matched.

### Group structure — fully decoded (`ivt_f2_geo_attributes()`)

The codebook is split into **groups** of growing size (`1, 1, 2, 4, 8, 16, 32, 64,
120` 256-member chunks for 98-10-0023 — coarse geographies first, dissemination
areas last). Within a group the layout is **attribute-major**: for each of the 11
attributes in the slot order above, **G English blocks** (chunk `0..G-1`) **then G
French blocks** (numeric/coded attributes store the French side as an identical
duplicate). So a group is `22·G` blocks, with `DGUID` at slot 5.

The parser anchors on the (100 %-validated) DGUID blocks:

1. **Segment groups.** In file order the DGUID blocks for a group are G member-ids
   ascending (English) then the same G (French); a maximal strictly-increasing run
   is the English set (size G), the next G are its French copy → one group with
   `d0` = the first DGUID-English block index and `starts` = the G chunk member-ids.
2. **Locate slot 0.** `group_lo` (the NAME English chunk-0 block) `= d0 − 10·G`
   (five attribute slots × 2 languages × G blocks precede DGUID).
3. **Read each attribute.** Attribute slot `a`, English, chunk `c` is block
   `group_lo + a·2G + c`.

Two robustness fixes were needed: (a) the **first group** carries an extra leading
NAME pair (a header table-of-contents), so its counted NAME-English block is at
`group_lo + G`; (b) **`DQF_NOTE`** (slot 9) is long text that the block scanner
splits into a variable number of blocks, so **`TNR_SHORT_FORM`** (slot 10) is found
by content instead (blocks of decimal-point numbers). The block scan is also
filtered to clean member arrays first (drop tiny garbage byte-runs and the
consecutive-integer member-ordinal delimiter blocks).

**Validated exact vs the metadata for all 63,404 geographies**: `GEO_NAME`,
`GEO_TYPE_DESC`, `GEO_LEVEL_DESC`, `GEO_TYPE_ABBR`, `PROV_ABBR`, `DGUID`,
`ALT_GEO_CODE`, `PR_CODE`, `DQF_CODE` and `TNR_SHORT_FORM` all 100 % (after the
Windows-1252 `is_label_byte()` fix above). `DQF_NOTE` is also 100 %, recovered via
its 1:1 relationship with `DQF_CODE` (its long concatenated text spans multiple
blocks). `read_ivt(geo_attributes = TRUE)` returns the table and `ivt_tidy()` then
labels by `geo_name` + `geo_level`; the default keeps the DGUID key.

**1991 `1003011`** is the same family-2 container with int16/int32 values and an
inline-code codebook; its sparse presence uses the **same byte-pair-swap** (verified
against the scraped GIDs). Wiring it into `read_ivt()` is the remaining family-2 task.
