import XCTest
@testable import FocusTracker

/// Codec-level tests for the daily log format (issue #11). The fixture file
/// itself is read directly for the parse/round-trip tests (read-only, never
/// written); mutation tests belong to `DailyLogStoreTests` on temp-dir copies.
final class DailyLogCodecTests: XCTestCase {

    // MARK: - Fixture access

    private static let fixtureLog = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests/FocusTrackerTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root
        .appendingPathComponent(
            "fixtures/sample-vault/Logs/2026-09-04.md", isDirectory: false)

    private static func day(_ timestamp: String) throws -> Date {
        try XCTUnwrap(
            DailyLogDay.date(fromTimestamp: timestamp),
            "fixture timestamp \(timestamp) must parse")
    }

    private func fixtureText() throws -> String {
        try String(decoding: Data(contentsOf: Self.fixtureLog), as: UTF8.self)
    }

    // MARK: - Exact fixture parse (issue #11 criterion 1)

    func testParseFixtureExactValues() throws {
        let parsed = try DailyLogCodec.parseDay(fixtureText())

        XCTAssertEqual(parsed.log.sessions.count, 2)
        XCTAssertEqual(parsed.log.breaks.count, 1)

        // Session 1 — the pause demo.
        let session1 = parsed.log.sessions[0]
        XCTAssertEqual(
            session1.sessionID, UUID(uuidString: "e4f6a8b0-3c5d-4e7f-9a1b-2d4e6f8a0b51"))
        XCTAssertEqual(session1.taskID, UUID(uuidString: "3f2a9c1e-5b7d-4e8a-9c21-7d4e6f8a1b02"))
        XCTAssertEqual(session1.startedAt, try Self.day("2026-09-04T10:00:00"))
        XCTAssertEqual(session1.endedAt, try Self.day("2026-09-04T10:30:00"))
        XCTAssertEqual(session1.focusedDuration, 25)
        XCTAssertEqual(session1.pauseCount, 1)
        XCTAssertEqual(session1.pausedDuration, 5)
        XCTAssertEqual(session1.focusRating, 4)
        XCTAssertEqual(session1.energyRating, 3)
        XCTAssertEqual(session1.taskCompleted, false)
        XCTAssertEqual(session1.notes, "One pause to take a phone call.")

        // Session 2 — the early-end demo.
        let session2 = parsed.log.sessions[1]
        XCTAssertEqual(
            session2.sessionID, UUID(uuidString: "f5a7b9c1-4d6e-4f8a-2b3c-9e5f7a1b2c62"))
        XCTAssertEqual(session2.taskID, UUID(uuidString: "8a4c2e6f-1d3b-4f5a-8b9c-2e7d1a4c6e08"))
        XCTAssertEqual(session2.startedAt, try Self.day("2026-09-04T11:00:00"))
        XCTAssertEqual(session2.endedAt, try Self.day("2026-09-04T11:15:00"))
        XCTAssertEqual(session2.focusedDuration, 15)
        XCTAssertEqual(session2.pauseCount, 0)
        XCTAssertEqual(session2.pausedDuration, 0)
        XCTAssertEqual(session2.focusRating, 3)
        XCTAssertEqual(session2.energyRating, 2)
        XCTAssertEqual(session2.taskCompleted, false)
        XCTAssertEqual(session2.notes, "Ended early, ran out of steam.")

        // The one break — 10:30→10:36, 6 minutes.
        let breakLog = parsed.log.breaks[0]
        XCTAssertEqual(breakLog.breakID, UUID(uuidString: "a6b8c0d2-5e7f-4a9b-8c1d-3f5a7b9c1d73"))
        XCTAssertEqual(breakLog.startedAt, try Self.day("2026-09-04T10:30:00"))
        XCTAssertEqual(breakLog.endedAt, try Self.day("2026-09-04T10:36:00"))
        XCTAssertEqual(breakLog.duration, 6)

        // The body is opaque and byte-for-byte, including its leading blank line.
        XCTAssertEqual(
            parsed.body,
            "\nTwo focus sessions on the roadmap planning, with a short break in between.\n")
    }

