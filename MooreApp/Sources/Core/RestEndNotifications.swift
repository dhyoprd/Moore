// Ticket #40 — rest-end notification-class delivery seam (SC-cues@1.0.0
// BR-005 / INV-C6). cue.rest.end is the ONE cue that reaches a backgrounded
// or locked device — the sole summoner. Cue decisions stay in CueEngine; this
// is the host scheduling contract BR-005 names: the local notification is
// scheduled for the expiry instant while the scene is backgrounded mid-run,
// and cancelled on foreground/finish. Re-foreground within the grace window
// (CueState.backgroundedNotificationGraceSec) removes the delivered
// notification in favor of the in-process cue.
//
// The UserNotifications-backed implementation lives in
// Platform/RestEndNotificationScheduler.swift (Mac-build-only); this file is
// Foundation-only so it parses/verifies off-Mac.

import Foundation

/// The rest-end summoner surface. Content binds SC-cues §6 copy keys verbatim
/// (rest.notification.title / rest.notification.body — UICopy.restNotification*).
public protocol RestEndNotificationScheduling: Sendable {
    /// One-time permission request. Called at the first workout start, never
    /// mid-set; the implementation guards the once-semantics itself, so
    /// calling on every start is lawful.
    func requestAuthorizationOnce()

    /// Schedule the rest-end notification for `expiry`. Idempotent by
    /// identifier — re-scheduling replaces any pending request.
    func scheduleRestEnd(expiry: Date, exerciseName: String, setNumber: Int, setTotal: Int)

    /// Cancel the pending request (scene foregrounded / session finished).
    func cancelPendingRestEnd()

    /// Remove an already-delivered notification (BR-005 grace re-foreground).
    func removeDeliveredRestEnd()
}

/// Boot-failure / diagnostics fallback: renders nothing.
public struct NoopRestEndNotifier: RestEndNotificationScheduling {
    public init() {}
    public func requestAuthorizationOnce() {}
    public func scheduleRestEnd(expiry: Date, exerciseName: String, setNumber: Int, setTotal: Int) {}
    public func cancelPendingRestEnd() {}
    public func removeDeliveredRestEnd() {}
}
