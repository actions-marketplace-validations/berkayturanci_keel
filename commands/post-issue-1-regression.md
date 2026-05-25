---
description: Manual regression playbook — drives on-device or simulator testing through the core ingreview flow (OCR scan, ingredient analysis, risk scoring, product invariants)
---

# /post-issue-1-regression

Deterministic manual regression playbook scoped to the core ingreview user journey: scanning a product label via OCR, analysing ingredients, checking risk scores, and verifying PLAN.md product invariants throughout. Run this after any non-trivial change to the OCR pipeline, risk engine, ingredient matching, or UI layer.

This command is a **spec** — it defines WHAT to test and WHEN each step is run. Automation of individual steps depends on the test infrastructure available in the local environment.

## When to use

Run after a non-trivial change to any of the following:
- `apps/mobile/lib/features/ocr/` — OCR capture pipeline
- `apps/mobile/lib/features/analysis/` — ingredient analysis and risk engine
- `packages/risk_engine/` — risk scoring library
- `packages/ingredient_dictionary/` — ingredient lookup and normalization
- `supabase/functions/` — edge functions used by analysis
- PLAN.md product invariants (§10, §14, §21, §24)
- Any UI screen that shows ingredient analysis results

And before tagging a release.

## Prerequisites

- A physical device or iOS/Android simulator connected and available.
- `flutter run` or `flutter install` from `apps/mobile/` is runnable.
- For steps marked `semi`: a test product label image staged locally.
- For steps marked `manual`: requires human review of output for correctness.

## Run-id convention

Use a UTC timestamp matching the agent-codename pattern from `AGENTS.md` (`POST1-<YYYYMMDDTHHMMSSZ>`, e.g. `POST1-20260518T135937Z`). All artifacts for a single playbook execution live under `build/regression-artifacts/<run-id>/<step-id>/`.

## Steps

### STEP-1-COLD-START — App launch and home screen

- **Tier:** `auto`
- **Checks:**
  - [ ] App launches without crash from cold start
  - [ ] Home screen renders with scan button, disclaimer link (PLAN.md §24)
  - [ ] Disclaimer text is reachable within 2 taps
- **Acceptance criteria:**
  - App reaches home screen within 5 s of launch.
  - No Dart exception in debug console during launch.
  - Disclaimer accessible via visible link on home screen.
- **Artifact:** `STEP-1-COLD-START/` — screenshot-home.png, flutter-log.txt

### STEP-2-OCR-SCAN — OCR capture pipeline

- **Tier:** `semi` — requires a test product label image staged locally
- **Checks:**
  - [ ] Camera permission granted (or simulator image-picker fallback)
  - [ ] Scan or pick a test label image → OCR runs and returns extracted text
  - [ ] Extracted text is non-empty and plausible (not garbage)
  - [ ] Progress indicator shown during OCR processing
- **Acceptance criteria:**
  - Extracted text contains recognizable ingredient names from the test image.
  - No Dart exception or unhandled error during OCR.
- **Artifact:** `STEP-2-OCR-SCAN/` — screenshot-scan.png, screenshot-result-raw.png, ocr-output.txt

### STEP-3-INGREDIENT-ANALYSIS — Ingredient matching and normalization

- **Tier:** `semi` — uses the output of STEP-2
- **Checks:**
  - [ ] OCR output is fed into the ingredient parser
  - [ ] Known test ingredients (e.g. "potassium sorbate", "sodium benzoate") are matched in the ingredient dictionary
  - [ ] Matched ingredients show correct normalized names (no wording rule violations — PLAN.md §14)
  - [ ] Unknown ingredients are labelled as "data-insufficient" or "community-reported", NOT as "safe" or "harmful"
- **Acceptance criteria:**
  - Each recognized ingredient maps to an entry in `packages/ingredient_dictionary/`.
  - No ingredient is labelled "kesin zararlı", "kesin güvenli", or any PLAN.md §14 prohibited phrase.
  - Unknown ingredients display a "data-insufficient" or neutral framing.
- **Artifact:** `STEP-3-INGREDIENT-ANALYSIS/` — screenshot-analysis.png, ingredient-list.txt

### STEP-4-RISK-SCORE — Risk engine scoring

- **Tier:** `auto`
- **Checks:**
  - [ ] Risk engine produces a score for the analysed product
  - [ ] Risk score is displayed in the ProductAnalysis screen alongside a disclaimer (PLAN.md §24)
  - [ ] Risk score and community score are displayed **separately** (PLAN.md §10, §21 Karar 3)
  - [ ] AI-generated summary (if present) does NOT contain a verdict ("safe", "harmful", "approved") — PLAN.md §21 Karar 4
