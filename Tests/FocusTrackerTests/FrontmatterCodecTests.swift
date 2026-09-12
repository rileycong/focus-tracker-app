import XCTest
@testable import FocusTracker

final class FrontmatterCodecTests: XCTestCase {
    // MARK: - Fixture access (read-only; fixtures are never modified)

    private static let fixturesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests/FocusTrackerTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("fixtures/sample-vault/Tasks", isDirectory: true)

    private func fixtureText(_ name: String) throws -> String {
        try String(contentsOf: Self.fixturesDirectory.appendingPathComponent(name), encoding: .utf8)
    }

    private func parseFixture(_ name: String) throws -> (text: String, task: TaskItem, body: String) {
        let text = try fixtureText(name)
        let (frontmatter, body) = try FrontmatterCodec.split(text)
        return (text, try FrontmatterCodec.decodeTask(frontmatter: frontmatter), body)
    }

    // MARK: - Helpers

    private static let testIDString = "3f2a9c1e-5b7d-4e8a-9c21-7d4e6f8a1b02"
    private static let testID = UUID(uuidString: testIDString)!

    private let baseYAML = """
    id: 3f2a9c1e-5b7d-4e8a-9c21-7d4e6f8a1b02
    title: Test task
    status: To Do
    categories:
      - Planning
    """

    private func fileText(yaml: String, body: String = "\nSome body.\n") -> String {
        let frontmatter = yaml.hasSuffix("\n") ? yaml : yaml + "\n"
        return "---\n" + frontmatter + "---\n" + body
    }

