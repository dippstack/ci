#!/usr/bin/env bash
# Ждёт Application Argo CD и смоук по HTTP. deliver.yml, driver=argocd.
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

while :; do
  sync="$(kubectl -n argocd get application "$APP" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  health="$(kubectl -n argocd get application "$APP" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  img="$(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  tag="${img##*:}"
  if [ "$sync" = Synced ] && [ "$health" = Healthy ] && [ "$tag" = "$EXPECTED_TAG" ]; then
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
