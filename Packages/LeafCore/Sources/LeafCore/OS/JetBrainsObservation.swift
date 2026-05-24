import Foundation

/// Phase Track-4 S2 — JetBrains family (IntelliJ / PyCharm / WebStorm / GoLand
/// / CLion / Rider / RubyMine / PhpStorm / Android Studio / DataGrip / RustRover
/// / DataSpell) boundary value type. Carries IDE bundle ID + project name +
/// active doc path only. Never `text of document` or `content`.
/// AppCode dropped Track-6 P6 (EOL Dec 2023).
public struct JetBrainsObservation: AdapterObservation, Hashable {
    public let ideBundleID: String
    public let projectName: String?
    public let activeDocPath: String?

    public init(ideBundleID: String, projectName: String?, activeDocPath: String?) {
        self.ideBundleID = ideBundleID
        self.projectName = projectName
        self.activeDocPath = activeDocPath
    }
}
