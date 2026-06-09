import Foundation

/// The decoded list of release notes, newest-first. Loaded from the `releases.json`
/// that `PBXFileSystemSynchronizedRootGroup` auto-bundles into the app from
/// `Leaf/Resources/`. Decoding is GRACEFUL — a missing or malformed file yields an
/// empty catalog rather than crashing, because the bundle is a generated artifact
/// that could be absent (dev build) or lag (out-of-order regeneration).
public struct ReleaseNotesCatalog: Sendable, Equatable {
    public let releases: [ReleaseNote]

    public init(releases: [ReleaseNote]) {
        self.releases = releases
    }

    /// The newest release (releases.json is emitted newest-first).
    public var latest: ReleaseNote? { releases.first }

    /// Find a specific version (e.g. the running build's `CFBundleShortVersionString`).
    public func release(version: String) -> ReleaseNote? {
        releases.first { $0.version == version }
    }

    /// Decode from raw JSON. The top-level `schemaVersion` is optional (forward-compat);
    /// any decode failure yields an empty catalog.
    public static func decode(from data: Data) -> ReleaseNotesCatalog {
        struct Wrapper: Decodable {
            let schemaVersion: Int?
            let releases: [ReleaseNote]
        }
        guard let wrapper = try? JSONDecoder().decode(Wrapper.self, from: data) else {
            return ReleaseNotesCatalog(releases: [])
        }
        return ReleaseNotesCatalog(releases: wrapper.releases)
    }

    /// Load the bundled `releases.json`. Missing resource or unreadable data → empty.
    public static func bundled(in bundle: Bundle = .main) -> ReleaseNotesCatalog {
        guard let url = bundle.url(forResource: "releases", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else {
            return ReleaseNotesCatalog(releases: [])
        }
        return decode(from: data)
    }
}
