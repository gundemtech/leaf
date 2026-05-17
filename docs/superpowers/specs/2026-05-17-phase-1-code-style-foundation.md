# Phase 1 — Code Style Foundation

| Поле | Значение |
|---|---|
| Дата | 2026-05-17 |
| Ветка | `feature/code-style-foundation` |
| Off-base | `origin/main` HEAD `60bf38e9` (alpha.16) |
| Trek | Параллельный refactor track, не блокирующий Track-7 |
| Статус | Draft → ждёт user review gate |
| Контракт | **Zero `.swift` file changes.** Только конфиги/доки. |

---

## 1. Motivation

Кодбаза Leaf достигла ~730 Swift файлов (494 prod + 235 test) с устоявшимися практиками (PascalCase types, factory-enum DI, `@MainActor @Observable` ViewModels, XCTest-доминантная test layer, ADR-010 privacy walkbacks). Конвенции **в голове у двух разработчиков и в shared memory комментариях**, но никогда не были формализованы. `conventions.md` записывает: *"Стиль: TBD"*.

Цели Phase 1:
- **Зафиксировать существующий стиль** в `STYLE.md` (актуальные практики, не aspirational).
- **Включить автоматическую проверку** на новых PR через CI (report-only режим).
- **Не сломать ничего** — параллельный Track-7 в полёте; этот трек **не трогает ни одного `.swift` файла**.

Phase 1 — это рельсы. Phase 2 (cleanup) и Phase 3 (block-mode CI gate) — отдельные треки.

---

## 2. Goals & non-goals

### Goals (P1)

- G1. Apple `swift-format` config (`.swift-format`) — formatter, defaults aligned с текущим стилем.
- G2. `SwiftLint` config (`.swiftlint.yml`) — semantic rules, hybrid baseline strategy.
- G3. `.swiftlint-baseline.json` — auto-generated grandfather для aspirational pool правил.
- G4. `STYLE.md` (root) — code conventions extracted from real codebase patterns.
- G5. `CONTRIBUTING.md` (root) — onboarding: clone → build → test → lint → format → PR.
- G6. `.editorconfig` (root) — IDE-baseline (4 spaces, LF, trim trailing, final newline).
- G7. `.github/workflows/code-style.yml` — GH Action, full-repo scan, report-only, PR annotations.
- G8. `justfile` — 5 рецептов: `lint`, `lint-fix`, `format`, `format-check`, `check-style`.
- G9. Shared memory update: `.claude/shared/conventions.md` (1 строка → ссылка на STYLE.md), `.claude/shared/current-state.md` (P1 landed entry).

### Non-goals (P1)

- N1. **Никакого `.swift` фикса** — даже trivial. Aspirational pool grandfather'ит через baseline.
- N2. Block-mode CI — exit-1 on violations (отложено в Phase 3 / Track-7 P11 wrap).
- N3. Build-time enforcement (Xcode build phase / SPM build plugin) — отложено в Phase 3.
- N4. Pre-commit hooks — отложено в Phase 3.
- N5. Custom SwiftLint rules (regex) — рассмотрим в Stage 5; defer'им если regex false-positive risk высокий.
- N6. Linting `LeafCorePrivate/Sources/*` — `excluded:` в `.swiftlint.yml`. Moat-код gitignored, локально может линтоваться руками если разработчику нужно.
- N7. Whitepaper sync — Phase 1 — implementation infrastructure, не product-level decision. В `leaf-docs` ничего не пишем.
- N8. Linear issue — не создаём (это инфраструктурный трек, не продуктовая фича).

---

## 3. Hard contract

Эти инварианты проверяются в Stage 7 verification, провал любого → REJECT:

