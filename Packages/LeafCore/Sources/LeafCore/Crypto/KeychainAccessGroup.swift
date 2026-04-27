import Foundation

/// Резолвит keychain access group для текущего бинаря.
///
/// Сейчас всегда возвращает пустую строку — используем default access group
/// (per-bundle-ID). `keychain-access-groups` entitlement требует Developer ID
/// Provisioning Profile (которого у нас нет на distribution-этапе alpha.1+);
/// без profile AMFI убивает app на launch с "Unsatisfied entitlements".
///
/// Trade-off: app/agent/mcp не разделяют один key — каждый бинарь хранит свой
/// в отдельном default group. Phase 3.4.5 / Phase 4 восстановит sharing через
/// (a) Developer ID Provisioning Profile, либо (b) file-based key вместо
/// Keychain, либо (c) XPC proxy через main app.
///
/// `KeychainKeyStore.fetchOrCreate(accessGroup:)` обрабатывает empty string
/// как "не передавать `kSecAttrAccessGroup`" → default group.
public enum KeychainAccessGroup {
    public static let leafSuffix = "tech.gundem.leaf"

    /// Текущее значение для текущего бинаря. Всегда "" до Phase 3.4.5.
    public static func current() -> String {
        return ""
    }
}
