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
            [u32 dir_ptr][u32 alloc][u32 n_entries][u16 flag]; see dimdir.R) — the
            member-label blocks, ordinals, doubled-name marker and per-dimension
            footnotes are all read positionally from these
```

**The 14-byte slot record, field by field** (all four fields resolved except one
flag; the decoder reads `dir_ptr` + `n_entries`, and cross-checks with `alloc`):

- `[u32 dir_ptr]` (@+0) — pointer to the block directory, directly or (the big
  chunked-geography directories) via a one-`u32` indirection struct.
- `[u32 alloc]` (@+4) — the block directory's **power-of-two allocated slot
  capacity**: measured `== nextpow2(n_entries)` on **243/243 corpus slots**, zero
  mismatches (the same power-of-two allocation the format uses for the presence
  bitmap and directory strides). Formerly the `?` field. `ivt_f2_dim_dir()` now uses
  it to **validate `n_entries`**: a slot whose `alloc != nextpow2(n_entries)` is a
  misread and is rejected before the directory is read (guarded on a non-zero alloc
  so a future zero-alloc vintage abstains rather than veto a good slot).
- `[u32 n_entries]` (@+8) — the **used** block-directory entry count (the decoded
  table may run a few short when null slots are skipped; validates the read).
- `[u16 flag]` (@+12) — **partially understood**: `0` on 240/243 corpus slots,
  `1` on exactly the three double-indirection chunked-DGUID **geography**
  directories (98-10-0023 / -0129 / -0174, all 6,244–6,758 entries). It tracks the
  extra-indirection / chunked-directory layout. `ivt_f2_dim_dir()` now uses it to
  **direct** which indirection depth to try first (flag ≠ 0 → the `slot → struct →
  directory` indirection first; else the direct read first) — a metadata-driven
  choice replacing the old direct-first trial-and-error, so the big chunked
  geography's directory is located by the file's own flag. The precise semantic is
  still inferred from three same-valued cases, not proven, so the OTHER depth
  remains a fallback and every candidate is gated by the `n_entries` check — a
  mis-flag reorders attempts but cannot mis-read. This is the one residual fragment.

So the codebook, the notes and the legends are located **from the header**, with
the bounded tail scans surviving only as fallbacks for layouts whose directories
do not resolve.

**What the slot table gives, precisely — and what it does NOT.** The slot's
`dir_ptr` + `n_entries` locate a **block directory** of `n_entries` records
`[u32 off][u16 len][u16 len]`, and each record gives the **exact byte place
(`off`) and extent (`len`) of one codebook BLOCK**. That addressing is exact and
exhaustive: a dimension's codebook *is* exactly this enumerated set of blocks, and
`ivt_f2_dim_dir()` self-validates the read against `n_entries`. Two things it is
**not**:

- **`n_entries` is a BLOCK count, not a member count.** A dimension's members are
  packed *inside* one or two of its blocks (the English label array, the French
  label array — each a single directory entry holding all members), alongside many
  member-count-independent blocks: the field dictionary (`81 02 <nfields> 00`), the
  doubled-name marker (`81 02 02 00`), the ordinal array (`02 01 …`), `81 01 …` note
  blocks, a `84 01` member-note bitmap, `01 01` note-text blobs, and `04 01 …`
  id/reference separators. So there is **no relation** between `n_entries` and the
  member count: ucr2.2_3-2006 has Offence = **24 entries / 30 members**, Geography =
  **12 entries / 1 member**, Year = **4 entries / 1 member**. The member count comes
  from the **descriptor** (correct for ordinary dimensions), reconciled against the
  actual member *array* when the descriptor framing is ambiguous
  (`ivt_f2_dir_member_count()` counts the records inside the `01 01`/`81 01` block) —
  **never** from `n_entries`. Feeding `n_entries` in as the count mis-nests the
  layout (the first UCR attempt decoded 24 garbage cells against a 30-bit presence
  record).
- **A dimension's blocks are individually addressed, NOT a contiguous per-dimension
  region.** On a small table (UCR) each dimension's blocks happen to be contiguous
  and the dimensions' `[min off, max off+len)` envelopes are disjoint — but that is
  incidental. In general the blocks are non-adjacent and **interleaved across
  dimensions**: on 98-10-0241 the seven dimensions' envelopes overlap heavily, and
  on the chunked-DGUID tables (98-10-0023) the geography directory is split into
  non-adjacent regions (a reversed root chunk + the bulk) whose envelope *brackets*
  the small data dimensions' blocks. So "dimension k's codebook" is the exact **set**
  of its `n_entries` blocks — do not treat `[min off, max off+len)` as a byte range
  that belongs to one dimension, and do not assume blocks tile without gaps.

### Undecoded / unused pockets

What is **not** consumed or not fully understood (small; the bulk of the file is
fully decoded):

- **Header zero-padding** (bytes ~3,182..35,949, ~32 KB of `00`). Reserved/fixed
  alignment before the page directory; carries no observed information.
- **The doubled directory size field.** Each 8-byte directory record stores the page
  byte-length **twice** (`[u32 off][u16 size][u16 size]`, the two `size`s identical).
  The size is the page's **allocated** length and upper-bounds its content: on every
  page of every supported table `4 + presence + trailer + head + n_values*width <=
  size`, with **equality** on the trailer-less `b2 == 0x00` pages whose `b3 <= 0x09`
  (the `b3 >= 0x0a` suppression-tail pages append mask records after the run — see
  "The b3 head block and suppression tails" below). The decoder enforces the bound
  per page (`canivt_page_overrun`), so a misread marker aborts rather than
  decoding garbage values. In the **codebook block directories** the second field
  is likewise the block's allocation and is usually equal to the content length,
  but some exports store it **larger**: the 1991 profiles round it up to a 4-byte
  boundary (`len2 = 4·ceil(len/4)`), and the 2006 custom-order crosstabs
  (`cro0172986_ct.7/8`) store an outright larger capacity (content 3024 →
  allocation 3078, 367 → 903). `ivt_f2_read_dir_at()` uses `len2 == len ||
  len2 == 4·ceil(len/4)` as its default end-of-table sentinel (a stricter rule
  that random trailing bytes rarely satisfy) and only admits any `len2 >= len` in
  its bounded `relaxed` mode (`ivt_f2_dim_dir()`, capped to the slot's declared
  entry count). The content length is always the first field.
- **Per-page header bytes.** The page marker is `[b0] 01 [b2] [b3]` with the value-
  width in `b0`'s low nibble and `b3 ∈ {08..0e}` (a ZERO high nibble in `b0`
  is the dense variant — bytes 3–4 are then a u16 value count, see "Dense pages"
  below); **`b2` encodes the trailer**:
  `b2 == 0x00` means "no trailer", otherwise
  `trailer = 2·(b2 >> 4) + 2·(low nibble(b2) > 0)` bytes; **`b3` encodes an
  auxiliary head block** of `32·(b3 − 8)` bytes between the trailer and the value
  run (see below). The b2 formula is derived from 98-10-0013, whose 22
  pages carry 18 distinct `b2` values (`0x2a`..`0x63`, trailers 6–14, each
  anchored byte-exact against the StatCan CSV); on the tables where `b2` never
  varies it reproduces the historical per-marker constants. What the trailing
  2-byte field (low-nibble flag) holds is unknown (`00 e0` on 0013's first
  page).
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

## The cell-status block (page tail)

**A page may carry a trailing block AFTER the value run that states, per cell,
why the cell is absent.** This is where StatCan's `x` (suppressed for
confidentiality) and `...` (not available) live.

The block's *start* is not stored anywhere: it is implied, at
`4 + presence_len + trailer(b2) + 32·(b3 − 8) + popcount·width`, and it runs to
the directory entry's u16 size. Its *kind* is declared by the page marker's `b0`
**high nibble**, and — in the wide form — by a self-describing header at the
block's own start. Nothing about it appears in the file header.

**Both forms are decoded** (`R/status.R`, `read_ivt(missing = TRUE)`): the `0x8`
1-bit mask, and the `0xa` reason-code array at its validated `W = 2` width. Both
are stored the same way — a sparse array of value-width words addressed by an
index bitmap occupying the whole pre-value region — and reading the `0xa` array
without that rebuild is what made its addressing look lineage-specific for so
long. What remains open is only the code *vocabulary* at `W = 1/4/8`.

### `b0` high nibble `0x8` — the bare absent mask (1 bit per cell)

No descriptor.

**Storage: a SPARSE array of `width`-byte words, addressed by an index bitmap
that occupies the WHOLE pre-value region.** That region is the `b2` trailer plus
the `32·(b3 − 8)` head — so `b3` is in effect an index-size code, since a page
needs a bigger index exactly when it has more words to address. The index is
read in the container's usual convention (byte-pair-swapped, MSB-first), one bit
per word of the reconstructed block, ascending; all-zero words are simply not
written, and the index's trailing bytes are zero when fewer words are needed.
Writing the selected words back to their indexed positions rebuilds the block —
of which the first `rec_bytes` are the mask.

    index = page bytes [4 + rec_bytes, 4 + rec_bytes + trailer + head)
    word k of the block is written  <=>  index bit k is set
    INVARIANT:  popcount(index) * width == tail length

That invariant is the gate, and it holds on **20,322 of 20,322 tail-bearing
pages** as first measured standalone — and, re-measured through the decoder over
every directory entry, on **1,810,626 of 1,810,626 mask pages of the 170-table
corpus, with 0 unreadable**. Sizing the index as the
`rec_bytes / (8·width)` words a full mask needs — the obvious reading — truncates
it on every page that also carries the second block (below) and drops 6 tables.

The mask bytes are **not** pair-swapped (the one bitmap in the container that
is not), are read MSB-first, and are addressed at the **padded presence-grid
bit** — the same `lay$grid$bit` the presence record uses, decisively over the
alternative of packing by real-cell ordinal. The `b3 ≥ 0x0a` 2006-vintage
"run-length" tail described further below is not a separate encoding: it is this
same sparse word array, which is why only its popcount was comparable before the
index was understood.

**It is a strict SUBSET of the absent cells, and the subset is the point.**

    masked absent    ⇒ genuine zero          (published `0`)
    UNMASKED absent  ⇒ missing / not available (published `N`)

Where a table has no missing values the two sets coincide and the mask reads as
the complement of the presence bitmap — which is why it long looked redundant.
Measured on all 87,630 pages of the three CMHC 2016 custom crosstabs: mask ==
complement, **0 unflagged absent cells**, and `4 + rec_bytes + trailer +
popcount·width + tail == size` byte-exact on every page. The B20/20-browser CSVs
of those same tables publish numeric zeros and no missing values — the
"masked ⇒ zero" half, confirmed against an authoritative rendering.

The other half is proven on **97F0020XCB2001070** (2001, economic families by
income) against the Beyond 20/20 web viewer, on a table whose layout is
`counts 14,2,8,282,2`, `ipc 2,282,2`, `straddle 3`, `wc 4`, 1128 cells/page:

- the viewer's absent cells split into 474 published `0` and **26 published `N`**;
  all 7,396 present cells are value-exact;
- in the file, `absent − popcount(tail)` is **exactly 4 on all 104 pages of
  geographies 1–13 and exactly 0 on all 8 pages of geography 14**, never negative;
- 4 = 2 `N` per earning member × the 2 earning members a page carries — confirmed
  by scraping each member separately (2 non-numeric each, at member rows 36 and 46);
- geography 14 (Nunavut) publishes `0` at those *same* coordinates and its pages
  have gap 0. The signal is **data-dependent**, so it can only come from the file;
- geographies 1, 6, 7, 10, 11 carry marker `84 01 00 08` — no head, no tail at
  all — and their only absent cells in the slice are exactly the 2 `N` cells,
  with zero published zeros. **No tail ⇒ nothing is a zero.**

Decoded incidence over the whole 170-table corpus (`fixtures/status-ledger.csv`,
one row per table: 105 carry mask pages, 47 carry `0xa` status pages, 36 write
no tail at all). **43 tables report missing cells, 622,290,283 in all**; the
*beyond* column — cells the page's word index has no bit for, the only real gap
(below) — is **0 everywhere**. The ten largest:

| table | missing | form | of which *beyond* |
|---|---:|---|---:|
| `98100393` | 231,789,142 | array | 0 |
| `98100529` | 174,477,266 | array | 0 |
| `98100526` | 57,168,574 | array | 0 |
| `98100456` | 36,700,820 | array | 0 |
| `98100357` | 36,459,978 | array | 0 |
| `98100274` | 25,003,760 | array | 0 |
| `98100241` | 21,110,192 | array | 0 |
| `98100174` | 11,816,700 | array | 0 |
| `98-400-X2016261` | 10,256,400 | array | 0 |
| `98100231` | 6,827,404 | array | 0 |

The scale is the point: these are sparse NDM crosstabs whose grid is mostly
`...` not available, and every one of those cells used to read as a published
zero. The eight mask-only tables are far smaller — `97F0015X` 2,080,404,
`SP3_AVQOPM_97F0007XCB2001042` 1,586,079, `SP3_H7WG5V_EDDTAB16` 5,276,
`97-563-XCB2006072` 1,485, `SP3_GPVU3L_00060210` 517, `97F0020XCB2001070` 344,
`SP3_NIQKF5_95f0487xcb01003` 220, `SP3_GPVU3L_00060208` 8.

The remaining 127 tables — CMHC T1/T2/T3, 98-312-XCB2011033, 98100045/66/179/662,
and the rest — report exactly **0** missing cells: mask == presence complement,
which is the "no missings published" case.

97F0020's 344 with **0 beyond** is the viewer-validated table, and it reproduces
the earlier popcount measurement exactly: 4 per page on each of the 86 pages of
geographies 1–13 that carry a tail, 0 on all 8 Nunavut pages, and the 18 no-tail
pages of geographies 1/6/7/10/11 contribute nothing.

**A mask that stops short of the grid is making a statement.** The sparse index
drops all-zero words, so the written mask routinely covers fewer words than the
page's cells span. That is not truncation: the index is sized by the marker, and
on **1,810,626 / 1,810,626** corpus mask pages `trailer + head` holds at least as
many bits as the grid spans words. The writer therefore had a bit for every mask
word and left the unwritten ones clear — an explicit "no genuine zeros here", so
every absent cell those words cover is missing.

    index words = 8·(trailer + head)      >=  ceil((max grid bit + 1) / (8·width))
    unwritten word INSIDE that span  =>  the word is all-zero  =>  those absent cells are MISSING
    word with no index bit at all    =>  unclassifiable        =>  reported `beyond`, warned

`covered_bits` is the second boundary, `min(index words, mask words)`, and the
corpus has nothing past it. `97F0015X` was the case that looked like an artefact:
93 % of its missings sat past the last *written* word, and its per-page unmasked
count is a pure function of how many words were written (`unm = 18·(42 −
mask_words)`, whole multiples of 108 = its two innermost dimensions 12 × 9). That
relation is a tautology of "the writer stops at the last flagged cell", not
evidence of a length bug — see "The mask says it, and the arithmetic agrees"
in [`decode-history.md`](decode-history.md) for the arithmetic that settles it.

Two limits remain, each reported by the decoder rather than hidden:

- **The x87 signalling-NaN artefact.** On float64 (`width = 8`) pages a mask word
  of mostly-ones is NaN-shaped, and the writer's x87 load/store quiets it by
  forcing the top mantissa bit (LSB bit 51) to 1 — destroying one status bit per
  affected word **in the source file**. Not recoverable: that cell reads as
  masked (a genuine zero) when it may have been missing. The evidence is an
  absence: **0** signalling NaNs survive in 63,582 `width = 8` mask words,
  against 374 of 94,893 (5.9% of the NaN-shaped ones) on `width = 4`, where no
  such quieting applies. Raw proof, 97-555 entry 66
  word 16: mask `ff ff 3f fb f3 ff ff ff` against `NOT(presence)` = `ff ff 3f fb
  f3 ff f7 ff` — identical but for byte 6. Counted as `nan_words`
  (`canivt_status_nan_quieted`; a source-side loss, so strict mode leaves it a
  warning).
- **A masked word may be one bit short of the truth, and only there.** Outside
  the NaN-shaped words the mask never contradicts the presence record.

The **`SP3_AVQOPM_97F0007XCB2001042`** discrepancy recorded here earlier — the
popcount running 8–10 per geography under the viewer's `N` count on 11 of 12
sampled geographies — was the *popcount* era's measurement, taken before the
index was understood and therefore blind to the dropped all-zero words. The
decoded mask now answers with 1,586,079 missings and the table's own arithmetic
backs it: over 3,053,547 sex-Total coordinates whose absent cells are all masked,
`Total − (Male + Female)` has median 0 and mean −0.2, while the 44,799
coordinates with cells reported missing fall short by a median of 25 (30 where
both sexes are missing, `frac > 0` = 1.000).

Across the corpus the mask never contradicts the presence record outside those
NaN-shaped words: **0 contradictory pages** in 1,810,626.

This form is **universal across every vintage** in the corpus (1981 and 1991
profiles, 1996/2001/2006 census, 2011/2016, Borealis surveys, 2021).

### The second tail block (OPEN)

On **8 corpus tables** the page's word index addresses words *past* the mask's
`rec_bytes`, i.e. the same index also addresses a further array:
`97-555-XCB2006058` (11,463 words), `SP3_AVQOPM_97F0007XCB2001042` (6,877),
`97F0015X` (3,113), `97-563-XCB2006072` (1,567), `SP3_APKNWC_100801` (47),
`SP3_BJFWAP_95F0377XCB01005` (10), `pid59227` (805), `95f0491xcb01004` (3).
Only on `b3 = 0x0c` pages (the 128-byte index) — coherent, since a page needs
the biggest index exactly when it has extra words to address. The array starts
at the padded `rec_bytes` boundary (97-555 entry 123 sets index bits 0–39 then
64–76, an explicit gap).

What is known:

- Its entries are **packed flag words, not data**. The value vocabulary is
  identical across tables and across value widths: `0x3333`, `0x1111`, `0x33FF`,
  `0x33F3`, `0x3033`, all-ones. Every nibble is drawn from {0,1,3,7,b,f}. On the
  float64 table they are written as genuine doubles holding those integers
  (1,051/1,051 finite and integral), so the writer stores them as numbers in the
  page's own value type.
- It is **not** the `0xa` array: no `[form][02][W]` descriptor at its start.
- It is **not a per-cell code array** under any tested encoding. All 16
  combinations of `W ∈ {2,4}` bits per code × MSB/LSB-first × plain/pair-swapped
  bytes × padded-grid-bit/real-cell addressing were swept against the structural
  requirement that a code be `0` wherever a value is present. Best result 3/400
  pages; `97F0007` scores 0/107 on every variant.
- Its **size correlates with nothing** per-cell: against `nvf`, cell count,
  present, absent, masked, unmasked and the real straddle width, r ≈ 0.05–0.21
  and no exact match.

The decoder counts these words (`extra_words`) and warns
(`canivt_status_extra_block`); it never reads them. Cracking it likely needs
external ground truth on one of the eight tables — the structural tests are
exhausted.

### `b0` high nibble `0xa` — the self-describing status array

**Rebuild the sparse block first** (the index above) — everything below is read
off the reconstructed block, never off the raw tail bytes.

The block opens with a 3-byte header and a 2-byte array intro:

    [form:u8] [0x02] [W:u8] ...        W = BITS PER CELL, one of 01 / 02 / 04 / 08

    form 0x01 (plain):            01 02 W        01 W    code array at byte 5
    form 0x02 (count-prefixed):   02 02 W <u16>  01 W    code array at byte 7

The intro is `[01][W]` — it repeats the width, which is what makes it a usable
gate. (Reading it as a literal `01 02` is what long hid the `W = 4/8/1` pages:
they open `01 02 04 01 04`, and a page whose intro says `02` while its header
says `04` is not a page at all.)

Codes are `W` bits wide, **MSB-first and NOT pair-swapped** (the mask
convention, not the presence one), addressed at the **same padded
presence-grid bit** as the presence record — `lay$grid$bit`.

`W = 2` is by far the most common. Its code values are **validated against
StatCan's own published tables**:

| code | meaning | filler byte |
|------|---------|-------------|
| `0` | cell carries a value, or is a genuine zero | `0x00` |
| `1` | filler — grid position outside the real cartesian | `0x55` |
| `2` | **`x` — suppressed for confidentiality** | |
| `3` | **`...` — not available** | |

Counting `W = 2` codes over the whole block and comparing with the `Symbol`
columns of `getFullTableDownloadCSV`:

| table | IVT code 2 / code 3 | published `x` / `...` |
|---|---|---|
| 98-10-0040 | 10 / 49 | 10 / 49 |
| 98-10-0655 | 0 / 2,600 | 0 / 2,600 |
| 98-10-0658 | 0 / 1,348 | 0 / 1,348 |
| 98-10-0128 | 389,888 / 1,466,488 | 389,888 / 1,466,488 |
| 98-10-0023 | 913,992 / 0 | 913,992 / 0 |
| 98-10-0129 | 1,485,120 / 0 | 1,485,120 / 0 |
| 98-10-0478 | 6,853 / 0 | 6,853 / 0 |

Exact on both codes on all seven, including 1.86M flagged cells. **Positionally**,
indexing the array at the presence-bitmap cell index on 98-10-0655 reproduces the
published symbols over all 11,154 cells with zero errors; 98-10-0040 joins 59/59
with nothing unmatched in either direction.

Three further structural checks, all corpus-wide over the 1,273,173 `0xa` pages
of the 170-table ledger, and none of which uses any external ground truth:

- the length gate `popcount(index)·width == tail length` passes on
  **1,273,173 / 1,273,173** pages;
- a cell that **carries a value** has code `0` on every page, at every `W`;
- code `1` falls **exactly** on the grid positions the decoder drops as padding
  — 166,965,381 cells, zero off-diagonal in either direction. The padding set
  comes from descriptor and slot geometry alone and the codes come from tail
  bytes alone, so this is two independent derivations of the same set.

### This overturns "an absent cell is a zero"

It is not. On 98-10-0655, cross-tabulating the presence bit against the status
code against what StatCan publishes:

| presence bit | status code | published |
|---|---|---|
| present | 0 | a real non-zero value (4,904) |
| **absent** | **0** | **`0.0` — a genuine zero (3,650)** |
| **absent** | **3** | **`...` — not available (2,600)** |

Absence is the union of two different things, and **the status block is the only
thing that tells them apart**. This is true in *both* forms and in every vintage:
a `0x8` page's mask says the same thing more crudely (masked ⇒ zero, unmasked ⇒
missing) and a `0xa` page's array adds the reason code. There is no vintage for
which "absent ⇒ zero" is safe a priori — only tables that happen to publish no
missings, where the mask coincides with the presence complement.

Whole-geography suppression (`metadata$geographies$has_data`) remains correct; it
is a coarsening of the per-cell signal, and stays the right answer for a
geography with no stored cells at all.

### The three "incompatible packings" were one bug

The addressing was long thought to be per-lineage, and three packings were on
record: 98-10-0655/0658 at the padded presence-grid cell index, 98-10-0040
"packing tighter" (a 24-byte geography stride = 96 codes against a padded 128),
98-10-0128 in per-member sub-blocks shaped
`[8 codes][48 filler][variable data][48 filler]` with a page-varying data
length. All three were the **same rule read without the sparse rebuild**: the
dropped all-zero words shift everything after them, and each table's typical
zero-run length produced its own apparent packing. Rebuild the block and one
rule covers the corpus. 92,790 of the corpus's `0xa` pages do drop an interior
word.

### What is still open (`W` other than 2)

The **addressing** is now general — present ⇒ code 0 and code 1 ⇒ padding hold
at every width — but only the `W = 2` **vocabulary** is validated, so nothing
else is interpreted (`canivt_status_block_undecoded`; 173,286 pages over 16 of
the 170 ledger tables):

- `W = 4` (`01 02 04 01 04`, filler byte `0x11`): 98-400-X2016203 (171,499
  pages), the `SP3_WLOGGX_000402xx` pair, `SP_BXW0XU_optab12`,
  `SP3_A2FD0W_02560006` and part of `ord-08035_ct1_2021` / `SP_U649IE_optab13`.
- `W = 8` and `W = 1`, count-prefixed, in the `SP3_RHUXA9_*` survey lineage and
  parts of 98-10-0013 / 98-10-0002 / 98-10-0010.

Two facts say the wider vocabularies are genuinely different rather than the
same one in a wider field: codes **above 3** occur (2,106,327 absent cells), and
code 1 lands on **real** cells (68,850) at `W = 1` and on two of the `W = 4`
tables — so `1` is not simply "filler" there. Cracking them needs published
ground truth for one of those tables.

Form incidence, from the earlier 171-**file** marker scan (a different sample
from the 170-table ledger): 33 carry `W = 2` status arrays — the 2021
NDM `9810xxxx` census tables, 2016 `98-400-X` crosstabs, and a couple of 2021
custom extracts. **No 1981/1991/1996/2001/2006 file has one.** Business Patterns
(`CBP*`) and the type-00 sub-A cluster carry no tail at all.

## The b3 head block and run-length absent tails (2006 vintage; b3 ≥ 0x0a)

The marker's fourth byte `b3` encodes an **auxiliary head block** of
`32·(b3 − 8)` bytes between the (b2-encoded) trailer and the dense value run:

    value run start = 4 + presence_len + trailer(b2) + 32·(b3 − 8)

`b3 = 0x08` (no head) and `0x09` (32 bytes) are the modern values — every `0xa2`
page in the corpus is `a2 01 03 09`, which is where the formerly hard-coded
"+32 on 0xa2 pages" constant came from; the head, not the marker family, owns
those 32 bytes. The **2006 census vintage** (97-563-XCB2006072, the first
decoded table of its kind) uses `b3 = 0x0a` (64-byte head) and `0x0c` (128-byte
head) on plain `0x82`/`0x84` `b2 == 0x00` pages. Verified against the page-size
equation on all 14,381 of its pages (byte-exact tail reconstruction on 14,111;
the rest carry writer slack/truncation, below). The head's *content* is
per-geography records (wholly-suppressed geographies carry `EE EE / E0 00`
sentinel words; published ones a small value + `E0 00`), semantics unproven —
the decoder skips it.

Pages with `b3 ≥ 0x0a` also append a **suppression tail** AFTER the value run.
This was originally read as a bespoke run-length coding — one mask field per
(geography, outer-data-dimension member) with ≥ 1 missing cell, in ascending
(geo, member) order, each field the missing-cell mask over the inner dimensions
in presence-nesting order (97-563: 9 `Presence of income` nibbles, each the sex
mask with Total/Male/Female at bits 3/2/1, so a wholly-missing slice is nine
`0xE` nibbles, `ee ee ee ee e0`), split into value-width units with all-zero
units dropped. **That reading is superseded**: it is the same sparse
index-addressed word array as every other `0x8` tail (§"the bare absent mask"),
and what looked like "fields with dropped units" is simply the index skipping
all-zero words. The `b3` head IS the index. The two descriptions agree on the
bytes; the general one also says *where* each word goes, which the run-length
reading could not. On 14,111 of 14,381 pages the reconstruction is byte-exact
from the presence bitmap alone — on **this** table nearly every cell absent from
the presence bitmap is flagged (the decoder now reports 1,485 unflagged, 405 of
them beyond the written mask), so here the tail is close to a complete
absent-cell inventory, and the published-value semantics hold for it: the store
keeps only non-zero cells and an absent cell renders `0` in the b2020 viewer
(validated on 97-563: 3,487/3,487 stored cells viewer-exact and all 833
absent sampled cells render 0, over 32 geographies — Canada through deep-tail
member 57,523, 20 of them random, including wholly-empty ones — the 2006
tabulations zero-fill area-suppressed small areas, so a suppression zero and
a true zero are indistinguishable in the published table; the per-geography
`has_data` signal remains the recoverable suppression marker). What used to look
like "benign writer artifacts" on the remaining pages — stale bytes beyond the
true tail, truncated tails, dropped all-`0xE` record groups — is accounted for
by the index: the length invariant `popcount(index)·width == tail length` holds
on **all 14,381** of the table's pages. The *value* decode still keys **only** on
the presence bitmap and the head size (values = the `popcount` ints/floats at the
head-adjusted start; `b2 == 0` exact-fit is asserted only for `b3 ≤ 0x09`); the
tail is read separately and only on `read_ivt(missing = TRUE)`, so it can never
affect a value.

98-400-X2016203's `a2 01 03 0a` pages are this same layout; its formerly
"non-exact `b2 == 0` pages" were an artifact of the u8-misread Selected
characteristics count (825 read as 57) mis-nesting the presence geometry —
with the u16 width tag the table is SUPPORTED and viewer-validated cell-exact
(2026-07-04).

## Dense pages (1991 profile exports; marker high nibble 0x0)

The 1991 profile tables (98F0172X "Profile of Census Tracts - Part B",
95F0170X "Census Divisions and Subdivisions - Part B") mix the sparse pages
above with a **dense variant** whose marker high nibble is `0x0` (`0x02`/`0x04`/
`0x08`, low nibble still the value width):

    [b0][01][u16 count]  then  count × width bytes of values

No presence record, no trailer, no head: one value per **in-page grid position
in grid order**, with absent/zero cells stored as **literal zeros**. `count`
covers at least the full window (2048 positions on these tables) and may run
past it as zero padding (observed 2048/2080/2112/2176; every extra value is 0,
as are the last window's positions past the geography count). Every dense page
fits its directory entry EXACTLY (`4 + count·width == size`), which is the
pre-flight rule for the variant (`ivt_page_preflight()`); the whole-marker test
(`ivt_f2_is_marker()`) accepts `[02|04|08] 01` with a positive count, since
bytes 3–4 are the count, not `b2`/`b3`.

These tables are otherwise the ordinary unified layout — `Values(1) ×
Profile(529) × Geography` with geography LAST (the profile lineage,
cf. 97-570-X1981004) and straddling the presence record: 98F0172X = 2 windows
of 2048 over 4,063 geographies → exactly 529 × 2 = 1,058 directory entries;
95F0170X = 3 windows over 5,602 → 529 × 3 with the directory walk identical.
The historical "non-rectangular Σcount" puzzle was an artifact of a truncated
directory read (the `0x0_` markers were rejected, so `ivt_idx0()` fell back to
the wrong base) plus the pre-fix inline-geography member order. The sparse
pages of these files are the standard container (`82 01 80 08`, `84 01 40 08`,
`88 01 00|20 08`; the `b2 == 0` ones exact-fit). Viewer-validated cell-exact
on both files (22 and 20 geographies × all 529 characteristics, incl. every
window boundary, Canada/deep-tail members, and the Ottawa-Hull block the
viewer's dropdown re-sorts — join viewer ground truth by NAME).

## Geography index

- Per-geography page directories start at `IVT_IDX0 = 37167`, stride
  `0x1000` (4096 bytes; a property of this table — strides are computed
  per file from the descriptor, see `ivt_layout()`). Directory `n` (0-based) is metadata
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

**The stride padding is DECLARED, not derived (2026-07-23).** Every dimension's
slot directory carries a member-code block `81 02 <alloc-u16> 16 00` (or, for
the survey generations' reference-period dimensions, the time-series member
table `81 02 <alloc-u16> 08 00`) whose leading u16 is the dimension's allocated
member-slot capacity. The presence-bit nesting and the page-directory entry
strides both pad each level to this **declared allocation**
(`ivt_f2_dim_slot_alloc()` → `ivt_layout()`); it equals `nextpow2(count)` on
almost every table — which is why the derived-`nextpow2` model decoded the
corpus — but can exceed it (LFHR Table-023's Hours: 32 slots for 10 members,
whose windows-of-4 occupy 8 directory slots — the once-mysterious
"doubled-window directory"). On chunked >1024-member dimensions the u16 is a
block-local allocation (1024) smaller than the member count; the layout then
falls back to `nextpow2(extent)`, exact for those layouts. The block's
mid-section (between the u16 and the tail Pascal member codes) is still
undecoded and likely carries per-slot flags (cf. markers.md §E.1).

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
  `2*ceil(nbits/16)` bytes (u16-padded) and is **not** a per-member presence map
  (unlike the `[84 01]` footnote bitmap): measured on 98-10-0662's dense arrays,
  `nbits` far exceeds the member count and the popcount equals the records-region
  byte length + 1 — it is a per-**byte** map of the packed records region. So it
  cannot supply member positions. Absent members are **skipped** in the record
  run, so the values are re-aligned using the empty-slot pattern of a plain
  sibling block from the same chunk.

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

**A second framing coexists across vintages**: `FOOTNOTE:<text>` /
`RENVOI :<text>` — all-caps, colon-terminated, **no number**. It is the 1981
profile's only footnote form, and it turns out to also carry real notes on the
1996/2006/2011/2016 tables that the numbered scan had silently missed (e.g.
98-400-X2016328's four commuting notes, the 2006 DA table's total-income
definition, twelve immigrant-status notes on 95F0223XDB96001).
`ivt_footnote_texts()` accepts both markers (case-sensitively, so the two
shapes cannot cross-match); numbering remains the caller's job.

### Chunked member-label blocks (data dimensions > 256 members)

A data dimension with more than 256 members stores its label blocks **chunked
exactly like the chunked geography codebook**: 256-member chunks in growing
groups of `G` chunks (`ivt_f2_geo_group_sizes()`: 1, 1, 2, 4, …), each group
laid down as its `G` English chunk blocks then its `G` French blocks, in slot-
directory order after the dimension's doubled-name marker; a trailing partial
chunk can be a **dense** `81 01` block (the strict parser handles both).
`ivt_f2_dim_dir_label_chunks()` (dimdir.R) assembles the runs, consuming a
candidate entry only when its record count equals the next expected chunk size
(interleaved framing blocks are skipped structurally). First instance:
98-400-X2016203's "Selected characteristics (825)" — groups 1/1/2, runs of
256 + 256 + 256 + 57 per language, all 825 EN labels exact against the B2020
viewer's row list.

### Identity via the master directory

The modern tables carry an inline `Product ID: … Title: …` text and the legacy
exports out-of-line title blocks at header `@40`/`@48`. The 1981 profile has
**neither** (both pointers zero) but stores the same `01 01 <u16 len>`-framed
`"<product_id>\r\n<title>"` blobs as **master-directory entries** (EN and FR).
`ivt_f2_master_identity()` (read-f2.R) reads them when both other sources come
up empty — this also fills the previously-NA identity on the 1996 and 2016
`98-400-X` tables.

## The older `02 00 20 00` survey-generation container

Every table discussed so far starts with the 4-byte signature `04 00 20 00`. A
second, older Beyond 20/20 container generation shares the last three bytes but
starts with `02 00 20 00` — byte 0 is a **container-generation tag** (`04`
modern census/custom, `02` an older split-definition survey product line), not
part of a fixed 4-byte constant. `ivt_family()` accepts byte 0 ∈ `{2, 4}`.
Corpus examples: Health Statistics at a Glance 1999 (the `00060xxx` series), the
1996 Census of Agriculture (`EDDTAB39`), and the 1996 Small Area Business survey
(`EMPLOY1`).

Everything **downstream of the signature is the same model** — page directory at
`@558` (low 16 bits, unwrapped the same way), pages framed as
`marker(4) + 256-byte presence + sparse values` with the same width nibble
(`2/4/8` = int16/int32/float64), and the same codebook region at the tail. Three
things differ, all confined to how the **descriptor** and **codebook** are read:

1. **No `FACET04` title block**, so the modern descriptor walk (which bounds
   itself on that title) cannot locate the end of the dimension records, and the
   generation's own quirks — a `04`-byte-separated "ANNUAL" time dimension, and
   `<display><description>` name pairs that are doubled and space-padded rather
   than exactly repeated — defeat the doubled-name walk outright. `byte 0 ==
   0x02` files therefore skip the descriptor block entirely: `ivt_f2_descriptor_02()`
   **rebuilds the descriptor from the per-dimension codebook** located by the
   header's own slot table (`@824 + 14·(k−1)`, the same slot table every
   generation uses). Each dimension's count comes from its member CODE array
   (`81 02 <alloc> 00 16 00`, `alloc = nextpow2(count)`) or label array; its name
   from the `81 02 02 00 56 00` bilingual name marker, falling back to a named
   schema field (`81 02 <n> 00 22 00`) then the descriptor's doubled reference
   name. A reference/time dimension with **no member array at all** (see below)
   is sized by probing which small candidate count makes the value-page layout
   validate (`ivt_page_preflight()`); this probe is the one part of the
   generation's read that still warns loudly (`canivt_descriptor_02_probe`) if
   it cannot disambiguate.
2. **No geography dimension.** By design, this generation's `REGION`/`GEOGRAPHY`
   dimension carries no geographic identifiers (no DGUID/GEOUID schema field, no
   inline `"name (code)"` pattern) — it is province/territory-level prose, not a
   StatCan geography. `ivt_f2_geo_dim_index()` structurally returns `0` for these
   files, so the dimension stays an ordinary, fully-labelled data dimension:
   `metadata$geographies` is empty and `cells` carries no `geo` column.
3. **The time-series member table** (`markers.md` §E.1) is how a reference
   dimension can exist with **neither a code array nor a label array**: a block
   framed `81 02 <alloc> 00 08 00` holding `alloc` one-byte member-**slot** flags
   (byte-pair-swapped, like every presence bitmap in this format — non-zero =
   populated slot) followed by one 3-byte little-endian **date** per populated
   slot, right-aligned at the block end. The epoch is **days since 0000-03-01**
   (the classic proleptic-Gregorian computational epoch); every observed date
   lands on 1 January of its year for an annual series, so member labels are
   *generated* from the dates rather than read as text. Deleted members leave
   **holes** in the slot numbering (one corpus table's three surviving periods
   sit at slots 1, 2 and 4) — the presence bitmap and page directory address
   members **by slot**, not by a dense 1..count range, so the layout carries a
   `dims[[k]]$slots` vector and `ivt_layout()`/`ivt_f2_cell_grid()`/`ivt_decode()`
   map slot positions back to member ids wherever it is present (a value landing
   on a hole warns `canivt_slot_hole` — it would indicate a mis-derived slot
   map, not a data-quality issue).

One more property of this generation is worth stating because it looks at first
like a missing decimal scale: **the stored values are complete integers, not a
fixed-point encoding**. The `b2` marker byte that looked like a candidate
"decimals" tag is (as everywhere else) only the value-width/trailer code, and a
byte-diff of same-shaped facet codebooks turns up nothing but member-count
bytes — there is no decimals byte anywhere in the container. Each facet member's
own `_Description` text states the unit the integer is already in (e.g. a total
fertility rate is stored as "children per 1,000 women", so `3840` means 3.84 per
woman) — `ivt_members()` surfaces that text as `description`/`description_fr`
when it can be mapped to a member unambiguously. No scale warning is emitted;
`read_ivt()` returns the raw integers unchanged.

## Validation

`tests/testthat/test-decode.R` checks (against the StatCan CSV/known values):
166 geographies, all DGUIDs present, dimension member counts `166,9,16,13,3,6,7`,
7,489,464 decoded cells, and Canada's published tenure totals
`14687350, 9787420, 5870875, 3916550, 4899925, 576625, 4323300`. The pure-R
decode of the whole file takes ~4–5 s.

## The 1991 census variant (E9101 / `1003011.IVT`)

The **1991 census** Beyond 20/20 format is the same container *family* as 2021.
Reference table here is **E9101** (`1003011.IVT`, 26 MB) — "Population by Single
Years of Age (110), Showing Sex (3)". 3 dimensions: Geography(41,859, incl.
enumeration areas) × Age(110) × Sex(3) = 330 cells per geography.

**Fully decoded** — `read_ivt()` reads it through the same shared path as every
other vintage, and it is one of the six cell-exact reference tables. This section
is kept as the byte-level record of *how* the variant differs; the section
headings below are historical, and the one marked "not yet cracked" was solved in
place (see the note in it). The findings were established by direct analysis
against scraped per-geography ground truth (Canada + provinces, GIDs
1,2,3,9,10,11,13,14 — see the sibling `censusmapper-import` repo).

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

#### Inline combined-block format variants

The inline geography "combined block" packs the member's name, code and (usually)
a data-quality flag into one string, but the field ORDER differs by vintage. Two
patterns cover the corpus, tried in order by `ivt_f2_parse_inline()`:

- **Flag-trailing** (`IVT_F2_INLINE_PAT`), the common form — `"<name> (<code>)
  [<type_abbr>] <flag>"` (1991/2006/2011) and its comma variant `"<name>
  (<code>), <type_abbr> <flag>"` (a few unorganised CSDs, plus the 2016 tables'
  trailing ` (<pct>%)` non-response rate). The code sits in the FIRST parentheses,
  the numeric flag last.