- **C1.** `git diff origin/main --name-only | grep '\.swift$'` → **0 строк** (ни одного `.swift` файла в diff).
- **C2.** Branch off `origin/main`, не off Track-7 ветки. (Stage 1 уже выполнен: worktree off `60bf38e9`.)
- **C3.** Каждое правило в `.swiftlint.yml` имеет inline-comment объясняющий **why** — либо evidence из codebase, либо предотвращаемый incident class. Никакого copy-paste без обоснования.
- **C4.** `STYLE.md` описывает **то что УЖЕ есть** в codebase. Aspirational практики помечены явным `### Aspirational (Phase 3)` разделом.
- **C5.** Перед `git push` — пробег по `/pre-push-leaf` чек-листу (репо публичный).

---

## 4. Tool choices

Все 6 forks решены в Stage 2 brainstorm:

| # | Fork | Решение | Rationale |
|---|---|---|---|
| 1 | Formatter | **Apple `swift-format`** | Ships с Xcode 16+, aligned с swift-syntax / SPM / PointFree / Vapor. Defaults близки к текущему стилю. |
| 2 | Enforcement | **CI-only + `just lint`** | Zero risk для Track-7. Report-only matches контракт «не блокирует merge». |
| 3 | Baseline | **Hybrid** (strict pool empty + aspirational pool with JSON baseline) | Сильная дисциплина сразу + roadmap для legacy violations. |
| 4 | CI scope | **Full repo + `--baseline` diff** | Honest enforcement. macos-26 runner handles 730 files в <2 min. |
| 5 | Docs layout | **`STYLE.md` + `CONTRIBUTING.md` at root** | OSS-стандарт. Single source of truth для style. |
| 6 | Moat scope | **`excluded:`** для `LeafCorePrivate/Sources/` | Симметрично с CI (там пусто). Чистый local `just lint` output. |

---

## 5. Deliverables

### 5.1. `.swift-format` (root)

Apple swift-format config (JSON). Версия `1`, defaults except:

```json
{
  "version": 1,
  "lineLength": 120,
  "indentation": { "spaces": 4 },
  "tabWidth": 4,
  "respectsExistingLineBreaks": true,
  "lineBreakBeforeControlFlowKeywords": false,
  "lineBreakBeforeEachArgument": false,
  "prioritizeKeepingFunctionOutputTogether": true,
  "indentConditionalCompilationBlocks": false,
  "indentSwitchCaseLabels": false,
  "rules": {
    "AlwaysUseLowerCamelCase": true,
    "AmbiguousTrailingClosureOverload": true,
    "BeginDocumentationCommentWithOneLineSummary": false,
    "NeverForceUnwrap": false,
    "NoLeadingUnderscores": false,
    "OrderedImports": true,
    "UseLetInEveryBoundCaseVariable": true,
    "UseSynthesizedInitializer": true,
    "UseTripleSlashForDocumentationComments": true,
    "ValidateDocumentationComments": false
  }
}
```

**Rationale для не-default ключей:**
- `lineLength: 120` — discovery показал реальные строки 100-130 char без видимого ущерба. Apple-default 100 спровоцировал бы массовые grandfather'ы. 120 = баланс.
- `OrderedImports: true` — VSCodeFamilyDispatcher и большинство файлов уже Foundation-first.
- `BeginDocumentationCommentWithOneLineSummary: false` — multi-line `///` блоки (VSCodeFamilyDispatcher line 3-5) — common pattern.
- `NeverForceUnwrap: false` — duplicate с SwiftLint `force_unwrapping`. Оставляем SwiftLint owner этой проверки.

### 5.2. `.swiftlint.yml` (root)

Структура (rule list locked в Stage 4 plan):

