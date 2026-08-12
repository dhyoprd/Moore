// Seam-1 XCTest guard-matrix for SC-progression@1.0.0.
// Pure logic only — engine has no GRDB dependency; fixtures run in-process.

import XCTest
@testable import MooreProgression

final class ProgressionEngineTests: XCTestCase {

    // MARK: - Helpers

    private func mkScheme(
        scheme: Scheme = .none,
        stallCount: Int = 0,
        stallMuted: Bool = false,
        nextBannerAt: Int = 3,
        deloadPending: Bool = false,
        lastDeloadSessionId: String? = nil,
        stalledWeight: Double? = nil,
        stalledReps: Int? = nil,
        stalledDurationSec: Int? = nil,
        baselineDurationSec: Int? = nil
    ) -> ProgressionRecord {
        ProgressionRecord(
            id: "sc-1", routineId: "routine-a", exerciseId: "ex-1",
            scheme: scheme, incrementValue: nil,
            doubleProgressionMinReps: nil, doubleProgressionMaxReps: nil,
            warmupEnabled: false, stallCount: stallCount, stallMuted: stallMuted,
            nextBannerAt: nextBannerAt, deloadPending: deloadPending,
            lastDeloadSessionId: lastDeloadSessionId, stalledWeight: stalledWeight,
            stalledReps: stalledReps, stalledDurationSec: stalledDurationSec,
            baselineDurationSec: baselineDurationSec,
            updatedAt: "2026-01-01T00:00:00Z", deletedAt: nil
        )
    }

    private func set(_ idx: Int, _ weight: Double?, _ reps: (Int?, Int?), status: SetStatus = .completed) -> ReferenceSessionSet {
        ReferenceSessionSet(
            sessionId: "s-\(idx)", routineId: "routine-a", status: status,
            exerciseId: "ex-1", setOrdinal: idx,
            plannedWeight: weight, plannedReps: reps.0, plannedDuration: nil,
            actualWeight: weight, actualReps: reps.1, actualDuration: nil
        )
    }

    // MARK: - BR-009 increments (upper-biased ambiguous)

    func testIncrementLowerBodyMatchesLegsKeyword() {
        XCTAssertEqual(ProgressionEngine.increment(forExerciseCategory: "Legs"), 5.0)
        XCTAssertEqual(ProgressionEngine.increment(forExerciseCategory: "Quads"), 5.0)
        XCTAssertEqual(ProgressionEngine.increment(forExerciseCategory: "Hamstrings"), 5.0)
    }

    func testIncrementUpperAndAmbiguousBias() {
        XCTAssertEqual(ProgressionEngine.increment(forExerciseCategory: "Chest"), 2.5)
        XCTAssertEqual(ProgressionEngine.increment(forExerciseCategory: nil), 2.5)         // ambiguous → upper-rung
        XCTAssertEqual(ProgressionEngine.increment(forExerciseCategory: "Core"), 2.5)
    }

    // MARK: - Rounding (BR-010)

    func testRound125() {
        XCTAssertEqual(ProgressionEngine.round125(52.4), 52.5)
        XCTAssertEqual(ProgressionEngine.round125(52.6), 52.5)
        XCTAssertEqual(ProgressionEngine.round125(51.875), 52.5)       // half-up at 1.25 grain
    }

    func testRound25_DeloadOnly() {
        XCTAssertEqual(ProgressionEngine.round25(52.5 * 0.9), 47.5)
        XCTAssertEqual(ProgressionEngine.round25(100.0 * 0.9), 90.0)
    }

    // MARK: - BR-006 clean

    func testCleanMetricReps() {
        let sets = [
            set(1, 50, (10, 10)),
            set(2, 50, (10, 12)),
            set(3, 50, (10, 11)),
        ]
        XCTAssertTrue(ProgressionEngine.clean(sets: sets, metric: .reps))
    }

    func testCleanFailsOnFailedSet() {
        let sets = [
            set(1, 50, (10, 10)),
            set(2, 50, (10, 12)),
            set(3, 50, (10, 5), status: .failed),
        ]
        XCTAssertFalse(ProgressionEngine.clean(sets: sets, metric: .reps))
    }

    func testCleanIgnoresDropped() {
        let sets = [
            set(1, 50, (10, 10)),
            set(2, 50, (10, nil), status: .dropped),        // dropped should not participate
            set(3, 50, (10, 12)),
        ]
        XCTAssertTrue(ProgressionEngine.clean(sets: sets, metric: .reps))
    }

