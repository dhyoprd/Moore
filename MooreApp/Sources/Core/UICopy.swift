// Ticket #33 — UI copy table.
// Every user-facing string binds to its contract key verbatim; code references
// these constants, never ad-hoc literals. Sources: SC-routines@1.0.0 §6,
// SC-settings@1.0.0 §6 (incl. the nineteen #14 empty-state keys),
// SC-workout-logging@1.0.0 §6, SC-foundation@1.0.0 §6 (fatal-recovery keys),
// SC-prs@1.0.0 §6 (PR toast / kind labels / summary cards / banner / badge).
// Dynamic values use the {placeholder} shapes from the contracts, resolved by
// the helper functions at the bottom. Voice per #17: declarative, factual,
// no exclamation marks.
//
// Foundation-only (no SwiftUI) so it parses/verifies off-Mac.

import Foundation

public enum UICopy {

    // MARK: Home surface (SC-routines §6)

    /// home.empty_title
    public static let homeEmptyTitle = "No routines yet"
    /// home.empty_sub
    public static let homeEmptySub = "Routines are your gym days. Create one and your next workout is one tap to start."
    /// home.empty_cta
    public static let homeEmptyCta = "Create your first routine"
    /// home.startEmpty_cta
    public static let homeStartEmptyCta = "Start empty"
    /// home.resume_cta
    public static let homeResumeCta = "Resume"
    /// home.routineRow_start
    public static let homeRoutineRowStart = "Start"
    /// home.unfiled_header
    public static let homeUnfiledHeader = "Unfiled"
    /// home.newRoutine_fab
    public static let homeNewRoutineFab = "Routine"

    // MARK: Routine editor (SC-routines §6)

    /// routineEditor.new_title
    public static let editorNewTitle = "New routine"
    /// routineEditor.edit_title
    public static let editorEditTitle = "Edit routine"
    /// routineEditor.namePlaceholder
    public static let editorNamePlaceholder = "e.g. Push Day A"
    /// routineEditor.addExercise_cta
    public static let editorAddExerciseCta = "Add exercise"
    /// routineEditor.setColumnWeight
    public static let editorSetColumnWeight = "Weight"
    /// routineEditor.setColumnReps
    public static let editorSetColumnReps = "Reps"
    /// routineEditor.setColumnDuration
    public static let editorSetColumnDuration = "Duration"
    /// routineEditor.save_cta
    public static let editorSaveCta = "Save"
    /// routineEditor.startDisabled_hint — the disabled-Start copy (BR-001: copy, never a toast)
    public static let editorStartDisabledHint = "Add an exercise ahead of starting"

    // MARK: Confirm-first destructive (SC-routines §6, BR-004)

    /// confirm.deleteRoutine.body
    public static let confirmDeleteRoutineBody = "Its history stays. This routine won't show on Home."
    /// confirm.deleteRoutine.confirm
    public static let confirmDeleteRoutineConfirm = "Delete"
    /// confirm.deleteRoutine.cancel
    public static let confirmDeleteRoutineCancel = "Cancel"
    /// confirm.deleteFolder.body
    public static let confirmDeleteFolderBody = "Routines inside move to Unfiled. Nothing is lost."
    /// confirm.deleteFolder.confirm
    public static let confirmDeleteFolderConfirm = "Delete"
    /// confirm.deleteFolder.cancel
    public static let confirmDeleteFolderCancel = "Cancel"

    // MARK: Exercise picker (#14 / SC-settings §6)

    /// picker.search_empty_title
    public static let pickerSearchEmptyTitle = "No matches"
    /// picker.search_empty_sub
    public static let pickerSearchEmptySub = "Check spelling or create it custom."
    /// picker.createCustom_cta
    public static let pickerCreateCustomCta = "Create custom exercise"
    /// picker.browse_hint
    public static let pickerBrowseHint = "Or scroll to browse"

    // MARK: Tab empty states (#14 / SC-settings §6)

    /// history.empty_title
    public static let historyEmptyTitle = "No sessions yet"
    /// history.empty_sub
    public static let historyEmptySub = "Your gym visits will live here."
    /// history.empty_cta — deep-links to Home (tab switch)
    public static let historyEmptyCta = "Start a workout"
    /// analytics.empty_title
    public static let analyticsEmptyTitle = "Nothing to graph yet"
    /// analytics.empty_sub
    public static let analyticsEmptySub = "Log 3 sessions to start seeing trends."
    /// analytics.empty_cta — deep-links to Home (tab switch)
    public static let analyticsEmptyCta = "Log your first session"
    /// analytics.hint_body
    public static let analyticsHintBody = "Every workout builds your stats."