    // MARK: - Round-trip byte stability (issue #11 criterion 10)

    func testRoundTripFixtureIsByteIdentical() throws {
        let original = try Data(contentsOf: Self.fixtureLog)
        let parsed = try DailyLogCodec.parseDay(
            try String(decoding: original, as: UTF8.self))
        let reserialized = DailyLogCodec.encodeDay(
            sessions: parsed.log.sessions, breaks: parsed.log.breaks, body: parsed.body)
        XCTAssertEqual(Data(reserialized.utf8), original)
    }

    // MARK: - Missing keys read as empty lists

    func testMissingKeysReadAsEmptyLists() throws {
        // Both keys absent (empty frontmatter) → empty day.
        let both = try DailyLogCodec.parseDay("---\n---\n")
        XCTAssertEqual(both.log, DailyLog())
        // Only sessions present → breaks empty.
        let onlySessions = try DailyLogCodec.parseDay(
            "---\nsessions: []\n---\n")
        XCTAssertEqual(onlySessions.log.sessions, [])
        XCTAssertEqual(onlySessions.log.breaks, [])
        // Only breaks present → sessions empty.
        let onlyBreaks = try DailyLogCodec.parseDay(
            "---\nbreaks: []\n---\n")
        XCTAssertEqual(onlyBreaks.log.sessions, [])
        XCTAssertEqual(onlyBreaks.log.breaks, [])
    }

    // MARK: - Per-entry typed errors name field + entry

    func testMissingSessionFieldNamesFieldAndEntry() throws {
        let text = """
        ---
        sessions:
          - session_id: e4f6a8b0-3c5d-4e7f-9a1b-2d4e6f8a0b51
            task_id: 3f2a9c1e-5b7d-4e8a-9c21-7d4e6f8a1b02
            started_at: 2026-09-04T10:00:00
            ended_at: 2026-09-04T10:30:00
            focused_duration: 25
            pause_count: 1
            paused_duration: 5
            energy_rating: 3
            task_completed: false
        breaks: []
        ---
        """
        // `focus_rating` is missing; the error names the field and the entry
        // (index 0, carrying its decoded session_id).
        XCTAssertThrowsError(try DailyLogCodec.parseDay(text)) { error in
            XCTAssertEqual(
                error as? DailyLogError,
                .missingField(
                    entry: DailyLogEntryRef(
                        list: .sessions, index: 0,
                        id: UUID(uuidString: "e4f6a8b0-3c5d-4e7f-9a1b-2d4e6f8a0b51")),
                    field: "focus_rating"))
        }
    }

    func testMissingBreakFieldNamesFieldAndEntry() throws {
        let text = """
        ---
        sessions: []
        breaks:
          - break_id: a6b8c0d2-5e7f-4a9b-8c1d-3f5a7b9c1d73
            started_at: 2026-09-04T10:30:00
            ended_at: 2026-09-04T10:36:00
        ---
        """
        XCTAssertThrowsError(try DailyLogCodec.parseDay(text)) { error in
            XCTAssertEqual(
                error as? DailyLogError,
                .missingField(
                    entry: DailyLogEntryRef(
                        list: .breaks, index: 0,
                        id: UUID(uuidString: "a6b8c0d2-5e7f-4a9b-8c1d-3f5a7b9c1d73")),
                    field: "duration"))
        }
    }

