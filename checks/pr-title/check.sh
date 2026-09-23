#!/usr/bin/env bash
# Заголовок PR — человеческим предложением, как в репозитории Claude Code (dippstack/ais#788):
#   «diff: a resumed session with edits opens the pane»   — область двоеточием, дальше что теперь происходит
#   «Add issue template for GitHub connection problems»   — или просто предложение
# Без типа `feat(scope):` — тип ничего не говорит читателю чата, а чип в Telegram цитирует именно
# заголовок сквош-коммита, то есть заголовок PR. Что ловим: префикс conventional commits,
# заглушку `task #N: slug` от dl land, меньше трёх слов, точку в конце, пустоту.
#
# Usage: check.sh "<заголовок>"   → rc 0 ок; rc 1 + причина в stdout
set -uo pipefail
t="${1:-}"
t="${t#"${t%%[![:space:]]*}"}"; t="${t%"${t##*[![:space:]]}"}"   # обрезать пробелы по краям
[ -n "$t" ] || { echo "пустой заголовок"; exit 1; }
shopt -s nocasematch
# Регексы — в переменных: скобки внутри [[ =~ ]] bash разбирает как синтаксис.
# Голый тип ловим только у тех слов, что областями не бывают (ci:, docs:, test: — законные области,
# как mods/agents-md: у Claude Code); форма со скобками или «!» — conventional при любом слове.
type_re='^((feat|fix|chore|refactor|build|perf|style|revert|wip)!?:|[a-z]+(\([^)]*\))!?:|[a-z]+!:)'
stub_re='^task #[0-9]+:'
if [[ "$t" =~ $type_re ]]; then
  echo "префикс типа «${BASH_REMATCH[0]}» — тип читателю ничего не говорит; напиши, что теперь происходит: «область: предложение» или просто предложение"; exit 1
fi
if [[ "$t" =~ $stub_re ]]; then
  echo "заглушка «task #N: slug» от dl land — дай PR человеческий заголовок до ревью"; exit 1
fi
shopt -u nocasematch
body="$t"
# «область: …» — область без пробелов и с маленькой буквы (diff, mods/agents-md, deliver); дальше само предложение.
area_re='^([a-z0-9][a-z0-9/._-]*): (.+)$'
if [[ "$t" =~ $area_re ]]; then body="${BASH_REMATCH[2]}"; fi
words="$(printf '%s' "$body" | tr -s '[:space:]' '\n' | grep -c .)"
[ "$words" -ge 3 ] || { echo "слишком коротко (${words} сл.): заголовок — предложение о том, что изменилось для читателя"; exit 1; }
[[ "$body" != *. ]] || { echo "точка в конце не нужна"; exit 1; }
# Длину считаем символами через python: ${#t} под локалью C раннера считает байты, и русский заголовок
# на 74 символа «весит» 132 байта. Лимит 160: заголовки issue у флота длинные, чип сам режет до 80.
len_chars="$(python3 -c 'import sys; print(len(sys.argv[1]))' "$t" 2>/dev/null || printf '%s' "${#t}")"
[ "$len_chars" -le 160 ] || { echo "длиннее 160 символов ($len_chars) — чип в чате обрежет; главное в первые 80"; exit 1; }
echo "ок"
