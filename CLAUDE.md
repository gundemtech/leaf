# LeafControl — общий контекст проекта

Этот файл читается Claude Code в начале каждой сессии у каждого разработчика команды.
Ниже подгружаются общие заметки (shared memory).

@.claude/shared/architecture.md
@.claude/shared/conventions.md
@.claude/shared/current-state.md
@.claude/shared/glossary.md

## Правила работы команды

- Язык общения: русский.
- Задачи ведём в Linear, проект `Leaf`. Есть Linear MCP — читай/создавай issue через него.
- Второй мозг команды живёт в Linear Docs проекта `Leaf`:
  - **Session Log** — append-only журнал саммари сессий
  - **Architecture Decisions** — устойчивые тех-решения
  - **Conventions** — командные соглашения (процесс, не код)
  - **Ideas & Principles** — выжимка идей/принципов из сессий
- Сохранение сессии — слеш-командой `/save-session` (см. `.claude/commands/save-session.md`).
- Личная auto-memory каждого разработчика остаётся локально в `~/.claude/` и в репо **не** попадает.
- **Shared memory дисциплина:** файлы `.claude/shared/*.md` грузятся в контекст каждой сессии — держим компактно (каждый ≤ 200 строк, только "текущий срез", без истории). Ревизия: `/audit-brain`. Обоснование: ADR-004 в Linear.
