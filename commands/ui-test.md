# /ui-test

Run Flutter widget smoke tests and (optionally) on-device UI verification against a connected device or simulator.

## Usage

```
/ui-test [screen]
/ui-test all
/ui-test home
/ui-test analysis
/ui-test detail
```

## What it does

Uses Flutter test infrastructure and (when a device is connected) ADB or `xcrun simctl` to:
1. Verify a device/simulator is connected or fall back to widget-test-only mode
2. Run `flutter test` for the target screen's widget tests
3. On a connected device: launch each target screen, capture a screenshot, and verify key elements
4. Report pass/fail per screen with screenshot paths

## Implementation

When this command is invoked, execute the following steps:

### Step 1 — Verify device and run widget tests

```bash
# Check for connected device/simulator
flutter devices
```

If no device is listed (other than the header), proceed in **widget-test-only mode**: run `flutter test apps/mobile/test/` and report results. No on-device screenshots are captured in this mode.

If a device is available, proceed with full on-device testing.

### Step 2 — Run widget tests

```bash
cd apps/mobile
flutter test --reporter=expanded
```

Report the pass/fail count. Failing tests block the on-device test phase — fix them before proceeding.

### Step 3 — Screen test matrix (on-device only)

For each screen in the matrix below (or just the requested screen):

1. Launch via `flutter run` or deep-link / `adb shell am start` (Android) / `xcrun simctl openurl` (iOS).
2. Wait 2 seconds for render.
3. Capture screenshot via `adb shell screencap -p` (Android) or `xcrun simctl io booted screenshot` (iOS).
4. Pull/read the screenshot and verify key elements.
5. Record PASS or FAIL with reason.

| Screen | Route / Feature | Required elements | Key checks |
|---|---|---|---|
| `home` | `/` (Home screen) | Scan button, disclaimer link, app bar | Disclaimer link visible, scan button tappable, no overflow |
| `scan` | OCR scan screen | Camera preview or image picker | Camera permission handled, progress indicator present |
| `analysis` | ProductAnalysis screen | Ingredient list, risk score section, community score section | Risk score and community score visually separate (PLAN.md §10); disclaimer visible |
| `detail` | IngredientDetail screen | Ingredient name, attention level, regulatory summary, disclaimer | Disclaimer text per PLAN.md §24; back nav works |
| `allergen` | Any ingredient with allergen flag | Allergen indicator, attention-needed label | No prohibited wording (PLAN.md §14); correct vocabulary used |

### Step 4 — Product invariant checks

After testing each screen, apply these cross-screen checks:

- **Wording (PLAN.md §14):** grep the rendered text on each screen for prohibited phrases:
  `kesin zararlı`, `kesin güvenli`, `kanser yapar`, `doktor onaylı`, `definitely harmful`, `definitely safe`, `causes cancer`, `doctor approved`.
  Any match is a FAIL.

- **Disclaimer (PLAN.md §24):** confirm that Home, ProductAnalysis, and IngredientDetail all have a visible disclaimer or disclaimer link. FAIL if absent.

- **AI verdict check (PLAN.md §21 Karar 4):** confirm that any AI-generated summary text does NOT contain `"safe"`, `"harmful"`, `"approved"`, or equivalent verdict vocabulary as a standalone claim.

### Step 5 — Report

Output a table:

```
Screen     | Status | Notes
-----------|--------|------
home       | PASS   | Disclaimer link visible
scan       | PASS   | Camera permission flow handled
analysis   | PASS   | Risk score and community score separate; disclaimer present
detail     | PASS   | Disclaimer present, back nav clean
allergen   | PASS   | Attention-needed label, no prohibited wording
```

Save screenshots to `/tmp/ui_test_results/` and report the path.

## Notes

- This command requires `flutter` on PATH and `apps/mobile/` to be the working directory.
- On-device screenshots require a connected Android device (ADB) or iOS simulator.
- Widget-test-only mode (no device) still validates all non-visual test logic.
- For full regression testing, use `/post-issue-1-regression` which covers the complete user journey including Supabase edge function integration.
- Product invariant violations (PLAN.md §14, §24) are FAIL regardless of visual correctness.
