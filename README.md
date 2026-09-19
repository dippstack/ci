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
- **`checks/own-runner`** — правило 1 канона CI: ни одного облачного раннера GitHub.
  Композитное действие, стоит первым шагом во всех рецептах выше и в `self-check`: грепает
  `.github/workflows` вызывающей репы на `ubuntu-*`, `macos-*`, `windows-*` (комментарии не
  считаются) и красит гейт. Так любой workflow флота с облачным раннером краснеет сам, без
  токенов и обхода репозиториев.
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
