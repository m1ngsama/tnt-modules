#!/bin/sh
# TNT choose-module: a random picker for tnt.module.v1.
#
# Reacts to chat messages that begin with "/choose" and replies with one of the
# pipe-separated options chosen at random. All other messages are acknowledged
# with a no-op so the module stays quiet during normal chat.

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

choose_result() {
  options=$1
  sender=$2
  seed=$(od -An -N4 -tu4 </dev/urandom 2>/dev/null | tr -d ' ')
  [ -n "$seed" ] || seed=$$

  awk -v seed="$seed" -v sender="$sender" -v options="$options" '
    function trim(s) {
      gsub(/^[ \t]+/, "", s)
      gsub(/[ \t]+$/, "", s)
      return s
    }
    BEGIN {
      srand(seed)
      if (sender == "") sender = "someone"
      n = split(options, raw, "[|]")
      m = 0
      for (i = 1; i <= n; i++) {
        t = trim(raw[i])
        if (t != "") opt[++m] = t
      }
      if (m < 2) {
        printf "\xF0\x9F\xA4\x94 choose usage: /choose a | b | c\n"
        exit 0
      }
      pick = int(rand() * m) + 1
      printf "\xF0\x9F\xA4\x94 %s chose: %s\n", sender, opt[pick]
    }
  '
}

while IFS= read -r line; do
  if printf '%s\n' "$line" | grep -q '"type"[[:space:]]*:[[:space:]]*"handshake"'; then
    protocol=$(extract_string protocol "$line")
    if [ "$protocol" = "tnt.module.v1" ]; then
      printf '{"type":"handshake.ok","protocol":"tnt.module.v1","module":{"name":"choose-module","version":"0.1.0"}}\n'
    else
      printf '{"type":"error","code":"unsupported_protocol","message":"requires tnt.module.v1"}\n'
    fi
  elif printf '%s\n' "$line" | grep -q '"type"[[:space:]]*:[[:space:]]*"message.created"'; then
    plain_text=$(extract_string plain_text "$line")
    case "$plain_text" in
      "/choose"|"/choose "*)
        sender=$(extract_string sender "$line")
        rest=${plain_text#/choose}
        rest=$(printf '%s' "$rest" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        result=$(choose_result "$rest" "$sender")
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
