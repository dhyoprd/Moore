# MooreApp — iOS app shell (ticket #33)

The Xcode project is **generated**, not committed. [XcodeGen](https://github.com/yonaskolb/xcodegen)
reads `project.yml` and produces `MooreApp.xcodeproj`, which links the iOS app
target against nine products of the local Moore Swift package (every
migration-owning module plus MooreWorkout) and GRDB.

## Build (macOS + Xcode 15+)

```sh
brew install xcodegen
cd MooreApp
xcodegen generate
open MooreApp.xcodeproj
```

Then select the `MooreApp` scheme and run on an iPhone simulator or device
(iOS 17+). Signing is automatic (`CODE_SIGN_STYLE: Automatic`, bundle id
`com.dhyoprd.moore`, repo-owner namespace per ticket #41). Your Apple team ID
is injected via `Signing.xcconfig` → `MOORE_DEV_TEAM` (gitignored
`Signing.local.xcconfig`) so it never touches a tracked file. The full
on-device runbook — one-time setup, install, and the acceptance checklist —
is **INSTALL.md** (ticket #41).

On first boot the app:

1. opens a GRDB `DatabaseQueue` at `<Application Support>/Moore/moore.sqlite`,
2. applies the ONE canonical migration chain 0001–0011 in order
   (each module owns its `.sql` files; `AppDependencies.migrateFullChain`
   runs the module runners in `MigrationRunner.canonicalChainIdentifiers` order),
3. verifies all 11 identifiers landed in `grdb_migrations`,
4. seeds the built-in exercise library (idempotent, SC-exercises §5),
5. wires DAOs + view-models and injects them via the SwiftUI environment.

A migration failure renders the SC-foundation §6 recovery copy
(`foundation.db.*`); nothing half-booted reaches Home.

## Layout

```
MooreApp/
  project.yml                  XcodeGen spec (this project's source of truth)
  Signing.xcconfig             DEVELOPMENT_TEAM = $(MOORE_DEV_TEAM) (ticket #41)
  README.md                    this file
  INSTALL.md                   on-device install runbook + AC checklist (#41)
  fastlane/Fastfile            optional build_and_install lane (#41, gym+ios-deploy)
  Sources/
    MooreApp.swift             @main — boots, injects AppState
    Core/                      Foundation-only (parses off-Mac; no SwiftUI)
      AppDependencies.swift    composition root: GRDB boot + DI wiring
      AppState.swift           boot phase, tabs, Active Workout presentation + start wiring
      HomeModel.swift          drives HomeSurfaceViewModel + DAO write seams
      WorkoutSessionModel.swift #34 money-screen state: drives FSM + Materialize + RestCycle
      RoutineEditorModel.swift drives RoutineEditorBuffer + RoutineDAO
      UICopy.swift             contract UI-copy table (verbatim keys)
      DesignTokens.swift       frozen visual tokens (#17 resolution)
      CompositeCueSink.swift   #40 fan-out sink (platform + recording spy)
      CueVisualPulse.swift     #40 visual pulse surface (SC-cues INV-C3)
      RestEndNotifications.swift #40 rest-end notification scheduling seam
    Platform/                  UIKit/UserNotifications (Mac-build-only)
      PlatformCueSink.swift    #40 haptic/audio renderer (SC-cues §5 CueSink)
      RestEndNotificationScheduler.swift #40 local-notification rest-end
      MooreAppearance.swift    #40 system-bar chrome (Tier 1 shell)
    Views/                     SwiftUI (thin: layout + bindings to Core models)
      RootView.swift           4 tabs + full-screen Active Workout cover + mini-player
      HomeView.swift           Home tracer bullet (folders, rows, streak, Start empty)
      RoutineEditorSheet.swift create/edit routine sheet
      ExercisePickerSheet.swift exercise picker (search / browse / create-custom)
      ActiveWorkoutView.swift  #34 money screen (flat set list + per-set ✓)
      SetEditSheet.swift       #34 bottom-sheet edit path (steppers/unit/plate preview)
      RestOverlayView.swift    #34 ambient rest overlay + Finish-morph panel
      WorkoutSummaryView.swift #34 plan-vs-actual summary
      MiniPlayerView.swift     persistent bar above the tab bar
      HistoryView.swift        placeholder (#37) with contract empty state
      AnalyticsView.swift      placeholder (#37) with contract empty state
      SettingsView.swift       placeholder (#38) with contract section titles
      DesignSystem.swift       SwiftUI mapping of DesignTokens
```

## Notes

- **DatabaseQueue, not DatabasePool.** The frozen module DAOs (`RoutineDAO`,
  `FolderDAO`, `ExerciseDAO`, `WorkoutSessionDAO`) are typed against GRDB's
  `DatabaseQueue`; the composition root opens one on disk. The ticket's
  "DatabasePool" phrasing yields to the frozen DAO seam — the on-disk database
  in Application Support is unchanged either way.
- **Architecture rule.** All business/state logic lives in `Sources/Core`
  (Foundation-only) and the pre-existing module view-models; SwiftUI views stay
  thin. That keeps the Android port (#8) and off-Mac verification intact.
- **Active Workout (#34).** The money screen is `ActiveWorkoutView` bound to
  `WorkoutSessionModel` (Core), which DRIVES the frozen engines — never
  reimplements them: `WorkoutSessionFSM` + `Materialize` + `WorkoutSessionDAO`
  (SC-workout-logging) for set logging, `RestCycle` + `RestResolver` (SC-rest)
  for the ambient rest overlay + Finish morph. Persistence doctrine: after every
  lawful FSM transition the model persists via the DAO, then cold re-reads the
  FSM from SQLite (#9 r4); the BR-003 drop-undo window is carried by the model
  (not derivable from rows, SC-workout-logging §8).
- **Scope.** History/Analytics/Settings are contract-empty placeholders
  (#37/#38). Cue delivery (#40) rides `PlatformCueSink` (SC-cues §5): the four
  haptic classes map to UIFeedbackGenerator/CoreHaptics, rest-end audio is a
  discreet system tone, and backgrounded/locked rest-end delivers via local
  notification (`RestEndNotificationScheduler`). Cue DECISIONS stay in
  `CueEngine`; the sinks render what the engine fires. A `CompositeCueSink`
  keeps the `RecordingCueSink` live for diagnostics. Visual polish (#40) wires
  the steel/lime tokens, glass tiers with rim-light, and the four named springs
  (`MooreMotion`) into the existing surfaces. Platform/UIKit files under
  `Sources/Platform/` are Mac-build-only (not parseable off-Mac).
