#!/usr/bin/env bash
# Тест правила заголовка PR (dippstack/ais#788): что проходит, что нет и почему.
# Запуск: bash checks/pr-title/tests/test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
fail=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fail=1; }
pass(){ out="$(bash "$HERE/check.sh" "$1")"; [ $? = 0 ] && ok "принят: $1" || bad "отвергнут зря: $1 → $out"; }
deny(){ out="$(bash "$HERE/check.sh" "$1")"; rc=$?; [ $rc = 1 ] && [[ "$out" == *"$2"* ]] && ok "отвергнут: $1 → $out" || bad "должен быть отвергнут ($2): $1 → rc=$rc $out"; }

# Как в Claude Code: область двоеточием или просто предложение.
pass "diff: a resumed session with edits opens the pane"
pass "mods/agents-md: the AGENTS.md project-instructions mod"
pass "Add issue template for GitHub connection problems on claude.ai"
pass "Камера снова открывается на iOS 17 при добавлении фото"
pass "deliver: красное сообщение объясняет причину словами, а не хвостом лога"
pass "cd: ночные зелёные без звука по зоне читателя"
# Без типа.
deny "feat(mobile): падение на iOS 17 при открытии камеры" "префикс типа"
deny "fix: гонка при повторной отправке заявки" "префикс типа"
deny "FEAT(deliver)!: чип без точки" "префикс типа"
deny "chore(deps): expo 54.0.3" "префикс типа"
deny "docs: обновить README" "префикс типа"
# Заглушка dl land, короткое, точка, пустое, длинное.
deny "task #784: deliver-fail-reason" "заглушка"
deny "deliver: чип" "коротко"
deny "Починил баг" "коротко"
deny "Камера снова открывается на iOS 17." "точка в конце"
deny "" "пустой"
deny "$(printf 'x%.0s' $(seq 1 121))" "120 символов"
# Область с заглавной буквы — это уже не область, а начало предложения: считаем предложением.
pass "Deliver: what happens now is described in words"

[ "$fail" = 0 ] && echo "pr-title: OK" || { echo "pr-title: FAIL"; exit 1; }
