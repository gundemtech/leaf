---
description: Релиз Leaf одной командой — bump + notarize + appcast под SSM-секретами, один confirm перед публикацией
---

# /release-leaf

Оркестрирует полный релиз Leaf: вывод версии → PREP (bump + changelog + release-notes) →
сборка/нотаризация/appcast под секретами из AWS SSM → **один confirm-гейт** → публикация
(R2 + сайт) → тег. Всё после гейта — read-only: правка notes/appcast инвалидирует EdDSA-подпись.

> **Это не автономный шаг.** `/release-leaf` реально отгружает прод-релиз: подписывает,
> нотарайзит у Apple, льёт на R2, двигает live-сайт. Запускай только когда осознанно
> релизишь. Тулинг (скрипты, тесты) живёт и проверяется отдельно; здесь — боевой прогон.

## Prerequisites (один раз)

1. **SSM `/leaf/release/*` засеян** (оператором с prod RW). Узкий prefix — только релизные ключи,
   НЕ blanket `/leaf/prod/` (иначе Supabase/Anthropic-секреты текут в env каждого
   `xcodebuild`/`notarytool`/`curl`):
   ```
   aws ssm put-parameter --type SecureString --name /leaf/release/R2_BUCKET            --value …
   aws ssm put-parameter --type SecureString --name /leaf/release/R2_ENDPOINT          --value …
   aws ssm put-parameter --type SecureString --name /leaf/release/R2_ACCESS_KEY_ID     --value …
   aws ssm put-parameter --type SecureString --name /leaf/release/R2_SECRET_ACCESS_KEY --value …
   aws ssm put-parameter --type SecureString --name /leaf/release/CF_ZONE_ID           --value …
   aws ssm put-parameter --type SecureString --name /leaf/release/CF_API_TOKEN         --value …
   aws ssm put-parameter --type String       --name /leaf/release/LEAF_SIGN_ID         --value 'Developer ID Application: … (…)'
   ```
   `LEAF_SIGN_ID` — `String` (это публичная Developer-ID строка, не секрет; leak-guard
   банит её литерал в коде, поэтому она живёт в SSM, а не в репозитории). Проверка:
   `AWS_PROFILE=… bash ../leaf-internal/scripts/vault.sh list release` показывает все 7 ключей.
2. **R2 CORS** (нужно для Phase 4 dashboard-фетча, не для самого релиза): на bucket/зоне —
   `Access-Control-Allow-Origin: https://leaf.gundem.tech` для `releases.json` и `*.sha256`.
   Это CF/R2-конфиг, не код. Без CORS-доступа автономно — задокументировано, не блокирует Ph2.
3. **Sparkle pinned** локально: `~/bin/sparkle/generate_appcast` поддерживает
   `--embed-release-notes` (проверено — bare-фрагмент без `<!DOCTYPE`/`<body>` встраивается
   как CDATA `<description>`). Подпись фида: `SURequireSignedFeed=YES` → linked-notes без
   подписи отвергаются, поэтому embed-only — канон.
4. **Дерево чистое, на `dev`**, `just preflight` зелёный.

## Поток (по шагам)

### 1. Версия

```bash
git fetch --tags --quiet
latest="$(./scripts/derive-version.sh)"        # напр. v1.0.0-alpha.30 (^v-фильтр + form-assert)
```
Следующая = `alpha.(N+1)` (strip `v`-префикса → `1.0.0-alpha.31`), либо явный аргумент.
Assert формы `^[0-9]+\.[0-9]+\.[0-9]+-alpha\.[0-9]+$`. **Везде без `v`** (pbxproj / CHANGELOG /
dmg / releases.json / аргумент release.sh) — `v` несёт **только git-тег**.

### 2. Preflight

`just preflight` на чистом дереве (R1). Красный → стоп.

### 3. PREP (ДО `release.sh` — Ordering-инвариант)

Дерево станет dirty; **коммит откладываем до после notary-success** (шаг 6), чтобы провал
до confirm оставлял dirty-tree, а не dangling-коммит. Все шаги **идемпотентны** (skip, если
уже сделано):

1. **`./scripts/bump-version.sh <ver>`** — все 6 MARKETING_VERSION + 6 CURRENT_PROJECT_VERSION.
   (Skip, если pbxproj уже на `<ver>`.)
