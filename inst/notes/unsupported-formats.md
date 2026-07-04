# Unsupported `.ivt` formats — reverse-engineering reconnaissance

Files that share the `04 00 20 00` signature but decode under none of the
supported layouts. Detection is structural (`ivt_f2_decodable()` = descriptor +
layout + the page pre-flight) and these files fail it in **two distinct ways**:

- **descriptor-level**: the header descriptor is a different, undecoded layout
  (garbage dimension count, zero data dimensions recovered) — the §2/§3 files;
- **page-level**: descriptor *and* directory parse cleanly, but the pages are
  inconsistent with the resolved layout and the pre-flight **capacity / span /
  exact-fit rules** reject them (97F0020X) — these decode *wrong*, not *not at
  all*, so the structural rejection is what protects against silently
  misindexed cells. Two former members of this class turned out to be
  descriptor MISREADS, not different layouts, and are now SUPPORTED
  (2026-07-04): **97-570-X1981004** (the "Values" placeholder's count read 32
  instead of 1 — the double-01 framing ambiguity, now reconciled against the
  codebook; geography is the LAST descriptor dimension, resolved by
  `ivt_f2_geo_dim_index()`) and **98-400-X2016203** (descriptor type `0x0a`
  carries a u16 count: 825 Selected characteristics, not 57). Both
  viewer-validated cell-exact — a reminder that a pre-flight rejection can
  mean "the descriptor was misread", not only "the container is alien".

This note captures the reconnaissance so a future decode effort is resumable.
Current per-file status lives in [`coverage.md`](coverage.md); this doc carries
the deeper recon detail.

Test corpus location: `<ivt_cache>/<id>/<file>` (option `canivt.ivt_cache`).

**Not in scope**: the large 2016 `98-400-X` crosstabs (2016328, 2016261,
2016120) turned out to be ordinary supported-container tables (validated
viewer-exact, zero code changes) — the 2016 vintage is *mostly* supported;
only the variants below are not.

## Taxonomy (at least four distinct situations)

### 1. Crosstab, near-family-2 — most tractable

Same descriptor sub-header as the decoded tables
(`81 01 20 00  f0 ?? 00 80  <n_dim?> ...`).

- **`ord-08035-…_ct.1-2021-population` (2021 custom CT export)** — the best target.
  - Plain-text structure in the header: `Geography(751) × Tenure(4) ×
    Selected Characteristics(76)`, `[304 cells / geog]`, `[228,304 cells]`
    (= 751 × 304 ✓). Value container: 44 pages, markers `88`×6 / `a8`×37 / `a2`×1.
  - **Blocker A:** `@32` points at a `01 01 <u16 len>` *title* block, not the
    descriptor. The real descriptor sub-header is found by scanning (`@10417`),
    where `n_dim@+16 = 3` parses correctly.
  - **Blocker B:** dimension-record dialect differs (see below) — geography type
    `0x0a` here; count offset shifted; bounded by `FACET04`, but the `@32`
    mis-point is the issue.
  - **Blocker C:** 751 geographies / 44 pages is **not** uniform (≈17.07), so
    geos-per-page is non-uniform — the decoder's `geo_count / n_pages` assumption
    needs a per-page presence-section length instead.
  - **Blocker D (2026-06 hands-on):** the "reuses the 98-10-0023 container
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
    rather than presence-then-values).
- **`97F0020XCB2001070` (2001 F-series crosstab)** — `@32 = 17836` *does* point at
  the descriptor (`n_dim = 5`); records are
  `[lead][count u8/u16][type][01][doubled name]`, e.g. Geography type `0x04`
  count 14, then Income(2), Earning Status(8), … Characteristics(282). Bounded by
  **`FACET03`** (not `FACET04`). **Its page directory IS locatable** (superseding
  the earlier "no page directory" note): after the entry-floor fix, header
  `@558 = 18589` resolves a directory whose entries are in *reverse* offset
  order, all `84 01 00 08` pages of size 4756 that fit **exactly** under the b2
  trailer arithmetic. **But the pages carry 1124 presence bits against the
  layout's 448-real-cell capacity** — the data is nested differently from the
  power-of-two model the layout derives — so the pre-flight **capacity rule**
  rejects it. The open problem is the *nesting*, not the container location.
  Served by StatCan's legacy `www12` dynamic system, not the modern b2020
  endpoint.

