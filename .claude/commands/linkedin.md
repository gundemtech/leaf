---
description: Сгенерировать LinkedIn-пост о текущей фиче / апдейте Leaf по контексту сессии
---

# /linkedin

Сгенерируй пост для LinkedIn о том, что мы только что сделали — обычно вызывается сразу после успешного коммита/пуша новой фичи в той же Claude Code сессии.

## Аргументы

`$ARGUMENTS` — опциональный угол поста. Например:
- `сравни с гугловским автокомплитом` — нужно сделать упор на сравнение с конкретным конкурентом
- `сделай акцент на encrypted storage` — выдвинуть один аспект на первый план
- (пусто) — берёшь главную тему из текущей сессии и пишешь общий апдейт

## Источники фактов

В порядке приоритета:

1. **Текущая Claude Code сессия.** Что коммитили (`git log -5`), какие файлы трогали, какой spec/plan читали, что обсуждали. Это первичный источник.
2. **`.claude/shared/current-state.md`** — последний снэпшот проекта. Используй чтобы:
   - правильно назвать фичу (она там уже задокументирована),
   - дать контекст «в рамках чего» (Phase X.Y, какая часть Layer A/B и т.д.),
   - не наврать про нетронутое в этой сессии.
3. **`.claude/shared/glossary.md`** — для имён фич, терминов, имён MCP tools. Не выдумывай новые термины, используй принятые в проекте.
4. **`$ARGUMENTS`** — модулирует угол, но не подменяет факты.

**Никогда не выдумывай факты.** Если фича в сессии не упомянута и в `current-state.md` её нет — спроси юзера прежде чем фантазировать.

## Стиль (образец — пост Димы про Vox)

> One more update to VOX. Typing a message in another language used to mean copy-paste gymnastics, and most translators still make you wait until you're done. Vox doesn't anymore. Google Translate lives in a browser tab you don't have open. ChatGPT waits for your full message, then waits some more. Vox is one keystroke away from whatever you're doing. Added a live translator yesterday. Text and voice, one panel. Type, and the translation streams as you pause. Commit a sentence and it freezes: no more watching the first sentence rewrite itself every time you add a word. Switch to voice mode, speak, and the translation appears as you talk. Swap source and target with one tap. If translation feels like work, the tool is wrong. A good one disappears.

Что важно вытащить из этого образца и **повторить**:

- **NO DASHES. ВООБЩЕ.** Это жёсткое правило, нарушать нельзя. Запрещены: `—` (em-dash), `–` (en-dash), `-` (hyphen-minus) внутри предложений, в составных словах, в датах, везде. Образец Димы про Vox содержит тире — **это образец стиля, а НЕ примера пунктуации**, у нас правило строже. Замены:
  - Вставная конструкция через тире `Leaf — ambient memory layer for Mac` → `Leaf, ambient memory layer for Mac,` или вынести в отдельное предложение: `Leaf is the ambient memory layer for Mac.`
  - Парантеза через тире `Counts make work look uniform — four PRs is four PRs` → двоеточие или точка: `Counts make work look uniform: four PRs is four PRs.` / `Counts make work look uniform. Four PRs is four PRs.`
  - Составные слова: `natural-language queries` → `natural language queries`, `5-min polling` → `5 min polling`, `open-source` → `open source`, `Mac-only` → `Mac only`. Читается естественно везде, проверено.
  - Диапазоны: `5-10 minutes` → `5 to 10 minutes` или `5, 10 minutes`.
  - Underscores в коде (`get_github_activity`) — это **не тире**, разрешены.
  - **Перед выдачей прогон по тексту: ни одного `—`, `–`, `-` не должно быть. Если нашёл — заменяй.**
- **LA startup vibe, не press release.** Тон не корпоративный и не инженерный мануал, а как пишет фаундер ранней стадии в личном тви/ленте. Что это значит конкретно:
  - **«You», не «developers» / «your team».** Адрес читателю напрямую: «You shipped four PRs this week.» вместо «Developers shipping multiple PRs per week…»
  - **Разговорная плотность.** «Just dropped», «here's the move», «real talk», «spoiler:», «built this last weekend». Не каждое предложение — но 1-2 за пост ставит тон.
  - **Лёгкая самоирония когда уместно.** Bug story Димы или наша история про squash-merge parser regression — это не «we identified and resolved an issue», а «we almost shipped without noticing» или «turns out we'd been silently dropping half the data».
  - **Меньше «We shipped today», больше «Just dropped».** Глаголы прямого действия, не корпоративные глаголы.
  - **Прямой адрес к чувству читателя, не к функции:** «If your tools make work feel like work, that's the bug» сильнее, чем «Our tool aims to reduce friction».
  - **ЧТО ЗАПРЕЩЕНО при этом:** tech-bro speak. «Absolutely insane», «this is huge», «let's go», «stoked», «massive W», «cooked», «based» — это та же корпоративная вода в другой маске. Молодёжно ≠ tech-bro. Образец Димы про Vox — он молодой, прямой, разговорный, но в нём ноль tech-bro-фраз. Целимся туда.