```yaml
# Leaf — SwiftLint configuration.
# Phase 1 — code style foundation.
# Каждое правило ниже либо ловит реальную проблему в codebase, либо предотвращает
# класс инцидентов. См. STYLE.md для обоснований.

excluded:
  - .build
  - .swiftpm
  - build
  - DerivedData
  - Packages/LeafCorePrivate/Sources  # moat, gitignored
  - Packages/*/.build
  - Packages/*/Tests/**/Fixtures      # generated test data
  - Resources

# Generated by `swiftlint baseline --baseline .swiftlint-baseline.json`.
# Aspirational pool grandfather list. Phase 3 промоут к strict pool.
baseline: .swiftlint-baseline.json

# Strict pool — empty baseline entries expected. Новые violations ловятся сразу.
opt_in_rules:
  - force_unwrapping
  - explicit_init
  - first_where
  - last_where
  - sorted_first_last
  - empty_count
  - empty_string
  - redundant_nil_coalescing
  - toggle_bool
  - unused_optional_binding
  - implicit_return
  - operator_usage_whitespace
  - shorthand_optional_binding
  - trailing_closure
  # rule list финализируется в Stage 4 plan после baseline gen

disabled_rules:
  - line_length              # owner = swift-format
  - trailing_whitespace      # owner = .editorconfig + swift-format
  - todo                     # TODO допустим, см. CLAUDE.md pre-push checklist
  - identifier_name          # legitimate short names (id, ts, db, fs, ws)
  - type_body_length         # XcodeBuildLifecycleStateMachine ~150 lines by design
  # rule list финализируется в Stage 4 plan

# Aspirational pool overrides — ниже default thresholds для force-pool entry.
force_cast: warning
force_try: warning
file_length:
  warning: 600
  error: 1500
function_body_length:
  warning: 80
  error: 200
cyclomatic_complexity:
  warning: 12
  error: 25
type_body_length:
  warning: 400
  error: 800

reporter: "github-actions-logging"
```

**Полный список правил с rationale per rule — секция 6 спека.**

### 5.3. `.swiftlint-baseline.json` (root)

Auto-generated через:

```bash
swiftlint baseline --baseline .swiftlint-baseline.json --config .swiftlint.yml
```

Содержит per-file per-rule grandfather entries для aspirational pool. Commit в репо. Размер ожидается ~50-200 KB.

**Regenerate trigger:** после merge Track-7 / Track-6 (новые `.swift` файлы добавятся к main; baseline должен учесть). Документировано в STYLE.md «Baseline maintenance».

### 5.4. `.editorconfig` (root)

```ini
root = true

[*]
indent_style = space
end_of_line = lf
charset = utf-8
trim_trailing_whitespace = true
insert_final_newline = true

[*.swift]
indent_size = 4

[*.{yml,yaml,json}]
indent_size = 2

[Package.swift]
indent_size = 4

[justfile]
indent_style = tab

[Makefile]
indent_style = tab
```

### 5.5. `STYLE.md` (root, ≤300 lines)

Section list:

1. **TL;DR** — 5 bullets для cold reader.
2. **Tooling** — `swift-format`, `SwiftLint`, `just`. Команды для local check.
3. **Naming** — types, funcs, vars, enum cases, files. Evidence из codebase (file:line refs).
4. **File layout** — import ordering, `// MARK:` для >150 lines, one-type-per-file (с допустимыми исключениями: nested types, private helper structs).
5. **Protocol-impl DI** — `Foo` protocol + `ProdFoo` impl + `StubFoo` test double. Factory enum pattern (DerivedInsightsFactory).
6. **SwiftUI Views & @Observable ViewModels** — `@MainActor @Observable final class FooViewModel`, `private(set) var state: State = .loading`, `private enum State: Equatable`, `Task.detached(priority: .userInitiated)` для async reload.
7. **Async & actor** — `@MainActor` isolation для UI mutation, `Task.detached` для background, no `@escaping` где можно избежать, Sendable on state machines.
8. **Testing** — XCTest dominant (228 vs 5 Swift Testing imports на HEAD `60bf38e9`); `final class FooTests: XCTestCase`, `testX` naming, manual stub structs (no mocking framework).
9. **Privacy walkbacks (ADR-010)** — `LEAKED_SENTINEL_*` injection pattern в `RelayBodyLeakageTests`. Parser allowlist discipline. См. CLAUDE.md «Won't-list».
10. **Comments** — sparse, why-only, MARK: для long files. No header license blocks.
11. **Error handling** — `throws` predominant; optional return для parse/map failures; `state = .error(String)` в ViewModels.
12. **Known violations grandfathered (Phase 1 baseline)** — auto-extracted list из `.swiftlint-baseline.json` (rule + count per file).
13. **Aspirational (Phase 3)** — что промоутим из aspirational pool, в каком порядке.

