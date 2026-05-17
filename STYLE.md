# Leaf — Style Guide

> Conventions extracted from the actual codebase on `origin/main` HEAD `60bf38e9` (alpha.16).
> Aspirational practices marked explicitly. См. [CONTRIBUTING.md](./CONTRIBUTING.md) для setup.

## TL;DR

- **Formatter:** Apple `swift-format` (bundled с Xcode 16+). Config: `.swift-format`.
- **Linter:** SwiftLint. Config: `.swiftlint.yml`. Grandfather baseline: `.swiftlint-baseline.json`.
- **Indent:** 4 spaces Swift, 2 spaces yml/json, tab justfile/Makefile. См. `.editorconfig`.
- **Line length:** 120 chars max (swift-format owner).
- **Local check:** `just check-style`. CI: report-only через `.github/workflows/code-style.yml`.

---

## Tooling

| Tool | Owner | Where |
|---|---|---|
| `swift-format` | Whitespace, indent, braces, imports order, doc-comment shape | `just format` / `just format-check` |
| `SwiftLint` | Semantic rules (force_cast, complexity, naming, idiomatic API) | `just lint` / `just lint-fix` |
| `.editorconfig` | IDE baseline (indent, EOL, charset, trim) | Auto (Xcode 16+, VS Code, JetBrains) |

Boundary discipline: каждое style правило имеет **один владелец**. Например `line_length` — swift-format, не SwiftLint (см. `.swiftlint.yml` § disabled_rules).

Иногда rule existуют у обоих tools, и мы делегируем **semantic preferences** (например `implicit_return` shorthand, `redundant_type_annotation`) SwiftLint'у — swift-format остаётся neutral на этих преобразованиях (`OmitExplicitReturns: false`). После `just lint-fix` (SwiftLint авто-фиксит) → `just format` не сломает результат. Tools cooperate, не конфликтуют.

---

## Naming

| Element | Convention | Evidence |
|---|---|---|
| Types (`struct` / `class` / `enum` / `protocol`) | `PascalCase` always | [`VSCodeFamilyDispatcher.swift:6`](./Packages/LeafCore/Sources/LeafCore/Insights/Parsers/VSCodeFamily/VSCodeFamilyDispatcher.swift) |
| Methods / functions | `camelCase`, verb-phrase (`map`, `observe`, `query`, `reload`, `parse`) | broad — `Packages/LeafCore/Sources/LeafCore/Insights/` |
| Properties / locals | `camelCase` | universal |
| Enum cases | `camelCase` (e.g. `.loading`, `.loaded(...)`, `.empty`, `.error`) | Discovery §ViewModels |
| Static constants | `camelCase` (e.g. `supportedBundleIDs`) — НЕ `UPPER_SNAKE` | `VSCodeFamilyDispatcher.swift:8` |
| Acronyms in types | Capitalized as-is: `URL`, `MCP`, `AI`, `IDE`, `OAuth` | `URLDomainExtractor`, `IDETitlePathSanitizer` |
| File names | Match primary type 1:1 | `VSCodeFamilyDispatcher.swift` ↔ `enum VSCodeFamilyDispatcher` |
| Test files | `<Type>Tests.swift` | `Packages/LeafCore/Tests/.../SessionFeedMapperTests.swift` |
| Protocol-impl pair | `Foo` (protocol) + `ProdFoo` (production) + `StubFoo` (test double) | `DerivedInsightsFactory` (Discovery §DI) |

**SwiftLint disabled rules для naming:**
- `identifier_name` — legit short names: `id`, `ts`, `ms`, `db`, `fs`, `ws`, `dt`, `to`, `from`, `qs`.
- `type_name` — acronym-heavy types like `URLDomainExtractor`, `MCPServer`.

---

## File layout

- **Imports:** Foundation first, then framework (`LeafCore`), then domain (`SwiftUI`, etc.). swift-format `OrderedImports` enforces alphabetical within group.
- **One primary type per file.** Nested types (e.g. `enum State`, `struct PrivateHelper`) внутри primary — OK.
- **`// MARK:` sections** для файлов >150 lines. Common patterns: public-then-private order, or logical sections (Banners / Hero / Content / Controls / Helpers).
- **No header license blocks.** Топ-of-file `///` doc-comments только когда объясняют non-obvious decisions (например `XcodeBuildLifecycleStateMachine.swift:3-17` — phase context, trade-offs).

---

## Protocol-impl DI

Стандартный pattern — factory enum + Prod/Stub variants:

```swift
public enum DerivedInsightsFactory {
    nonisolated(unsafe) private static var provider: DerivedInsights?

    public static func register(_ p: DerivedInsights) { provider = p }

    public static func make() -> DerivedInsights {
        provider ?? StubInsights()
    }
}
```

