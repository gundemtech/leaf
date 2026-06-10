# AI-UI-3 — Умный handoff (design)

_Дата: 2026-06-10. Фаза 3 трека «in-app AI surface» (трек — `.claude/plans/ai-ui-track.md`, local-only; backlog-источник — `ai-coworker-backlog.md` §P4 follow-ups). Ветка: `feature/ai-ui-3-smart-handoff` → PR в `dev`. Спеки предыдущих фаз — `2026-06-10-ai-ui-1-ask-leaf-design.md`, `2026-06-10-ai-ui-2-escalation-privacy-design.md`._

## Цель

Довести AI-handoff (AI Coworker P4) от «болванки по body-free фактам» до умного флоу: dedicated handoff prompt (moat seam), выбор периода, escalation-в-черновике («Add details»), NL-вход из Ask Leaf («передай коллеге…») и AI-разворачивание входящего handoff'а получателем («Context for me»).

**Не входит** (дальше по треку / backlog): AI-included путь (AI-UI-4), header-bell + счётчик, model picker в handoff-флоу, multi-turn в Ask Leaf, dedicated `message` kind (бэкенд Path B).

## Решения (брейншторм 2026-06-10)

- **Скоуп:** все четыре куска P4 follow-ups — dedicated prompt + escalation-в-черновике + period-picker + NL-вход/AI-pickup.
- **NL intent:** локальный парсер (pure Swift, TDD), без LLM-классификации. EN + RU паттерны, имя — unique match по ростеру.
- **AI-pickup:** «Context for me» — LLM получает текст handoff'а + body-free факты ПОЛУЧАТЕЛЯ; ответ локально, не шлётся обратно. При пустом собственном контексте — POST не уходит вообще (`notEnoughData`).
- **Escalation-в-черновике:** двухступенчато — сначала body-free драфт, затем «Add details (AI)…» → consent-шаг (паттерн EscalationSheet, unchecked) → redraft с телами.
- **Периоды:** reuse `ReviewActivityPeriod` (Today / Yesterday / Last 7 days, дефолт last7) — паритет с Ask Leaf, без новых кейсов.
- **Подход A:** расширение существующих типов (`HandoffDrafter` += seam + escalated), новые pure-типы только там, где логики нет (`HandoffIntentParser`, `InboundHandoffExplainer`). Ноль новых LLM-путей мимо §8.1, ноль миграций, MCP-registry не трогаем.
- **BYOK-only** (паритет AI-UI-1/2; live — за signed-build acceptance gate).

## Архитектура / data flow

```
1) Dedicated prompt (moat seam)
   HandoffPromptMoat { prompts: any HandoffPrompts }
     ├─ .publicSubstrate → PublicHandoffPrompts (текущий handoffInstruction +
     │   public-копии redraft/inbound инструкций; работает, не fail-closed —
     │   промпт не секрет-зависимость)
     └─ #if LEAF_PROD → prodHandoffPromptMoat() из LeafCorePrivate
   AIWiring.handoffPromptMoat() → HandoffDrafter / InboundHandoffExplainer.
   Инструкции проходят policy.makeQuestion (collapse+cap, N-4) — moat меняет
   ТЕКСТ, не дисциплину границы.

2) Period + escalation-в-черновике (SendDirectMessageSheet)
   draftWithAISection += picker (ReviewActivityPeriod) → handoffReader.draft(period:)
   .drafted → «✨ Drafted from N facts» + [Add details (AI)…]
     → HandoffRedraftConsentSheet: кандидаты = ActivityFeedQuery(period драфта),
       unchecked; preview тел = EscalationPreviewBuilder (бит-в-бит send-путь);
       dropped (bucket-1 / без body) видимы, «never sent», не выбираемы
     → [Redraft with K bodies] → HandoffDraftReader.redraft(selectedEventIDs:)
       → gatherSelectedBodiesKeyed → policy.makeEscalation → HandoffDrafter.draft(
         …, escalated:) — audit-first M031 → ОДИН POST (escalated-overload
         Summarizer) → body заменён, provenance.escalated = true
   M032 при send как сейчас (escalated уже в схеме) — миграций НЕТ.

3) NL-вход (Ask Leaf)
   submit → HandoffIntentParser.parse(question, rosterNames)
     hit → Q&A НЕ запускается; в ленте suggestion-entry
       «Create handoff for <Name>?» [Create handoff] [Ask anyway]
     [Create handoff] → SendDirectMessageSheet(recipient:, initialKind: .handoff,
       initialTopic: topic) — sheet локально из AskLeafView
     [Ask anyway] → обычный Q&A (bypass-флаг)

4) AI-pickup (ConversationPane)
   inbound .handoff бабл → «Context for me» → InboundHandoffContextSheet
     → InboundHandoffExplainer.explain(handoffText:senderName:events:)
       ├─ policy.makeContext(МОИ body-free факты, 7д) — пусто → notEnoughData,
       │   POST не уходит
       ├─ policy.makeInboundHandoff(text:) → EscalatedBodies
       │   (authoredByViewer=false labeling, cap) — ЧУЖОЙ текст = data, не инструкции
       └─ audit-first M031 (event_ids=[], source_summary метка inbound handoff)
          → ОДИН POST → ответ in-place, никуда не шлётся
```