- **Code-trailing** (`IVT_F2_INLINE_PAT2`) — `"<name>[, <type_abbr>] (<code>)"`
  with **no flag**, the code in the LAST parentheses (the 2006 custom-order
  crosstabs `cro0172986_ct.7/8`: `"East Kootenay, RD (5901)"`, `"Elkford, DM
  (5901003)"`; the name keeps its `, <type>` suffix as StatCan displays it).
  Tried only after the flag-trailing form, so the older vintages are unaffected.

The block is read **positionally** from the geography dimension's slot directory
(`ivt_f2_geo_inline_dir()`), which lays down, per 256-member chunk, several runs:
two combined runs (English then French — often near-identical, only province-level
names translate) plus separate code / type / ordinal arrays. Both combined runs
are parsed, giving `geo_name` (English, chosen by `ivt_f2_frscore()`) and
`geo_name_fr`; the bare-code run supplies the `geouid`. Low-level geographies with
no name (a code-only member) simply carry the code as the name — expected.

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

Two refinements (2026-07, the profile-lineage / 2016203 unlock):

- **Count width is tagged by the type byte**: `0x10`, `0x0d`, `0x0a` and `0x0c`
  carry a **u16** count, everything else a u8. The last two were found on the
  profile lineage (98F0172X's Profile(529) `11 02 0a 01`, Geography(4063)
  `df 0f 0c 01`) — and reading `0x0a` as u8 was exactly what had broken
  98-400-X2016203: its "Selected characteristics" dimension is **825** members
  (`0x0339`); the u8 read took the low byte (57), mis-nested the whole layout,
  and made its `b2 == 0` pages look non-exact-fit. With the true count the
  file is an ordinary supported container (viewer-validated cell-exact).
