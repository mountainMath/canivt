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
One file in the cluster still fails to reconcile, so the gate refuses it:

| key | why |
|---|---|
| `SP_FPBMMO_PRVNAIC1dec1998` | Business-Register provincial NAIC — no stride the directory tiling can confirm, so the modelled geometry stays unverified (see below) |

(Every other sub-A guard has been onboarded. `CACMA3-2`, `PROVSIC4-2`,
`PROVSIC4dec1997` and `PROVSIC2june1998` were refused here until 2026-07-26 and now
decode and reconcile exactly — see the directory-tiling section of
[`coverage.md`](coverage.md). `PRSIC2june2001`, `PRVNAIC3_LOC-1` and
`CDCSDNAIC3dec2006`, listed as guards on 2026-07-25, were onboarded 2026-07-26 —
see the sparse-directory section there. `SP3_C2YSID_Table-080` and
`SP3_NAZQV2_Table-210`, also listed on 2026-07-25, were onboarded 2026-07-26 by the
blank-led anchor work — see below.)

### The sub-A refusal rule, restated (2026-07-26)

In this cluster the outer directory stride is a **non-declared physical constant**:
no `16 00` slot table exists for any dimension in these files (measured — every
`ivt_f2_dim_slot_table()` call returns NULL), so nothing in the file states it and
it can only be measured from the page directory. An **unmeasurable stride is a
refusal**, because the modelled geometry would then be unverified.

What "measurable" means is the directory's **tiling**, not a progression: every
geography occupies `S` consecutive entry slots and writes the *same* window
residues inside them. `ivt_f2_suba_dir_stride()` accepts the smallest `S` for which
the populated entries fall into `geo_count` groups with an identical residue set
**and** nothing is populated beyond `geo_count · S`. That last clause is what
separates a real stride from a divisor of it. The rule tolerates a couple of
wholly-empty groups, since suppression here is whole-geography and a geography with
no cells writes no entries at all.

Reading the tiling rather than a progression is what un-gated four files: it does
not assume window 0 is populated, so `PROVSIC4dec1997`'s 11 industry windows at
entry slots **3..13** of a 16-slot group are measured correctly (the stride was 16
all along; the blank leading window was the whole problem). `ivt_f2_suba_annotate()`
raises `suba_unverified` — and `ivt_f2_decodable()` returns `FALSE` — only where
there are ≥ 2 outer members: a single outer member (`EDDTAB16`, geography count 1)
has no periodicity to measure and nothing to verify, so it is left alone.

Across the whole cluster the industry **labels remain provisional**
(`canivt_suba_labels`, loud) — reconciliation validates SUMS, not the SIC-code →
member assignment (a uniform relabel leaves the sums unchanged), and there is no
published ground truth: Borealis/Odesi carry only `.ivt`, and the open CBC CSVs are
a different vintage *and* classification (web- and Dataverse-API-checked
2026-07-24). See [`coverage.md`](coverage.md) for the manual code→member evidence
gathered 2026-07-26, which the parser deliberately does not run.

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
- `PROVSIC2june1998` was onboarded 2026-07-26 (8,809 cells). Its directory is not
  "irregular": the pages sit at window slots 0 and 5 of a 16-entry stride because
  the industry axis is a **detached total** — the `Total` member alone in window 0,
  the detail run right-aligned at the top of the group. The directory-tiling stride
  rule measures that shape, and the file then reconciles exactly (142/142 groups,
  maxdiff 0). It is also the strongest cross-file check in the cluster: rolling the
  independently-decoded `PROVSIC4-2` up by 2-digit SIC prefix reproduces it
  cell-for-cell (8,667/8,667, maxdiff 0, zero one-sided cells).
- `PRVNAIC1dec1998` remains a **ledgered guard**. Its pages sit at slot 0 **plus
  slot 10** of a 16-entry stride, which is neither a contiguous run nor a detached
  total, and the tiling rule finds no stride it can confirm. Its industry count is
  correspondingly under-read (20 against a directory carrying two windows' worth of
  pages), so the geometry stays unverified and the gate refuses it.

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
