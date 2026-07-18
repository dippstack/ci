#!/usr/bin/env bash
# bump-stubs.sh — обновить пин SHA reusable во ВСЕХ репах-потребителях (consumers.txt)
# до текущего main этого репо (dippstack/ci). Открывает PR в каждой (не пушит в main).
# Так пин по SHA (immutable, supply-chain-safe) остаётся удобным: правишь рецепт здесь →
# `bash bump-stubs.sh` → PR-ы с новым SHA во всех репах.
#
#   bash bump-stubs.sh              # бампнуть до HEAD dippstack/ci
#   bash bump-stubs.sh <sha>        # до конкретного SHA
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEWSHA="${1:-$(gh api repos/dippstack/ci/commits/main --jq '.sha')}"
echo "Бамп reusable-пина → $NEWSHA"

while read -r repo stack _; do
  [ -z "${repo:-}" ] && continue
  case "$repo" in \#*) continue;; esac
  echo "== $repo ($stack) =="
  br="ci/bump-${NEWSHA:0:8}"
  base="$(gh api "repos/$repo/git/ref/heads/main" --jq '.object.sha')"
  gh api -X POST "repos/$repo/git/refs" -f ref="refs/heads/$br" -f sha="$base" >/dev/null 2>&1 || true
  cur="$(gh api "repos/$repo/contents/.github/workflows/ci.yml?ref=$br" --jq '.sha')"
  new="$(gh api "repos/$repo/contents/.github/workflows/ci.yml?ref=$br" --jq '.content' | base64 -d \
        | sed -E "s#(ci-${stack}\\.yml@)[a-f0-9]+#\\1${NEWSHA}#")"
  b64="$(printf '%s' "$new" | base64 | tr -d '\n')"
  gh api -X PUT "repos/$repo/contents/.github/workflows/ci.yml" \
    -f message="ci: bump reusable pin → ${NEWSHA:0:8}" -f branch="$br" -f sha="$cur" \
    -f content="$b64" >/dev/null
  gh pr create --repo "$repo" --base main --head "$br" \
    --title "ci: bump reusable pin → ${NEWSHA:0:8}" \
    --body "Автобамп пина dippstack/ci reusable (bump-stubs.sh). Мержить после зелёного CI." 2>&1 | tail -1
done < "$here/consumers.txt"
echo "Готово. Проверь и слей PR-ы (CI прогонит новый рецепт)."
