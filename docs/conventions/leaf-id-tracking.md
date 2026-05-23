# Convention: GUN-NN tracking — Linear ↔ GitHub ↔ Slack

**Author:** Dmitrii · **Date:** 2026-05-22 (updated 2026-05-23) · **Status:** active

Этот документ описывает дисциплину работы для **обоих разработчиков** (Дмитрий + Антон) чтобы substrate Leaf реально начал ловить cross-provider связи в данных. Сейчас данные показывают **0 cross-source links за 7 дней** — `LinearIDExtractor` ничего не находит потому что commits используют внутренний `track-XX-TY` naming.

> **Workspace prefix.** Наш реальный Linear workspace — `GUN-` (gundemtech). Convention изначально писалась под placeholder `LEAF-`; substrate `LinearIDExtractor` whitelist всё ещё хардкодит `["LEAF"]` (см. carry §5) — значит GUN-NN в commits **не** auto-link'аются substrate'ом до тех пор пока multi-prefix patch не landed. Human cross-ref в Linear UI работает уже сейчас, substrate-auto-link — позже.

---

## TL;DR — Один Linear GUN issue = одна phase/track

Без `GUN-NN` reference в commit subject substrate не может (пока) связать GitHub commit с Linear issue. Все наши Track-9 / Track-10 / etc. имена — внутреннее phase coding которое regex `[A-Z][A-Z0-9]{1,4}-\d+` матчит, но prefix whitelist `["LEAF"]` отбрасывает.

**Минимально:** добавить `GUN-NN` в branch name + commit subject. Substrate auto-link включится автоматом когда LinearIDExtractor whitelist расширится (carry §5). Maximum effort: integrate Linear status changes на phase start/ship.

---

## 5-шаговый рецепт на каждую phase

### 1. Перед началом phase — создаём Linear issue

В Linear UI (project `Leaf`):

- **Title:** `Track-10 T5 — SINCE YOU WERE LAST ACTIVE` (внутреннее name остаётся)
- **State:** `Backlog` → переключи в `Todo` когда планируем, потом `In Progress` когда стартуем
- **Description:** 1-2 предложения "что и зачем" + ссылка на спек если есть
- **Label:** один из `модули / дизайн / сервер / сайт / функции` per `/linear-task` convention
- **Priority:** Medium для большинства; Urgent — только когда блокирует ship

Linear выдаёт ID автоматом: `GUN-NN`.

### 2. Дай Claude Code `GUN-NN` в первом сообщении сессии

Шаблон первого сообщения новой Claude-сессии:

```
Делаем GUN-47 (Track-10 T5). Спек: docs/superpowers/specs/...
Идём по 8-этапному workflow per conventions.md "Одна phase = одна сессия".
```

Claude помнит `GUN-47` весь session и проставит в branches / commits / spec headers.

### 3. Branch naming с GUN prefix

| Было | Стало |
|---|---|
| `feature/track-10-T5-since-last-active` | `feature/GUN-47-track-10-T5-since-last-active` |
| `fix/dev-launch-reliability` | `fix/GUN-NN-dev-launch-reliability` |

GUN-NN всегда сразу после `feature/` / `fix/`. Track-NN-TM внутреннее имя сохраняется для контекста (помогает читать `git log`).

### 4. Commits — GUN-NN в subject (обязательно)

| Было | Стало |
|---|---|
| `fix(track-10-T2-5): RESUME hero — fence blank-shell` | `fix(GUN-NN): RESUME hero — fence blank-shell` |
| `docs(track-10-T5): SHIPPED — phase spec landing` | `docs(GUN-47): SHIPPED — Track-10 T5 phase spec landing` |
| `feat(track-9-T7): WhereStoppedDeriver substrate` | `feat(GUN-NN): WhereStoppedDeriver substrate (Track-9 T7)` |

**Что substrate из этого вытащит (когда whitelist расширится — см. carry §5):**