- **Double-01 records are ambiguous and get reconciled against the codebook**
  (`ivt_f2_dim_count_reconcile()`, dimdir.R). The reference-period record is
  `[type][count][01][01]<name>` ("Year (2)": `0e 02 01 01`), but the profile
  lineage's 1-member "Values" placeholder shares the byte shape
  (`00 20 01 01 ValuesValues`) while its count is NOT at that position — the
  naive read produced 32. For every double-01-framed record, the dimension's
  own slot-directory member block decides: the descriptor count can never
  exceed the block's stored slot count (slots only pad upward to the next
  power of two), so a larger count is replaced by the block's real (last
  non-empty) member count. Counts the codebook cannot contradict are left
  untouched — every previously validated table is byte-identical through this.

#### The geography dimension is not always dimension 1 (`ivt_f2_geo_dim_index()`)

Geography is the FIRST descriptor dimension in every layout **except the
profile-table lineage** (97-570-X1981004, 98F0172X, 95F0170X), which stores a
1-member "Values" placeholder first and **geography LAST**:
`Values(1) × Profile(79) × Geography(5989)` on the 1981 profile. The
identification stays metadata-driven (`ivt_f2_geo_dim_index()`, dimdir.R):
dimension 1 is accepted outright unless its count is 1 (a real geography can
never be a 1-member dimension alongside others); then each dimension's slot
directory is probed for a **geography codebook signature** — the geography
attribute schema (a dictionary block naming `GEO_NAME`, modern DGUID tables) or
inline combined-format member blocks (`"<name> (<code>) <flag>"`,
`IVT_F2_INLINE_PAT`) — and the matching dimension takes the geography role
(slug/labels/codebook anchoring). Nothing else changes: the cell decode is
dimension-agnostic, and "geography-last" needs **no new nesting** — with the
reconciled counts the ordinary unified layout describes the 1981 profile
exactly (geography straddles the presence record, 3 windows of 2048 bits;
Profile directory-paged at stride 4; Values(1) the trivial outermost entry
dimension; the directory's period-4 valid/invalid entry pattern is the
pow-2-padded window count). Viewer-validated: all 5,989 geography members in
order, 1,264/1,264 sampled cells exact (incl. the 2048/2049 and 4096/4097
window boundaries and member 5,989), absent cells render 0.

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

