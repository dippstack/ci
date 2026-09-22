#!/usr/bin/env bash
# Причина ошибки выкатки словами — для итогового сообщения шлюза в Телеграм (dippstack/ais#784).
#
# Вход — env:
#   EXPLAIN_TITLE   заголовок PR/коммита («fix(server): гонка при повторной отправке заявки»)
#   EXPLAIN_REASON  техническая причина из шлюза, одна строка («Хост отверг коммит: проверка красная»)
#   EXPLAIN_TAIL    файл с хвостом журнала хоста; может отсутствовать
#   GBRAIN_SOURCE   yan | ais | marketplace — брейн проекта для «похожего случая»; пусто = без брейна
#   EXPLAIN_TIMEOUT секунд на ответ модели (по умолчанию 60)
# Выход — stdout, не больше двух строк:
#   1: одно предложение «что случилось», без разметки; состояние прода сюда НЕ входит — его
#      добавляет шлюз фразой закрытого словаря
#   2: `похожий случай: <slug>` — только если модель узнала в странице брейна тот же сбой
# Любая беда (нет claude, нет токена, таймаут, пустой ответ, «Not logged in») → пустой stdout,
# rc 0: шлюз покажет техническую причину и хвост лога, как раньше. Модель — необязательный слой,
# который не имеет права уронить итоговое сообщение.
#
# claude и токен берутся так же, как у ботов флота на этом же хосте: бинарь в ~/.local/bin,
# долгоживущий CLAUDE_CODE_OAUTH_TOKEN в ~/.config/dippstack/claude-oauth.env, брейны — адреса
# BRAIN_<SOURCE>_URL в ~/.config/dippstack/brains.env. Ничего из этого в GitHub Settings нет.
set -uo pipefail
TITLE="${EXPLAIN_TITLE:-}"; REASON="${EXPLAIN_REASON:-}"; TAIL_FILE="${EXPLAIN_TAIL:-}"
SRC="${GBRAIN_SOURCE:-}"; TIMEOUT="${EXPLAIN_TIMEOUT:-60}"
MODEL=claude-sonnet-5; BRAIN_TIMEOUT=15   # Sonnet отвечает за 5–6 с (проба 23.09), Haiku медленнее и слабее
log(){ printf 'explain-failure: %s\n' "$*" >&2; }

# Без HOME (голый env в контейнере) токена и бинаря всё равно нет — выходим тихо, не падаем на set -u.
: "${HOME:=/nonexistent}"
PATH="$HOME/.local/bin:$PATH"
command -v claude >/dev/null 2>&1 || { log "claude не найден — без модели"; exit 0; }
# Лимит по времени — часть контракта: без coreutils timeout модель не зовём вовсе.
command -v timeout >/dev/null 2>&1 || { log "нет timeout — без модели"; exit 0; }
if [ -f "$HOME/.config/dippstack/claude-oauth.env" ]; then
  # shellcheck disable=SC1091
  set -a; . "$HOME/.config/dippstack/claude-oauth.env"; set +a
