// Packages/LeafCore/Sources/LeafCore/OS/BrowserDomainAllowList.swift
import Foundation

/// Phase Track-6 P3 — per-domain URL granularity. See spec §4 + §9.
public enum URLGranularity: String, Sendable, Hashable {
    case fullUrl = "full_url"
    case pathStripped = "path_stripped"
    case domainOnly = "domain_only"
}

/// Filter facade — adapter wrapper calls this for each tab snapshot's URL
/// before passing snapshots into the state machines.
public protocol DomainAllowListReader: Sendable {
    func granularity(for domain: String) -> URLGranularity
}

private let _allowedSchemes: Set<String> = ["http", "https"]

/// Extract host-only domain (lowercased) from a URL string. Empty for
/// non-standard or invalid URLs (non-http/https schemes).
public func extractDomain(_ urlString: String) -> String {
    guard let comps = URLComponents(string: urlString),
          let scheme = comps.scheme?.lowercased(),
          _allowedSchemes.contains(scheme),
          let host = comps.host?.lowercased() else { return "" }
    return host
}

/// Apply the granularity rule to a URL string. Spec §9.3.
public func applyGranularity(_ urlString: String, _ granularity: URLGranularity) -> String {
    switch granularity {
    case .fullUrl:
        return urlString
    case .pathStripped:
        guard let comps = URLComponents(string: urlString),
              let host = comps.host?.lowercased() else { return "" }
        let path = comps.path
        return path.isEmpty ? host : host + path
    case .domainOnly:
        return extractDomain(urlString)
    }
}

/// Test double — pure value-type allow-list driver.
public struct InMemoryDomainAllowListReader: DomainAllowListReader {
    private let rules: [String: URLGranularity]
    public init(rules: [String: URLGranularity]) { self.rules = rules }
    public func granularity(for domain: String) -> URLGranularity {
        rules[domain] ?? .domainOnly
    }
}