    // MARK: Settings (SC-settings §6)

    /// settings.title
    public static let settingsTitle = "Settings"
    /// settings.units.title
    public static let settingsUnitsTitle = "Units"
    /// settings.units.weight
    public static let settingsUnitsWeight = "Weight unit"
    /// settings.restDefaults.title
    public static let settingsRestDefaultsTitle = "Rest defaults"
    /// settings.restDefaults.compound
    public static let settingsRestDefaultsCompound = "Compound lifts"
    /// settings.restDefaults.isolation
    public static let settingsRestDefaultsIsolation = "Isolation"
    /// settings.bodyMetrics.title
    public static let settingsBodyMetricsTitle = "Body metrics"
    /// settings.bodyMetrics.addCta
    public static let settingsBodyMetricsAddCta = "Add entry"
    /// settings.bodyMetrics.empty
    public static let settingsBodyMetricsEmpty = "No entries yet"
    /// settings.bodyMetrics.trendTitle
    public static let settingsBodyMetricsTrendTitle = "Trend"
    /// settings.dataSync.title
    public static let settingsDataSyncTitle = "Data & sync"
    /// settings.dataSync.exportCta
    public static let settingsDataSyncExportCta = "Export backup"
    /// settings.dataSync.importHevy
    public static let settingsDataSyncImportHevy = "Import from Hevy"
    /// settings.dataSync.importHevyBlocked
    public static let settingsDataSyncImportHevyBlocked = "Available after import ships"
    /// settings.cloudSync.title
    public static let settingsCloudSyncTitle = "Cloud sync"
    /// settings.cloudSync.coming
    public static let settingsCloudSyncComing = "Coming after self-validation gate"
    /// settings.tombstones.title
    public static let settingsTombstonesTitle = "Deleted custom exercises"
    /// settings.tombstones.restoreCta
    public static let settingsTombstonesRestoreCta = "Restore"
    /// settings.tombstones.empty
    public static let settingsTombstonesEmpty = "Nothing deleted"

    // MARK: Workout (SC-workout-logging §6)

    /// workout.adhoc_title — title for sessions with no routine (Start empty)
    public static let workoutAdhocTitle = "Workout"
    /// workout.section.nextUp — derived first-non-terminal highlight tag (INV-W1)
    public static let workoutSectionNextUp = "Next up"
    /// workout.set.dropped — row state copy for a dropped set
    public static let workoutSetDropped = "Set dropped"
    /// workout.set.acceptHint — accessibility hint for the per-set ✓ target
    public static let workoutSetAcceptHint = "Tap ✓ to log"
    /// workout.edit.title — bottom-sheet title for the edit path
    public static let workoutEditTitle = "Edit set"
    /// workout.edit.failTitle — bottom-sheet title, pre-tagged failed (BR-002)
    public static let workoutEditFailTitle = "Failed set"
    /// workout.edit.weightLabel
    public static let workoutEditWeightLabel = "Weight"
    /// workout.edit.repsLabel
    public static let workoutEditRepsLabel = "Reps"
    /// workout.edit.durationLabel
    public static let workoutEditDurationLabel = "Duration"
    /// workout.edit.actualRepsPlaceholder — fail-flow reps field (BR-002)
    public static let workoutEditActualRepsPlaceholder = "Reps completed"
    /// workout.edit.accept — sheet ✓ CTA
    public static let workoutEditAccept = "Done"
    /// workout.addSet.cta — exercise-group header [+] (BR-004)
    public static let workoutAddSetCta = "+"
    /// workout.undo.title — drop-undo toolbar state copy (BR-003)
    public static let workoutUndoTitle = "Set dropped"
    /// workout.undo.cta — drop-undo toolbar CTA (BR-003)
    public static let workoutUndoCta = "Undo"
    /// workout.finish.title — summary screen title
    public static let workoutFinishTitle = "Workout complete"
    /// workout.finish.cta — finish-panel CTA
    public static let workoutFinishCta = "Finish workout"
    /// workout.empty.title — zero-row money screen state (Start empty)
    public static let workoutEmptyTitle = "No sets yet"
    /// workout.empty.sub
    public static let workoutEmptySub = "Add an exercise to start logging."
    /// confirm.discardSession.title
    public static let confirmDiscardSessionTitle = "Discard workout?"
    /// confirm.discardSession.confirm
    public static let confirmDiscardSessionConfirm = "Discard"
    /// confirm.discardSession.cancel
    public static let confirmDiscardSessionCancel = "Keep"

