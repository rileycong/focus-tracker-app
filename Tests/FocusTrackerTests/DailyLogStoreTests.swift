import XCTest
@testable import FocusTracker

/// Store-level tests for `DailyLogStore` (issue #11): reads, appends,
/// arithmetic validation, concurrency and the `sessions(for:on:)` helper.
/// Every mutation test operates on a temp-dir copy of the fixture vault —
/// the repo fixture is never written (same convention as the #6/#7 tests).
final class DailyLogStoreTests: XCTestCase {

    // MARK: - Fixture access

    private static let fixturesVault = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests/FocusTrackerTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("fixtures/sample-vault", isDirectory: true)

    private static let taskAID = UUID(uuidString: "3f2a9c1e-5b7d-4e8a-9c21-7d4e6f8a1b02")!
    private static let taskBID = UUID(uuidString: "8a4c2e6f-1d3b-4f5a-8b9c-2e7d1a4c6e08")!
    private static let session1ID = UUID(uuidString: "e4f6a8b0-3c5d-4e7f-9a1b-2d4e6f8a0b51")!
    private static let session2ID = UUID(uuidString: "f5a7b9c1-4d6e-4f8a-2b3c-9e5f7a1b2c62")!
    private static let breakID = UUID(uuidString: "a6b8c0d2-5e7f-4a9b-8c1d-3f5a7b9c1d73")!

