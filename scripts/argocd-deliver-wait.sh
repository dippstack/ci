#!/usr/bin/env bash
# Ждёт Application Argo CD и смоук по HTTP. deliver.yml, driver=argocd.
# Тег образа берём из Application.status.summary.images (RBAC ci:smoke не читает Deployment).
set -euo pipefail
APP="${1:?argocd application}"
NS="${2:?namespace с Deployment}"
DEPLOY="${3:?deployment}"
EXPECTED_TAG="${4:?short image tag}"
TIMEOUT="${5:-900}"
export KUBECONFIG="${KUBECONFIG:-${6:-$HOME/.kube/config}}"
HEALTH_BASE="${7:?base URL}"
health_base="${HEALTH_BASE%/}"
deadline=$(( $(date +%s) + TIMEOUT ))

tag_from_app() {
  local imgs tag img
  imgs="$(kubectl -n argocd get application "$APP" -o jsonpath='{range .status.summary.images[*]}{.}{"\n"}{end}' 2>/dev/null || true)"
  tag=""
  while IFS= read -r img; do
    [ -n "$img" ] || continue
    case "$img" in
      *"/${DEPLOY}:"*) tag="${img##*:}"; break ;;
    esac
  done <<< "$imgs"
  if [ -z "$tag" ]; then
    img="$(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
    tag="${img##*:}"
  fi
  printf '%s' "$tag"
}

while :; do
  sync="$(kubectl -n argocd get application "$APP" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  health="$(kubectl -n argocd get application "$APP" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  tag="$(tag_from_app)"
  if [ "$sync" = Synced ] && [ "$health" = Healthy ] && [ -n "$tag" ] && [ "$tag" = "$EXPECTED_TAG" ]; then
    if curl -fsS --max-time 10 "${health_base}/health" >/dev/null \
      && curl -fsS --max-time 15 "${health_base}/ready" >/dev/null; then
      echo "✅ argocd: $APP Synced, :$tag на $DEPLOY, смоук ok"
      exit 0
    fi
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "❌ timeout ${TIMEOUT}s sync=$sync health=$health tag=${tag:-?} want=$EXPECTED_TAG" >&2
    exit 1
  fi
  echo "… $APP sync=$sync health=$health tag=${tag:-?} want=$EXPECTED_TAG"
  sleep 15
done
