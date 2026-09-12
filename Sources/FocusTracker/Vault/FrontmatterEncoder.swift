import Foundation
import Yams

extension FrontmatterCodec {
    /// Serializes a `TaskItem` plus its opaque Markdown body into the canonical file
    /// format (identical layout to `fixtures/sample-vault/Tasks/`):
    ///
    ///     ---
    ///     id: 3f2a9c1e-…          ← lowercase UUID, always first
    ///     title: Plan Q4 roadmap
    ///     status: In Progress
    ///     categories:             ← always present, one `- name` per item
    ///       - Planning
    ///     project: Work           ← optional; omitted when nil
    ///     priority: High          ← optional; omitted when nil
    ///     effort: L               ← optional; omitted when nil
    ///     deadline: 2026-10-15    ← optional; omitted when nil (yyyy-MM-dd, UTC)
    ///     notes: …                ← optional; omitted when nil
    ///     order: 3                ← optional; omitted when nil (tasks only,
    ///                               never `order: null` — issue #10)
    ///     subtasks:               ← omitted when empty; recursive, same shape
    ///       - id: …                 (id, title, status, priority, effort,
    ///         title: …               deadline, notes, subtasks; no project/categories/order)
    ///     ---
    ///     <body, byte-for-byte>
    ///
    /// Canonical-form rules (chosen for byte-stability: serialize → parse → serialize
    /// is the identity):
    /// - **Key order** is fixed as above; subtask entries use the same order
    ///   minus `project`/`categories`/`order` (`SubtaskItem.children` persists
    ///   under `subtasks`).
    /// - **Quoting** is delegated to Yams' emitter (plain when safe, quoted otherwise,
    ///   Unicode kept literal). Strings that YAML would resolve as a non-string scalar
    ///   (`true`, `123`, `2026-10-15`, …), strings containing newlines or control
    ///   characters, and the empty string (`''`) are force-quoted, so every string
    ///   re-parses as a string.
    /// - **Nil handling**: optional fields and empty `subtasks` lists are omitted;
    ///   nothing is ever written as `null`.
    /// - **Body**: appended untouched after the closing `---`. The fixture-style blank
    ///   line between the delimiter and the body is the body's own leading `\n`;
    ///   nothing after the closing delimiter is parsed, reformatted, or dropped.
    /// - **Deadline**: written via `DeadlineDay`'s fixed UTC-noon mapping, so the
    ///   `yyyy-MM-dd` text can never shift with the process time zone.
    public static func encode(task: TaskItem, body: String) -> String {
        var lines: [String] = []
        lines.append("id: \(scalar(task.id.uuidString.lowercased()))")
        lines.append("title: \(scalar(task.title))")
        lines.append("status: \(scalar(task.status.rawValue))")
        lines.append("categories:")
        lines.append(contentsOf: task.categories.map { "  - \(scalar($0.name))" })
        if let project = task.project {
            lines.append("project: \(scalar(project.name))")
        }
        if let priority = task.priority {
            lines.append("priority: \(scalar(priority.rawValue))")
        }
        if let effort = task.effort {
            lines.append("effort: \(scalar(effort.rawValue))")
        }
        if let deadline = task.deadline {
            lines.append("deadline: \(DeadlineDay.string(from: deadline))")
        }
        if let notes = task.notes {
            lines.append("notes: \(scalar(notes))")
        }
        // `order` (issue #10) is written only when non-nil — never as a null
        // key — in the pinned slot between `notes` and `subtasks`, grouped with
        // the trailing optionals. A plain decimal int (incl. `0` and negatives)
        // always re-parses as an int, so no quoting is needed. Subtasks never
        // carry `order`.
        if let order = task.order {
            lines.append("order: \(order)")
        }
        lines.append(contentsOf: subtaskLines(task.subtasks, atIndent: ""))
        return "---\n" + lines.joined(separator: "\n") + "\n---\n" + body
    }

    /// Recursive subtask block: items are `- key: value` at the current indent,
    /// continuation fields two spaces deeper (matching the fixture layout).
    private static func subtaskLines(_ subtasks: [SubtaskItem], atIndent indent: String) -> [String] {
        guard !subtasks.isEmpty else { return [] }
        var lines: [String] = ["\(indent)subtasks:"]
        let fieldIndent = indent + "  "
        for subtask in subtasks {
            let itemIndent = fieldIndent
            let textIndent = fieldIndent + "  "
            lines.append("\(itemIndent)- id: \(scalar(subtask.id.uuidString.lowercased()))")
            lines.append("\(textIndent)title: \(scalar(subtask.title))")
            lines.append("\(textIndent)status: \(scalar(subtask.status.rawValue))")
            if let priority = subtask.priority {
                lines.append("\(textIndent)priority: \(scalar(priority.rawValue))")
            }
            if let effort = subtask.effort {
                lines.append("\(textIndent)effort: \(scalar(effort.rawValue))")
            }
            if let deadline = subtask.deadline {
                lines.append("\(textIndent)deadline: \(DeadlineDay.string(from: deadline))")
            }
            if let notes = subtask.notes {
                lines.append("\(textIndent)notes: \(scalar(notes))")
            }
            lines.append(contentsOf: subtaskLines(subtask.children, atIndent: textIndent))
        }
        return lines
    }

    /// Emits one scalar in canonical form (see the `encode(task:body:)` doc comment).
    /// Yams' emitter is deterministic; a scalar-only serialization cannot fail in
    /// practice, but the fallback keeps this function total without any trapping.
    private static func scalar(_ string: String) -> String {
        let style: Node.Scalar.Style
        if string.isEmpty {
            style = .singleQuoted // a bare empty plain scalar would re-parse as null
        } else if containsBreaksOrControls(string) || resolvesToNonStringTag(string) {
            style = .doubleQuoted
        } else {
            style = .any // let the emitter pick plain / quoted
        }
        do {
            let yaml = try Yams.serialize(
                node: Node(string, .implicit, style), width: -1, allowUnicode: true)
            return yaml.hasSuffix("\n") ? String(yaml.dropLast()) : yaml
        } catch {
            return doubleQuotedFallback(string)
        }
    }

    private static func containsBreaksOrControls(_ string: String) -> Bool {
        string.contains("\n")
            || string.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    /// True when Yams' resolver (the same one used on read) would tag the bare scalar
    /// as something other than a string (bool, int, float, null, timestamp, merge,
    /// value, …). Such strings are double-quoted so they re-parse as strings.
    private static func resolvesToNonStringTag(_ string: String) -> Bool {
        Node(string, .implicit).tag.rawValue != Tag.Name.str.rawValue
    }

    private static func doubleQuotedFallback(_ string: String) -> String {
        var escaped = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default:
                if scalar.value < 0x20 {
                    escaped += String(format: "\\x%02x", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return escaped + "\""
    }
}
