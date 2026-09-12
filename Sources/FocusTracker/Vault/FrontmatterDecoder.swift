import Foundation
import Yams

extension FrontmatterCodec {
    /// Parses a full task file (frontmatter + body) into a `TaskItem`.
    /// The body is ignored here — it is opaque (see `split(_:)`).
    public static func parseTask(_ fileText: String) throws -> TaskItem {
        let (frontmatter, _) = try split(fileText)
        return try decodeTask(frontmatter: frontmatter)
    }

    /// Decodes raw frontmatter YAML into a `TaskItem`.
    ///
    /// Decoding is lenient about things that cannot lose data (any key order, quoted
    /// scalars, explicit `!!str` tags, CRLF newlines) and strict about everything
    /// that could (unknown keys, wrong types, missing required fields) — PRD §18:
    /// no silent data loss. `categories: []` surfaces the model's
    /// `TaskItem.ValidationError.atLeastOneCategoryRequired` unchanged; the codec
    /// never injects placeholder data.
    public static func decodeTask(frontmatter: String) throws -> TaskItem {
        let node: Node?
        do {
            node = try Yams.compose(yaml: frontmatter)
        } catch {
            throw FrontmatterError.invalidYAML(String(describing: error))
        }
        guard let node else {
            // Empty frontmatter: required fields are missing, starting with `id`.
            throw FrontmatterError.missingField("id")
        }
        guard case .mapping(let mapping) = node else {
            throw FrontmatterError.wrongType(
                field: "frontmatter", value: summary(of: node), expected: "mapping")
        }
        return try task(from: mapping)
    }

    // MARK: - Schema

    private static let taskKeys: Set<String> = [
        "id", "title", "status", "categories", "project",
        "priority", "effort", "deadline", "notes", "subtasks",
    ]

    private static let subtaskKeys: Set<String> = [
        "id", "title", "status", "priority", "effort", "deadline", "notes", "subtasks",
    ]

    // MARK: - Task & subtask mappings

    private static func task(from mapping: Node.Mapping) throws -> TaskItem {
        try checkUnknownKeys(in: mapping, allowed: taskKeys)
        let id = try requiredID(in: mapping)
        let title = try requiredString("title", in: mapping)
        let status = try requiredStatus(in: mapping)
        let categories = try categories(in: mapping)
        let project = try optionalString("project", in: mapping).map(Project.init(name:))
        let priority = try optionalEnum(Priority.self, field: "priority", in: mapping)
        let effort = try optionalEnum(Effort.self, field: "effort", in: mapping)
        let deadline = try optionalDeadline(in: mapping)
        let notes = try optionalString("notes", in: mapping)
        let subtasks = try subtasks(in: mapping)
        return try TaskItem(
            id: id, title: title, categories: categories, status: status,
            project: project, priority: priority, effort: effort,
            deadline: deadline, notes: notes, subtasks: subtasks)
    }

    private static func subtasks(in mapping: Node.Mapping) throws -> [SubtaskItem] {
        guard let node = value("subtasks", in: mapping) else { return [] }
        guard case .sequence(let sequence) = node else {
            throw FrontmatterError.wrongType(
                field: "subtasks", value: summary(of: node), expected: "list")
        }
        return try sequence.map { try subtask(from: $0) }
    }

    private static func subtask(from node: Node) throws -> SubtaskItem {
        guard case .mapping(let mapping) = node else {
            throw FrontmatterError.wrongType(
                field: "subtasks", value: summary(of: node), expected: "mapping")
        }
        try checkUnknownKeys(in: mapping, allowed: subtaskKeys)
        let id = try requiredID(in: mapping)
        let title = try requiredString("title", in: mapping)
        let status = try requiredStatus(in: mapping)
        let priority = try optionalEnum(Priority.self, field: "priority", in: mapping)
        let effort = try optionalEnum(Effort.self, field: "effort", in: mapping)
        let deadline = try optionalDeadline(in: mapping)
        let notes = try optionalString("notes", in: mapping)
        let children = try subtasks(in: mapping)
        return SubtaskItem(
            id: id, title: title, status: status, priority: priority,
            effort: effort, deadline: deadline, notes: notes, children: children)
    }

    // MARK: - Field readers

    private static func checkUnknownKeys(in mapping: Node.Mapping, allowed: Set<String>) throws {
        var unknown: [String] = []
        for (key, _) in mapping {
            switch key {
            case .scalar(let scalar): unknown.append(scalar.string)
            default: unknown.append(summary(of: key))
            }
        }
        let unexpected = unknown.filter { !allowed.contains($0) }.sorted()
        if !unexpected.isEmpty {
            throw FrontmatterError.unknownKeys(unexpected)
        }
    }