    private var root: URL!
    private var vaultURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DailyLogStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vaultURL = root.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.copyItem(at: Self.fixturesVault, to: vaultURL)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func day(_ timestamp: String, file: StaticString = #filePath, line: UInt = #line)
        throws -> Date
    {
        // Timestamps are interpreted in the local calendar, so a date parsed
        // from "2026-09-04T…" always names the file "2026-09-04.md".
        try XCTUnwrap(
            DailyLogDay.date(fromTimestamp: timestamp),
            "test timestamp \(timestamp) must parse", file: file, line: line)
    }

    private func fixtureDate(file: StaticString = #filePath, line: UInt = #line) throws -> Date {
        try day("2026-09-04T10:00:00", file: file, line: line)
    }

    private func makeStore() -> DailyLogStore {
        DailyLogStore(vaultURL: vaultURL)
    }

    private func logFile(_ name: String) -> URL {
        vaultURL
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }

    private func bytes(at url: URL, file: StaticString = #filePath, line: UInt = #line) throws
        -> Data
    {
        try XCTUnwrap(
            try? Data(contentsOf: url), "expected file at \(url)", file: file, line: line)
    }

    private func text(at url: URL) throws -> String {
        try String(decoding: bytes(at: url), as: UTF8.self)
    }

    private func makeSession(
        id: UUID = UUID(), taskID: UUID, start: String, end: String,
        focused: Int, paused: Int = 0, notes: String? = "Test session."
    ) throws -> FocusSessionLog {
        FocusSessionLog(
            sessionID: id, taskID: taskID,
            startedAt: try day(start), endedAt: try day(end),
            focusedDuration: focused, pauseCount: paused > 0 ? 1 : 0,
            pausedDuration: paused, focusRating: 4, energyRating: 4,
            taskCompleted: false, notes: notes)
    }

    private func makeBreak(
        id: UUID = UUID(), start: String, end: String, duration: Int
    ) throws -> BreakLog {
        BreakLog(
            breakID: id, startedAt: try day(start), endedAt: try day(end), duration: duration)
    }

    private func expectError<T>(
        _ expected: DailyLogError, file: StaticString = #filePath, line: UInt = #line,
        _ operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as DailyLogError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error type: \(error)", file: file, line: line)
        }
    }

    /// The frontmatter text before the `breaks:` key — i.e. every original
    /// session line of the fixture.
    private func fixtureSessionsBlock(of frontmatter: String) throws -> String {
        let breaksRange = try XCTUnwrap(
            frontmatter.range(of: "\nbreaks:"),
            "fixture frontmatter must contain a breaks key")
        return String(frontmatter[..<breaksRange.lowerBound])
    }

    // MARK: - Reading (missing file, fixture, malformed)

    func testMissingDayFileReadsEmpty() async throws {
        let store = makeStore()
        let log = try await store.readDay(for: try day("2026-09-10T09:00:00"))
        XCTAssertEqual(log, DailyLog())
        // The helper agrees: no sessions for anything on a missing day.
        let sessions = try await store.sessions(for: Self.taskAID, on: try day("2026-09-10T09:00:00"))
        XCTAssertTrue(sessions.isEmpty)
        // And no file was created by reading.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: logFile("2026-09-10.md").path(percentEncoded: false)))
    }

    func testReadDayReturnsFixtureEntriesInFileOrder() async throws {
        let store = makeStore()
        let log = try await store.readDay(for: try fixtureDate())
        XCTAssertEqual(log.sessions.map(\.sessionID), [Self.session1ID, Self.session2ID])
        XCTAssertEqual(log.breaks.map(\.breakID), [Self.breakID])
    }

    func testMalformedDayFileFailsReadWithTypedError() async throws {
        try FileManager.default.createDirectory(
            at: logFile("").deletingLastPathComponent(), withIntermediateDirectories: true)
        let bad = logFile("2026-09-11.md")
        try Data("---\nsessions: [unclosed\n---\n".utf8).write(to: bad)

        let store = makeStore()
        let date = try day("2026-09-11T09:00:00")
        do {
            _ = try await store.readDay(for: date)
            XCTFail("expected malformedFrontmatter")
        } catch let error as DailyLogError {
            guard case .malformedFrontmatter(.invalidYAML) = error else {
                return XCTFail("expected malformedFrontmatter(.invalidYAML), got \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testMissingFieldFailsReadNamingField() async throws {
        try FileManager.default.createDirectory(
            at: logFile("").deletingLastPathComponent(), withIntermediateDirectories: true)
        let bad = logFile("2026-09-12.md")
        try Data("""
        ---
        sessions:
          - session_id: e4f6a8b0-3c5d-4e7f-9a1b-2d4e6f8a0b51
            task_id: 3f2a9c1e-5b7d-4e8a-9c21-7d4e6f8a1b02
            started_at: 2026-09-12T10:00:00
            ended_at: 2026-09-12T10:30:00
            focused_duration: 25
            pause_count: 0
            paused_duration: 5
            energy_rating: 3
            task_completed: false
        breaks: []
        ---
        """.utf8).write(to: bad)

        let store = makeStore()
        let date = try day("2026-09-12T10:00:00")
        await expectError(
            .missingField(
                entry: DailyLogEntryRef(
                    list: .sessions, index: 0, id: Self.session1ID),
                field: "focus_rating")
        ) {
            try await store.readDay(for: date)
        }
    }

    func testReadDoesNotEnforceArithmeticInvariant() async throws {
        // Pinned decision: a hand-edited file with inconsistent durations
        // still loads (the invariant is enforced on append only).
        try FileManager.default.createDirectory(
            at: logFile("").deletingLastPathComponent(), withIntermediateDirectories: true)
        let handEdited = logFile("2026-09-13.md")
        try Data("""
        ---
        sessions:
          - session_id: e4f6a8b0-3c5d-4e7f-9a1b-2d4e6f8a0b51
            task_id: 3f2a9c1e-5b7d-4e8a-9c21-7d4e6f8a1b02
            started_at: 2026-09-13T10:00:00
            ended_at: 2026-09-13T10:30:00
            focused_duration: 10
            pause_count: 0
            paused_duration: 0
            focus_rating: 4
            energy_rating: 3
            task_completed: false
        breaks: []
        ---
        """.utf8).write(to: handEdited)

        let store = makeStore()
        let log = try await store.readDay(for: try day("2026-09-13T10:00:00"))
        XCTAssertEqual(log.sessions.count, 1)
        XCTAssertEqual(log.sessions[0].focusedDuration, 10)
        XCTAssertEqual(log.sessions[0].pausedDuration, 0)
    }

    // MARK: - Appending to the fixture copy

    func testAppendSessionToFixtureCopyPreservesEntriesAndBodyByteForByte() async throws {
        let store = makeStore()
        let url = logFile("2026-09-04.md")
        let original = try text(at: url)
        let originalParsed = try DailyLogCodec.parseDay(original)

        let newSession = try makeSession(
            taskID: Self.taskAID, start: "2026-09-04T13:00:00", end: "2026-09-04T13:25:00",
            focused: 25, notes: "Afternoon sprint.")
        try await store.appendSession(newSession, to: try fixtureDate())

        let updated = try text(at: url)
        let updatedParsed = try DailyLogCodec.parseDay(updated)

        // Parses back with the original and the new entries, in order.
        XCTAssertEqual(
            updatedParsed.log.sessions, originalParsed.log.sessions + [newSession])
        XCTAssertEqual(updatedParsed.log.breaks, originalParsed.log.breaks)

        // The body is byte-for-byte.
        XCTAssertEqual(updatedParsed.body, originalParsed.body)

        // Byte-level: every original session line (the frontmatter before the
        // breaks key) is untouched — the new entry was inserted after the last
        // session, before `breaks:`.
        let originalFM = try FrontmatterCodec.split(original).frontmatter
        let updatedFM = try FrontmatterCodec.split(updated).frontmatter
        XCTAssertTrue(
            updatedFM.hasPrefix(try fixtureSessionsBlock(of: originalFM)),
            "original session lines must survive byte-for-byte before the breaks key")

        // And the whole file is the deterministic re-serialization.
        XCTAssertEqual(
            Data(updated.utf8),
            Data(DailyLogCodec.encodeDay(
                sessions: originalParsed.log.sessions + [newSession],
                breaks: originalParsed.log.breaks,
                body: originalParsed.body).utf8))
    }

    func testAppendBreakToFixtureCopyPreservesEntriesAndBodyByteForByte() async throws {
        let store = makeStore()
        let url = logFile("2026-09-04.md")
        let original = try text(at: url)
        let originalParsed = try DailyLogCodec.parseDay(original)

        let newBreak = try makeBreak(
            start: "2026-09-04T15:00:00", end: "2026-09-04T15:10:00", duration: 10)
        try await store.appendBreak(newBreak, to: try fixtureDate())

        let updated = try text(at: url)
        let updatedParsed = try DailyLogCodec.parseDay(updated)

        XCTAssertEqual(updatedParsed.log.breaks, originalParsed.log.breaks + [newBreak])
        XCTAssertEqual(updatedParsed.log.sessions, originalParsed.log.sessions)
        XCTAssertEqual(updatedParsed.body, originalParsed.body)

        // A new break goes after the last break — i.e. at the very end of the
        // frontmatter — so the ENTIRE original frontmatter is a byte-prefix
        // (stronger than needed: nothing moved at all).
        let originalFM = try FrontmatterCodec.split(original).frontmatter
        let updatedFM = try FrontmatterCodec.split(updated).frontmatter
        XCTAssertTrue(
            updatedFM.hasPrefix(originalFM),
            "original frontmatter (sessions + breaks) must survive byte-for-byte")

        XCTAssertEqual(
            Data(updated.utf8),
            Data(DailyLogCodec.encodeDay(
                sessions: originalParsed.log.sessions,
                breaks: originalParsed.log.breaks + [newBreak],
                body: originalParsed.body).utf8))
    }

    func testAppendToAbsentDateCreatesCanonicalFile() async throws {
        let store = makeStore()
        let date = try day("2026-09-10T09:00:00")
        let url = logFile("2026-09-10.md")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: url.path(percentEncoded: false)))

        let session = try makeSession(
            taskID: Self.taskAID, start: "2026-09-10T09:00:00", end: "2026-09-10T09:30:00",
            focused: 30, notes: nil)
        try await store.appendSession(session, to: date)

        // Created in canonical format: both keys present (empty breaks as []),
        // empty body (documented choice), parses back.
        let created = try text(at: url)
        XCTAssertTrue(created.contains("sessions:"))
        XCTAssertTrue(created.contains("breaks: []"))
        XCTAssertEqual(
            created, DailyLogCodec.encodeDay(sessions: [session], breaks: [], body: ""))

        let parsed = try await store.readDay(for: date)
        XCTAssertEqual(parsed.sessions, [session])
        XCTAssertEqual(parsed.breaks, [])
    }

    func testAppendBreakToAbsentDateCreatesCanonicalFile() async throws {
        let store = makeStore()
        let date = try day("2026-09-10T09:00:00")
        let breakLog = try makeBreak(
            start: "2026-09-10T10:00:00", end: "2026-09-10T10:05:00", duration: 5)
        try await store.appendBreak(breakLog, to: date)

        let created = try text(at: logFile("2026-09-10.md"))
        XCTAssertEqual(
            created, DailyLogCodec.encodeDay(sessions: [], breaks: [breakLog], body: ""))
        let parsed = try await store.readDay(for: date)
        XCTAssertEqual(parsed.breaks, [breakLog])
    }

    func testAppendCreatesLogsDirectoryForFreshVault() async throws {
        // A vault root without Logs/: the first append creates the directory.
        let freshVault = root.appendingPathComponent("fresh-vault", isDirectory: true)
        let store = DailyLogStore(vaultURL: freshVault)
        let date = try day("2026-09-10T09:00:00")
        let session = try makeSession(
            taskID: Self.taskAID, start: "2026-09-10T09:00:00", end: "2026-09-10T09:30:00",
            focused: 30, notes: nil)
        try await store.appendSession(session, to: date)

        let parsed = try await store.readDay(for: date)
        XCTAssertEqual(parsed.sessions, [session])
    }

    // MARK: - Arithmetic validation on append (typed, nothing written)

    func testSessionArithmeticMismatchRejectedAndFileUntouched() async throws {
        let store = makeStore()
        let url = logFile("2026-09-04.md")
        let original = try bytes(at: url)

        // 29-minute span ≠ 25 focused + 5 paused.
        let inconsistent = try makeSession(
            taskID: Self.taskAID, start: "2026-09-04T13:00:00", end: "2026-09-04T13:29:00",
            focused: 25, paused: 5, notes: nil)
        await expectError(
            .sessionArithmeticMismatch(
                sessionID: inconsistent.sessionID,
                startedAt: "2026-09-04T13:00:00",
                endedAt: "2026-09-04T13:29:00",
                focusedMinutes: 25,
                pausedMinutes: 5,
                spanSeconds: 29 * 60)
        ) {
            try await store.appendSession(inconsistent, to: try fixtureDate())
        }
        XCTAssertEqual(try bytes(at: url), original, "file must be untouched")
    }

    func testSessionArithmeticMismatchOnAbsentDateCreatesNothing() async throws {
        let store = makeStore()
        let inconsistent = try makeSession(
            taskID: Self.taskAID, start: "2026-09-14T10:00:00", end: "2026-09-14T10:31:00",
            focused: 30, paused: 0, notes: nil)
        await expectError(
            .sessionArithmeticMismatch(
                sessionID: inconsistent.sessionID,
                startedAt: "2026-09-14T10:00:00",
                endedAt: "2026-09-14T10:31:00",
                focusedMinutes: 30,
                pausedMinutes: 0,
                spanSeconds: 31 * 60)
        ) {
            try await store.appendSession(inconsistent, to: try day("2026-09-14T10:00:00"))
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: logFile("2026-09-14.md").path(percentEncoded: false)),
            "a rejected append must not create the file")
    }

    func testBreakArithmeticMismatchRejectedAndFileUntouched() async throws {
        let store = makeStore()
        let url = logFile("2026-09-04.md")
        let original = try bytes(at: url)

        // 6-minute span ≠ 7-minute duration.
        let inconsistent = try makeBreak(
            start: "2026-09-04T15:00:00", end: "2026-09-04T15:06:00", duration: 7)
        await expectError(
            .breakArithmeticMismatch(
                breakID: inconsistent.breakID,
                startedAt: "2026-09-04T15:00:00",
                endedAt: "2026-09-04T15:06:00",
                durationMinutes: 7,
                spanSeconds: 6 * 60)
        ) {
            try await store.appendBreak(inconsistent, to: try fixtureDate())
        }
        XCTAssertEqual(try bytes(at: url), original, "file must be untouched")
    }

    // MARK: - Session check at whole-minute granularity (issue #27)

    func testSubMinuteSpanWithMinuteSumAppendsIssue27Repro() async throws {
        // The #27 repro: a 66 s span with focused 1 / paused 0 — under the
        // old exact-second check this could NEVER pass (66 ≠ 60·k); the
        // #27 amendment compares nearest(66/60) == 1 == 1 + 0.
        let store = makeStore()
        let date = try day("2026-09-10T09:00:00")
        let repro = try makeSession(
            taskID: Self.taskAID, start: "2026-09-10T09:00:00", end: "2026-09-10T09:01:06",
            focused: 1, paused: 0, notes: nil)
        try await store.appendSession(repro, to: date)
        let parsed = try await store.readDay(for: date)
        XCTAssertEqual(parsed.sessions, [repro])
    }

    func testWholeMinuteSpanStillAppends() async throws {
        // The amendment does not loosen the aligned case: a 60 s span with
        // a 1-minute sum appends exactly as before.
        let store = makeStore()
        let date = try day("2026-09-10T09:00:00")
        let aligned = try makeSession(
            taskID: Self.taskAID, start: "2026-09-10T09:00:00", end: "2026-09-10T09:01:00",
            focused: 1, paused: 0, notes: nil)
        try await store.appendSession(aligned, to: date)
        let parsed = try await store.readDay(for: date)
        XCTAssertEqual(parsed.sessions, [aligned])
    }

    func testMinuteSumOffByOneMinuteFromSpanStillFails() async throws {
        // The check still catches real corruption: a 3600 s span vs a
        // 61-minute sum — nearest(3600/60) = 60 ≠ 61.
        let store = makeStore()
        let corrupted = try makeSession(
            taskID: Self.taskAID, start: "2026-09-10T10:00:00", end: "2026-09-10T11:00:00",
            focused: 30, paused: 31, notes: nil)
        await expectError(
            .sessionArithmeticMismatch(
                sessionID: corrupted.sessionID,
                startedAt: "2026-09-10T10:00:00",
                endedAt: "2026-09-10T11:00:00",
                focusedMinutes: 30,
                pausedMinutes: 31,
                spanSeconds: 3600)
        ) {
            try await store.appendSession(corrupted, to: try day("2026-09-10T10:00:00"))
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: logFile("2026-09-10.md").path(percentEncoded: false)),
            "a rejected append must not create the file")
    }