    // MARK: Progression (SC-progression §5 — verbatim)

    /// progression.banner.deloadCta — renders only when the pair has a weight (BR-013)
    public static let progressionDeloadCta = "Deload −10%"
    /// progression.banner.holdCta
    public static let progressionHoldCta = "Hold"
    /// progression.banner.ignoreCta
    public static let progressionIgnoreCta = "Ignore"

    /// progression.banner.stall — "Looks stalled on {name} — {n} sessions short of target."
    public static func progressionBannerStall(name: String, n: Int) -> String {
        "Looks stalled on \(name) — \(n) sessions short of target."
    }

    /// progression.nextLine — "Next: {name} {weight}×{reps}" (`value` is the
    /// resolved "{weight}×{reps}" pair, or the duration shape for
    /// duration-metric exercises).
    public static func progressionNextLine(name: String, value: String) -> String {
        "Next: \(name) \(value)"
    }

    // MARK: Warm-ups (SC-warmup §5 — verbatim)

    /// warmup.chip — the warm-up row tag (BR-016)
    public static let warmupChip = "WU"
    /// warmup.editor.toggle — routine-editor per-pair toggle (BR-010)
    public static let warmupEditorToggle = "Auto warm-ups"
    /// warmup.editor.toggleSub
    public static let warmupEditorToggleSub = "Adds a weight-matched ramp at session start. Warm-ups never count toward PRs, volume, or stall detection."

    // MARK: Progression editor (surfaced by #35; no contract §6 keys exist for
    // the picker labels — move into SC-progression §6 when the surface freezes)

    /// Per-exercise scheme picker label (routine editor)
    public static let editorSchemeLabel = "Progression"
    /// Scheme values (SC-progression §2 vocabulary)
    public static let schemeNone = "None"
    public static let schemeLinear = "Linear"
    public static let schemeDouble = "Double progression"
    public static let schemeHoldDuration = "Hold duration"
    // MARK: Personal records (SC-prs §6)

    /// pr.kind.max_1rm — headline kind label for toasts + summary cards
    public static let prKindMax1rm = "1RM"
    /// pr.kind.max_volume
    public static let prKindMaxVolume = "Volume"
    /// pr.kind.max_reps
    public static let prKindMaxReps = "Reps"
    /// pr.kind.max_duration
    public static let prKindMaxDuration = "Duration"
    /// history.badge.pr — History session-row PR badge (#36 groundwork for #37)
    public static let historyBadgePr = "PR"

    // MARK: Rest overlay + Finish morph (SC-rest §6)

    /// rest.overlay.title
    public static let restOverlayTitle = "Rest"
    /// rest.overlay.cta.skip
    public static let restOverlayCtaSkip = "Skip"
    /// rest.overlay.cta.plus15
    public static let restOverlayCtaPlus15 = "+15s"
    /// rest.overlay.cta.minus15
    public static let restOverlayCtaMinus15 = "−15s"
    /// rest.over.title — expired rest state
    public static let restOverTitle = "Rest over"
    /// rest.finish.cta — Finish-morph panel CTA (§2b)
    public static let restFinishCta = "Finish Workout"

    // MARK: Rest-end notification-class delivery (SC-cues §6 — BR-005)

    /// rest.notification.title — the backgrounded/locked delivery surface of
    /// cue.rest.end (same string as rest.over.title; distinct key per §6).
    public static let restNotificationTitle = "Rest over"

    // MARK: Active Workout empty state (#14 §2 / SC-settings §6)

    /// activeWorkout.emptyList_line
    public static let workoutEmptyLine = "No sets yet"
    /// activeWorkout.addExercise_cta
    public static let workoutAddExerciseCta = "+ Add exercise"
    /// activeWorkout.startEmpty_help
    public static let workoutStartEmptyHelp = "Add an exercise to start logging"

    // MARK: Fatal recovery (SC-foundation §6)

