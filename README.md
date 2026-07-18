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

## Рецепты

- **`ci-python.yml`** — секрет-скан (regex по трекаемым; исключения ложных
  срабатываний — построчно в `.github/secret-scan-ignore` вызывающей репы) → `ruff --select E9`
  (синтакс-ошибки Python) → `shellcheck -S error` (если есть `*.sh`) → `scripts/check-paths.sh`
  (если есть, hardcode-гард) → `make verify` (если есть цель). Раннер `ubuntu-latest`
  (вход `runner` для оверрайда). Шаги гардятся на наличие → один рецепт покрывает репы
  с мелкими отличиями.
- **`ci-node.yml`** — `pnpm install --frozen-lockfile` → `pnpm typecheck` → `pnpm lint`
  на self-hosted `home`-раннере. Входы `node-version` (22), `pnpm-version` (10.0.0).

## Версионирование

Стабы пинят `@v1` — подвижный тег на последний совместимый рецепт. Ломающее изменение
рецепта → новый тег `@v2` + миграция стабов. Мелкие правки (добавить шаг, поднять
версию action) → двигаем `v1` на новый коммит.