    func testNegativeSpanStillFails() async throws {
        // ended before started: −30 s → nearest(−0.5) = −1 (away from zero)
        // ≠ the 0-minute sum — a negative span still fails, unchanged.
        let store = makeStore()
        let negative = try makeSession(
            taskID: Self.taskAID, start: "2026-09-10T10:00:30", end: "2026-09-10T10:00:00",
            focused: 0, paused: 0, notes: nil)
        await expectError(
            .sessionArithmeticMismatch(
                sessionID: negative.sessionID,
                startedAt: "2026-09-10T10:00:30",
                endedAt: "2026-09-10T10:00:00",
                focusedMinutes: 0,
                pausedMinutes: 0,
                spanSeconds: -30)
        ) {
            try await store.appendSession(negative, to: try day("2026-09-10T10:00:00"))
        }
    }

    func testNonFiniteSpanStillFailsAtCodecLevel() throws {
        // `exactSpanSeconds` maps a non-finite interval to 0 (nothing
        // traps); the check then fails against the non-negative minute sum,
        // unchanged. Asserted at the codec level — the append would fail
        // before any I/O, so no day file is involved.
        let nonFinite = FocusSessionLog(
            sessionID: UUID(), taskID: Self.taskAID,
            startedAt: Date(timeIntervalSinceReferenceDate: 0),
            endedAt: Date(timeIntervalSinceReferenceDate: .infinity),
            focusedDuration: 1, pauseCount: 0, pausedDuration: 0,
            focusRating: 4, energyRating: 4, taskCompleted: false, notes: nil)
        guard
            case .sessionArithmeticMismatch = DailyLogCodec.appendValidationFailure(
                for: nonFinite)
        else {
            return XCTFail("a non-finite span must still fail validation")
        }
    }