    /// foundation.db.fatalTitle
    public static let dbFatalTitle = "Storage unavailable"
    /// foundation.db.fatalBody
    public static let dbFatalBody = "Moore's local database can't be opened. Your training data may be at risk. Export a backup from Settings if you can, then reinstall the app."
    /// foundation.db.migrationFailedTitle
    public static let dbMigrationFailedTitle = "Update failed"
    /// foundation.db.migrationFailedBody
    public static let dbMigrationFailedBody = "This update requires a database change that didn't complete. Don't delete the app — export your data and contact support."
    /// foundation.db.unknownError
    public static let dbUnknownError = "Something went wrong with local storage. Try again."

    // MARK: Tab titles (screen blueprint #7; settings via settings.title above)

    public static let tabHome = "Home"
    public static let tabHistory = "History"
    public static let tabAnalytics = "Analytics"

    // MARK: App-level copy not pinned by a contract key yet
    // (surfaced by #33; move into a contract §6 when that surface freezes)

    /// Routine row context action — BR-002 duplicate
    public static let homeRoutineRowDuplicate = "Duplicate"
    /// Routine row context action — BR-004 delete (confirm-first follows)
    public static let homeRoutineRowDelete = "Delete"
    /// Folder header context action — BR-004 delete (confirm-first follows)
    public static let homeFolderDelete = "Delete folder"
    /// Picker inline create-form confirm (create-custom, SC-exercises §2b .creating)
    public static let pickerCreateConfirm = "Create"
    /// Picker inline create-form cancel
    public static let pickerCreateCancel = "Cancel"
    /// Picker create-form field labels (taxonomy form; no contract keys exist)
    public static let pickerCategoryLabel = "Category"
    public static let pickerMetricLabel = "Metric"
    public static let pickerEquipmentLabel = "Equipment"
    /// Routine editor dismiss action
    public static let editorCancel = "Cancel"
    /// Money-screen swipe-left actions (SC-workout-logging BR-002/BR-003 gestures;
    /// no contract §6 keys exist for the swipe labels themselves)
    public static let workoutSwipeFail = "Failed"
    public static let workoutSwipeDrop = "Drop"
    /// Summary plan-vs-actual column lead-in (no contract key)
    public static let workoutSummaryPlanned = "Planned"

    // MARK: Settings surface copy not pinned by a contract key yet
    // (surfaced by #38; SC-settings §6 pins the keys above, these render shapes
    // the contract leaves open — move into a contract §6 when the surface refreezes)

    /// Body-metric kind names (add-sheet picker + row titles; §3b closed vocabulary)
    public static let settingsKindLabel = "Kind"
    public static let settingsUnitLabel = "Unit"
    public static let settingsKindBodyWeight = "Weight"
    public static let settingsKindBodyFat = "Body fat"
    public static let settingsKindMeasurement = "Measurement"
    /// Add-entry sheet field labels/placeholders
    public static let settingsSheetSave = "Save"
    public static let settingsSheetCancel = "Cancel"
    public static let settingsValuePlaceholder = "Value"
    public static let settingsLabelPlaceholder = "e.g. Waist"
    public static let settingsUnitPlaceholder = "cm"
    public static let settingsRecordedAtLabel = "Date"
    /// Storage stats rows (Data & sync; BR-009 accounting render)
    public static let settingsStorageSize = "Database size"
    public static let settingsStorageRows = "Rows"
    public static let settingsStorageDeletedRows = "Deleted rows"

    // MARK: Dynamic value resolution ({placeholder} shapes from the contracts)

    /// home.streak_label — "{n}-day streak"
    public static func streakLabel(_ n: Int) -> String {
        "\(n)-day streak"
    }

    /// settings.restDefaults.value — "{n}s"
    public static func restDefaultsValue(_ n: Int) -> String {
        "\(n)s"
    }

    /// settings.dataSync.exportedToast — "Backup saved: {fileName}"
    public static func exportedToast(fileName: String) -> String {
        "Backup saved: \(fileName)"
    }

    /// home.resume_label — "Resume: {routineName} — {setsDone}/{setsTotal} sets".
    /// `routineName` nil = ad-hoc / Start-empty session → workout.adhoc_title.
    public static func resumeLabel(routineName: String?, setsDone: Int, setsTotal: Int) -> String {
        let name = routineName ?? workoutAdhocTitle
        return "Resume: \(name) — \(setsDone)/\(setsTotal) sets"
    }

    /// home.routineRow_sub — "{count} exercises" (verbatim shape, no plural rule in contract)
    public static func routineRowSub(count: Int) -> String {
        "\(count) exercises"
    }

