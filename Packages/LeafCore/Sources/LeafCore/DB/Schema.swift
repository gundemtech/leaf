import Foundation

/// Namespace для имён таблиц и колонок. Имена публичны (уже в architecture.md).
/// SQL тела — не здесь, живут в LeafCorePrivate (moat).
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

    /// Phase 2.3 — byte-offset persistence для tail-read collector'ов.
    /// PK — composite (collector_id, source_id). UPSERT через `INSERT ... ON CONFLICT`.
    public enum CollectorOffsets {
        public static let tableName = "collector_offsets"
        public static let collectorID = "collector_id"
        public static let sourceID = "source_id"
        public static let byteOffset = "byte_offset"
        public static let inode = "inode"
        public static let size = "size"
        public static let lastModifiedMs = "last_modified_ms"
        public static let updatedMs = "updated_ms"
    }
}

/// Канонические `collector_id` значения. Литералы — public, чтобы тесты
/// и Agent могли передавать одни и те же ID (single source of truth).
public enum CollectorID {
    /// Phase 2.3 — Claude Code session jsonl tail-reader.
    public static let claudeCodeJSONL = "claude_code_jsonl"
}
