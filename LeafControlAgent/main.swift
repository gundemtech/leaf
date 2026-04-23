import Foundation
import LeafControlCore

// Phase 0 stub — бинарь только чтобы embed в app bundle и подтвердить что LaunchAgent
// вообще стартует через SMAppService. Реальный collector loop — Phase 1.

let logger = "leafcontrol-agent"
let signalList = SignalType.allCases.map(\.rawValue).joined(separator: ", ")

FileHandle.standardError.write(Data("\(logger): v0 — phase 0 stub, exiting\n".utf8))
FileHandle.standardError.write(Data("\(logger): signal types available: \(signalList)\n".utf8))

exit(0)