    // MARK: - Concurrency (pinned strategy: actor-serialized read-modify-write)

    func testConcurrentAppendsLeaveExactlyNEntries() async throws {
        let store = makeStore()
        let date = try day("2026-09-20T09:00:00")
        let n = 8
        let sessionBase = try day("2026-09-20T09:00:00")
        let breakBase = try day("2026-09-20T12:00:00")
        let sessions = (0..<n).map { index -> FocusSessionLog in
            let start = sessionBase.addingTimeInterval(Double(index) * 1800)
            return FocusSessionLog(
                sessionID: UUID(), taskID: Self.taskAID,
                startedAt: start,
                endedAt: start.addingTimeInterval(1500),
                focusedDuration: 25, pauseCount: 0, pausedDuration: 0,
                focusRating: 4, energyRating: 4, taskCompleted: false, notes: nil)
        }
        let breaks = (0..<n).map { index -> BreakLog in
            let start = breakBase.addingTimeInterval(Double(index) * 900)
            return BreakLog(
                breakID: UUID(),
                startedAt: start,
                endedAt: start.addingTimeInterval(300),
                duration: 5)
        }

        // 2N concurrent appends to the same day file through one store.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for session in sessions {
                group.addTask { try await store.appendSession(session, to: date) }
            }
            for breakLog in breaks {
                group.addTask { try await store.appendBreak(breakLog, to: date) }
            }
            while try await group.next() != nil {}
        }

        let log = try await store.readDay(for: date)
        XCTAssertEqual(log.sessions.count, n, "no concurrent append may be lost")
        XCTAssertEqual(log.breaks.count, n, "no concurrent append may be lost")
        XCTAssertEqual(Set(log.sessions.map(\.sessionID)), Set(sessions.map(\.sessionID)))
        XCTAssertEqual(Set(log.breaks.map(\.breakID)), Set(breaks.map(\.breakID)))
    }

    // MARK: - sessions(for:on:) helper (#20 "Session N today")

    func testSessionsForTaskMatchesFiltersAndKeepsFileOrder() async throws {
        let store = makeStore()
        let date = try fixtureDate()

        // The fixture: session 1 belongs to task A, session 2 to task B.
        var taskASessions = try await store.sessions(for: Self.taskAID, on: date)
        let taskBSessions = try await store.sessions(for: Self.taskBID, on: date)
        XCTAssertEqual(taskASessions.map(\.sessionID), [Self.session1ID])
        XCTAssertEqual(taskBSessions.map(\.sessionID), [Self.session2ID])
        let unknownTaskSessions = try await store.sessions(for: UUID(), on: date)
        XCTAssertTrue(unknownTaskSessions.isEmpty)

        // Two more sessions for task A (plus one for task B) — the helper
        // returns file order, only matching the given task.
        let newA1 = try makeSession(
            taskID: Self.taskAID, start: "2026-09-04T13:00:00", end: "2026-09-04T13:30:00",
            focused: 30, notes: nil)
        let newB = try makeSession(
            taskID: Self.taskBID, start: "2026-09-04T14:00:00", end: "2026-09-04T14:20:00",
            focused: 20, notes: nil)
        let newA2 = try makeSession(
            taskID: Self.taskAID, start: "2026-09-04T15:00:00", end: "2026-09-04T15:25:00",
            focused: 25, notes: nil)
        try await store.appendSession(newA1, to: date)
        try await store.appendSession(newB, to: date)
        try await store.appendSession(newA2, to: date)

        taskASessions = try await store.sessions(for: Self.taskAID, on: date)
        XCTAssertEqual(
            taskASessions.map(\.sessionID),
            [Self.session1ID, newA1.sessionID, newA2.sessionID],
            "matches only the given task_id, in file order")
        XCTAssertEqual(taskASessions.count, 3, "count is what #20 uses for Session N today")
        let taskBSessionsAfter = try await store.sessions(for: Self.taskBID, on: date)
        XCTAssertEqual(
            taskBSessionsAfter.map(\.sessionID),
            [Self.session2ID, newB.sessionID])
    }
}
