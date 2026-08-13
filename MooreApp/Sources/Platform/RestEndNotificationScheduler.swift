// Ticket #40 — the UserNotifications-backed rest-end summoner (SC-cues@1.0.0
// BR-005 / INV-C6). cue.rest.end is the ONLY cue delivered while the app is
// backgrounded or locked — the one cue that may cross the room to fetch you.
// Cue decisions stay in CueEngine; this is the host scheduling contract
// BR-005 names:
//
//   • schedule at the expiry instant while the scene is backgrounded mid-run
//     (AppState.scenePhaseChanged — the run's timestamps are authoritative);
//   • cancel on foreground / finish (the in-process cue takes over);
//   • re-foreground within CueState.backgroundedNotificationGraceSec of
//     expiry removes the delivered notification in favor of the in-process
//     cue (first-deliverable-opportunity).
//
// Content binds SC-cues §6 copy keys verbatim via UICopy.restNotification*.
// Sound is deliberately `.default`-optional: a silenced device still gets the
// banner + system notification haptic, so the summon never depends on sound
// (BR-004 spirit; #10 point 2).
//
// Mac-build-only: imports UserNotifications.

import Foundation
import UserNotifications

final class RestEndNotificationScheduler: RestEndNotificationScheduling, @unchecked Sendable {

    /// One identifier: the rest-end summons is singular (INV-C6). Scheduling
    /// with an existing pending identifier REPLACES it — exactly the
    /// re-background reschedule semantics BR-005 wants.
    static let restEndIdentifier = "moore.rest.end"

    /// "Permission requested once at first workout start, never a modal
    /// prompt mid-set" — persisted, so a denial is never re-asked on later
    /// launches either.
    private static let authorizationRequestedKey = "moore.notifications.authorizationRequestedOnce"

    func requestAuthorizationOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.authorizationRequestedKey) else { return }
        defaults.set(true, forKey: Self.authorizationRequestedKey)
        // One system prompt, fired from the first workout start — never
        // mid-set. Denial degrades to in-process delivery only: the engine's
        // foreground cues still fire; the summon simply can't leave the app.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            // The cue contract never blocks on the answer (BR-011 spirit).
        }
    }

    func scheduleRestEnd(expiry: Date, exerciseName: String, setNumber: Int, setTotal: Int) {
        let content = UNMutableNotificationContent()
        // rest.notification.title
        content.title = UICopy.restNotificationTitle
        // rest.notification.body — "{exerciseName} — set {n} of {total}"
        content.body = UICopy.restNotificationBody(exerciseName: exerciseName, n: setNumber, total: setTotal)
        // Optional audio axis: silenced devices still deliver the banner and
        // the system notification haptic.
        content.sound = .default

        // UNTimeIntervalNotificationTrigger requires a positive interval; a
        // sub-second remainder clamps to 1s (the expiry was already imminent
        // when the scene backgrounded).
        let interval = max(1, expiry.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: Self.restEndIdentifier, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    func cancelPendingRestEnd() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.restEndIdentifier])
    }

    func removeDeliveredRestEnd() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.restEndIdentifier])
    }
}
