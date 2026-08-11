// contractId: SC-exercises @1.0.0
// PickerViewModel: owns the transient state machine of the picker sheet (§2b).
// Pure layer — no SwiftUI, no Combine. Closure-based observation keeps this
// portable: #21's surface wraps this in its own @Published/@Observable adapter.

import Foundation

public enum PickerOutcome: Equatable, Sendable {
    case selected(exercise: Exercise)
    case createdCustom(exercise: Exercise)
}

public final class PickerViewModel {
    public private(set) var state: PickerState = .idle
    public private(set) var results: [Exercise] = []
    public var query: String = ""      { didSet { notify() } }
    public var categoryFilter: ExerciseCategory? { didSet { refreshResults() } }
    public var excludeIds: Set<String> = [] { didSet { refreshResults() } }
    public let allowCreate: Bool

    private let dao: ExerciseDAO
    private var outcome: PickerOutcome?
    private var observers: [Observer] = []

    public init(
        dao: ExerciseDAO,
        allowCreate: Bool = true,
        initialQuery: String = "",
        categoryFilter: ExerciseCategory? = nil,
        excludeIds: Set<String> = []
    ) {
        self.dao = dao
        self.allowCreate = allowCreate
        self.categoryFilter = categoryFilter
        self.excludeIds = excludeIds
        self.query = initialQuery
        self.state = initialQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .idle
            : .searching(query: initialQuery)
        refreshResults()
    }

    // MARK: - Observation

    /// Observers are called with (viewModel, latestOutcome-or-nil). The caller
    /// consumes the outcome; the picker only synthesizes one per presentation.
    public typealias Observer = (PickerViewModel, PickerOutcome?) -> Void

    public func observe(_ body: @escaping Observer) {
        observers.append(body)
        body(self, outcome)
    }

    private func notify() { observers.forEach { $0(self, outcome) } }

    // MARK: - Input events (named per §2b transition matrix)

    public func textEntered(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            cleared()
            return
        }
        query = text
        state = .searching(query: text)
        refreshResults()
    }

    public func cleared() {
        query = ""
        state = .idle
        refreshResults()
    }

    public func tappedRow(id: String) {
        guard let exercise = try? dao.getById(id), exercise.deletedAt == nil else { return }
        outcome = .selected(exercise: exercise)
        state = .selected(exerciseId: id)
        notify()
    }

    /// Tap on `picker.createCustom` CTA. Only legal from searching/noResults.
    public func tappedCreateCustom() {
        guard allowCreate else { return }
        switch state {
        case .searching(let q):     state = .creating(seedName: q)
        case .noResults(let q):     state = .creating(seedName: q)
        case .idle:                 break   // per INV-P1 the CTA isn't visible from idle
        case .creating, .created, .selected: break
        }
        notify()
    }

    public func confirmedCreate(name: String, category: ExerciseCategory, defaultMetric: DefaultMetric, equipment: ExerciseEquipment) {
        guard case .creating = state else { return }
        do {
            let result = try dao.insertCustom(name: name, category: category, defaultMetric: defaultMetric, equipment: equipment)
            let exercise: Exercise
            switch result {
            case .inserted(let e), .matchedExisting(let e), .restoredCustom(let e), .restoredBuiltIn(let e):
                exercise = e
            }
            self.outcome = .createdCustom(exercise: exercise)
            state = .created(exerciseId: exercise.id)
        } catch {
            state = .noResults(query: query)
        }
        notify()
    }

    public func cancelledCreate() {
        guard case .creating(let seed) = state else { return }
        state = .searching(query: seed)
        notify()
    }

    public func cancelledPicker() {
        outcome = nil
        state = .idle
        notify()
    }

    // MARK: - Helpers

    private func refreshResults() {
        do {
            let rows = try dao.searchNamed(query, category: categoryFilter, excludeIds: excludeIds)
            results = rows
            if rows.isEmpty && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                state = .noResults(query: query)
            } else if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                state = .searching(query: query)
            } else {
                state = .idle
            }
        } catch {
            results = []
            state = .noResults(query: query)
        }
        notify()
    }
}
