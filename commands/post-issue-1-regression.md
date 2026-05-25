---
description: Post-Issue-1 manual emulator regression playbook — drives ADB MCP through the Android 15 (API 35) checklist scoped to changes that landed since PR #36
---

# /post-issue-1-regression

Deterministic manual-emulator regression playbook scoped to the risk surface that
accumulated on `develop` after PR #36 closed Issue #1 with `status:needs-test`.
Drives ADB MCP automation where possible and explicitly flags steps that need
owner sign-off (real-money billing, release-keystore auth, dashboard checks).

This command is a **spec** — it defines WHAT to test and WHEN each step is run.
The ADB MCP wrapper that implements the HOW (per-step commands, artifact capture,
auto-issue-on-failure) lands in a companion PR. Until then, a human runs this
playbook on a connected Mac with ADB MCP and uses the step IDs below to label
artifacts.

## When to use

Run after a non-trivial change to any subsystem named in issue #466's risk list
(Activity/DetailActivity cluster, `Util`/`UtilPremium`, Firebase Auth, Realm
models, locale handling, vibration, Crashlytics telemetry, edge-to-edge insets)
and before tagging a release. The playbook is intentionally separate from
`/ui-test` (which is a fast inset smoke check) and from `/regression` (which is a
static code scan). This is the long-form on-device regression matrix.

## Prerequisites

- Android 15 (API 35) emulator running locally (`adb devices` lists it).
- ADB MCP server configured per `android/CLAUDE.md` § "ADB MCP UI Testing".
- Debug build installed: `cd android && ./gradlew installDebug`.
- For steps marked `semi`: owner-provided test account credentials and/or the
  release keystore staged out-of-band.
