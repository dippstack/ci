#!/usr/bin/env bash
# Смоук шелл-логики deliver.yml без сети (dippstack/ais#787): извлекает run старт-шага (id notify)
# и шага-сторожа из YAML, подменяет curl и date стабами и гоняет под bash -e, как GitHub.
# Проверяет: ночь по зоне читателя → disable_notification=true, день → нет; сторож отвечает на
# старт с ⏳ и правит старт; при ok:false шаги не падают. Запуск: bash checks/deliver-smoke/test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fail=1; }
python3 - "$HERE/.github/workflows/deliver.yml" "$tmp" <<'PY' || { echo "  ✗ yaml не разобран (нужен pyyaml)"; exit 1; }
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
steps = d["jobs"]["deliver"]["steps"]
for st in steps:
    if st.get("id") == "notify": open(sys.argv[2] + "/start.sh", "w").write(st["run"])
    if st.get("name", "").startswith("сторож"):
        open(sys.argv[2] + "/watch.sh", "w").write(st["run"])
        assert "steps.summary.conclusion == 'skipped'" in str(st.get("if")), "сторож должен спрашивать «итог пропущен»"
assert any(st.get("id") == "summary" for st in steps), "у итог-шага нет id: summary"
PY
mkdir -p "$tmp/bin"
cat > "$tmp/bin/curl" <<'EOS'
#!/usr/bin/env bash
# Дописываем, не затираем: у сторожа два вызова подряд (ответ и правка), нужны оба.
url=""; while [ $# -gt 0 ]; do case "$1" in --data-urlencode) printf '%s\n' "$2" >> "$STUB_CURL_FILE"; shift;; http*) url="$1";; esac; shift; done
printf 'URL=%s\n' "${url##*/}" >> "$STUB_CURL_FILE"
case "${STUB_TG:-ok}" in ok) printf '{"ok":true,"result":{"message_id":7}}';; *) printf '{"ok":false,"description":"boom"}';; esac
EOS
cat > "$tmp/bin/date" <<'EOS'
#!/usr/bin/env bash
[ "${1:-}" = +%H ] && { echo "${FAKE_HOUR:-12}"; exit 0; }; exec /bin/date "$@"
EOS
chmod +x "$tmp/bin/curl" "$tmp/bin/date"
export PATH="$tmp/bin:$PATH" STUB_CURL_FILE="$tmp/curl.txt"
reset(){ : > "$STUB_CURL_FILE"; }
export REPO_URL=https://github.com/x/y REPO=x/y LINK=https://github.com/x/y/pull/1 RUN_URL=https://github.com/x/y/actions/runs/1 NUM_PREFIX="#1 " TITLE="t &amp; u" ENV_SUFFIX="" SERVICE=s
export TELEGRAM_BOT_TOKEN=tok TELEGRAM_DEVSUPPORT_CHAT=1 TELEGRAM_DEVSUPPORT_THREAD=9 GITHUB_OUTPUT="$tmp/gh-out"
sent(){ grep -qx "$1" "$STUB_CURL_FILE"; }

reset; FAKE_HOUR=03 bash -e "$tmp/start.sh" > "$tmp/log" 2>&1 || bad "старт 03ч упал: $(cat "$tmp/log")"
sent 'disable_notification=true' && grep -q 'ночь' "$tmp/log" && ok "03ч по зоне → старт без звука" || bad "03ч: $(cat "$STUB_CURL_FILE" "$tmp/log")"
grep -q '^mid=7$' "$GITHUB_OUTPUT" && ok "mid из ответа → GITHUB_OUTPUT" || bad "mid: $(cat "$GITHUB_OUTPUT")"
reset; FAKE_HOUR=12 bash -e "$tmp/start.sh" > "$tmp/log" 2>&1 || bad "старт 12ч упал"
! sent 'disable_notification=true' && grep -q 'день' "$tmp/log" && ok "12ч → старт со звуком" || bad "12ч: $(cat "$STUB_CURL_FILE")"
reset; FAKE_HOUR=08 bash -e "$tmp/start.sh" > "$tmp/log" 2>&1 || bad "старт 08ч упал"
! sent 'disable_notification=true' && ok "08ч — граница, уже день" || bad "08ч тихий"
reset; FAKE_HOUR=00 TELEGRAM_QUIET_TZ=Etc/UTC bash -e "$tmp/start.sh" > "$tmp/log" 2>&1 || bad "старт 00ч упал"
sent 'disable_notification=true' && grep -q 'Etc/UTC' "$tmp/log" && ok "зона из TELEGRAM_QUIET_TZ печатается и работает" || bad "tz: $(cat "$tmp/log")"

reset; MID=5 bash -e "$tmp/watch.sh" > "$tmp/log" 2>&1 || bad "сторож упал: $(cat "$tmp/log")"
sent 'reply_to_message_id=5' && sent 'message_thread_id=9' && grep -q '^text=⏳' "$STUB_CURL_FILE" && sent 'message_id=5' && grep -q 'URL=editMessageText' "$STUB_CURL_FILE" && ok "сторож: ⏳ ответом в теме и правка старта" || bad "сторож: $(cat "$STUB_CURL_FILE")"
reset; MID=5 STUB_TG=fail bash -e "$tmp/watch.sh" > "$tmp/log" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'сторож не прошёл' "$tmp/log" && grep -q 'правка старта на ⏳ не прошла' "$tmp/log" && ok "сторож при ok:false не падает, оба предупреждения в журнале" || bad "сторож fail: rc=$rc $(cat "$tmp/log")"

[ "$fail" = 0 ] && echo "deliver-smoke: OK" || { echo "deliver-smoke: FAIL"; exit 1; }
