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
- **`97F0020XCB2001070` (2001 F-series crosstab)** — `@32 = 17836` *does* point at
  the descriptor (`n_dim = 5`); records are
  `[lead][count u8/u16][type][01][doubled name]`, e.g. Geography type `0x04`
  count 14, then Income(2), Earning Status(8), … Characteristics(282). Bounded by
  **`FACET03`** (not `FACET04`). **But `ivt_f2_find_directory()` finds no page
  directory** — its value-page container/location differs.

### 2. Profile tables (`"Values"` dimension) — family-2 int container

- **`98F0172X`** (2001): value container present — 68 pages, markers `82` int16 /
  `84` int32 (the 1991/1003011 int dialect). First dim is **`Values`** (a profile
  of 32 characteristics). `n_dim@+16` reads garbage (770), so the descriptor's
  dimension count lives at a different offset for this layout.
- **`95F0170X`** (1991 profile, "Census Divisions and Subdivisions - Part B"):
  legacy out-of-line titles (`@40`/`@48` set, like 1003011); marker `84` int32;
  `find_directory` returns only 1 page (likely under-detected — the directory
  anchor/scan needs adjusting for this layout).

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

1. **`ord-08035`** (2021 CT): same value container as 98-10-0023, so once the
   descriptor (3 dims) and a **per-page** geo count are read, the existing
   n-dimensional `ivt_f2_decode()` should apply. Validate cell totals against the
   header's `[228,304 cells]` and spot-check against CensusMapper (BC CSDs).
2. **`98F0172X`** (profile, int container): need the profile descriptor offset and
   the `Values`-dimension member list; value container is the `82`/`84` dialect we
   already decode.
3. The rest need their container located first.

## Status

Reconnaissance only — none decoded yet. They are correctly rejected (no crash).
Cracking them is future work; `ord-08035` is the recommended starting point.
