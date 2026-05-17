import Foundation

/// Phase Track-4 S3 — locale-aware screenshot filename matcher. Recognises
/// macOS default screenshot prefixes for 10 locales + extension whitelist.
/// **Filename only** — никогда не читает file contents (ADR-010 Won't-list).
public struct ScreenshotMatcher: Sendable {
    /// 10-locale prefix bank — single source of truth для test fixtures.
    /// Case-insensitive prefix match; user может override через
    /// `additionalPrefixes` (testing / custom screenshot tools).
    public static let defaultPrefixes: [String] = [
        "Screenshot",
        "Screen Shot",
        "Снимок экрана",
        "Bildschirm",  // German — covers Bildschirmfoto / Bildschirmaufnahme
        "Capture d'écran",
        "Captura de pantalla",
        "スクリーンショット",  // Japanese
        "스크린샷",  // Korean
        "Cattura schermata",  // Italian
        "Captura de tela",  // Portuguese (Brazil)
    ]

    public static let allowedExtensions: Set<String> = [
        "png", "heic", "jpg", "jpeg", "pdf",
    ]

    private let prefixes: [String]

    public init(additionalPrefixes: [String] = []) {
        self.prefixes = Self.defaultPrefixes + additionalPrefixes
    }

    public func matches(filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        guard Self.allowedExtensions.contains(ext) else { return false }
        let lower = filename.lowercased()
        for prefix in prefixes {
            if lower.hasPrefix(prefix.lowercased()) { return true }
        }
        return false
    }
}
