import XCTest

@testable import LeafCore

/// AI-UI-4 — Settings → AI Answers state→copy derivation. Honesty contract:
/// the team plan covers the IN-APP surfaces; MCP ask_about_my_work stays
/// BYOK-only (the sidecar can't share the app's Supabase session), so copy
/// never claims MCP is covered by the plan.
final class AIAnswersSettingsPresentationTests: XCTestCase {

  func testNoKeyShowsIncludedViaTeamPlan() {
    let m = AIAnswersSettingsPresentation.model(hasKey: false)
    XCTAssertEqual(m.statusLabel, "AI answers included via your team plan")
    XCTAssertTrue(m.statusIsActive, "keyless is a LIVE state now, not a muted 'no key' state")
  }

  func testKeyShowsByokOverride() {
    let m = AIAnswersSettingsPresentation.model(hasKey: true)
    XCTAssertEqual(m.statusLabel, "Using your Anthropic key (team plan override)")
    XCTAssertTrue(m.statusIsActive)
  }

  // Removing the key is no longer "AI disabled" — the pool picks up in-app.
  func testRemovedFeedbackPointsAtTeamPlanNotDisabled() {
    let m = AIAnswersSettingsPresentation.model(hasKey: false)
    XCTAssertTrue(m.removedFeedback.contains("team plan"))
    XCTAssertFalse(m.removedFeedback.contains("AI answers are disabled"))
  }

  func testSavedFeedbackMentionsOwnKey() {
    let m = AIAnswersSettingsPresentation.model(hasKey: true)
    XCTAssertTrue(m.savedFeedback.contains("your key"))
  }

  // The section description frames BYOK as the optional valve and stays
  // honest about MCP needing a key.
  func testDescriptionFramesByokAsOptionalAndMCPAsKeyOnly(){
    let m = AIAnswersSettingsPresentation.model(hasKey: false)
    XCTAssertTrue(m.sectionDescription.contains("included with your team plan"))
    XCTAssertTrue(m.sectionDescription.contains("ask_about_my_work"))
    XCTAssertTrue(m.sectionDescription.localizedCaseInsensitiveContains("your own Anthropic API key"))
  }

  // Copy is state-independent where it must be (description/feedback strings
  // don't flip with hasKey — only the status row does).
  func testOnlyStatusRowDependsOnKeyPresence() {
    let a = AIAnswersSettingsPresentation.model(hasKey: false)
    let b = AIAnswersSettingsPresentation.model(hasKey: true)
    XCTAssertEqual(a.sectionDescription, b.sectionDescription)
    XCTAssertEqual(a.savedFeedback, b.savedFeedback)
    XCTAssertEqual(a.removedFeedback, b.removedFeedback)
    XCTAssertNotEqual(a.statusLabel, b.statusLabel)
  }
}
