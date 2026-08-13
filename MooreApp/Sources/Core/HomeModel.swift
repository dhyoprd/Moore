// Ticket #33 — Home surface app model. Drives the existing HomeSurfaceViewModel
// (SC-routines §5: `readModel()` is the ONLY read) and the DAO write seams
// (RoutineDAO/FolderDAO). No business logic is reimplemented here — this file
// only orchestrates: read → expose, gesture → DAO call → re-read.
//
// #34: session start moved to WorkoutSessionModel (AppState.startWorkout /
// startWorkoutEmpty) — one owner for the materialise → present → log → finish
// lifecycle. HomeModel stays the Home READ surface + routine/folder mutations.
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
    /// #35: per-routine "Next:" preview line (SC-progression BR-018 — the
    /// one-line routine-preview surface). Keyed by routineId; holds the first
    /// pair (in routine order) that produces a line. Recomputed on refresh().
    public private(set) var nextLineByRoutine: [String: String] = [:]
    /// Last write-path error, surfaced inline (copy-driven states only, no toasts).
    public private(set) var errorMessage: String?

    private let surface: HomeSurfaceViewModel
    private let routineDAO: RoutineDAO
    private let folderDAO: FolderDAO
    private let progression: ProgressionModel

    public init(
        surface: HomeSurfaceViewModel,
        routineDAO: RoutineDAO,
        folderDAO: FolderDAO,
        progression: ProgressionModel
    ) {
        self.surface = surface
        self.routineDAO = routineDAO
        self.folderDAO = folderDAO
        self.progression = progression
        self.snapshot = (try? surface.readModel())
            ?? HomeSnapshot(activeSession: nil, streakCount: nil, routines: [], folders: [])
        refreshNextLines()
    }

    // MARK: Read (the ONLY read is readModel)

    public func refresh() {
        do {
            snapshot = try surface.readModel()
            refreshNextLines()
            errorMessage = nil
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// #35: derive each routine's one-line "Next:" preview. Suggestions are
    /// read-only here (ProgressionModel discards the engine's record mutation
    /// on the preview path — BR-020: suggestions are materialization-time).
    private func refreshNextLines() {
        var lines: [String: String] = [:]
        for row in snapshot.routines {
            guard let sets = try? routineDAO.fetchSets(routineId: row.routine.id) else { continue }
            var seen = Set<String>()
            for set in sets {
                guard !seen.contains(set.exerciseId) else { continue }
                seen.insert(set.exerciseId)
                if let line = progression.nextLineText(routineId: row.routine.id, exerciseId: set.exerciseId) {
                    lines[row.routine.id] = line
                    break
                }
            }
        }
        nextLineByRoutine = lines
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
