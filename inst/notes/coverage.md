# IVT format coverage — what we decode and what's left

A living assessment of how completely `canivt` understands the Beyond 20/20 `.ivt`
format. **Update this when a gap is closed or a new one is found.** Status keys:
`[x]` decoded & exposed · `[~]` read but not surfaced (recoverable) · `[?]` read
but semantics unproven · `[ ]` not parsed / unknown.

Byte-coverage figures below are measured on the family-2 reference table
**98-10-0023** (142,016,485 bytes); cross-checked against family-1 (98-10-0241)
and the legacy 1991 table (1003011).

## Byte coverage (every region is identified)

| region | bytes | share | status |
|---|--:|--:|---|
| header (identity + descriptor) | ~3.2 KB | 0.002 % | partial — see below |
| header zero-padding | ~33 KB | 0.023 % | reserved, no information |
| page directory | 127 KB | 0.089 % | fully used |
| dir → pages gap | ~4 KB | 0.003 % | padding |
| value pages (data) | 124 MB | 87.6 % | decoded cell-exact |
| codebook + footnotes + dimension blocks | 17.4 MB | 12.3 % | see below |

No unexplained "mystery blocks": 100 % of the file is accounted for by region.
Within the value pages, **96.7 %** is marker + presence + values (all decoded
exactly) and **3.3 %** is `0xFF` trailers + zero-padding (no information).

## [x] Fully decoded and exposed

- [x] All cell values (validated cell-for-cell vs the StatCan CSV — family 1:
  7,489,464 cells; family 2: 14.5 M; 1991: all scraped ground-truth geographies).
- [x] Geography: all 11 attributes — name, DGUID/GEOUID, level, type +
  abbreviation, province abbreviation, two geocodes, data-quality flag + note,
  non-response rate. (Covers every StatCan geo attribute key 3,4,5,9,10,12-17.)
- [x] Dimension member labels (Age/Gender/Sex), counts, type markers.
- [x] Footnote text (modern framed `Footnote N`/`Renvoi N`; legacy `(N) text`).
- [x] Header layout pointers (`ivt_f2_header_layout()`); format/version indicator.

## [~] Read but not surfaced (recoverable, just not exposed)

The codebook scan finds 5,942 member-array blocks; we extract the English/first
copy of each attribute and parse past the rest.

- [~] **French copies of every label** — names, levels, types, footnotes, and the
  Age/Gender member labels (~half the codebook volume). Discarded (EN-only).
- [~] Per-chunk **member-ordinal arrays** (`1..n`) — used only as anchors.
- [~] Block-framing **`<u16>` length prefixes** — we scan instead of using them.
- [~] The **doubled directory size field** (second copy ignored).

## [?] Read structurally but semantics unproven

- [?] Fixed header fields `@4,@8,@12,@16,@20` (constants `32`, `64/8`, `544`,
  `32/14`, `4096`) — `@20` is the family-1 `0x1000` stride; the rest unexplained.
- [?] Descriptor sub-header bytes (`f0 20 00 80`, `8f c8 0f f8`, per-dimension
  display masks `f3 ff f0 ff` / `c0 ff c0 ff`).
- [?] Dimension **type markers** `0x10`/`0x07`/`0x02` (geography / age-type /
  gender-type — inferred, not proven).
- [?] Page-marker bytes `b2` (`0x20`/`0x41`/`0x03`) and `b3` (`08`/`09`); only the
  value-width low nibble of `b0` is understood.
- [x] The marker-specific pad/`0xFF` **trailer length** is now tabulated per
  marker (`IVT_F2_PAGE_TRAILER`: 4/10/34/18/8/16) and the value-run start derived
  as `4 + presence_len + trailer`. Still *positional* (we do not know why each
  marker has its particular trailer), but no longer a decode gap.

## [x] Decoder generality — arbitrary-dimension family-2 (DONE)

The family-2 cell decoder is now **n-dimensional**, driven entirely by the header
descriptor, and validated cell-exact on the 4-dimension table **98-10-0129**
(Geography × Gender × Marital status × Age): the full 15,685,859 non-zero cells
decode in ~3 s, with **120/120** sampled geographies and **all 28 `0xa4`-marker
geographies** an exact match vs the StatCan CSV; the 3-dim tables (98-10-0023,
1003011) still decode exact (regression-green).

- [x] **Geographies per page is computed** = geography member count / page count
  (4 for the 3-dim tables, **2** for 98-10-0129). `ivt_f2_geos_per_page()`.
- [x] **Presence is a power-of-two-nested positional bitmap** over the data
  dimensions (descriptor order, outermost first; each level padded to the next
  power of two of count × inner-block; innermost in the low bits). Byte-pair-
  swapped, read **MSB-first**. The old "128 Age nibbles × 3 Gender bits" is the
  special case (Gender→4 bits, Age→512 → 64-byte record). 98-10-0129 →
  strides 256/16/1, 128-byte record. `ivt_f2_bit_layout()` / `ivt_f2_cell_grid()`.
- [x] **Marker `0xa4`** (int32) added: trailer **18** → values inline at off+278.
  (It is *not* a "separator" layout — the value run is contiguous; the trailing
  `0xAAAAAAAA` slots are pad after the run.)
- [x] **Value-run start generalised** to `4 + presence_len + trailer[marker]`
  (`presence_len = rec_bytes × geos_per_page`), reproducing the validated absolute
  starts and adapting to any record size. `IVT_F2_PAGE_TRAILER`.
