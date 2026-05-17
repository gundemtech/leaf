# Contributing to Leaf

Leaf is a macOS ambient-memory utility (Swift 6, SwiftUI, MCP server). См. [README.md](./README.md) для продуктового overview и [STYLE.md](./STYLE.md) для code conventions.

## Requirements

- **macOS 14+** (Sonoma или newer).
- **Xcode 16+** — ships Apple `swift-format`.
- **Homebrew** для CLI tools.
- **[just](https://github.com/casey/just):** `brew install just`.
- **[SwiftLint](https://github.com/realm/SwiftLint):** `brew install swiftlint` (≥ 0.63 — baseline JSON shape locked at this version).

Linux / Windows — не поддерживаемые targets.

## Setup

```bash
git clone git@github.com:gundemtech/leaf.git
cd leaf
open Leaf.xcodeproj   # или `xed .`
```

## Build

```bash
# Через Xcode UI: ⌘B на интересующем scheme.
# Через CLI — все 5 schemes Debug:
just build-all
```

## Test

```bash
# LeafCore SPM tests (preferred — быстрее):
just test-core

# Полный suite через Xcode UI: ⌘U per scheme.
```

## Style

```bash
just format          # apply swift-format на месте
just format-check    # validate без правок
just lint            # SwiftLint vs baseline (Phase 1 — report-only)
just lint-fix        # auto-fix violations где rule supports --fix
just check-style     # composite: format-check + lint
```

См. [STYLE.md](./STYLE.md) для конвенций, [.swift-format](./.swift-format) для formatter config, [.swiftlint.yml](./.swiftlint.yml) для linter rules.

## PR checklist

Перед `git push`:

- [ ] `just check-style` runs без crashes (violations OK для Phase 1 — report-only режим).
- [ ] `just build-all` — все 5 xcodebuild schemes Debug build SUCCESS.
- [ ] `just test-core` — test count parity с baseline на `main`.
- [ ] Если затрагивает архитектуру / продукт — обновлён whitepaper (см. CLAUDE.md «Whitepaper — source of truth»).
- [ ] **`/pre-push-leaf`** пройден (репо публичный — moat protection).

## Branch convention

- Feature work: `feature/<short-name>` off `main`.
- Bug fix: `fix/<short-name>`.
- Chore (CI / docs / style): `chore/<short-name>`; прямой push в `main` discouraged unless trivial.

См. `.claude/shared/conventions.md` для деталей.

## Commit message

Imperative, lowercase prefix:

```
feat(<Module>): <what>
fix(<Module>): <what>
docs(<scope>): <what>
chore(<scope>): <what>
test(<Module>): <what>
ci(<scope>): <what>
```

Examples из git log:

```
feat(Leaf): Track-7 P2 polish — compact rows for enabled-empty surface cards
docs(shared): Track-7 P2-collapsed landed — current-state update
test(LeafCore): Track-7 P2 step 33 — privacy walkback fence for 5 surface payloads
chore(style): .swiftlint.yml — rule pool locked (strict + aspirational, baseline regen)
```

## License & conduct

См. [README.md](./README.md).
