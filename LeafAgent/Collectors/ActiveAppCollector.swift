import Foundation
import AppKit
import os
import LeafCore

/// Слушает `NSWorkspace.didActivateApplicationNotification` — каждый раз когда
/// юзер переключает active app → пишем attention event.
///
/// Notification callback диспатчится на `.main` queue (mandatory — NSWorkspace не thread-safe),
/// так что внутренняя логика однопоточна на main. `@unchecked Sendable` — потому что
/// `NSObjectProtocol` observer не Sendable, но обращаемся к нему только из start/stop
/// которые вызываются из main.
final class ActiveAppCollector: @unchecked Sendable {
    private let writer: EventWriter
    private let blocklist: Set<String>
    private var observer: NSObjectProtocol?

    init(writer: EventWriter, blocklist: Set<String>) {
        self.writer = writer
        self.blocklist = blocklist
    }

    func start() {
        let writer = self.writer
        let blocklist = self.blocklist

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            guard let bundleID = app.bundleIdentifier else {
                collectorLogger.debug("Activation without bundle ID — dropped")
                return
            }
            guard !blocklist.contains(bundleID) else {
                return
            }

            let event = RawEvent(
                signalType: .attention,
                bundleID: bundleID,
                payload: [:]
            )
            Task { await writer.enqueue(event) }
        }
        collectorLogger.info("ActiveAppCollector started")
    }

    func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
        collectorLogger.info("ActiveAppCollector stopped")
    }
}
