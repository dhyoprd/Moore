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
`com.moore.app`).

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
  README.md                    this file
  Sources/
    MooreApp.swift             @main — boots, injects AppState
    Core/                      Foundation-only (parses off-Mac; no SwiftUI)
      AppDependencies.swift    composition root: GRDB boot + DI wiring
      AppState.swift           boot phase, tabs, Active Workout presentation hook
      HomeModel.swift          drives HomeSurfaceViewModel + DAO write seams
      RoutineEditorModel.swift drives RoutineEditorBuffer + RoutineDAO
      UICopy.swift             contract UI-copy table (verbatim keys)
      DesignTokens.swift       frozen visual tokens (#17 resolution)
    Views/                     SwiftUI (thin: layout + bindings to Core models)
      RootView.swift           4 tabs + full-screen Active Workout cover + mini-player
      HomeView.swift           Home tracer bullet (folders, rows, streak, Start empty)
      RoutineEditorSheet.swift create/edit routine sheet
      ExercisePickerSheet.swift exercise picker (search / browse / create-custom)
      ActiveWorkoutStubView.swift  #34 stub behind the presentation hook
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
- **Scope.** Active Workout is a stubbed presentation hook (money screen = #34);
  History/Analytics/Settings are contract-empty placeholders (#37/#38). Visual
  polish beyond tokens (rim light, glass tiers, motion) is #40.
