# AI-UI-2 — Escalation-модалка + Privacy-ленты (design)

_Дата: 2026-06-10. Фаза 2 трека «in-app AI surface» (трек — `.claude/plans/ai-ui-track.md`, local-only; backlog-источник — `ai-coworker-backlog.md` §P3/P4 follow-ups). Ветка: `feature/ai-ui-2-escalation-privacy` → PR в `dev`. Спек предыдущей фазы — `2026-06-10-ai-ui-1-ask-leaf-design.md`._

## Цель

In-app поверхность bodies-эскалации (P3-путь, до сих пор только MCP `escalate_to_ai`) + прозрачность: модалка «ИИ просит тела N событий» с честным consent-preview и две Privacy-ленты — «AI received» (`ai_escalation_audit`, M031) и «AI handoffs» (`handoff_audit`, M032) — в Settings → Sharing. Попутно оживляем Activity → Raw events (источник entries выпилен в IV.A.2, режим показывает пустоту) — он же кормит модалку кандидатами.

**Не входит** (следующие фазы / follow-ups): escalation-в-черновике handoff (AI-UI-3), AI-included путь (AI-UI-4), array-body kinds / detector-excerpt-by-id / per-source forward-deny (P3 backlog), новые MCP tools, миграции.

## Решения (брейншторм 2026-06-10)

- **Две точки входа:** Activity multi-select («Analyze with AI (N)») и Ask Leaf «Dig deeper» на answered-entry (period-режим).
- **Ответ — в самой модалке** (self-contained flow: preview → confirm → answer; одинаково из обеих точек).
- **Consent-preview:** счётчики «Will send K of N» + список событий; каждое раскрывается до **точного** capped-текста (результат `LLMPolicy.makeEscalation` — ровно то, что уйдёт). Dropped (bucket-1 / без body) видимы, помечены «never sent», не выбираемы.
- **Ленты:** Settings → Sharing, секция «AI privacy» (семантика таба — «что покидает устройство»).
- **Подход A** — тонкие reader'ы по паттерну AI-UI-1; оркестрация и audit-first — существующий `AIDetailAnswerer`, ноль новых LLM-путей.
- **Activity raw-events оживляем в этой фазе** (`ActivityFeedQuery` — общий источник для Activity и period-режима модалки).
- **Checked-default:** ids-режим (из Activity) — переданные события pre-checked (юзер их уже выбрал); period-режим (из Ask Leaf) — unchecked (consent = активный выбор).
- **BYOK-only** (паритет с AI-UI-1; AI-included — AI-UI-4).

## Архитектура / data flow

```
Activity (Raw events — оживлён)            Ask Leaf (answered entry)
  чекбоксы → «Analyze with AI (N)»           кнопка «Dig deeper» (entry.period)
        └────────────┬──────────────────────────────┘
                     v
        EscalationSheet (одна модалка; seed: .ids([entry]) | .period(p))
          └─ EscalationReader (@MainActor @Observable, app)
               ├─ кандидаты: ActivityFeedQuery (LeafCore) — fetch + ActivityFeedMapper + coalesce
               ├─ preview:   WorkFactGatherer.gatherSelectedBodiesKeyed + EscalationPreviewBuilder
               │             (pure makeEscalation per-event; ЛОКАЛЬНО, без egress, без аудита)
               └─ confirm:   AIDetailAnswerer.answer(question, eventIDs, selectedEvents, .byok, model)
                               ↑ существующий: audit-first → ai_escalation_audit → один POST
                             ответ — in-place в модалке

Settings → Sharing → «AI privacy»
  └─ AIPrivacyFeedsReader → db.recentAIEscalationAudit / recentHandoffAudit (read-API уже есть)
       └─ AIPrivacyFeedPresentation (LeafCore, pure) — формат строк + резолв имени получателя
```

## Компоненты

### LeafCore (новое, public, TDD)

