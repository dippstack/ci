#!/usr/bin/env bash
# Фикстура deliver-selftest: «выкатка», которая всегда падает на гейте. Пишет журнал в форме
# CD marketspace (с ANSI-цветами — их шлюз обязан вычистить) и оставляет метку для health.sh.
# Ничего не деплоит. Шлюз запускает этот файл отцепленно и пишет stdout в ~/.deliver/deliver-selftest.log.
set -uo pipefail
sha="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
echo "### CD: гейт на candidate ${sha:0:7} (фикстура deliver-selftest, ничего не катится)"
printf '  \033[32m✓\033[0m слой 14_cash_inflow.sql\n'
printf '  \033[31m✗\033[0m слой 15_sku_pnl.sql: ERROR:  column "net_price" does not exist\n'
echo '  LINE 12:   sum(net_price) as pnl'
printf '  \033[31mСЛОИ: КРАСНО\033[0m — 1 из 17 слоёв не применился\n'
echo "ВЕРДИКТ: КРАСНО (тир=selftest) — доказано: старое не сломано, новое не поднялось."
echo "### CD: гейт красный на ${sha:0:7} — откат хаба (ADR-0013)"
echo "### откат: ok (перегрузок снято 2, вьюх 0)"
mkdir -p "$HOME/.deliver" && : > "$HOME/.deliver/selftest-$sha.red"
