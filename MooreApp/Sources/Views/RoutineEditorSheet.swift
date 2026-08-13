// Ticket #33 — routine create/edit sheet. Drives RoutineEditorModel (which wraps
// the existing RoutineEditorBuffer and persists via RoutineDAO.create/update).
// Thin view: layout + bindings; all state transitions live in the model/DAOs.

import SwiftUI
import MooreExercises
import MooreRoutines

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
                exerciseDAO: deps.exerciseDAO
            ))
        case .edit(let routineId):
            // Load the live routine + its sets into the buffer (cold read).
            let routine = try? deps.routineDAO.fetch(id: routineId)
            let sets = (try? deps.routineDAO.fetchSets(routineId: routineId)) ?? []
            if let routine {
                _model = State(initialValue: RoutineEditorModel(
                    routineDAO: deps.routineDAO,
                    exerciseDAO: deps.exerciseDAO,
                    routine: routine,
                    sets: sets
                ))
            } else {
                _model = State(initialValue: RoutineEditorModel(
                    routineDAO: deps.routineDAO,
                    exerciseDAO: deps.exerciseDAO
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
