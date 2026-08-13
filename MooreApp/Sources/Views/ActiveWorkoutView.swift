// Ticket #34 — the Active Workout MONEY SCREEN. Replaces the #33 stub.
//
// Contract shape (SC-workout-logging@1.0.0): a flat, order-free set list
// grouped by exercise; every row independently actionable, no enforced cursor
// (INV-W1). Per-set ✓ is the 80% path — one tap, ≥44×44pt, no inline steppers
// (BR-005). Editing is exclusively the bottom-sheet path. Swipe-left is the
// one fluid gesture for Fail (records actual reps, BR-002) and Drop (undo
// until next set logs, BR-003). The screen is opaque steel, mis-tap-proof,
// and never shows a modal — only sheets and the ambient bottom overlay.
//
// Thin view: every transition lives in WorkoutSessionModel (Foundation-only),
// which drives the frozen WorkoutSessionFSM + RestCycle engines.

import SwiftUI
import MooreWorkout

struct ActiveWorkoutView: View {
    @Environment(AppState.self) private var appState
    var model: WorkoutSessionModel

    /// Heartbeat: drives the header elapsed slot, the rest countdown, and
    /// natural-expiry detection (BR-007: render reads timestamps; the tick
    /// never accumulates time).
    @State private var now = Date()
    @State private var showingExercisePicker = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        @Bindable var model = model
        Group {
            if let summary = model.summary {
                WorkoutSummaryView(summary: summary) {
                    appState.closeFinishedWorkout()
                }
            } else {
                moneyScreen
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The money screen is opaque steel — glass never appears here (#17).
        .background(MooreColor.steelBase)
        // Non-dismissable: the only ways down are the minimize chevron,
        // Finish (FSM), or the summary's Done (#7 §2).
        .interactiveDismissDisabled()
        .onReceive(timer) { date in
            now = date
            model.restTick(now: date)
        }
        // Bottom-sheet edit path — never a modal (§2a: editing is transient UI).
        // medium is the bottom-sheet resting height; large is reachable when the
        // fail-flow keyboard (focused reps field) needs the room.
        .sheet(item: $model.editRequest) { request in
            SetEditSheet(model: model, request: request)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        // Start-empty bootstrap: pick the first exercise (ad-hoc sessions
        // materialise with zero rows).
        .sheet(isPresented: $showingExercisePicker) {
            if let deps = appState.dependencies {
                ExercisePickerSheet(exerciseDAO: deps.exerciseDAO) { exercise in
                    _ = model.addFirstSet(exerciseId: exercise.id)
                }
            }
        }
    }

    // MARK: Money screen

    private var moneyScreen: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                header
                if model.snapshot.sets.isEmpty {
                    emptyState
                } else {
                    setList
                }
            }

            // Ambient bottom tier: drop-undo toolbar + rest overlay / finish
            // panel. The rest→Finish morph animates on the surface change
            // (motion.morph — the one sanctioned rupture).
            VStack(spacing: DesignTokens.Spacing.m) {
                if let undo = model.undoableDrop, undo.available {
                    undoBar
                }
                bottomSurface
            }
            .padding(.horizontal, DesignTokens.Spacing.l)
            .padding(.bottom, DesignTokens.Spacing.l)
        }
        .animation(.spring(duration: DesignTokens.Motion.morphSeconds), value: model.overlaySurface)
    }

    // MARK: Header (#7 §3: minimize chevron · title · elapsed slot)