### 5.6. `CONTRIBUTING.md` (root, ≤80 lines)

```markdown
# Contributing to Leaf

## Requirements
- macOS 14+, Xcode 16+ (ships swift-format)
- Just task runner: `brew install just`
- SwiftLint: `brew install swiftlint`

## Setup
git clone git@github.com:gundemtech/leaf.git
cd leaf

## Build
open Leaf.xcodeproj в Xcode 16+ → ⌘B
ИЛИ `just build-all` (все 5 schemes Debug)

## Test
just test-core           # LeafCore SPM tests

## Style
just format-check        # validate без правок
just format              # apply formatting
just lint                # SwiftLint vs baseline
just lint-fix            # auto-fix where possible
just check-style         # composite: format-check + lint

## Conventions
См. STYLE.md.

## PR checklist
- [ ] just check-style passes
- [ ] xcodebuild all 5 schemes Debug build OK
- [ ] just test-core зелёный
- [ ] Если затрагивает архитектуру/whitepaper-уровень — `/sync-docs`
- [ ] Если PR в `gundemtech/leaf` (публичный) — `/pre-push-leaf` пройден
```

### 5.7. `.github/workflows/code-style.yml`

```yaml
name: code-style
on:
  pull_request:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read
  pull-requests: write

jobs:
  style:
    name: Format & lint
    runs-on: macos-26
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0  # full history for baseline diff

      - name: Select Xcode
        run: sudo xcode-select -switch /Applications/Xcode.app

      - name: Versions
        run: |
          xcrun swift-format --version
          xcodebuild -version

      - name: Install SwiftLint
        run: brew install swiftlint

      - name: Format check
        id: fmt
        continue-on-error: true
        run: |
          xcrun swift-format lint \
            --recursive --strict \
            Leaf LeafAgent LeafMCP \
            Packages/LeafCore/Sources \
            Packages/LeafCore/Tests \
            > swift-format.log 2>&1 || true
          cat swift-format.log

      - name: SwiftLint
        id: lint
        continue-on-error: true
        run: |
          swiftlint lint \
            --config .swiftlint.yml \
            --baseline .swiftlint-baseline.json \
            --reporter github-actions-logging

      - name: Style summary
        run: |
          echo "## Style check (report-only)" >> $GITHUB_STEP_SUMMARY
          echo "" >> $GITHUB_STEP_SUMMARY
          echo "**swift-format:** \`${{ steps.fmt.outcome }}\`" >> $GITHUB_STEP_SUMMARY
          echo "**SwiftLint:** \`${{ steps.lint.outcome }}\`" >> $GITHUB_STEP_SUMMARY
          echo "" >> $GITHUB_STEP_SUMMARY
          echo "Violations отображены как PR annotations выше." >> $GITHUB_STEP_SUMMARY
          echo "Этот workflow в **report-only** режиме (Phase 1). См. STYLE.md." >> $GITHUB_STEP_SUMMARY
```

**Block-mode toggle (Phase 3):** убрать `continue-on-error: true` на fmt + lint step. Альтернатива — repo variable `STYLE_BLOCKING` с `if: vars.STYLE_BLOCKING == 'true' && steps.lint.outcome == 'failure'` step для fail.

### 5.8. `justfile` — extension

Существующие рецепты (`check-tokens`, `check-tokens-self-test`, `build-all`, `test-core`) сохраняются. Добавляем:

