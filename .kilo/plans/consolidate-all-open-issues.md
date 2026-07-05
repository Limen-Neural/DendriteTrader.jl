# Plan: Consolidate All Open Issues into One PR

**Goal:** Create a single PR that addresses all 4 open GitHub issues in `Limen-Neural/DendriteTrader.jl`.

**Current State:**
- Branch: `merge/dendrite-trader-spikekelly` (up-to-date with `main`)
- 4 open issues (no PRs open)
- CI workflow exists (`ci-julia.yml`) but differs from issue #8 spec
- Working tree clean

---

## Issues to Address

### Issue #8 — CI Workflow (GitHub spec)
- **File:** `.github/workflows/ci.yml`
- **Spec:** Matrix `["1.10", "1.11"]`, `julia-actions/julia-runtest@v1`, explicit doctest step with `continue-on-error: true`
- **Current:** `ci-julia.yml` uses `["1.10","1.11","1.12"]`, `Pkg.test()` only, no doctest step

### Issue #7 — LIM-50 Boundary Docs (DendriteTrader side)
- **File:** `src/DendriteTrader.jl` (module docstring)
- **Changes:** Add explicit "does NOT own" list, note that win-rate/PnL tracking belongs in `metabolic-ledger`, ensure no `GhostWallet`-like state

### Issue #6 — LIM-50 Boundary Docs (metabolic-ledger side)
- **File:** `README.md`
- **Changes:** Confirm `metabolic-ledger` owns persistent accounting; reference boundary test/comment in DendriteTrader

### Issue #5 — SpikeEngine Boundary Decision
- **Status:** Decision already made (SpikeKelly folded into DendriteTrader)
- **Action:** Close with rationale referencing the SpikeKelly merge PR (#4)

---

## Implementation Plan

### 1. Branch Strategy
- Create new branch from `main`: `consolidate/open-issues`
- Work is documentation + CI alignment only (low risk, no code changes)

### 2. CI Workflow Alignment (Issue #8)
- Create `.github/workflows/ci.yml` exactly matching the spec in issue #8:
  - Matrix: `["1.10", "1.11"]`
  - Uses `julia-actions/julia-runtest@v1`
  - Explicit doctest step with `continue-on-error: true`
- Optionally keep `ci-julia.yml` (or rename/remove) — decide during review

### 3. DendriteTrader Module Docstring (Issue #7)
- Update the module docstring in `src/DendriteTrader.jl:1-50`:
  - Add explicit "does NOT own" section:
    - `GhostWallet`-like persistent state
    - Win rate, realized PnL, portfolio position tracking
  - Add boundary comment: "Win-rate/PnL tracking belongs in `metabolic-ledger`"
  - Ensure no new `GhostWallet`-style fields are present (already true)

### 4. README Boundary Section (Issue #6)
- Enhance the "Repository Boundary" section in `README.md`:
  - Confirm `metabolic-ledger` owns persistent accounting
  - Cross-reference the explicit boundary comment added to the module docstring

### 5. Close Issue #5
- Record decision rationale in a comment on issue #5:
  - SpikeKelly was folded into DendriteTrader (PR #4)
  - `TradeSignal`/`TradeSide`/`DydxClient` remain in DendriteTrader as the trading adapter scope was chosen
  - Core SNN runtime (`SpikeEngine.jl`) is not in this repo

### 6. Validation Steps
- `julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.test()'`
- `rg "GhostWallet|realized PnL|win rate|portfolio position" src test README.md`
- Confirm CI workflow file matches issue #8 spec exactly
- Verify no new persistent accounting state was introduced

### 7. PR Creation
- Single PR titled: `chore: consolidate open issues (CI, LIM-50 boundary, SpikeEngine decision)`
- Body references all 4 issues (`Closes #5`, `Closes #6`, `Closes #7`, `Closes #8`)
- Labels: `documentation`, `ci`, `chore`
- Branch: `consolidate/open-issues` → `main`

---

## Risk Assessment
- **Low risk** — all changes are documentation strings, README wording, and CI workflow alignment.
- No behavioral changes to Kelly sizing, execution engine, or ZMQ paths.
- CI change only affects workflow definition; matrix is a subset of current.

---

## Open Questions for User (if any)
- Should the existing `ci-julia.yml` be removed, kept alongside, or replaced by the new `ci.yml`?
- Any preference on branch name (`consolidate/open-issues` vs. another)?

---

**Plan Status:** Ready for implementation. All information gathered; no further exploration needed.