    private var header: some View {
        HStack {
            Button {
                appState.minimizeWorkout()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(MooreColor.textPrimary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)

            Spacer()

            // workout.title "{routineName}" / workout.adhoc_title "Workout"
            Text(UICopy.workoutTitle(routineName: model.routineName))
                .font(MooreFont.display(.headline))
                .foregroundStyle(MooreColor.textPrimary)

            Spacer()

            // Elapsed slot — mm:ss from startedAt, numeric-mono register.
            Text(model.elapsedText(at: now))
                .font(MooreFont.numeric(.subheadline))
                .foregroundStyle(MooreColor.textSecondary)
                .frame(minWidth: 44, alignment: .trailing)
        }
        .padding(.horizontal, DesignTokens.Spacing.m)
        .padding(.top, DesignTokens.Spacing.s)
    }

    // MARK: Set list (flat, order-free, grouped by exercise)

    private var setList: some View {
        List {
            ForEach(model.groups) { group in
                Section {
                    ForEach(group.sets) { set in
                        SetRowView(model: model, set: set, isNextUp: set.id == model.nextIncompleteSetId)
                            .listRowBackground(MooreColor.steelRaised)
                            .listRowSeparatorTint(MooreColor.steelHairline)
                    }
                } header: {
                    exerciseHeader(group)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(MooreColor.steelBase)
        // Keep the last row reachable above the ambient bottom tier.
        .contentMargins(.bottom, 150, for: .scrollContent)
    }

    /// Exercise-group header: name + the [+] add-set affordance (BR-004 —
    /// prefills from the exercise's last row; dropsets emerge without modes).
    private func exerciseHeader(_ group: ExerciseGroup) -> some View {
        HStack {
            Text(group.name.uppercased())
                .font(MooreFont.display(.footnote))
                .foregroundStyle(MooreColor.textSecondary)
            Spacer()
            Button {
                _ = model.addSet(exerciseId: group.exerciseId)
            } label: {
                Text(UICopy.workoutAddSetCta)
                    .font(MooreFont.display(.body))
                    .foregroundStyle(MooreColor.lime)
                    .frame(width: 44, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(UICopy.workoutAddSetCta)
        }
        .background(MooreColor.steelBase)
    }

    // MARK: Start-empty state (workout.empty_*)

    private var emptyState: some View {
        VStack(spacing: DesignTokens.Spacing.m) {
            Spacer()
            Text(UICopy.workoutEmptyTitle)
                .font(MooreFont.display(.title3))
                .foregroundStyle(MooreColor.textPrimary)
            Text(UICopy.workoutEmptySub)
                .font(MooreFont.body(.subheadline))
                .foregroundStyle(MooreColor.textSecondary)
            Button {
                showingExercisePicker = true
            } label: {
                Label(UICopy.workoutAddExerciseCta, systemImage: "plus")
            }
            .buttonStyle(MoorePrimaryButtonStyle())
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Drop-undo toolbar (BR-003: lives until the next logged set, no timer)

    private var undoBar: some View {
        HStack {
            // workout.undo.title
            Text(UICopy.workoutUndoTitle)
                .font(MooreFont.body(.subheadline))
                .foregroundStyle(MooreColor.textPrimary)
            Spacer()
            // workout.undo.cta
            Button(UICopy.workoutUndoCta) {
                _ = model.undoDrop()
            }
            .buttonStyle(MooreSecondaryButtonStyle())
        }
        .padding(.horizontal, DesignTokens.Spacing.l)
        .padding(.vertical, DesignTokens.Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.tier3)
                .fill(MooreColor.steelRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.tier3)
                .strokeBorder(MooreColor.steelHairline, lineWidth: 1)
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: Bottom surface (rest overlay ⇄ finish panel, SC-rest §2b)

    @ViewBuilder
    private var bottomSurface: some View {
        switch model.overlaySurface {
        case .none:
            EmptyView()
        case .rest:
            RestOverlayView(model: model, now: now)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        case .finishPanel:
            FinishPanelView(model: model, now: now)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
    }
}

// MARK: - One set row

/// A single row of the flat list. Planned rows: planned values + the per-set ✓
/// (1 tap, ≥44×44, BR-005). Completed/failed rows: logged delta, tap opens the
/// correction sheet (BR-006). Dropped rows: inert — undo is the only way back.
struct SetRowView: View {
    var model: WorkoutSessionModel
    let set: SetSnapshot
    let isNextUp: Bool

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.m) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                if isNextUp && set.status == .planned {
                    // INV-W1: "next up" is a derived highlight, never a cursor.
                    Text(UICopy.workoutSectionNextUp)
                        .mooreChip()
                }
                rowValueText
            }
            Spacer()
            trailingAffordance
        }
        .padding(.vertical, DesignTokens.Spacing.s)
        .contentShape(Rectangle())
        .onTapGesture {
            // Tap on ANY row is the sheet path (BR-005: no inline mutation).
            model.openEdit(setId: set.id)
        }
        // Swipe-left: the one fluid gesture for Fail / Drop (planned rows only
        // — §2a's `—` cells stay unreachable by construction). Full-swipe is
        // disabled: mis-tap-proof (BR-005).
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if set.status == .planned {
                Button {
                    model.openFail(setId: set.id)
                } label: {
                    Label(UICopy.workoutSwipeFail, systemImage: "xmark.circle")
                }
                .tint(MooreColor.textSecondary)
                Button {
                    _ = model.drop(setId: set.id)
                } label: {
                    Label(UICopy.workoutSwipeDrop, systemImage: "trash")
                }
                .tint(MooreColor.steelHairline)
            }
        }
        .opacity(set.status == .dropped ? 0.5 : 1)
    }

    @ViewBuilder
    private var rowValueText: some View {
        switch set.status {
        case .planned:
            // workout.set.plannedValue / durationValue
            Text(model.plannedText(for: set))
                .font(MooreFont.numeric(.body))
                .foregroundStyle(MooreColor.textPrimary)
        case .completed:
            // workout.set.doneDelta
            Text(model.actualText(for: set))
                .font(MooreFont.numeric(.body))
                .foregroundStyle(MooreColor.textPrimary)
        case .failed:
            // workout.set.failedDelta
            Text(model.actualText(for: set))
                .font(MooreFont.numeric(.subheadline))
                .foregroundStyle(MooreColor.textSecondary)
        case .dropped:
            // workout.set.dropped
            Text(UICopy.workoutSetDropped)
                .font(MooreFont.body(.subheadline))
                .foregroundStyle(MooreColor.textSecondary)
                .strikethrough()
        }
    }

    @ViewBuilder
    private var trailingAffordance: some View {
        switch set.status {
        case .planned:
            // The ✓ — 1-tap accept (BR-001 field-copy), ≥44×44pt hit target.
            Button {
                _ = model.accept(setId: set.id)
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(MooreColor.lime))
            }
            .buttonStyle(FlashButtonStyle())
            .accessibilityLabel(UICopy.workoutSetAcceptHint)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(MooreColor.lime)
                .frame(width: 44, height: 44)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.title3)
                .foregroundStyle(MooreColor.textSecondary)
                .frame(width: 44, height: 44)
        case .dropped:
            Image(systemName: "minus.circle")
                .font(.title3)
                .foregroundStyle(MooreColor.textSecondary.opacity(0.6))
                .frame(width: 44, height: 44)
        }
    }
}

/// motion.flash — the ✓ press feedback (0.080s), the fastest sanctioned motion.
struct FlashButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.linear(duration: DesignTokens.Motion.flashSeconds), value: configuration.isPressed)
    }
}