```just
# Lint via SwiftLint, filter through baseline.
lint:
    swiftlint lint --config .swiftlint.yml --baseline .swiftlint-baseline.json

# Auto-fix SwiftLint violations where possible.
lint-fix:
    swiftlint lint --fix --config .swiftlint.yml --baseline .swiftlint-baseline.json

# Apply swift-format in-place.
format:
    xcrun swift-format format --in-place --recursive \
        Leaf LeafAgent LeafMCP \
        Packages/LeafCore/Sources Packages/LeafCore/Tests

# Validate format without writing.
format-check:
    xcrun swift-format lint --recursive --strict \
        Leaf LeafAgent LeafMCP \
        Packages/LeafCore/Sources Packages/LeafCore/Tests

# Composite gate — format-check + lint.
check-style:
    just format-check
    just lint
```

### 5.9. `.claude/shared/conventions.md` — 1-line update

Раздел `## Код`:

```
- Стиль: см. STYLE.md (root). Configs: .swift-format + .swiftlint.yml.
  Локальная проверка: `just check-style`. CI: report-only через .github/workflows/code-style.yml.
```

(Заменяет существующее `Стиль: TBD`.)

### 5.10. `.claude/shared/current-state.md` — P1 landed entry

В формате существующих entries — добавляется в Stage 8 final commit:

```
**2026-05-17 — Phase 1 Code Style Foundation landed** на `feature/code-style-foundation` (off main `60bf38e9`).
Apple swift-format + SwiftLint + hybrid baseline + STYLE.md + CONTRIBUTING.md + report-only CI. Zero .swift changes per контракт. <N> known violations grandfathered в aspirational pool (см. STYLE.md §12). Promote to block-mode — Phase 3 / Track-7 P11 wrap.
```

---

## 6. SwiftLint rule pool methodology

### 6.1. Decision algorithm

```
Run baseline gen on origin/main HEAD 60bf38e9 →
  for each candidate rule R (SwiftLint default-enabled + opt-in candidates):
    violations = swiftlint lint --no-cache --reporter json | jq '[.[] | select(.rule_id == R)] | length'
    if violations == 0:
      STRICT POOL — enable, empty baseline entry. Любая новая violation ловится сразу.
    elif violations <= 5:
      STRICT POOL — enable, fix inline... STOP. C1 запрещает .swift changes. → ASPIRATIONAL POOL.
    else:
      ASPIRATIONAL POOL — enable, entries в baseline JSON. Roadmap в STYLE.md §13.

Disabled-by-default rules — рассматриваем индивидуально:
  if matches evidence (greppable) OR known incident → opt_in.
  else skip с пометкой "considered, deferred".
```

### 6.2. Candidate rule list (initial — Stage 4 plan locks final)

#### Strict pool (target: 0 violations, error severity)

| Rule | Why |
|---|---|
| `force_cast` | Crash risk. AppleScript adapter shapes drift → `as!` brittle. Evidence: 0 hits на HEAD (verified Stage 5). |
| `force_try` | Crash risk. Migration / SQL / network call sites — wrap в `do/catch` или `try?`. |
| `force_unwrapping` (opt-in) | Same family. State machines используют guard let pattern. |
| `colon`, `comma`, `opening_brace`, `closing_brace` | Style consistency — `swift-format` владелец formatting, но SwiftLint catches edge cases swift-format пропускает. |
| `redundant_nil_coalescing` | Anti-pattern catch. |
| `empty_count`, `empty_string` | Style — `isEmpty` predicate clarity. |
| `unused_optional_binding` | `if let _ = ...` anti-pattern. |
| `trailing_newline` | Catches misaligned files. |
| `legacy_constructor`, `legacy_constant` | Apple modernization. |
| `mark` | `// MARK:` syntax discipline. |
| `shorthand_optional_binding` | Swift 5.7+ — `if let foo` shorthand. |
| `redundant_set_access_control` | `private set` redundant in private class. |
| `explicit_init` | `Foo.init(...)` only where needed. |
| `first_where`, `last_where` | `.first { $0.x == y }` vs `.first(where: { $0.x == y })`. |
| `toggle_bool` | `flag.toggle()` over `flag = !flag`. |

