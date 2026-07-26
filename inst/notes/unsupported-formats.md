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
| `SP_VB0LLW_PROVSIC4dec1997` | `idx0` mis-detection — the page-directory anchor does not resolve, so there is no layout to reconcile against |

Further guards, unrelated to sub-A, whose diagnosis is in the deferred section
below — they are in the local corpus, so they carry a ledger row (2026-07-25)
rather than sitting only in prose:

| key | why |
|---|---|
| `SP3_NAZQV2_Table-210` | stale `@558` anchor **and** irregular directory packing that does not fit the power-of-two stride model — `ivt_page_preflight()` rejects |
| `SP3_C2YSID_Table-080` | the `@558` anchor does not resolve; `ivt_idx0()` falls to the historical constant and no directory entry validates |
| `SP_1ODZAS_PROVSIC2june1998` | Business-Register provincial SIC — span-and-overshoot pre-flight failure that the count witnesses do not resolve |
| `SP_FPBMMO_PRVNAIC1dec1998` | same |

(`PRSIC2june2001`, `PRVNAIC3_LOC-1` and `CDCSDNAIC3dec2006`, listed here as guards
on 2026-07-25, were onboarded 2026-07-26 — see the sparse-directory section of
[`coverage.md`](coverage.md).)

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

**Directory relocation / anchor failure**

- `SP3_C2YSID_Table-080` — the `@558` anchor does not resolve; `ivt_idx0()` falls
  to the historical constant and no directory entries validate. **Ledgered guard.**
- `SP3_NAZQV2_Table-210` (LFHR: Geography 11 × Sex 3 × Age 9 × Characteristics 10
  × Education 10 × Timeseries 240 monthly, 1990-01…2009-12) — `@558 = 34997` is
  **stale**; the real directory is at **35197**, findable only by the marker scan
  (`ivt_f2_find_directory()`, which `ivt_idx0()` deliberately does not use for the
  decode path). Even from the right base the packing is irregular (validity
  alternates 8/12 valid entries per 32-entry block; two page sizes) and does not
  fit the power-of-two stride model: Characteristics decodes only 4 of 10 members
  (missing Unemployment and the rates) and the in-page Education dimension is off
  by one (member 1 phantom-absent). This is the Table-023/Table-024 geometry. The
  `16 00` mid-section, once suspected of biting here, is now decoded (2026-07-25)
  and does name the slot positions -- Education level occupies slots 10..19 of 32 --
  but the irregular packing survives it, so the file stays rejected rather than
  routed through the scan, which would **silently mis-decode**.

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

**Layout extent / overshoot**

- `02560006`, `Table_6_c-2009` — small tables whose directory overshoots
  the modelled cartesian; the extent guard rejects them. (`701`, listed here
  before, was onboarded 2026-07-25 as `SP3_RHUXA9_701` by the under-declared-count
  work, as was the `103` formerly listed under anchor failure.)

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
