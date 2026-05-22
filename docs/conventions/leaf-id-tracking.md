# Convention: LEAF-NN tracking — Linear ↔ GitHub ↔ Slack

**Author:** Dmitrii · **Date:** 2026-05-22 · **Status:** active (применяется со следующей phase)

Этот документ описывает дисциплину работы для **обоих разработчиков** (Дмитрий + Антон) чтобы substrate Leaf реально начал ловить cross-provider связи в данных. Сейчас данные показывают **0 cross-source links за 7 дней** — `LinearIDExtractor` ничего не находит потому что commits используют внутренний `track-XX-TY` naming.

---

## TL;DR — Один Linear LEAF issue = одна phase/track

Без LEAF-NN reference в commit subject substrate не может связать GitHub commit с Linear issue. Все наши Track-9 / Track-10 / etc. имена — внутреннее phase coding которое regex `[A-Z][A-Z0-9]{1,4}-\d+` + whitelist `["LEAF"]` не матчит.

**Минимально:** добавить `LEAF-NN` в branch name + commit subject. Maximum effort: integrate Linear status changes на phase start/ship.

---

## 5-шаговый рецепт на каждую phase

### 1. Перед началом phase — создаём Linear issue

В Linear UI (project `Leaf`):

- **Title:** `Track-10 T2.5 — operational follow-up (post-T3 smoke)` (внутреннее name остаётся)
- **State:** `Backlog` → переключи в `Todo` когда планируем, потом `In Progress` когда стартуем
- **Description:** 1-2 предложения "что и зачем" + ссылка на спек если есть
- **Label:** один из `модули / дизайн / сервер / сайт / функции` per `/linear-task` convention
- **Priority:** Medium для большинства; Urgent — только когда блокирует ship

Linear выдаёт ID автоматом: `LEAF-NNN`.

### 2. Дай Claude Code `LEAF-NN` в первом сообщении сессии

Шаблон первого сообщения новой Claude-сессии:

```
Делаем LEAF-323 (Track-10 T2.5). Спек: docs/superpowers/specs/...
Идём по 8-этапному workflow per conventions.md "Одна phase = одна сессия".
```

Claude помнит `LEAF-323` весь session и проставит в branches / commits / spec headers.

### 3. Branch naming с LEAF prefix

| Было | Стало |
|---|---|
| `feature/track-10-T2-5-operational-followup` | `feature/LEAF-323-track-10-T2-5-operational-followup` |
| `fix/dev-launch-reliability` | `fix/LEAF-318-dev-launch-reliability` |

LEAF-NN всегда сразу после `feature/` / `fix/`. Track-NN-TM внутреннее имя сохраняется для контекста (помогает читать `git log`).

### 4. Commits — LEAF-NN в subject (обязательно)

| Было | Стало |
|---|---|
| `fix(track-10-T2-5): RESUME hero — fence blank-shell` | `fix(LEAF-323): RESUME hero — fence blank-shell` |
| `docs(track-10-T2-5): SHIPPED — phase spec landing` | `docs(LEAF-323): SHIPPED — Track-10 T2.5 phase spec landing` |
| `feat(track-9-T7): WhereStoppedDeriver substrate` | `feat(LEAF-310): WhereStoppedDeriver substrate (Track-9 T7)` |

**Что substrate из этого вытащит:**

- `gh_commit_pushed` event → `LinearIDExtractor` находит `LEAF-323` в commit subject → пишет `payload.linked_linear_id = "LEAF-323"`
- `get_cross_provider_thread(LEAF-323)` возвращает chronological timeline: Linear creation → branch → 5 commits → PR opened → reviews → status_transition Done
- RESUME card (Home) открывает `linearID` line: "LEAF-323 · feature/LEAF-323-..." + Linear CTA button работает (URL `linear.app/<slug>/issue/LEAF-323`)
- TODAY pill "Linear" (action-noun) растёт — issues completed counter

### 5. На SHIPPED — переключаем Linear в Done

Когда `docs(LEAF-NN): SHIPPED` коммит landed:

- В Linear UI: status `In Progress → Done`
- Substrate ловит `status_transition` event с `to_state_type: "completed"` → Today metrics counter увеличивается
- Если Claude Code сессия имеет Linear write access — автоматизируем (на момент 2026-05-22 у Claude только read-only)

---

## Slack — когда подключать

Slack пока пустой. Substrate ловит:

- `slack_message_authored_aggregate` (counts only, no body per ADR-010)
- `slack_status_change` (custom emoji transitions)
- `slack_canvas_*` / `slack_bookmark_*` (titles only, no body)
- Reactions count + huddle minutes

**Если начнёте использовать Slack для async между собой:**

- В сообщениях упоминайте `LEAF-NN` когда обсуждаете phase
- Substrate автоматом найдёт LEAF-NN в slack_canvas / bookmark titles (LinearIDExtractor применяется)
- `huddleMinutes` начнёт расти → попадёт в Today / Analytics

**Claude Code может постить в Slack от твоего имени** (есть Slack MCP — `slack_send_message`). Например, "Phase LEAF-323 SHIPPED, branch merged". Только по явной команде — не без спроса.

---

## Командная convention (Дмитрий + Антон)

### Перед началом phase

