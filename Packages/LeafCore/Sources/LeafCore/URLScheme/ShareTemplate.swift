import Foundation

/// Phase 5.5.B — pre-filled message templates для share-flow (RU; EN polish при review).
/// Pure value-type helper. Каналы (Mail / Messages / Copy) — `mailtoURL` / `smsURL` / NSPasteboard
/// в Leaf app target; здесь только compose + percent-encoded URL builders.
public enum ShareTemplate {

    /// Discriminator + interpolatable params per template variant (decomposition §4.5).
    public enum Kind: Sendable {
        /// Admin → invitee "ask to join" (admin-first path).
        case askToJoin(orgName: String)
        /// Invitee → admin "here's my Join code" (invitee-first path).
        case inviteeShare(displayName: String, joinCode: String)
        /// Admin → invitee "here's your invite link" (final exchange).
        case adminShare(displayName: String, inviteURL: URL)
    }

    /// Compose human-readable body. Plain string suitable for clipboard / Mail body / SMS body.
    public static func compose(_ kind: Kind) -> String {
        switch kind {
        case .askToJoin(let orgName):
            return """
                Привет! Я добавляю тебя в Leaf team "\(orgName)".

                Чтобы присоединиться:
                1. Скачай Leaf — https://leaf-docs.gundem.tech/install
                2. Запусти, выбери "Join existing team"
                3. Скопируй мне Join code который покажет приложение

                Я пришлю invite link сразу как получу.
                """
        case .inviteeShare(let displayName, let joinCode):
            return """
                Привет! Я \(displayName), готов(а) присоединиться к Leaf team. Мой Join code:

                \(joinCode)

                Жду от тебя invite link 🌿
                """
        case .adminShare(let displayName, let inviteURL):
            // Admin-side не всегда знает invitee display name (paste-Join-code flow без preceding
            // inviteeShare exchange). Empty/whitespace → neutral greeting; иначе — personalized.
            let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let greeting = trimmed.isEmpty ? "Привет!" : "Привет, \(trimmed)!"
            return """
                \(greeting) Вот твой Leaf invite link (действует 24 часа):

                \(inviteURL.absoluteString)

                Кликни — Leaf откроется и подхватит автоматически.
                """
        }
    }

    /// Build `mailto:?subject=…&body=…` URL with proper percent-encoding (handles unicode + newlines).
    public static func mailtoURL(subject: String, body: String) -> URL {
        var components = URLComponents()
        components.scheme = "mailto"
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        // URLComponents already percent-encodes query values. Force unwrap safe — scheme + queryItems
        // produce a valid mailto: URL deterministically.
        return components.url!
    }

    /// Build `sms:?&body=…` URL. iOS / macOS Messages (Continuity) opens for any sms: URL.
    public static func smsURL(body: String) -> URL {
        var components = URLComponents()
        components.scheme = "sms"
        components.queryItems = [URLQueryItem(name: "body", value: body)]
        return components.url!
    }
}
