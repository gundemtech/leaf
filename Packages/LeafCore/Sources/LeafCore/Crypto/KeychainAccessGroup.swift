import Foundation

/// Резолвит текущий keychain access group для подписанного бинаря.
///
/// Читает `AppIdentifierPrefix` из `Bundle.main.infoDictionary` — это значение
/// Xcode/codesign подставляют автоматически из entitlements. Формат:
/// `"<TeamID>."` — поэтому склеиваем с суффиксом `"tech.gundem.leaf"`.
///
/// Для unsigned/CI сборок (`AppIdentifierPrefix` отсутствует) возвращает
/// пустую строку. `KeychainKeyStore.fetchOrCreate(accessGroup:)` в этом
/// случае работает против default keychain (unit-tests pattern, не shared).
public enum KeychainAccessGroup {
    public static let leafSuffix = "tech.gundem.leaf"

    /// Текущее значение для текущего бинаря. Пустая строка = unsigned (fallback).
    public static func current() -> String {
        guard let prefix = Bundle.main.infoDictionary?["AppIdentifierPrefix"] as? String,
              !prefix.isEmpty else {
            return ""
        }
        // `AppIdentifierPrefix` включает trailing dot → prefix + suffix без
        // дополнительной точки.
        return prefix + leafSuffix
    }
}