    // MARK: - BR-007 failed-max donation

    func testFailedMaxReps() {
        let sets = [
            set(1, 80, (8, 8), status: .completed),
            set(2, 80, (8, 4), status: .failed),
            set(3, 80, (8, 6), status: .failed),
        ]
        XCTAssertEqual(ProgressionEngine.failedMax(sets: sets, metric: .reps), 6)
    }

    // MARK: - Suggest — core schemes

    func testSuggestInitialSessionReturnsBlueprintVerbatim() {
        // BR-003: no reference history → blueprint Values verbatim
        let (suggestion, _) = ProgressionEngine.suggest(
            record: mkScheme(), reference: nil,
            metric: .reps, category: "Chest",
            blueprintWeight: 40, blueprintReps: 10, blueprintDurationSec: nil
        )
        XCTAssertEqual(suggestion.weight, 40); XCTAssertEqual(suggestion.reps, 10)
        XCTAssertEqual(suggestion.touched, ["blueprint-verbatim"])
    }

    func testSuggestLinearUpperCleanIncrements25() {
        // SC-progression V1
        let history = [set(1, 50, (10, 10)), set(2, 50, (10, 10))]
        let rec = mkScheme(scheme: .linear)
        let (suggestion, _) = ProgressionEngine.suggest(
            record: rec, reference: history, metric: .reps, category: "Chest",
            blueprintWeight: nil, blueprintReps: nil, blueprintDurationSec: nil
        )
        XCTAssertEqual(suggestion.weight, 52.5); XCTAssertEqual(suggestion.reps, 10)
        XCTAssertEqual(suggestion.touched, ["linear"])
    }

    func testSuggestLinearLowerCleanIncrements5() {
        // SC-progression V2 (squat-family)
        let history = [set(1, 100, (5, 5))]
        let rec = mkScheme(scheme: .linear)
        let (suggestion, _) = ProgressionEngine.suggest(
            record: rec, reference: history, metric: .reps, category: "Legs",
            blueprintWeight: nil, blueprintReps: nil, blueprintDurationSec: nil
        )
        XCTAssertEqual(suggestion.weight, 105.0); XCTAssertEqual(suggestion.reps, 5)
    }

    func testSuggestDoubleCeilingWeightBump() {
        // SC-progression V4
        let history = [set(1, 80, (12, 12)), set(2, 80, (12, 12)), set(3, 80, (12, 12))]
        let rec = mkScheme(scheme: .double)
        let (suggestion, _) = ProgressionEngine.suggest(
            record: rec, reference: history, metric: .reps, category: "Chest",
            blueprintWeight: nil, blueprintReps: nil, blueprintDurationSec: nil
        )
        XCTAssertEqual(suggestion.weight, 82.5); XCTAssertEqual(suggestion.reps, 8)
        XCTAssertEqual(suggestion.touched, ["double-ceiling"])
    }

    func testSuggestDoubleMiddleRepsProgress() {
        // SC-progression V5
        let history = [set(1, 80, (10, 10)), set(2, 80, (10, 10))]
        let rec = mkScheme(scheme: .double)
        let (suggestion, _) = ProgressionEngine.suggest(
            record: rec, reference: history, metric: .reps, category: "Chest",
            blueprintWeight: nil, blueprintReps: nil, blueprintDurationSec: nil
        )
        XCTAssertEqual(suggestion.weight, 80); XCTAssertEqual(suggestion.reps, 11)
    }

