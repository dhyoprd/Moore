# Installing Moore on your iPhone — runbook (ticket #41)

The repeatable Mac-side sequence for getting Moore onto the builder's physical
iPhone, plus the on-device checklist that mirrors the ticket's acceptance
criteria. Everything up to step 3 is already green in CI on every push
(`.github/workflows/verify.yml`: all 12 Node contract verifiers + the Android
`:core` parity suite), so a red baseline means "fix before installing".

Signing setup lives in `project.yml` + `Signing.xcconfig` (ticket #41):
automatic development signing (`CODE_SIGN_STYLE: Automatic`), bundle id
`com.dhyoprd.moore`, iOS 17.0 deployment target, and `DEVELOPMENT_TEAM`
injected via `MOORE_DEV_TEAM` so your team ID never touches a tracked file.

## What you need

- Mac with Xcode 15+ (iOS 17 SDK).
- iPhone on iOS 17+, its cable, and your Apple ID. A **free personal team**
  is sufficient — no paid developer account needed for one device.

## 1. One-time setup (~5 min, per Mac)

1. Install XcodeGen:

   ```sh
   brew install xcodegen
   ```

2. Clone (or pull) the repo:

   ```sh
   git clone https://github.com/dhyoprd/Moore.git
   cd Moore
   ```

3. Find your **Team ID** (10 characters): sign in at
   [developer.apple.com/account](https://developer.apple.com/account) →
   *Membership details* → *Team ID*. (With a free personal team the same ID
   shows in Xcode → Settings → Accounts once your Apple ID is added.)

4. Inject it **without editing any tracked file** — create the gitignored
   local xcconfig:

   ```sh
   echo "MOORE_DEV_TEAM = XXXXXXXXXX" > MooreApp/Signing.local.xcconfig
   ```

   `Signing.xcconfig` (committed) maps `MOORE_DEV_TEAM` → `DEVELOPMENT_TEAM`
   for Debug and Release, so the value survives every `xcodegen generate`.
   *Prefer to skip this?* You can instead pick your team once in Xcode's
   Signing & Capabilities (step 3.4) — but then you must re-pick it after
   each re-generate.

## 2. Generate the Xcode project

```sh
cd MooreApp
xcodegen generate
```

## 3. Install on the iPhone (primary path: Xcode ⌘R)

1. On the iPhone: **Settings → Privacy & Security → Developer Mode → ON**
   (required since iOS 16; the phone may reboot once). Plug into the Mac and
   tap *Trust* on the phone.
2. `open MooreApp.xcodeproj`
3. Select the **MooreApp** scheme and your iPhone as the run destination.
4. If Xcode reports a signing error: *MooreApp target → Signing &
   Capabilities → Team* → pick your personal team (one tap; it writes the
   generated project, which is fine). With step 1.4 done, this is already set.
5. **⌘R.** Xcode signs, installs, and launches Moore. If the phone shows
   *Untrusted Developer* on first manual launch: Settings → General → VPN &
   Device Management → trust your profile.

Notes:

- **Free-team expiry:** a free personal team signs for **7 days**; after that
  the app stops launching until you plug in and ⌘R again (data survives).
- **Headless alternative (optional):** `brew install fastlane ios-deploy`,
  then `cd MooreApp && fastlane build_and_install` — builds the
  development-signed IPA and installs it on the connected device via
  `ios-deploy`. Same signing prerequisites; the manual ⌘R path stays primary.
- **Archive / Ad Hoc alternative:** Product → Archive, then Organizer →
  Distribute App → Release Testing (development). Only worth it if you want a
  distributable `.ipa`; for one personal device, ⌘R is strictly simpler.

## 4. On-device checklist — ticket #41 acceptance criteria

Tick each box on the device. Facts about the current build, so you know what
"expected" means:

- First boot applies migration chain **0001–0011** in order, verifies all 11
  identifiers, then seeds the built-in exercise library — all before anything
  renders. Any failure shows the `foundation.db.*` recovery copy instead of Home.
- Cue delivery (notification/sound/haptic) is the **#29 seam wired to the
  recording spy** (#33); the rest overlay is visual-only. So no system
  notification prompt is expected from this build — AC #2 below checks the
  actual device behavior and records that gap.
- A killed process re-attaches in `noRest`: the session and logged sets come
  back from SQLite, but a mid-rest timer intentionally restarts fresh.

### AC checklist

- [ ] **AC1 — installs & launches on the physical iPhone.** ⌘R succeeds, the
      app icon appears, Moore launches without crashing, and first boot lands
      on the empty Home with the single "Create your first routine" CTA
      (= migrations + seed applied, boot integrity check passed). No
      `foundation.db.*` recovery screen.
- [ ] **AC2 — rest-end behavior while locked/backgrounded mid-session.**
      Create a routine → start a session → log one set → rest overlay starts →
      immediately lock the phone (side button) and wait past the rest
      duration, then unlock and reopen. Record: did a notification permission
      prompt or banner appear? (Not expected in this build — spy seam.) Is the
      session intact, with the overlay at "Rest over" / expired correctly
      rather than reset or crashed?
- [ ] **AC3a — full workout survives suspension.** Mid-session, swipe up to
      background the app, wait ~30–60 s, reopen: active session restored with
      the mini-player, logged sets intact, rest countdown wall-clock correct
      (it's `expiresAt`-based, not tick-based).
- [ ] **AC3b — full workout survives a kill.** Mid-session, force-quit from
      the app switcher, relaunch: active session cold re-read from SQLite,
      logged sets intact (rest restarts fresh by design — see facts above).
- [ ] **Battery sanity.** After the session, check Settings → Battery: drain
      over the workout is acceptable (rule of thumb ≲ 20% for a ~1 h session)
      and there is no noticeable background drain afterwards.
- [ ] **AC4 — money screen legible, mis-tap-free, real thumbs, gym lighting.**
      During the real session: set numbers/plate math readable under gym
      lighting at a glance; ✓ / edit targets hit reliably with thumbs; no
      mis-taps on adjacent rows.
- [ ] **AC5 — one genuine training session end-to-end.** Start → log every
      set (including at least one rest period) → Finish → plan-vs-actual
      summary lands. This is the "can I actually train with it" checkpoint.

## 5. Troubleshooting

| Symptom | Fix |
| --- | --- |
| "Signing requires a development team" | Pick your team in Signing & Capabilities, or set `MOORE_DEV_TEAM` in `MooreApp/Signing.local.xcconfig` and re-run `xcodegen generate`. |
| Provisioning / bundle-id error | Bundle id is `com.dhyoprd.moore`; if it ever collides, change `PRODUCT_BUNDLE_IDENTIFIER` (+ `bundleIdPrefix`) in `project.yml` and regenerate. |
| App stops launching after a week | Free-team 7-day expiry — plug in, ⌘R again. |
| "Please update your iPhone…" / install fails | Developer Mode off, or iOS < 17. |
| Team choice lost after `xcodegen generate` | Expected (project is regenerated) — `MOORE_DEV_TEAM` in `Signing.local.xcconfig` makes it permanent. |
| iPhone not listed as destination | Try another cable/port, re-tap *Trust*, check Window → Devices and Simulators. |

## Data notes

- The database is `<Application Support>/Moore/moore.sqlite` (keyed by bundle
  id). Re-running ⌘R over an existing install keeps your data; deleting the
  app wipes it.
- Changing the bundle id starts a fresh database — treat it as a reinstall.
