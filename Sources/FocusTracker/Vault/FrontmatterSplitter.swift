import Foundation

/// Codec for the vault's one-task-per-file Markdown format (PRD §5.3–§5.4, issue #4):
/// `---`-delimited YAML frontmatter decoded into `TaskItem` (with a recursive
/// `SubtaskItem` tree under the YAML key `subtasks`), plus an opaque Markdown body.
/// The codec operates purely on text in memory; callers own file access (PRD §18).
public enum FrontmatterCodec {}

extension FrontmatterCodec {
    /// Splits a task file into its raw frontmatter (the text between the first two
    /// `---` delimiter lines, newlines included) and its body (everything after the
    /// first closing `---`, preserved byte-for-byte — a `---` horizontal-rule line
    /// inside the body cannot terminate the frontmatter because only the *first*
    /// closing delimiter wins).
    ///
    /// A delimiter line is exactly `---` (a trailing `\r` from CRLF files is
    /// tolerated). A leading UTF-8 BOM is ignored on read. Delimiter lines are
    /// matched strictly: `----` or `--- comment` are not delimiters.
    ///
    /// - Throws: `FrontmatterError.missingOpeningDelimiter` when the first line is
    ///   not `---`, `FrontmatterError.missingClosingDelimiter` when no second
    ///   delimiter line exists.
    public static func split(_ fileText: String) throws -> (frontmatter: String, body: String) {
        let text = fileText.hasPrefix("\u{FEFF}") ? String(fileText.dropFirst()) : fileText

        var lines: [(content: Substring, endAfterNewline: String.Index)] = []
        var lineStart = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "\n" {
                let endAfterNewline = text.index(after: index)
                lines.append((text[lineStart..<index], endAfterNewline))
                lineStart = endAfterNewline
            }
            index = text.index(after: index)
        }
        if lineStart < text.endIndex {
            lines.append((text[lineStart..<text.endIndex], text.endIndex))
        }

        func isDelimiter(_ line: Substring) -> Bool {
            line == "---" || (line.hasSuffix("\r") && line.dropLast() == "---")
        }

        guard let first = lines.first, isDelimiter(first.content) else {
            throw FrontmatterError.missingOpeningDelimiter
        }
        guard let closing = lines.dropFirst().first(where: { isDelimiter($0.content) }) else {
            throw FrontmatterError.missingClosingDelimiter
        }

        let frontmatter = String(text[first.endAfterNewline..<closing.content.startIndex])
        let body = String(text[closing.endAfterNewline...])
        return (frontmatter, body)
    }
}
