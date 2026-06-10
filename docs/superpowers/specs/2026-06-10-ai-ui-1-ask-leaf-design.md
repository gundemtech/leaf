# AI-UI-1 — Ask Leaf: in-app Q&A панель (design)

_Дата: 2026-06-10. Фаза 1 трека «in-app AI surface» (полный трек — `.claude/plans/ai-ui-track.md`, local-only). Ветка: `feature/ai-ui-1-ask-leaf` → PR в `dev`._

## Цель

Видимая in-app поверхность «ИИ-анализатора»: пользователь задаёт natural-language вопросы о своей работе (git/Linear/Slack/AI-сессии) прямо в апке и получает ответ тем же privacy-preserving пайплайном, что MCP-тул `ask_about_my_work`. Плюс первый UI для управления BYOK-ключом — до сих пор ключ клали в файл руками.

**Не входит** (следующие фазы трека): escalation-модалка и Privacy-ленты (AI-UI-2), умный handoff-анализ (AI-UI-3), AI-included путь без своего ключа (AI-UI-4, ждёт login-ветку + leaf-relay `/v1/ai/*`).

## Решения (брейншторм 2026-06-10)

- **Поверхность:** отдельная вкладка в сайдбаре («Ask Leaf»), группа LEAF.
- **Формат:** чат-лента; каждый вопрос **независим** (без multi-turn контекста — паритет с MCP-тулом). История — in-memory, живёт пока открыто окно.
- **Путь инференса:** только `.byok` в этой фазе.
- **Подход:** A — «тонкий reader» поверх существующего пайплайна. Ноль новых LLM-путей, ноль миграций.

## Архитектура / data flow

```
AskLeafView (вкладка .askLeaf)
  └─ AskLeafReader (@MainActor @Observable, Leaf/Models/)
       ├─ WorkFactGatherer.gather(period) → [EgressEvent]      // тот же, что в MCP-туле
       └─ AIWorkAnswerer.answer(question:events:path:.byok, preferred:)
            ├─ LLMPolicy.makeContext(events) → PromptSafeContext   // §8.1, fail-closed
            ├─ ModelGate.model(path:preferred:)
            └─ Summarizer  (prodAISummarizerMoat ← FileAnthropicKeyStore)
```

### Компоненты

1. **`LeafCore/AI/AskLeafTranscript.swift`** (новый, public LeafCore — TDD-able):
   - `struct AskLeafEntry: Identifiable, Equatable, Sendable` — `id`, `question`, `period`, `model`, `askedAtMs`, `phase: Phase` где `enum Phase { case pending, answered(String), notEnoughData, failed(String) }`.
   - `struct AskLeafTranscript` — append-only список entries + переходы (`ask(...) -> id`, `resolve(id:with: AIWorkAnswerer.Answer)`). Чистая логика, без I/O.
2. **`LeafCore/AI/AnthropicKeyValidator.swift`** (новый, public LeafCore — TDD-able):
   - Pure-валидация ввода ключа для Settings: trim, непустой, sanity-префикс (`sk-ant-`) → `enum Verdict { ok, emptyInput, suspiciousFormat }` (suspicious — warning, не блокер: формат Anthropic может меняться).
3. **`Leaf/Models/AIWiring.swift`** (новый, app target):
   - Вынос трёх composition-root дефолтов из `HandoffDraftReader` (`defaultPolicy` / `defaultSummarizerMoat` / `defaultModelGateMoat`, `#if LEAF_PROD` ветвление как сейчас) в общий enum-неймспейс. `HandoffDraftReader` переводится на него — поведение бит-в-бит.
4. **`Leaf/Models/AskLeafReader.swift`** (новый, app target — зеркало `HandoffDraftReader`):
   - `@MainActor @Observable final class AskLeafReader`; lazy bootstrap `AIWorkAnswerer` + DB-handle (как `HandoffDraftReader.draft`); держит `AskLeafTranscript`; метод `ask(question:period:model:) async`.
   - Однополётность: пока entry в `.pending`, новый `ask` игнорируется (UI дизейблит Send).
