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
  printf '%s' "$1" | awk '
    BEGIN { ORS = "" }
    {
      gsub(/\\/,"\\\\")
      gsub(/"/,"\\\"")
      gsub(/\t/,"\\t")
      gsub(/\r/,"\\r")
      gsub(/\n/,"\\n")
      print
    }
  '
}

extract_string() {
  key=$1
  line=$2
  printf '%s\n' "$line" | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p"
}

quote_result() {
  seed=$(od -An -N4 -tu4 </dev/urandom 2>/dev/null | tr -d ' ')
  [ -n "$seed" ] || seed=$$

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
      printf "\xE2\x9D\x9D %s \xE2\x9D\x9E\n", q[pick]
    }
  '
}

while IFS= read -r line; do
  if printf '%s\n' "$line" | grep -q '"type"[[:space:]]*:[[:space:]]*"handshake"'; then
    protocol=$(extract_string protocol "$line")
    if [ "$protocol" = "tnt.module.v1" ]; then
      printf '{"type":"handshake.ok","protocol":"tnt.module.v1","module":{"name":"quote-module","version":"0.1.0"}}\n'
    else
      printf '{"type":"error","code":"unsupported_protocol","message":"requires tnt.module.v1"}\n'
    fi
  elif printf '%s\n' "$line" | grep -q '"type"[[:space:]]*:[[:space:]]*"message.created"'; then
    plain_text=$(extract_string plain_text "$line")
    case "$plain_text" in
      "/quote"|"/quote "*)
        result=$(quote_result)
        escaped=$(json_escape "$result")
        printf '{"type":"message.create","plain_text":"%s"}\n' "$escaped"
        ;;
      *)
        printf '{"type":"event.ok"}\n'
        ;;
    esac
  else
    printf '{"type":"error","code":"bad_request","message":"expected handshake or message.created"}\n'
  fi
done