    func testWrongFieldTypesFailTyped() throws {
        // Quoted integer → no silent coercion (mirrors the #4 codec's stance).
        let quotedInt = """
        ---
        sessions:
          - session_id: e4f6a8b0-3c5d-4e7f-9a1b-2d4e6f8a0b51
            task_id: 3f2a9c1e-5b7d-4e8a-9c21-7d4e6f8a1b02
            started_at: 2026-09-04T10:00:00
            ended_at: 2026-09-04T10:30:00
            focused_duration: '25'
            pause_count: 1
            paused_duration: 5
            focus_rating: 4
            energy_rating: 3
            task_completed: false
        breaks: []
        ---
        """
        XCTAssertThrowsError(try DailyLogCodec.parseDay(quotedInt)) { error in
            XCTAssertEqual(
                error as? DailyLogError,
                .wrongType(
                    entry: DailyLogEntryRef(
                        list: .sessions, index: 0,
                        id: UUID(uuidString: "e4f6a8b0-3c5d-4e7f-9a1b-2d4e6f8a0b51")),
                    field: "focused_duration", value: "25", expected: "integer"))
        }

        // Invalid UUID.
        let badUUID = """
        ---
        sessions:
          - session_id: not-a-uuid
            task_id: 3f2a9c1e-5b7d-4e8a-9c21-7d4e6f8a1b02
            started_at: 2026-09-04T10:00:00
            ended_at: 2026-09-04T10:30:00
            focused_duration: 25
            pause_count: 1
            paused_duration: 5
            focus_rating: 4
            energy_rating: 3
            task_completed: false
        breaks: []
        ---
        """
        XCTAssertThrowsError(try DailyLogCodec.parseDay(badUUID)) { error in
            XCTAssertEqual(
                error as? DailyLogError,
                .invalidUUID(
                    entry: DailyLogEntryRef(list: .sessions, index: 0, id: nil),
                    field: "session_id", value: "not-a-uuid"))
        }

        // Timestamp outside the pinned convention.
        let badTimestamp = """
        ---
        sessions:
          - session_id: e4f6a8b0-3c5d-4e7f-9a1b-2d4e6f8a0b51
            task_id: 3f2a9c1e-5b7d-4e8a-9c21-7d4e6f8a1b02
            started_at: 2026-09-04 10:00
            ended_at: 2026-09-04T10:30:00
            focused_duration: 25
            pause_count: 1
            paused_duration: 5
            focus_rating: 4
            energy_rating: 3
            task_completed: false
        breaks: []
        ---
        """
        XCTAssertThrowsError(try DailyLogCodec.parseDay(badTimestamp)) { error in
            XCTAssertEqual(
                error as? DailyLogError,
                .invalidTimestamp(
                    entry: DailyLogEntryRef(
                        list: .sessions, index: 0,
                        id: UUID(uuidString: "e4f6a8b0-3c5d-4e7f-9a1b-2d4e6f8a0b51")),
                    field: "started_at", value: "2026-09-04 10:00"))
        }
    }

    func testUnknownKeysFailTyped() throws {
        // Unknown top-level key — fail-loud (PRD §18), same stance as #4.
        let topLevel = "---\nsessions: []\nbreaks: []\nmood: happy\n---\n"
        XCTAssertThrowsError(try DailyLogCodec.parseDay(topLevel)) { error in
            XCTAssertEqual(error as? DailyLogError, .unknownKeys(["mood"]))
        }

        // Unknown per-entry key.
        let entryLevel = """
        ---
        sessions:
          - session_id: e4f6a8b0-3c5d-4e7f-9a1b-2d4e6f8a0b51
            task_id: 3f2a9c1e-5b7d-4e8a-9c21-7d4e6f8a1b02
            started_at: 2026-09-04T10:00:00
            ended_at: 2026-09-04T10:30:00
            focused_duration: 25
            pause_count: 1
            paused_duration: 5
            focus_rating: 4
            energy_rating: 3
            task_completed: false
            title: Overtime
        breaks: []
        ---
        """
        XCTAssertThrowsError(try DailyLogCodec.parseDay(entryLevel)) { error in
            XCTAssertEqual(
                error as? DailyLogError,
                .unknownEntryKeys(
                    // The unknown-keys schema check runs before any field
                    // decode, so the ref carries the index but no ID yet.
                    entry: DailyLogEntryRef(list: .sessions, index: 0, id: nil),
                    keys: ["title"]))
        }
    }

