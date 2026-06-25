# OP001UI — Behavior Map, Risk List & Refactor Plan

**Program:** OP001UI (Pick & Pack Casing)
**Source analyzed:** `OP001UI.TXT` (1,030 lines, fixed/free hybrid RPGLE)
**Scope of this document:** Analysis only. No source code has been changed.
**File structures verified against:** IBM i Db2, library **EDILIB** (production copies). RMBOXXF structure taken from the RPGLE source (it is not present in EDILIB).
**Date:** 2026-06-25

---

## 1. Behavior Map

### 1.1 What the program does, in one paragraph

OP001UI reads pick records (`OP001L8`) in customer / sort / store / PO order and packs them into cartons ("cases"). For each pick line it looks up a cubic-inch size and a weight, decides how many units fit in a carton without exceeding the per-customer max cube or max pounds, writes one **SKU-detail record** per SKU placed (`OP002WF`) and one **carton record** per closed carton (`OP003WF`). Along the way it allocates case/invoice numbers from data areas, adds a carton tare weight based on carton size, and applies a long list of retailer-specific exceptions to cube, weight, grouping, PO formatting, and case numbering. It is a batch program with no interactive display and no calls to other programs — it communicates only through files, data areas, and a printer error report.

### 1.2 Files

**Input (read-only, keyed):**

| File | Prefix / Record | Role |
|------|-----------------|------|
| `OP001L8` | (driver) | Main input — pick lines, read in key order |
| `INVMST` | record `invfmt` | Cube (`CU#IN`), weight, price per dept/lot/color |
| `SH241F` | record `sh241m` | Ship-customer cross reference (`SHCCDE`, `SHCSTN`) |
| `OP004PF` | record `op004r`, key `OPCUST` | Per-customer carton params: `OPMXCB` max cube, `OPMXLB` max lbs, `OPNXT#` invoice source, `OPXCUB`, `OPUPAC`, `OPFLG1` |
| `OP004PF2` | record `op004r2`, key `OPCUST/OPSTYX/OPSIZX` | Per-style/size carton param override; also chained with partial key `'30X'` (rows whose `OPCUST` slot holds the `30X` marker) |
| `ACCREC` | prefix `a_` | Duplicate store/order check |
| `CALALL1` | prefix `c`, member CASEHIST | Case-number history — used to confirm a candidate case# is unused |
| `SPP204L1` | — | **Dead** — file still declared but all uses are commented out (removed 08/28/25) |
| `BCMST2P` | prefix `b2` | Grouping quantity (`B2B2NM06`) and roll flag (`B2B2AL03='ROLL'`) |
| `RMBOXXF` | — | Box id (`BXINUM`): `ROLL`, `AS1`, `AS2`; key cust/style/size/color |
| `CUST_STOR` | — | Order type (`CSCUIN`) for the SKU record |
| `OP017W2L2` | — | Walmart-retail (`WMRET`) carton cube lookup |
| `OP017W3` | — | Walmart-retail tie-pallet / avg-case cube |
| `OP001PF` | key dept/style/lot | Heavy-item pound override (`X@POUNDS`, 9,2) for POUND/RACK/SRACK |

**Output (write):**