    func testSuggestHoldDurationTicksByFiveUntilCap() {
        // SC-progression V6
        let rec = mkScheme(scheme: .holdDuration, baselineDurationSec: 60)
        let history = [set(1, nil, (nil, nil))]   // duration exercised; needs actualDuration in row helper — using blueprint fallback:
        let history2 = [ReferenceSessionSet(sessionId: "s-1", routineId: "routine-a", status: .completed, exerciseId: "ex-1", setOrdinal: 1, plannedWeight: nil, plannedReps: nil, plannedDuration: 60, actualWeight: nil, actualReps: nil, actualDuration: 60)]
        let _ = history
        let (suggestion, _) = ProgressionEngine.suggest(
            record: rec, reference: history2, metric: .duration, category: "Core",
            blueprintWeight: nil, blueprintReps: nil, blueprintDurationSec: nil
        )
        XCTAssertEqual(suggestion.durationSec, 65)
        // At cap: last actual 120, baseline 60, cap 120 → stays 120 (BR-008)
        var rec2 = rec; rec2.baselineDurationSec = 60
        let history3 = [ReferenceSessionSet(sessionId: "s-1", routineId: "routine-a", status: .completed, exerciseId: "ex-1", setOrdinal: 1, plannedWeight: nil, plannedReps: nil, plannedDuration: 120, actualWeight: nil, actualReps: nil, actualDuration: 120)]
        let (s2, _) = ProgressionEngine.suggest(record: rec2, reference: history3, metric: .duration, category: "Core", blueprintWeight: nil, blueprintReps: nil, blueprintDurationSec: nil)
        XCTAssertEqual(s2.durationSec, 120)
    }

    func testSuggestNotCleanHoldsWeightTargetFromBestFail() {
        // SC-progression V10 — failed sets donate MAX actual reps
        let history = [
            set(1, 80, (8, 8), status: .completed),
            set(2, 80, (8, 6), status: .failed),
            set(3, 80, (8, 4), status: .failed),
        ]
        let rec = mkScheme(scheme: .linear)
        let (suggestion, _) = ProgressionEngine.suggest(
            record: rec, reference: history, metric: .reps, category: "Chest",
            blueprintWeight: nil, blueprintReps: nil, blueprintDurationSec: nil
        )
        XCTAssertEqual(suggestion.weight, 80); XCTAssertEqual(suggestion.reps, 6)
        XCTAssertEqual(suggestion.touched, ["hold-weight-from-fail"])
    }

    func testBodyweightLinearDegeneratesToNone() {
        // BR-011: no weight → linear degrades to none
        let history = [set(1, nil, (15, 15))]
        let rec = mkScheme(scheme: .linear)
        let (suggestion, _) = ProgressionEngine.suggest(
            record: rec, reference: history, metric: .reps, category: "Core",
            blueprintWeight: nil, blueprintReps: nil, blueprintDurationSec: nil
        )
        XCTAssertNil(suggestion.weight)
        XCTAssertEqual(suggestion.touched, ["linear-degenerate-none"])
    }

    // MARK: - Stall lifecycle (BR-012..BR-017)

    func testStallCounterTripsBannerAtThree() {
        // SC-progression V11
        var rec = mkScheme(scheme: .linear)
        let failingSets = [
            set(1, 80, (8, 8), status: .completed),
            set(2, 80, (8, 4), status: .failed),     // 4 < 8 → stall increments
        ]
        // Session 1
        var r = ProgressionEngine.onSessionFinished(record: rec, currentSessionSets: failingSets, previousWorkingWeight: 80, metric: .reps, exerciseName: "Bench")
        rec = r.updatedRecord; XCTAssertEqual(rec.stallCount, 1); XCTAssertFalse(r.shouldBanner)
        // Session 2
        r = ProgressionEngine.onSessionFinished(record: rec, currentSessionSets: failingSets, previousWorkingWeight: 80, metric: .reps, exerciseName: "Bench")
        rec = r.updatedRecord; XCTAssertEqual(rec.stallCount, 2); XCTAssertFalse(r.shouldBanner)
        // Session 3
        r = ProgressionEngine.onSessionFinished(record: rec, currentSessionSets: failingSets, previousWorkingWeight: 80, metric: .reps, exerciseName: "Bench")
        rec = r.updatedRecord; XCTAssertEqual(rec.stallCount, 3); XCTAssertTrue(r.shouldBanner)
        XCTAssertTrue(r.bannerCopy?.contains("Bench") ?? false)
    }

    func testStallChainResetsOnWeightChange() {
        // SC-progression V12
        var rec = mkScheme(scheme: .linear, stallCount: 2)
        let shortfallSets = [
            set(1, 85, (8, 8), status: .completed),
            set(2, 85, (8, 5), status: .failed),
        ]
        let r = ProgressionEngine.onSessionFinished(record: rec, currentSessionSets: shortfallSets, previousWorkingWeight: 80, metric: .reps, exerciseName: "Bench")
        rec = r.updatedRecord
        XCTAssertEqual(rec.stallCount, 0)   // 80→85 reset
        XCTAssertFalse(r.shouldBanner)
    }

