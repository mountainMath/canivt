# Unsupported `.ivt` formats — reverse-engineering reconnaissance

Files that share the `04 00 20 00` signature but are **not** one of the two
decoded container families. They are currently detected as unsupported
(`ivt_f2_decodable()` is `FALSE`: their header descriptor reads a garbage
dimension count and yields zero data dimensions). This note captures the
structural reconnaissance so a future decode effort is resumable.

Test corpus location: `<ivt_cache>/<id>/<file>` (option `canivt.ivt_cache`).

## Taxonomy (at least three distinct sub-formats)

### 1. Crosstab, near-family-2 — most tractable

Same descriptor sub-header as the decoded tables
(`81 01 20 00  f0 ?? 00 80  <n_dim?> ...`) and, for `ord-08035`, the **same
value container** as 98-10-0023 (page markers `88`/`a8` float64, `a2` int16).

- **`ord-08035-…_ct.1-2021-population` (2021 custom CT export)** — the best target.
  - Plain-text structure in the header: `Geography(751) × Tenure(4) ×
    Selected Characteristics(76)`, `[304 cells / geog]`, `[228,304 cells]`
    (= 751 × 304 ✓). Value container: 44 pages, markers `88`×6 / `a8`×37 / `a2`×1.
  - **Blocker A:** `@32` points at a `01 01 <u16 len>` *title* block, not the
    descriptor. The real descriptor sub-header is found by scanning (`@10417`),
    where `n_dim@+16 = 3` parses correctly.
  - **Blocker B:** dimension-record dialect differs (see below) — geography type
    `0x04` not `0x10`; count offset shifted; bounded by `FACET04` here but the
    `@32` mis-point is the issue.
  - **Blocker C:** 751 geographies / 44 pages is **not** uniform (≈17.07), so
    geos-per-page is non-uniform — the decoder's `geo_count / n_pages` assumption
    needs a per-page presence-section length instead.
  - **Blocker D (NEW, 2026-06 hands-on):** the "reuses the 98-10-0023 container
    exactly" assumption does **not** hold on inspection. The descriptor parses
    cleanly (`81 01 20 00 f0 20 00 80`, `n_dim@+8 = n_dim@+16 = 3`, dims in order
    **Geography(0x0a) · Characteristics · Tenure**) and the full directory reads
    (44 records). But the value **pages do not contain a recognisable float64
    value run**: page 1 (`a8 01 81 08`, 8214 B) is `ee ee …`-style presence bytes
    at the head and a long uniform `11 11 11 …` run at the tail, with **no**
    plausible population float64 anywhere, and the page-size equation
    `4 + 64·G + trailer + width·Σpopcount == size` has **no integer solution** for
    any G on any page (0/44). So the per-geography record size (assumed 64 B from
    `nextpow2(76·4)=512`) and/or the value encoding differ from 98-10-0023; the
    container is **not** a drop-in. Decoding needs the page body re-RE'd from
    scratch (the `ee`/`11` byte patterns suggest the whole page may be bit-packed
    rather than presence-then-values). Geography type here is `0x0a`, not the `0x04`
    the earlier note guessed.
- **`97F0020XCB2001070` (2001 F-series crosstab)** — `@32 = 17836` *does* point at
  the descriptor (`n_dim = 5`); records are
  `[lead][count u8/u16][type][01][doubled name]`, e.g. Geography type `0x04`
  count 14, then Income(2), Earning Status(8), … Characteristics(282). Bounded by
  **`FACET03`** (not `FACET04`). **But `ivt_f2_find_directory()` finds no page
  directory** — its value-page container/location differs.

### 2. Profile tables (`"Values"` dimension) — family-2 int container

Layout **cracked** (2026-06): these are 2-D **Geography × Values** profiles whose
value stream is **characteristic-major, geography-minor** — the transpose of the
geography-major model the current decoder assumes. Confirmed cell-exact against
HTML ground truth (the new profile scraper, `/profiles/Rp-eng.cfm`).