### 2. Profile tables (`"Values"` dimension) — family-2 int container, geography-minor

Layout **cracked** (2026-06): these are 2-D **Geography × Values** profiles whose
value stream is **characteristic-major, geography-minor** — the transpose of the
geography-major model the current decoder assumes. Confirmed cell-exact against
HTML ground truth (the profile scraper, `/profiles/Rp-eng.cfm`).

- **`98F0172X`** (1991 "Profile of Census Tracts - Part B"):
  - **Geography**: 4,063, decoded **exactly** today by `ivt_f2_geo_inline()`
    (legacy inline `"name (GEOUID) flag"` codebook; member 3808 = "St. John's",
    3809 = "St. John's - 002", …). Header `@40`/`@48` titles set ⇒ inline route.
  - **Values dimension**: ~529 characteristics, each tagged by a StatCan line code
    (101, 102, 201, …, 3813) — read straight from the profile viewer rows.
  - **Descriptor** `@32 = 1511`: sub-header `81 01 20 00  f0 28 00 80`, then a
    doubled-name record `…01 01 "ValuesValues" 11 02 0a 01 "Profile of…"`. Values
    is **type `0x01`** (`01 01` also frames blocks, so a marker scan can't be
    trusted here). `n_dim@+16` reads garbage (770) — as elsewhere, the count
    field is unreliable and only the recovered records count.
  - **Value order**: **characteristic-major, geography-minor** — within a value run
    the values are a single characteristic across consecutive geographies in
    inline-codebook member order (verified: file offset 315512 →
    `171859, 5850, 4391, 3288, 1971, …` = char 101 for members 3808, 3809, 3810…
    = St. John's CMA then its CTs; cross-checked exact vs the scraped char-101
    values).
  - **Full page directory located**: at the header pointer `u16@558 = 1936`,
    **1,046 contiguous 8-byte records** `[u32 off][u16 size][u16 size]` whose
    offsets+sizes tile the value region **100 %** (103624 → 7,306,856;
    Σsizes = span, zero gaps). The old `off < 1e5` entry floor that hid part of
    it **has since been fixed package-wide** (floor is now 1024 — the
    98-400-X2016387 fix); the remaining directory blocker is only that
    `ivt_f2_is_marker()` accepts page byte0 ∈ {82,84,88,a2,a4,a8} and so
    rejects this file's `0x0_` dense pages.
  - **Two page families**, by the byte0 high nibble (low nibble = value width:
    2→int16, 4→int32, 8→float64):
    - **Dense `0x02/04/08`** (196+10+16 pages): header `[b0][01][count_u16]` then
      `count` values, no presence/trailer (payload = count × width exactly, e.g.
      `04 01 00 08` = int32 × 2048 = 8192-byte payload). St. John's page is `0x04`.
    - **Sparse `0x82/84/88`** (441+325+58 pages): the **same presence-bitmap +
      values + trailer framing as the geography-major container we already decode**
      (e.g. `84 01 40 08  bf ef f7 ff …` — the `bf ef f7…` is the presence bitmap).
  - **Blockers remaining for a full decode**: (a) accept the `0x0_` dense page
    markers in the directory validation **without regressing** the supported
    tables. (b) Decode the **hybrid** page set: dense `0x0_` pages give `count`
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
  the directory is under-detected (same `0x0_`-marker blocker as 98F0172X). Same
  profile family; decode once 98F0172X is solved.
