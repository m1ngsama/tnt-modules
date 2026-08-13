#!/bin/sh
# TNT 8ball-module: a Magic 8-Ball for tnt.module.v1.
#
# Reacts to chat messages that begin with "/8ball" and replies with a random
# classic answer. All other messages are acknowledged with a no-op so the
# module stays quiet during normal chat.

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

eightball_result() {
  sender=$1
  seed=$2

  # Pass untrusted text as input. awk -v assignments interpret backslash
  # escapes, which can corrupt a literal sender and even emit raw controls.
  printf '%s\n' "$sender" | LC_ALL=C awk -v seed="$seed" '
    NR == 1 { sender = $0 }
    END {
      srand(seed)
      if (sender == "") sender = "someone"
      n = 0
      # 10 affirmative
      a[++n] = "It is certain."
      a[++n] = "It is decidedly so."
      a[++n] = "Without a doubt."
      a[++n] = "Yes, definitely."
      a[++n] = "You may rely on it."
      a[++n] = "As I see it, yes."
      a[++n] = "Most likely."
      a[++n] = "Outlook good."
      a[++n] = "Yes."
      a[++n] = "Signs point to yes."
      # 5 non-committal
      a[++n] = "Reply hazy, try again."
      a[++n] = "Ask again later."
      a[++n] = "Better not tell you now."
      a[++n] = "Cannot predict now."
      a[++n] = "Concentrate and ask again."
      # 5 negative
      a[++n] = "Do not count on it."
      a[++n] = "My reply is no."
      a[++n] = "My sources say no."
      a[++n] = "Outlook not so good."
      a[++n] = "Very doubtful."
      pick = int(rand() * n) + 1
      printf "🎱 %s: %s\n", sender, a[pick]
    }
  '
}

while IFS= read -r line; do
  type=$(json_string_field "" type "$line")
  if [ "$type" = "handshake" ]; then
    protocol=$(json_string_field "" protocol "$line")
    if [ "$protocol" = "tnt.module.v1" ]; then
      printf '{"type":"handshake.ok","protocol":"tnt.module.v1","module":{"name":"8ball-module","version":"0.2.0"}}\n'
    else
      printf '{"type":"error","code":"unsupported_protocol","message":"requires tnt.module.v1"}\n'
    fi
  elif [ "$type" = "message.created" ]; then
    plain_text=$(json_string_field message plain_text "$line")
    case "$plain_text" in
      "/8ball"|"/8ball "*)
        sender=$(json_string_field message sender "$line")
        next_seed
        result=$(eightball_result "$sender" "$event_seed")
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
