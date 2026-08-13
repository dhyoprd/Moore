// Ticket #33 — exercise picker sheet. Drives the existing PickerViewModel state
// machine (SC-exercises §2b): idle browse-by-category, searching, noResults with
// the single create-custom CTA (#14 §4), inline create form. All transitions live
// in the view-model; this view mirrors its state via observe() and forwards taps.
// Outcome (selected / createdCustom) is consumed exactly once → onPick.

import SwiftUI
import MooreExercises

struct ExercisePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var vm: PickerViewModel
    @State private var results: [Exercise] = []
    @State private var pickerState: PickerState = .idle
    @State private var searchText: String = ""
    @State private var consumedOutcome = false

    // Inline create-form fields (.creating state)
    @State private var createName: String = ""
    @State private var createCategory: ExerciseCategory = .other
    @State private var createMetric: DefaultMetric = .reps
    @State private var createEquipment: ExerciseEquipment = .other

    private let onPick: (Exercise) -> Void

    init(exerciseDAO: ExerciseDAO, onPick: @escaping (Exercise) -> Void) {
        self.onPick = onPick
        _vm = State(initialValue: PickerViewModel(dao: exerciseDAO))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                if case .creating(let seed) = pickerState {
                    createForm(seedName: seed)
                } else {
                    resultsList
                }
            }
            .navigationTitle(UICopy.editorAddExerciseCta)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(UICopy.editorCancel) {
                        vm.cancelledPicker()
                        dismiss()
                    }
                }
            }
        }
        // #40: Tier 2 glass (sheets/modals tier) + rim-light top hairline.
        .mooreSheetGlass()
        .preferredColorScheme(.dark)
        .onAppear {
            // Mirror the view-model's state into @State; consume the outcome once.
            vm.observe { vm, outcome in
                results = vm.results
                pickerState = vm.state
                if case .creating(let seed) = vm.state, createName.isEmpty {
                    createName = seed
                }
                if let outcome, !consumedOutcome {
                    consumedOutcome = true
                    let exercise: Exercise
                    switch outcome {
                    case .selected(let e), .createdCustom(let e):
                        exercise = e
                    }
                    onPick(exercise)
                    dismiss()
                }
            }
        }
    }

    // MARK: Search field

    private var searchField: some View {
        HStack(spacing: DesignTokens.Spacing.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(MooreColor.textSecondary)
            TextField("", text: $searchText)
                .font(MooreFont.body())
                .autocorrectionDisabled()
                .onChange(of: searchText) { _, newValue in
                    vm.textEntered(newValue)
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    vm.cleared()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(MooreColor.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(DesignTokens.Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Spacing.m)
                .fill(MooreColor.steelRaised)
        )
        .padding(DesignTokens.Spacing.l)
    }

    // MARK: Results / browse / no-results

    private var resultsList: some View {
        List {
            switch pickerState {
            case .idle:
                // Browse: grouped by category, all live rows (SC-exercises §5).
                ForEach(ExerciseCategory.allCases, id: \.self) { category in
                    let rows = results.filter { $0.category == category }
                    if !rows.isEmpty {
                        Section(Self.categoryLabel(category)) {
                            ForEach(rows) { exerciseRow($0) }
                        }
                    }
                }
                Section {
                    // picker.browse_hint
                    Text(UICopy.pickerBrowseHint)
                        .font(MooreFont.body(.footnote))
                        .foregroundStyle(MooreColor.textSecondary)
                }
            case .searching:
                Section {
                    ForEach(results) { exerciseRow($0) }
                    createCustomRow
                }
            case .noResults:
                Section {
                    // picker.search_empty_title / picker.search_empty_sub
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        Text(UICopy.pickerSearchEmptyTitle)
                            .font(MooreFont.display(.body))
                            .foregroundStyle(MooreColor.textPrimary)
                        Text(UICopy.pickerSearchEmptySub)
                            .font(MooreFont.body(.subheadline))
                            .foregroundStyle(MooreColor.textSecondary)
                    }
                    .padding(.vertical, DesignTokens.Spacing.s)
                    // picker.createCustom_cta — the one CTA, last row (#14 §4)
                    createCustomRow
                }
            case .creating, .created, .selected:
                EmptyView()
            }
        }
        .scrollContentBackground(.hidden)
    }

    /// picker.createCustom_cta row — visible while searching or at no-results
    /// (never from idle, per INV-P1).
    private var createCustomRow: some View {
        Button {
            vm.tappedCreateCustom()
        } label: {
            Label(UICopy.pickerCreateCustomCta, systemImage: "plus.circle")
                .foregroundStyle(MooreColor.lime)
        }
    }

    private func exerciseRow(_ exercise: Exercise) -> some View {
        Button {
            vm.tappedRow(id: exercise.id)
        } label: {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text(exercise.name)
                    .font(MooreFont.body())
                    .foregroundStyle(MooreColor.textPrimary)
                Text(Self.categoryLabel(exercise.category))
                    .font(MooreFont.body(.caption))
                    .foregroundStyle(MooreColor.textSecondary)
            }
        }
    }

    // MARK: Inline create form (.creating)

    private func createForm(seedName: String) -> some View {
        Form {
            Section {
                TextField(UICopy.editorNamePlaceholder, text: $createName)
                    .font(MooreFont.body())
            }
            Section {
                Picker(UICopy.pickerCategoryLabel, selection: $createCategory) {
                    ForEach(ExerciseCategory.allCases, id: \.self) { category in
                        Text(Self.categoryLabel(category)).tag(category)
                    }
                }
                Picker(UICopy.pickerMetricLabel, selection: $createMetric) {
                    Text(UICopy.editorSetColumnReps).tag(DefaultMetric.reps)
                    Text(UICopy.editorSetColumnDuration).tag(DefaultMetric.duration)
                }
                Picker(UICopy.pickerEquipmentLabel, selection: $createEquipment) {
                    ForEach(ExerciseEquipment.allCases, id: \.self) { equipment in
                        Text(Self.equipmentLabel(equipment)).tag(equipment)
                    }
                }
            }
            Section {
                Button(UICopy.pickerCreateConfirm) {
                    vm.confirmedCreate(
                        name: createName.isEmpty ? seedName : createName,
                        category: createCategory,
                        defaultMetric: createMetric,
                        equipment: createEquipment
                    )
                }
                .disabled(createName.isEmpty && seedName.isEmpty)
                Button(UICopy.pickerCreateCancel) {
                    vm.cancelledCreate()
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: Labels (data-driven; no contract keys exist for taxonomy names)

    static func categoryLabel(_ category: ExerciseCategory) -> String {
        spacedCapitalized(category.rawValue)
    }

    static func equipmentLabel(_ equipment: ExerciseEquipment) -> String {
        spacedCapitalized(equipment.rawValue)
    }

    /// "fullBody" → "Full Body"
    private static func spacedCapitalized(_ camel: String) -> String {
        var spaced = ""
        for character in camel {
            if character.isUppercase { spaced.append(" ") }
            spaced.append(character)
        }
        return spaced.trimmingCharacters(in: .whitespaces).capitalized
    }
}
