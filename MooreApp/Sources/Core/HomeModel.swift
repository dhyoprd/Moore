// Ticket #33 — Home surface app model. Drives the existing HomeSurfaceViewModel
// (SC-routines §5: `readModel()` is the ONLY read) and the DAO write seams
// (RoutineDAO/FolderDAO/Materialize). No business logic is reimplemented here —
// this file only orchestrates: read → expose, gesture → DAO call → re-read.
//
// Foundation-only (@Observable, no SwiftUI) so it parses/verifies off-Mac.

import Foundation
import Observation
import MooreRoutines
import MooreWorkout

// MARK: - Home grouping (BR-006 render shape)

/// One render group on Home: a real folder, or the trailing Unfiled pseudo-group.
/// Derived from HomeSnapshot per BR-006 — folders name asc (the DAO already
/// orders them), routines inside each group keep the snapshot's last-used
/// desc / name asc order, Unfiled last.
public enum HomeGroup: Identifiable, Equatable {
    case folder(Folder, [RoutineRow])
    case unfiled([RoutineRow])

    public var id: String {
        switch self {
        case .folder(let folder, _): return folder.id
        case .unfiled: return "unfiled"
        }
    }

    public var routines: [RoutineRow] {
        switch self {
        case .folder(_, let rows): return rows
        case .unfiled(let rows): return rows
        }
    }
}

// MARK: - HomeModel

@Observable
public final class HomeModel {
    /// The single Home read (SC-routines §5). Starts empty; refresh() materialises.
    public private(set) var snapshot: HomeSnapshot
    /// Last write-path error, surfaced inline (copy-driven states only, no toasts).
    public private(set) var errorMessage: String?

    private let surface: HomeSurfaceViewModel
    private let routineDAO: RoutineDAO
    private let folderDAO: FolderDAO
    private let materialize: Materialize

    public init(
        surface: HomeSurfaceViewModel,
        routineDAO: RoutineDAO,
        folderDAO: FolderDAO,
        materialize: Materialize
    ) {
        self.surface = surface
        self.routineDAO = routineDAO
        self.folderDAO = folderDAO
        self.materialize = materialize
        self.snapshot = (try? surface.readModel())
            ?? HomeSnapshot(activeSession: nil, streakCount: nil, routines: [], folders: [])
    }

    // MARK: Read (the ONLY read is readModel)

    public func refresh() {
        do {
            snapshot = try surface.readModel()
            errorMessage = nil
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// BR-006 render shape: folder groups in folder-name order, then Unfiled.
    /// When there are no real folders, everything renders flat (single group,
    /// no "Unfiled" header — the pseudo-group only distinguishes when folders exist).
    public var groups: [HomeGroup] {
        let rows = snapshot.routines
        let folders = snapshot.folders
        guard !folders.isEmpty else {
            return rows.isEmpty ? [] : [.unfiled(rows)]
        }
        var result: [HomeGroup] = []
        var unfiled: [RoutineRow] = []
        let byFolder = Dictionary(grouping: rows, by: { $0.routine.folderId })
        for folder in folders {
            result.append(.folder(folder, byFolder[folder.id] ?? []))
        }
        unfiled = byFolder[nil] ?? []
        if !unfiled.isEmpty {
            result.append(.unfiled(unfiled))
        }
        return result
    }

    /// True when the first-run empty state (home.empty_*) renders: no routines at all.
    public var isEmpty: Bool {
        snapshot.routines.isEmpty && snapshot.folders.isEmpty
    }

    // MARK: Start / resume (SC-workout-logging §5 materialisation)

    /// Start a session from a routine row: snapshot-copy its live PlannedSets into
    /// a fresh session (§2b / INV-R5). Returns the new session id, or nil when the
    /// routine has no plan (BR-001: zero-exercise routines never start).
    @discardableResult
    public func start(routineId: String) -> String? {
        do {
            let sets = try routineDAO.fetchSets(routineId: routineId)
            guard !sets.isEmpty else { return nil }   // BR-001
            let inputs = sets.map { set in
                Materialize.PlannedSetInput(
                    exerciseId: set.exerciseId,
                    plannedWeight: set.plannedWeight,
                    plannedReps: set.plannedReps,
                    plannedDuration: set.plannedDuration,
                    setClass: set.setClass.flatMap { MooreWorkout.SetClass(rawValue: $0.rawValue) }
                )
            }
            let sessionId = try materialize.startSession(routineId: routineId, plannedSets: inputs)
            refresh()
            return sessionId
        } catch {
            errorMessage = "\(error)"
            return nil
        }
    }

    /// Start empty — the always-visible ad-hoc escape hatch (#14 §1): a session
    /// with `routineId = NULL` and an empty flat list. Never gated, never ghosted.
    @discardableResult
    public func startEmpty() -> String? {
        do {
            let sessionId = try materialize.startSession(routineId: nil, plannedSets: [])
            refresh()
            return sessionId
        } catch {
            errorMessage = "\(error)"
            return nil
        }
    }

    // MARK: Routine mutations (write seam — typed DAO calls, then re-read)

    /// BR-002 duplicate — true copy, "Copy of " name, enters lifecycle as draft.
    public func duplicate(routineId: String) {
        do {
            _ = try routineDAO.duplicate(sourceId: routineId)
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// BR-004 delete routine — confirm-first is the UI's job (confirmationDialog);
    /// the write is a tombstone (INV-3), never a hard delete.
    public func deleteRoutine(routineId: String) {
        do {
            try routineDAO.tombstone(id: routineId)
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// BR-004/BR-003 delete folder — tombstones the folder, contained routines
    /// survive as Unfiled (FolderDAO handles the unfile in one transaction).
    public func deleteFolder(folderId: String) {
        do {
            try folderDAO.tombstone(id: folderId)
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }
}