- `Foo` protocol — domain name, NO `-able` или `Protocol` suffix.
- `ProdFoo` — production impl, обычно в `LeafCorePrivate/` (gitignored moat) для performance- или security-sensitive путей; в `LeafCore` если public-safe.
- `StubFoo` — test double + graceful-fallback в `LeafCore` (default-extension возвращает `.empty`).

Default-extension pattern на protocol даёт graceful degrade когда provider не зарегистрирован (см. `DerivedInsights` ext в `LeafCore/Insights/`).

---

## SwiftUI Views & @Observable ViewModels

### Detail-screen pattern

```swift
@MainActor
@Observable
final class FooDetailViewModel {
    private(set) var state: State = .loading
    var range: DetailRange = .lastSevenDays {
        didSet { guard oldValue != range else { return }; reload() }
    }

    private enum State: Equatable {
        case loading
        case loaded(<Surface>ActivityBreakdown)
        case empty
        case error(String)
    }

    private func reload() {
        state = .loading
        Task.detached(priority: .userInitiated) { [range] in
            do {
                let breakdown = try InsightsReader.defaultConfig().<surface>ActivityBreakdown(period: range)
                await MainActor.run { self.state = breakdown.isEmpty ? .empty : .loaded(breakdown) }
            } catch {
                await MainActor.run { self.state = .error(error.localizedDescription) }
            }
        }
    }
}
```

**Enforced conventions:**
- `@MainActor @Observable final class` для VMs (Discovery §ViewModels).
- `private(set) var state` — read-only к consumers.
- `private enum State: Equatable` — 4 case'а: `.loading`, `.loaded(...)`, `.empty`, `.error(String)`.
- `didSet` filter on selection props — `guard oldValue != newValue else { return }` против redundant reloads.
- `Task.detached(priority: .userInitiated)` для async load, explicit priority.

### Stateless card pattern

Когда mapping pure (no internal state) — namespace enum + static method:

```swift
public enum FooCardViewModel {
    public static func state(
        isEnabled: Bool,
        snapshot: InsightsSnapshot?
    ) -> CardState {
        ...
    }
}
```

См. `VSCodeFamilyDispatcher` (`Packages/LeafCore/Sources/LeafCore/Insights/Parsers/VSCodeFamily/VSCodeFamilyDispatcher.swift:6`) — namespace enum со `static let supportedBundleIDs` + `static func isVSCodeFamily(...)` + `static func parse(...)`. Дополнительные stateless card VMs landing'аются с Track-7 P2.

---

## Async & actor

- **`@MainActor` isolation** для UI state mutation.
- **`Task.detached(priority:)`** для background work; priority explicit (`.userInitiated` для detail-screen reload, `.background` для polling).
- **`actor` types** для shared mutable state (например `BrowserBookmarksWatcher`).
- **`Sendable` / `Hashable`** на state machines passed across tasks (например `XcodeBuildLifecycleStateMachine`).
- **`assumeIsolated`** — discouraged outside tightly-scoped legacy callbacks; prefer `Task { @MainActor in ... }` block.
- **`@escaping`** — избегаем где возможно; вместо этого `@MainActor`-isolated closure в `Task` block.

---

## Testing

- **XCTest dominant.** На HEAD `60bf38e9`: 228 XCTest imports vs 5 Swift Testing imports. Track-7 начинает Swift Testing adoption, но XCTest остаётся mainstream.
- **`final class <Type>Tests: XCTestCase`** + **`testCamelCase`** method naming.
- **Inline fixtures**, не `setUp`/`tearDown`. Helper methods — `private` в test class.
- **Manual stub structs.** Нет mocking framework. Например `StubClassifier` conforming to `AppCategoryClassifier`.
- **Swift Testing OK для новых тестов** (`@Test` / `@Suite`), не enforced.

---

## Privacy walkbacks (ADR-010)

Leaf — ambient memory collector. Captured bodies / PII никогда не утекают в presence stream. Discipline:

- **Parser allowlist:** parser strips forbidden fields **до** emit RawEvent. Например `ClaudeCodeHookParser` allowlist-only reads `tool_use_id` / `permission_mode` / `duration_ms` — никаких `command` / `tool_input` / `tool_response` / `content` / `thinking` / `signature`.
- **Sentinel injection fences:** Tests inject `LEAKED_SENTINEL_<TRACK>` в forbidden positions; integration test walks RawEvent payload tree и fail'ит если sentinel survives. Existing fences: `LEAKED_SENTINEL_CLAUDE_P1`, `LEAKED_SENTINEL_XCODE_P2`, plus per-track variants.
- **Won't-list** (что НЕ хранится никогда): см. `.claude/shared/architecture.md` Layer A "Запрещено" + корневой CLAUDE.md `/pre-push-leaf` checklist.