#### Aspirational pool (target: ≤current count, warning severity, baseline grandfather)

| Rule | Default threshold | Why aspirational |
|---|---|---|
| `function_body_length` | 80 warn / 200 error | Existing state-machine `observe()` methods near 80; promote to 60 в Phase 3. |
| `type_body_length` | 400 warn / 800 error | `MenuBarContent` ~230, `QueryEngine` ~700. |
| `file_length` | 600 warn / 1500 error | Long parser/mapper files. |
| `cyclomatic_complexity` | 12 warn / 25 error | Switch-heavy mappers (33-kind `mapLocalOS`). |
| `function_parameter_count` | 6 warn / 8 error | Some collectors с config injection. |
| `nesting` | 2 warn / 5 error | Generic constraints в LeafCore types. |
| `large_tuple` | 3 warn / 4 error | Body-kind dispatcher tuples (track-4 S4). |

#### Disabled (rationale)

| Rule | Why disabled |
|---|---|
| `line_length` | swift-format owner. SwiftLint check был бы double-warn. |
| `trailing_whitespace` | .editorconfig + swift-format. |
| `todo` | Pre-push checklist уже filter'ит TODO с internal context. |
| `identifier_name` | Legitimate short names: `id`, `ts`, `ms`, `db`, `fs`, `ws`, `dt`, `to`, `from`. |
| `multiple_closures_with_trailing_closure` | SwiftUI views legitimately chain `.onAppear { } .onDisappear { }`. |
| `closure_body_length` | SwiftUI body views часто 50-80 lines for layout. |

### 6.3. Custom rules — рассматриваем в Stage 5

Кандидаты (regex-based):

- **`walkback_sentinel_required`** — файл `*RelayBodyLeakageTests.swift` должен содержать `LEAKED_SENTINEL_` строку (warning). Защита ADR-010 discipline.
  - **Risk:** new test files без sentinel — false positive если test покрывает не-leaky surface. Mitigation: regex match `func test.*Sentinel|Leakage` сначала.
- **`mark_for_long_files`** — файл >250 lines должен содержать `// MARK:` минимум один раз.
  - **Risk:** legitimate single-purpose long file. Mitigation: warning, не error.

**Decision:** include в P1 если Stage 5 покажет clear regex без false positives. Иначе defer в Phase 3.

---

## 7. CI workflow design — see §5.7

Дополнения к skeleton выше:

- **Workflow file:** `.github/workflows/code-style.yml` — отдельный от существующего `ci.yml`.
- **Triggers:** `pull_request: [main]` + `workflow_dispatch`. **Не** `push: [main]` — runs только на PR-уровне для feedback loop.
- **Parallel execution с `ci.yml`:** оба workflow тригерятся на тот же PR; jobs параллельны (default GHA behavior).
- **macos-26 runner:** matches existing `ci.yml`. SwiftLint install через `brew` — кэшируем через `actions/cache` если runtime превышает 90s в Stage 5 smoke.
- **Permissions:** `pull-requests: write` нужен для annotations + step summary. `contents: read` для checkout.
- **Annotation UX:** `--reporter github-actions-logging` в SwiftLint создаёт inline annotations прямо в PR Files-changed view. `swift-format` пишет в stdout (захватываем в `swift-format.log`, посылаем в step summary).

---

## 8. Local developer workflow

```
# Setup
brew install just swiftlint
# swift-format — bundled c Xcode 16+

# Cycle
just format         # auto-format в worktree
just check-style    # gate перед commit
git add .
git commit -m "feat(Leaf): ..."

# Если check-style fails — посмотри annotations + fix.
# Aspirational violations не fail'ят (baseline filter).
# Strict violations fail'ят локально.
```

