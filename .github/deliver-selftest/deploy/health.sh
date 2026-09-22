#!/usr/bin/env bash
# Фикстура deliver-selftest: контракт deploy/health.sh <sha> — rc 1 «ещё нет», пока autodeploy.sh
# не оставил метку, потом rc 2 «хост отверг этот SHA». Так шлюз успевает получить журнал, а не
# пустой хвост. rc 0 не бывает: это фикстура красного пути.
[ -f "$HOME/.deliver/selftest-${1:-none}.red" ] && exit 2
exit 1
