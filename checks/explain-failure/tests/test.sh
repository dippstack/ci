#!/usr/bin/env bash
# Тест explain.sh без сети: стабы claude и gbrain на PATH, свой HOME с токеном, брейнами и скиллом.
# Проверяет контракт: две строки на успех, похожий случай только из выданных страниц, пустой
# вывод и rc 0 при любой беде (нет claude, нет токена, таймаут, «Not logged in»), ANSI вычищен.
# Запуск: bash checks/explain-failure/tests/test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fail=1; }

# Свой HOME: токен, адреса брейнов, скилл — как на раннере.
export HOME="$tmp/home"
mkdir -p "$HOME/.config/dippstack" "$HOME/.claude/skills/humanize" "$tmp/bin"
echo 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-test' > "$HOME/.config/dippstack/claude-oauth.env"
printf 'BRAIN_YAN_URL=postgres://x@localhost:1/gbrain\n' > "$HOME/.config/dippstack/brains.env"
echo '# humanize stub' > "$HOME/.claude/skills/humanize/SKILL.md"

# Стаб claude: пишет полученный промпт в файл, отвечает по STUB_MODE.
cat > "$tmp/bin/claude" <<'EOF'
#!/usr/bin/env bash
cat > "${STUB_PROMPT_FILE:-/dev/null}"
[ -n "${STUB_ENV_FILE:-}" ] && env > "$STUB_ENV_FILE"
[ -n "${STUB_ARGS_FILE:-}" ] && printf '%s\n' "$@" > "$STUB_ARGS_FILE"
case "${STUB_MODE:-ok}" in
  ok)        printf 'ПРИЧИНА: Слой 15_sku_pnl.sql не применился: column "net_price" does not exist.\nПОХОЖИЙ: yan/ops/2026-08-red-gate\n' ;;
  fake-slug) printf 'ПРИЧИНА: Что-то упало.\nПОХОЖИЙ: yan/ops/выдуманная-страница\n' ;;
  preamble)  printf 'Проверю память на похожие случаи сбоя.\n**Tool: BashOutput**\n**ПРИЧИНА:** Слой упал.\n' ;;
  nomarker)  printf 'Проверю память на похожие случаи сбоя.\n' ;;
  noauth)    printf 'Not logged in · Please run /login\n' ;;
  apierr)    printf 'ПРИЧИНА: Сервис упал: в логе API Error 403 от реестра.\n' ;;
  rc1)       echo "boom" >&2; exit 1 ;;
  empty)     printf '\n\n' ;;
  slug-only) printf 'ПОХОЖИЙ: yan/ops/2026-08-red-gate\n' ;;
  slow)      sleep 5; printf 'поздно\n' ;;
esac
EOF
# Стаб gbrain: отмечает вызов, отдаёт две страницы в формате CLI.
cat > "$tmp/bin/gbrain" <<'EOF'
#!/usr/bin/env bash
: > "${STUB_GBRAIN_CALLED:-/dev/null}"
[ -n "${STUB_GBRAIN_CALLED:-}" ] && printf '%s\n' "$2" > "$STUB_GBRAIN_CALLED"
printf '[0.8460] yan/ops/2026-08-red-gate -- красный гейт: слой sku_pnl, колонка net_price\n[0.8100] yan/meta/backlog -- бэклог\n'
EOF
chmod +x "$tmp/bin/claude" "$tmp/bin/gbrain"
export PATH="$tmp/bin:$PATH"

printf '  \033[32m✓\033[0m слой 14\n  \033[31m✗\033[0m слой 15_sku_pnl.sql: ERROR: column "net_price" does not exist\n' > "$tmp/tail.txt"
run(){ EXPLAIN_TITLE='fix(engine): курс ЦБ' EXPLAIN_REASON='Хост отверг коммит.' EXPLAIN_TAIL="${EXPLAIN_TAIL:-$tmp/tail.txt}" bash "$HERE/explain.sh" 2>"$tmp/err"; }

