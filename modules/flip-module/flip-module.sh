#!/bin/sh
# TNT flip-module: a coin flipper for tnt.module.v1.
#
# Reacts to chat messages that begin with "/flip" and replies with a public
# heads/tails result. All other messages are acknowledged with a no-op so the
# module stays quiet during normal chat.

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

flip_result() {
  sender=$1
  seed=$(od -An -N4 -tu4 </dev/urandom 2>/dev/null | tr -d ' ')
  [ -n "$seed" ] || seed=$$

  awk -v seed="$seed" -v sender="$sender" '
    BEGIN {
      srand(seed)
      if (sender == "") sender = "someone"
      face = (int(rand() * 2) == 0) ? "heads" : "tails"
      printf "\xF0\x9F\xAA\x99 %s flipped \xE2\x86\x92 %s\n", sender, face
    }
  '
}

while IFS= read -r line; do
  if printf '%s\n' "$line" | grep -q '"type"[[:space:]]*:[[:space:]]*"handshake"'; then
    protocol=$(extract_string protocol "$line")
    if [ "$protocol" = "tnt.module.v1" ]; then
      printf '{"type":"handshake.ok","protocol":"tnt.module.v1","module":{"name":"flip-module","version":"0.1.0"}}\n'
    else
      printf '{"type":"error","code":"unsupported_protocol","message":"requires tnt.module.v1"}\n'
    fi
  elif printf '%s\n' "$line" | grep -q '"type"[[:space:]]*:[[:space:]]*"message.created"'; then
    plain_text=$(extract_string plain_text "$line")
    case "$plain_text" in
      "/flip"|"/flip "*)
        sender=$(extract_string sender "$line")
        result=$(flip_result "$sender")
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
