// Ticket #33 — routine create/edit sheet. Drives RoutineEditorModel (which wraps
// the existing RoutineEditorBuffer and persists via RoutineDAO.create/update).
// Thin view: layout + bindings; all state transitions live in the model/DAOs.
//
// #35 additions: per-exercise progression surfaces — the scheme picker
// (none/linear/double/hold-duration, SC-progression BR-002), the Auto warm-ups
// toggle (SC-warmup BR-010), the "Next:" preview line + the non-modal stall
// banner (BR-013/BR-018) — all state in RoutineEditorModel/ProgressionModel.

import SwiftUI
import MooreExercises
import MooreRoutines
import MooreProgression

struct RoutineEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: RoutineEditorModel
    private let exerciseDAO: ExerciseDAO
    private let onSaved: () -> Void

    init(config: RoutineSheetConfig, deps: AppDependencies, onSaved: @escaping () -> Void) {
        self.exerciseDAO = deps.exerciseDAO
        self.onSaved = onSaved
        switch config.mode {
        case .create:
            _model = State(initialValue: RoutineEditorModel(
                routineDAO: deps.routineDAO,
                exerciseDAO: deps.exerciseDAO,
                progression: deps.progression
            ))
        case .edit(let routineId):
            // Load the live routine + its sets into the buffer (cold read).
            let routine = try? deps.routineDAO.fetch(id: routineId)
            let sets = (try? deps.routineDAO.fetchSets(routineId: routineId)) ?? []
            if let routine {
                _model = State(initialValue: RoutineEditorModel(
                    routineDAO: deps.routineDAO,
                    exerciseDAO: deps.exerciseDAO,
                    progression: deps.progression,
                    routine: routine,
                    sets: sets
                ))
            } else {
                _model = State(initialValue: RoutineEditorModel(
                    routineDAO: deps.routineDAO,
                    exerciseDAO: deps.exerciseDAO,
                    progression: deps.progression
                ))
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // routineEditor.namePlaceholder
                    TextField(UICopy.editorNamePlaceholder, text: $model.buffer.name)
                        .font(MooreFont.display(.body))
                }

                Section {
                    ForEach(model.buffer.drafts) { draft in
                        // #35: the per-exercise progression header (stall banner,
                        // "Next:" line, scheme picker, warm-up toggle) rides above
                        // that exercise's FIRST draft row.
                        if isFirstDraft(of: draft) {
                            pairHeader(for: draft.exerciseId)
                        }
                        setRow(draft)
                    }
                    .onDelete { offsets in
                        for index in offsets.sorted(by: >) where index < model.buffer.drafts.count {
                            model.removeSet(id: model.buffer.drafts[index].id)
                        }
                    }
                    .onMove { source, destination in
                        guard let from = source.first else { return }
                        model.moveSet(from: from, to: destination > from ? destination - 1 : destination)
                    }

                    // routineEditor.addExercise_cta → the SC-exercises picker sheet
                    Button {
                        model.showingPicker = true
                    } label: {
                        Label(UICopy.editorAddExerciseCta, systemImage: "plus")
                            .foregroundStyle(MooreColor.lime)
                    }
                }

                if model.hasNoExercises {
                    Section {
                        // BR-001 hint copy — the routine would have Start disabled.
                        Text(UICopy.editorStartDisabledHint)
                            .font(MooreFont.body(.footnote))
                            .foregroundStyle(MooreColor.textSecondary)
                    }
                }

                if let error = model.saveError {
                    Section {
                        Text(error)
                            .font(MooreFont.numeric(.caption))
                            .foregroundStyle(MooreColor.textSecondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(MooreColor.steelBase)
            // routineEditor.new_title / routineEditor.edit_title
            .navigationTitle(model.isNew ? UICopy.editorNewTitle : UICopy.editorEditTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(UICopy.editorCancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    // routineEditor.save_cta
                    Button(UICopy.editorSaveCta) {
                        if model.save() {
                            onSaved()
                            dismiss()
                        }
                    }
                    .disabled(!model.canSave)
                }
            }
            .sheet(isPresented: $model.showingPicker) {
                ExercisePickerSheet(exerciseDAO: exerciseDAO) { exercise in
                    model.addExercise(exercise.id)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// One planned-set row: exercise name + planned weight/reps (or duration for
    /// duration-metric exercises) + add-set [+] for that exercise.
    private func setRow(_ draft: EditableSetDraft) -> some View {
        let exercise = model.exercise(for: draft.exerciseId)
        let isDuration = exercise?.defaultMetric == .duration
        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
            HStack {
                Text(exercise?.name ?? draft.exerciseId)
                    .font(MooreFont.display(.subheadline))
                    .foregroundStyle(MooreColor.textPrimary)
                Spacer()
                // Add-set affordance: copies this exercise's last row values (#7 §3).
                Button {
                    model.addSet(forExercise: draft.exerciseId)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(MooreColor.lime)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: DesignTokens.Spacing.m) {
                if isDuration {
                    // routineEditor.setColumnDuration
                    TextField(UICopy.editorSetColumnDuration, value: durationBinding(draft), format: .number)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .font(MooreFont.numeric(.body))
                } else {
                    // routineEditor.setColumnWeight
                    TextField(UICopy.editorSetColumnWeight, value: weightBinding(draft), format: .number)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .font(MooreFont.numeric(.body))
                    // routineEditor.setColumnReps
                    TextField(UICopy.editorSetColumnReps, value: repsBinding(draft), format: .number)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .font(MooreFont.numeric(.body))
                }
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    // MARK: #35 — per-exercise progression header

    /// True when `draft` is the first row of its exercise in buffer order —
    /// the pair header renders once per exercise, above that first row.
    private func isFirstDraft(of draft: EditableSetDraft) -> Bool {
        model.buffer.drafts.first(where: { $0.exerciseId == draft.exerciseId })?.id == draft.id
    }

    /// Stall banner (BR-013, non-modal, tap-to-apply) + "Next:" preview line
    /// (BR-018) + the per-pair scheme picker (BR-002) + warm-up toggle
    /// (SC-warmup BR-010, gated to reps-metric exercises by BR-002).
    @ViewBuilder
    private func pairHeader(for exerciseId: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
            if let banner = model.stallBanner(for: exerciseId) {
                StallBannerView(
                    banner: banner,
                    onChoice: { action in
                        model.applyStallChoice(action, forExercise: exerciseId)
                    },
                    onDismiss: {
                        model.dismissStallBanner(for: exerciseId)
                    }
                )
            }
            // progression.nextLine — what the next session materializes.
            if let line = model.nextLine(for: exerciseId) {
                Text(line)
                    .font(MooreFont.numeric(.footnote))
                    .foregroundStyle(MooreColor.textSecondary)
            }
            // Per-pair scheme picker (none/linear/double/hold-duration).
            Picker(UICopy.editorSchemeLabel, selection: schemeBinding(exerciseId)) {
                Text(UICopy.schemeNone).tag(Scheme.none)
                Text(UICopy.schemeLinear).tag(Scheme.linear)
                Text(UICopy.schemeDouble).tag(Scheme.double)
                Text(UICopy.schemeHoldDuration).tag(Scheme.holdDuration)
            }
            .pickerStyle(.menu)
            .tint(MooreColor.lime)
            // warmup.editor.toggle — hidden for duration-metric exercises
            // (SC-warmup BR-002 gates generation on the reps metric).
            if model.showsWarmupToggle(exerciseId) {
                Toggle(isOn: warmupBinding(exerciseId)) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        Text(UICopy.warmupEditorToggle)
                            .font(MooreFont.display(.subheadline))
                            .foregroundStyle(MooreColor.textPrimary)
                        Text(UICopy.warmupEditorToggleSub)
                            .font(MooreFont.body(.caption))
                            .foregroundStyle(MooreColor.textSecondary)
                    }
                }
                .tint(MooreColor.lime)
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    private func schemeBinding(_ exerciseId: String) -> Binding<Scheme> {
        Binding(
            get: { model.scheme(for: exerciseId) },
            set: { model.setScheme($0, forExercise: exerciseId) }
        )
    }

    private func warmupBinding(_ exerciseId: String) -> Binding<Bool> {
        Binding(
            get: { model.warmupEnabled(for: exerciseId) },
            set: { model.setWarmupEnabled($0, forExercise: exerciseId) }
        )
    }

    // MARK: Bindings into the model's buffer (logic stays in RoutineEditorModel)
    //
    // TextField(value:format:) binds non-optional FormatInput, so nil ⇄ 0 is the
    // bridge: a planned value of 0 kg / 0 reps / 0 s is not a meaningful plan, so
    // 0 stores NULL (unset) and NULL displays 0.

    private func weightBinding(_ draft: EditableSetDraft) -> Binding<Double> {
        Binding(
            get: { draft.plannedWeight ?? 0 },
            set: { value in
                model.updateSet(id: draft.id) { $0.plannedWeight = value == 0 ? nil : value }
            }
        )
    }

    private func repsBinding(_ draft: EditableSetDraft) -> Binding<Int> {
        Binding(
            get: { draft.plannedReps ?? 0 },
            set: { value in
                model.updateSet(id: draft.id) { $0.plannedReps = value == 0 ? nil : value }
            }
        )
    }

    private func durationBinding(_ draft: EditableSetDraft) -> Binding<Int> {
        Binding(
            get: { draft.plannedDuration ?? 0 },
            set: { value in
                model.updateSet(id: draft.id) { $0.plannedDuration = value == 0 ? nil : value }
            }
        )
    }
}
