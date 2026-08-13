// Ticket #39 — Hevy CSV import flow screens (SC-import@1.0.0 §2/§6): the sheet
// presented from Settings → Data & sync after a file is picked. Renders the
// Foundation-only ImportModel's §2 machine: parsing → preview (dry-run counts,
// quarantined-row inspection, per-exercise unit overrides) → applying (one
// transaction) → done (summary line + History/Analytics pointers + PR
// re-derivation confirmation) | error (the two §6 error keys). All copy binds
// UICopy's SC-import §6 keys verbatim; all logic lives in ImportModel driving
// HevyImportEngine / HevyImportDAO — this view is layout + bindings.

import SwiftUI
import MooreImport

struct HevyImportFlowView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let model: ImportModel

    var body: some View {
        NavigationStack {
            content
                .scrollContentBackground(.hidden)
                .background(MooreColor.steelBase)
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        // The one transaction must run to commit/rollback undisturbed (INV-IM2).
        .interactiveDismissDisabled(model.phase == .applying)
        // INV-IM1: any dismissal before [Import] discards the plan wholesale.
        .onDisappear { model.reset() }
    }

    private var navigationTitle: String {
        switch model.phase {
        case .preview: return UICopy.hevyImportPreviewTitle   // hevyImport.preview.title
        default: return UICopy.hevyImportTitle                // hevyImport.title
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .parsing:
            progressPanel
        case .preview:
            previewList
        case .applying:
            progressPanel
        case .done:
            donePanel
        case .error(let kind, let detail):
            errorPanel(kind: kind, detail: detail)
        }
    }

    // MARK: parsing / applying

    private var progressPanel: some View {
        VStack(spacing: DesignTokens.Spacing.l) {
            Spacer()
            ProgressView()
                .controlSize(.large)
                .tint(MooreColor.lime)
            if let fileName = model.sourceFileName {
                Text(fileName)
                    .font(MooreFont.body(.footnote))
                    .foregroundStyle(MooreColor.textSecondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: preview (BR-014 dry-run render — every count from the ONE plan)

    private var previewList: some View {
        List {
            countsSection
            if let plan = model.plan, !plan.quarantined.isEmpty {
                quarantineSection(plan)
            }
            if !model.overridableExercises.isEmpty {
                unitOverrideSection
            }
            noticesSection
            ctaSection
        }
    }

    /// §6 preview counts: sessions/sets headline rows plus the conditional
    /// accounting rows (BR-014 renders them all from PreviewCounts).
    @ViewBuilder
    private var countsSection: some View {
        if let plan = model.plan {
            Section {
                countRow(UICopy.hevyImportPreviewSessions(plan.counts.sessionsFound))
                countRow(UICopy.hevyImportPreviewSets(plan.counts.setsImported))
                countRow(UICopy.hevyImportPreviewMatched(plan.counts.exercisesMatched))
                if !plan.newExercises.isEmpty {
                    countRow(UICopy.hevyImportPreviewNewExercises(plan.newExercises.count))
                    // The new custom exercise names (BR-014 surfaces them).
                    Text(plan.newExercises.map(\.name).joined(separator: ", "))
                        .font(MooreFont.body(.caption))
                        .foregroundStyle(MooreColor.textSecondary)
                }
                if plan.counts.sessionsAlreadyImported > 0 {
                    countRow(UICopy.hevyImportPreviewAlreadyImported(plan.counts.sessionsAlreadyImported))
                }
                if plan.counts.foldedSetTypes > 0 {
                    countRow(UICopy.hevyImportPreviewFolded(plan.counts.foldedSetTypes))
                }
                if plan.counts.cardioRowsSkipped > 0 {
                    countRow(UICopy.hevyImportPreviewCardioSkipped(plan.counts.cardioRowsSkipped))
                }
                if plan.counts.metadataDropped.rpe > 0
                    || plan.counts.metadataDropped.exerciseNotes > 0
                    || plan.counts.metadataDropped.supersetId > 0 {
                    countRow(UICopy.hevyImportPreviewMetadataDropped)
                }
                if let unit = plan.unit {
                    // hevyImport.preview.unitDetected — the BR-010 declared unit.
                    countRow(UICopy.hevyImportPreviewUnitDetected(unit: unit.rawValue))
                }
            } header: {
                sectionHeader(UICopy.hevyImportPreviewTitle)
            }
        }
    }

    /// BR-012/BR-014: quarantined rows are inspectable — row number, offending
    /// column, value, and the engine's message (the §3b QuarantinedRow shape).
    private func quarantineSection(_ plan: ImportPlan) -> some View {
        Section {
            // hevyImport.preview.quarantined — "{n} rows set aside — tap to inspect"
            DisclosureGroup {
                ForEach(plan.quarantined, id: \.rowNumber) { row in
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        Text("\(row.column): \(row.message)")
                            .font(MooreFont.body(.footnote))
                            .foregroundStyle(MooreColor.textPrimary)
                        // Row number (1-based data-record index) + the raw value.
                        Text("#\(row.rowNumber)  \(row.value)")
                            .font(MooreFont.numeric(.caption))
                            .foregroundStyle(MooreColor.textSecondary)
                    }
                    .padding(.vertical, DesignTokens.Spacing.xs)
                }
            } label: {
                Text(UICopy.hevyImportPreviewQuarantined(plan.quarantined.count))
                    .font(MooreFont.body())
                    .foregroundStyle(MooreColor.textPrimary)
            }
            .tint(MooreColor.lime)
        }
    }

    /// BR-010 per-exercise unit overrides: a segmented kg/lb control per
    /// weight-bearing exercise; choosing the detected unit clears the override.
    private var unitOverrideSection: some View {
        Section {
            ForEach(model.overridableExercises) { exercise in
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    // hevyImport.preview.unitOverride — "Unit for {exerciseName}"
                    Text(UICopy.hevyImportPreviewUnitOverride(exerciseName: exercise.displayName))
                        .font(MooreFont.body(.footnote))
                        .foregroundStyle(MooreColor.textSecondary)
                    Picker(
                        UICopy.hevyImportPreviewUnitOverride(exerciseName: exercise.displayName),
                        selection: unitOverrideBinding(for: exercise)
                    ) {
                        Text(HevyUnit.kg.rawValue).tag(HevyUnit.kg)
                        Text(HevyUnit.lb.rawValue).tag(HevyUnit.lb)
                    }
                    .pickerStyle(.segmented)
                }
                .padding(.vertical, DesignTokens.Spacing.xs)
            }
        }
    }

    /// BR-010 render hook: the effective unit for this exercise — the override
    /// if set, else the file's detected unit, else kg. Selecting the detected
    /// unit is identity → the override is removed, not stored as a duplicate.
    private func unitOverrideBinding(for exercise: ImportPlanExercise) -> Binding<HevyUnit> {
        let detected = model.plan?.unit
        return Binding(
            get: {
                model.unitOverrides[exercise.normalizedName] ?? detected ?? .kg
            },
            set: { newValue in
                if newValue == detected {
                    model.clearUnitOverride(normalizedName: exercise.normalizedName)
                } else {
                    model.setUnitOverride(normalizedName: exercise.normalizedName, unit: newValue)
                }
            }
        )
    }

    /// The one-time-migration caveat + engine warnings (duplicate headers,
    /// dual weight columns — the plan carries them verbatim).
    @ViewBuilder
    private var noticesSection: some View {
        if let plan = model.plan {
            Section {
                // hevyImport.preview.oneTime
                noticeRow(UICopy.hevyImportPreviewOneTime)
                ForEach(plan.warnings, id: \.self) { warning in
                    noticeRow(warning)
                }
            }
        }
    }

    /// §2 preview exits: [Import] → applying, [Cancel] → idle (plan discarded).
    private var ctaSection: some View {
        Section {
            // hevyImport.importCTA
            Button(UICopy.hevyImportImportCta) {
                model.applyImport()
            }
            .buttonStyle(MoorePrimaryButtonStyle())
            .frame(maxWidth: .infinity)
            // An empty plan (cardio-only file / all sessions already imported
            // with zero sets planned) has nothing to transact.
            .disabled((model.plan?.sessions.isEmpty ?? true))
            // hevyImport.cancelCTA
            Button(UICopy.hevyImportCancelCta) {
                model.reset()
                dismiss()
            }
            .font(MooreFont.display(.subheadline))
            .foregroundStyle(MooreColor.textSecondary)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: done (§2 terminal — summary line + pointers at the fed surfaces)

    private var donePanel: some View {
        VStack(spacing: DesignTokens.Spacing.l) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(MooreColor.lime)
            if let summary = model.summary {
                if model.lastImportAddedNothing {
                    // INV-IM4 render: re-import of the same file is a counted
                    // no-op — hevyImport.preview.alreadyImported.
                    Text(UICopy.hevyImportPreviewAlreadyImported(summary.sessionsSkippedAlreadyImported))
                        .font(MooreFont.display(.title3))
                        .foregroundStyle(MooreColor.textPrimary)
                        .multilineTextAlignment(.center)
                }
                // hevyImport.summaryLine
                Text(UICopy.hevyImportSummaryLine(
                    sessions: summary.sessionsImported,
                    sets: summary.setsImported,
                    skipped: summary.sessionsSkippedAlreadyImported,
                    quarantined: model.plan?.counts.quarantinedCount ?? 0
                ))
                .font(MooreFont.body())
                .foregroundStyle(MooreColor.textSecondary)
                .multilineTextAlignment(.center)
                if model.prRowsAddedByApply > 0 {
                    // BR-016 confirmation: the record book re-derived on apply.
                    Text(UICopy.hevyImportDonePrs(model.prRowsAddedByApply))
                        .font(MooreFont.body(.footnote))
                        .foregroundStyle(MooreColor.textSecondary)
                }
            }
            // Imported rows are plain CompletedSets — History + Analytics light
            // up immediately (null plannedX tolerated per SC-foundation BR-004).
            HStack(spacing: DesignTokens.Spacing.m) {
                Button(UICopy.hevyImportDoneViewHistory) {
                    appState.selectedTab = .history
                    dismiss()
                }
                .buttonStyle(MooreSecondaryButtonStyle())
                Button(UICopy.hevyImportDoneViewAnalytics) {
                    appState.selectedTab = .analytics
                    dismiss()
                }
                .buttonStyle(MooreSecondaryButtonStyle())
            }
            Button(UICopy.hevyImportDoneCta) {
                dismiss()
            }
            .buttonStyle(MoorePrimaryButtonStyle())
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(DesignTokens.Spacing.l)
    }

    // MARK: error (§2 terminal — the two §6 error keys, detail rides small)

    private func errorPanel(kind: ImportModel.ErrorKind, detail: String) -> some View {
        VStack(spacing: DesignTokens.Spacing.l) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 52))
                .foregroundStyle(MooreColor.lime)
            Text(kind == .notHevyExport
                 ? UICopy.hevyImportErrorNotHevyExport     // hevyImport.error.notHevyExport
                 : UICopy.hevyImportErrorApplyFailed)      // hevyImport.error.applyFailed
                .font(MooreFont.display(.title3))
                .foregroundStyle(MooreColor.textPrimary)
                .multilineTextAlignment(.center)
            // Technical detail — small, for support; the §6 copy carries the message.
            Text(detail)
                .font(MooreFont.numeric(.caption))
                .foregroundStyle(MooreColor.textSecondary)
                .multilineTextAlignment(.center)
            Button(UICopy.hevyImportErrorCta) {
                model.reset()
                dismiss()
            }
            .buttonStyle(MoorePrimaryButtonStyle())
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(DesignTokens.Spacing.l)
    }

    // MARK: Shared row chrome

    private func countRow(_ text: String) -> some View {
        Text(text)
            .font(MooreFont.body())
            .foregroundStyle(MooreColor.textPrimary)
            .padding(.vertical, DesignTokens.Spacing.xs)
    }

    private func noticeRow(_ text: String) -> some View {
        Text(text)
            .font(MooreFont.body(.footnote))
            .foregroundStyle(MooreColor.textSecondary)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(MooreFont.display(.footnote))
            .foregroundStyle(MooreColor.textSecondary)
            .textCase(nil)
    }
}
