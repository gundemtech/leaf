import XCTest
@testable import LeafCore

final class JetBrainsRecentProjectsWatcherTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Inline mimic of what production sets via ProdJetBrainsProductMap (moat).
        // Tests verify watcher's PUBLIC interface; integration smoke covers
        // the prod-side resolver wiring.
        JetBrainsRecentProjectsWatcher._versionDirResolver = { versionDir in
            let mapping: [String: String] = [
                "IntelliJIdea":  "com.jetbrains.intellij",
                "IdeaIC":        "com.jetbrains.intellij.ce",
                "PyCharm":       "com.jetbrains.pycharm",
                "PyCharmCE":     "com.jetbrains.pycharm.ce",
                "WebStorm":      "com.jetbrains.WebStorm",
                "GoLand":        "com.jetbrains.goland",
                "CLion":         "com.jetbrains.CLion",
                "Rider":         "com.jetbrains.rider",
                "RubyMine":      "com.jetbrains.rubymine",
                "PhpStorm":      "com.jetbrains.PhpStorm",
                "DataGrip":      "com.jetbrains.datagrip",
                "RustRover":     "com.jetbrains.rustrover",
                "DataSpell":     "com.jetbrains.dataspell"
            ]
            let pattern = #"^([A-Za-z]+)(\d{4}\.\d+)$"#
            guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
            let range = NSRange(versionDir.startIndex..., in: versionDir)
            guard let match = re.firstMatch(in: versionDir, range: range),
                  let productRange = Range(match.range(at: 1), in: versionDir) else {
                return nil
            }
            let product = String(versionDir[productRange])
            guard let bundleID = mapping[product] else { return nil }
            return .init(bundleID: bundleID, versionDir: versionDir)
        }
    }

    override func tearDown() {
        JetBrainsRecentProjectsWatcher._versionDirResolver = nil
        super.tearDown()
    }

    func test_inferIDEFromVersionDir_intelliJ() {
        let info = JetBrainsRecentProjectsWatcher.inferIDE(fromVersionDir: "IntelliJIdea2025.1")
        XCTAssertEqual(info?.bundleID, "com.jetbrains.intellij")
        XCTAssertEqual(info?.versionDir, "IntelliJIdea2025.1")
    }

    func test_inferIDEFromVersionDir_pyCharm() {
        let info = JetBrainsRecentProjectsWatcher.inferIDE(fromVersionDir: "PyCharm2025.1")
        XCTAssertEqual(info?.bundleID, "com.jetbrains.pycharm")
    }

    func test_inferIDEFromVersionDir_dataGrip() {
        let info = JetBrainsRecentProjectsWatcher.inferIDE(fromVersionDir: "DataGrip2025.2")
        XCTAssertEqual(info?.bundleID, "com.jetbrains.datagrip")
    }

    func test_inferIDEFromVersionDir_unknownProductReturnsNil() {
        XCTAssertNil(JetBrainsRecentProjectsWatcher.inferIDE(fromVersionDir: "MysteryIDE2024.3"))
    }

    func test_parseRecentProjectsXML_extractsEntriesWithActivationTimestamp() {
        let xml = """
        <application>
          <component name="RecentProjectsManager">
            <option name="additionalInfo">
              <map>
                <entry key="$USER_HOME$/Desktop/Leaf/leaf">
                  <value>
                    <RecentProjectMetaInfo activationTimestamp="1747345678901">
                      <option name="displayName" value="leaf" />
                    </RecentProjectMetaInfo>
                  </value>
                </entry>
                <entry key="$USER_HOME$/code/research">
                  <value>
                    <RecentProjectMetaInfo activationTimestamp="1747000000000">
                      <option name="displayName" value="research" />
                    </RecentProjectMetaInfo>
                  </value>
                </entry>
              </map>
            </option>
          </component>
        </application>
        """
        let entries = JetBrainsRecentProjectsWatcher.parseRecentProjectsXML(xml)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].displayName, "leaf")
        XCTAssertEqual(entries[0].activationTimestampMs, 1_747_345_678_901)
        XCTAssertEqual(entries[1].displayName, "research")
    }

    func test_parseRecentProjectsXML_malformedReturnsEmpty() {
        XCTAssertTrue(JetBrainsRecentProjectsWatcher.parseRecentProjectsXML("<>not xml").isEmpty)
        XCTAssertTrue(JetBrainsRecentProjectsWatcher.parseRecentProjectsXML("").isEmpty)
    }

    func test_parseRecentProjectsXML_omitsRunManagerSecrets() {
        // ADR-010 walkback: XML element bodies beyond displayName + activationTimestamp
        // must NOT enter payload. Verify <runManager> child content is dropped.
        let xml = """
        <application>
          <component name="RecentProjectsManager">
            <option name="additionalInfo">
              <map>
                <entry key="$USER_HOME$/x">
                  <value>
                    <RecentProjectMetaInfo activationTimestamp="1747000000000">
                      <option name="displayName" value="x" />
                      <runManager><secret>LEAKED_SENTINEL_JB_P6</secret></runManager>
                    </RecentProjectMetaInfo>
                  </value>
                </entry>
              </map>
            </option>
          </component>
        </application>
        """
        let entries = JetBrainsRecentProjectsWatcher.parseRecentProjectsXML(xml)
        XCTAssertEqual(entries.count, 1)
        // No leaked sentinel string anywhere in parsed entries.
        let mirror = String(describing: entries)
        XCTAssertFalse(mirror.contains("LEAKED_SENTINEL_JB_P6"),
                       "secret leaked through parser: \(mirror)")
    }

    func test_buildEvent_emitsExpectedPayload() {
        let event = JetBrainsRecentProjectsWatcher.buildEvent(
            bundleID: "com.jetbrains.pycharm",
            versionDir: "PyCharm2025.1",
            displayName: "ml-research",
            activationTimestampMs: 1_747_345_678_901,
            outsideWatchedFolder: true
        )
        XCTAssertEqual(event.payload["event_kind"], "jetbrains_recent_project_observed")
        XCTAssertEqual(event.payload["ide_bundle_id"], "com.jetbrains.pycharm")
        XCTAssertEqual(event.payload["ide_version_dir"], "PyCharm2025.1")
        XCTAssertEqual(event.payload["project_name"], "ml-research")
        XCTAssertEqual(event.payload["activation_timestamp_ms"], "1747345678901")
        XCTAssertEqual(event.payload["outside_watched_folder"], "true")
    }

    // MARK: - Track-9 T1: workspace_root extraction

    func testWorkspaceRootExtractedFromUserHomeKey() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <application>
          <component name="RecentProjectsManager">
            <option name="additionalInfo">
              <map>
                <entry key="$USER_HOME$/Desktop/Leaf/leaf">
                  <value>
                    <RecentProjectMetaInfo>
                      <option name="displayName" value="leaf" />
                      <option name="activationTimestamp" value="1715800000000" />
                    </RecentProjectMetaInfo>
                  </value>
                </entry>
              </map>
            </option>
          </component>
        </application>
        """
        let parsed = JetBrainsRecentProjectsWatcher.parseRecentProjectsXML(xml)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].workspaceRoot, "~/Desktop/Leaf/leaf")
    }

    func testWorkspaceRootNilForProjectDirKey() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <application><component name="RecentProjectsManager">
          <option name="additionalInfo"><map>
            <entry key="$PROJECT_DIR$/subproject">
              <value><RecentProjectMetaInfo>
                <option name="displayName" value="sub" />
              </RecentProjectMetaInfo></value>
            </entry>
          </map></option>
        </component></application>
        """
        let parsed = JetBrainsRecentProjectsWatcher.parseRecentProjectsXML(xml)
        XCTAssertEqual(parsed.first?.workspaceRoot, nil)
    }

    func testBuildEventIncludesWorkspaceRootWhenAvailableAndEnabled() {
        let event = JetBrainsRecentProjectsWatcher.buildEvent(
            bundleID: "com.jetbrains.intellij",
            versionDir: "IntelliJIdea2024.1",
            displayName: "leaf",
            activationTimestampMs: 1_715_800_000_000,
            outsideWatchedFolder: false,
            workspaceRoot: "~/Desktop/Leaf/leaf",
            workspaceRootEnabled: true
        )
        XCTAssertEqual(event.payload["workspace_root"], "~/Desktop/Leaf/leaf")
    }

    func testBuildEventOmitsWorkspaceRootWhenDisabled() {
        let event = JetBrainsRecentProjectsWatcher.buildEvent(
            bundleID: "com.jetbrains.intellij",
            versionDir: "IntelliJIdea2024.1",
            displayName: "leaf",
            activationTimestampMs: 1_715_800_000_000,
            outsideWatchedFolder: false,
            workspaceRoot: "~/Desktop/Leaf/leaf",
            workspaceRootEnabled: false
        )
        XCTAssertNil(event.payload["workspace_root"])
    }

    func testBuildEventDropsAbsolutePathDefensively() {
        let event = JetBrainsRecentProjectsWatcher.buildEvent(
            bundleID: "com.jetbrains.intellij",
            versionDir: "IntelliJIdea2024.1",
            displayName: "leaf",
            activationTimestampMs: 1_715_800_000_000,
            outsideWatchedFolder: false,
            workspaceRoot: "/Users/alice/Desktop/leaf",
            workspaceRootEnabled: true
        )
        XCTAssertNil(event.payload["workspace_root"])
    }
}