- **`98F0172X`** (1991 "Profile of Census Tracts - Part B"):
  - **Geography**: 4,063, decoded **exactly** today by `ivt_f2_geo_inline()`
    (legacy inline `"name (GEOUID) flag"` codebook; member 3808 = "St. John's",
    3809 = "St. John's - 002", …). Header `@40`/`@48` titles set ⇒ inline route.
  - **Values dimension**: ~529 characteristics, each tagged by a StatCan line code
    (101, 102, 201, …, 3813) — read straight from the profile viewer rows.
  - **Descriptor** `@32 = 1511`: sub-header `81 01 20 00  f0 28 00 80`, then a
    doubled-name record `…01 01 "ValuesValues" 11 02 0a 01 "Profile of…"`. Values
    is **type `0x01`** (not in `IVT_F2_DESC_TYPES`; `01 01` also frames blocks, so
    the modern marker scan can't be trusted here). `n_dim@+16` reads garbage (770).
  - **Value order**: **characteristic-major, geography-minor** — within a value run
    the values are a single characteristic across consecutive geographies in
    inline-codebook member order (verified: file offset 315512 →
    `171859, 5850, 4391, 3288, 1971, …` = char 101 for members 3808, 3809, 3810…
    = St. John's CMA then its CTs; cross-checked exact vs the scraped char-101
    values).
  - **Full page directory located** (2026-06): it is at the header pointer
    `u16@558 = 1936` and has **1,046 contiguous 8-byte records**
    `[u32 off][u16 size][u16 size]` whose offsets+sizes tile the value region
    **100 %** (103624 → 7,306,856; Σsizes = span, zero gaps). The current
    `ivt_f2_find_directory()` finds only 68 because (a) the hard-coded `off < 1e5`
    floor rejects the next valid record and (b) `ivt_f2_is_marker()` only accepts
    page byte0 ∈ {82,84,88,a2,a4,a8} and so rejects this file's `0x0_` pages.
  - **Two page families**, by the byte0 high nibble (low nibble = value width:
    2→int16, 4→int32, 8→float64):
    - **Dense `0x02/04/08`** (196+10+16 pages): header `[b0][01][count_u16]` then
      `count` values, no presence/trailer (payload = count × width exactly, e.g.
      `04 01 00 08` = int32 × 2048 = 8192-byte payload). St. John's page is `0x04`.
    - **Sparse `0x82/84/88`** (441+325+58 pages): the **same presence-bitmap +
      values + trailer framing as the geography-major container we already decode**
      (e.g. `84 01 40 08  bf ef f7 ff …` — the `bf ef f7…` is the presence bitmap).
  - **Blockers remaining for a full decode**: (a) generalise the directory reader
    to the full 1,046-record table (drop the `1e5` floor; accept `0x0_` page
    byte0) **without regressing** the geography-major tables that the shared finder
    serves. (b) Decode the **hybrid** page set: dense `0x0_` pages give `count`
    values directly; sparse `0x8_` pages need the presence-bitmap path. (c) Recover
    the **page → (characteristic, geo-range) mapping**: page headers carry no
    coordinate, so the assignment is implicit in page (offset) order. **The grid is
    not a clean rectangle**: Σ(count over all 1,046 pages) = **2,222,304**, which is
    **not** divisible by 4063 (=546.96) nor by 529 — so it is not a simple
    characteristic-major × 4063-geography array. The likely cause is a
    geography-level-dependent characteristic set (e.g. CMA-level vs CT-level
    geographies carry different profiles), or per-group sub-blocks; this
    non-rectangular grouping is the main unknown left. (The flat all-dense
    reconstruction also conflates the sparse `0x8_` pages, whose `count` is the
    cell total, not the stored-value count.)
- **`95F0170X`** (1991 profile, "Census Divisions and Subdivisions - Part B"):
  legacy out-of-line titles (`@40`/`@48` set, like 1003011); marker `84` int32;
  `find_directory` returns only 1 page (under-detected — same directory-scan
  blocker as 98F0172X). Same profile family; decode once 98F0172X is solved.

### 3. Older / other — container not located

- **`97F0015XCB2001041`** (2001) and **`97-570-X1981002`** (1981 Census Profile):
  `n_dim@+16` is garbage (1282 / 35841), no dimension records parse, and
  `find_directory` finds no page directory. Different header + container; the
  least understood.

## The dimension-record dialect (sub-format 1)

After the `81 01 20 00 f0 ?? 00 80 …` sub-header, each dimension is

    [lead byte][count: u8, or u16 when > 255][type][0x01][NAME NAME]

- The **name is stored twice** back-to-back (a robust delimiter: find two
  consecutive identical printable runs).
- **Geography type is `0x04`** in the F/custom dialect (vs `0x10` in the modern
  2021 tables); data dims use `0x01`, `0x03`, `0x07`, ….
- Bounded by `FACET03` (2001) or `FACET04` (2021).

The modern parser `ivt_f2_descriptor()` misses dims here because (a) it trusts
`@32` (wrong for custom exports), (b) `type 0x01` is not in its marker type set
(and adding it is unsafe — `01 01` is also block framing), and (c) the count
offset differs. A dialect-aware parser should locate the descriptor by scanning
for the sub-header, then walk records by the doubled-name delimiter.

## Decode path, by tractability

1. **`98F0172X`** (profile): geography + values + full 1,046-record directory +
   both page formats decoded; geographies and spot values confirmed exact vs HTML
   ground truth. Remaining: the **non-rectangular page → grid mapping** (Σcount not
   a clean multiple of the geography count) and the hybrid dense/sparse assembly.
   `95F0170X` is the same family. (Closest to a decode, but the grouping is unsolved.)
2. **`ord-08035`** (2021 CT): descriptor + directory decode, **but the value pages
   are not the 98-10-0023 container** after all (no float64 value run; page-size
   equation unsolved on every page — see Blocker D). Needs the page body RE'd from
   scratch.
3. The rest need their container located first.

## Status

**Hands-on hex analysis (2026-06) revised the earlier optimistic recon downward**:
both "tractable" targets are harder than the strings-level survey implied.

- `98F0172X`/`95F0170X` (profile): geography, values, the full 1,046-record
  directory, and both page formats (dense `0x0_` / sparse `0x8_`) are decoded, and
  geographies + spot values validate exact vs HTML ground truth — but the
  **page→grid mapping is non-rectangular and unsolved**, so no cell decode yet.
- `ord-08035` (CT): descriptor + directory decode, but the **value-page body is a
  different (un-RE'd) encoding** — not a drop-in for the existing decoder.

No new decoder is wired; doing so would be either incorrect or risk regressing the
shared directory finder. All files remain correctly rejected by
`ivt_is_supported()` (no crash). These each need further dedicated reverse-
engineering; the profile family (`98F0172X`) is the closest to done.