- [x] **Geography count** comes from the descriptor's geography record
  (`ivt_f2_geo_count()`); the fixed-offset `ivt_f2_header_geo_count()` u16 reads a
  wrong 16320 for 4-dim descriptors and is no longer used for sizing.

### Note: the `0xa` marker variant and empty geographies

`0xa` vs `0x8` in the marker's high nibble is purely a **storage variant** (a
longer pad/`0xFF` trailer before the still-inline value run), **not** a data-
suppression flag: `0xa2`/`0xa4`/`0xa8` pages carry real data that decodes
cell-exact. **All-zero geographies** (an empty presence record) do occur — listed
for completeness with no data in this table — but that is a per-geography property
(the CSV publishes them as all-zero) and appears on both `0x8` and `0xa` pages,
sometimes right beside a data-rich geography on the same page.

## [ ] Other Beyond 20/20 products that share the signature but are undecoded

Several other `.ivt` products share the `04 00 20 00` signature and even expose a
page-directory-like structure, but their **header descriptor is a different,
undecoded layout**: `ivt_f2_descriptor()` reads a garbage dimension count
(hundreds/thousands) and recovers zero data dimensions. They are now **detected as
unsupported** (`ivt_family()` returns `NA`, `ivt_is_supported()` is `FALSE`) and
`read_ivt()`/`ivt_metadata()` abort with a clear message — previously they passed
the loose family-2 gate and crashed the decoder with `argument of length 0`. The
fix is the `ivt_f2_decodable()` check (plausible `n_dim`, ≥1 sized data dimension).
Regression-guarded in `tests/testthat/test-formats.R`.

Files in the test corpus that are currently unsupported:

- [~] **Profile tables** (`98F0172X`, `95F0170X`): **structure largely cracked, not
  yet wired.** 2-D Geography × Values; value order **characteristic-major,
  geography-minor**. For 98F0172X: 4,063 geographies decode exactly today
  (`ivt_f2_geo_inline()`); values confirmed exact vs the HTML profile-viewer ground
  truth (St. John's char 101 = 171,859); the **full page directory** is located
  (header `u16@558`=1936, 1,046 contiguous records tiling 100 % of the value
  region). Pages are a **hybrid**: dense `0x0_` (`[b0][01][count]`+values) and
  sparse `0x8_` (presence-bitmap + values + trailer, the container we already
  decode). Open: the grid is **non-rectangular** (Σcount=2,222,304 not a multiple of
  4063/529) — likely geography-level-dependent characteristic sets — plus the
  Values count/order from the type-`0x01` descriptor. See `unsupported-formats.md` §2.
- [ ] **Other "F"-series** (`97F0015XCB2001041`, `97F0020XCB2001070`): 2001-era
  crosstabs. `inline_geo` header flag varies; descriptor layout differs;
  `97F0020X` has no locatable page directory. Served by StatCan's legacy `www12`
  dynamic system, not the modern b2020 endpoint.
- [ ] **1981 census** (`97-570-X1981002`): older still; descriptor undecoded.
- [ ] **Custom CT / "cro"/"ord" extracts** (`cro0172986_ct.*-2006-*`,
  `ord-08035-…_ct.1-2021-population`): Beyond 20/20 desktop exports (not StatCan
  table downloads); single-page-ish directories, descriptor undecoded.

Decoding any of these is future work — each likely needs its descriptor/codebook
layout reverse-engineered. Reconnaissance (sub-format taxonomy, descriptor
locations, which share the family-2 value container) is captured in
[`unsupported-formats.md`](unsupported-formats.md). Summary: they fall into ≥3
sub-formats — a near-family-2 crosstab (`ord-08035`, `97F0020X`; `ord-08035`
reuses the 98-10-0023 value container exactly and is the recommended first
target), profile tables with a `"Values"` dimension (`98F0172X`, `95F0170X`; int
container we already decode), and older layouts whose container is not yet located
(`97F0015X`, 1981 `97-570-X`).

## [ ] Not parsed at all

- [ ] The **variable section-pointer table** (~header bytes 690–1080). Known to
  exist and to tag entries with a type byte (`16` = member/data block, `15` =
  notes), but its record grammar is undecoded. Not needed (everything is located
  from the fixed header + scanning), but it is the single unparsed structure.

## [ ] Unknown / possibly not in the binary

- [ ] **Footnote → member/dimension linkage.** The metadata CSV carries per-member
  Note IDs; we extract footnote *text* but not *which* footnote annotates which
  member. (The inline `01 01 … 00 01` markers we investigated are block framing,
  not note references, so it is unproven this linkage is stored inline at all.)
- [ ] **Member hierarchy as a structured tree** for family 2. Encoded via leading-
  space indentation in the labels (preserved verbatim) but not parsed into
  parent/child. Family 1 exposes `ivt_label_depth()`; family 2 does not yet.

## Summary

For the **reference tables** (family 1: 98-10-0241; 3-dim family 2: 98-10-0023;
legacy: 1003011), ~100 % of information-bearing bytes are identified and the data
plus all geography/dimension/footnote metadata decode exactly. The bit-level gaps
there, by size: (1) the **French label copies** (~half the codebook, recoverable,
just not surfaced); (2) the **section-pointer table grammar** (routed around); (3)
a few small header/marker bytes with inferred/unknown semantics; plus the
footnote↔member linkage and structured member hierarchy that may be absent from the
binary.

The family-2 decoder now handles **arbitrary-dimension** tables (validated on the
4-dim 98-10-0129, cell-exact) in addition to the 3-dim and legacy tables. The
remaining open item is the **2001/2006 "F"-series** products (97F0015X, 98F0172X),
not yet decoded — possibly an older B2020 variant; see the section above.