    func testMalformedFilesFailTyped() throws {
        // Invalid YAML inside the frontmatter.
        let badYAML = "---\nsessions: [unclosed\n---\n"
        XCTAssertThrowsError(try DailyLogCodec.parseDay(badYAML)) { error in
            guard case .malformedFrontmatter(.invalidYAML) = error as? DailyLogError else {
                return XCTFail("expected malformedFrontmatter(.invalidYAML), got \(error)")
            }
        }
        // Missing closing delimiter (via the reused #4 splitter).
        let noClosing = "---\nsessions: []\n"
        XCTAssertThrowsError(try DailyLogCodec.parseDay(noClosing)) { error in
            XCTAssertEqual(
                error as? DailyLogError,
                .malformedFrontmatter(.missingClosingDelimiter))
        }
        // A list element that is not a mapping.
        let scalarEntry = "---\nsessions:\n  - 42\nbreaks: []\n---\n"
        XCTAssertThrowsError(try DailyLogCodec.parseDay(scalarEntry)) { error in
            XCTAssertEqual(
                error as? DailyLogError,
                .entryNotAMapping(entry: DailyLogEntryRef(list: .sessions, index: 0, id: nil)))
        }
    }

    // MARK: - Canonical empty-day serialization

    func testEncodeEmptyDayWritesBothKeysAsEmptyLists() {
        let text = DailyLogCodec.encodeDay(sessions: [], breaks: [], body: "")
        XCTAssertEqual(text, "---\nsessions: []\nbreaks: []\n---\n")
        // And it parses back to the empty day.
        let parsed = try? DailyLogCodec.parseDay(text)
        XCTAssertEqual(parsed?.log, DailyLog())
        XCTAssertEqual(parsed?.body, "")
    }

    func testEncodeOmitsNilNotesNeverWritesNull() throws {
        let session = FocusSessionLog(
            sessionID: UUID(uuidString: "e4f6a8b0-3c5d-4e7f-9a1b-2d4e6f8a0b51")!,
            taskID: UUID(uuidString: "3f2a9c1e-5b7d-4e8a-9c21-7d4e6f8a1b02")!,
            startedAt: try Self.day("2026-09-04T10:00:00"),
            endedAt: try Self.day("2026-09-04T10:30:00"),
            focusedDuration: 25, pauseCount: 0, pausedDuration: 5,
            focusRating: 4, energyRating: 3, taskCompleted: false, notes: nil)
        let text = DailyLogCodec.encodeDay(sessions: [session], breaks: [], body: "")
        XCTAssertFalse(text.contains("notes"))
        XCTAssertFalse(text.contains("null"))
        // Round-trips: notes reads back as nil.
        let parsed = try DailyLogCodec.parseDay(text)
        XCTAssertNil(parsed.log.sessions[0].notes)
        XCTAssertEqual(parsed.log.sessions[0], session)
    }

    // MARK: - Date conventions (one place: DailyLogDay)

    func testDailyLogDayConventions() throws {
        // Filename = local calendar day + ".md".
        let date = try Self.day("2026-09-04T10:00:00")
        XCTAssertEqual(DailyLogDay.fileName(for: date), "2026-09-04.md")
        XCTAssertEqual(DailyLogDay.dayString(for: date), "2026-09-04")

        // Offset-less second-precision timestamps round-trip exactly.
        XCTAssertEqual(DailyLogDay.timestampString(from: date), "2026-09-04T10:00:00")

        // Strict parsing rejects malformed values (same stance as DeadlineDay).
        XCTAssertNil(DailyLogDay.date(fromTimestamp: "2026-1-5"))
        XCTAssertNil(DailyLogDay.date(fromTimestamp: "2026-02-30"))
        XCTAssertNil(DailyLogDay.date(fromTimestamp: "not-a-time"))
        XCTAssertNil(DailyLogDay.date(fromTimestamp: "2026-09-04T10:00"))
    }
}