fi
[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || { log "нет CLAUDE_CODE_OAUTH_TOKEN — без модели"; exit 0; }
unset CLAUDE_CONFIG_DIR   # env-токен перебивает keychain и файл; config-dir тут только мешает

# Хвост лога: ANSI-цвета долой (журнал хоста цветной), последние 40 строк.
TAIL=""
if [ -n "$TAIL_FILE" ] && [ -f "$TAIL_FILE" ]; then
  TAIL="$(sed -E $'s/\e\\[[0-9;]*[A-Za-z]//g' "$TAIL_FILE" | tail -n 40)"
fi

# Похожий случай: страницы брейна проекта по заголовку, причине и строкам с ошибкой из хвоста.
# Счёт поиска не отличает «тот же сбой» от «та же тема», поэтому решает модель, а не порог.
HITS=""
if [ -n "$SRC" ] && command -v gbrain >/dev/null 2>&1 && [ -f "$HOME/.config/dippstack/brains.env" ]; then
  # shellcheck disable=SC1091
  . "$HOME/.config/dippstack/brains.env"
  var="BRAIN_$(printf '%s' "$SRC" | tr '[:lower:]-' '[:upper:]_')_URL"
  url="${!var:-}"
  if [ -n "$url" ]; then
    errs="$(printf '%s\n' "$TAIL" | grep -iE 'error|fail|✗|❌|красн|отка|упал|denied|refused|timeout' | tail -n 3 || true)"
    q="$(printf '%s %s %s' "$TITLE" "$REASON" "$errs" | tr '\n' ' ' | cut -c1-300)"
    HITS="$(GBRAIN_DATABASE_URL="$url" timeout "$BRAIN_TIMEOUT" gbrain search "$q" --limit 3 --snippet-chars 240 2>/dev/null \
            | grep -E '^\[[0-9.]+\] ' || true)"
  else
    log "нет $var в brains.env — без похожего случая"
  fi
fi

SYS="Ты пишешь для дежурного разработчика в Телеграм, почему выкатка не прошла.
Первая строка ответа — ОДНО предложение по-русски: что случилось, без разметки, без вводных
слов, без догадок сверх лога. Назови конкретную строку лога, если она объясняет причину.
Не пиши про состояние прода — это добавят отдельно.
Если лог кончается на «другой экземпляр ещё бежит / пропуск тика» — скажи, что катил таймер
хоста и причина в его журнале. Если причины в хвосте не видно — так и скажи и назови, что видно.
Если среди страниц брейна есть та, что описывает ТОТ ЖЕ сбой (не ту же тему), добавь второй
строкой ровно: похожий случай: <slug страницы>. Иначе второй строки нет."
SKILL="$HOME/.claude/skills/humanize/SKILL.md"
if [ -f "$SKILL" ]; then
  SYS="$SYS

Стиль — по правилам ниже (скилл humanize):
$(cat "$SKILL")"
fi

PROMPT="$(printf 'Выкатка: %s\nЧто сказал шлюз: %s\n\nХвост журнала хоста:\n%s\n' \
  "$TITLE" "$REASON" "${TAIL:-(хвоста нет)}")"
if [ -n "$HITS" ]; then
  PROMPT="$PROMPT
Страницы брейна проекта по поиску (могут не подходить):
$HITS"
fi

RAW="$(printf '%s' "$PROMPT" | timeout "$TIMEOUT" claude -p --model "$MODEL" --tools "" --max-turns 1 \
        --no-session-persistence --output-format text --append-system-prompt "$SYS" 2>/dev/null \
        | tr -d '\r' | sed -E '/^[[:space:]]*$/d')" || RAW=""
case "$RAW" in *"Not logged in"*|*"Invalid API key"*|*"API Error"*) log "claude не авторизован: ${RAW:0:120}"; RAW="";; esac
# Предложение — первая строка, которая не «похожий случай: …»: голый slug вместо причины не печатаем.
SENTENCE="$(printf '%s\n' "$RAW" | grep -v '^[[:space:]]*похожий случай:' | head -n 1)"
[ -n "$SENTENCE" ] || { log "модель не ответила за ${TIMEOUT}с — без модели"; exit 0; }
[ "${#SENTENCE}" -le 400 ] || SENTENCE="${SENTENCE:0:399}…"
printf '%s\n' "$SENTENCE"

# Slug модели принимаем, только если он из выданных ей страниц — выдумать «похожий случай» нельзя.
SLUG="$(printf '%s\n' "$RAW" | sed -n 's/^[[:space:]]*похожий случай:[[:space:]]*//p' | head -n 1 | tr -d '`* ')"
if [ -n "$SLUG" ] && printf '%s\n' "$HITS" | awk '{print $2}' | grep -qxF "$SLUG"; then
  printf 'похожий случай: %s\n' "$SLUG"
fi
exit 0
