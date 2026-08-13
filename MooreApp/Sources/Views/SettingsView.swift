// Ticket #38 — Settings tab: the SC-settings@1.0.0 surface. Five sections per
// the contract + blueprint #7 §7: Units (display-only kg/lb), Rest defaults
// (SC-rest's two level-4 keys), Body metrics (date-descending trend list + add
// sheet), Data & sync (Hevy CSV import entry — #39's live flow, full-file
// backup export via ShareLink, permanently greyed cloud-sync toggle, storage
// stats), and exercise tombstones (list + restore). All copy binds UICopy's
// contract keys verbatim; all logic lives in the Foundation-only SettingsModel
// driving SettingsEngine / SettingsDAO — this view is layout + bindings.

import SwiftUI
import UniformTypeIdentifiers
import MooreSettings

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var showingAddMetric = false
    /// #39: system file picker for the Hevy CSV export (SC-import §2 idle →
    /// file-picked → parsing).
    @State private var showingImportPicker = false
    /// #39: the import flow sheet (preview → applying → done | error).
    @State private var showingImportFlow = false

    var body: some View {
        if let model = appState.settings {
            NavigationStack {
                List {
                    unitsSection(model)
                    restDefaultsSection(model)
                    bodyMetricsSection(model)
                    dataSyncSection(model)
                    tombstonesSection(model)
                    errorSection(model)
                }
                .scrollContentBackground(.hidden)
                .background(MooreColor.steelBase)
                // settings.title
                .navigationTitle(UICopy.settingsTitle)
                // Add-entry sheet (BR-006) over the engine's validation gate.
                .sheet(isPresented: $showingAddMetric) {
                    BodyMetricSheet(model: model)
                }
                // settings.dataSync.exportedToast — "Backup saved: {fileName}".
                .overlay(alignment: .bottom) {
                    if let fileName = model.exportedToastFileName {
                        toast(fileName: fileName) { model.clearToast() }
                    }
                }
                // #39 — Hevy CSV import flow (SC-import §2): the system file
                // picker hands a URL to the Foundation-only ImportModel, then
                // the flow sheet renders preview → applying → done | error.
                .fileImporter(
                    isPresented: $showingImportPicker,
                    allowedContentTypes: [UTType.commaSeparatedText, UTType.plainText],
                    allowsMultipleSelection: false
                ) { result in
                    guard let importModel = appState.importFlow else { return }
                    switch result {
                    case .success(let urls):
                        guard let url = urls.first else { return }
                        importModel.loadFile(at: url)
                        showingImportFlow = true
                    case .failure(let error):
                        // The picker reports cancellation as a failure — a
                        // no-op, not an import error.
                        let nsError = error as NSError
                        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSUserCancelledError {
                            return
                        }
                        importModel.filePickFailed(detail: "\(error)")
                        showingImportFlow = true
                    }
                }
                .sheet(isPresented: $showingImportFlow) {
                    if let importModel = appState.importFlow {
                        HevyImportFlowView(model: importModel)
                    }
                }
            }
        } else {
            // phase == .failed renders FatalBootView instead of the tab bar;
            // this branch is defensive only.
            MooreColor.steelBase.ignoresSafeArea()
        }
    }

    // MARK: Units (BR-001 / INV-ST1)

    /// settings.units.title — the toggle writes one settings row, never data.
    private func unitsSection(_ model: SettingsModel) -> some View {
        Section {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
                // settings.units.weight
                Text(UICopy.settingsUnitsWeight)
                    .font(MooreFont.body())
                    .foregroundStyle(MooreColor.textPrimary)
                Picker(
                    UICopy.settingsUnitsWeight,
                    selection: Binding(
                        get: { model.settings.weightUnit },
                        set: { model.setWeightUnit($0) }
                    )
                ) {
                    ForEach(WeightUnit.allCases, id: \.self) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(.vertical, DesignTokens.Spacing.xs)
        } header: {
            sectionHeader(UICopy.settingsUnitsTitle)
        }
    }

    // MARK: Rest defaults (BR-005)

    /// settings.restDefaults.title — edits SC-rest's level-4 keys upsert-on-change;
    /// per-set/per-routine overrides still win (SC-rest BR-001 levels 1–3).
    private func restDefaultsSection(_ model: SettingsModel) -> some View {
        Section {
            restRow(
                label: UICopy.settingsRestDefaultsCompound,
                seconds: model.settings.defaultRestCompoundSec
            ) { model.updateRestDefaults(compoundSec: $0, isolationSec: nil) }
            restRow(
                label: UICopy.settingsRestDefaultsIsolation,
                seconds: model.settings.defaultRestIsolationSec
            ) { model.updateRestDefaults(compoundSec: nil, isolationSec: $0) }
        } header: {
            sectionHeader(UICopy.settingsRestDefaultsTitle)
        }
    }

    private func restRow(label: String, seconds: Int, commit: @escaping (Int) -> Void) -> some View {
        HStack(spacing: DesignTokens.Spacing.s) {
            Text(label)
                .font(MooreFont.body())
                .foregroundStyle(MooreColor.textPrimary)
            Spacer()
            // Commits on submit/focus-loss — upsert-on-change, never per keystroke.
            TextField(
                "",
                value: Binding(
                    get: { seconds },
                    set: { commit($0) }
                ),
                format: .number
            )
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .font(MooreFont.numeric())
            .foregroundStyle(MooreColor.textPrimary)
            .frame(width: 64)
            // settings.restDefaults.value — "{n}s"
            .accessibilityValue(UICopy.restDefaultsValue(seconds))
            // The unit suffix from the settings.restDefaults.value shape ("{n}s").
            Text("s")
                .font(MooreFont.body())
                .foregroundStyle(MooreColor.textSecondary)
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    // MARK: Body metrics (BR-006 / BR-007)

    private func bodyMetricsSection(_ model: SettingsModel) -> some View {
        Group {
            Section {
                // settings.bodyMetrics.addCta
                Button {
                    showingAddMetric = true
                } label: {
                    Label(UICopy.settingsBodyMetricsAddCta, systemImage: "plus")
                        .font(MooreFont.display(.subheadline))
                        .foregroundStyle(MooreColor.lime)
                }
            } header: {
                sectionHeader(UICopy.settingsBodyMetricsTitle)
            }

            // settings.bodyMetrics.trendTitle — date-descending list, no charts (BR-007).
            Section {
                if model.bodyMetrics.isEmpty {
                    // settings.bodyMetrics.empty
                    Text(UICopy.settingsBodyMetricsEmpty)
                        .font(MooreFont.body())
                        .foregroundStyle(MooreColor.textSecondary)
                } else {
                    ForEach(model.bodyMetrics, id: \.id) { metric in
                        metricRow(model, metric: metric)
                    }
                    .onDelete { offsets in
                        for index in offsets where index < model.bodyMetrics.count {
                            model.deleteBodyMetric(id: model.bodyMetrics[index].id)
                        }
                    }
                }
            } header: {
                sectionHeader(UICopy.settingsBodyMetricsTrendTitle)
            }
        }
    }

    private func metricRow(_ model: SettingsModel, metric: SettingsBodyMetric) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text(model.displayTitle(for: metric))
                    .font(MooreFont.display(.subheadline))
                    .foregroundStyle(MooreColor.textPrimary)
                Text(model.displayDate(forISO: metric.recordedAt))
                    .font(MooreFont.body(.caption))
                    .foregroundStyle(MooreColor.textSecondary)
            }
            Spacer()
            // BR-004: row-unit → active-unit lens, pct/cm/in verbatim.
            Text(model.displayString(for: metric))
                .font(MooreFont.numeric())
                .foregroundStyle(MooreColor.textPrimary)
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    // MARK: Data & sync (BR-008..BR-012)

    private func dataSyncSection(_ model: SettingsModel) -> some View {
        Section {
            // SC-import §6 placement: the import row sits directly above the
            // export row.
            importRow()
            exportRow(model)
            cloudSyncRow(model)
            storageRows(model)
        } header: {
            sectionHeader(UICopy.settingsDataSyncTitle)
        }
    }

    /// settings.dataSync.exportCta — tap exports (§2 machine); once completed the
    /// row becomes the ShareLink handing over the `.moore-backup` file (BR-008).
    private func exportRow(_ model: SettingsModel) -> some View {
        Group {
            switch model.exportPhase {
            case .completed:
                if let url = model.exportFileURL {
                    ShareLink(item: url) {
                        Label(UICopy.settingsDataSyncExportCta, systemImage: "square.and.arrow.up")
                            .font(MooreFont.display(.subheadline))
                            .foregroundStyle(MooreColor.lime)
                    }
                }
            case .preparing, .writing:
                HStack {
                    Label(UICopy.settingsDataSyncExportCta, systemImage: "square.and.arrow.up")
                        .font(MooreFont.display(.subheadline))
                        .foregroundStyle(MooreColor.textSecondary)
                    Spacer()
                    ProgressView()
                }
            case .failed:
                // §2 exportFailed → foundation.db.* fallback copy (SC-foundation §6).
                Button {
                    model.exportBackup()
                } label: {
                    Label(UICopy.settingsDataSyncExportCta, systemImage: "arrow.clockwise")
                        .font(MooreFont.display(.subheadline))
                        .foregroundStyle(MooreColor.lime)
                }
                Text(UICopy.dbUnknownError)
                    .font(MooreFont.body(.footnote))
                    .foregroundStyle(MooreColor.textSecondary)
            case .idle:
                Button {
                    model.exportBackup()
                } label: {
                    Label(UICopy.settingsDataSyncExportCta, systemImage: "square.and.arrow.up")
                        .font(MooreFont.display(.subheadline))
                        .foregroundStyle(MooreColor.lime)
                }
            }
        }
    }

    /// #39 — the live Hevy-import entry (replaces the #38 BR-012 stub). Tap
    /// opens the system file picker; the picked URL drives the Foundation-only
    /// ImportModel through SC-import §2's machine, presented as the import
    /// flow sheet. Copy: hevyImport.title ("Import from Hevy (CSV)").
    private func importRow() -> some View {
        Button {
            showingImportPicker = true
        } label: {
            Label(UICopy.hevyImportTitle, systemImage: "square.and.arrow.down")
                .font(MooreFont.display(.subheadline))
                .foregroundStyle(MooreColor.lime)
        }
    }

    /// BR-011: cloud sync renders permanently greyed at v1 — disabled constant,
    /// no handler, no write path (INV-ST5). Info icon points at #4's gate.
    private func cloudSyncRow(_ model: SettingsModel) -> some View {
        Toggle(isOn: .constant(false)) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                HStack(spacing: DesignTokens.Spacing.s) {
                    // settings.cloudSync.title
                    Text(UICopy.settingsCloudSyncTitle)
                        .font(MooreFont.body())
                        .foregroundStyle(MooreColor.textPrimary)
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(MooreColor.textSecondary.opacity(0.6))
                        .accessibilityLabel(model.cloudSyncStatus.infoIssue)
                }
                // settings.cloudSync.coming
                Text(UICopy.settingsCloudSyncComing)
                    .font(MooreFont.body(.caption))
                    .foregroundStyle(MooreColor.textSecondary)
            }
        }
        .disabled(model.cloudSyncStatus.greyed)
    }

    /// Storage stats: BR-009 core-table accounting + on-disk file size (derived).
    private func storageRows(_ model: SettingsModel) -> some View {
        Group {
            if let stats = model.storageStats {
                statRow(UICopy.settingsStorageSize, SettingsModel.displayFileSize(stats.fileSizeBytes))
                statRow(UICopy.settingsStorageRows, "\(stats.coreRowCount)")
                statRow(UICopy.settingsStorageDeletedRows, "\(stats.tombstoneCount)")
            }
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(MooreFont.body(.footnote))
                .foregroundStyle(MooreColor.textSecondary)
            Spacer()
            Text(value)
                .font(MooreFont.numeric(.footnote))
                .foregroundStyle(MooreColor.textPrimary)
        }
    }

    // MARK: Tombstones (BR-010 / INV-ST4)

    private func tombstonesSection(_ model: SettingsModel) -> some View {
        Section {
            if model.tombstones.isEmpty {
                // settings.tombstones.empty
                Text(UICopy.settingsTombstonesEmpty)
                    .font(MooreFont.body())
                    .foregroundStyle(MooreColor.textSecondary)
            } else {
                ForEach(model.tombstones, id: \.id) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                            Text(item.name)
                                .font(MooreFont.display(.subheadline))
                                .foregroundStyle(MooreColor.textPrimary)
                            Text(model.displayDate(forISO: item.deletedAt))
                                .font(MooreFont.body(.caption))
                                .foregroundStyle(MooreColor.textSecondary)
                        }
                        Spacer()
                        // settings.tombstones.restoreCta
                        Button(UICopy.settingsTombstonesRestoreCta) {
                            model.restoreExercise(id: item.id)
                        }
                        .font(MooreFont.display(.subheadline))
                        .foregroundStyle(MooreColor.lime)
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, DesignTokens.Spacing.xs)
                }
            }
        } header: {
            sectionHeader(UICopy.settingsTombstonesTitle)
        }
    }

    // MARK: Error + chrome

    private func errorSection(_ model: SettingsModel) -> some View {
        Group {
            if let message = model.errorMessage {
                Section {
                    Text(message)
                        .font(MooreFont.numeric(.caption))
                        .foregroundStyle(MooreColor.textSecondary)
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(MooreFont.display(.footnote))
            .foregroundStyle(MooreColor.textSecondary)
            .textCase(nil)
    }

    /// settings.dataSync.exportedToast — auto-dismisses (~4s), the completed
    /// file + ShareLink stay alive (toast clear ≠ §2 dismiss).
    private func toast(fileName: String, onExpire: @escaping () -> Void) -> some View {
        Text(UICopy.exportedToast(fileName: fileName))
            .font(MooreFont.body(.footnote))
            .foregroundStyle(.black)
            .padding(.horizontal, DesignTokens.Spacing.l)
            .padding(.vertical, DesignTokens.Spacing.m)
            .background(Capsule().fill(MooreColor.lime))
            .padding(.bottom, DesignTokens.Spacing.xxl)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: fileName) {
                do {
                    try await Task.sleep(for: .seconds(4))
                    onExpire()
                } catch {
                    // Cancelled — a newer toast (or dismissal) owns the lifecycle.
                }
            }
    }
}