- **Hook = продающий, через боль или резонанс с читателем, не констатация.** Первая фраза — это решение читателя продолжать или скроллить. Слабо: «Most dev dashboards count actions» (факт, читателю всё равно). Сильно: «You shipped four PRs this week. Did it feel like four?» — это **попадание в самочувствие читателя**, он не может проскроллить. Другие шаблоны:
  - **Боль:** «Stop guessing if Monday was slower than Friday.»
  - **Парадокс:** «Your dashboard says you're shipping. Your gut says you're tired. Both are right.»
  - **Цена бездействия:** «Counting work is easy. Knowing how it went is the hard part.»
  - **Прямой вопрос:** «How long did your last PR actually wait for review? You don't know.»

  После hook'а — противопоставление категории (которое было правилом раньше: «Most X do Y. Leaf does Z.»). Hook + категорийное противопоставление = первые 200 символов цепляют и сразу позиционируют продукт.
- **Короткие предложения.** 5-12 слов. Длинные сложноподчинённые: нет.
- **Конкретика, не маркетинг.** «one keystroke away», «streams as you pause», «freezes when you commit a sentence»: точные сценарии. Не «революционный», не «бесшовный», не «инновационный».
- **Никаких эмодзи. Никаких хэштегов.** Совсем.
- **Никаких bullet-листов.** Только параграфы из коротких предложений.
- **Финал: короткий афоризм или вывод про продукт.** «If translation feels like work, the tool is wrong. A good one disappears.»: одна фраза, формулирующая принцип. Без «stay tuned», без «what do you think?», без призыва к лайкам.
- **Нет «I'm excited to share that…»**, «We are thrilled», «proud to announce» и прочей корпоративной воды. Сразу к делу: «Just dropped a thing.» / «Today's move:» / «Here's what changed:».
- **Термины из whitepaper переводи на внешний язык.** «Layer A / Layer B / Layer C», «Phase 4.6.A.1», «Section A/B done», «derived insights», `signal_type`, `collector_offsets`, «MVP scope»: внутренний словарь команды. На LinkedIn никто не знает что такое Layer B и его называть им бессмысленно. Замены: `Layer B` → «across our integrations» / «across GitHub, Linear, and Slack» / нужный конкретный список; `Phase X.Y`: не упоминай вообще, скажи что сделано; `derived insights` → «metrics» / «what Leaf computes». Имена **MCP tools** (`get_github_activity`, `get_linear_activity`): один раз за пост максимум, и только если оно что-то добавляет (например, сигнал «у нас MCP-интеграция»). Перечислять две и более — нет.
- **Поменьше технической инфы.** Это пост про **что это даёт человеку**, а не про **как это устроено внутри**. Конкретные ограничения:
  - **Цифры:** 1-2 за весь пост максимум. Хорошо: «average cycle 11 hours» (одна резонирующая цифра). **Плохо (никогда так не делай):** `PRs merged: 4 · avg cycle 11h, Reviews: 6 · avg wait 2h, Closed: 3 · avg duration 1d 4h` — это дамп интерфейса, читать невозможно, читателю фуфу. Вместо дампа — одно следствие в человеческой форме: «Most PRs merge in under a day. One sat for three.» / «Average cycle dropped from invisible to 11 hours.»
  - **Не перечисляй формы вывода.** Плохо: «This shows up in the menubar popover, the MCP server, and the JSON response.» Хорошо: одна форма, либо «hover the menu bar», либо «ask Claude», но не оба сразу.
  - **Не лезь в кишки.** Не объясняй парсер, не объясняй полл-интервалы, не объясняй формат payload, не упоминай SQL/SQLCipher/SPM/encoding. Это интересно нам, не им.
  - **Bug story допускается** если про **человеческий момент** («we almost shipped without noticing this»), не про архитектурный («the GitHub events feed reports squash-merged PRs as action: merged instead of closed plus merged: true»). Если описание бага требует двух предложений про API того сервиса, это слишком технически: уплощай или режь.
  - **Тест:** прочитал бы пост твой друг, который **не разработчик**? Если он на третьем предложении подумает «ладно, не моё», ты потерял 80% LinkedIn-аудитории. Технические детали уважают только узкий круг — пиши сначала для широкого читателя, технические сигналы оставляй между строк (имя MCP tool раз, цифра-якорь, конкретное приложение). Целевая аудитория — фаундеры стартапов и менеджеры команд, не staff engineers.