5. **`Leaf/Views/Window/AskLeaf/AskLeafView.swift`** (новый):
   - Лента entries (вопрос + ответ/ошибка), внизу input + Send; пикеры периода (today/yesterday/last_7_days, дефолт last_7_days) и модели (haiku/sonnet/opus, дефолт haiku); empty state с подсказками-вопросами.
6. **Routing** (3 точечные правки):
   - `WindowSection`: кейс `.askLeaf` (после `.analytics`); иконка — SF Symbol если рендер поддерживает `iconIsSystem == true`, иначе новый asset.
   - `Sidebar.swift`: в группу LEAF.
   - `RootView.detail(for:)`: кейс → `AskLeafView()`.
   - `LeafApp.swift`: `@State private var askLeafReader = AskLeafReader()` + environment (по образцу `handoffDraftReader`) — единственная точка пересечения с login-веткой, одна строка.
7. **Settings → секция «AI»** (`WindowSettingsView` + новый sub-view `AISettingsSection`):
   - SecureField + Save / Remove поверх `FileAnthropicKeyStore` (`storeKey`/`deleteKey`/`loadKey != nil` для статуса «ключ задан»). Сам ключ после сохранения **не** перечитывается в поле и нигде не отображается.
   - Подпись: ключ хранится локально (file 0600), включает AI-ответы в апке **и** в MCP-туле.

### Почему file-store, а не Keychain

`KeychainAnthropicKeyStore` существует, но MCPServer Keychain читать не может (subprocess, P0-решение) — у него file-store. Один источник правды для обеих поверхностей = `FileAnthropicKeyStore` (0600, рядом с `db.key`/`x25519.priv`, FileVault-паритет). Keychain-store остаётся в коде на будущее.

### Privacy / §8.1

Новых egress-путей нет: Q&A шлёт только `PromptSafeContext` (кластеры фактов, без тел) — ровно как MCP-тул. Reverse-audit не требуется (паритет с MCP-путём, у которого аудита тоже нет; bodies-эскалация — AI-UI-2). Ключ: не логируется, не эхо-ится в ошибках (`AIWorkAnswerer.message(for:)` уже opaque).

## Error handling

Маппинг ошибок — существующий `AIWorkAnswerer.message(for:)`:
- `missingAPIKey` → entry-ошибка + кнопка «Open Settings» (переключает `WindowState.section = .settings`).
- `notEnoughData` → «недостаточно записанной работы за период».
- `authFailed` / `rateLimited` / generic network → существующие тексты.
- Ошибка — терминальное состояние entry в ленте; следующий вопрос не блокируется.

## Testing

- **LeafCore (TDD, swift test):** `AskLeafTranscript` (переходы, однополётность на уровне модели, ordering), `AnthropicKeyValidator` (вердикты), плюс smoke на то, что `AIWorkAnswerer` отдаёт `missingAPIKey`-маппинг (уже покрыт — проверить, не дублировать).
- **App target:** тест-бандла нет (прецедент) → view/reader-клей верифицируется `xcodebuild -scheme Leaf` + manual smoke: golden path (ключ в Settings → вопрос → ответ), edge (без ключа → CTA, пустой период → notEnoughData).
- **Гейты:** `just preflight` (R1) + зелёный CI на PR; leak-guard (R2). Имена в тестах — только плейсхолдеры (Alice/Eve — leak-guard флагает реальные).

## Конфликты с параллельной работой

- `feature/account-login-phase1` переписывает `LeafApp.swift`/`RootView.swift` — наши правки там минимальные (1 строка DI + 1 кейс в switch), мерж-конфликт тривиален.
- `feature/team-ui-polish` (пока пустая) — потенциально Team-вьюхи; мы их не трогаем (рефактор `HandoffDraftReader` — только перенос приватных static-дефолтов).
