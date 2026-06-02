import Foundation
import GRDB

/// Internal GRDB record for the events table. Doesn't leak into the public API —
/// conversion to/from `RawEvent` happens inside `Database`.
internal struct EventRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = Schema.Events.tableName

    var id: Int64?
    var ts: Int64
    var signalType: String
    var bundleID: String?
    var payloadJSON: String

    enum CodingKeys: String, CodingKey {
        case id
        case ts
        case signalType = "signal_type"
        case bundleID = "bundle_id"
        case payloadJSON = "payload_json"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