- `gh_commit_pushed` event → `LinearIDExtractor` находит `GUN-47` в commit subject → пишет `payload.linked_linear_id = "GUN-47"`
- `get_cross_provider_thread(GUN-47)` возвращает chronological timeline: Linear creation → branch → 5 commits → PR opened → reviews → status_transition Done
- RESUME card (Home) открывает `linearID` line: "GUN-47 · feature/GUN-47-..." + Linear CTA button работает (URL `linear.app/<slug>/issue/GUN-47`)
- TODAY pill "Linear" (action-noun) растёт — issues completed counter

**До whitelist patch:** payload `linked_linear_id` остаётся nil для GUN-NN, но human cross-ref в Linear UI / branch name / commit subject полностью работают.

### 5. На SHIPPED — переключаем Linear в Done

Когда `docs(GUN-NN): SHIPPED` коммит landed:

- В Linear UI: status `In Progress → Done`
- Substrate ловит `status_transition` event с `to_state_type: "completed"` → Today metrics counter увеличивается (это уже работает — status_transition не зависит от LinearIDExtractor whitelist)
- Если Claude Code сессия имеет Linear write access — автоматизируем (на момент 2026-05-23 у Claude только read-only)

---

## Slack — когда подключать

Slack пока пустой. Substrate ловит:

- `slack_message_authored_aggregate` (counts only, no body per ADR-010)
- `slack_status_change` (custom emoji transitions)
- `slack_canvas_*` / `slack_bookmark_*` (titles only, no body)
- Reactions count + huddle minutes

**Если начнёте использовать Slack для async между собой:**

- В сообщениях упоминайте `GUN-NN` когда обсуждаете phase
- Substrate автоматом найдёт GUN-NN в slack_canvas / bookmark titles **после** LinearIDExtractor whitelist patch (carry §5)
- `huddleMinutes` начнёт расти → попадёт в Today / Analytics

**Claude Code может постить в Slack от твоего имени** (есть Slack MCP — `slack_send_message`). Например, "Phase GUN-47 SHIPPED, branch merged". Только по явной команде — не без спроса.

---

## Командная convention (Дмитрий + Антон)

### Перед началом phase

Один из вас создаёт Linear issue с GUN-NN. Другой не стартует параллельную phase которая может пересечь те же файлы — стандартная coordination (см. `.claude/shared/conventions.md` "Работа вдвоём").

### Имя driver и Linear assignee

Кто phase делает = Linear assignee. Если коллега должен дать review / answer / handoff — `leaf_ask_question(to: ...)` или Linear comment.

### Branch protection (когда добавите в leaf-репо)

PR title должен матчить regex `GUN-\d+`. Без GUN-NN PR не merge'ится в `main`. Это окончательно closes the loop — никто не сможет случайно landed commit без Linear reference.

Можно добавить через GitHub Actions / GitHub branch protection rules. Carry для future setup phase.

---

## Что substrate автоматом включится после 2-3 phase под convention + whitelist patch

| Сейчас | После convention + whitelist patch |
|---|---|
| `get_cross_provider_thread(GUN-NN)` → empty events | → chronological timeline Linear → GitHub commits → PR → review → merged → Linear Done |
| `leaf_query_activity` → `links: []` | → non-empty links graph |
| RESUME card → branch + WIP only | → `GUN-NN · branch` + Linear CTA enabled |
| TODAY pill Linear → 1 (только GUN-31 случайно) | → растёт с каждой phase Done |
| Detector pipeline → `decisions/blockers/questions: []` | → должно начать наполняться (требует separate investigation почему пусто сейчас) |

---

## Carry — substrate enhancements которые добавим позже

1. **Branch-name GUN extraction** — сейчас LinearIDExtractor применяется только к commit subjects / PR titles / Slack canvas titles. Branch names не парсятся. Если бы парсились — `feature/GUN-47-...` → events автотегаются даже без GUN-NN в commit subject.