    /// home.routineRow_lastUsed — "{relativeDate} · {setCount} sets · {volumeKg} kg".
    /// `sessionDescription` is HomeSurfaceViewModel's "{setCount} sets · {volumeKg} kg".
    public static func routineRowLastUsed(relativeDate: String, sessionDescription: String) -> String {
        "\(relativeDate) · \(sessionDescription)"
    }

    /// confirm.deleteRoutine.title / confirm.deleteFolder.title — "Delete "{name}"?"
    public static func confirmDeleteTitle(name: String) -> String {
        "Delete \"\(name)\"?"
    }

    /// workout.title — "{routineName}" (nil → workout.adhoc_title)
    public static func workoutTitle(routineName: String?) -> String {
        routineName ?? workoutAdhocTitle
    }

    /// workout.set.plannedValue — "{weight} × {reps}"
    public static func workoutSetPlannedValue(weight: String, reps: Int) -> String {
        "\(weight) × \(reps)"
    }

    /// workout.set.durationValue — "{duration}"
    public static func workoutSetDurationValue(duration: String) -> String {
        duration
    }

    /// workout.set.doneDelta — "{actualWeight} × {actualReps}"
    public static func workoutSetDoneDelta(actualWeight: String, actualReps: Int) -> String {
        "\(actualWeight) × \(actualReps)"
    }

    /// workout.set.failedDelta — "Failed at {actualReps} — {plannedWeight} × {plannedReps}"
    public static func workoutSetFailedDelta(actualReps: Int, plannedWeight: String, plannedReps: Int) -> String {
        "Failed at \(actualReps) — \(plannedWeight) × \(plannedReps)"
    }

    /// workout.finish.subtitle — "{setsDone} sets · {volumeKg} kg"
    public static func workoutFinishSubtitle(setsDone: Int, volumeKg: Double) -> String {
        "\(setsDone) sets · \(volumeKg) kg"
    }

    /// confirm.discardSession.body — "{setsLogged} sets logged. This can't be undone."
    public static func confirmDiscardSessionBody(setsLogged: Int) -> String {
        "\(setsLogged) sets logged. This can't be undone."
    }

    /// rest.overlay.remaining — "{mm:ss}"
    public static func restOverlayRemaining(seconds: Int) -> String {
        let clamped = max(0, seconds)
        return String(format: "%d:%02d", clamped / 60, clamped % 60)
    }

    /// rest.over.body — "{exerciseName} — set {n} of {total}"
    public static func restOverBody(exerciseName: String, n: Int, total: Int) -> String {
        "\(exerciseName) — set \(n) of \(total)"
    }

    /// rest.notification.body — "{exerciseName} — set {n} of {total}"
    /// (SC-cues §6; identical shape to rest.over.body, distinct key).
    public static func restNotificationBody(exerciseName: String, n: Int, total: Int) -> String {
        "\(exerciseName) — set \(n) of \(total)"
    }

    /// rest.finish.summary — "{setCount} sets · {exerciseCount} exercises · {duration}"
    public static func restFinishSummary(setCount: Int, exerciseCount: Int, duration: String) -> String {
        "\(setCount) sets · \(exerciseCount) exercises · \(duration)"
    }

    // MARK: Personal records dynamic resolution (SC-prs §6)

    /// pr.kind.* — the §6 kind-label table keyed by SC-prs's canonical raw
    /// values (INV-PR1 closed vocabulary). Unknown kinds render their raw
    /// value verbatim (forward-compat, never a crash — mirrors SC-cues BR-007).
    public static func prKindLabel(_ kindRaw: String) -> String {
        switch kindRaw {
        case "max_1rm": return prKindMax1rm
        case "max_volume": return prKindMaxVolume
        case "max_reps": return prKindMaxReps
        case "max_duration": return prKindMaxDuration
        default: return kindRaw
        }
    }

    /// toast.pr.new — "🏆 New {kindLabel} PR — {exerciseName} {value}"
    public static func toastPrNew(kindLabel: String, exerciseName: String, value: String) -> String {
        "🏆 New \(kindLabel) PR — \(exerciseName) \(value)"
    }

    /// summary.pr.card — "{exerciseName} {kindLabel} {value}"
    public static func summaryPrCard(exerciseName: String, kindLabel: String, value: String) -> String {
        "\(exerciseName) \(kindLabel) \(value)"
    }

    /// summary.pr.banner — "🏆 {n} new PRs"
    public static func summaryPrBanner(count: Int) -> String {
        "🏆 \(count) new PRs"
    }
}
