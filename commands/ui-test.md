# /ui-test

Run ADB MCP UI smoke tests against a connected Android device.

## Usage

```
/ui-test [screen]
/ui-test all
/ui-test main
/ui-test detail
```

## What it does

Uses ADB MCP tools to:
1. Check a device is connected (`adb devices`)
2. Launch each target screen via `adb shell am start`
3. Wait for render, then capture a screenshot
4. Dump the UI hierarchy via `adb shell uiautomator dump` and verify key elements
5. Report pass/fail per screen with screenshot paths

## Implementation

When this command is invoked, execute the following steps:

### Step 1 — Verify device

```bash
adb devices
```

If no device is listed (other than the header), report: "No device connected. Connect a device and enable USB debugging, then re-run /ui-test."

Get the package name: `com.nonzeroapps.android.smartinventory`

### Step 2 — Screen test matrix

For each screen in the matrix below (or just the requested screen):

1. Launch via `adb shell am start -n <component>`
2. Wait 2 seconds for render: `sleep 2`
3. Capture screenshot: `adb shell screencap -p /sdcard/ui_test_<screen>.png`
4. Pull to local: `adb pull /sdcard/ui_test_<screen>.png /tmp/ui_test_<screen>.png`
5. Read the screenshot image and describe what you see
6. Dump UI: `adb shell uiautomator dump /sdcard/ui_dump.xml && adb pull /sdcard/ui_dump.xml /tmp/ui_dump_<screen>.xml`
7. Check for required elements (see matrix)
8. Record PASS or FAIL with reason

| Screen | Component | Required elements | Key checks |
|---|---|---|---|
| `main` | `.activity.MainActivity` | Toolbar, tab bar (ITEMS/GROUPS/TAGS), FAB | FAB not behind nav bar, tabs visible |
| `detail_item` | `.activity.detail.ItemDetailActivity` | Toolbar, name field, save FAB | No status bar overlap, scroll to bottom shows Delete button above nav bar |
| `detail_group` | `.activity.detail.GroupDetailActivity` | Toolbar, name field, save FAB | Same as item detail |
| `detail_tag` | `.activity.detail.TagDetailActivity` | Toolbar, name field, save FAB | Same as item detail |
| `import_export` | `.activity.ImportExportActivity` | Toolbar, scroll view, export buttons | Scroll to bottom — Import Start button above nav bar |
| `user_settings` | `.activity.UserSettingsActivity` | Toolbar, profile image, NestedScrollView | Toolbar fills status bar, scroll to bottom — Delete Account above nav bar |
| `summary` | `.activity.SummaryActivity` | Toolbar, pie chart card, stats cards | Toolbar below status bar, scroll to bottom — last tag card above nav bar |
| `premium` | `.activity.PremiumActivity` | Close button, feature list, Subscribe button | Close button below status bar, Subscribe button above nav bar |
| `barcode_list` | `.activity.BarcodeTypeListActivity` | Toolbar, RecyclerView of barcode types | Last barcode type row fully visible when scrolled to bottom |
| `search` | `.activity.SearchActivity` | Search bar, results list | Keyboard does not break layout, results above nav bar |

Full component path prefix: `com.nonzeroapps.android.smartinventory/com.nonzeroapps.android.smartinventory`

### Step 3 — Drawer test (after `main`)

After testing `main`:
1. Open the navigation drawer: `adb shell input swipe 0 500 300 500`
2. Wait 1 second, take screenshot
3. Check: drawer header (avatar + "Anonymous User" text) must be **below** the status bar — not overlapping it
4. Scroll the drawer to the bottom and verify the last menu item is above the nav bar
5. Close drawer: `adb shell input keyevent KEYCODE_BACK`

### Step 4 — Edge-to-edge inset checks

For each screen, look at the screenshot and check:
- **Top**: toolbar or first content card starts **below** the status bar (not hidden behind it); the toolbar background extends into the status bar area
- **Bottom**: last visible element or FAB/button is **above** the navigation bar (not hidden behind it); for scrollable screens, scroll to the bottom and confirm the last item is fully readable
- **FAB screens** (main, item detail, group detail, tag detail): FAB is fully visible and tappable — not overlapping the nav bar

Known static review findings to watch for on device:
- **Summary**: toolbar may not receive the top inset on all devices
- **Settings / Barcode list / Premium**: previously reported inset defects are fixed; verify there is no toolbar gap or nav bar overlap

### Step 5 — Report

Output a table:

```
Screen        | Status | Notes
--------------|--------|------
main          | PASS   | FAB at 12dp above nav bar, tabs clear
drawer        | PASS   | Header avatar starts at 88px (below 72px status bar)
detail_item   | PASS   | Delete button visible, Save FAB clear of nav bar
detail_group  | PASS   |
detail_tag    | PASS   |
import_export | PASS   | Import Start button fully visible
user_settings | PASS   | Toolbar fills status bar, Delete Account row visible
summary       | WARN   | Toolbar gap (see Issue 3 in report)
premium       | PASS   | Close button and Subscribe/Manage button clear of system bars
barcode_list  | PASS   | Toolbar fills status bar, last row visible above nav bar
search        | PASS   |
```

Save screenshots to `/tmp/ui_test_results/` and report the path.

## Notes

- This command requires ADB MCP to be configured and active (see `.claude/settings.json`)
- Requires a physical device or emulator with `adb devices` showing a connected device
- The app must be installed — use `cd android && ./gradlew installDebug` to install the debug build
- For edge-to-edge testing, use a device running Android 10+ (gesture navigation) or Android 15 (enforced edge-to-edge)
- Static review findings for this screen set are tracked alongside the relevant issue on GitHub (search the issue tracker for `edge-to-edge`).