## Компоненты

### LeafCore (новое/изменённое, public, TDD)

1. **`AI/HandoffPrompts.swift`** — `protocol HandoffPrompts: Sendable`:
   `draftInstruction(topic:recipientName:)`, `redraftInstruction(topic:recipientName:)` (упоминает included event details), `inboundContextInstruction()`. `struct HandoffPromptMoat { prompts; static publicSubstrate }`; `PublicHandoffPrompts` поглощает текущий `HandoffDrafter.handoffInstruction`.
2. **`AI/HandoffDrafter.swift`** — init += `prompts: any HandoffPrompts = …publicSubstrate.prompts`, `audit: (any AuditSink)? = nil` (тот же протокол, что у `AIDetailAnswerer`); `draft(...)` += `escalated: EscalatedBodies? = nil`. Escalated-путь: audit-first (fail → `.failure`, POST не уходит), escalated-overload `Summarizer`, `provenance.escalated = true`. Body-free путь — поведение бит-в-бит как сейчас.
3. **`AI/HandoffIntentParser.swift`** (pure) — `parse(question:rosterNames:) -> Hit?`, `Hit { recipientName, topic }`. EN-паттерны («hand off to X», «handoff for X», «tell X», …) + RU («передай X», «расскажи X», «хендоф для X», …); имя — unique case/diacritic-insensitive match; неоднозначность / нет матча / нет topic → `nil`.
4. **`AI/InboundHandoffExplainer.swift`** (зеркало `AIDetailAnswerer`) — `explain(handoffText:senderName:events:path:preferred:) async -> Answer` (`.text/.notEnoughData/.failure`). Пустой контекст → `.notEnoughData` ДО аудита и POST.
5. **`Egress/LLMPolicy.makeInboundHandoff(text:) -> EscalatedBodies`** — единственная новая проекция: один `EscalatedBody`, `authoredByViewer = false`, kind-метка inbound handoff, тот же cap что у escalation. Пустой/whitespace текст → пустые bodies.
6. **`AI/HandoffRedraftPick.swift`** (pure state machine, по образцу `EscalationDraft` без question/answer-фаз) — candidates, `selected` (toggle отклоняет dropped/сверх-cap `escalationEventIDCap`), счётчики K-of-N. Если на имплементации `EscalationDraft` реюзается напрямую — берём его, тип не плодим.

### App target (клей, без тестов — прецедент)

7. **`Models/HandoffDraftReader.swift`** — `draft(...)` принимает period из UI (параметр уже есть); новый `redraft(recipientName:topic:period:selectedEventIDs:)`; `.drafted` несёт factCount (есть в provenance) для строки «Drafted from N facts».
8. **`Views/Window/Team/SendDirectMessageSheet.swift`** — period picker в `draftWithAISection`; после `.drafted` — провенанс-строка + [Add details (AI)…] → nested sheet **`HandoffRedraftConsentSheet`** (новый view, визуальный паттерн `EscalationSheet`); `init(initialKind:initialTopic:)` (заодно чинит «Handoff…»-меню из ConversationPane, открывавшее `.ping`).
9. **`Models/AskLeafReader.swift`** — на `ask(...)`: сначала parser (ростер из существующего team-members read); хит → новый transcript-кейс `handoffSuggestion(recipient:topic:)`, Q&A не зовётся; «Ask anyway» → re-ask с bypass.
10. **`Views/Window/AskLeaf/AskLeafView.swift`** — рендер suggestion-entry + `.sheet` с prefilled `SendDirectMessageSheet`. Slack/Linear closures — дефолтные no-ops (cross-post reauth из этой точки недоступен — осознанный трейдофф, send работает).
11. **`Views/Window/Team/Chats/ConversationPane.swift`** — на inbound `.handoff` бабле кнопка/context-menu «Context for me» → **`InboundHandoffContextSheet`** (+ `InboundHandoffContextReader` по образцу `AskLeafReader`): подпись «Sends this message + a body-free summary of your own recent activity to your AI», confirm, ответ in-place.
12. **`Models/AIWiring.swift`** — `handoffPromptMoat()` (`#if LEAF_PROD → prodHandoffPromptMoat()`).

