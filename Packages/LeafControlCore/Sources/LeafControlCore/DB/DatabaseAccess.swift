import Foundation

/// Абстракция над SQLCipher DB поверх GRDB. Конкретные типы GRDB
/// намеренно не торчат в публичном API — изолируем зависимость
/// от публичного контракта и упрощаем тестирование.
public protocol DatabaseAccess: Sendable {
    /// Writer — открывается один раз в Agent.
    static func openForWrite(at url: URL, key: Data) throws -> Self

    /// Reader — открывается в App и MCP, параллельно writer'у через WAL.
    static func openForRead(at url: URL, key: Data) throws -> Self

    /// Записать сырой event.
    func write(_ event: RawEvent) throws

    /// Прочитать events в диапазоне, опционально фильтруя по bundleID.
    func events(in range: DateInterval, bundleID: String?) throws -> [RawEvent]

    /// Принудительный WAL checkpoint (вызывается writer'ом периодически).
    func checkpointWAL() throws
}

public extension DatabaseAccess {
    /// Каноничный путь файла SQLCipher.
    static var defaultURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support
            .appendingPathComponent("LeafControl", isDirectory: true)
            .appendingPathComponent("events.sqlite", isDirectory: false)
    }
}
