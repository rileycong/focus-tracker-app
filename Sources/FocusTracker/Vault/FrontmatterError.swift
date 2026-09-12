import Foundation

/// Errors surfaced when reading a vault task file's YAML frontmatter (issue #4, PRD §18).
///
/// Together with `TaskItem.ValidationError.atLeastOneCategoryRequired` (surfaced directly
/// from the model's throwing initializer when `categories` is empty), this is the complete
/// documented set of codec errors; both are `Equatable` so tests can assert exact cases.
public enum FrontmatterError: Error, Equatable, Sendable {
    /// The file does not start with a `---` delimiter line.
    case missingOpeningDelimiter
    /// No second `---` delimiter line terminates the frontmatter.
    case missingClosingDelimiter
    /// The YAML block between the delimiters is not syntactically valid YAML.
    case invalidYAML(String)
    /// Frontmatter keys outside the known schema. Write-lossy keys must fail loudly,
    /// never be silently dropped (PRD §18). Names are sorted for determinism.
    case unknownKeys([String])
    /// A required field is absent (or an explicit null): the task requires
    /// `id`, `title`, `status`, `categories`; every subtask requires `id`, `title`, `status`.
    case missingField(String)
    /// A value has the wrong YAML type. `value` is the offending scalar/summary,
    /// `expected` names the required shape.
    case wrongType(field: String, value: String, expected: String)
    /// A string value that is not a valid UUID. Field is `id`.
    case invalidUUID(field: String, value: String)
    /// A string value outside a `TaskStatus`/`Priority`/`Effort` raw value set.
    case invalidEnumValue(field: String, value: String)
    /// A value that is not exactly a `yyyy-MM-dd` calendar date (en_US_POSIX).
    case invalidDate(field: String, value: String)
}
