import Foundation

/// One release entry, mirroring a record in the bundled `releases.json` (the file
/// `scripts/gen-release-notes.sh` generates from `CHANGELOG.md`). Decoding is
/// tolerant: unknown future keys are ignored (Codable skips undeclared keys), and
/// `yanked` defaults to `false` when absent — so an older app reading a newer
/// releases.json schema still decodes cleanly.
public struct ReleaseNote: Codable, Equatable, Sendable, Identifiable {
    public let version: String
    public let date: String
    public let added: [String]
    public let fixed: [String]
    public let changed: [String]
    public let dmgURL: String
    public let zipURL: String
    public let yanked: Bool

    public var id: String { version }

    /// True when the release carries no user-visible notes (all three buckets empty)
    /// — the What's New UI can skip rendering an empty section list.
    public var hasNotes: Bool { !added.isEmpty || !fixed.isEmpty || !changed.isEmpty }

    private enum CodingKeys: String, CodingKey {
        case version, date, added, fixed, changed, dmgURL, zipURL, yanked
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        date = try c.decode(String.self, forKey: .date)
        added = try c.decodeIfPresent([String].self, forKey: .added) ?? []
        fixed = try c.decodeIfPresent([String].self, forKey: .fixed) ?? []
        changed = try c.decodeIfPresent([String].self, forKey: .changed) ?? []
        dmgURL = try c.decodeIfPresent(String.self, forKey: .dmgURL) ?? ""
        zipURL = try c.decodeIfPresent(String.self, forKey: .zipURL) ?? ""
        yanked = try c.decodeIfPresent(Bool.self, forKey: .yanked) ?? false
    }

    public init(
        version: String, date: String, added: [String] = [], fixed: [String] = [],
        changed: [String] = [], dmgURL: String = "", zipURL: String = "", yanked: Bool = false
    ) {
        self.version = version; self.date = date
        self.added = added; self.fixed = fixed; self.changed = changed
        self.dmgURL = dmgURL; self.zipURL = zipURL; self.yanked = yanked
    }
}
