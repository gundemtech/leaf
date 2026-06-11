import Foundation

/// AI-UI-4 — Settings → AI Answers state→copy derivation (pattern:
/// `AIPrivacyFeedPresentation` — pure, SPM-testable; the view stays glue).
/// With AI-included live, "no key" is no longer a disabled state: in-app AI
/// answers ride the team plan, and the BYOK key is the optional override
/// valve. MCP `ask_about_my_work` remains BYOK-only (the read-only sidecar
/// can't share the app's Supabase session) — copy stays honest about that.
public enum AIAnswersSettingsPresentation {
  public struct Model: Equatable, Sendable {
    public let statusLabel: String
    /// Dot tone — active in BOTH states now (the keyless state is live via
    /// the team plan, not muted).
    public let statusIsActive: Bool
    public let sectionDescription: String
    public let savedFeedback: String
    public let removedFeedback: String
  }

  public static func model(hasKey: Bool) -> Model {
    Model(
      statusLabel: hasKey
        ? "Using your Anthropic key (team plan override)"
        : "AI answers included via your team plan",
      statusIsActive: true,
      sectionDescription:
        "In-app AI answers — Ask Leaf, escalations, handoff drafts — are included with your team plan. Optionally add your own Anthropic API key to route them through your key instead; the key also enables the MCP ask_about_my_work tool, which uses your key only. The key is stored locally in a permission-restricted file and never leaves this Mac except to call Anthropic.",
      savedFeedback: "Key saved. AI answers now use your key — in Ask Leaf and MCP.",
      removedFeedback:
        "Key removed. In-app AI answers now run on your team plan; the MCP tool needs a key.")
  }
}
