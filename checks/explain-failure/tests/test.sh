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
case "${STUB_MODE:-ok}" in
  ok)        printf 'Слой 15_sku_pnl.sql не применился: column "net_price" does not exist.\nпохожий случай: yan/ops/2026-08-red-gate\n' ;;
  fake-slug) printf 'Что-то упало.\nпохожий случай: yan/ops/выдуманная-страница\n' ;;
  noauth)    printf 'Not logged in · Please run /login\n' ;;
  empty)     printf '\n\n' ;;
  slug-only) printf 'похожий случай: yan/ops/2026-08-red-gate\n' ;;
  slow)      sleep 5; printf 'поздно\n' ;;
esac
EOF
# Стаб gbrain: отмечает вызов, отдаёт две страницы в формате CLI.
cat > "$tmp/bin/gbrain" <<'EOF'
#!/usr/bin/env bash
: > "${STUB_GBRAIN_CALLED:-/dev/null}"
[ -n "${STUB_GBRAIN_CALLED:-}" ] && printf '%s\n' "$3" > "$STUB_GBRAIN_CALLED"
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
grep -q 'курс ЦБ' "$tmp/gcalled" && ok "запрос к брейну не порезан по байтам" || bad "запрос к брейну: $(cat "$tmp/gcalled")"
out="$(STUB_MODE=ok STUB_ENV_FILE="$tmp/env" GBRAIN_SOURCE=yan run)"
if grep -q '^BRAIN_YAN_URL=' "$tmp/env"; then bad "DSN брейна утёк в окружение claude"; else ok "DSN брейна не в окружении claude"; fi
grep -q 'humanize stub' "$tmp/prompt" || true   # скилл идёт системным промптом, в stdin его нет

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

# 5. Хвоста нет — модель всё равно зовётся, промпт говорит «(хвоста нет)».
out="$(STUB_MODE=ok STUB_PROMPT_FILE="$tmp/prompt2" EXPLAIN_TAIL="$tmp/nope.txt" GBRAIN_SOURCE='' run)"
grep -q '(хвоста нет)' "$tmp/prompt2" && [ -n "$out" ] && ok "без файла хвоста — модель зовётся с пометкой" || bad "no-tail: $out"

[ "$fail" = 0 ] && echo "explain-failure: OK" || { echo "explain-failure: FAIL"; exit 1; }