# 1. Полный путь: предложение + похожий случай из выданных страниц, ANSI в промпте нет.
out="$(STUB_MODE=ok STUB_PROMPT_FILE="$tmp/prompt" STUB_GBRAIN_CALLED="$tmp/gcalled" GBRAIN_SOURCE=yan run)"; rc=$?
[ "$rc" = 0 ] && ok "rc 0" || bad "rc $rc"
[ "$(printf '%s\n' "$out" | sed -n 1p)" = 'Слой 15_sku_pnl.sql не применился: column "net_price" does not exist.' ] && ok "первая строка — предложение модели" || bad "первая строка: $out"
[ "$(printf '%s\n' "$out" | sed -n 2p)" = 'похожий случай: yan/ops/2026-08-red-gate' ] && ok "вторая строка — похожий случай из выдачи брейна" || bad "вторая строка: $(printf '%s\n' "$out" | sed -n 2p)"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 2 ] && ok "ровно две строки" || bad "строк: $(printf '%s\n' "$out" | wc -l)"
[ -f "$tmp/gcalled" ] && ok "брейн спрошен при GBRAIN_SOURCE" || bad "брейн не спрошен"
if grep -q $'\e' "$tmp/prompt"; then bad "ANSI уехал в промпт"; else ok "ANSI вычищен из хвоста"; fi
grep -q 'net_price' "$tmp/prompt" && ok "хвост дошёл до модели" || bad "хвоста нет в промпте"
out="$(STUB_MODE=ok STUB_ARGS_FILE="$tmp/args" GITHUB_OUTPUT="$tmp/gh-out" GBRAIN_SOURCE=yan run)"
grep -qx -- '--strict-mcp-config' "$tmp/args" && grep -qx -- '--tools' "$tmp/args" && ok "модель без инструментов и без MCP" || bad "флаги claude: $(tr '\n' ' ' < "$tmp/args")"
grep -qx -- '--system-prompt' "$tmp/args" && ! grep -qx -- '--append-system-prompt' "$tmp/args" && ok "штатный системный промпт заменён, не дополнен" || bad "system-prompt: $(tr '\n' ' ' < "$tmp/args")"
out="$(STUB_MODE=preamble GBRAIN_SOURCE=yan run)"
[ "$out" = 'Слой упал.' ] && ok "преамбула и маркер инструмента отброшены, взята строка ПРИЧИНА" || bad "preamble: $out"
out="$(STUB_MODE=nomarker GBRAIN_SOURCE=yan run)"; rc=$?
[ -z "$out" ] && [ "$rc" = 0 ] && ok "ответ без маркера ПРИЧИНА → пусто" || bad "nomarker: rc=$rc out=$out"
grep -qx 'sentence=Слой 15_sku_pnl.sql не применился: column "net_price" does not exist.' "$tmp/gh-out" && grep -qx 'similar=yan/ops/2026-08-red-gate' "$tmp/gh-out" && ok "GITHUB_OUTPUT: sentence= и similar=" || bad "GITHUB_OUTPUT: $(cat "$tmp/gh-out")"
out="$(STUB_MODE=apierr GBRAIN_SOURCE=yan run)"
[ "$out" = 'Сервис упал: в логе API Error 403 от реестра.' ] && ok "«API Error» в тексте предложения не принимается за отказ claude" || bad "apierr: $out"
out="$(STUB_MODE=ok GBRAIN_SOURCE=ais/prod run)"; rc=$?
[ "$rc" = 0 ] && [ -n "$out" ] && ok "кривой GBRAIN_SOURCE (ais/prod) не роняет скрипт" || bad "bad-source: rc=$rc out=$out err=$(cat "$tmp/err")"
grep -q 'курс ЦБ' "$tmp/gcalled" && ok "запрос к брейну не порезан по байтам" || bad "запрос к брейну: $(cat "$tmp/gcalled")"
out="$(STUB_MODE=ok STUB_ENV_FILE="$tmp/env" GBRAIN_SOURCE=yan run)"
if grep -q '^BRAIN_YAN_URL=' "$tmp/env"; then bad "DSN брейна утёк в окружение claude"; else ok "DSN брейна не в окружении claude"; fi

# 2. Модель назвала slug не из выдачи — вторую строку не печатаем.
out="$(STUB_MODE=fake-slug GBRAIN_SOURCE=yan run)"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] && ok "выдуманный slug отброшен" || bad "выдуманный slug прошёл: $out"