- ~~**`97-570-X1981004`** (1981 Census Profile)~~ — **SUPPORTED** (2026-07-04),
  moved out of this doc. The "geography-last nesting" was an illusion: the
  descriptor's "Values" record is a 1-member placeholder whose count byte read
  32 (the double-01 framing ambiguity), and with the reconciled counts
  (`Values(1) × Profile(79) × Geography(5989)`) the ordinary unified layout
  fits the file exactly (geography — the LAST descriptor dimension, identified
  by `ivt_f2_geo_dim_index()` from its codebook — straddles the presence
  record; 3 windows; Profile paged at stride 4). Viewer-validated cell-exact;
  see coverage.md. **Implication for 98F0172X/95F0170X**: their descriptors
  now parse the same way (`Values(1) × Profile(529) × Geography(4063/5602)`,
  u16 counts under the `0x0a`/`0x0c` width tags) — their remaining blocker is
  ONLY the hybrid dense/sparse page set below, and the "non-rectangular"
  puzzle should be revisited knowing Values has ONE member, not ~529: the
  529-member dimension is the Profile characteristics axis, and 1981004's
  sibling layout (geography straddling, characteristics paged) suggests the
  1991 profiles may pattern the same way once the dense `0x0_` pages are
  admitted.

### 3. Container not located / descriptor undecoded

- **`97-563-XCB2006072`** (2006 census DA crosstab): **DECODED and SUPPORTED**
  (2026-07-03) — moved out of this doc. The directory was at the plain
  `u16@558 = 45641` all along (14,381 entries = ⌈57,523/4⌉ exactly); the
  validator rejected it only because this vintage's page markers carry
  `b3 = 0x0a/0x0c`, which turned out to encode a **`32·(b3−8)`-byte auxiliary
  head block** before the value run — the general rule behind the formerly
  hard-coded "+32 on `a2 01 03 09` pages". Its pages also append per-(geo, age)
  suppression-mask records after the value run (byte-exact reconstructible from
  the presence bitmap on 14,111 of 14,381 pages; the rest is writer
  slack/truncation). See ivt-format.md "The b3 head block and suppression
  tails" and coverage.md.
- **`97F0015XCB2001041`** (2001) and **`97-570-X1981002`** (1981 Census Profile):
  `n_dim@+16` is garbage (1282 / 35841), no dimension records parse, and no page
  directory is found. Different header + container; the least understood.
- **`98-400-X2016019`** (the older 2016-census `98-400-X` descriptor variant):
  descriptor misreads, rejected by `ivt_f2_decodable()`. (Its large siblings
  2016328/2016261/2016120 are the *supported* container — this variant is the
  exception, not the 2016 rule.)
- **Custom CT / "cro" extracts** (`cro0172986_ct.*-2006-*`): Beyond 20/20
  desktop exports; single-page-ish directories, descriptor undecoded.
  (`ord-08035` is the better-understood custom export — see §1.)

### 4. ~~`98-400-X2016203`~~ — SUPPORTED (2026-07-04)

Moved out of this doc. Both page-level anomalies were ONE descriptor bug:
type `0x0a` carries a **u16** member count, and the u8 read had taken the low
byte of "Selected Demographic, Cultural, Labour Force and Educational
Characteristics **(825)**" (= 57, `0x0339 → 0x39`), mis-nesting the whole
layout — the "non-exact `b2 == 0` fits" were an artifact of the wrong presence
geometry, and the `a2 01 03 0a` pages were already explained by the b3 head
rule. With the true count every page fits, the pre-flight passes, all 825
member labels read via the chunked label path
(`ivt_f2_dim_dir_label_chunks()`), and the decode is viewer-validated
cell-exact (39,516/39,516 multi-fixed + ~25k single-fixed cells; labels
825/825). See coverage.md.

## The dimension-record dialect (sub-format 1)

After the `81 01 20 00 f0 ?? 00 80 …` sub-header, each dimension is

    [lead byte][count: u8, or u16 when > 255][type][0x01][NAME NAME]

