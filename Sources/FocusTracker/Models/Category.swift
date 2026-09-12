/// A user-created organizational label (PRD §6.3).
///
/// Lightweight: just a name. Serializes as a plain string so vault files
/// (`categories: [Planning, Work]`) round-trip losslessly.
public struct Category: Hashable, Sendable, Codable {
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
