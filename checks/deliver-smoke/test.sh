#!/usr/bin/env bash
# Смоук итогового сообщения deliver.yml без сети. Извлекает run шага «итог → Телеграм» (id
# summary) из YAML, подменяет curl стабом и гоняет под bash -e, как GitHub.
# Проверяет: зелёный → ✅ без звука и цитата-саммари; красный → ❌ со звуком, причина курсивом,
# хвост журнала хоста в цитате, HTML экранирован; Telegram отверг разметку → повтор без
# parse_mode; ok:false → шаг не падает, предупреждение в журнале. Запуск: bash checks/deliver-smoke/test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fail=1; }
python3 - "$HERE/.github/workflows/deliver.yml" "$tmp" <<'PY' || { echo "  ✗ yaml не разобран (нужен pyyaml)"; exit 1; }
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
steps = [st for st in d["jobs"]["deliver"]["steps"] if st.get("id") == "summary"]
assert len(steps) == 1, "шаг id=summary не найден ровно один раз"
open(sys.argv[2] + "/summary.sh", "w").write(steps[0]["run"])
PY
mkdir -p "$tmp/bin"
# Стаб curl: пишет в файл по строке на аргумент --data-urlencode и метод из URL; отвечает ok или
# fail (STUB_TG=fail — всегда, STUB_TG=html — только на запрос с parse_mode).
cat > "$tmp/bin/curl" <<'EOS'
#!/usr/bin/env bash
html=0
for a in "$@"; do
  case "$a" in https://*) echo "URL=${a##*/}" >> "$STUB_CURL_FILE";; esac
done
while [ $# -gt 0 ]; do
  if [ "$1" = --data-urlencode ]; then echo "$2" >> "$STUB_CURL_FILE"; case "$2" in parse_mode=*) html=1;; esac; shift; fi
  shift
done
echo "---" >> "$STUB_CURL_FILE"
if [ "${STUB_TG:-}" = fail ] || { [ "${STUB_TG:-}" = html ] && [ "$html" = 1 ]; }; then echo '{"ok":false}'; else echo '{"ok":true,"result":{"message_id":7}}'; fi
EOS
chmod +x "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH" STUB_CURL_FILE="$tmp/curl.txt" RUNNER_TEMP="$tmp/rt"
mkdir -p "$RUNNER_TEMP"
export REPO_URL=https://github.com/x/y REPO=x/y LINK=https://github.com/x/y/pull/1 RUN_URL=https://github.com/x/y/actions/runs/1 NUM_PREFIX="#1 " TITLE="t &amp; u" ENV_SUFFIX="" SERVICE=s
export TELEGRAM_BOT_TOKEN=tok TELEGRAM_DEVSUPPORT_CHAT=1 TELEGRAM_DEVSUPPORT_THREAD=9
reset(){ : > "$STUB_CURL_FILE"; rm -f "$RUNNER_TEMP/host-tail.txt"; }
sent(){ grep -qx -- "$1" "$STUB_CURL_FILE"; }
calls(){ grep -c '^URL=' "$STUB_CURL_FILE"; }

reset; JOB_STATUS=success SUMMARY="что сделано" bash -e "$tmp/summary.sh" > "$tmp/log" 2>&1 || bad "зелёный упал: $(cat "$tmp/log")"
[ "$(calls)" = 1 ] && sent 'URL=sendMessage' && ok "зелёный: ровно одно сообщение sendMessage" || bad "зелёный вызовы: $(cat "$STUB_CURL_FILE")"
sent 'disable_notification=true' && ok "зелёный: без звука" || bad "зелёный со звуком"
grep -q '^text=✅' "$STUB_CURL_FILE" && grep -q 'blockquote expandable>что сделано' "$STUB_CURL_FILE" && sent 'message_thread_id=9' && ok "зелёный: ✅, саммари в цитате, в теме" || bad "зелёный текст: $(cat "$STUB_CURL_FILE")"

reset; printf 'ERROR: <boom> & co\n' > "$RUNNER_TEMP/host-tail.txt"
JOB_STATUS=failure SUMMARY="" FAIL_WHAT="Хост отверг коммит." PROD_STATE="Прод на прежней версии." bash -e "$tmp/summary.sh" > "$tmp/log" 2>&1 || bad "красный упал: $(cat "$tmp/log")"
[ "$(calls)" = 1 ] && ok "красный: ровно одно сообщение" || bad "красный вызовы: $(calls)"
! sent 'disable_notification=true' && ok "красный: со звуком" || bad "красный без звука"
grep -q '^text=❌' "$STUB_CURL_FILE" && grep -q '<i>Хост отверг коммит. Прод на прежней версии.</i>' "$STUB_CURL_FILE" && grep -q 'actions/runs/1' "$STUB_CURL_FILE" && ok "красный: ❌, причина курсивом, ссылка на прогон" || bad "красный текст: $(cat "$STUB_CURL_FILE")"
grep -q '<code>ERROR: &lt;boom&gt; &amp; co</code>' "$STUB_CURL_FILE" && ok "красный: хвост хоста в цитате, HTML экранирован" || bad "хвост: $(cat "$STUB_CURL_FILE")"

reset; STUB_TG=html JOB_STATUS=success SUMMARY="" bash -e "$tmp/summary.sh" > "$tmp/log" 2>&1 || bad "повтор упал"
[ "$(calls)" = 2 ] && ! grep -q 'итог не прошёл' "$tmp/log" && ok "разметку отвергли → повтор без parse_mode прошёл" || bad "повтор: $(calls) $(cat "$tmp/log")"

reset; STUB_TG=fail JOB_STATUS=failure SUMMARY="" bash -e "$tmp/summary.sh" > "$tmp/log" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'итог не прошёл' "$tmp/log" && ok "ok:false → шаг не падает, предупреждение в журнале" || bad "fail: rc=$rc $(cat "$tmp/log")"

[ "$fail" = 0 ] && echo "deliver-smoke: OK" || { echo "deliver-smoke: FAIL"; exit 1; }
