/// A simple container grouping tasks (PRD §6.4).
///
/// Deliberately lightweight — no description/goal/status/workflow fields.
/// Serializes as a plain string so vault files (`project: Work`) round-trip losslessly.
public struct Project: Hashable, Sendable, Codable {
    public let name: String

    public init(name: String) {
        self.name = name
    }

    public init(from decoder: Decoder) throws {
        name = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(name)
    }
}
