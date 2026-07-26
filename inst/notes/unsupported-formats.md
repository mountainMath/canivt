# Unsupported `.ivt` files — the current refusal ledger

What `canivt` deliberately refuses to decode, and why. Everything else in the
corpus decodes (see [`coverage.md`](coverage.md); the story of each onboarding in
[`decode-history.md`](decode-history.md); the repeatable onboarding recipe in
[`onboarding-backlog.md`](onboarding-backlog.md)).

## How rejection works

Detection is **structural** — `ivt_f2_decodable()` = descriptor + layout +
`ivt_page_preflight()`, no allow/deny lists — and a file can fail it in two
distinct ways:

- **descriptor-level**: the header descriptor is a layout we do not model (wrong
  dimension count, a dimension missing, a count read at the wrong width);
- **page-level**: descriptor *and* directory parse cleanly, but the pages are
  inconsistent with the resolved layout and the pre-flight's **extent /
  exact-fit / capacity / span** rules reject them. These would decode *wrong*,
  not *not at all*, so the rejection is what protects against silently
  misindexed cells.

**A pre-flight rejection frequently means "the descriptor was misread", not "the
container is alien."** Every file this document used to list has since been
onboarded that way — 97-570-X1981004 (the "Values" placeholder's count read 32
instead of 1: the double-01 framing ambiguity), 98-400-X2016203 (type `0x0a`
carries a **u16** count: 825, not 57), 97F0020XCB2001070 (type `0x09` likewise:
282, not 1 — which also fixed a silent mis-decode of 98-10-0174), 97-563-XCB2006072
(the `b3` head-block rule), the 1991 profiles (the dense `0x0_` page variant),
`ord-08035`, the `cro`/`CRO` custom extracts, 97F0015X, 97-570-X1981002,
98-400-X2016019, `SP3_RHUXA9_801` (the "Date" count read 3386 against the 23
members its `08 00` time table declares). **Check the descriptor first.**

The rule when a file cannot be onboarded honestly: **ledger it
`supported = FALSE`** in `tests/testthat/fixtures/corpus-ledger.csv` rather than
emit unvalidated values. That row is a guard — the corpus test fails if the gate
ever silently starts accepting the file.

## Ledgered guard files (in the corpus, `supported = FALSE`)

The type-00 sub-A provincial Business-Patterns cluster (`byte 0 == 0x02`, no
geography, `PROV/CAN|CA/CMA × INDUSTRY × EMPCLASS`). `R/suba.R` measures the
directory stride from the page directory (it is a physical constant this
generation does not declare), recovers the industry count from the codebook
chunks, maps the members, and **commits only if the decode reconciles**
(industry `Total` == Σ detail per geo × empclass, or geo `Canada` == Σ provinces).
These three do not reconcile, so the gate refuses them:

| key | why |
|---|---|
| `SP3_PAWNKX_CACMA3-2` | hierarchical CMA geography, 330 industry codes — the recovered slot map does not reconcile |
| `SP3_PAWNKX_PROVSIC4-2` | SIC-4, 1254 classes — does not reconcile |
| `SP_VB0LLW_PROVSIC4dec1997` | SIC-4, 1,255 classes — the outer directory stride cannot be measured, so the modelled one is unverified (see below) |

Further guards, unrelated to sub-A, whose diagnosis is in the deferred section
below — they are in the local corpus, so they carry a ledger row (2026-07-25)
rather than sitting only in prose:

| key | why |
|---|---|
| `SP_1ODZAS_PROVSIC2june1998` | Business-Register provincial SIC — span-and-overshoot pre-flight failure that the count witnesses do not resolve |
| `SP_FPBMMO_PRVNAIC1dec1998` | same |

(`PRSIC2june2001`, `PRVNAIC3_LOC-1` and `CDCSDNAIC3dec2006`, listed here as guards
on 2026-07-25, were onboarded 2026-07-26 — see the sparse-directory section of
[`coverage.md`](coverage.md). `SP3_C2YSID_Table-080` and `SP3_NAZQV2_Table-210`,
also listed on 2026-07-25, were onboarded 2026-07-26 by the blank-led anchor work
— see below.)

### `SP_VB0LLW_PROVSIC4dec1997` — refused on an unverifiable stride (2026-07-26)

Its `@558` anchor **does** resolve (that diagnosis was the blank-led-entry bug,
fixed 2026-07-26), and its industry count is now recovered correctly: the codebook
writes 1,255 SIC-4 members as `[94][256][256][256][256][137]` per language copy —
a **leading** partial chunk as well as a trailing one, which the original
trailing-partial-only recogniser declined (`ivt_f2_slot_chunk_multiset()` now
resolves it; the sibling `PROVSIC4-2` reports ~1,254, so the figure is corroborated
across the lineage).

It still must not decode. The page directory lays **11 industry windows per
province at entry slots 3..13** of a 16-slot group, where the positional model
produces 10 windows from slot 0. `ivt_f2_suba_dir_stride()` finds no stride it can
confirm, and in this cluster the outer stride is a non-declared physical constant —
so the modelled geometry is unverified. Decoding anyway yields 41,260 cells on an
industry axis running 419…1254 with no `Total` member, and `Canada == Σ provinces`
misses by millions on all 445 complete slices. `ivt_f2_suba_annotate()` therefore
flags the descriptor `suba_unverified` and `ivt_f2_decodable()` returns `FALSE`.
The flag is raised **only** where there are ≥ 2 outer members — a single outer
member (`EDDTAB16`, geography count 1) has no stride to measure and nothing to
verify.

