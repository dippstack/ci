#!/usr/bin/env bash
# Тест дайджеста дня (dippstack/ais#785) на фикстурах: счёт, чипы, дата словами, пропуск без работы.
# Запуск: bash checks/deploy-digest/tests/test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
fail=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fail=1; }
C="$HERE/compose.sh"; F="$HERE/tests"

out="$(DIGEST_REPO=yan-app/yan-monorepo DIGEST_DATE=2026-10-10 bash "$C" < "$F/day.json")"; rc=$?
[ "$rc" = 0 ] && ok "день с красными: rc 0" || bad "rc=$rc"
first="$(printf '%s\n' "$out" | sed -n 1p)"
[[ "$first" == '📋 <a href="https://github.com/yan-app/yan-monorepo">yan-app/yan-monorepo</a>, 10 октября: 4 выкатки за сутки, 1 не докатилась, 1 без итога.' ]] && ok "первая строка: дата словами, репо ссылкой, счёт (бегущий прогон не считается)" || bad "первая строка: $first"
printf '%s\n' "$out" | grep -q '^❌ <a href="https://github.com/yan-app/yan-monorepo/pull/689">#689 server: гонка при повторной отправке заявки &amp; выход</a>$' && ok "красный: чип на PR, (#N) вырезан, & экранирован" || bad "красный: $(printf '%s\n' "$out" | grep '^❌')"
printf '%s\n' "$out" | grep -q '^⏳ <a href="https://github.com/yan-app/yan-monorepo/actions/runs/3">deps: expo 54.0.3, reanimated 4.1</a>$' && ok "висящий (cancelled): чип на прогон, без номера" || bad "висящий: $(printf '%s\n' "$out" | grep '^⏳')"
[ "$(printf '%s\n' "$out" | grep -c '^✅')" = 0 ] && ok "зелёные поимённо не перечисляются" || bad "зелёные в списке"
printf '%s\n' "$out" | grep -q '^<i>Красные и висящие' && ok "хвостовая строка курсивом" || bad "нет хвостовой строки"

out="$(DIGEST_REPO=x/y DIGEST_DATE=2026-10-01 bash "$C" < "$F/green.json")"
[ "$out" = '📋 <a href="https://github.com/x/y">x/y</a>, 1 октября: 2 выкатки за сутки, все зелёные.' ] && ok "все зелёные — одна строка" || bad "green: $out"

out="$(DIGEST_REPO=x/y bash "$C" <<< '[]')"; rc=$?
[ "$rc" = 3 ] && [ -z "$out" ] && ok "работы не было → пусто, rc 3" || bad "empty: rc=$rc out=$out"
out="$(DIGEST_REPO=x/y DIGEST_MIN_RUNS=3 DIGEST_DATE=2026-10-01 bash "$C" < "$F/green.json")"; rc=$?
[ "$rc" = 3 ] && ok "меньше min-runs → пропуск" || bad "min-runs: rc=$rc"
out="$(DIGEST_REPO=x/y bash "$C" <<< 'мусор' 2>/dev/null)"; rc=$?
[ "$rc" = 2 ] && ok "не JSON → rc 2" || bad "junk: rc=$rc"
one="$(DIGEST_REPO=x/y DIGEST_DATE=2026-10-21 bash "$C" <<< '[{"conclusion":"success","status":"completed","displayTitle":"t","url":"u"}]')"
[[ "$one" == *"21 октября: 1 выкатка за сутки, все зелёные."* ]] && ok "склонение: 1 выкатка" || bad "plural: $one"
five="$(DIGEST_REPO=x/y DIGEST_DATE=2026-10-21 bash "$C" <<< '[{"conclusion":"failure","status":"completed","displayTitle":"a","url":"u"},{"conclusion":"failure","status":"completed","displayTitle":"b","url":"u"},{"conclusion":"failure","status":"completed","displayTitle":"c","url":"u"},{"conclusion":"failure","status":"completed","displayTitle":"d","url":"u"},{"conclusion":"failure","status":"completed","displayTitle":"e","url":"u"}]')"
[[ "$five" == *"5 выкаток за сутки, 5 не докатились."* ]] && ok "склонение: 5 выкаток, 5 не докатились" || bad "plural5: $(printf '%s\n' "$five" | sed -n 1p)"
[ "$fail" = 0 ] && echo "deploy-digest: OK" || { echo "deploy-digest: FAIL"; exit 1; }
