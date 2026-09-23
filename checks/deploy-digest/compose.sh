#!/usr/bin/env bash
# Дайджест дня выкаток прозой (dippstack/ais#785). Вход — stdin: JSON-массив прогонов deliver за
# сутки в форме `gh run list --json conclusion,status,displayTitle,url,headSha,createdAt`.
# Выход — HTML для Telegram: дата словами, репо ссылкой, сколько выкачено, красные и висящие
# поимённо чипами. Работы не было (прогонов меньше DIGEST_MIN_RUNS, по умолчанию 1) — пусто, rc 3:
# дайджест не нужен, это правило владельца, а не сбой.
#
# Env: DIGEST_REPO=org/repo (обязателен), DIGEST_REPO_URL (по умолчанию https://github.com/$DIGEST_REPO),
#      DIGEST_DATE=YYYY-MM-DD (по умолчанию сегодня по DIGEST_TZ, умолчание Europe/Moscow), DIGEST_MIN_RUNS.
set -uo pipefail
REPO="${DIGEST_REPO:?DIGEST_REPO=org/repo}"; REPO_URL="${DIGEST_REPO_URL:-https://github.com/$REPO}"
MIN="${DIGEST_MIN_RUNS:-1}"; TZN="${DIGEST_TZ:-Europe/Moscow}"
DATE="${DIGEST_DATE:-$(TZ="$TZN" date +%Y-%m-%d)}"
command -v python3 >/dev/null || { echo "compose: нет python3" >&2; exit 2; }
# Разбор JSON и сборка — в python: bash без jq JSON не читает, а jq на узлах не везде.
# Вход — во временный файл: heredoc со скриптом сам занимает stdin.
IN="$(mktemp)"; trap 'rm -f "$IN"' EXIT; cat > "$IN"
DIGEST_REPO="$REPO" DIGEST_REPO_URL="$REPO_URL" DIGEST_MIN_RUNS="$MIN" DIGEST_DATE="$DATE" DIGEST_IN="$IN" python3 - <<'PY'
import json, os, sys, html, re, datetime

repo = os.environ["DIGEST_REPO"]; repo_url = os.environ["DIGEST_REPO_URL"]
min_runs = int(os.environ["DIGEST_MIN_RUNS"]); date = os.environ["DIGEST_DATE"]
try:
    runs = json.load(open(os.environ["DIGEST_IN"], encoding="utf-8"))
except Exception as e:
    print(f"compose: вход не JSON: {e}", file=sys.stderr); sys.exit(2)
if not isinstance(runs, list):
    print("compose: ожидался массив прогонов", file=sys.stderr); sys.exit(2)
# Только завершённые прогоны: бегущий сейчас — не итог дня.
runs = [r for r in runs if (r.get("status") or "completed") == "completed"]
if len(runs) < min_runs:
    sys.exit(3)

def plural(n, one, few, many):
    n = abs(n) % 100
    if 11 <= n <= 19: return many
    n %= 10
    if n == 1: return one
    if 2 <= n <= 4: return few
    return many

MONTHS = ["января","февраля","марта","апреля","мая","июня","июля","августа","сентября","октября","ноября","декабря"]
try:
    d = datetime.date.fromisoformat(date); date_words = f"{d.day} {MONTHS[d.month-1]}"
except Exception:
    date_words = date

def chip(r):
    title = (r.get("displayTitle") or "").strip().splitlines()[0] if (r.get("displayTitle") or "").strip() else "(без заголовка)"
    m = re.search(r"\s\(#(\d+)\)$", title)
    if m:
        num, title, link = f"#{m.group(1)} ", title[:m.start()], f"{repo_url}/pull/{m.group(1)}"
    else:
        num, link = "", r.get("url") or repo_url
    if len(title) > 80: title = title[:79] + "…"
    return f'<a href="{html.escape(link, quote=True)}">{num}{html.escape(title)}</a>'

# Один словарь исходов: зелёные, красные, висящие; skipped — не выкатка, в счёт не входит.
RED = ("failure", "timed_out", "startup_failure")
ok   = [r for r in runs if r.get("conclusion") == "success"]
red  = [r for r in runs if r.get("conclusion") in RED]
tail = [r for r in runs if r.get("conclusion") not in ("success", "skipped") and r.get("conclusion") not in RED]
n = len(ok) + len(red) + len(tail)
if n < min_runs:
    sys.exit(3)
# Лимит Telegram 4096: чипов не больше CAP, остальное — «и ещё M»; красные важнее висящих.
CAP = 12
head = f'📋 <a href="{html.escape(repo_url, quote=True)}">{html.escape(repo)}</a>, {date_words}: '
parts = []
if n == len(ok):
    parts.append(f"{n} {plural(n,'выкатка','выкатки','выкаток')} за сутки, все зелёные.")
else:
    s = f"{n} {plural(n,'выкатка','выкатки','выкаток')} за сутки"
    if red:  s += f", {len(red)} не {plural(len(red),'докатилась','докатились','докатились')}"
    if tail: s += f", {len(tail)} без итога"
    parts.append(s + ".")
lines = [head + " ".join(parts)]
named = [("❌ ", r) for r in red] + [("⏳ ", r) for r in tail]
for icon, r in named[:CAP]: lines.append(icon + chip(r))
rest = len(named) - CAP
if rest > 0: lines.append(f"…и ещё {rest} {plural(rest,'прогон','прогона','прогонов')} без зелёного итога — в Actions за сутки.")
if red or tail:
    lines.append("<i>Красные и висящие — выше поимённо; зелёные уже были в ленте.</i>")
print("\n".join(lines))
PY