    private func assertThrows(
        _ expression: @autoclosure () throws -> some Any,
        _ expected: FrontmatterError,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), message(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? FrontmatterError, expected,
                "expected \(expected), got \(error) \(message())",
                file: file, line: line)
        }
    }

    // MARK: - Fixture parsing: exact values

    func testParsingPlanQ4RoadmapYieldsExactValues() throws {
        let task = try parseFixture("Plan Q4 roadmap.md").task
        XCTAssertEqual(task.id, Self.testID)
        XCTAssertEqual(task.title, "Plan Q4 roadmap")
        XCTAssertEqual(task.status, .inProgress)
        XCTAssertEqual(task.categories.map(\.name), ["Planning", "Work"])
        XCTAssertEqual(task.project, Project(name: "Work"))
        XCTAssertEqual(task.priority, .high)
        XCTAssertEqual(task.effort, .l)
        XCTAssertEqual(task.deadline.map(DeadlineDay.string(from:)), "2026-10-15")
        XCTAssertEqual(task.notes, "Draft the roadmap, then review with the team before the offsite.")
    }

    func testParsingReadDeepWorkYieldsExactValues() throws {
        let task = try parseFixture("Read Deep Work.md").task
        XCTAssertEqual(task.id, UUID(uuidString: "c9d1e3f5-2a4b-4c6d-8e0f-7b9a1d3c5e69"))
        XCTAssertEqual(task.title, "Read Deep Work")
        XCTAssertEqual(task.status, .dropped)
        XCTAssertEqual(task.categories.map(\.name), ["Learning"])
        XCTAssertNil(task.project)
        XCTAssertNil(task.priority)
        XCTAssertEqual(task.effort, .xl)
        XCTAssertNil(task.deadline)
        XCTAssertEqual(task.notes, "Dropped after three chapters; revisit next quarter.")
        XCTAssertTrue(task.subtasks.isEmpty)
    }

    func testParsingRenewPassportYieldsExactValues() throws {
        let task = try parseFixture("Renew passport.md").task
        XCTAssertEqual(task.id, UUID(uuidString: "a2b8c4d6-9e1f-4a7b-b3c5-8d2e6f4a1c47"))
        XCTAssertEqual(task.title, "Renew passport")
        XCTAssertEqual(task.status, .blocked)
        XCTAssertEqual(task.categories.map(\.name), ["Admin"])
        XCTAssertNil(task.project)
        XCTAssertEqual(task.priority, .medium)
        XCTAssertEqual(task.effort, .m)
        XCTAssertEqual(task.deadline.map(DeadlineDay.string(from:)), "2026-11-01")
        XCTAssertEqual(task.notes, "Blocked until the new passport photos are ready.")
    }

    func testAllStatusesAndEffortBucketsAppearAcrossFixtures() throws {
        var statuses = Set<TaskStatus>()
        var efforts = Set<Effort>()
        func collect(_ task: TaskItem) {
            statuses.insert(task.status)
            efforts.formUnion(task.effort.map { [$0] } ?? [])
            func collectSubtasks(_ subtasks: [SubtaskItem]) {
                for subtask in subtasks {
                    statuses.insert(subtask.status)
                    efforts.formUnion(subtask.effort.map { [$0] } ?? [])
                    collectSubtasks(subtask.children)
                }
            }
            collectSubtasks(task.subtasks)
        }
        for name in ["Plan Q4 roadmap.md", "Read Deep Work.md", "Renew passport.md"] {
            collect(try parseFixture(name).task)
        }
        XCTAssertEqual(statuses, Set(TaskStatus.allCases), "all five statuses must appear")
        XCTAssertEqual(efforts, Set(Effort.allCases), "all four effort buckets must appear")
    }

    // MARK: - Fixture parsing: nested subtask tree

    func testParsingPlanQ4YieldsFullNestedSubtaskTree() throws {
        let task = try parseFixture("Plan Q4 roadmap.md").task

        XCTAssertEqual(task.subtasks.count, 2)

        let collectInput = task.subtasks[0]
        XCTAssertEqual(collectInput.id, UUID(uuidString: "8a4c2e6f-1d3b-4f5a-8b9c-2e7d1a4c6e08"))
        XCTAssertEqual(collectInput.title, "Collect team input")
        XCTAssertEqual(collectInput.status, .done)
        XCTAssertEqual(collectInput.effort, .s)
        XCTAssertNil(collectInput.priority)
        XCTAssertNil(collectInput.deadline)
        XCTAssertEqual(collectInput.notes, "Gathered via the weekly sync and shared doc.")
        XCTAssertTrue(collectInput.children.isEmpty)

        let draftOKRs = task.subtasks[1]
        XCTAssertEqual(draftOKRs.id, UUID(uuidString: "5d9e7f2a-3c6b-4a1d-9e8f-6b2c4d7a9e13"))
        XCTAssertEqual(draftOKRs.title, "Draft objectives and key results")
        XCTAssertEqual(draftOKRs.status, .inProgress)
        XCTAssertEqual(draftOKRs.priority, .medium)
        XCTAssertEqual(draftOKRs.effort, .m)
        XCTAssertEqual(draftOKRs.deadline.map(DeadlineDay.string(from:)), "2026-09-30")
        XCTAssertEqual(draftOKRs.notes, "Two passes needed; first draft is in the shared doc.")

        XCTAssertEqual(draftOKRs.children.count, 2, "second-level nesting required")
        let defineObjectives = draftOKRs.children[0]
        XCTAssertEqual(defineObjectives.id, UUID(uuidString: "1b6d8f3a-4e7c-4b2a-8d5e-9f3b1c6d8e24"))
        XCTAssertEqual(defineObjectives.title, "Define Q4 objectives")
        XCTAssertEqual(defineObjectives.status, .blocked)
        XCTAssertEqual(defineObjectives.priority, .low)
        XCTAssertEqual(defineObjectives.notes, "Waiting on final company goals from leadership.")

        let mapKeyResults = draftOKRs.children[1]
        XCTAssertEqual(mapKeyResults.id, UUID(uuidString: "7c3e9a4b-5f8d-4c3b-9e6f-1a4c2d8e9f35"))
        XCTAssertEqual(mapKeyResults.title, "Map key results to objectives")
        XCTAssertEqual(mapKeyResults.status, .toDo)
        XCTAssertEqual(mapKeyResults.notes, "Start once the objectives are locked.")
        XCTAssertNil(mapKeyResults.priority)
        XCTAssertTrue(mapKeyResults.children.isEmpty)
    }

    // MARK: - Round-trip and byte-stability

    func testModelRoundTripForEveryFixtureFile() throws {
        for name in ["Plan Q4 roadmap.md", "Read Deep Work.md", "Renew passport.md"] {
            let (text, first, body) = try parseFixture(name)
            let second = try FrontmatterCodec.parseTask(
                FrontmatterCodec.encode(task: first, body: body))
            XCTAssertEqual(second, first, "model round-trip failed for \(name)")
            XCTAssertEqual(
                try FrontmatterCodec.split(FrontmatterCodec.encode(task: first, body: body)).body,
                body, "body round-trip failed for \(name)")
            XCTAssertFalse(text.isEmpty)
        }
    }

    func testSerializedCanonicalFormMatchesFixtureBytesExactly() throws {
        for name in ["Plan Q4 roadmap.md", "Read Deep Work.md", "Renew passport.md"] {
            let (text, task, body) = try parseFixture(name)
            XCTAssertEqual(
                try FrontmatterCodec.encode(task: task, body: body), text,
                "canonical serialization must reproduce \(name) byte-for-byte")
        }
    }

    func testSerializeParseSerializeIsByteIdentical() throws {
        let noonUTC = try XCTUnwrap(DeadlineDay.date(from: "2026-10-15"))
        let leaf = SubtaskItem(
            title: "Sous-tâche 東京 🚀", status: .done, effort: .xl, notes: "true")
        let middle = SubtaskItem(
            title: "123", status: .blocked, priority: .low, deadline: noonUTC,
            children: [leaf])
        let synthetic = try TaskItem(
            title: "Café ☕ 規劃 — Planifié", categories: [Category(name: "Catégorie"), Category(name: "")],
            status: .inProgress, project: Project(name: "2026-10-15"), priority: .high,
            effort: .m, deadline: noonUTC,
            notes: "Multi\nline\twith emoji 🚀 中文 and quotes \"here\"",
            subtasks: [middle])
        var inputs: [(String, TaskItem, String)] = []
        for name in ["Plan Q4 roadmap.md", "Read Deep Work.md", "Renew passport.md"] {
            let (text, task, body) = try parseFixture(name)
            inputs.append((name, task, body))
        }
        inputs.append(("synthetic", synthetic, "\nBody with hr:\n\n---\n\nStill body.\n"))
        inputs.append(("minimal", try TaskItem(title: "Minimal", categories: [Category(name: "Admin")]), ""))
        for (name, task, body) in inputs {
            let first = FrontmatterCodec.encode(task: task, body: body)
            let reparsed = try FrontmatterCodec.split(first)
            let second = FrontmatterCodec.encode(
                task: try FrontmatterCodec.decodeTask(frontmatter: reparsed.frontmatter),
                body: reparsed.body)
            XCTAssertEqual(second, first, "byte instability for \(name)")
        }
    }

    // MARK: - Body opacity

    func testBodyIsPreservedByteForByteIncludingHorizontalRule() throws {
        let body = "\nIntro paragraph.\n\n---\n\nMore after an hr.\n\n----\n\nTrailing blank lines follow.\n\n"
        let text = fileText(yaml: baseYAML + "\n", body: body)
        let (frontmatter, splitBody) = try FrontmatterCodec.split(text)
        XCTAssertEqual(splitBody, body, "body must be byte-for-byte, `---` lines included")
        let task = try FrontmatterCodec.decodeTask(frontmatter: frontmatter)
        let encoded = FrontmatterCodec.encode(task: task, body: splitBody)
        XCTAssertTrue(encoded.hasSuffix(body), "serialization must end with the exact body")
        XCTAssertEqual(encoded, text, "full round-trip is byte-identical")
    }

    func testEmptyBodyParsesAndSerializesWithoutInventingContent() throws {
        for text in [fileText(yaml: baseYAML + "\n", body: ""), "---\n" + baseYAML + "\n---"] {
            let (frontmatter, body) = try FrontmatterCodec.split(text)
            XCTAssertEqual(body, "")
            let task = try FrontmatterCodec.decodeTask(frontmatter: frontmatter)
            let encoded = FrontmatterCodec.encode(task: task, body: body)
            XCTAssertEqual(encoded, "---\n" + baseYAML + "\n---\n")
            XCTAssertEqual(encoded.hasSuffix("---\n"), true)
        }
    }

    func testBodyWithoutLeadingBlankLineStaysUntouched() throws {
        let text = fileText(yaml: baseYAML + "\n", body: "Body directly after delimiter.")
        let (frontmatter, body) = try FrontmatterCodec.split(text)
        XCTAssertEqual(body, "Body directly after delimiter.")
        let task = try FrontmatterCodec.decodeTask(frontmatter: frontmatter)
        XCTAssertEqual(FrontmatterCodec.encode(task: task, body: body), text)
    }

    func testSplitExtractsFrontmatterBetweenFirstTwoDelimitersOnly() throws {
        let text = fileText(
            yaml: "id: \(Self.testIDString)\ntitle: T\nstatus: Done\ncategories:\n  - A\n",
            body: "\n---\n\ncategories: [not-yaml]\n")
        let (frontmatter, body) = try FrontmatterCodec.split(text)
        XCTAssertTrue(frontmatter.hasPrefix("id: "))
        XCTAssertEqual(body, "\n---\n\ncategories: [not-yaml]\n")
        let task = try FrontmatterCodec.decodeTask(frontmatter: frontmatter)
        XCTAssertEqual(task.title, "T")
        XCTAssertEqual(task.categories.map(\.name), ["A"])
    }

    // MARK: - Lenient-but-lossless reads

    func testValidButDifferentlyOrderedAndQuotedYAMLParses() throws {
        let text = fileText(yaml: """
        status: Done
        notes: 'has: colon'
        title: "Reordered"
        categories: [Admin]
        effort: S
        deadline: '2026-10-15'
        id: C9D1E3F5-2A4B-4C6D-8E0F-7B9A1D3C5E69
        """)
        let task = try FrontmatterCodec.parseTask(text)
        XCTAssertEqual(task.status, .done)
        XCTAssertEqual(task.notes, "has: colon")
        XCTAssertEqual(task.title, "Reordered")
        XCTAssertEqual(task.categories.map(\.name), ["Admin"])
        XCTAssertEqual(task.effort, .s)
        XCTAssertEqual(task.deadline.map(DeadlineDay.string(from:)), "2026-10-15")
        XCTAssertEqual(task.id, UUID(uuidString: "c9d1e3f5-2a4b-4c6d-8e0f-7b9a1d3c5e69"))
    }

    func testUnicodeRoundTripsLosslessly() throws {
        let title = "Café ☕ 規劃 — Planifié"
        let notes = "中文注释 with emoji 🚀 and accents éàü; quotes \"x\" and a # hash"
        let subtask = SubtaskItem(title: "Sous-tâche 東京 🚀", status: .toDo, notes: "naïve ✓")
        let task = try TaskItem(
            title: title,
            categories: [Category(name: "Catégorie"), Category(name: "类别")],
            status: .inProgress,
            notes: notes,
            subtasks: [subtask])
        let encoded = FrontmatterCodec.encode(task: task, body: "\n中文 body — café 🚀\n")
        let decoded = try FrontmatterCodec.parseTask(encoded)
        XCTAssertEqual(decoded, task)
        XCTAssertEqual(try FrontmatterCodec.split(encoded).body, "\n中文 body — café 🚀\n")
    }

    func testEmptyStringCategoryRoundTripsLosslessly() throws {
        let task = try TaskItem(
            title: "Empty category", categories: [Category(name: "")], status: .toDo)
        let encoded = FrontmatterCodec.encode(task: task, body: "")
        XCTAssertTrue(encoded.contains("  - ''"), "empty category must be quoted: \(encoded)")
        let decoded = try FrontmatterCodec.parseTask(encoded)
        XCTAssertEqual(decoded, task)
        XCTAssertEqual(decoded.categories.map(\.name), [""])
    }

    // MARK: - Deadline mapping

    func testDeadlineRoundTripsLosslesslyAsYYYYMMDD() throws {
        let deadline = try XCTUnwrap(DeadlineDay.date(from: "2026-10-15"))
        let task = try TaskItem(
            title: "Deadline task", categories: [Category(name: "Planning")],
            status: .toDo, deadline: deadline)
        let encoded = FrontmatterCodec.encode(task: task, body: "\nBody.\n")
        XCTAssertTrue(encoded.contains("\ndeadline: 2026-10-15\n"), encoded)
        let decoded = try FrontmatterCodec.parseTask(encoded)
        XCTAssertEqual(decoded.deadline, deadline)
    }

    func testDeadlineUsesFixedUTCNoonMapping() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        func utcDate(hour: Int, minute: Int = 0) throws -> Date {
            var components = DateComponents()
            components.year = 2026
            components.month = 10
            components.day = 15
            components.hour = hour
            components.minute = minute
            return try XCTUnwrap(calendar.date(from: components))
        }
        let dayStart = try utcDate(hour: 0)
        let noon = try utcDate(hour: 12)
        let lateEvening = try utcDate(hour: 23, minute: 55)
        // All times of day on the 15th (UTC) write the same date; parsing yields UTC noon.
        for moment in [dayStart, noon, lateEvening] {
            XCTAssertEqual(DeadlineDay.string(from: moment), "2026-10-15")
        }
        XCTAssertEqual(DeadlineDay.date(from: "2026-10-15"), noon)
        // Next UTC day is written as the next date regardless of local time zone.
        XCTAssertEqual(
            DeadlineDay.string(from: dayStart.addingTimeInterval(86_400)), "2026-10-16")
        // Non-canonical date strings are rejected, not normalized.
        XCTAssertNil(DeadlineDay.date(from: "2026-1-5"))
        XCTAssertNil(DeadlineDay.date(from: "2026-02-30"))
        XCTAssertNil(DeadlineDay.date(from: "2026-10-15T00:00:00Z"))
        XCTAssertNil(DeadlineDay.date(from: "15/10/2026"))
    }

    // MARK: - Typed errors: delimiters & YAML

    func testMissingOpeningDelimiterThrowsTypedError() {
        assertThrows(try FrontmatterCodec.parseTask("id: x\n---\n"), .missingOpeningDelimiter)
        assertThrows(try FrontmatterCodec.parseTask(""), .missingOpeningDelimiter)
    }

    func testMissingClosingDelimiterThrowsTypedError() {
        assertThrows(try FrontmatterCodec.parseTask("---\nid: x\n"), .missingClosingDelimiter)
    }

    func testInvalidYAMLThrowsTypedError() {
        XCTAssertThrowsError(try FrontmatterCodec.parseTask("---\nkey: [unclosed\n---\n")) {
            error in
            guard case .invalidYAML(let message) = error as? FrontmatterError else {
                return XCTFail("expected .invalidYAML, got \(error)")
            }
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testNonMappingFrontmatterThrowsWrongType() {
        assertThrows(
            try FrontmatterCodec.parseTask("---\njust a string\n---\n"),
            .wrongType(field: "frontmatter", value: "just a string", expected: "mapping"))
    }

    // MARK: - Typed errors: required fields

    func testMissingTaskFieldsNameTheField() {
        let yamlByMissing: [String: String] = [
            "id": "title: T\nstatus: To Do\ncategories:\n  - Planning\n",
            "title": "id: \(Self.testIDString)\nstatus: To Do\ncategories:\n  - Planning\n",
            "status": "id: \(Self.testIDString)\ntitle: T\ncategories:\n  - Planning\n",
            "categories": "id: \(Self.testIDString)\ntitle: T\nstatus: To Do\n",
        ]
        for (field, yaml) in yamlByMissing {
            assertThrows(
                try FrontmatterCodec.parseTask(fileText(yaml: yaml)),
                .missingField(field), "missing \(field)")
        }
        // An explicit null counts as missing, not as a value.
        assertThrows(
            try FrontmatterCodec.parseTask(fileText(yaml: baseYAML.replacingOccurrences(
                of: "title: Test task", with: "title:"))),
            .missingField("title"))
    }

    func testMissingSubtaskFieldsNameTheField() {
        let subtaskByMissing: [String: String] = [
            "id": "  - title: Sub\n    status: To Do\n",
            "title": "  - id: \(Self.testIDString)\n    status: To Do\n",
            "status": "  - id: \(Self.testIDString)\n    title: Sub\n",
        ]
        for (field, subtaskYAML) in subtaskByMissing {
            assertThrows(
                try FrontmatterCodec.parseTask(
                    fileText(yaml: baseYAML + "\nsubtasks:\n" + subtaskYAML)),
                .missingField(field), "subtask missing \(field)")
        }
    }

    // MARK: - Typed errors: unknown keys

    func testUnknownTopLevelKeysThrowSorted() {
        assertThrows(
            try FrontmatterCodec.parseTask(fileText(yaml: baseYAML + "\nzebra: 1\naardvark: 2\n")),
            .unknownKeys(["aardvark", "zebra"]))
    }

    func testUnknownSubtaskKeysThrow() {
        assertThrows(
            try FrontmatterCodec.parseTask(fileText(yaml: baseYAML + """
            \nsubtasks:
              - id: \(Self.testIDString)
                title: Sub
                status: To Do
                category: Not allowed here
            """)),
            .unknownKeys(["category"]))
    }

    // MARK: - Typed errors: malformed values

    func testMalformedUUIDNamesFieldAndValue() {
        assertThrows(
            try FrontmatterCodec.parseTask(fileText(yaml: baseYAML.replacingOccurrences(
                of: "id: \(Self.testIDString)", with: "id: not-a-uuid"))),
            .invalidUUID(field: "id", value: "not-a-uuid"))
    }

    func testInvalidEnumValuesNameFieldAndValue() {
        assertThrows(
            try FrontmatterCodec.parseTask(fileText(yaml: baseYAML.replacingOccurrences(
                of: "status: To Do", with: "status: donee"))),
            .invalidEnumValue(field: "status", value: "donee"))
        assertThrows(
            try FrontmatterCodec.parseTask(fileText(yaml: baseYAML + "\npriority: Nope\n")),
            .invalidEnumValue(field: "priority", value: "Nope"))
        assertThrows(
            try FrontmatterCodec.parseTask(fileText(yaml: baseYAML + "\neffort: XXL\n")),
            .invalidEnumValue(field: "effort", value: "XXL"))
    }

    func testWrongTypedValuesNameFieldAndOffendingValue() {
        assertThrows(
            try FrontmatterCodec.parseTask(fileText(yaml: baseYAML.replacingOccurrences(
                of: "categories:\n  - Planning", with: "categories: Planning"))),
            .wrongType(field: "categories", value: "Planning", expected: "list"))
        assertThrows(
            try FrontmatterCodec.parseTask(fileText(yaml: baseYAML.replacingOccurrences(
                of: "id: \(Self.testIDString)", with: "id: 123"))),
            .wrongType(field: "id", value: "123", expected: "string"))
        assertThrows(
            try FrontmatterCodec.parseTask(fileText(yaml: baseYAML.replacingOccurrences(
                of: "status: To Do", with: "status: 123"))),
            .wrongType(field: "status", value: "123", expected: "string"))
        assertThrows(
            try FrontmatterCodec.parseTask(fileText(yaml: baseYAML + "\nnotes:\n  - not notes\n")),
            .wrongType(field: "notes", value: "[1 items]", expected: "string"))
        assertThrows(
            try FrontmatterCodec.parseTask(fileText(yaml: baseYAML + "\nsubtasks: not-a-list\n")),
            .wrongType(field: "subtasks", value: "not-a-list", expected: "list"))
        assertThrows(
            try FrontmatterCodec.parseTask(fileText(yaml: baseYAML + "\nsubtasks:\n  - just text\n")),
            .wrongType(field: "subtasks", value: "just text", expected: "mapping"))
        assertThrows(
            try FrontmatterCodec.parseTask(fileText(yaml: baseYAML.replacingOccurrences(
                of: "  - Planning", with: "  - 1"))),
            .wrongType(field: "categories", value: "1", expected: "string"))
    }

    func testInvalidDeadlineValuesNameFieldAndValue() {
        for bad in ["15/10/2026", "2026-02-30", "2026-1-5", "2026-10-15T00:00:00Z"] {
            assertThrows(
                try FrontmatterCodec.parseTask(fileText(yaml: baseYAML + "\ndeadline: \(bad)\n")),
                .invalidDate(field: "deadline", value: bad), bad)
        }
        assertThrows(
            try FrontmatterCodec.parseTask(fileText(yaml: baseYAML + "\ndeadline: [2026-10-15]\n")),
            .wrongType(field: "deadline", value: "[1 items]", expected: "yyyy-MM-dd date string"))
    }

    func testEmptyCategoriesSurfacesModelValidationErrorWithoutTouchingFile() throws {
        let text = fileText(yaml: baseYAML.replacingOccurrences(
            of: "categories:\n  - Planning", with: "categories: []"), body: "\nKeep me.\n")
        XCTAssertThrowsError(try FrontmatterCodec.parseTask(text)) { error in
            XCTAssertEqual(
                error as? TaskItem.ValidationError, .atLeastOneCategoryRequired,
                "expected the model's zero-categories error, got \(error)")
        }
        XCTAssertEqual(text, fileText(yaml: baseYAML.replacingOccurrences(
            of: "categories:\n  - Planning", with: "categories: []"), body: "\nKeep me.\n"))
        XCTAssertEqual(try FrontmatterCodec.split(text).body, "\nKeep me.\n")
    }
}
