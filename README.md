# dippstack/ci — единый CI-гейт флота

Публичный репозиторий с **reusable-workflow'ами** для CI всех проектов флота
(ais, marketplace, yan, bali). Публичный намеренно: reusable-workflow из приватной
репы нельзя звать через границу организации на free-плане, а публичный — можно из
любой репы любой орги. Здесь **только рецепты проверок** (линт/синтакс/секрет-скан) —
ни кода продукта, ни данных, ни секретов.

## Зачем

Раньше `ci.yml` был скопирован в каждую репу и копии разошлись (разные версии
checkout, разный набор шагов). Теперь логика гейта живёт в ОДНОМ месте, а репы
ссылаются на неё тонким стабом. Дрейф невозможен: меняешь рецепт здесь — меняется
у всех. Контекст паритета: `dippstack/ais` → `@infra/github/FLEET-PARITY.md`.

## Как подключить репу

**Python/shell репо** — `.github/workflows/ci.yml`:

```yaml
name: ci
on:
  pull_request:
    branches: [main]
  workflow_dispatch:
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true
jobs:
  ci:
    uses: dippstack/ci/.github/workflows/ci-python.yml@v1
```

**Node/pnpm репо** — то же, но `ci-node.yml@v1`.

**Проза-волты** (vault, render-vault) — `ci-vault.yml@v1` с приватным оверлеем паттернов:

```yaml
jobs:
  ci:
    uses: dippstack/ci/.github/workflows/ci-vault.yml@v1
    with:
      patterns: .config/scrub-extra.json
```

**Инфраструктура (OpenTofu/Terraform)** — `ci-terraform.yml@v1`. Модули и live-стеки
передаются JSON-списками, токены облаков приходят из secrets вызывающей репы:

```yaml
jobs:
  ci:
    uses: dippstack/ci/.github/workflows/ci-terraform.yml@v1
    with:
      modules: '["modules/vps-with-firewall", "live/home/vpn"]'
      plan-modules: '["live/home/vpn"]'
    secrets: inherit
```

**Выкатка (deliver)** — `.github/workflows/deliver.yml@v1`, стаб `deliver.yml` в репо продукта
на push в main. Сам контур доставки (реестр, kamal, шаблон `health.sh`, разворот на чистом
хосте) — приватный `dippstack/delivery`; здесь только reusable-механика, потому что её зовут
из других орг. Пример для продукта с pull-моделью на хосте:

```yaml
jobs:
  deliver:
    uses: dippstack/ci/.github/workflows/deliver.yml@v1
    with:
      service: yan
      driver: script            # kamal | script | watch
      runner: imac              # раннер с доверенным ssh до хоста
      deploy-host: home
      deploy-dir: ~/yan
      vault-env: /Users/imac/sandbox/yan/.vault/env/yan-bot.env   # TELEGRAM_BOT_TOKEN + TELEGRAM_DEVSUPPORT_CHAT/THREAD
```

## Рецепты

- **`ci-python.yml`** — секрет-скан (regex по трекаемым; исключения ложных
  срабатываний — построчно в `.github/secret-scan-ignore` вызывающей репы) → `ruff --select E9`
  (синтакс-ошибки Python) → `shellcheck -S error` (если есть `*.sh`) → `scripts/check-paths.sh`
  (если есть, hardcode-гард) → `make verify` (если есть цель). Раннер свой `home`
  (вход `runner` для оверрайда; GitHub-hosted не используем). Шаги гардятся на наличие → один рецепт покрывает репы
  с мелкими отличиями.
- **`ci-vault.yml`** — скраб секретов прозы на полном тире (core+dsn-creds+prose) единым
  движком; вендор/язык — приватным оверлеем из Vault волта (вход `patterns`). Раннер `home`.
- **`ci-terraform.yml`** — два джоба на раннере `home`. `validate` (вход `modules`): `tofu fmt -check`
  → `init -backend=false` → `validate` → `tflint` (конфиг `.tflint.hcl` из корня) → `trivy config`
  (CRITICAL,HIGH) → `tofu test` (если есть `tests/`). Без кредов и без сети к облаку. `plan`
  (вход `plan-modules`): `tofu init` → `tofu plan -detailed-exitcode`, **никогда apply**; дифф
  в summary прогона. С `fail-on-drift: true` расхождение state с кодом красит джоб — так
  работает расписание дрейфа. Токены провайдеров в рецепте не хранятся: вызывающая репа
  отдаёт свои secrets через `secrets: inherit`. На PR из форка `plan` не бежит.