| File | Record | Role |
|------|--------|------|
| `OP002WF` | `op002wr` | One record per SKU placed into a carton (detail) |
| `OP003WF` | `op003wr` | One record per closed carton (header — weight, cube, PO#22) |
| `QSYSPRT` | printer | Error report only (`prtof`, `prtdup`, `prtdupacc`) |

**Data areas:**

| Data area | Field | Role |
|-----------|-------|------|
| `PFSINV#` | `inv#` (6,0) | Next invoice/case number — source 1 |
| `INVOIN` | `inv#2` (6,0) | Next number — source 2 |
| `KMTINV` | `inv#3` (6,0) | Next number — Kmart |
| `NXTPT#` | `inv#4` (6,0) | Next number — wraps `999999` → `2001` |
| `QGPL/MAXCUBE` | `max_cube` (zoned 5,0) | Global max cube; replaced former hardcoding (added 11/08/21). Used in tare tiers, `avg_case`, and the `*in42`/`9945` rule |

**External programs called:** none.

### 1.3 Program phases (subroutines)

The program is built entirely from subroutines (`begsr`/`endsr`) sharing global fields — there are no subprocedures today.

1. **`*inzsr`** — define KLISTs, reset overflow, set `factory='FACTORY'`, read in data areas.
2. **Mainline (lines 102–144)** — read `OP001L8`; on first record run `custsetup` + `dupcheck`; then loop: allocate next ticket if needed → recompute cube if `OPXCUB='Y'` → `caseit` → read-equal within the same sort-sequence (`*in11`), same `wrkkey` (`*in10`), and customer break (`*in12`), closing cartons at each break.
3. **`custsetup`** — reset the case-number indicators (`*in41`–`*in49`), chain `OP004PF` for customer params, detect `30X` override (`*in42`), detect SkuMax flag (`OPFLG1` → `*in49`), and detect Walmart-retail orders (`lot#=' WMRET'` → `*in23`, `OPXCUB='Y'`, `wmt_cube`).
4. **`changecube`** — re-derive cube for cust/style/size when `OPXCUB='Y'`: chain INVMST, apply OP001PF pound override, BBB casepack cube, WMRET cube, cap at `OPMXCB`, and close the carton if the max-cube changed.
5. **`nextptkt`** — allocate the next case/invoice number (see §1.5) and resolve the ship-customer code (`SH241F`) including retailer DVS→base-name remaps.
6. **`caseit`** — the core bin-packing loop: derive cube + weight for the line, test fit, and place units into cartons one group at a time, forcing a single case for AS1/AS2.
7. **`addrecord`** — write the SKU-detail record (`OP002WF`), applying customer-specific `BOXSZ`/`SMAN`/`CWGT` rules, then accumulate carton weight and handle the SkuMax carton split.
8. **`Closecarton`** — finalize a carton: add tare (`Get_tare`), build the retailer-specific `PO#22`, write `OP003WF`, reset accumulators, bump `CASCNT`, and force a new ticket at `CASCNT=999`.
9. **`dupcheck`** — flag store/order combinations already in `ACCREC` (Kohls.com `KOLDS*` also compares order date).
10. **`Get_tare` / `Test_tare`** — add carton tare weight by cube tier; `Test_tare` is the trial version used to decide fit, `Get_tare` commits it at carton close.
11. **`get_otype`** — look up order type (`CSCUIN`) from `CUST_STOR`.

### 1.4 Retailer / customer-specific branches

Grouped by business purpose rather than by the date they were bolted on:

**Ship-customer code remap (`nextptkt`):** `WALMARTP&P→WALMART`, `WALMARTDVS→WALMARTCOM`, `KOHLSDSN→KOHLS`, `WAYFRDSN→WAYFAIR`, `AMZDSN→AMAZON`, `HAYNDDSN→HAYNEEDLE`, `OVERDDSN→OVERSTOCK`, `BBB.COM→BBB.COM`, `JCP.COM→JCP.COM`. `JCPENNEYR` forces `shccde/savcu#=1`.

**Cube / casepack overrides:** BBB casepack `cu#in = max_cube / caseqty` (in both `changecube` and `caseit`); WMRET `cu#in = wmt_cube`; `30X` + `cu#in=9945` → `cu#in=max_cube`; JCPENNEY retries the OP004PF2 lookup with style prefixed `C` + first 4 chars.

**PO#22 derivation (`Closecarton`)** — the big nested `If/Else`: `WALMARTP&P`=`sort2`; `COSTCO`=`sort1+sort2`; `BELK`=`sort2`; `TARGET` (str# `TDD`)=`sort2`; `WALMARTCOM`(str# `WMDVS`)/`WALMARTDVS`/`KOHLSDSN`/`WAYFRDSN`/`WAYFAIR`/`JCP.COM`/`HAYNDDSN`/`HAYNEEDLE`/`AMAZON`/`AMAZONP`/`JOSS&MAIN`/`ALLMODERN`/`OVERDDSN`/`OVERSTOCK`/`BBB.COM`/`HOME DEPOT`/`LOWES.COM`=`sort1+sortst5`; everything else clears `PO#22`.

**SKU-record (`addrecord`) field overrides:** `COSTCO` PO-line from `lnsku`; `KMART`/`SEARS` J1 boxes (`BOXSZ='J'`, store into `CWGT`); `KMART`/`SEARS` DROP SHIP (`TIME='DROP'+seq`, `BOXSZ='J'`); `JCPENNEY` (`BOXSZ=catdpt`, `SMAN`); `TARGET` (`SMAN=catdpt`); `WINNERS`/`CLOSEOUTS`/`KOHLS`/`WAYFAIR`/`JOSS&MAIN`/`ALLMODERN`/`HAYNEEDLE`/`OVERSTOCK`/`BBB.COM`/`KMART` Manual (`SMAN=catdpt`).

**Pricing:** uses `PCOST` (from OP001WF) rather than INVMST `PRICE`, because of the Wayfair 10% discount (changed 10/23/17).

**Commented-out / historical:** TARGET PO `2462239` / style `E2290` two-piece special; old WALMARTP&P casepack; old JCPENNEYDS; SPP204L1 size-`9/X/L`→4800. These remain as comments and must be preserved.

### 1.5 Case-number / invoice-number rules

- The next-number **source is chosen by `OPNXT#`** (the customer param): `PFSINV#`→`inv#`, `INVOIN`→`inv#2`, `KMTINV`→`inv#3`, `NXTPT#`→`inv#4`.
- The chosen data area is **locked (`in`), incremented, written back (`out`)**.
- `NXTPT#` **wraps**: when `inv#4 = 999999` it resets to `2001` before incrementing.
- The candidate number is checked against `CALALL1` (case history); **if it already exists, retry** with the next number.
- **Retry limit = 5000** (`hunt# > 5000`): on exhaustion the program prints `prtof`/`prtdup` and sets `*inlr` (aborts the run).
- `CASCNT` starts at 1 and increments per carton; **`CASCNT = 999` forces `neednext='Y'`** (a fresh ticket — the "over 999" rule, 01/06/14).

### 1.6 Tare-weight rules (`Get_tare` / `Test_tare`)

Tare is added to the carton weight by cube tier (identical tiers in both subroutines):

| Carton cube ≤ | Tare added (lbs) |
|---------------|------------------|
| 1530 | 0.97 |
| 2880 | 2.070 |
| 3840 | 2.230 |
| 4800 | 2.717 |
| `max_cube` | 2.740 |
| 6120 | 3.37 |
| 9945 | 3.91 |
| (none matched, `Selected='N'`) | 4 |

Tare is **skipped entirely when the item is a roll** (`ItsARoll='Y'`), *unless* `cu#in < max_cube and piece_count > 1`. POUND / RACK / SRACK / PRTRN / RRTRN styles are excluded from the `Get_tare` add.

### 1.7 Roll rules (`Get_tare` / `Test_tare`)

`ItsARoll='Y'` if `RMBOXXF` is found and `BXINUM='ROLL'`; otherwise, if `RMBOXXF` is missing or `BXINUM` is blank, chain `BCMST2P` and treat `B2B2AL03='ROLL'` as a roll. (The older SPP204L1 `SPRLFG='Y' and qty=1` test is commented out.)

### 1.8 Cube rules

- Base cube `CU#IN` comes from `INVMST`; **if 0 it is forced to 1** (09/29/15 fallback).
- For POUND/RACK/SRACK, the pound override comes from `OP001PF` (`X@POUNDS`), and `*in99` controls whether weight is multiplied by `.01`.
- At `cu#in = 4800` with an over-max weight, `maxpounds`/`OPMXLB` are bumped to fit.
- WMRET (`*in23`): `cu#in = wmt_cube` (= `max_cube / avg_case`).
- BBB casepack: `cu#in = max_cube / caseqty`.
- `30X` (`*in42`) + `cu#in = 9945` → `cu#in = max_cube`.
- Final cap: `cu#in > OPMXCB` → `cu#in = OPMXCB`.

### 1.9 Weight rules

- `xweight = xx_lbs * .01` when `*in99` is off (weight from INVMST `iweight`); `xweight = xx_lbs` when `*in99` is on (pounds from OP001PF, already in lbs).
- `*in99` on ⇔ the OP001PF heavy-item record was found.
- POUND/RACK/SRACK weights exceeding 99.99 lbs are sourced from OP001PF (06/06/19, 11/09/20, 05/19/22 changes).
- Carton max weight comes from `OPMXLB` (`maxpounds`).

### 1.10 Single-case rules (`ShouldForceSingleCase`)

- **AS1 / AS2** (RMBOXXF `BXINUM`): the fit test in `caseit` includes `or bxinum='AS1' or bxinum='AS2'`, which forces the unit into the current case and ends placement — one item per case (added 01/28/25).
- **SkuMax** (`OPFLG1` → `*in49`, value moved to `SkuMax`): when `SkuCount = SkuMax`, the carton is closed — limits the number of distinct SKUs per carton.

### 1.11 Indicators in use

| Indicator | Meaning |
|-----------|---------|
| `*inlr` | End of input / abort |
| `*in10` / `*in11` / `*in12` | Read-equal control: `wrkkey` break / `wrkkey2` (sort-seq) break / customer break |
| `*in23` | Walmart-retail (WMRET) mode |
| `*in41` | Set when `OPNXT#='PFSINV#'` (set in `custsetup`; **no downstream reader found** — see risk list) |
| `*in42` | `30X` override active (OP004PF2 row found) |
| `*in43`–`*in48` | Reset every `custsetup` but **never set or read** — dormant |
| `*in49` | SkuMax active (`OPFLG1` non-blank) |
| `*in99` | Weight source: on = OP001PF pounds, off = INVMST `iweight` |
| `*inof` | Printer overflow |

---

## 2. Risk List — where behavior could accidentally change

Ordered roughly most-dangerous first.

1. **Subroutine → subprocedure conversion changes scoping.** Every routine today shares global fields and indicators. Step 3 of the plan wants real subprocedures. The moment a global becomes a local (or a parameter is passed by value instead of reference), a value that silently carried between routines can stop carrying. `casecube`, `cartlbs`, `casepounds`, `thisqty`, `maxcube`/`save_maxcube`, `*in99`, `cu#in`, `xx_lbs` and `ItsARoll` are all cross-routine state. Extracting procedures must keep these as globals (or pass them explicitly) — verify each one.

2. **`Test_tare` mixes `testcube` and `casecube` in its tier ladder.** In `Test_tare` (the trial calc used to decide fit) the first five WHEN clauses test the trial value `testcube` (`<=1530 … <=max_cube`), but the last two — `<=6120` and `<=9945` — test the *committed* `casecube` instead. `Get_tare` is internally consistent (it tests `casecube` in every tier, which is correct for a carton being committed). The inconsistency is confined to `Test_tare` and looks like a copy-paste artifact, but **it is current behavior** — do not "fix" it during refactor. Flag it, preserve it, and raise it separately with the business (see §4 Q1).

3. **Tier ordering depends on `max_cube`'s runtime value.** The ladder is `4800 → max_cube → 6120 → 9945`. If `max_cube` (from `QGPL/MAXCUBE`) is ≤ 4800 or ≥ 6120, the `<= max_cube` WHEN can shadow or be shadowed by neighbors, silently changing which tare applies. Any refactor that reorders or "tidies" the WHEN clauses will change results. Keep the exact order.

4. **Data-area lock/unlock timing.** `nextptkt` does `in` (lock) → increment → `out` (unlock) on `PFSINV#`/`INVOIN`/`KMTINV`/`NXTPT#`. These are the live number generators shared with other jobs. Re-sequencing, wrapping in a procedure that changes lock duration, or changing `*lock` semantics risks double-issued or skipped numbers. Treat this routine as load-bearing concrete.

5. **Fall-through `Select` / nested `If-Else` semantics.** The `PO#22` chain in `Closecarton` and the customer blocks in `addrecord` rely on `Or`/`And` precedence in fixed-format C-specs (e.g. line 591–593, 614–616, 699–702, 778–781). Fixed-format RPG evaluates `And` before `Or` across factor lines in a specific way; rewriting these as free-form `if (a and b) or c` can change grouping. Each converted condition needs a side-by-side truth-table check.

6. **`*in41`–`*in48` look dead but may be referenced outside this source.** They are reset here and (41/42 aside) not used in this program — but indicators can be passed via the cycle or read by called/calling programs. Since OP001UI makes no calls, risk is low, but confirm no external dependency before removing them.

7. **`SPP204L1` is declared but unused.** Removing the F-spec is tempting and probably safe, but it changes the open/close file list and could affect override/library-list expectations at runtime. Treat file-declaration removal as its own reviewable change with an IBM i compile + open test.

8. **`30X` partial-key chain on `OP004PF2`.** `chain('30X') op004pf2` is a partial key against a file keyed `OPCUST/OPSTYX/OPSIZX`; it matches rows whose `OPCUST` slot is `30X`. This is subtle and easy to misread as a bug. Document it; don't normalize it.

9. **Customer-name string literals carry trailing-blank significance.** Values like `'BBB       '` vs `'BBB    '` vs `'KMART '` are compared at fixed lengths; note that `caseit` tests `'BBB    '` (line 521) while `changecube` tests `'BBB       '` (line 304) — different blank counts. When extracting to named constants, the constant must reproduce the exact literal (length and trailing blanks) used at each site, or comparisons flip.

10. **`cu#in = 0 → 1` fallback lives in two places with different guards.** `caseit` forces 1 unconditionally after the chain; `changecube` only forces 1 when `cu#in = 0` inside `%found`. Consolidating them into one `DetermineCube` must preserve both guard conditions.

11. **`maxcube` vs `savecube` vs `save_maxcube` vs `max_cube`.** Four similarly named cube variables with different lifetimes (`max_cube` = data area; `maxcube` = working; `savecube`/`save_maxcube` = restore points). `caseit` saves and restores `maxcube` around the 30X block (lines 473, 646). Renaming for clarity is desirable but high-risk; do it last and one variable at a time.

12. **`time` field is overloaded.** `TIME` (a 5-char output field) holds both an actual time-ish value and the literal `'DROP'+seq` for Kmart/Sears drop ship. Any "cleanup" that treats it as numeric/time breaks drop-ship labeling.

---

## 3. Refactor Plan — safe, reviewable commits

Each commit is independently compilable and behavior-preserving. Recommended order; do **not** batch them.

**Commit 0 — Header & changelog hygiene (zero logic change).**
Move the 40+ historical comment lines into a structured changelog header. Keep every line verbatim. No code touched. Compile to confirm byte-for-byte behavior.

**Commit 1 — Named constants for literals (no value changes).**
Introduce named constants for retailer names, `'DROPS'`/`'DROP'`, `'WMRET'`, `'ROLL'`, `'AS1'`/`'AS2'`, `'30X'`, `'FACTORY'`, the 5000 retry limit, the 999 carton limit, the `999999`/`2001` wrap, the `9945`/`4800`/`max_cube` cube thresholds, and the tare values. Each constant must reproduce the **exact literal including trailing blanks** at its original site (see risk #9). Pure substitution — diff should show only literal→name swaps.

**Commit 2 — Name the live indicators.**
Add named boolean aliases / comments for `*in23` (WMRET mode), `*in42` (`30X`), `*in49` (SkuMax), `*in99` (weight source), and the read-break indicators `*in10/11/12`. Document `*in41` and the dormant `*in43–48` in place; do not remove them yet (risk #6).

**Commit 3 — Extract pure look-up procedures (no shared mutable state).**
Start with the routines that read inputs and return a value: `DetermineRollItem` (from `Get_tare`/`Test_tare` roll logic), `DetermineCasePackQuantity` (BCMST2P GroupQty), `AllocateInvoiceNumber` / `AllocateCaseNumber` (wrap `nextptkt`'s data-area logic, preserving lock timing — risk #4), and `get_otype`→`DetermineOrderType`. These have the cleanest boundaries.

**Commit 4 — Extract the cube/weight/tare calculators.**
`DetermineCube`, `DetermineActualWeight`, `DetermineTareWeight`. Preserve the two cube-fallback guards (risk #10), the `casecube`-in-tier quirk (risk #2), and the exact tier order (risk #3). Keep `max_cube`/`maxcube`/`savecube` as globals for now (risk #11).

**Commit 5 — Extract `ShouldForceSingleCase`.**
Encapsulate the AS1/AS2 + SkuMax single-case logic. This is small and well-bounded.

**Commit 6 — Extract `ApplyRetailerExceptions` / rule grouping.**
Consolidate the PO#22 derivation and the `addrecord` field overrides into clearly named procedures grouped by purpose, with an explicit **default path for unknown customers**. Each converted condition gets a truth-table check against the original (risk #5). This is the largest commit — consider splitting PO#22 and field-overrides into two.

**Commit 7 — Extract `WriteCaseRecords` / `Closecarton`.**
Wrap the `OP002WF`/`OP003WF` writes and carton finalization. Preserve `CASCNT=999` and the accumulator resets.

**Commit 8 — Guardrails (explicit, behavior-preserving).**
Make the existing fallbacks explicit and add validation around: zero cube (already 1), overweight (already bumps maxpounds), invoice overflow (`NXTPT#` wrap and the >999 carton rule), case-number exhaustion (5000 retries), and missing cross-reference records (RMBOXXF/BCMST2P/CUST_STOR not found). Keep current fallback behavior — only surface it.

**Commit 9 — Variable renaming for clarity.**
Last, and one variable at a time: internal work fields to business names. Never touch externally described fields, record formats, or data-area names without a compatibility plan (rule #3).

**Commit 10 — Optional: remove dead `SPP204L1` declaration.**
Separate, with an IBM i open/compile test (risk #7).

A **regression test matrix** (normal pick/pack, roll item, BBB casepack, Wayfair price/cost, Amazon/Amazon Procurement, Home Depot direct, Lowes.com, Kohls direct, POUND/RACK/SRACK >99 lb, AS1/AS2 single case, invoice >999, case-number retry exhaustion, cube=0 fallback) should be captured before Commit 3 and re-run after each subsequent commit. It will be delivered as a separate checklist alongside the refactored code.

---

## 4. Open questions for the business (not blockers)

1. The `casecube` reference in the `<=6120` / `<=9945` tare tiers (risk #2) — intended, or a latent bug? Behavior is currently preserved either way.
2. Are `*in41` and `*in43`–`*in48` truly dead, or consumed by a downstream/scheduled process outside this source?
3. Is `SPP204L1` slated for full removal, or kept on the open list for a reason?