Что **не повторять**:
- Дима пишет на английском — у нас тоже английский для LinkedIn.

## Технические рамки

- **Язык:** английский (LinkedIn международный).
- **Лимит символов:** **900-1500**. LinkedIn truncate'ит превью на ~1300 + кнопка "see more", поэтому первые 200-250 символов несут главное сообщение, остальное раскрывает деталь. **Не уходи за 1500** — лонгрид в ленте не читают, плотный пост работает лучше. Если получилось 600-900 и при этом мысль доведена — оставляй, не дотягивай искусственно.
- **Структура:** 3-5 параграфов, разделённых пустой строкой. Внутри параграфа — 2-4 коротких предложения.
- **Имя продукта:** **Leaf** (без LeafControl, без Leaf App, просто Leaf). Если в первом упоминании уместно сказать что это, делай отдельным предложением: `Leaf is the ambient memory layer for Mac.` Не вставляй описание через тире (`Leaf — ambient memory layer for Mac`): это запрещено правилом NO DASHES в разделе «Стиль».

## Output

Только тело поста. Никаких:
- префиксов («Here's the post:», «Вот черновик:»),
- объяснений выбора стиля,
- списка alternatives,
- markdown-разметки (`**bold**`, `# headings`) — LinkedIn её не понимает,
- эмодзи,
- хэштегов.

Чистый текст, готовый к copy-paste в LinkedIn editor.

## Sanity check перед выдачей

Перед тем как показать пост юзеру, прогони его в голове по чек-листу:

1. **Факты сходятся с сессией / current-state.md?** Если упомянул цифру (135 tests, 5min polling, 1.7MB delta), она реальная, ты её видел в коде/state, не выдумал.
2. **NO DASHES?** Прогон поиском по `—`, `–`, `-`. Ни одного не должно быть в тексте поста. Если нашёл, заменяй (см. правила в разделе «Стиль»). Это самая частая ошибка, проверяй её первой.
3. **Длина в рамках 900-1500?** Больше 1500: режь самое слабое. Меньше 600: добавь одну деталь. Между 600-1500: норма, искусственно не дотягивай.
4. **Hook продающий, не констатация?** Если первая фраза просто факт («Most dashboards count actions»), усиль до резонанса с читателем: «You shipped four PRs this week. Did it feel like four?», «Stop guessing if Monday was slower than Friday.» Hook + категорийное противопоставление в первых 200 символах.
5. **LA startup vibe, не press release / не tech-bro?** Прогон по «excited», «thrilled», «proud», «pleased to announce», «revolutionary», «seamless», «leverage», «empower», «unlock»: выкидывай (это press release). Прогон по «absolutely insane», «this is huge», «massive W», «let's go», «stoked», «cooked», «based»: выкидывай (это tech-bro). Между этими двумя крайностями: «just dropped», «here's the move», «real talk», «spoiler» в меру.
6. **Поменьше технической инфы.** Цифр в посте 1-2 максимум, не больше. Форм вывода названо одна, не три. Не описывай парсер/архитектуру/JSON формат. Bug story если есть, то про человеческий момент, не про API. Тест: друг-не-разработчик прочитал бы это до конца? Если на третьем предложении он скроллит, переписывай.
7. **Внутренние термины переведены?** Прогон по словам «Layer A/B/C», «Phase X.Y», «Section A/B», «derived insights», `signal_type`: если есть в посте, заменяй на внешний эквивалент. MCP tool name: один раз максимум за пост.
8. **Финал = короткая фраза-вывод, не призыв?** «Stay tuned» / «What do you think?» / «DM me if interested»: нет.

Если что-то из чек-листа не сходится — переписывай **молча**, не показывай альтернативы, выдай финальную версию.

## Когда не запускать

- В сессии не было содержательного коммита и `$ARGUMENTS` пустой — тогда не из чего писать. Скажи: «нет фактов для поста, дай тему через `$ARGUMENTS` или закоммить фичу сначала».
- Юзер просит написать про что-то, чего ты не видел в сессии и в `current-state.md` нет — не фантазируй, попроси факты.