The open question is where those 3 leading window slots come from: the shape
matches a dimension whose live slots start above 1, which is exactly what the
`16 00` slot table declares elsewhere. That is the next thing to measure here.

Onboarded siblings, for contrast: `PROVINDjune1997` (dense DIVISIONS, 2,031
cells), `PROVSIC3june1997` (chunked, total-far, 22,581), `PROVSIC3-1` (chunked,
total-first, 29,463). Their industry **labels are provisional** — reconciliation
validates SUMS, not the SIC-code → member assignment (a uniform relabel leaves the
sums unchanged), and there is no ground truth: Borealis/Odesi carry only `.ivt`,
and the open CBC CSVs are a different vintage *and* classification (web- and
Dataverse-API-checked 2026-07-24).

## Known but not in the corpus (deferred, no ledger row)

Sampled by the range-harvest sweeps, diagnosed, left for a future pass. Grouped by
the format issue, not the file. Entries here have **no ledger row** because the
file is not in the local corpus; the ones that are were promoted to ledgered
guards above on 2026-07-25 and keep their diagnosis here.

**Directory relocation / anchor failure — CLOSED 2026-07-26**

Both entries here (`SP3_C2YSID_Table-080`, `SP3_NAZQV2_Table-210`) are onboarded.
Neither anchor was stale: `@558` was correct on both, and the *validator* was
wrong. It required entry 0 of the candidate base to be a page, but a directory
pads every level to its declared allocation, so the leading slots of the base can
be legitimately **unwritten** — 96 blank entries on Table-080, 1 on Table-210.
`ivt_f2_dir_first_entry()` now walks up to `IVT_DIR_LEAD_BLANK_MAX` all-zero
records before giving up, and `ivt_f2_dir_anchor_header()` takes the strict pass
across **all** wraps first so no already-working file can change.

Table-210's "irregular packing" was the same bug seen downstream: with the anchor
resolved and the descriptor's slot positions attached, all 10 Characteristics and
all 10 Education levels decode. The one further fix needed was that
`ivt_f2_descriptor_impl()`'s `descriptor_from_slots` early return bypassed
`ivt_f2_dim_count_reconcile()`, so a dimension declaring live slots **above 1**
(Table-080's "Sex" at slots 4..6 of 8 — exactly where the directory's entries sit)
never received its `$slots`. See [`coverage.md`](coverage.md) for the validation.

**Sparse-directory modelling (Business-Register provincial SIC/NAIC)**

- **Largely closed 2026-07-26.** The "sparseness" was a correct directory read
  against a wrong count: the directory allocates `nextpow2(window_count)` entry
  slots per outer member and leaves unwritten windows as zero entries. With the
  page directory added as the third count witness (`ivt_dir_outer_count()`),
  `PRSIC2june2001`, `PRVNAIC3_LOC-1` and `CDCSDNAIC3dec2006` all decode and
  reconcile exactly on the files' own identities — see the sparse-directory
  section of [`coverage.md`](coverage.md). `PRNAIC6dec2000` had already gone that
  way on 2026-07-25 via the `16 00` slot table.
- `PROVSIC2june1998`, `PRVNAIC1dec1998` remain **ledgered guards**. They are
  `byte 0 == 0x02` sub-A files, and their directories are irregular in a way the
  onboarded siblings' are not: within a 16-entry stride per province the pages
  sit at slot 0 **plus slot 10** (`PRVNAIC1dec1998`) or slots 0 and 5
  (`PROVSIC2june1998`), where the positional model produces consecutive window
  slots (`PROVSIC3june1997`, onboarded, packs 0,1,2,3). Their industry counts are
  correspondingly under-read (20 and 77 against a directory carrying two windows'
  worth of pages), and the sub-A recovery does not reconcile — so the gate refuses
  them.

**Layout extent / overshoot — CLOSED**

- `02560006` (184 cells) and `Table_6_c-2009` (2,072) were onboarded 2026-07-25
  by the slot-map work and carry `supported = TRUE` ledger rows; this entry was
  stale prose, corrected 2026-07-26. `701` went the same way as `SP3_RHUXA9_701`
  via the under-declared-count work, as did the `103` formerly listed under anchor
  failure.

**Corrupted source**

- `Dec09DA` (Canadian Business Patterns) — the downloaded file itself is corrupt,
  not a format gap.

## Closed: the "known limitation" on `CDNAIC3_LOC-1` (2026-07-26)

This section used to record `SP3_PAWNKX_CDNAIC3_LOC-1` as knowingly partial —
ledgered at **133,217** cells with its `SUB-SECTORS` count over-read as 26,628,
because the chunk-count reconcile that fixes it (1,366) left only sub-members
1..104 decoding and there was no ground truth to prefer 162,127 over 133,217.

Both halves are now settled, structurally:

- **1,366 is right**, and the container says so: the directory allocates 16 entry
  slots per geography = `nextpow2(11 windows)`, which is the file declaring an
  11-window dimension. A ~104-member dimension would have been allocated one slot.
- **162,127 is the whole file.** Only window 0 is ever populated (one page per
  geography), and the referenced pages are byte-contiguous with zero gaps, so
  there is no unwritten-window data hiding anywhere: the product publishes the
  3-digit NAICS level only, while the codebook carries the full hierarchy. The
  6-digit sibling `PRNAIC6dec2000` populates all 8 of its windows under the same
  model.

Validated on four internal identities (all exact, zero residual) and cell-for-cell
against `PRVNAIC3_LOC-1`, a file with a different dimension order and straddle
geometry — details in [`coverage.md`](coverage.md). Ledger row raised to 162,127.
