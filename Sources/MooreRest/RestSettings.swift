// contractId: SC-rest @1.0.0
// Level-4 global defaults (#9 v1: compound 180s / isolation 90s). Value type;
// persisted by RestSettingsDAO in Sources/MooreRest/RestSettingsDAO.swift
// against the migration-0007 `app_setting` singleton rows.

import Foundation

public struct RestSettings: Codable, Equatable, Sendable {
    /// Default rest for `Exercise.category == .compound` (180s after migrate).
    public var defaultRestCompoundSec: Int
    /// Default rest for isolation AND all duration-metric exercises (90s).
    public var defaultRestIsolationSec: Int

    public init(defaultRestCompoundSec: Int, defaultRestIsolationSec: Int) {
        self.defaultRestCompoundSec = defaultRestCompoundSec
        self.defaultRestIsolationSec = defaultRestIsolationSec
    }

    /// The #9 v1 defaults, matching the 0007 seed (INV-S2).
    public static let `default` = RestSettings(
        defaultRestCompoundSec: 180,
        defaultRestIsolationSec: 90
    )
}