- For step 9 (`semi`): the pre-Issue-1 APK (commit at PR #36 merge) staged at a
  local path the owner shares before the run.

## Run-id convention

Use a UTC timestamp matching the agent-codename pattern from `AGENTS.md`
(`POST1-<YYYYMMDDTHHMMSSZ>`, e.g. `POST1-20260518T135937Z`). All artifacts for a
single playbook execution live under
`build/regression-artifacts/<run-id>/<step-id>/`. The run-id is stated in the
first user-facing line of the run output.

## Steps

The 10 steps below are copied verbatim from issue #466 and re-formatted with a
stable Step ID, an automation tier, acceptance criteria, and an artifact path.

Automation tiers:

- `auto` — Mac Claude + ADB MCP can run autonomously, no human in the loop.
- `semi` — needs an owner-provided artefact (test account, keystore, pre-built
  APK) staged before the run; automation then proceeds.
- `manual` — real-money or device-physical action; owner sign-off required
  before money moves or hardware is exercised.

---

### STEP-1-COLD-START — Cold start + Android 15 smoke

- **Tier:** `auto`
- **From issue #466:** Issue #1 AC #2, #5
- **Checks:**
  - [ ] `adb install -r` debug APK on emulator at API 35
  - [ ] Launch app; verify `MainActivity` reaches the inventory list without
    `FATAL EXCEPTION` in logcat
  - [ ] No `StrictMode` violations from edge-to-edge enforcement
- **Acceptance criteria:**
  - App reaches inventory list within 10 s of `am start`.
  - `logcat -d -b crash` is empty for the app PID.
  - No `StrictMode policy violation` entries in logcat for the run window.
- **Artifact:** `build/regression-artifacts/<run-id>/STEP-1-COLD-START/`
  containing `screenshot-main.png`, `logcat.txt`, `logcat-crash.txt`.

### STEP-2-EDGE-TO-EDGE — Edge-to-edge / system bars

- **Tier:** `auto`
- **From issue #466:** Issue #1 AC #3, audit residual
- **Checks:**
  - [ ] `MainActivity`: status-bar icons readable in both light and dark theme;
    nav-bar inset applied to bottom of list
  - [ ] Detail activities (`ItemDetailActivity`, `GroupDetailActivity`,
    `TagDetailActivity`): toolbar not under status bar; FAB not under nav bar
  - [ ] `PremiumActivity`: scrollable content reaches above nav bar; no clipping
  - [ ] `UserSettingsActivity`, `SettingsActivity`, `ImportExportActivity`,
    `SearchActivity`, `SummaryActivity`, `ContactUsActivity`, `AboutUsActivity`:
    status bar inset present on first frame
- **Acceptance criteria:**
  - For each screen above, the toolbar/top element is not occluded by the status
    bar and the FAB/bottom element clears the nav bar on first frame.
  - Both light and dark theme captured for `MainActivity`.
- **Artifact:** `build/regression-artifacts/<run-id>/STEP-2-EDGE-TO-EDGE/`
  containing per-screen `screenshot-<activity>-{light,dark}.png` plus
  `uihierarchy-<activity>.xml` dumps.

### STEP-3-PREDICTIVE-BACK — Predictive back gesture

- **Tier:** `auto`
- **From issue #466:** Issue #1 AC #4
- **Checks:**
  - [ ] System gesture nav: enable "Predictive back animations" in developer
    options
  - [ ] From `ItemDetailActivity` → back gesture → animation visible → returns
    to caller without crash
  - [ ] Same for `GroupDetailActivity`, `TagDetailActivity`, `PremiumActivity`
  - [ ] In-flight edits in detail screen: unsaved-changes dialog still triggered
    by predictive back
- **Acceptance criteria:**
  - All four detail/premium screens return to caller after a back gesture with
    no `FATAL EXCEPTION` in logcat.
  - Detail screen with a dirty edit field shows the unsaved-changes dialog
    before the back transition completes.
- **Artifact:** `build/regression-artifacts/<run-id>/STEP-3-PREDICTIVE-BACK/`
  containing `screenrecord-<activity>.mp4` (or per-frame screenshots) and
  `logcat.txt`.

### STEP-4-IME-INSETS — IME / keyboard insets

- **Tier:** `auto`
- **From issue #466:** issue #167 regression target
- **Checks:**
  - [ ] Open `ItemDetailActivity`, focus the name field → keyboard pushes scroll
    content up, toolbar stays pinned, FAB reachable above keyboard
  - [ ] Rotate to landscape → same behaviour
  - [ ] Repeat for `GroupDetailActivity` and `TagDetailActivity`
- **Acceptance criteria:**
  - In both portrait and landscape, on each of the three detail activities,
    the toolbar remains visible while the IME is open and the FAB is not
    occluded by the keyboard.
- **Artifact:** `build/regression-artifacts/<run-id>/STEP-4-IME-INSETS/`
  containing `screenshot-<activity>-{portrait,landscape}-ime.png` and
  `dumpsys-input-method.txt`.

### STEP-5-BILLING — Billing / Premium

- **Tier:** `manual` — real money / Play Console internal-test track; owner
  sign-off required before money moves
- **From issue #466:** Issue #1 constraint: must not break
- **Checks:**
  - [ ] `PremiumActivity` loads with all subscription tiers visible
  - [ ] `BillingClient` connects (logcat shows `onBillingSetupFinished` OK)
  - [ ] Initiate a test purchase via Play Console internal-test track or
    `BILLING_RESPONSE_RESULT_OK` mock → `User.isOneTimePayment` /
    `User.isSubscriber` flips correctly
  - [ ] Restore purchase flow: launch with existing entitlement → premium UI
    shown without re-purchase
  - [ ] XOR-encoded `User` fields decode correctly after restore (verify via
    Crashlytics telemetry from #308)
- **Acceptance criteria:**
  - Owner explicitly confirms the run is approved before purchase is initiated.
  - Purchase flips the entitlement flag on the Realm `User` row; restore on a
    fresh install reproduces the entitlement without a second charge.
- **Artifact:** `build/regression-artifacts/<run-id>/STEP-5-BILLING/`
  containing `screenshot-premium.png`, `logcat-billing.txt`, and an
  `owner-signoff.txt` recording the approving owner and timestamp.

### STEP-6-FIREBASE-AUTH — Firebase Auth

- **Tier:** `semi` — debug build can be `auto` with a test account; release
  build needs the keystore staged out-of-band
- **From issue #466:** issue #275 — mandatory upgrade gate
- **Checks:**
  - [ ] Email/password sign-in on **debug** build → success
  - [ ] Email/password sign-in on **release** build → success
  - [ ] Google sign-in on debug + release
  - [ ] Sign-out and account-delete on a dedicated test account
  - [ ] `firebase-auth:23.0.0` + `firebase-ui-auth:8.0.2` consistency check via
    `./gradlew :smartinventory:dependencies --configuration releaseRuntimeClasspath | grep firebase`
    — paste output in playbook artifact
- **Acceptance criteria:**
  - All four sign-in paths complete without `FATAL EXCEPTION`.
  - The dependency grep output shows `firebase-auth:23.0.0` and
    `firebase-ui-auth:8.0.2` aligned with `gradle/libs.versions.toml`.
- **Artifact:** `build/regression-artifacts/<run-id>/STEP-6-FIREBASE-AUTH/`
  containing `screenshot-signin-<variant>.png`, `logcat-auth.txt`, and
  `dependencies-firebase.txt`.

### STEP-7-LOCALE-SWITCH — Locale switching

- **Tier:** `auto`
- **From issue #466:** issue #215 — Android 13+ per-app language
- **Checks:**
  - [ ] System Settings → Apps → SmartInventory → Language → pick each of the 9
    locales (en/de/es/fr/it/pl/pt/ru/tr)
  - [ ] Each locale changes UI without app restart; `MainActivity` reads
    correct strings; numeric formatting respects locale
- **Acceptance criteria:**
  - All 9 locales render `MainActivity` strings in the picked language without
    a process restart and without falling back to English.
- **Artifact:** `build/regression-artifacts/<run-id>/STEP-7-LOCALE-SWITCH/`
  containing `screenshot-main-<locale>.png` for each of the 9 locales.

### STEP-8-VIBRATION — Vibration

- **Tier:** `auto`
- **From issue #466:** issue #372 — VibrationEffect migration
- **Checks:**
  - [ ] Trigger any code path calling `Util.vibrate()` (e.g. successful scan in
    `ContQRScanActivity`)
  - [ ] Device vibrates; no `VibrationEffect` deprecation warnings on API 35
- **Acceptance criteria:**
  - `dumpsys vibrator` (or equivalent) confirms the vibrator was driven during
    the trigger window.
  - Logcat shows no `VibrationEffect`-related deprecation warnings.
- **Artifact:** `build/regression-artifacts/<run-id>/STEP-8-VIBRATION/`
  containing `dumpsys-vibrator.txt` and `logcat-vibration.txt`.

### STEP-9-REALM-MIGRATION — Realm migration smoke

- **Tier:** `semi` — needs the pre-Issue-1 APK staged at a path the owner
  shares before the run
- **From issue #466:** CLAUDE.md mandate before any model-touching PR
- **Checks:**
  - [ ] Install pre-Issue-1 APK on a clean emulator → seed items/groups/tags
    via UI
  - [ ] Upgrade-install current APK → all data visible; no crash on
    `MainActivity` cold-start
  - [ ] Run `./gradlew connectedAndroidTest --tests "*RealmUpgradePathTest" --tests "*RealmFreshInstallTest"`
- **Acceptance criteria:**
  - Seeded items, groups, and tags are all visible after the upgrade install.
  - Both `RealmUpgradePathTest` and `RealmFreshInstallTest` complete green
    against the running emulator.
- **Artifact:** `build/regression-artifacts/<run-id>/STEP-9-REALM-MIGRATION/`
  containing `screenshot-before-upgrade.png`, `screenshot-after-upgrade.png`,
  `connectedAndroidTest-report/`, and `pre-issue-1-apk-sha256.txt`.

### STEP-10-CRASHLYTICS-TELEMETRY — Crashlytics telemetry additions

- **Tier:** `semi` — forcing the permission-revoke and billing-disconnect
  triggers is automatable from the Mac; verifying the entry appears in the
  Crashlytics web dashboard is not automatable and needs owner sign-off
- **From issue #466:** #303 #304 #308 #315 #316
- **Checks:**
  - [ ] Force an `UtilImportExport` write failure (e.g. revoke storage
    permission mid-export) → Crashlytics records non-fatal; export flow still
    recovers gracefully
  - [ ] Force a billing `BillingClient` disconnect mid-purchase → telemetry
    recorded; UI shows error snackbar
- **Acceptance criteria:**
  - Each forced failure surfaces a user-facing recovery path (snackbar/dialog),
    not a crash.
  - Owner confirms the corresponding non-fatal entries appear in the
    Crashlytics dashboard within the standard reporting window.
- **Artifact:** `build/regression-artifacts/<run-id>/STEP-10-CRASHLYTICS-TELEMETRY/`
  containing `screenshot-snackbar-<scenario>.png`, `logcat-crashlytics.txt`,
  and `owner-dashboard-confirmation.txt`.

### STEP-11-POST-NOTIFICATIONS — POST_NOTIFICATIONS runtime permission

- **Tier:** `semi` — install / launch / kill / `uiautomator dump` /
  `logcat` capture are automatable from the Mac via ADB MCP; the real FCM push
  trigger needs owner sign-off to fire from the Firebase Console
- **From issue #892:** PR #875 (issue #872) added
  `MainActivity.requestPostNotificationsPermissionIfNeeded()` — the canonical
  Tiramisu-guarded prompt with a `SharedPreferences`-backed "Don't ask again"
  state machine and a `Util.logEvent(...)` grant/deny event pipeline. None of
  these are exercised by STEP-1..STEP-10; this step adds the regression
  matrix.
- **Common prerequisites:**
  - Debug APK built at `android/smartinventory/build/outputs/apk/debug/smartinventory-debug.apk`
    (`./gradlew :smartinventory:assembleDebug`).
  - For 11.3 specifically: the last released APK at `versionCode 82` staged
    out-of-band by the owner before the run.
  - All emulator state wipes use `adb shell pm clear com.nonzeroapps.android.smartinventory`
    so the ADB MCP can sequence scenarios without a full emulator cold-wipe.

#### 11.1 Fresh install on Android 13+ emulator (API 33+)

- **Tier:** `semi` — install/launch/dump are `auto`; the FCM push trigger is
  owner sign-off
- **Checks:**
  - [ ] `adb shell pm clear com.nonzeroapps.android.smartinventory` on a clean
    API 33+ emulator to guarantee a fresh permission state
  - [ ] `adb install -r android/smartinventory/build/outputs/apk/debug/smartinventory-debug.apk`
  - [ ] `adb shell am start -n com.nonzeroapps.android.smartinventory/.activity.MainActivity`
  - [ ] Expect the system "Send you notifications" prompt visible within 2 s
    of `onCreate`; `adb shell uiautomator dump /sdcard/11.1-prompt.xml &&
    adb pull /sdcard/11.1-prompt.xml build/regression-artifacts/<run-id>/STEP-11-POST-NOTIFICATIONS/11.1-prompt.xml`
  - [ ] **Allow path:** tap **Allow** via
    `adb shell input tap <x> <y>` against the resolved bounds → owner triggers
    an FCM test push from the Firebase Console → confirm the notification
    appears in the shade
  - [ ] `adb shell uiautomator dump /sdcard/11.1-granted.xml && adb pull
    /sdcard/11.1-granted.xml build/regression-artifacts/<run-id>/STEP-11-POST-NOTIFICATIONS/11.1-granted.xml`
  - [ ] `adb logcat -d` should show a
    `Util.logEvent("post_notifications_granted", …)` entry forwarded to
    Firebase Analytics; capture under
    `build/regression-artifacts/<run-id>/STEP-11-POST-NOTIFICATIONS/11.1-logcat-granted.txt`
  - [ ] `adb shell screencap -p /sdcard/11.1-granted.png && adb pull
    /sdcard/11.1-granted.png build/regression-artifacts/<run-id>/STEP-11-POST-NOTIFICATIONS/11.1-granted.png`
  - [ ] **Deny path:** repeat
    `adb shell pm clear` + `adb install -r` + `am start` → tap **Don't allow**
    → owner re-triggers the FCM push → confirm NO notification appears and
    `adb logcat -d | grep post_notifications_denied` shows
    `Util.logEvent("post_notifications_denied", …)`; app MUST NOT crash on
    denial
  - [ ] Capture deny-path UI dump + logcat under
    `build/regression-artifacts/<run-id>/STEP-11-POST-NOTIFICATIONS/11.1-denied.xml`,
    `…/11.1-denied.png`, and `…/11.1-logcat-denied.txt`
- **Acceptance criteria:**
  - Allow path: notification appears in the shade after the owner-triggered
    FCM push; `post_notifications_granted` event present in logcat.
  - Deny path: no notification in the shade; `post_notifications_denied`
    event present in logcat; `adb logcat -d -b crash` empty for the app PID.
- **Artifact:** `build/regression-artifacts/<run-id>/STEP-11-POST-NOTIFICATIONS/`
  containing `11.1-prompt.xml`, `11.1-granted.xml`, `11.1-granted.png`,
  `11.1-logcat-granted.txt`, `11.1-denied.xml`, `11.1-denied.png`, and
  `11.1-logcat-denied.txt`.

#### 11.2 Fresh install on Android 12 emulator (API 32)

- **Tier:** `semi` — install/launch/dump are `auto`; the FCM push trigger is
  owner sign-off
- **Checks:**
  - [ ] `adb shell pm clear com.nonzeroapps.android.smartinventory` on a clean
    API 32 emulator
  - [ ] `adb install -r android/smartinventory/build/outputs/apk/debug/smartinventory-debug.apk`
  - [ ] `adb shell am start -n com.nonzeroapps.android.smartinventory/.activity.MainActivity`
  - [ ] Expect **NO** permission prompt (auto-granted on pre-Tiramisu); the
    Tiramisu guard in `requestPostNotificationsPermissionIfNeeded()` should
    short-circuit
  - [ ] `adb shell uiautomator dump /sdcard/11.2-no-prompt.xml && adb pull
    /sdcard/11.2-no-prompt.xml build/regression-artifacts/<run-id>/STEP-11-POST-NOTIFICATIONS/11.2-no-prompt.xml`
    and confirm the dump contains the `MainActivity` inventory list, not a
    permission dialog
  - [ ] Owner triggers an FCM test push from the Firebase Console →
    notification appears in the shade
  - [ ] `adb shell screencap -p /sdcard/11.2-shade.png && adb pull
    /sdcard/11.2-shade.png build/regression-artifacts/<run-id>/STEP-11-POST-NOTIFICATIONS/11.2-shade.png`
  - [ ] `adb logcat -d` MUST NOT contain any
    `requestPermissions(...POST_NOTIFICATIONS...)` call; capture under
    `build/regression-artifacts/<run-id>/STEP-11-POST-NOTIFICATIONS/11.2-logcat.txt`
- **Acceptance criteria:**
  - No permission dialog is rendered on first launch.
  - Owner-triggered FCM push delivers a notification visible in the shade.
  - Logcat shows no `POST_NOTIFICATIONS` permission request.
- **Artifact:** `build/regression-artifacts/<run-id>/STEP-11-POST-NOTIFICATIONS/`
  containing `11.2-no-prompt.xml`, `11.2-shade.png`, and `11.2-logcat.txt`.

#### 11.3 Existing-user upgrade simulation

- **Tier:** `semi` — needs the `versionCode 82` master APK staged out-of-band
  by the owner before the run; FCM push trigger also needs owner sign-off
- **Checks:**
  - [ ] `adb shell pm clear com.nonzeroapps.android.smartinventory` on a clean
    Android 14 (API 34) emulator
  - [ ] `adb install -r <path-to-versionCode-82>.apk` (the last released APK
    from `master`, staged out-of-band)
  - [ ] `adb shell am start -n com.nonzeroapps.android.smartinventory/.activity.MainActivity`
    → grant any prompts the legacy build raises → `adb shell am force-stop
    com.nonzeroapps.android.smartinventory`
  - [ ] Side-load the current develop APK over the top: `adb install -r
    android/smartinventory/build/outputs/apk/debug/smartinventory-debug.apk`
  - [ ] `adb shell am start -n com.nonzeroapps.android.smartinventory/.activity.MainActivity`
  - [ ] Expect **NO** duplicate `POST_NOTIFICATIONS` prompt (the OS preserves
    the prior grant across the upgrade install)
  - [ ] `adb shell uiautomator dump /sdcard/11.3-no-reprompt.xml && adb pull
    /sdcard/11.3-no-reprompt.xml build/regression-artifacts/<run-id>/STEP-11-POST-NOTIFICATIONS/11.3-no-reprompt.xml`
    and confirm the dump contains `MainActivity`, not a permission dialog
  - [ ] Owner triggers an FCM test push from the Firebase Console →
    notification appears in the shade
  - [ ] `adb shell screencap -p /sdcard/11.3-shade.png && adb pull
    /sdcard/11.3-shade.png build/regression-artifacts/<run-id>/STEP-11-POST-NOTIFICATIONS/11.3-shade.png`
  - [ ] `adb logcat -d` captured under
    `build/regression-artifacts/<run-id>/STEP-11-POST-NOTIFICATIONS/11.3-logcat.txt`
    must NOT show a `requestPermissions(...POST_NOTIFICATIONS...)` call from
    the upgraded build
- **Acceptance criteria:**
  - No re-prompt on upgrade; the OS-preserved grant carries forward.
  - Owner-triggered FCM push delivers a notification after the upgrade.
  - Seeded items / groups / tags from STEP-9 conventions remain visible if
    the run is combined with STEP-9 (no Realm data loss).
- **Artifact:** `build/regression-artifacts/<run-id>/STEP-11-POST-NOTIFICATIONS/`
  containing `11.3-no-reprompt.xml`, `11.3-shade.png`, `11.3-logcat.txt`,
  and a `11.3-pre-upgrade-apk-sha256.txt` recording the staged APK hash.

#### 11.4 Don't-ask-again terminal path

- **Tier:** `auto` — fully scriptable via ADB; no FCM push required
- **Checks:**
  - [ ] `adb shell pm clear com.nonzeroapps.android.smartinventory` on a clean
    Android 14 (API 34) emulator
  - [ ] `adb install -r android/smartinventory/build/outputs/apk/debug/smartinventory-debug.apk`
  - [ ] First launch: `adb shell am start -n
    com.nonzeroapps.android.smartinventory/.activity.MainActivity` → tap
    **Don't allow** → `adb shell uiautomator dump /sdcard/11.4-deny-1.xml &&
    adb pull /sdcard/11.4-deny-1.xml build/regression-artifacts/<run-id>/STEP-11-POST-NOTIFICATIONS/11.4-deny-1.xml`
  - [ ] `adb shell am force-stop com.nonzeroapps.android.smartinventory`
  - [ ] Second launch: `adb shell am start -n
    com.nonzeroapps.android.smartinventory/.activity.MainActivity` → tap
    **Don't allow** a second time → `adb shell uiautomator dump
    /sdcard/11.4-deny-2.xml && adb pull /sdcard/11.4-deny-2.xml
    build/regression-artifacts/<run-id>/STEP-11-POST-NOTIFICATIONS/11.4-deny-2.xml`
  - [ ] `adb shell am force-stop com.nonzeroapps.android.smartinventory`
  - [ ] Third launch: `adb shell am start -n
    com.nonzeroapps.android.smartinventory/.activity.MainActivity` → expect
    **NO prompt** (OS sets `shouldShowRequestPermissionRationale == false`
    and the persisted `post_notifications_prompted = true` flag in the
    `post_notifications_prefs` SharedPreferences file causes the canonical
    entry-point to bail out)
  - [ ] `adb shell uiautomator dump /sdcard/11.4-no-prompt.xml && adb pull
    /sdcard/11.4-no-prompt.xml build/regression-artifacts/<run-id>/STEP-11-POST-NOTIFICATIONS/11.4-no-prompt.xml`
    and confirm the dump contains `MainActivity`, not a permission dialog
  - [ ] `adb shell screencap -p /sdcard/11.4-no-prompt.png && adb pull
    /sdcard/11.4-no-prompt.png build/regression-artifacts/<run-id>/STEP-11-POST-NOTIFICATIONS/11.4-no-prompt.png`
  - [ ] `adb logcat -d` MUST NOT show a
    `requestPermissions(...POST_NOTIFICATIONS...)` call on the third launch
    and MUST NOT show any `Util.logEvent("post_notifications_…")` entry from
    this launch window; capture under
    `build/regression-artifacts/<run-id>/STEP-11-POST-NOTIFICATIONS/11.4-logcat.txt`
  - [ ] Verify the persisted flag via
    `adb shell run-as com.nonzeroapps.android.smartinventory cat
    shared_prefs/post_notifications_prefs.xml` and confirm
    `post_notifications_prompted=true`; capture under
    `build/regression-artifacts/<run-id>/STEP-11-POST-NOTIFICATIONS/11.4-prefs.xml`
- **Acceptance criteria:**
  - Third launch raises no permission dialog.
  - No `requestPermissions` call and no
    `post_notifications_{granted,denied}` analytics event in the third-launch
    logcat window.
  - `post_notifications_prefs.xml` contains
    `post_notifications_prompted=true`.
- **Artifact:** `build/regression-artifacts/<run-id>/STEP-11-POST-NOTIFICATIONS/`
  containing `11.4-deny-1.xml`, `11.4-deny-2.xml`, `11.4-no-prompt.xml`,
  `11.4-no-prompt.png`, `11.4-logcat.txt`, and `11.4-prefs.xml`.

#### 11.5 Edge case: process death during prompt (defensive characterisation)

- **Tier:** `auto` — fully scriptable via ADB; this is a
  **defensive characterisation, not a pass/fail gate** per the known
  trade-off documented in `MainActivity.requestPostNotificationsPermissionIfNeeded()`
  KDoc and in issue #872. Record the observed behaviour as a known
  limitation; do NOT open a regression issue if the user is not re-prompted.
- **Checks:**
  - [ ] `adb shell pm clear com.nonzeroapps.android.smartinventory` on a clean
    API 33+ emulator
  - [ ] `adb install -r android/smartinventory/build/outputs/apk/debug/smartinventory-debug.apk`
  - [ ] `adb shell am start -n com.nonzeroapps.android.smartinventory/.activity.MainActivity`
    → wait for the permission dialog to render
  - [ ] `adb shell uiautomator dump /sdcard/11.5-prompt-visible.xml && adb
    pull /sdcard/11.5-prompt-visible.xml
    build/regression-artifacts/<run-id>/STEP-11-POST-NOTIFICATIONS/11.5-prompt-visible.xml`
    to confirm the dialog was on-screen at the moment of kill
  - [ ] In a second terminal (or chained ADB call): `adb shell kill -9
    $(adb shell pidof com.nonzeroapps.android.smartinventory)` to simulate
    an OOM kill while the dialog is up

    > `am kill` only terminates background/cached processes and will
    > silently no-op while the permission dialog is showing in the
    > foreground. The `kill -9 $(pidof …)` form sends SIGKILL directly to
    > the foreground process — the closest ADB-accessible approximation of
    > an OOM kill.
  - [ ] Re-launch: `adb shell am start -n
    com.nonzeroapps.android.smartinventory/.activity.MainActivity`
  - [ ] **Expected per known trade-off** (documented in
    `MainActivity.requestPostNotificationsPermissionIfNeeded()` KDoc and in
    issue #872): the user is **not** re-prompted on next launch because the
    `post_notifications_prompted` flag is persisted to SharedPreferences
    *before* `ActivityCompat.requestPermissions` is called, precisely to
    survive process death and avoid loop-prompting. The remediation (an
    in-app "enable notifications" surface) is deferred to a future
    "Notification settings" screen.
  - [ ] `adb shell uiautomator dump /sdcard/11.5-after-kill.xml && adb pull
    /sdcard/11.5-after-kill.xml build/regression-artifacts/<run-id>/STEP-11-POST-NOTIFICATIONS/11.5-after-kill.xml`
  - [ ] `adb shell screencap -p /sdcard/11.5-after-kill.png && adb pull
    /sdcard/11.5-after-kill.png build/regression-artifacts/<run-id>/STEP-11-POST-NOTIFICATIONS/11.5-after-kill.png`
  - [ ] `adb logcat -d` captured under
    `build/regression-artifacts/<run-id>/STEP-11-POST-NOTIFICATIONS/11.5-logcat.txt`
  - [ ] Write a one-line characterisation note to
    `build/regression-artifacts/<run-id>/STEP-11-POST-NOTIFICATIONS/11.5-known-limitation.txt`
    in the form `KNOWN LIMITATION (#872): no re-prompt after
    process-death-during-prompt; remediation deferred to in-app
    "Notification settings" screen.`
- **Acceptance criteria:**
  - This scenario has no pass/fail gate.
  - The artifact bundle MUST exist and MUST include
    `11.5-known-limitation.txt` recording the observed behaviour.
  - If — and only if — the observed behaviour deviates from the documented
    trade-off (e.g. the app crashes on relaunch, or an unexpected re-prompt
    fires), open a regression issue per the standard "On failure" section
    below.
- **Artifact:** `build/regression-artifacts/<run-id>/STEP-11-POST-NOTIFICATIONS/`
  containing `11.5-prompt-visible.xml`, `11.5-after-kill.xml`,
  `11.5-after-kill.png`, `11.5-logcat.txt`, and
  `11.5-known-limitation.txt`.

---

## On failure

Failure handling is **continue, don't abort**. For each failing step:

1. Capture the step's artifact bundle under
   `build/regression-artifacts/<run-id>/<step-id>/` exactly as the success path
   would, so the bundle exists regardless of pass/fail.
2. Open a draft GitHub issue via `gh issue create --draft` with:
   - Title: `regression: <STEP-ID> failed on run <run-id>`
   - Body: a one-line repro pointing at the run-id, the step ID, the failing
     acceptance criterion, and the artifact path.
   - Attach the artifact bundle (or upload the screenshot/logcat slice) to the
     issue.
   - Label: `regression`, `type:testing`, plus the platform label (`android`)
     and any severity label per `AGENTS.md § Issue Label Taxonomy`.
3. Continue to the next step in the playbook. Do NOT abort the run — the value
   of a regression playbook is the full pass/fail matrix, not a fast exit.

Implementation note: the `gh issue create` wrapper that performs steps 1–3
automatically ships in a companion PR. Until then, a human running this
playbook performs steps 1–3 by hand using the templates above.

## Cross-references

- `.claude/commands/ui-test.md` — fast inset/system-bar smoke check; this
  playbook reuses its `adb devices` + screenshot conventions.
- `.claude/commands/regression.md` — codebase-wide static regression scan; runs
  in parallel with this on-device playbook and shares the `regression` label.
- `android/CLAUDE.md` § "ADB MCP UI Testing" → "Post-Issue-1 regression
  playbook" — lists which steps a contributor can run unattended and which
  need owner sign-off.
- `AGENTS.md` § "Testing" — single-line cross-reference into this playbook.
- Source issue: #466. Origin: #1 / PR #36 (`status:needs-test`).