1. **`Insights/ActivityFeedQuery.swift`** — единственный новый DB-read: `SELECT id, ts, signal_type, bundle_id, payload_json FROM events WHERE ts BETWEEN ? AND ? ORDER BY ts DESC LIMIT ~500` → существующий `ActivityFeedMapper.map` → `coalesceConsecutive`. Параметризован `DateInterval`. Reader-safe (`readSQL`).
2. **`WorkFactGatherer.gatherSelectedBodiesKeyed(eventIDs:) -> [(id: Int64, event: EgressEvent)]`** — keyed-вариант `gatherSelectedBodies` (тот же SQL, кап `escalationEventIDCap`); старый метод делегирует на новый (поведение бит-в-бит). Нужен потому, что `EgressEvent` не несёт id, а preview маппит «что уйдёт» на строки.
3. **`AI/EscalationPreviewBuilder.swift`** (pure) — per-event `policy.makeEscalation(selected: [e])` → `[Int64: EscalatedBody?]`; `nil` = dropped (bucket-1 / нет body). Даёт «K из N» и точный capped-текст под disclosure. Переиспользование чистой проекции, не новый путь через границу.
4. **`AI/EscalationDraft.swift`** (pure state machine, зеркало `AskLeafTranscript`): candidates (id + display-метаданные), `selected: Set<Int64>` (toggle отклоняется для dropped и сверх капа), question, model, `phase: .composing → .sending → .answered(String) | .failed(String)`; single-flight; производные counts (N selected / K sendable).
5. **Promotion `DBEscalationAuditSink`: LeafMCP → `LeafCore/DB`** — апке нужен тот же sink (прецедент app-записи — `HandoffAuditWriter`); LeafMCP переходит на LeafCore-тип, файл в LeafMCP удаляется. Поведение неизменно.
6. **`AI/AIPrivacyFeedPresentation.swift`** (pure, по образцу `TeamFeedPresentation`) — строки двух лент из `AIEscalationAuditStore.AuditEntryView` / `HandoffAuditStore.AuditEntryView` + `[TeamMember]`: дата, model/path, счётчики (event ids / facts), question/topic excerpt, имя получателя (резолв по `recipientMemberID`, fallback «Former teammate»), флаги crosspost.

### App target (клей, без тестов — прецедент)

7. **`Models/ActivityFeedReader.swift`** — @MainActor @Observable; state loading/empty/error/loaded(`[ActivityFeedEntry]`); fetch через `ActivityFeedQuery` off-main (`Task.detached`, по образцу `AskLeafReader`); период «сегодня» для Activity-экрана.
8. **`ActivityView` re-wire** — rawEventsContent читает `ActivityFeedReader` вместо `entries = []`; filter-счётчики становятся живыми; `@State selected: Set<Int64>` + чекбокс в строке + action bar «Analyze with AI (N)» (N>0) → sheet. Выбор сверх 50 блокируется с подсказкой.
9. **`Models/EscalationReader.swift`** — зеркало `AskLeafReader`: lazy bootstrap через `AIWiring` (policy/summarizerMoat/modelGateMoat/db*); держит `EscalationDraft`; `loadCandidates(seed:)`, `togglе`, `confirm()` (создаёт `AIDetailAnswerer` c `DBEscalationAuditSink`).
10. **`Views/Window/Escalation/EscalationSheet.swift`** — `LeafSheetLayout` (общая для обеих точек входа); header-счётчик, список кандидатов (чекбокс, иконка kind/provider, primary text, время; dropped — серый бейдж «never sent»; disclosure → точный текст из preview), question (TextField), model picker (haiku/sonnet/opus, дефолт haiku), Confirm «Send K bodies» (disabled при K=0 или пустом question), Cancel; после confirm — progress → ответ in-place (selectable) → Done. Seed: `.ids([ActivityFeedEntry])` | `.period(ReviewActivityPeriod, prefillQuestion: String?)`.
11. **`AskLeafView`** — кнопка «Dig deeper» на answered-entry → `.sheet` с seed `.period(entry.period, prefillQuestion: entry.question)` (вопрос редактируемый).
12. **`Views/Window/Settings/AIPrivacySection.swift`** + **`Models/AIPrivacyFeedsReader.swift`** — секция в Sharing-табе после `PrivacySettingsSection`; два блока «AI received» / «AI handoffs», limit 50 newest, empty-states; refresh on appear.