    /// The mapping's value for `field`, treating an explicit null (`key:`, `key: null`,
    /// `key: ~`) as absent. Quoted empty strings (`key: ''`) are *not* null — they are
    /// real string values.
    private static func value(_ field: String, in mapping: Node.Mapping) -> Node? {
        guard let node = mapping[Node(field)] else { return nil }
        if case .scalar(let scalar) = node,
            node.tag.rawValue == Tag.Name.null.rawValue, scalar.style == .plain {
            return nil
        }
        return node
    }

    /// Extracts the string content of a scalar that is unambiguously a string:
    /// a `str`-tagged scalar, a `timestamp`-tagged scalar when `allowingTimestampTag`
    /// (Yams resolves bare `yyyy-MM-dd` values to the timestamp tag), or any quoted
    /// scalar (quoting is explicit string intent). Non-string plain scalars
    /// (`123`, `true`, `null`) return nil so callers can raise typed errors.
    private static func stringScalar(
        _ node: Node, allowingTimestampTag: Bool = false
    ) -> String? {
        guard case .scalar(let scalar) = node else { return nil }
        let tagName = node.tag.rawValue
        if tagName == Tag.Name.str.rawValue { return scalar.string }
        if allowingTimestampTag && tagName == Tag.Name.timestamp.rawValue { return scalar.string }
        if scalar.style != .plain { return scalar.string }
        return nil
    }

    private static func requiredID(in mapping: Node.Mapping) throws -> UUID {
        guard let node = value("id", in: mapping) else {
            throw FrontmatterError.missingField("id")
        }
        guard let raw = stringScalar(node) else {
            throw FrontmatterError.wrongType(
                field: "id", value: summary(of: node), expected: "string")
        }
        guard let uuid = UUID(uuidString: raw) else {
            throw FrontmatterError.invalidUUID(field: "id", value: raw)
        }
        return uuid
    }

    private static func requiredString(_ field: String, in mapping: Node.Mapping) throws -> String {
        guard let node = value(field, in: mapping) else {
            throw FrontmatterError.missingField(field)
        }
        guard let raw = stringScalar(node) else {
            throw FrontmatterError.wrongType(
                field: field, value: summary(of: node), expected: "string")
        }
        return raw
    }

    private static func optionalString(_ field: String, in mapping: Node.Mapping) throws -> String? {
        guard let node = value(field, in: mapping) else { return nil }
        guard let raw = stringScalar(node) else {
            throw FrontmatterError.wrongType(
                field: field, value: summary(of: node), expected: "string")
        }
        return raw
    }

    private static func requiredStatus(in mapping: Node.Mapping) throws -> TaskStatus {
        guard let node = value("status", in: mapping) else {
            throw FrontmatterError.missingField("status")
        }
        guard let raw = stringScalar(node) else {
            throw FrontmatterError.wrongType(
                field: "status", value: summary(of: node), expected: "string")
        }
        guard let status = TaskStatus(rawValue: raw) else {
            throw FrontmatterError.invalidEnumValue(field: "status", value: raw)
        }
        return status
    }

    private static func optionalEnum<E: RawRepresentable & CaseIterable>(
        _ type: E.Type, field: String, in mapping: Node.Mapping
    ) throws -> E? where E.RawValue == String {
        guard let node = value(field, in: mapping) else { return nil }
        guard let raw = stringScalar(node) else {
            throw FrontmatterError.wrongType(
                field: field, value: summary(of: node), expected: "string")
        }
        guard let parsed = E(rawValue: raw) else {
            throw FrontmatterError.invalidEnumValue(field: field, value: raw)
        }
        return parsed
    }

    private static func categories(in mapping: Node.Mapping) throws -> [Category] {
        guard let node = value("categories", in: mapping) else {
            throw FrontmatterError.missingField("categories")
        }
        guard case .sequence(let sequence) = node else {
            throw FrontmatterError.wrongType(
                field: "categories", value: summary(of: node), expected: "list")
        }
        return try sequence.map { element in
            guard let raw = stringScalar(element) else {
                throw FrontmatterError.wrongType(
                    field: "categories", value: summary(of: element), expected: "string")
            }
            return Category(name: raw)
        }
    }

    private static func optionalDeadline(in mapping: Node.Mapping) throws -> Date? {
        guard let node = value("deadline", in: mapping) else { return nil }
        guard let raw = stringScalar(node, allowingTimestampTag: true) else {
            throw FrontmatterError.wrongType(
                field: "deadline", value: summary(of: node), expected: "yyyy-MM-dd date string")
        }
        guard let date = DeadlineDay.date(from: raw) else {
            throw FrontmatterError.invalidDate(field: "deadline", value: raw)
        }
        return date
    }

    /// Deterministic single-line description of a node for error payloads:
    /// scalars use their raw string, sequences `[n items]`, mappings `{mapping}`.
    private static func summary(of node: Node) -> String {
        switch node {
        case .scalar(let scalar): return scalar.string
        case .sequence(let sequence): return "[\(sequence.count) items]"
        case .mapping: return "{mapping}"
        case .alias: return "*alias"
        }
    }
}
