import Foundation

/// Phase Track-6 P2 — start/stop interface for the FSEvents watcher on
/// `~/Library/Developer/Xcode/DerivedData/`. Production impl in LeafCorePrivate
/// (`ProdDerivedDataWatcher`). Spec §4.4.
public protocol DerivedDataWatcher: Sendable {
    func start() async
    func stop() async
}