- **Acceptance criteria:**
  - Risk score is a numeric or categorical value with a visible disclaimer.
  - Community score section is visually distinct from the risk engine score section.
  - AI summary (if shown) uses attention/caution framing only — no verdicts.
- **Artifact:** `STEP-4-RISK-SCORE/` — screenshot-risk-score.png, screenshot-community-score.png

### STEP-5-ALLERGEN-FLOW — Allergen and attention indicators

- **Tier:** `auto`
- **Checks:**
  - [ ] Known allergens (e.g. gluten, lactose) are flagged with an "attention-needed" or "known allergen" label
  - [ ] Pregnancy/breastfeeding-sensitive ingredients show the "consult your doctor" disclaimer (PLAN.md §24)
  - [ ] No ingredient is labelled "toxic" or equivalent (PLAN.md §14)
- **Acceptance criteria:**
  - Allergen indicators use the approved vocabulary: "attention-needed", "known allergen", "community-reported", "regulatory-limited", "data-insufficient".
  - Pregnancy flow disclaimer is visible in the IngredientDetail screen for any flagged ingredient.
- **Artifact:** `STEP-5-ALLERGEN-FLOW/` — screenshot-allergen.png, screenshot-pregnancy-disclaimer.png

### STEP-6-INGREDIENT-DETAIL — IngredientDetail screen

- **Tier:** `auto`
- **Checks:**
  - [ ] Tapping an ingredient navigates to IngredientDetail screen
  - [ ] IngredientDetail screen shows: normalized name, attention level, regulatory summary, and disclaimer (PLAN.md §24)
  - [ ] Back navigation returns to ProductAnalysis without crash
- **Acceptance criteria:**
  - IngredientDetail renders within 2 s.
  - Disclaimer text is present per PLAN.md §24.
  - No navigation crash on back gesture.
- **Artifact:** `STEP-6-INGREDIENT-DETAIL/` — screenshot-ingredient-detail.png

### STEP-7-SUPABASE-EDGE-FUNCTION — Edge function integration

- **Tier:** `semi` — requires Supabase project URL + anon key in `.env`
- **Checks:**
  - [ ] The ingredient analysis edge function is called with the parsed ingredient list
  - [ ] The edge function returns a response within 10 s
  - [ ] The response does NOT contain AI-generated verdicts (PLAN.md §21 Karar 4)
  - [ ] Error handling: if the edge function is unavailable, the app shows a graceful degraded state
- **Acceptance criteria:**
  - Edge function call succeeds (HTTP 200) and returns a structured response.
  - Response vocabulary passes PLAN.md §14 wording check (no prohibited phrases).
  - Offline/degraded mode shows a user-facing error message, not a crash.
- **Artifact:** `STEP-7-SUPABASE-EDGE-FUNCTION/` — edge-function-response.json, screenshot-degraded-mode.png

### STEP-8-PRODUCT-INVARIANTS — Final product invariant sweep

- **Tier:** `manual` — owner reviews output for correctness
- **Checks:**
  - [ ] Run `flutter test` from `apps/mobile/` — all unit tests pass
  - [ ] Run `flutter analyze` from `apps/mobile/` — zero errors
  - [ ] Grep the codebase for any prohibited wording: `grep -rn "kesin zararlı\|kesin güvenli\|kanser yapar\|doktor onaylı\|definitely harmful\|definitely safe\|causes cancer\|doctor approved" apps/ packages/ supabase/`
  - [ ] Owner reviews risk score display and disclaimer placement for correctness
- **Acceptance criteria:**
  - `flutter test` exits 0.
  - `flutter analyze` exits 0.
  - The prohibited-wording grep returns 0 matches.
  - Owner explicitly confirms the risk score and disclaimer display are correct.
- **Artifact:** `STEP-8-PRODUCT-INVARIANTS/` — flutter-test-output.txt, flutter-analyze-output.txt, wording-grep-output.txt, owner-signoff.txt

---

## On failure

Failure handling is **continue, don't abort**. For each failing step:

1. Capture the step's artifact bundle under `build/regression-artifacts/<run-id>/<step-id>/`.
2. Open a draft GitHub issue via `gh issue create --draft` with:
   - Title: `regression: <STEP-ID> failed on run <run-id>`
   - Body: a one-line repro pointing at the run-id, the step ID, the failing acceptance criterion, and the artifact path.
   - Labels: `regression`, `type:testing`, plus severity label per `AGENTS.md § Issue Label Taxonomy`.
3. Continue to the next step. Do NOT abort the run.

## Cross-references

- `.claude/commands/ui-test.md` — fast Flutter widget smoke check.
- `.claude/commands/regression.md` — codebase-wide static regression scan.
- `PLAN.md` §10, §14, §21, §24 — product invariants this playbook validates.
- `AGENTS.md` § "Product invariants (from PLAN.md)" — summary of the invariants.
