# CLAUDE.md — canivt

**canivt** downloads and parses StatCan *Beyond 20/20* `.ivt` tables
into tidy data / Parquet / CSV, plus their metadata (dimension members,
geographic identifiers/DGUIDs, footnotes).

**Parsing must be driven by metadata and markers found in the file
itself.** External ground truth (2021 CSVs, the web viewer) is for
*validation only* — never a hidden hard-coded parsing path. Parsers must
generalize to files the test suite has not seen, and warn loudly on
every fallback.

## Companion docs (`inst/notes/`)

| doc | role |
|----|----|
| [`ivt-format.md`](https://mountainmath.github.io/canivt/inst/notes/ivt-format.md) | authoritative byte-format reference. **Read before changing the parser.** (User-facing copy: `vignettes/ivt-format.Rmd`.) |
| [`markers.md`](https://mountainmath.github.io/canivt/inst/notes/markers.md) | terse byte-marker catalog. Self-checked by `test-markers.R`. **Update in the same commit as the recognizer.** |
| [`code-map.md`](https://mountainmath.github.io/canivt/inst/notes/code-map.md) | what every file in `R/` does, in full. **Read the relevant row before editing a file.** |
| [`coverage.md`](https://mountainmath.github.io/canivt/inst/notes/coverage.md) | living completeness tracker + measured byte coverage. **Update when a gap opens or closes.** |
| [`decode-history.md`](https://mountainmath.github.io/canivt/inst/notes/decode-history.md) | narrative changelog: how each table was cracked, per-table validation records, invariant derivations. Consult for the *why*. |
| [`testing.md`](https://mountainmath.github.io/canivt/inst/notes/testing.md) | dev workflow: sample files, the three corpus ledgers, the parallel suite. |
| [`unsupported-formats.md`](https://mountainmath.github.io/canivt/inst/notes/unsupported-formats.md) | the UNSUPPORTED ledger: what the gate refuses and why. |
| [`refactor-plan.md`](https://mountainmath.github.io/canivt/inst/notes/refactor-plan.md) | consolidation backlog (open items only). |
| [`onboarding-backlog.md`](https://mountainmath.github.io/canivt/inst/notes/onboarding-backlog.md) | the repeatable per-table onboarding recipe. |

## What works today

**Every `.ivt` in the corpus decodes**, and **the refusal ledger is
empty** (2026-07-26) — all 170 rows `supported = TRUE`, with no gate
relaxed to get there. One descriptor-driven, name/type-agnostic decoder
(`decode.R`) plus one shared metadata path (`ivt_f2_metadata()`) handle
every vintage: 1981–2021 census and profiles, 2001/2006 F-series, 2016
`98-400-X` crosstabs, custom cro/ord extracts, Canadian Business
Patterns, and the `02 00 20 00` survey generation (byte 0 == `0x02`;
**no geography dimension** — `ivt_f2_geo_dim_index()` returns 0, no
`geo` column). Whole-file pure-R decode of the 7.5 M-cell reference
table: ~3 s (~6.5 s completed to its 39.2 M published rows). Per-table
validation records: `decode-history.md`; what is and isn’t decoded:
`coverage.md`.

The historical “family 1 / family 2” split is **not two formats** — it
is one power-of-two-nested positional layout differing only in *which*
dimension straddles the 2048-bit page boundary.
[`read_ivt()`](https://mountainmath.github.io/canivt/reference/read_ivt.md)
auto-detects via `ivt_family()`; `family` only tags provenance and gates
`geo_attributes`.

Key semantics:

- **[`read_ivt()`](https://mountainmath.github.io/canivt/reference/read_ivt.md)
  returns the PUBLISHED TABLE, not the store** (`complete = TRUE` by
  default): one row per real grid coordinate, published zeros written
  out, flagged cells carrying `value = NA` + `symbol`/`status` factors.
  The rule is derived from the file’s own bytes — *absent ⇒ published
  zero unless the page’s cell-status block says otherwise* — never from
  a published CSV. A page whose tail cannot be read publishes its
  absences as zeros **and counts them** (`canivt_absent_unclassified`).
  `complete = FALSE` restores the store-only output; completion is
  refused above `getOption("canivt.max_cells", 1e8)` grid cells.
- **The store keeps only non-zero cells**, so an absent cell is *either*
  a zero or a missing value, and the page’s **cell-status block** is the
  only thing separating them. **“Absent ⇒ zero” is FALSE in every
  vintage**; it merely looks true on tables that publish no missings.
- **The cell-status tail IS decoded**, opt-in:
  `read_ivt(missing = TRUE)` → `x$missing`. Both forms (`0x8` 1-bit
  absent mask, `0xa` reason-code array) come from one storage rule, and
  **what the codes MEAN is declared by the FILE** — header slot `@698`
  holds the table’s own status legend (`ivt_f2_status_legend()`); seven
  distinct, mutually offset legends over the corpus, so a fixed table
  mislabels most of it. A code the legend does not name is counted,
  never translated. See `status.R` in `code-map.md`, and
  `ivt-format.md`, “The cell-status block”.
- **Geography metadata is on the DEFAULT path**: `metadata$geographies`
  packs every decoded per-member column (bilingual labels, `geo_uid`,
  level/type, geocodes, `dqf_code`, `tnr_short_form`; all-NA columns
  dropped). `read_ivt(geo_attributes = TRUE)` adds the full attribute
  table for large chunked tables (~30 s block scan).

## Code map (`R/`) — full detail in [`code-map.md`](https://mountainmath.github.io/canivt/inst/notes/code-map.md)

| file | one line |
|----|----|
| `utils-bytes.R` | low-level readers; **all offsets 0-based** |
| `fallback.R` | `ivt_fallback()` — every heuristic raises a classed `canivt_fallback`; `canivt.strict` upgrades to error; `ivt_quietly()` for probes |
| `container.R` | page-directory anchor `ivt_idx0()` (`u16@558`) |
| `decode.R` | **the unified cell decoder**: `ivt_layout()` + `ivt_decode()`, plus `ivt_dir_outer_count()` (the container count witness) |
| `container-f2.R` | page-directory finder + the page-marker byte model |
| `decode-f2.R` | presence-bitmap primitives; the grid carries its bit addressing precomputed |
| `status.R` | the page cell-status tail + the `@698` reason-code legend |
| `complete.R` | the published table: grid fold, code → `symbol`/`status` factors |
| `dimdir.R` | bilingual labels, dimension names, the `@824` header slot table, count reconcile |
| `codebook-f2.R` | the unified codebook: geography dispatcher + specializer chain, slot/time declarations, slugs |
| `read-f2.R` | unified metadata + tidy, dimensions, footnotes |
| `suba.R` | the type-00 sub-A Business-Patterns module (reconciliation-gated, PROVISIONAL labels) |
| `read.R` | public [`read_ivt()`](https://mountainmath.github.io/canivt/reference/read_ivt.md) / [`ivt_metadata()`](https://mountainmath.github.io/canivt/reference/ivt_metadata.md) / [`ivt_tidy()`](https://mountainmath.github.io/canivt/reference/ivt_tidy.md), family detector + support gate |
| `stream.R` | chunked conversion — the published grid written a slice at a time |
| `collect.R` | [`ivt_members()`](https://mountainmath.github.io/canivt/reference/ivt_members.md) / [`collect_ivt()`](https://mountainmath.github.io/canivt/reference/collect_ivt.md) factor levels + the `_missing` sidecar resolver |
| `write.R` | `ivt_write_parquet()/_csv()/_metadata()`; CSV gzipped by default; label indentation → hierarchy |
| `get.R` | [`get_statcan_ivt()`](https://mountainmath.github.io/canivt/reference/get_statcan_ivt.md) — resolve → download → decode → cache Parquet → Arrow connection |
| `ground-truth.R` | internal B20/20 viewer scraper for validation fixtures |

## Key invariants (don’t regress)

The *rules*; the measurements and original bugs behind them are in
[`decode-history.md`](https://mountainmath.github.io/canivt/inst/notes/decode-history.md)
(“Invariant derivations”) and
[`coverage.md`](https://mountainmath.github.io/canivt/inst/notes/coverage.md).

### Geometry

- **There is ONE decode pattern** (`decode.R`) — nest every dimension
  power-of-two-positionally, data dims innermost (descriptor order, last
  fastest), geography outermost. Each page carries a fixed **2048-bit
  (256-byte) presence record**; the same nesting describes the in-page
  bits **and** the 8-byte directory entries. **Exactly one dimension
  straddles** the 2048-bit boundary: its in-page part
  (`ipc = floor(2048/inner_block)`) stays in the bitmap, the rest
  becomes `window_count = ceil(count/ipc)` directory-paged windows. The
  “family” is just *which* dimension straddles
  (`ivt_layout()$geo_in_page`). The walk never asks which dimension is
  geography.
- **All nesting geometry — presence-bit AND directory strides — pads
  each dimension to its DECLARED slot allocation**
  (`ivt_f2_dim_slot_alloc()`), falling back to `nextpow2(extent)` only
  when the declaration cannot hold the members.
- Presence bytes are **pair-swapped** (`bitwXor(i, 1)`) and read
  **MSB-first**; the value stream is **not** swapped.
- **Value run start** = `4 + presence_len + trailer(b2) + 32·(b3 − 8)`
  (`ivt_value_trailer()`). Unknown markers **abort**
  (`canivt_unknown_marker`); valid entries pointing at them are skipped
  loudly (`canivt_skipped_pages`). Every page is extent-checked against
  its directory entry’s u16 size, with **equality only when `b2 == 0`
  and `b3 == 08`** (`canivt_page_overrun`). Decoding stays
  presence-authoritative, so a tail never affects it.
- **The pre-value region is not padding — it is the tail’s INDEX**
  (`status.R`): the whole `trailer + head` span is a bitmap, one bit per
  value-width word of the trailing cell-status block. Gate
  `popcount(index)·width == tail length`. Read only under
  `missing = TRUE`; it can never move a value.
- The marker’s **low nibble is the value-width code** (`0x8`→float64,
  `0x4`→int32, `0x2`→int16); the high nibble selects the page’s trailing
  cell-status block (`0x8` bare mask, `0xa` reason-code array — `0xa`
  **is** a suppression-bearing flag). A **zero high nibble is the DENSE
  page variant** (1991 profiles): bytes 3–4 are a u16 value COUNT, exact
  fit `4 + count·width == size` (`ivt_decode_page_dense()`).
- Directory entries are in **geography member-id order**; geos-per-page
  is **computed** (`geo_count / n_pages`), never assumed. Member id
  columns in `cells` are **1-based** (match StatCan Member IDs), as is
  the CSV ground truth’s `Coordinate`.
- The header dir pointer **`@558` stores only the LOW 16 BITS** —
  `ivt_idx0()` unwraps it. The page-directory entry floor is **1024**.

### Slots, counts and sparse directories

- **The bitmap addresses members by SLOT, and slots can have holes.** A
  dimension declares them in either its `81 02 <alloc> 16 00`
  mid-section (`ivt_f2_dim_slot_table()`, 22-bit per-slot records —
  markers.md §E.1a) or the `81 02 <alloc> 08 00` time-series table
  (`ivt_f2_time_members()`, §E.1) — never both.
  `ivt_f2_dim_slot_declared()` adopts the declared count and slot
  positions **quietly** (a declaration is not a fallback), gated on the
  codes it predicts consuming the member-code array byte-exactly
  (`codes_ok`); `ivt_f2_dim_time_declared()` supplies the same from the
  time table, gated on every populated slot resolving to a plausible
  date. `ivt_f2_dim_slot_expand()` is only the fallback where no table
  parses. Extents drive the geometry, `ivt_f2_cell_grid(pos=)` maps bits
  to slots, and a value at a deleted slot warns `canivt_slot_hole`.
- **The declared slot map also addresses the CODEBOOK member arrays**,
  not only the presence bitmap: a label array may be written one record
  per allocated slot, so an interior hole defeats the trailing-NA trim.
  `ivt_f2_dir_member_arrays(slots=)` accepts `v[slots]` only when
  `which(!is.na(v))` is *exactly* the declared slots.
- **`ivt_f2_descriptor_impl()`’s `descriptor_from_slots` early return
  reconciles too** — skipping `ivt_f2_dim_count_reconcile()` drops
  `$slots` for any dimension whose `16 00` block declares live slots
  above 1.
- **Four count witnesses, in order.** (1) the descriptor record — but
  **double-01 records are ambiguous** (`[type][count][01][01]` is shared
  by the reference-period record and the profile “Values” placeholder),
  and a count of exactly **256 from a REBUILT descriptor is a chunk
  cap**, re-found by name via `ivt_f2_desc_declared_count()` (markers.md
  §D.1, raises only, `canivt_declared_count`). (2) the **declared
  allocation**: `alloc > 4·nextpow2(count)` means the descriptor was
  under-read, and the codebook member array’s own LENGTH is adopted when
  it lies between the two (`canivt_underdeclared_count`). (3) a **chunk
  run**, including a LEADING partial (`ivt_f2_slot_chunk_multiset()`:
  the member-array lengths must partition into `R ≥ 2` identical runs;
  `canivt_chunked_count`). (4) the **page directory, and it is the last
  word** (`ivt_dir_outer_count()` / `ivt_f2_dim_count_container()`) —
  extends the outermost paged dimension to the last entry that decodes
  AND carries cells; needs ≥ 2 paged levels, declines on slot holes,
  never stops at the first gap, only ever raises
  (`canivt_container_count`).
- **A “sparse” directory is a correct directory read against a wrong
  count.** Outer levels pad to `nextpow2()` and an unwritten window is a
  zero entry — the same absence as a suppressed geography. **The stride
  witnesses the count** (16 entry slots per outer member declares an
  11-window dimension). Likewise **a directory BASE may open with
  unwritten entries**: `ivt_f2_dir_first_entry()` walks up to
  `IVT_DIR_LEAD_BLANK_MAX` (1024) blanks, and
  `ivt_f2_dir_anchor_header()` runs the strict pass across every wrap
  **first**, so a blank-led candidate can never beat a populated one.
  **A failed anchor is not evidence of a stale pointer** — on all five
  files once blamed on `@558`, the pointer was right.
- **A written page whose presence record is all zero is an ABSENCE, not
  a witness** (`ivt_f2_page_blank()`) — the same absence as an unwritten
  entry slot, one level down, and it must be counted out of any stride
  measurement.
- **An ordinal run indexes members, so it cannot exceed the member
  count** (`ivt_f2_is_ordinal(t, n)`) — without that bound a chunk of
  consecutive numeric *codes* reads as an ordinal delimiter.

### Descriptor and dimension identity

- **`ivt_f2_descriptor()` anchors dimension records on the doubled
  name**, not a fixed marker: the **first copy may be truncated** (~14
  chars; longest matching prefix wins), and the name may start with an
  uppercase letter **or a digit**. The type byte is a
  storage/classification tag, **not** dimension identity. The header
  **`n_dim` field is unreliable** — gate on `length(d$dims)`. Handles
  the **INVERTED layout** and **PROSE-BLEED names** (2001 F-series).
- **Geography is the first descriptor dimension EXCEPT the profile
  lineage** (`ivt_f2_geo_dim_index()` — a 1-member “Values” placeholder
  first, geography LAST). Identification is **never by type byte**: the
  geography type is a storage-width tag for the member count (**u16**
  for `0x10`/`0x0d`/`0x0a`/`0x0c`/`0x09`/`0x0f`, u8 otherwise). Use
  `ivt_f2_geo_count()`, **not** `ivt_f2_header_geo_count()`, for any
  geography sizing. A reference-period / facet dimension (type `0x0e`)
  is **not** geography-folded.
- `cells` data columns are named by a purely generic, **name-agnostic
  slug** (`ivt_dim_slug()`), in descriptor order, so `geo` need not be
  first. **No code branches on dimension names or type bytes** —
  everything the decoder needs is structural. Labels come from the
  codebook at `tidy` time.

### Gates and fallbacks

- **`ivt_f2_decodable()` = descriptor + layout +
  `ivt_page_preflight()`** is the whole detection gate: extent within
  the entry size, exact fit for `b2 == 0`, presence count ≤ the page’s
  real cell capacity, and the directory **spanning the outer entry
  cartesian**. A rejection often means **the descriptor was misread**,
  not that the container is alien. **The gate always returns a verdict**
  — entry indices are screened by `ivt_entry_addressable()`, never an
  integer-overflow `NA`.
- **In the type-00 sub-A cluster the outer directory stride is
  non-declared, so an unmeasurable stride is a REFUSAL.** It is measured
  as a **TILING, not a progression** (`ivt_f2_suba_dir_stride()`: the
  smallest `S` whose populated entries fall into `geo_count` groups with
  an identical residue set, nothing populated beyond `geo_count · S`),
  and the residues **gate the early return** too. Placements — including
  the detached total — are adopted on **exact reconciliation**, never on
  shape; where the bilingual member arrays and the occupied-slot count
  agree, the members ARE the occupied slots. When nothing confirms,
  `suba_unverified` and `ivt_f2_decodable()` returns `FALSE`.
- **Fallbacks are LOUD** (`ivt_fallback()`): every content-heuristic
  path (stride walks, regex/dedup scans, count-keyed labels, marker-scan
  directory location, fixed slot orders, tail windows) raises a classed
  `canivt_fallback` warning when it supplies values; `canivt.strict`
  upgrades these (and skipped pages) to errors. Detection probes stay
  quiet (`ivt_quietly()`). Wire every new fallback through it.

## Dev workflow

See
[`testing.md`](https://mountainmath.github.io/canivt/inst/notes/testing.md)
for the sample-file env vars, the three corpus ledgers and the
parallel-suite rules. The short version:

``` sh
CANIVT_CORPUS_TESTS=1 Rscript -e 'devtools::test(filter = "corpus")'
```

- `corpus-ledger.csv` (verdict / strict-cleanliness / stored cell
  count), `status-ledger.csv` (the cell-status tail) and
  `complete-ledger.csv` (the fold) are the three contracts; re-measure
  the latter two with `dev/msweep.R` and `dev/csweep.R`.
- When a gap is closed or a table onboarded, update the ledger row
  **and** `coverage.md` in the same commit.
- `expect_*()` must never be called from a forked child — the corpus
  sweeps read in a parallel pre-pass and assert serially.
- `.ivt` and large `.csv` files are git-ignored; never commit them.

## Open tasks

The decoder, unified metadata, uniform geography parsing, the attribute
table, commuting-flow decoding, footnote scope, geo-name completeness,
the `16 00` mid-section, the `0xa` reason codes and their `@698` legend
are all **done**; the onboarding backlog is cleared and the refusal
ledger is empty.

- **The SECOND tail block is NOT decoded** (opened 2026-07-27). On 8
  corpus tables, index bits address words past the mask’s `rec_bytes`.
  Content is packed flag words, but **not a per-cell code array under
  any of 16 tested encodings**, and its size correlates with no per-cell
  quantity. Counted as `extra_words`, loud
  (`canivt_status_extra_block`). Two dead leads recorded so they are not
  re-run — see `ivt-format.md`, “The second tail block (OPEN)”.
- **Mask completeness caveats, reported not hidden.** A mask that stops
  short of the grid is a **statement**, not a gap: an unwritten word
  inside the index’s reach declares that word all-zero. `covered_bits`
  is that reach and `canivt_status_beyond_mask` fires only past it — **0
  corpus-wide**. The x87 sNaN artefact destroys one status bit per
  NaN-shaped `width = 8` word **in the source file**
  (`canivt_status_nan_quieted`, raised via `ivt_source_truncation()` so
  strict keeps it a warning).
- **type-00 sub-A industry labels are PROVISIONAL** (`R/suba.R`) —
  reconciliation validates sums, not the code→member assignment, and no
  published ground truth exists. Manual leaf-code evidence supports the
  current assignment but the parser deliberately does not run it, so the
  loud flag stays.
- **`Rcpp` fast path** — only if pure-R decode becomes a bottleneck (~5
  s for 7.5 M cells is fine).

Two resolved behaviours are **accepted by design** (detail in
`decode-history.md`): source-side `DQF_NOTE` truncation (\>252 chars,
truncated by StatCan’s writer — `canivt_source_truncation` stays a
warning under strict), and synthetic-aggregate geographies whose
`geo_uid` / `geo_level` are genuinely absent and correctly stay `NA`.

## Provenance

The reverse-engineering started in a project on-boarding older census
data into CensusMapper; those import scripts seeded **canivt**.
