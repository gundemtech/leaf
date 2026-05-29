// Packages/LeafCore/Sources/LeafCore/OS/BrowserDomainAllowList.swift
import Foundation

/// Phase Track-6 P3 — darwin notification name posted by `BrowserAllowListStore`
/// (MenuBarApp process) after every add/remove mutation. The Agent process observes
/// this and calls `DBDomainAllowListReader.invalidate()` to flush its stale cache.
/// Pattern mirrors `FSEventsCollector.darwinNotificationName` / `WatchedFoldersService`.
public let browserDomainAllowChangedNotification = "tech.gundem.leaf.browser-domain-allow.changed"

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
        let host = comps.host?.lowercased()
    else { return "" }
    return host
}

/// Phase 5 defence-in-depth — drop the URL fragment (and only the fragment) from a
/// URL string. Fragments are client-side anchors that frequently carry OAuth
/// implicit-flow tokens, JWTs, and magic-link secrets; they are never needed for an
/// activity signal and must never be stored (audit HIGH H1). URLComponents path when
/// parseable; string-split fallback (`#…`) so a fragment is stripped even from inputs
/// URLComponents cannot parse. This is the single source of truth for "never store a
/// fragment" — `sanitizeURL` mirrors `comps.fragment = nil` on its already-parsed
/// components.
func stripURLFragment(_ urlString: String) -> String {
    if var comps = URLComponents(string: urlString) {
        comps.fragment = nil
        if let rebuilt = comps.string { return rebuilt }
    }
    if let hashIndex = urlString.firstIndex(of: "#") {
        return String(urlString[..<hashIndex])
    }
    return urlString
}

/// Apply the granularity rule to a URL string. Spec §9.3.
public func applyGranularity(_ urlString: String, _ granularity: URLGranularity) -> String {
    switch granularity {
    case .fullUrl:
        // Keep path + query (the user opted this domain into full-URL granularity)
        // but always drop the fragment — see `stripURLFragment`.
        return stripURLFragment(urlString)
    case .pathStripped:
        guard let comps = URLComponents(string: urlString),
            let host = comps.host?.lowercased()
        else { return "" }
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