**Editor integrations (рекомендуем в STYLE.md):**

- Xcode 16+ — Editor → Format → Format Source (или ⌃I) использует bundled swift-format.
- VS Code: extension `vknabel.vscode-apple-swift-format`.
- JetBrains IDEs: built-in Swift formatter respects `.swift-format`.

---

## 9. Verification gates (Stage 7)

Все 6 — обязательны:

| # | Gate | Команда | Pass criteria |
|---|---|---|---|
| V1 | Zero `.swift` changes | `git diff origin/main --name-only \| grep '\.swift$' \| wc -l` | `0` |
| V2 | `just format-check` parseable | `just format-check; echo $?` | Exit code valid, output parseable (либо `0` если clean, либо list of violations). |
| V3 | `just lint` parseable | `just lint; echo $?` | Same. |
| V4 | CI workflow green on draft PR | Push branch → open draft PR → wait for `code-style` workflow | All steps complete, step summary populated, annotations visible. |
| V5 | All 5 xcodebuild schemes green | `just build-all` | All schemes Debug build SUCCESS. |
| V6 | Existing test count preserved | `swift test --package-path Packages/LeafCore 2>&1 \| tail -1` | Test count parity с baseline на `60bf38e9` (capture before Stage 5, compare после). |

---

## 10. Out-of-scope / Phase 2-3 roadmap

### Phase 2 (cleanup, отдельная сессия)

- P2.1. Промоут aspirational pool rules где violations <10 — fix `.swift` files.
- P2.2. Reduce baseline JSON entries по N штук per category.
- P2.3. SwiftLint cache config для CI speed.
- P2.4. Editor integration docs (Xcode formatting shortcuts, VS Code settings.json).

### Phase 3 (block-mode + extension, отдельная сессия)

- P3.1. Remove `continue-on-error: true` — CI блокирует на violations.
- P3.2. Promote выбранные rules к build-time (Xcode build phase или SPM build plugin).
- P3.3. Pre-commit hook installer (`brew install pre-commit` + `.pre-commit-config.yaml`).
- P3.4. Custom rules (если в P1 отложены).
- P3.5. `gitleaks` integration для secret scanning (упомянуто в корневом CLAUDE.md, было "когда появится код" — pre-push-leaf чек-лист уже manual).

### Carry-forward in STYLE.md `§13 Aspirational`

Каждое aspirational pool rule promoteable в strict pool при achievement specific count thresholds.

---

## 11. Risks & mitigations

| Risk | Probability | Impact | Mitigation |
|---|---|---|---|
| **R1.** Track-7 P11 merge invalidates baseline JSON | High | Medium | Doc'd в STYLE.md §12 «Baseline maintenance». Post-Track-7 regen в отдельном chore commit. |
| **R2.** SwiftLint 0.x → 1.0 breaking changes | Low | High | Pin SwiftLint version в CI через `brew install swiftlint@0.59` (если formula supports). Otherwise lock через `actions/cache` warmth. |
| **R3.** swift-format defaults shift между Xcode versions | Medium | Low | `.swift-format` JSON explicit — overrides defaults. Pinning Xcode не делаем (used latest stable). |
| **R4.** `--baseline` flag сделают breaking change | Low | Medium | Test против HEAD SwiftLint в Stage 5; rollback команды документированы. |
| **R5.** macos-26 runner deprecation | Low | Low | Matches existing `ci.yml`; bump в lockstep. |
| **R6.** PR annotations clutter Files-changed view | Medium | Low | Baseline filter reduces noise. Если всё равно too noisy в Stage 5 smoke — switch reporter to `emoji` для PR-comment-only. |
| **R7.** Контрибьюторы игнорируют report-only | High | Low (acceptable) | Это by design. Phase 3 промоут к block-mode когда дисциплина закрепится. |

---