**DI весь локальный (`@State` в view).** `LeafApp.swift`, `RootView.swift`, `LeafAgent/Agent.swift`, `SendDirectMessageSheet.swift` — не трогаем (ноль пересечений с `feature/account-login-phase1`).

## Privacy / §8

- Preview = локальный DB-read + чистая проекция `makeEscalation` — **не egress, аудит не пишется** (§8 п.4: audit = акт egress, over-record never under-record не нарушен — записывается каждый фактический POST).
- Единственный egress = confirm через неизменённый `AIDetailAnswerer`: audit-first (fail → send aborts), bucket-1 drop + cap внутри `makeEscalation`, prompt-injection дисциплина (`authoredByViewer` labeling) — как в MCP-пути.
- Кап выбора = `escalationEventIDCap` (50), enforce и в UI, и (как раньше) в gatherer.
- Ленты показывают только metadata/refs/собственные excerpts — тел в таблицах структурно нет (M032 sentinel-тест); экран не добавляет новых чтений payload'ов.
- Ключ BYOK не логируется и не эхо-ится (ошибки `AIDetailAnswerer` уже opaque).

## Error handling

- `missingAPIKey` → сообщение + CTA «Open Settings» (`WindowState.section = .settings`, паритет с Ask Leaf).
- K=0 (всё dropped) → Confirm disabled + подпись «These events have no text that can be sent» — notEnoughData не достижим по кнопке.
- Сеть / auth / rate-limit → opaque message в модалке (`.failed`), Confirm снова активен (retry с тем же draft).
- Ошибка чтения кандидатов/preview → inline error + Try again (паттерн `LeafBanner` из ActivityView).
- Ленты: ошибка чтения → компактный inline error, не баннер на весь Settings.

## Testing

- **LeafCore (TDD, swift test):** `ActivityFeedQuery` (in-memory DB: границы периода, ordering, cap, skip-kinds через mapper), `gatherSelectedBodiesKeyed` (паритет со старым методом, кап, bundle_id carry), `EscalationPreviewBuilder` (bucket-1 drop → nil, cap 2000, authoredByViewer), `EscalationDraft` (фазы, single-flight, toggle-отказы: dropped / сверх капа, counts), `AIPrivacyFeedPresentation` (резолв имени, fallback, форматирование обоих типов строк).
- **Sentinel:** preview-путь не выдаёт bucket-1 текст (зеркало `EscalationEgressLeakageTests` — personal-app/DM события дают `nil` в preview-карте).
- **App target:** тест-бандла нет (прецедент) → `xcodebuild -scheme Leaf` + manual smoke: golden path (Activity select → preview → раскрыть тело → confirm → ответ → строка в «AI received»), edge (без ключа → CTA; всё dropped → Confirm disabled; «Dig deeper» из Ask Leaf; handoff → строка в «AI handoffs»).
- **Гейты:** `just preflight` (R1) + зелёный CI на PR (parsed conclusions, не `--watch` exit-0); leak-guard (R2). Имена в тестах — плейсхолдеры (Alice/Eve).

## Конфликты с параллельной работой

- `feature/account-login-phase1` (Антон) переписывает `LeafApp.swift` / `RootView.swift` / `LeafAgent/Agent.swift` / `Leaf/Auth/*` — мы эти файлы **не трогаем** (DI локальный).
- `SendDirectMessageSheet` (его же недавние правки в dev) — не трогаем; escalation-в-черновике — AI-UI-3.
- Activity/AskLeaf/Settings-Sharing — вне его ветки.
