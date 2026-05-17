import Foundation

public enum URLDomainExtractor {
    /// Returns the lowercased ASCII host component of `urlString`, or nil
    /// when the input has no parseable host (file://, opaque schemes,
    /// malformed, empty). IPs are returned verbatim. Ports are stripped
    /// (URLComponents.host already excludes the port).
    public static func domain(of urlString: String) -> String? {
        guard let host = URLComponents(string: urlString)?.host, !host.isEmpty else {
            return nil
        }
        return host.lowercased()
    }
}
