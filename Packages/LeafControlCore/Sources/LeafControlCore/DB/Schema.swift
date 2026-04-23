import Foundation

/// Namespace для имён таблиц и колонок. Имена публичны (уже в architecture.md).
/// SQL тела — не здесь, живут в LeafControlCorePrivate (moat).
public enum Schema {
    public enum Events {
        public static let tableName = "events"
        public static let id = "id"
        public static let ts = "ts"
        public static let signalType = "signal_type"
        public static let bundleID = "bundle_id"
        public static let payloadJSON = "payload_json"

        public static let indexTs = "events_ts"
        public static let indexBundleTs = "events_bundle_ts"
    }
}
