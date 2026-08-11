// contractId: SC-routines @1.0.0
// Home surface read model (§5). One seam: `readModel()` returns a fully materialised
// HomeSnapshot; the Home screen never reads anywhere else and never mutates through it.
// Pure Swift (no SwiftUI) per the ticket's Windows constraint — the SwiftUI layer binds
// to this bundle in a later ticket.

import Foundation

// MARK: - Read-model value types (§3b)

/// One row of the active-session banner / quick-resume card. Present iff a
/// `WorkoutSession` with `endedAt IS NULL` exists (§5).
public struct ActiveSessionSummary: Codable, Equatable, Sendable {
    public var id: String
    public var routineId: String?
    public var routineName: String?          // nil for ad-hoc / Start-empty sessions
    public var startedAt: Date
    public var setsDone: Int                  // completed sets so far
    public var setsTotal: Int                 // total sets in the session

    public init(id: String, routineId: String?, routineName: String?, startedAt: Date, setsDone: Int, setsTotal: Int) {
        self.id = id
        self.routineId = routineId
        self.routineName = routineName
        self.startedAt = startedAt
        self.setsDone = setsDone
        self.setsTotal = setsTotal
    }
}

/// One routine row on Home (§3b). Derived; never persisted (INV-R4).
public struct RoutineRow: Codable, Equatable, Sendable, Identifiable {
    public var routine: Routine
    public var exerciseCount: Int
    public var lastUsedAt: Date?
    public var lastSessionSetCount: Int?
    public var lastSessionVolumeKg: Double?
    public var lastSessionDescription: String? // "{setCount} sets · {volumeKg} kg"; nil when never used
    public var startEnabled: Bool              // = exerciseCount > 0  (BR-001)

    public var id: String { routine.id }

    public init(
        routine: Routine,
        exerciseCount: Int,
        lastUsedAt: Date?,
        lastSessionSetCount: Int?,
        lastSessionVolumeKg: Double?,
        lastSessionDescription: String?,
        startEnabled: Bool
    ) {
        self.routine = routine
        self.exerciseCount = exerciseCount
        self.lastUsedAt = lastUsedAt
        self.lastSessionSetCount = lastSessionSetCount
        self.lastSessionVolumeKg = lastSessionVolumeKg
        self.lastSessionDescription = lastSessionDescription
        self.startEnabled = startEnabled
    }
}

/// The whole Home bundle (§3b). The Surface's single read.
public struct HomeSnapshot: Codable, Equatable, Sendable {
    public var activeSession: ActiveSessionSummary?
    public var streakCount: Int?               // nil when zero completed sessions (BR-005)
    public var routines: [RoutineRow]          // last-used desc, then name asc (BR-006)
    public var folders: [Folder]               // live folders, name asc (BR-006)

    public init(activeSession: ActiveSessionSummary?, streakCount: Int?, routines: [RoutineRow], folders: [Folder]) {
        self.activeSession = activeSession
        self.streakCount = streakCount
        self.routines = routines
        self.folders = folders
    }
}

/// The Home surface's read seam (§5). Exactly one read.
public protocol HomeSurfaceReading {
    func readModel() throws -> HomeSnapshot
}

// MARK: - ViewModel

/// Builds `HomeSnapshot` from the DAOs. `now` is injectable so BR-005's streak and
/// BR-006's last-used ordering are deterministic under test.
public final class HomeSurfaceViewModel: HomeSurfaceReading {
    private let routineDAO: RoutineDAO
    private let folderDAO: FolderDAO
    private let sessionStatsProvider: SessionStatsProviding
    public var now: () -> Date

    public init(
        routineDAO: RoutineDAO,
        folderDAO: FolderDAO,
        sessionStatsProvider: SessionStatsProviding,
        now: @escaping () -> Date = Date.init
    ) {
        self.routineDAO = routineDAO
        self.folderDAO = folderDAO
        self.sessionStatsProvider = sessionStatsProvider
        self.now = now
    }

    public func readModel() throws -> HomeSnapshot {
        let routines = try routineDAO.fetchAll()
        let folders = try folderDAO.fetchAll()
        let now = self.now()

        // Per-routine derivations.
        var rows: [RoutineRow] = []
        rows.reserveCapacity(routines.count)
        for routine in routines {
            let count = try routineDAO.exerciseCount(routineId: routine.id)
            let last = try sessionStatsProvider.lastCompletedSessionStats(routineId: routine.id)
            let desc: String? = last.map { Self.sessionDescription(setCount: $0.setCount, volumeKg: $0.volumeKg) }
            rows.append(RoutineRow(
                routine: routine,
                exerciseCount: count,
                lastUsedAt: last?.completedAt,
                lastSessionSetCount: last?.setCount,
                lastSessionVolumeKg: last?.volumeKg,
                lastSessionDescription: desc,
                startEnabled: count > 0        // BR-001
            ))
        }
        // BR-006: last-used desc, ties/never-used fall back to name asc.
        rows.sort { a, b in
            switch (a.lastUsedAt, b.lastUsedAt) {
            case let (la?, lb?): return la != lb ? la > lb : a.routine.name < b.routine.name
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.routine.name < b.routine.name
            }
        }

        // Active session (quick-resume card).
        let active = try sessionStatsProvider.activeSession()

        // Streak (BR-005).
        let completedDates = try sessionStatsProvider.completedSessionDates()
        let streak = StreakCalculator.streakCount(completedAtDates: completedDates, now: now)

        return HomeSnapshot(
            activeSession: active,
            streakCount: streak,
            routines: rows,
            folders: folders
        )
    }

    /// §3b `lastSessionDescription` — the format the UI binds to `home.routineRow_lastUsed`.
    static func sessionDescription(setCount: Int, volumeKg: Double) -> String {
        let volume = volumeKg.rounded()
        let volumeStr = volume.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(volume))
            : String(format: "%.1f", volume)
        return "\(setCount) sets · \(volumeStr) kg"
    }
}

// MARK: - Session stats seam

/// Statistics for one completed session started from a routine.
public struct SessionStats: Equatable, Sendable {
    public var completedAt: Date
    public var setCount: Int
    public var volumeKg: Double

    public init(completedAt: Date, setCount: Int, volumeKg: Double) {
        self.completedAt = completedAt
        self.setCount = setCount
        self.volumeKg = volumeKg
    }
}

/// The WorkoutSession read seam the Home surface depends on (§5). Owned by the
/// session/foundation layer; MooreRoutines only consumes it. Kept narrow so #22's
/// session module can supply the concrete implementation.
public protocol SessionStatsProviding {
    /// The single in-flight session, if any (`endedAt IS NULL`), for the resume card.
    func activeSession() throws -> ActiveSessionSummary?
    /// Every completed session's `endedAt` — feeds BR-005's streak.
    func completedSessionDates() throws -> [Date]
    /// The most recent completed session started from `routineId`, with its
    /// completed-set count and Σ(actualWeight × actualReps) over completed work sets.
    func lastCompletedSessionStats(routineId: String) throws -> SessionStats?
}