2. **AI session ↔ Linear auto-link** — самое ценное для нашего workflow. Когда Claude Code сессия идёт в `~/leaf` и есть active "In Progress" Linear issue (через `presence_state.linear.assignedIssues`), substrate автоматом тегал бы AI events с `linked_linear_id`. Не требует ничего от пользователя.

3. **Browser URL ↔ Linear/GitHub** — когда читаешь `github.com/.../pull/256` в Safari, browser collector мог бы дёрнуть LinearIDExtractor на URL и линковать. Сейчас URL живёт в attention payload без extraction.

4. **DetectorPipeline activation check** — отдельный investigation: за 7 дней 0 decisions / blockers / open_questions / event_links. Substrate готов (Track-1 D3), но runtime registration или body capture может быть на carry. Когда заработает — substrate начнёт ещё богаче связывать события.

5. **LinearIDExtractor multi-prefix — blocker для всего вышеперечисленного** — сейчас whitelist хардкод `["LEAF"]`, наш реальный workspace `GUN-` substrate-blind. Phase 4.7.A spec упоминает "v1.1 — pull live workspace prefix set from Linear (`LinearIDPrefixCache`)". Минимальный fix — bump whitelist до `["LEAF", "GUN"]`; правильный — динамически читать из `presence_state.linear.workspace_slug` / `viewer.organization.urlKey`. Отдельная post-Track-10 phase.

---

## Ретроактивно — что делать со старыми Track / Phase

**Не amend'им уже опубликованные commits** (Track-9 / Track-10 T1-T4 + старые). Слишком много истории, сломает GitHub PR refs.

**Опционально:** в whitepaper changelog (`leaf-docs/docs/05-reference/changelog.md`) добавить mapping таблицу:

| Linear | Track / Phase | Date | Driver |
|---|---|---|---|
| `GUN-NN` | Track-9 T1..T10 — substrate enrichment | 2026-05-19..21 | Dmitrii |
| `GUN-NN` | Track-10 T1 — foundation | 2026-05-22 | Dmitrii |
| `GUN-NN` | Track-10 T2 — RESUME hero | 2026-05-22 | Dmitrii |
| `GUN-NN` | Track-10 T3 — YOU·NOW badge | 2026-05-22 | Dmitrii |
| `GUN-NN` | Track-10 T2.5 — operational follow-up | 2026-05-22 | Dmitrii |
| `GUN-NN` | Track-10 T4 — NEEDS YOU rename | 2026-05-22 | Dmitrii |
| `GUN-47` | Track-10 T5 — SINCE YOU WERE LAST ACTIVE | 2026-05-23 | Dmitrii |

(Номера примерные — реальные присваивает Linear когда создашь issues. GUN-47 = реальный.)

Это дает retroactive linkage без переписи истории.

---

## Что сделать прямо сейчас

1. **Дмитрий** — создаёт Linear issue `GUN-NN — "Convention: GUN-NN tracking — Linear ↔ GitHub ↔ Slack adoption"` (этот документ как описание/attachment). Priority Medium, Label `функции`.

2. **Антон** — читает этот документ, подтверждает understanding. Со следующей phase обоих — GUN-NN в commits.

3. **Со следующей phase** — обоим следуем 5-шагу выше. После 2-3 phase под новой дисциплиной вернёмся к substrate-картине и сравним: `links: []` vs `links: [...]`.

4. **Параллельно** — отдельной post-Track-10 phase landing carry §5 (LinearIDExtractor multi-prefix patch). Без него substrate auto-link для GUN-NN не заработает; convention пока даёт только human cross-ref discipline.

---

## Ссылки

- `Phase 4.7.A` — LinearIDExtractor implementation
- `get_cross_provider_thread` — MCP tool для timeline по GUN-NN
- `.claude/shared/conventions.md` — общая team convention (8-stage phase workflow / shared memory discipline)
- `/linear-task` — slash command для генерации Linear issue text
- ADR-010 — privacy discipline (никаких bodies в LinearID extraction surface)