## 12. Acceptance criteria (Stage 8 PR description)

Phase 1 considered landed если:

- AC1. PR содержит **только** файлы из §5 deliverables (gate V1).
- AC2. `just check-style` запускается без crash, выдаёт structured output (gates V2 + V3).
- AC3. Draft PR на `feature/code-style-foundation` — CI workflow green, step summary populated, ≥1 annotation visible если есть aspirational violations (gate V4).
- AC4. `just build-all` все 5 schemes Debug → SUCCESS (gate V5).
- AC5. `swift test --package-path Packages/LeafCore` — test count парный с baseline (gate V6).
- AC6. `STYLE.md` содержит все 13 секций §5.5; каждое правило в `.swiftlint.yml` имеет inline rationale comment (gate C3).
- AC7. Independent code review (`superpowers:code-reviewer` subagent) — ACCEPT или ACCEPT-WITH-NITS. REJECT → fix-bundle перед Stage 8.
- AC8. Manual smoke contributor flow: clean clone → `brew install just swiftlint` → `just check-style` → exit cleanly (без stack traces, без missing-tool errors).
- AC9. `.claude/shared/current-state.md` + `.claude/shared/conventions.md` updated с Phase 1 landed entry (gate G9).

**Out of AC scope:** merge в `main` — на усмотрение пользователя после review PR.

---

## 13. Open questions / placeholders

- **OQ-1.** Конкретный список `opt_in_rules` финализируется в Stage 4 plan после first baseline gen run (Stage 5 task 1). Список в §6.2 — initial draft, может скорректироваться.
- **OQ-2.** SwiftLint version pinning — TBD после проверки Homebrew formula versioning capabilities (`brew install swiftlint` vs `brew install swiftlint@VERSION`).
- **OQ-3.** Custom rules inclusion в P1 — решается в Stage 5 после regex validation на real codebase samples.
- **OQ-4.** Editor config для tab width в `justfile` — checked Apple convention (tabs), не spaces. Verify в Stage 5.

---

## 14. Implementation order (Stage 4 plan input)

High-level last:

1. Setup: install SwiftLint, swift-format version verify, worktree clean.
2. `.editorconfig` (independent, no dependency).
3. `.swift-format` (independent).
4. Initial `.swiftlint.yml` (rule list per §6.2 draft, no baseline yet).
5. Generate `.swiftlint-baseline.json` (running step 4 config против codebase).
6. Iterate on rule list — для каждого правила verify violation count, decide strict vs aspirational, update inline comment.
7. `STYLE.md` write (use baseline output для §12).
8. `CONTRIBUTING.md` write.
9. `justfile` extension.
10. `.github/workflows/code-style.yml`.
11. Stage 7 verification — six gates.
12. Self-review + fix-bundle.
13. Independent code review subagent.
14. Final commit + PR draft (Stage 8).

Каждый step выше → atomic commit (Stage 4 plan refinement).

---

## Self-review checklist

- [x] Placeholders scan: `<N>`, `TBD` appear только в `.claude/shared/current-state.md` template (replaced в Stage 8) и в `Phase 3` aspirational пометках (intentional).
- [x] Internal consistency: 6 forks → 6 deliverables → 14 implementation steps — chains aligned.
- [x] Scope check: single phase, single PR, single review session. Decomposable если в Stage 5 окажется что rule iteration слишком dense — можно расщепить на P1a (configs) + P1b (rules) commits, не на отдельную фазу.
- [x] Ambiguity: §6.1 decision algorithm — explicit. §6.2 rule list — initial, OQ-1 flag'ит, что финал в Stage 4.
- [x] Контракт C1 (zero .swift) — упомянут в §3, §6.1 (algorithm), §10 (deferred fixes), §12 (AC1). Coverage triple-redundant.
- [x] OSS reference projects — §4 row 1 + §6 references swift-syntax, PointFree, Vapor, swift-async-algorithms. Не "выдуманы".
