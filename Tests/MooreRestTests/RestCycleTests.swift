// contractId: SC-rest @1.0.0
// Seam-1 + Seam-3 XCTest mirror of Tests/MooreRestTests/Fixtures/*.json.
// The authoritative runbook on CI-without-Xcode is VerifyRest.mjs (JS mirror);
// this file encodes the same vectors against the real Swift FSM for hosts with
// a Swift toolchain, so the Swift implementation and the JS mirror cannot drift
// without one of them failing.

import XCTest
@testable import MooreRest

final class RestCycleTests: XCTestCase {

    private let settings = RestSettings.default

    // MARK: - Helpers

    private static func date(at seconds: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    private func resolve(
        perSetSec: Int? = nil,
        perExerciseSec: Int? = nil,
        perRoutineSec: Int? = nil,
        categoryIsCompound: Bool
    ) -> RestResolution {
        RestResolver.resolve(
            perSetSec: perSetSec,
            perExerciseSec: perExerciseSec,
            perRoutineSec: perRoutineSec,
            categoryIsCompound: categoryIsCompound,
            settings: settings
        )
    }

    private func assertRunning(
        _ cycle: RestCycle,
        durationSec: Int,
        startedAt: Int,
        adjustmentSec: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case let .restRunning(d, started, adj) = cycle.current else {
            return XCTFail("expected restRunning, got \(cycle.current)", file: file, line: line)
        }
        XCTAssertEqual(d, durationSec, file: file, line: line)
        XCTAssertEqual(started, Self.date(at: startedAt), file: file, line: line)
        XCTAssertEqual(adj, adjustmentSec, file: file, line: line)
    }

    // MARK: - BR-001 hierarchy (duration-hierarchy.json)

    func testPerSetBeatsAllLevels_V1() {
        var cycle = RestCycle()
        let res = resolve(perSetSec: 240, perExerciseSec: 120, perRoutineSec: 200, categoryIsCompound: true)
        XCTAssertEqual(res, RestResolution(durationSec: 240, source: .perSet))
        XCTAssertNil(cycle.dispatch(.setCompleted(resolution: res, allSetsTerminal: false, at: Self.date(at: 0))))
        assertRunning(cycle, durationSec: 240, startedAt: 0, adjustmentSec: 0)
    }

    func testPerExerciseWhenNoPerSet_V2() {
        var cycle = RestCycle()
        let res = resolve(perExerciseSec: 120, perRoutineSec: 200, categoryIsCompound: true)
        XCTAssertEqual(res.source, .perExercise)
        cycle.dispatch(.setCompleted(resolution: res, allSetsTerminal: false, at: Self.date(at: 0)))
        assertRunning(cycle, durationSec: 120, startedAt: 0, adjustmentSec: 0)
    }

    func testPerRoutineWhenNoNarrower_V3() {
        var cycle = RestCycle()
        let res = resolve(perRoutineSec: 200, categoryIsCompound: true)
        XCTAssertEqual(res.source, .perRoutine)
        cycle.dispatch(.setCompleted(resolution: res, allSetsTerminal: false, at: Self.date(at: 0)))
        assertRunning(cycle, durationSec: 200, startedAt: 0, adjustmentSec: 0)
    }

    func testGlobalDefaultsBucketByCategory_V4() {
        var compound = RestCycle()
        let resC = resolve(categoryIsCompound: true)
        XCTAssertEqual(resC, RestResolution(durationSec: 180, source: .globalCompound))
        compound.dispatch(.setCompleted(resolution: resC, allSetsTerminal: false, at: Self.date(at: 0)))
        assertRunning(compound, durationSec: 180, startedAt: 0, adjustmentSec: 0)

        var isolation = RestCycle()
        let resI = resolve(categoryIsCompound: false)
        XCTAssertEqual(resI, RestResolution(durationSec: 90, source: .globalIsolation))
        isolation.dispatch(.setCompleted(resolution: resI, allSetsTerminal: false, at: Self.date(at: 0)))
        assertRunning(isolation, durationSec: 90, startedAt: 0, adjustmentSec: 0)
    }

    // MARK: - BR-002 adjust (oneoff-adjust.json)

    func testPlus15AdjustsWithoutPersisting_V5() {
        var cycle = RestCycle()
        let res = resolve(categoryIsCompound: true)
        cycle.dispatch(.setCompleted(resolution: res, allSetsTerminal: false, at: Self.date(at: 0)))
        XCTAssertNil(cycle.dispatch(.adjustSec(delta: 15, at: Self.date(at: 10))))
        assertRunning(cycle, durationSec: 180, startedAt: 0, adjustmentSec: 15)
        XCTAssertEqual(
            RestCycle.remainingSec(durationSec: 180, startedAt: Self.date(at: 0), adjustmentSec: 15, now: Self.date(at: 10)),
            185
        )
        // INV-T2: no persistence surface exists on the FSM; nothing to assert beyond the in-memory value.
    }

    func testMinus15Under15RemainingIsSkipEquivalent_V6() {
        var cycle = RestCycle()
        cycle.dispatch(.setCompleted(resolution: resolve(categoryIsCompound: true), allSetsTerminal: false, at: Self.date(at: 0)))
        XCTAssertNil(cycle.dispatch(.adjustSec(delta: -15, at: Self.date(at: 170)))) // 10s left
        XCTAssertEqual(cycle.current, .noRest)
    }

    func testRepeatedPlus15CapsAt600_E1() {
        var cycle = RestCycle()
        cycle.dispatch(.setCompleted(resolution: resolve(categoryIsCompound: true), allSetsTerminal: false, at: Self.date(at: 0)))
        for _ in 0..<30 {
            cycle.dispatch(.adjustSec(delta: 15, at: Self.date(at: 0)))
        }
        assertRunning(cycle, durationSec: 180, startedAt: 0, adjustmentSec: 420)
        XCTAssertEqual(
            RestCycle.remainingSec(durationSec: 180, startedAt: Self.date(at: 0), adjustmentSec: 420, now: Self.date(at: 0)),
            600
        )
    }

    // MARK: - BR-003 skip (skip-gesture.json)

    func testSkipCancelsInstantlyNoCue_V7() {
        let spy = InMemoryCueDispatcher()
        var cycle = RestCycle()
        cycle.dispatch(.setCompleted(resolution: resolve(categoryIsCompound: true), allSetsTerminal: false, at: Self.date(at: 0)), into: spy)
        cycle.dispatch(.skip(at: Self.date(at: 45)), into: spy)
        XCTAssertEqual(cycle.current, .noRest)
        XCTAssertEqual(spy.events, [])
    }

    func testSkipFromExpiredDismisses_E2() {
        let spy = InMemoryCueDispatcher()
        var cycle = RestCycle()
        cycle.dispatch(.setCompleted(resolution: resolve(categoryIsCompound: false), allSetsTerminal: false, at: Self.date(at: 0)), into: spy)
        cycle.dispatch(.expireNaturally(at: Self.date(at: 90)), into: spy)   // cue fires here
        cycle.dispatch(.skip(at: Self.date(at: 95)), into: spy)
        XCTAssertEqual(cycle.current, .noRest)
        XCTAssertEqual(spy.events, [.restEnd])
    }

    // MARK: - BR-004 restart (restart-on-mid-rest-completion.json)

    func testRestartPicksUpNewSetsDuration_V8() {
        var cycle = RestCycle()
        cycle.dispatch(.setCompleted(resolution: resolve(categoryIsCompound: true), allSetsTerminal: false, at: Self.date(at: 0)))
        cycle.dispatch(.setCompleted(resolution: resolve(categoryIsCompound: false), allSetsTerminal: false, at: Self.date(at: 30)))
        assertRunning(cycle, durationSec: 90, startedAt: 30, adjustmentSec: 0)
    }

    func testFailedSetAlsoRestarts_E3() {
        var cycle = RestCycle()
        cycle.dispatch(.setCompleted(resolution: resolve(categoryIsCompound: true), allSetsTerminal: false, at: Self.date(at: 0)))
        cycle.dispatch(.setFailed(resolution: resolve(perSetSec: 240, categoryIsCompound: true), allSetsTerminal: false, at: Self.date(at: 10)))
        assertRunning(cycle, durationSec: 240, startedAt: 10, adjustmentSec: 0)
    }

    // MARK: - BR-005 drop (drop-no-rest.json)

    func testDropFromNoRestStartsNothing_V9() {
        let spy = InMemoryCueDispatcher()
        var cycle = RestCycle()
        cycle.dispatch(.setDropped, into: spy)
        XCTAssertEqual(cycle.current, .noRest)
        XCTAssertEqual(spy.events, [])
    }

    func testDropMidRestLeavesTimerUntouched_E8() {
        var cycle = RestCycle()
        cycle.dispatch(.setCompleted(resolution: resolve(categoryIsCompound: false), allSetsTerminal: false, at: Self.date(at: 0)))
        cycle.dispatch(.setDropped)
        assertRunning(cycle, durationSec: 90, startedAt: 0, adjustmentSec: 0)
    }

    // MARK: - BR-006 + §2b morph (final-set-and-finish-morph.json)

    func testFinalSetStillAutoStartsRest_E6() {
        var cycle = RestCycle()
        cycle.dispatch(.setCompleted(resolution: resolve(categoryIsCompound: true), allSetsTerminal: true, at: Self.date(at: 0)))
        assertRunning(cycle, durationSec: 180, startedAt: 0, adjustmentSec: 0)
        XCTAssertEqual(cycle.overlay, .rest)
    }

    func testFinalSetRestExpiryMorphsWithoutRestCue_V10() {
        let spy = InMemoryCueDispatcher()
        var cycle = RestCycle()
        cycle.dispatch(.setCompleted(resolution: resolve(categoryIsCompound: false), allSetsTerminal: true, at: Self.date(at: 0)), into: spy)
        cycle.dispatch(.expireNaturally(at: Self.date(at: 90)), into: spy)
        XCTAssertEqual(cycle.overlay, .finishPanel)
        XCTAssertEqual(cycle.current, .noRest)
        XCTAssertEqual(spy.events, [.finishMorph])
    }

    func testSkippingFinalRestMorphsToo_E7() {
        let spy = InMemoryCueDispatcher()
        var cycle = RestCycle()
        cycle.dispatch(.setCompleted(resolution: resolve(categoryIsCompound: true), allSetsTerminal: true, at: Self.date(at: 0)), into: spy)
        cycle.dispatch(.skip(at: Self.date(at: 20)), into: spy)
        XCTAssertEqual(cycle.overlay, .finishPanel)
        XCTAssertEqual(spy.events, [.finishMorph])
    }

    // MARK: - BR-007 recompute (recompute-on-kill.json)

    func testBackgroundedRecomputesThenPresentsExpired_V11() {
        let spy = InMemoryCueDispatcher()
        var cycle = RestCycle()
        cycle.dispatch(.setCompleted(resolution: resolve(categoryIsCompound: true), allSetsTerminal: false, at: Self.date(at: 0)), into: spy)
        cycle.dispatch(.backgrounded(at: Self.date(at: 60)), into: spy)
        assertRunning(cycle, durationSec: 180, startedAt: 0, adjustmentSec: 0)
        XCTAssertEqual(RestCycle.remainingSec(durationSec: 180, startedAt: Self.date(at: 0), adjustmentSec: 0, now: Self.date(at: 60)), 120)
        cycle.dispatch(.backgrounded(at: Self.date(at: 200)), into: spy)
        guard case .restExpired = cycle.current else {
            return XCTFail("expected restExpired, got \(cycle.current)")
        }
        cycle.dispatch(.backgrounded(at: Self.date(at: 250)), into: spy)
        XCTAssertEqual(spy.events, [.restEnd])
    }

    // MARK: - BR-008 cue (rest-end-cue.json)

    func testOrdinaryExpiryFiresOneRestEndCue_V12() {
        let spy = InMemoryCueDispatcher()
        var cycle = RestCycle()
        cycle.dispatch(.setCompleted(resolution: resolve(categoryIsCompound: false), allSetsTerminal: false, at: Self.date(at: 0)), into: spy)
        cycle.dispatch(.expireNaturally(at: Self.date(at: 90)), into: spy)
        cycle.dispatch(.expireNaturally(at: Self.date(at: 90)), into: spy)  // re-arrival must not double-fire
        cycle.dispatch(.expireNaturally(at: Self.date(at: 95)), into: spy)
        XCTAssertEqual(spy.events, [.restEnd])
    }

    // MARK: - Overlay unlatch (forward-compat-suppress.json)

    func testNewRunAfterMorphUnlatchesOverlayAndCuesNormally_E8() {
        let spy = InMemoryCueDispatcher()
        var cycle = RestCycle()
        // Final set's rest expires → morph.
        cycle.dispatch(.setCompleted(resolution: resolve(categoryIsCompound: false), allSetsTerminal: true, at: Self.date(at: 0)), into: spy)
        cycle.dispatch(.expireNaturally(at: Self.date(at: 90)), into: spy)
        XCTAssertEqual(cycle.overlay, .finishPanel)
        // A later set (superset flow) starts a NORMAL countdown; overlay unlatches.
        cycle.dispatch(.setCompleted(resolution: resolve(categoryIsCompound: true), allSetsTerminal: false, at: Self.date(at: 100)), into: spy)
        XCTAssertEqual(cycle.overlay, .rest)
        assertRunning(cycle, durationSec: 180, startedAt: 100, adjustmentSec: 0)
        // … and its expiry fires cue.rest.end — the earlier morph does not absorb it.
        cycle.dispatch(.expireNaturally(at: Self.date(at: 280)), into: spy)
        guard case .restExpired = cycle.current else {
            return XCTFail("expected restExpired, got \(cycle.current)")
        }
        XCTAssertEqual(spy.events, [.finishMorph, .restEnd])
    }

    // MARK: - BR-001 clamp (duration-clamp.json)

    func testResolvedDurationClampsTo600_V14() {
        var cycle = RestCycle()
        let res = resolve(perSetSec: 900, categoryIsCompound: true)
        XCTAssertEqual(res, RestResolution(durationSec: 600, source: .perSet))
        cycle.dispatch(.setCompleted(resolution: res, allSetsTerminal: false, at: Self.date(at: 0)))
        assertRunning(cycle, durationSec: 600, startedAt: 0, adjustmentSec: 0)
    }
}