- **`deliver.yml`** — шлюз выкатки. `driver: kamal` — образ → реестр → `kamal deploy` с
  откатом; `driver: script` — по ssh отцепленно (`nohup`) запустить `deploy/autodeploy.sh`
  продукта и ждать `deploy/health.sh <sha>` (rc 0 доехало, 1 ещё нет, 2 хост отверг этот
  SHA — красный сразу); `driver: watch` — только ждать health, когда таймер на узле нельзя
  дублировать. Телеграм — одна форма на флот: в env бота проекта лежат `TELEGRAM_BOT_TOKEN`,
  `TELEGRAM_SUPPORT_CHAT/THREAD` (группа поддержки пользователей) и
  `TELEGRAM_DEVSUPPORT_CHAT/THREAD` (дев-саппорт: выкатки, алерты, CI); указано — есть,
  пусто — молчим. Сообщение в devsupport — форма-чип, как у PR в Claude Code: одна строка,
  две кликабельные части — репо ссылкой на `REPO_URL` и рядом узел `#N заголовок` (номер PR,
  если это squash-мерж с `(#N)` в конце заголовка коммита — тогда ссылка на PR, иначе без
  номера и ссылка на сам коммит) тегом на PR/коммит; окружение добавляется в конец строки
  `<code>`-тегом, только если оно не дефолтное `dev`. SHA в строке не показываем — коммит
  виден в узле. Шлюз шлёт стартовое сообщение (🚀) до выкатки и по завершении правит его же
  на итог: при успехе (✅) та же строка плюс свёрнутая цитата с саммари — первым абзацем тела
  сквош-коммита (PR-описание), если оно есть; при ошибке правится только строка на ❌
  (вторая ссылка становится ссылкой на прогон), а отдельным НОВЫМ сообщением-ответом
  (`reply_to_message_id` на стартовое — правка не будит читателя) шлёт ту же строку, причину
  одним предложением (сборка образа упала, kamal deploy упал, гейт/флап-гард на хосте
  красный, health не позеленел за таймаут) и, если ошибка дошла до health на хосте, хвост
  журнала хоста (до 12 строк) свёрнутой цитатой. Токен и чат из `vault-env` на раннере,
  нет файла — предупреждение и прогон молча. Раннер — вход `runner`.
- **`checks/own-runner`** — правило 1 канона CI: ни одного облачного раннера GitHub.
  Композитное действие, стоит первым шагом во всех рецептах выше и в `self-check`: грепает
  `.github/workflows` вызывающей репы на `ubuntu-*`, `macos-*`, `windows-*` (комментарии не
  считаются) и красит гейт. Так любой workflow флота с облачным раннером краснеет сам, без
  токенов и обхода репозиториев.
- **`checks/pr-title`** — заголовок PR человеческим предложением, как в репозитории Claude Code
  (dippstack/ais#788): «область: что теперь происходит» (`diff: a resumed session with edits opens
  the pane`) или просто предложение (`Add issue template for GitHub connection problems`). Без типа
  `feat(scope):` — тип читателю чата ничего не говорит, а чип в Telegram цитирует заголовок
  сквош-коммита, то есть заголовок PR. Ловит префикс conventional commits (голый тип только у слов, что областями не бывают: `feat:`,
  `fix:`, `chore:`…; `ci:`, `docs:`, `test:` — законные области, а `ci(x):` и `ci!:` — тип), заглушку
  `task #N: slug`, меньше трёх слов, точку в конце, длиннее 160 символов (считает символы, не байты). Стоит во всех четырёх рецептах на
  `pull_request` в режиме предупреждения (правка заголовка гейт не перезапускает, красный бы не
  отпустил); `mode: error` — по желанию репо. Тест: `bash checks/pr-title/tests/test.sh`.
- **`ci-node.yml`** — `pnpm install --frozen-lockfile` → `pnpm typecheck` → `pnpm lint`
  на self-hosted `home`-раннере. Входы `node-version` (22), `pnpm-version` (10.0.0).

## Версионирование

Канон CI флота (2026-09-19, ais-render-vault `vault/vision/12`, «Раннеры и CI на три
организации»): раннеры свои и регистрируются на уровне организации, репы выбирают их
меткой (`home`, `linux`, `docker`; `imac`, `macos`, `xcode`, `simulator`), а не именем.
GitHub-hosted не используем нигде.

Стабы пинят `@v1` — подвижный тег на последний совместимый рецепт. Ломающее изменение
рецепта → новый тег `@v2` + миграция стабов. Мелкие правки (добавить шаг, поднять
версию action) → двигаем `v1` на новый коммит.