**DI весь локальный** (`@State` в view / существующие environment). `LeafApp.swift`, `RootView.swift` — не трогаем (ноль пересечений с `feature/account-login-phase1`).

### LeafCorePrivate (moat, отдельный коммит в leaf-private)

`prodHandoffPromptMoat()` — dedicated handoff/redraft/inbound промпты (quality = moat). В публичный репо — только seam + public-копии.

## Privacy / §8

- Новых барьеров нет: все три LLM-вызова через `makeContext` + `makeQuestion` + `EscalatedBodies` (конструирует только `LLMPolicy`).
- **Каждый bodies-POST = M031 строка, audit-first** (fail → POST не уходит): redraft и pickup-explain. Body-free драфт — без аудита (паритет P4/Q&A). M032 при send — без изменений, `escalated` теперь бывает true.
- `makeInboundHandoff`: текст коллеги — только как labeled data (`authoredByViewer = false`), capped. Sentinel: инструкция-инъекция в handoff-тексте не попадает в instruction-часть промпта.
- Bucket-1 на redraft-кандидатах дропается в `EscalationPreviewBuilder` (nil → «never sent»); зеркальный sentinel на redraft-путь.
- **Moat-промпты не утекают через audit:** в M031 `question_excerpt` для redraft/pickup — null или фиксированная метка, НЕ текст инструкции (audit читается MCP `get_ai_escalation_log`).
- NL-парсер полностью локальный, нулевой egress.

## Error handling

- `missingAPIKey` → CTA «Open Settings» во всех трёх точках (паритет AI-UI-1/2).
- Redraft: любой fail (audit / сеть) → `.failure`-сообщение, **исходный body-free драфт остаётся в поле**; retry доступен.
- Pickup-explain: opaque ошибки в шите, retry; пустой собственный контекст → «Not enough of your own activity recorded — read the handoff as is», POST не уходит.
- NL: ложный хит безвреден («Ask anyway» в один клик); ложный промах → обычный Q&A.
- Period picker: смена периода после `.drafted` не сбрасывает draft; следующий «Draft with AI» берёт новый период.

## Testing

- **LeafCore (TDD, swift test):**
  - `HandoffPrompts`: public substrate непустой; drafter использует injected prompts (recorder).
  - `HandoffDrafter` escalated: audit-first порядок (audit fail → нет POST), `escalated=true` в provenance, escalated-overload получает ровно выбранные тела, body-free путь не изменился; sentinel bucket-1.
  - `HandoffIntentParser`: EN/RU хиты + topic-извлечение, unique-match (двое с одним именем → nil), пустой ростер → nil, корпус негативных примеров (обычные Q&A-вопросы) → nil.
  - `InboundHandoffExplainer`: labeling, cap, audit-first, injection-sentinel, пустой контекст → notEnoughData без POST и без audit-строки.
  - `LLMPolicy.makeInboundHandoff`: cap, labeling, пустой текст.
  - `HandoffRedraftPick`: toggle-отказы (dropped / сверх cap), счётчики — если не реюзнули `EscalationDraft`.
- **App target:** тест-бандла нет (прецедент) → `xcodebuild -scheme Leaf` + manual smoke: golden (period → draft → Add details → consent → redraft → send → строки в «AI received» и «AI handoffs»), NL-хит → sheet prefilled, «Ask anyway», pickup → Context for me, без ключа → CTA. Имена в тестах — Alice/Eve/Alex (leak-guard).
- **Гейты:** `just preflight` (R1) + зелёный CI на PR (parsed per-check conclusions, не `--watch` exit-код); `/pre-push-leaf` перед push (R2); moat-коммит в leaf-private отдельно.

## Конфликты с параллельной работой

- `feature/account-login-phase1` (Антон): `LeafApp.swift` / `RootView.swift` / `Leaf/Auth/*` — **не трогаем** (DI локальный).
- `SendDirectMessageSheet` / `ConversationPane` / `AskLeafView` — вне его ветки; Team Hub (#56) уже в dev-базе этой ветки.