Один из вас создаёт Linear issue с LEAF-NN. Другой не стартует параллельную phase которая может пересечь те же файлы — стандартная coordination (см. `.claude/shared/conventions.md` "Работа вдвоём").

### Имя driver и Linear assignee

Кто phase делает = Linear assignee. Если коллега должен дать review / answer / handoff — `leaf_ask_question(to: ...)` или Linear comment.

### Branch protection (когда добавите в leaf-репо)

PR title должен матчить regex `LEAF-\d+`. Без LEAF-NN PR не merge'ится в `main`. Это окончательно closes the loop — никто не сможет случайно landed commit без Linear reference.

Можно добавить через GitHub Actions / GitHub branch protection rules. Carry для future setup phase.

---

## Что substrate автоматом включится после 2-3 phase под convention

| Сейчас | После convention |
|---|---|
| `get_cross_provider_thread(LEAF-NN)` → empty events | → chronological timeline Linear → GitHub commits → PR → review → merged → Linear Done |
| `leaf_query_activity` → `links: []` | → non-empty links graph |
| RESUME card → branch + WIP only | → `LEAF-NN · branch` + Linear CTA enabled |
| TODAY pill Linear → 1 (только GUN-31 случайно) | → растёт с каждой phase Done |
| Detector pipeline → `decisions/blockers/questions: []` | → должно начать наполняться (требует separate investigation почему пусто сейчас) |

---

## Carry — substrate enhancements которые добавим позже

1. **Branch-name LEAF extraction** — сейчас LinearIDExtractor применяется только к commit subjects / PR titles / Slack canvas titles. Branch names не парсятся. Если бы парсились — `feature/LEAF-323-...` → events автотегаются даже без LEAF-NN в commit subject.

2. **AI session ↔ Linear auto-link** — самое ценное для нашего workflow. Когда Claude Code сессия идёт в `~/leaf` и есть active "In Progress" Linear issue (через `presence_state.linear.assignedIssues`), substrate автоматом тегал бы AI events с `linked_linear_id`. Не требует ничего от пользователя.

3. **Browser URL ↔ Linear/GitHub** — когда читаешь `github.com/.../pull/256` в Safari, browser collector мог бы дёрнуть LinearIDExtractor на URL и линковать. Сейчас URL живёт в attention payload без extraction.

4. **DetectorPipeline activation check** — отдельный investigation: за 7 дней 0 decisions / blockers / open_questions / event_links. Substrate готов (Track-1 D3), но runtime registration или body capture может быть на carry. Когда заработает — substrate начнёт ещё богаче связывать события.

5. **LinearIDExtractor multi-prefix** — сейчас whitelist хардкод `["LEAF"]`. Phase 4.7.A spec упоминает "v1.1 — pull live workspace prefix set from Linear (`LinearIDPrefixCache`)". Когда landed — другие workspace prefixes (`GUN`, etc.) тоже будут работать.

---

## Ретроактивно — что делать со старыми Track / Phase

**Не amend'им уже опубликованные commits** (Track-9 / Track-10 T1-T3 + старые). Слишком много истории, сломает GitHub PR refs.

**Опционально:** в whitepaper changelog (`leaf-docs/docs/05-reference/changelog.md`) добавить mapping таблицу:

| Linear | Track / Phase | Date | Driver |
|---|---|---|---|
| `LEAF-301` | Track-9 T1..T10 — substrate enrichment | 2026-05-19..21 | Dmitrii |
| `LEAF-310` | Track-10 T1 — foundation | 2026-05-22 | Dmitrii |
| `LEAF-311` | Track-10 T2 — RESUME hero | 2026-05-22 | Dmitrii |
| `LEAF-312` | Track-10 T3 — YOU·NOW badge | 2026-05-22 | Dmitrii |
| `LEAF-323` | Track-10 T2.5 — operational follow-up | 2026-05-22 | Dmitrii |

(Номера примерные — реальные присваивает Linear когда создашь issues.)

Это дает retroactive linkage без перепись истории.

---

## Что сделать прямо сейчас

1. **Дмитрий** — создаёт Linear issue `LEAF-NNN — "Convention: LEAF-NN tracking — Linear ↔ GitHub ↔ Slack adoption"` (этот документ как описание/attachment). Priority Medium, Label `функции`.

2. **Антон** — читает этот документ, подтверждает understanding. Со следующей phase обоих — LEAF-NN в commits.

3. **Со следующей phase** — обоим следуем 5-шагу выше. После 2-3 phase под новой дисциплиной вернёмся к этому substrate-картина и сравним: `links: []` vs `links: [...]`.

4. **Опционально** — Дмитрий retroactively rebase 3 commit'а T2.5 (`51f747f4`, `7552a33f`, `b65be6d1`) с reword: `fix(track-10-T2-5): ...` → `fix(LEAF-NNN, track-10-T2-5): ...`. Тогда RESUME card сразу покажет LEAF-NNN line после rebuild + Linear CTA enabled. Это **тестовый прогон** convention на конкретной phase.

---

## Ссылки

- `Phase 4.7.A` — LinearIDExtractor implementation
- `get_cross_provider_thread` — MCP tool для timeline по LEAF-NN
- `.claude/shared/conventions.md` — общая team convention (8-stage phase workflow / shared memory discipline)
- `/linear-task` — slash command для генерации Linear issue text
- ADR-010 — privacy discipline (никаких bodies в LinearID extraction surface)