- The **name is stored twice** back-to-back (a robust delimiter: find two
  consecutive identical printable runs).
- **Geography type is `0x04`** in the 2001 F dialect and **`0x0a`** in the 2021
  custom-export dialect (vs `0x10` in the modern 2021 tables); data dims use
  `0x01`, `0x03`, `0x07`, ….
- Bounded by `FACET03` (2001) or `FACET04` (2021).

The modern parser `ivt_f2_descriptor()` misses dims here because (a) it trusts
`@32` (wrong for custom exports), (b) `type 0x01` needs care — `01 01` is also
block framing — and (c) the count offset differs. A dialect-aware parser should
locate the descriptor by scanning for the sub-header, then walk records by the
doubled-name delimiter.

## Decode path, by tractability

1. ~~**`97-563-XCB2006072`** (2006 DA crosstab)~~ — **DONE** (2026-07-03, the
   b3 head-block rule; see §3).
2. ~~**`97-570-X1981004`** (1981 profile)~~ and ~~**`98-400-X2016203`**~~ —
   **DONE** (2026-07-04: descriptor count reconciliation +
   `ivt_f2_geo_dim_index()`; the `0x0a` u16 width tag; see §2/§4).
3. **`98F0172X`** (profile): geography + values + the full 1,046-record
   directory + both page formats decoded; geographies and spot values confirmed
   exact vs HTML ground truth; the descriptor now parses correctly
   (`Values(1) × Profile(529) × Geography(4063)`). Remaining: accept `0x0_`
   markers, the hybrid dense/sparse assembly, and the **page → grid mapping**
   (revisit the "non-rectangular" Σcount puzzle knowing Values has 1 member
   and 1981004's sibling layout — geography straddling, characteristics
   paged). `95F0170X` is the same family.
4. **`ord-08035`** (2021 CT custom export): descriptor + directory decode, but
   the value-page body is a different (un-RE'd) encoding — needs the page body
   RE'd from scratch.
5. **`97F0020X`** (2001 F crosstab): container fully located, pages exact-fit —
   the open problem is its different presence **nesting** (1124 bits vs 448
   cells).
6. The rest (§3 descriptor-undecoded files) need their header/container located
   first.

## Status

Last full pass 2026-07-04 (aligned with coverage.md after the descriptor
count-reconciliation / geography-dimension-index / `0x0a`-`0x0c` u16 width
sweep, which moved `97-570-X1981004` and `98-400-X2016203` OUT of this doc).

- `98F0172X`/`95F0170X` (profile): geography, values, the full 1,046-record
  directory, and both page formats (dense `0x0_` / sparse `0x8_`) are decoded,
  geographies + spot values validate exact vs HTML ground truth, and the
  descriptor now parses (`Values(1) × Profile(529) × Geography`) — but the
  **page→grid mapping is unsolved**, so no cell decode yet (revisit knowing
  the 1981004 sibling layout: geography straddling, characteristics paged).
- `97F0020X` (2001 F crosstab): directory located and pages exact-fit under the
  b2 arithmetic, but the **presence nesting differs** (capacity-rule reject).
- `97-563-XCB2006072` (2006 DA crosstab): **SUPPORTED** as of 2026-07-03 (the
  `b3` head-block rule; directory was at the plain `u16@558`) — see §3.
- `97-570-X1981004` (1981 profile) and `98-400-X2016203`: **SUPPORTED** as of
  2026-07-04 (descriptor misreads, not alien layouts) — see §2/§4.
- `ord-08035` (CT custom export): descriptor + directory decode, but the
  **value-page body is a different (un-RE'd) encoding** — not a drop-in for the
  existing decoder.

All remaining files are rejected **structurally** by
`ivt_is_supported()` (descriptor gate or page pre-flight — no allow/deny
lists, no crashes). Each needs further dedicated reverse-engineering; the
profile family (`98F0172X`, grid mapping) is the closest to done.