При добавлении новых event_kinds для Layer A/B/C providers — обязательно:
1. Per-kind parser-allowlist test.
2. Sentinel injection fence в `RelayBodyLeakageTests`.
3. `ShareEventTypeKey` registry entry (default OFF per ADR-020).

---

## Comments

- **Sparse, why-only.** Naming carries intent.
- `///` doc-comments — non-obvious decisions, phase/track context, trade-offs (например `XcodeBuildLifecycleStateMachine.swift:3-17`).
- `// MARK:` — sectioning для long files (>150 lines).
- **No** header license blocks.
- **No** "what" comments на naming-clear code.
- Track / Phase refs OK (`// Track-6 P2 — pure transition detector for Xcode build lifecycle`).

---

## Error handling

- **`throws` predominant.** Caller decides `try`, `try?`, `try!` (the last — только где caller guarantees domain safety, например миграции).
- **`Result<Success, Error>`** — rare; optional return для parse/map failures.
- **ViewModels:** `state = .error(String)` с user-facing message.
- **Logging:** `Logger(subsystem: "tech.gundem.leaf", category: "...")` в error paths.
- **Force unwrap** (`!`) — class риска. 248 hits в aspirational baseline; cleanup в Phase 2/3. Новый код — `guard let`/`if let` per default.

---

## Known violations grandfathered (Phase 1 baseline)

Auto-generated в `.swiftlint-baseline.json` (Task 5). **603 entries** распределены так:

| Rule | Count | Pool |
|---|---|---|
| `force_unwrapping` | 248 | aspirat. — crash class |
| `prefer_self_in_static_references` | 89 | aspirat. — `Self.x` modernization |
| `modifier_order` | 29 | aspirat. — `public final` consistency |
| `no_extension_access_modifier` | 26 | aspirat. — `public extension Foo` smell |
| `type_body_length` | 25 | aspirat. — QueryEngine, MenuBarContent |
| `file_length` | 24 | aspirat. — long parser/mapper files |
| `cyclomatic_complexity` | 24 | aspirat. — switch-heavy mappers |
| `redundant_type_annotation` | 21 | aspirat. — `let x: Int = 5` |
| `function_body_length` | 21 | aspirat. — state-machine `observe()` |
| `large_tuple` | 16 | aspirat. — body-kind dispatcher tuples |
| `function_parameter_count` | 12 | aspirat. — collectors с config injection |
| `force_try` | 12 | aspirat. — crash class |
| `implicit_return` | 11 | aspirat. — Swift 5.1+ shorthand |
| `switch_case_alignment` | 6 | aspirat. |
| `for_where` | 6 | aspirat. |
| `closure_parameter_position` | 6 | aspirat. |
| остальные | <6 each | strict ↔ aspirat. mix |

**Также** swift-format reports ~1338 stylistic violations (whitespace, brace placement, redundant tokens). Без baseline mechanism; cleanup через `just format` в Phase 2 separate PR (zero-`.swift`-changes контракт P1 запрещает).

**Maintenance:** baseline regenerate после merge крупных tracks (Track-6/Track-7) — chore commit `chore(style): regen baseline post-Track-N`.

---

## Aspirational (Phase 3)

После Phase 2 cleanup промоут из aspirational к strict:

- `force_unwrapping` — target 0 violations, promote с warning → error.
- `function_body_length` — tighten warn threshold 80 → 60 lines.
- `type_body_length` — promote с warning → error на 400.
- `cyclomatic_complexity` — tighten warn 12 → 10.

После integration Track-7 P11 wrap'а consider:

- **Block-mode CI** (`continue-on-error: false` на lint steps).
- **Build-time enforcement** (SwiftPM build plugin или Xcode build phase).
- **Pre-commit hook installer** (например `pre-commit` framework).
- **Custom regex rules** (например `walkback_sentinel_required` для `RelayBodyLeakageTests`).

---

## Maintenance

| Trigger | Action |
|---|---|
| Track-6 / Track-7 merge to main | `chore(style): regen baseline post-Track-N` commit (`swiftlint lint --write-baseline .swiftlint-baseline.json`) |
| Rule addition / threshold change | Update `.swiftlint.yml` inline rationale comment + соответствующую секцию STYLE.md в том же commit |
| New event_kind с body fields | Add parser-allowlist test + sentinel fence + `ShareEventTypeKey` entry (per §ADR-010 above) |
| Mass cleanup PR (Phase 2) | После merge — `swiftlint lint --write-baseline .swiftlint-baseline.json` обновляет grandfather list |

См. также `.claude/shared/conventions.md` (общие team conventions) и корневой `CLAUDE.md` (`/pre-push-leaf` discipline).
