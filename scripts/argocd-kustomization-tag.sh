#!/usr/bin/env bash
# Читает newTag образа из kustomization.yaml (stdin). deliver.yml, driver=argocd.
set -euo pipefail
deploy="${1:?deployment name}"
python3 -c '
import re, sys
deploy = sys.argv[1]
text = sys.stdin.read()
m = re.search(rf"name: {re.escape(deploy)}\n(?:.*\n){0,6}?    newTag: (\S+)", text)
if not m:
    raise SystemExit("newTag не найден для " + deploy)
print(m.group(1))
' "$deploy"
