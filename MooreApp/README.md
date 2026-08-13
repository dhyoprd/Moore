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
  (#37/#38). Visual polish beyond tokens (rim light, full glass treatment,
  motion wiring) is #40; concrete haptic/audio cue delivery is #29's seam (the
  app currently wires the abstract SC-rest channel to the recording spy).
