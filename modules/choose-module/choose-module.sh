#!/bin/sh
LC_ALL=C
export LC_ALL
seed=$(od -An -N4 -tu4 </dev/urandom 2>/dev/null)
while [ "${seed# }" != "$seed" ]; do seed=${seed# }; done
while [ "${seed% }" != "$seed" ]; do seed=${seed% }; done
case "$seed" in ''|*[!0-9]*) seed=$$ ;; esac
exec awk -v seed="$seed" -f ./module_json.awk -f ./choose-module.awk
