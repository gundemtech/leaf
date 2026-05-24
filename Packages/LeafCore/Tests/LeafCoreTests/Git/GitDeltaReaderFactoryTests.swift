import XCTest
@testable import LeafCore

final class GitDeltaReaderFactoryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        GitDeltaReaderFactory.resetForTests()
    }

    override func tearDown() {
        GitDeltaReaderFactory.resetForTests()
        super.tearDown()
    }

    func testDefaultMakeReturnsStub() async {
        let reader = GitDeltaReaderFactory.make()
        let snapshot = await reader.read(forWorkspacePath: "/tmp/anywhere")
        XCTAssertNil(snapshot)
    }

    func testRegisterReplacesProvider() async {
        GitDeltaReaderFactory.register {
            FixedGitDeltaReader(snapshot: GitDeltaSnapshot(
                commitsAhead: 7, commitsBehind: 0, uncommittedCount: 0,
                mergeBase: "origin/main", remote: nil))
        }
        let reader = GitDeltaReaderFactory.make()
        let snapshot = await reader.read(forWorkspacePath: "/anything")
        XCTAssertEqual(snapshot?.commitsAhead, 7)
        XCTAssertEqual(snapshot?.mergeBase, "origin/main")
    }

    func testResetForTestsClearsRegistration() async {
        GitDeltaReaderFactory.register {
            FixedGitDeltaReader(snapshot: GitDeltaSnapshot(
                commitsAhead: 1, commitsBehind: 1, uncommittedCount: 1))
        }
        GitDeltaReaderFactory.resetForTests()
        let reader = GitDeltaReaderFactory.make()
        let snapshot = await reader.read(forWorkspacePath: nil)
        XCTAssertNil(snapshot)
    }

    func testStubReturnsNilForAnyPath() async {
        let stub = StubGitDeltaReader()
        let a = await stub.read(forWorkspacePath: nil)
        let b = await stub.read(forWorkspacePath: "/tmp")
        XCTAssertNil(a)
        XCTAssertNil(b)
    }
}

private struct FixedGitDeltaReader: GitDeltaReader {
    let snapshot: GitDeltaSnapshot
    func read(forWorkspacePath path: String?) async -> GitDeltaSnapshot? { snapshot }
}
