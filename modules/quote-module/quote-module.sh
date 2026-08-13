#!/bin/sh
# TNT quote-module: a random proverb sharer for tnt.module.v1.
#
# Reacts to chat messages that begin with "/quote" and replies with a random
# proverb. All other messages are acknowledged with a no-op so the module stays
# quiet during normal chat.
#
# The built-in list is intentionally common, public-domain proverbs without
# attribution, to avoid misquoting anyone.

json_escape() {
  printf '%s' "$1" | LC_ALL=C awk '
    BEGIN {
      ORS = ""
      hex = "0123456789abcdef"
      for (i = 1; i <= 255; i++) byte[sprintf("%c", i)] = i
    }
    {
      if (NR > 1) printf "%s", "\\n"
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c == "\\") printf "%s", "\\\\"
        else if (c == "\"") printf "%s", "\\\""
        else if (c == "\b") printf "%s", "\\b"
        else if (c == "\f") printf "%s", "\\f"
        else if (c == "\t") printf "%s", "\\t"
        else if (c == "\r") printf "%s", "\\r"
        else {
          value = byte[c]
          if (value < 32 || value == 127) {
            printf "\\u00%s%s", substr(hex, int(value / 16) + 1, 1), \
                   substr(hex, (value % 16) + 1, 1)
          } else {
            printf "%s", c
          }
        }
      }
    }
  '
}

json_string_field() {
  scope=$1
  key=$2
  line=$3
  printf '%s\n' "$line" | LC_ALL=C awk -v scope="$scope" -v key="$key" \
    -f ./module_json.awk
}

seed_base=
seed_counter=0

next_seed() {
  if [ -z "$seed_base" ]; then
    seed_base=$(od -An -N4 -tu4 </dev/urandom 2>/dev/null)
    while [ "${seed_base# }" != "$seed_base" ]; do seed_base=${seed_base# }; done
    while [ "${seed_base% }" != "$seed_base" ]; do seed_base=${seed_base% }; done
    case "$seed_base" in ''|*[!0-9]*) seed_base=$$ ;; esac
  fi
  seed_counter=$((seed_counter + 1))
  event_seed=$(((seed_base + seed_counter) % 2147483646 + 1))
}

quote_result() {
  seed=$1

  awk -v seed="$seed" '
    BEGIN {
      srand(seed)
      n = 0
      q[++n] = "Well begun is half done."
      q[++n] = "A journey of a thousand miles begins with a single step."
      q[++n] = "Fortune favors the bold."
      q[++n] = "Still waters run deep."
      q[++n] = "Where there is a will, there is a way."
      q[++n] = "Actions speak louder than words."
      q[++n] = "The early bird catches the worm."
      q[++n] = "Necessity is the mother of invention."
      q[++n] = "Better late than never."
      q[++n] = "Practice makes perfect."
      q[++n] = "A picture is worth a thousand words."
      q[++n] = "Slow and steady wins the race."
      q[++n] = "Knowledge is power."
      q[++n] = "Hope for the best, prepare for the worst."
      q[++n] = "Measure twice, cut once."
      pick = int(rand() * n) + 1
      printf "❝ %s ❞\n", q[pick]
    }
  '
}

while IFS= read -r line; do
  type=$(json_string_field "" type "$line")
  if [ "$type" = "handshake" ]; then
    protocol=$(json_string_field "" protocol "$line")
    if [ "$protocol" = "tnt.module.v1" ]; then
      printf '{"type":"handshake.ok","protocol":"tnt.module.v1","module":{"name":"quote-module","version":"0.2.0"}}\n'
    else
      printf '{"type":"error","code":"unsupported_protocol","message":"requires tnt.module.v1"}\n'
    fi
  elif [ "$type" = "message.created" ]; then
    plain_text=$(json_string_field message plain_text "$line")
    case "$plain_text" in
      "/quote"|"/quote "*)
        next_seed
        result=$(quote_result "$event_seed")
        escaped=$(json_escape "$result")
        printf '{"type":"message.create","plain_text":"%s"}\n' "$escaped"
        printf '{"type":"event.ok"}\n'
        ;;
      *)
        printf '{"type":"event.ok"}\n'
        ;;
    esac
  else
    printf '{"type":"event.ok"}\n'
  fi
done
