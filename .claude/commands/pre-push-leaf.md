---
description: Проверка diff перед пушем в публичный app-репо gundemtech/leaf — фильтр implementation moat
---

# /pre-push-leaf

Ручная проверка diff перед `git push` в публичный app-репо `gundemtech/leaf`. Цель — не допустить утечки implementation moat в публичный код.

## Когда запускать

**Перед каждым `git push origin main` (или на feature-branch) в `gundemtech/leaf`.** Если не уверен — запускай всегда.

## Алгоритм

1. **Определи, что будет запушено:**
   ```bash
   cd /Users/ddemidov/Desktop/LeafControl   # или где клон leaf
   git log origin/main..HEAD --oneline       # коммиты к пушу
   git diff origin/main..HEAD                # полный diff
   ```
   Если пуш не в `main` — сравни с base-веткой.

2. **Пройди diff по чек-листу (см. корневой `CLAUDE.md`, раздел "Pre-push чек-лист").** Конкретно ищи:

   ### Критичное (обязательно блокируем push)
   - **Секреты в коде/configs:** строки формата `sk-...`, `ghp_...`, `cf_...`, `-----BEGIN PRIVATE KEY-----`, base64-encoded длинные строки в commit, .env значения.
   - **SQL-запросы Derived Insights Engine** — тела функций `timeInApp`, `focusSessions`, `contextSwitchRate`, `teamPresenceOverlap`, `aiRatio`, `deepWorkStreak`, `peakProductivityHour`, `weekOverWeekDelta`, `filesTouched`, `lastSeenFile`, `currentPresence`, `teamCurrentPresence`. Сигнатуры — ок, тела — нет.
   - **SQLCipher pragma значения** (конкретные числа): `cipher_plaintext_header_size=...`, `busy_timeout=...`, KDF params, salt generation.
   - **Cloudflare Worker код** — не должен быть здесь вообще, он в `gundemtech/leaf-relay`.
   - **Crypto envelope byte layout**, exact nonce generation, HKDF info strings, AAD content.
   - **Git polling command** (exact `git log --format=...`), Claude Code hooks JSON parser.

   ### Высокий риск (показать юзеру, пусть решит)
   - **Точные пороги и числа:** idle threshold seconds, polling intervals (5 мин Linear, git polling), heartbeat (60с), WAL checkpoint (15 мин / 4MB), hardcoded delays.
   - **Share Controls preset bundle IDs** — список "common dev defaults" хардкодом.
   - **TODO/FIXME с внутренним контекстом** ("hack because Linear quirk", "Anton asked", "for customer X").
   - **Коммит-сообщения и PR descriptions** с именами сотрудников, ship dates, клиентскими деталями, competitive intel.

   ### Низкий риск (ок, но пометь)
   - Неочевидные implementation patterns без публичного обоснования.
   - Отсутствие ссылки на whitepaper в крупных архитектурных комментах.

3. **Сформируй отчёт:**
   ```
   ## Pre-push check для gundemtech/leaf

   Коммитов к пушу: N
   Файлов изменено: M

   ### ❌ Критические утечки (N)
   - <файл:строка> <что> <почему блокирует>

   ### ⚠️ Высокий риск (N)
   - <файл:строка> <что> <рекомендация>

   ### ℹ️ Заметки (N)
   - <мелочь>

   ### Вердикт
   [BLOCK / WARN / OK] — <одна строка>
   ```

4. **Действие по вердикту:**
   - **BLOCK** — не пушить. Вывести список что поправить, предложить варианты (переместить в приватный модуль, вынести в `.env`, убрать).
   - **WARN** — показать список, спросить юзера "пушить несмотря на это? [y/N]". НЕ пушить без явного подтверждения.
   - **OK** — можно пушить. По запросу юзера — выполнить `git push` и отчитаться.

## Что НЕ делать

- Не блокировать на стилистике или code quality — это не цель команды.
- Не правь код сам без подтверждения юзера.
- Не игнорируй даже мелкие утечки "ради удобства" — moat теряется маленькими кусками.

## Куда переносить заблокированное

- **SQL-запросы / точные пороги / crypto** → приватные модули внутри проекта (папки `*/Private/` или отдельный SPM target помеченный `.gitignore`). Временно — до обсуждения окончательной архитектуры.
- **Секреты** → GitHub Secrets (CI), `.env` локально, Keychain в рантайме.
- **Preset bundle IDs** → runtime-конфиг, подтягиваемый с сервера при onboarding.
- **Внутренние TODO** → Linear issue, ссылка на issue в коде.
