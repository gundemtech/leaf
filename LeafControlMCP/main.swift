import Foundation
import LeafControlCore

// Phase 0 stub — бинарь только чтобы embed в app bundle и зарегистрировать
// в `claude mcp add`. Реальный JSON-RPC loop + tools/list + tools/call — Phase 1.

let logger = "leafcontrol-mcp"
let granularityList = Granularity.allCases.map { "L\($0.rawValue)" }.joined(separator: ", ")

FileHandle.standardError.write(Data("\(logger): v0 — phase 0 stub, exiting\n".utf8))
FileHandle.standardError.write(Data("\(logger): granularity levels available: \(granularityList)\n".utf8))

exit(0)