2. **CHANGELOG-cut** — перенести накопленное из `## [Unreleased]` в новую секцию
   `## [<ver>] — <YYYY-MM-DD>` (категории `### Added/Fixed/Changed`), оставить `[Unreleased]`
   пустой, добавить compare-ссылку в футере. **Public-safe:** глазами просмотреть diff как
   `/pre-push-leaf` — leak-guard ловит имена/секреты/pragma-числа, но НЕ прозу. (Skip, если
   `<ver>` уже в CHANGELOG.)
3. **`./scripts/gen-release-notes.sh`** — регенерит `Leaf/Resources/releases.json` (committed)
   так, что на диске он теперь несёт `<ver>` **до** `step_archive`. Это и есть Ordering-инвариант:
   `PBXFileSystemSynchronizedRootGroup` бандлит файл как есть — иначе билд N унесёт каталог N−1
   и in-app What's New молча покажет старую версию.

### 4. Сборка до appcast (под секретами)

```bash
AWS_PROFILE=… bash ../leaf-internal/scripts/vault.sh run release -- \
    bash scripts/release.sh <ver> --until appcast
```
Живой SSM-фетч (плейнтекст не на диск). `--until appcast` строит/нотарайзит/генерит appcast,
но **не публикует** (нет R2-аплоада, нет деплоя сайта). `assert_secrets` валит мгновенно, если
секреты не подъехали. pbxproj-guard сходится (bump уже применён). Offline без SSM: `just
secrets-refresh` → `~/.config/leaf/release.env`, который release.sh подхватит, **только** если
live-env пуст (с громким `! using CACHED secrets`).

### 5. CONFIRM-гейт (AskUserQuestion) — единственный human-гейт

Показать **read-only** сводку и спросить «публиковать?»:
- версия `<ver>`;
- changelog-секция `<ver>` (что увидят в What's New);
- размеры артефактов (`du -h build/releases/Leaf-<ver>.{dmg,zip}`);
- notary submission id (из вывода `step_notary`).

**После гейта правки запрещены** — любая правка notes/appcast после `generate_appcast`
инвалидирует EdDSA-подпись фида и требует `release.sh <ver> --redo-from appcast`.

### 6. На «да» — публикация

1. **Коммит PREP** (bump + CHANGELOG + releases.json) — теперь, после notary-success.
   Сообщение `release: bump to <ver>`. (Git-side идемпотентно: skip, если уже закоммичено.)
2. **Resume** `release.sh <ver>` (без `--until`) под `vault.sh run release` — догоняет
   `upload` + `site`. Stamps пропускают сделанное; шаг `site` ждёт CDN-propagation appcast.
   **CDN-wait:** `step_site` крутит `sleep 10`×12 — foreground sleep заблокирован в харнессе,
   поэтому гнать resume как `run_in_background` (Bash `run_in_background: true`) либо драйвить
   ожидание через Monitor/until-loop на уровне команды, не блокируя сессию.
3. **Тег**: `git tag v<ver> && git push origin v<ver>` (+ `git push` коммита PREP в `dev`/`main`
   по branch-модели). Тег идемпотентен: skip, если `v<ver>` уже существует.
4. **Опционально** — 1 строка в `leaf-docs` changelog (как раньше; product-changelog ≠
   app-release-notes, две разные поверхности).
5. Отчёт: версия, R2-URL'ы, live appcast, tag.

## Yank / rollback (если релиз оказался битым)

1. **CHANGELOG**: пометить секцию `## [<ver>] — <date> [YANKED]` → `gen-release-notes.sh`
   проставит `"yanked": true` в `releases.json` (dashboard это чтит и не предлагает скачивание).
2. **Appcast**: убрать/заменить `<item>` битой версии — перегенерить `generate_appcast`
   без её артефактов (appcast single-item: yank latest ⇒ заново шипнуть прошлый appcast),
   чтобы Sparkle перестал её предлагать. Только `generate_appcast` подписывает фид — ручной
   upload appcast запрещён.
3. **Re-upload + purge**: `releases.json` (yanked) + новый appcast на R2; CF purge обоих.
4. Лучше — забампать фикс-версию `alpha.(N+1)` и отгрузить нормально; yank оставить для
   «скачивание этой версии вредно».

## Заметки

- **Один транк**: реализация тулинга идёт feature-веткой → PR в `dev`. Сам **акт релиза**
  (bump + tag) — отдельная чистая операция, тег не вешаем на feature-ветку (R4/R6).
- Полный e2e (Sparkle native What's New + in-app sheet + dashboard) проверяется на втором Mac
  (two-Mac signed-build gate, current-state).