# 2б. Модель ответила только строкой «похожий случай» — без предложения вывод пуст.
out="$(STUB_MODE=slug-only GBRAIN_SOURCE=yan run)"; rc=$?
[ -z "$out" ] && [ "$rc" = 0 ] && ok "только slug без предложения → пусто" || bad "slug-only: rc=$rc out=$out"

# 3. Без GBRAIN_SOURCE брейн не трогаем, одна строка.
rm -f "$tmp/gcalled"
out="$(STUB_MODE=ok STUB_GBRAIN_CALLED="$tmp/gcalled" GBRAIN_SOURCE='' run)"
[ ! -f "$tmp/gcalled" ] && ok "без GBRAIN_SOURCE брейн не спрошен" || bad "брейн спрошен без источника"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] && ok "без брейна — одна строка" || bad "без брейна строк: $out"

# 4. Беды → пусто, rc 0.
out="$(STUB_MODE=noauth GBRAIN_SOURCE=yan run)"; rc=$?
[ -z "$out" ] && [ "$rc" = 0 ] && ok "«Not logged in» → пусто, rc 0" || bad "noauth: rc=$rc out=$out"
out="$(STUB_MODE=rc1 GBRAIN_SOURCE=yan run)"; rc=$?
[ -z "$out" ] && [ "$rc" = 0 ] && grep -q 'rc≠0: boom' "$tmp/err" && ok "claude rc 1 → пусто, rc 0, stderr в журнале" || bad "rc1: rc=$rc out=$out err=$(cat "$tmp/err")"
out="$(STUB_MODE=empty GBRAIN_SOURCE=yan run)"; rc=$?
[ -z "$out" ] && [ "$rc" = 0 ] && ok "пустой ответ → пусто, rc 0" || bad "empty: rc=$rc out=$out"
out="$(STUB_MODE=slow EXPLAIN_TIMEOUT=1 GBRAIN_SOURCE=yan run)"; rc=$?
[ -z "$out" ] && [ "$rc" = 0 ] && ok "таймаут → пусто, rc 0" || bad "slow: rc=$rc out=$out"
mv "$HOME/.config/dippstack/claude-oauth.env" "$tmp/tok.bak"
out="$(STUB_MODE=ok GBRAIN_SOURCE=yan run)"; rc=$?
[ -z "$out" ] && [ "$rc" = 0 ] && grep -q 'нет CLAUDE_CODE_OAUTH_TOKEN' "$tmp/err" && ok "нет токена → пусто, rc 0, причина в stderr" || bad "no-token: rc=$rc out=$out err=$(cat "$tmp/err")"
mv "$tmp/tok.bak" "$HOME/.config/dippstack/claude-oauth.env"
out="$(PATH="/usr/bin:/bin" STUB_MODE=ok GBRAIN_SOURCE=yan run)"; rc=$?
[ -z "$out" ] && [ "$rc" = 0 ] && ok "нет claude → пусто, rc 0" || bad "no-claude: rc=$rc out=$out"

# 4б. Голый env без HOME — тоже пусто и rc 0, а не «unbound variable».
out="$(env -i PATH="/usr/bin:/bin" EXPLAIN_TITLE=t EXPLAIN_REASON=r bash "$HERE/explain.sh" 2>/dev/null)"; rc=$?
[ -z "$out" ] && [ "$rc" = 0 ] && ok "без HOME → пусто, rc 0" || bad "no-home: rc=$rc out=$out"

# 5. Хвоста нет (kamal) — модели нечего объяснять: пусто, rc 0, claude не зовётся.
out="$(STUB_MODE=ok STUB_PROMPT_FILE="$tmp/prompt2" EXPLAIN_TAIL="$tmp/nope.txt" GBRAIN_SOURCE='' run)"; rc=$?
[ -z "$out" ] && [ "$rc" = 0 ] && [ ! -f "$tmp/prompt2" ] && ok "без хвоста → пусто, модель не зовётся" || bad "no-tail: rc=$rc out=$out"

[ "$fail" = 0 ] && echo "explain-failure: OK" || { echo "explain-failure: FAIL"; exit 1; }
