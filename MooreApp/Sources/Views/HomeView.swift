// Ticket #33 — Home surface. Renders exactly what HomeSnapshot carries (the
// single read, SC-routines §5): resume card, streak chip (hidden until the first
// completed session, BR-005), collapsible folders + Unfiled (BR-006), routine
// rows (name, exercise count, last-used, last-session stats), Start (disabled on
// zero-exercise routines, BR-001, copy not toast), the always-visible Start-empty
// escape hatch (#14 §1), the [+ Routine] FAB, and the single first-run empty-state
// CTA (home.empty_*). Writes go through HomeModel's DAO calls, then re-read.

import SwiftUI
import MooreRoutines

// MARK: - Editor sheet identity

struct RoutineSheetConfig: Identifiable, Equatable {
    enum Mode: Equatable {
        case create
        case edit(routineId: String)
    }
    let mode: Mode

    var id: String {
        switch mode {
        case .create: return "create"
        case .edit(let routineId): return routineId
        }
    }
}

// MARK: - Home

struct HomeView: View {
    @Environment(AppState.self) private var appState

    @State private var editorSheet: RoutineSheetConfig?
    @State private var routinePendingDelete: RoutineRow?
    @State private var folderPendingDelete: Folder?
    @State private var collapsedFolders: Set<String> = []   // default expanded

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        if let home = appState.home, let deps = appState.dependencies {
            homeScreen(home: home, deps: deps)
        }
    }

    private func homeScreen(home: HomeModel, deps: AppDependencies) -> some View {
        NavigationStack {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
                        if home.isEmpty {
                            firstRunEmptyState
                                .frame(maxWidth: .infinity)
                                .padding(.top, DesignTokens.Spacing.xxl)
                        } else {
                            if let active = home.snapshot.activeSession {
                                resumeCard(active)
                            }
                            if let streak = home.snapshot.streakCount {
                                Text(UICopy.streakLabel(streak))
                                    .mooreChip()
                            }
                            ForEach(home.groups) { group in
                                groupView(group, home: home)
                            }
                            if let message = home.errorMessage {
                                Text(message)
                                    .font(MooreFont.numeric(.caption))
                                    .foregroundStyle(MooreColor.textSecondary)
                            }
                        }
                    }
                    .padding(.horizontal, DesignTokens.Spacing.l)
                    .padding(.bottom, 96)   // room for the FAB
                }
                .background(MooreColor.steelBase)
                .navigationTitle(UICopy.tabHome)
                .toolbar {
                    // Start empty — always visible, never ghosted (#14 §1).
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(UICopy.homeStartEmptyCta) {
                            // #34: the session lifecycle (materialise → present →
                            // log → finish) is owned by AppState + WorkoutSessionModel.
                            appState.startWorkoutEmpty()
                        }
                        .buttonStyle(MooreSecondaryButtonStyle())
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    // The [+ Routine] FAB — creation affordance everywhere (#7 §4).
                    Button {
                        editorSheet = RoutineSheetConfig(mode: .create)
                    } label: {
                        Label(UICopy.homeNewRoutineFab, systemImage: "plus")
                    }
                    .buttonStyle(MoorePrimaryButtonStyle())
                    .padding(DesignTokens.Spacing.xl)
                }
                .sheet(item: $editorSheet) { config in
                    RoutineEditorSheet(config: config, deps: deps) {
                        home.refresh()
                    }
                }
                .confirmationDialog(
                    routinePendingDelete.map { UICopy.confirmDeleteTitle(name: $0.routine.name) } ?? "",
                    isPresented: Binding(
                        get: { routinePendingDelete != nil },
                        set: { if !$0 { routinePendingDelete = nil } }
                    ),
                    titleVisibility: .visible,
                    presenting: routinePendingDelete
                ) { row in
                    Button(UICopy.confirmDeleteRoutineConfirm, role: .destructive) {
                        home.deleteRoutine(routineId: row.routine.id)
                        appState.refreshActiveSession()
                    }
                    Button(UICopy.confirmDeleteRoutineCancel, role: .cancel) {}
                } message: { _ in
                    Text(UICopy.confirmDeleteRoutineBody)
                }
                .confirmationDialog(
                    folderPendingDelete.map { UICopy.confirmDeleteTitle(name: $0.name) } ?? "",
                    isPresented: Binding(
                        get: { folderPendingDelete != nil },
                        set: { if !$0 { folderPendingDelete = nil } }
                    ),
                    titleVisibility: .visible,
                    presenting: folderPendingDelete
                ) { folder in
                    Button(UICopy.confirmDeleteFolderConfirm, role: .destructive) {
                        home.deleteFolder(folderId: folder.id)
                    }
                    Button(UICopy.confirmDeleteFolderCancel, role: .cancel) {}
                } message: { _ in
                    Text(UICopy.confirmDeleteFolderBody)
                }
                .task {
                    home.refresh()
                    appState.refreshActiveSession()
                }
        }
    }

    // MARK: Sections

    /// The single first-run CTA (home.empty_*): one primary action, typography-first.
    private var firstRunEmptyState: some View {
        VStack(spacing: DesignTokens.Spacing.l) {
            Text(UICopy.homeEmptyTitle)
                .font(MooreFont.display(.largeTitle))
                .foregroundStyle(MooreColor.textPrimary)
            Text(UICopy.homeEmptySub)
                .font(MooreFont.body())
                .foregroundStyle(MooreColor.textSecondary)
                .multilineTextAlignment(.center)
            Button(UICopy.homeEmptyCta) {
                editorSheet = RoutineSheetConfig(mode: .create)
            }
            .buttonStyle(MoorePrimaryButtonStyle())
        }
        .padding(.horizontal, DesignTokens.Spacing.l)
    }

    /// Quick-resume card (#7 §4): exactly one, only while a session is active;
    /// tapping = 1-tap resume.
    private func resumeCard(_ active: ActiveSessionSummary) -> some View {
        Button {
            appState.presentWorkout(sessionId: active.id)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    Text(UICopy.resumeLabel(
                        routineName: active.routineName,
                        setsDone: active.setsDone,
                        setsTotal: active.setsTotal
                    ))
                    .font(MooreFont.display(.subheadline))
                    .foregroundStyle(MooreColor.textPrimary)
                }
                Spacer()
                Text(UICopy.homeResumeCta)
                    .font(MooreFont.display(.subheadline))
                    .foregroundStyle(MooreColor.lime)
            }
            .mooreCard()
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func groupView(_ group: HomeGroup, home: HomeModel) -> some View {
        switch group {
        case .folder(let folder, let rows):
            DisclosureGroup(
                isExpanded: Binding(
                    get: { !collapsedFolders.contains(folder.id) },
                    set: { expanded in
                        if expanded { collapsedFolders.remove(folder.id) }
                        else { collapsedFolders.insert(folder.id) }
                    }
                )
            ) {
                VStack(spacing: DesignTokens.Spacing.s) {
                    ForEach(rows) { row in
                        routineRow(row, home: home)
                    }
                }
                .padding(.top, DesignTokens.Spacing.s)
            } label: {
                Text(folder.name.uppercased())
                    .font(MooreFont.display(.footnote))
                    .foregroundStyle(MooreColor.textSecondary)
                    .contextMenu {
                        Button(UICopy.homeFolderDelete, role: .destructive) {
                            folderPendingDelete = folder
                        }
                    }
            }
            .tint(MooreColor.textSecondary)
        case .unfiled(let rows):
            // Render the "Unfiled" header only when real folders exist — with no
            // folders at all, the routines render flat (BR-006 pseudo-group).
            if !home.snapshot.folders.isEmpty {
                Text(UICopy.homeUnfiledHeader.uppercased())
                    .font(MooreFont.display(.footnote))
                    .foregroundStyle(MooreColor.textSecondary)
            }
            VStack(spacing: DesignTokens.Spacing.s) {
                ForEach(rows) { row in
                    routineRow(row, home: home)
                }
            }
        }
    }

    /// One routine row: name · exercise count · last-used + last-session stats ·
    /// Start (BR-001 disabled on zero exercises, with the copy hint). Tap body =
    /// edit; context menu = Duplicate / Delete (BR-002 / BR-004).
    private func routineRow(_ row: RoutineRow, home: HomeModel) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.m) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                // home.routineRow_title
                Text(row.routine.name)
                    .font(MooreFont.display(.body))
                    .foregroundStyle(MooreColor.textPrimary)
                // home.routineRow_sub — "{count} exercises"
                Text(UICopy.routineRowSub(count: row.exerciseCount))
                    .font(MooreFont.body(.subheadline))
                    .foregroundStyle(MooreColor.textSecondary)
                // home.routineRow_lastUsed — "{relativeDate} · {setCount} sets · {volumeKg} kg"
                if let lastUsed = row.lastUsedAt, let description = row.lastSessionDescription {
                    Text(UICopy.routineRowLastUsed(
                        relativeDate: Self.relativeFormatter.localizedString(for: lastUsed, relativeTo: Date()),
                        sessionDescription: description
                    ))
                    .font(MooreFont.numeric(.caption))
                    .foregroundStyle(MooreColor.textSecondary)
                }
                if !row.startEnabled {
                    // BR-001 disabled state uses copy, never a toast.
                    Text(UICopy.editorStartDisabledHint)
                        .font(MooreFont.body(.caption))
                        .foregroundStyle(MooreColor.textSecondary.opacity(0.8))
                }
            }
            Spacer()
            // home.routineRow_start
            Button(UICopy.homeRoutineRowStart) {
                // #34: materialise + present owned by AppState + WorkoutSessionModel.
                appState.startWorkout(routineId: row.routine.id)
            }
            .buttonStyle(MoorePrimaryButtonStyle())
            .disabled(!row.startEnabled)
            .opacity(row.startEnabled ? 1 : 0.4)
        }
        .mooreCard()
        .contentShape(Rectangle())
        .onTapGesture {
            editorSheet = RoutineSheetConfig(mode: .edit(routineId: row.routine.id))
        }
        .contextMenu {
            Button(UICopy.homeRoutineRowDuplicate) {
                home.duplicate(routineId: row.routine.id)
            }
            Button(UICopy.homeRoutineRowDelete, role: .destructive) {
                routinePendingDelete = row
            }
        }
    }
}
