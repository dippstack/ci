#!/usr/bin/env bash
# Пути к точкам входа продукта в deliver.yml без сети. Извлекает run шагов «входы драйвера»,
# запуска автовыкатки и health из YAML и гоняет их локально (deploy-host пуст = хост и есть
# раннер) на фикстуре, где точки входа лежат не там, где раньше: infra/host/{autodeploy,health}.sh.
# Проверяет: параметры deploy-script/health-script доезжают до хоста; по умолчанию остаются
# deploy/autodeploy.sh и deploy/health.sh (стабы без параметров не ломаются); путь с «..»,
# абсолютный или с метасимволами оболочки отвергается до ssh. Запуск: bash checks/deliver-paths/test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fail=1; }
python3 - "$HERE/.github/workflows/deliver.yml" "$tmp" <<'PY' || { echo "  ✗ yaml не разобран (нужен pyyaml)"; exit 1; }
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
steps = d["jobs"]["deliver"]["steps"]
# Шаги берём по содержимому, а не по имени: тест должен падать на путях, а не на переименовании.
def pick(what, marker):
    found = [st["run"] for st in steps if marker in st.get("run", "")]
    assert len(found) == 1, f"шаг «{what}» (маркер {marker!r}) не найден ровно один раз"
    return found[0]
open(sys.argv[2] + "/inputs.sh", "w").write(pick("входы драйвера", "неизвестный driver"))
open(sys.argv[2] + "/deploy.sh", "w").write(pick("запуск автовыкатки", "nohup bash"))
open(sys.argv[2] + "/health.sh", "w").write(pick("ожидание health", "DEADLINE="))
PY

# Фикстура продукта: точки входа по каноническим путям, старых нет. autodeploy оставляет метку,
# health отвечает 0 только после неё — так проверяется, что оба пути дошли до хоста.
prod="$tmp/product"; mkdir -p "$prod/infra/host"
cat > "$prod/infra/host/autodeploy.sh" <<'EOS'
echo ran > "$PWD/.autodeploy-ran"
EOS
cat > "$prod/infra/host/health.sh" <<'EOS'
[ -f "$PWD/.autodeploy-ran" ] && exit 0
exit 1
EOS
( cd "$prod" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "fixture (#1)" )

base_env(){ # чистое окружение шага, как у GitHub
  SHA="$(git -C "$prod" rev-parse HEAD)"
  export DRIVER=script DEPLOY_HOST="" DEPLOY_DIR="$prod" HEALTH_TIMEOUT=2 SHA
  export SERVICE=s LOG_NAME=s REPO=x/y REPO_URL=https://github.com/x/y ENVIRONMENT=dev
  export GITHUB_ENV="$tmp/github_env" RUNNER_TEMP="$tmp/rt"; : > "$GITHUB_ENV"; mkdir -p "$RUNNER_TEMP"
  export HOME="$tmp/home"; mkdir -p "$HOME"
}
step(){ # $1 = файл шага; запуск под bash -e из клона продукта, как на раннере
  ( cd "$prod" && bash -e "$tmp/$1" ) > "$tmp/out" 2>&1
}

echo "▶ параметры доезжают до хоста"
base_env; export DEPLOY_SCRIPT=infra/host/autodeploy.sh HEALTH_SCRIPT=infra/host/health.sh
rm -f "$prod/.autodeploy-ran"
if step inputs.sh; then ok "входы приняты"; else bad "входы отвергнуты: $(tail -1 "$tmp/out")"; fi
step deploy.sh; for _ in 1 2 3 4 5; do [ -f "$prod/.autodeploy-ran" ] && break; sleep 0.2; done
if [ -f "$prod/.autodeploy-ran" ]; then ok "запущен infra/host/autodeploy.sh"; else bad "infra/host/autodeploy.sh не запускался: $(tail -2 "$tmp/out" | tr '\n' ' ')"; fi
if step health.sh; then ok "health по infra/host/health.sh зелёный"; else bad "health по infra/host/health.sh не позеленел: $(grep -v '^$' "$tmp/out" | tail -1)"; fi

echo "▶ по умолчанию прежние пути (стаб без параметров)"
base_env; unset DEPLOY_SCRIPT HEALTH_SCRIPT
python3 - "$HERE/.github/workflows/deliver.yml" <<'PY' > "$tmp/defaults" || bad "у deliver.yml нет входов deploy-script/health-script"
import sys, yaml
i = yaml.safe_load(open(sys.argv[1]))[True]["workflow_call"]["inputs"]
print(i["deploy-script"]["default"], i["health-script"]["default"])
PY
if [ "$(cat "$tmp/defaults")" = "deploy/autodeploy.sh deploy/health.sh" ]; then ok "по умолчанию deploy/autodeploy.sh и deploy/health.sh"; else bad "умолчания: '$(cat "$tmp/defaults")'"; fi

echo "▶ опасный путь отвергается до ssh"
for p in '../x.sh' '/etc/x.sh' 'a;rm -rf ~.sh' 'a b.sh' 'a$(id).sh' ''; do
  base_env; export DEPLOY_SCRIPT="$p" HEALTH_SCRIPT=infra/host/health.sh
  if step inputs.sh; then bad "принят deploy-script '$p'"; else ok "отвергнут deploy-script '$p'"; fi
  base_env; export DEPLOY_SCRIPT=infra/host/autodeploy.sh HEALTH_SCRIPT="$p"
  if step inputs.sh; then bad "принят health-script '$p'"; else ok "отвергнут health-script '$p'"; fi
done

[ "$fail" = 0 ] && echo "deliver-paths: всё зелёное" || { echo "deliver-paths: есть провалы"; exit 1; }