    func testDeloadApplyThenNextGoesDownThenReEnters() {
        // SC-progression V13
        var rec = mkScheme(scheme: .linear, stallCount: 3)
        let refSets = [
            set(1, 80, (8, 8), status: .completed),
            set(2, 80, (8, 4), status: .failed),
        ]
        // Stall detected → user taps Deload → record is primed
        rec = ProgressionEngine.applyStallChoice(.deload, record: rec, currentWeight: 80, currentReps: 8, currentDurationSec: nil)
        XCTAssertTrue(rec.deloadPending); XCTAssertEqual(rec.stalledWeight, 80); XCTAssertEqual(rec.stalledReps, 8)
        // Next materialization is the deload session
        let (sugg, postDeloadRec) = ProgressionEngine.suggest(
            record: rec, reference: refSets, metric: .reps, category: "Chest",
            blueprintWeight: nil, blueprintReps: nil, blueprintDurationSec: nil
        )
        XCTAssertEqual(sugg.weight, 72.5)                       // round25(80×0.9)
        XCTAssertEqual(sugg.reps, 8)                            // stalledReps
        XCTAssertEqual(sugg.touched, ["deload-applied"])
        XCTAssertFalse(postDeloadRec.deloadPending)
        XCTAssertEqual(postDeloadRec.stallCount, 0)
        // Session after deload: re-enter unconditionally at stalled weight (BR-014)
        // (simulate by setting lastDeloadSessionId = this session id)
        var reentryRec = postDeloadRec
        reentryRec.lastDeloadSessionId = "thisSessionId"
        let reentrySets = [ReferenceSessionSet(sessionId: "thisSessionId", routineId: "routine-a", status: .completed, exerciseId: "ex-1", setOrdinal: 1, plannedWeight: 72.5, plannedReps: 8, plannedDuration: nil, actualWeight: 72.5, actualReps: 8, actualDuration: nil)]
        let (sugg2, _) = ProgressionEngine.suggest(
            record: reentryRec, reference: reentrySets, metric: .reps, category: "Chest",
            blueprintWeight: nil, blueprintReps: nil, blueprintDurationSec: nil
        )
        XCTAssertEqual(sugg2.weight, 80)                        // stalledWeight restored
        XCTAssertEqual(sugg2.reps, 8)
        XCTAssertEqual(sugg2.touched, ["deload-reentry"])
    }

    func testHoldReArmsBannerTwoLater() {
        // SC-progression V14
        var rec = mkScheme(scheme: .linear, stallCount: 3)
        rec = ProgressionEngine.applyStallChoice(.hold, record: rec, currentWeight: 80, currentReps: 8, currentDurationSec: nil)
        XCTAssertEqual(rec.nextBannerAt, 5); XCTAssertFalse(rec.deloadPending); XCTAssertFalse(rec.stallMuted)
    }

    func testIgnoreMutesPair() {
        // SC-progression V15
        var rec = mkScheme(scheme: .linear, stallCount: 3)
        rec = ProgressionEngine.applyStallChoice(.ignore, record: rec, currentWeight: 80, currentReps: 8, currentDurationSec: nil)
        XCTAssertTrue(rec.stallMuted)
        // additional stalls don't banner
        let failingSets = [set(1, 80, (8, 8), status: .completed), set(2, 80, (8, 4), status: .failed)]
        var r = ProgressionEngine.onSessionFinished(record: rec, currentSessionSets: failingSets, previousWorkingWeight: 80, metric: .reps, exerciseName: "Bench")
        rec = r.updatedRecord; XCTAssertFalse(r.shouldBanner)
        // and the count keeps climbing but no banner because muted
        r = ProgressionEngine.onSessionFinished(record: rec, currentSessionSets: failingSets, previousWorkingWeight: 80, metric: .reps, exerciseName: "Bench")
        XCTAssertFalse(r.shouldBanner); XCTAssertEqual(r.updatedRecord.stallCount, 5)
    }

    func testEditorTouchResetsChain() {
        // SC-progression V16
        var rec = mkScheme(scheme: .linear, stallCount: 2, stallMuted: true, nextBannerAt: 7)
        rec = ProgressionEngine.resetChainOnEdit(record: rec)
        XCTAssertEqual(rec.stallCount, 0); XCTAssertFalse(rec.stallMuted); XCTAssertEqual(rec.nextBannerAt, 3)
    }
}
