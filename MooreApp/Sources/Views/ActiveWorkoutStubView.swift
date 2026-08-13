// Ticket #33 — Active Workout presentation STUB. #33 wires the reserved modal
// semantics (full-screen cover over the tab bar, non-dismissable, minimize
// chevron → mini-player per blueprint #7 §2); the money screen itself is #34.
//
// Non-dismissable: fullScreenCover has no swipe-dismiss; interactive dismissal
// is disabled anyway — the only exit is the minimize chevron (collapse to the
// mini-player) or, later, Finish/Discard through the session FSM (#34).

import SwiftUI

struct ActiveWorkoutStubView: View {
    @Environment(AppState.self) private var appState
    let sessionId: String

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.l) {
            // Header: minimize chevron top-left, session title, elapsed slot (#7 §3).
            HStack {
                Button {
                    appState.minimizeWorkout()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(MooreColor.textPrimary)
                        .padding(DesignTokens.Spacing.s)
                }
                .buttonStyle(.plain)

                Spacer()

                // workout.title "{routineName}" / workout.adhoc_title "Workout"
                Text(UICopy.workoutTitle(routineName: appState.activeSession?.routineName))
                    .font(MooreFont.display(.headline))
                    .foregroundStyle(MooreColor.textPrimary)

                Spacer()

                // Symmetric placeholder keeps the title centered (elapsed slot, #34).
                Color.clear.frame(width: 40, height: 1)
            }
            .padding(.horizontal, DesignTokens.Spacing.l)
            .padding(.top, DesignTokens.Spacing.l)

            Spacer()

            VStack(spacing: DesignTokens.Spacing.m) {
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.system(size: 40))
                    .foregroundStyle(MooreColor.lime)
                if let session = appState.activeSession {
                    Text(UICopy.resumeLabel(
                        routineName: session.routineName,
                        setsDone: session.setsDone,
                        setsTotal: session.setsTotal
                    ))
                    .font(MooreFont.numeric(.subheadline))
                    .foregroundStyle(MooreColor.textSecondary)
                }
                // workout.empty.* copy for the zero-set state (#14 §2)
                Text(UICopy.workoutEmptyLine)
                    .font(MooreFont.display(.title3))
                    .foregroundStyle(MooreColor.textPrimary)
                Text(UICopy.workoutStartEmptyHelp)
                    .font(MooreFont.body(.subheadline))
                    .foregroundStyle(MooreColor.textSecondary)
            }

            Spacer()

            Text("Session \(sessionId.prefix(8)) — money screen ships in #34")
                .font(MooreFont.numeric(.caption2))
                .foregroundStyle(MooreColor.textSecondary.opacity(0.6))
                .padding(.bottom, DesignTokens.Spacing.l)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The money screen is opaque steel — glass never appears there (#17).
        .background(MooreColor.steelBase)
        .interactiveDismissDisabled()
    }
}