### Sparse-geo cell presence (solved: pair-swapped positional)
Sparse geographies (every province that has *any* zero cell — i.e. most of them,
GIDs 9/10/11/13/14 — and all enumeration areas) store **only their nonzero cells**
(verified: GID9 = 279/330, GID11 = 222/330, GID10 = 55/330, each found as an exact
contiguous int16 run), so reconstructing the 330-cell grid needs to know *which*
cells are present.

Presence is **positional after all** — the records are **byte-pair-swapped**, the
same rule as 98100023 below. Each geo gets a 64-byte record (consecutive in the
page's presence section, ages at byte positions {0..53,55}, marker `0xE`). Swap
adjacent bytes (`B0↔B1, B2↔B3, …`), then read positional nibble-per-age with Sex
bits `Total/Male/Female = 3/2/1`, `0` = absent. Verified against the 8 scraped
GIDs: GID13/14 exact; GID9/10/11 (records at 314297/314361/314425, 64 bytes apart)
exact except the very last age (idx 109) — an off-by-one because 1991's odd
byte-55 data byte lands in byte 54 *after* the swap (do the `{0..53,55}`
byte-position mapping AFTER swapping). With that, every geo decodes.

*The dead end, kept as the record:* this was first framed as "the encoding is
**not** a verbatim positional bitmap", because an exhaustive search matched no
sparse geo's known present-pattern under contiguous nibble-per-age (any bit
assignment, hi/lo nibble order, age-pair swap), the 64-byte interspersed-pad
layout learned from the dense blocks, tight 3-bit-per-age packing, or
nibble-padded packing. Every one of those searches read the bytes **unswapped**;
the model was right and the byte order was wrong.

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
  `b0` ∈ `{0x82,0x84,0x88,0xa2,0xa4,0xa8}` and `b3` ∈ `{0x08,0x09,0x0a,0x0c}`. The
  marker's **low nibble is the value-width code** (exactly the per-table type marker
  that had to exist): `0x8` → 8-byte **float64**, `0x4` → int32, `0x2` → **int16**
  (the int pages are base-5 random-rounded counts). 98100023 uses `88` (float64),
  `a8` (float64) and `a2` (int16).
- **Page layout.** `[4-byte marker][256-byte presence section][0xFF trailer][head
  block][dense value run]`. The presence section is 4 × 64-byte records (one per
  geo, in value order). The trailer is **encoded in the marker's `b2` byte** and
  the auxiliary head block **in its `b3` byte**
  (`ivt_value_trailer()`, decode.R): trailer = `b2 == 0x00` → none; otherwise
  `2·(b2 >> 4) + 2·(low nibble(b2) > 0)` bytes; head = `32·(b3 − 8)` bytes (see
  "The b3 head block and suppression tails" above). This reproduces the six
  historically constant pairs (`88/20/08`→4, `a8/41/08`→10, `84/40/08`→8,
  `82/80/08`→16, `a4/82/08`→18, `a2/03/09`→2+32=34 —
  which had made the trailer look like a per-width constant) and the 18 varying
  `b2` values of 98-10-0013 (each anchored byte-exact vs the StatCan CSV); an
  unrecognised width code, high nibble or b3 aborts (`canivt_unknown_marker`)
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
