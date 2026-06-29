#!/bin/sh
# TNT 8ball-module: a Magic 8-Ball for tnt.module.v1.
#
# Reacts to chat messages that begin with "/8ball" and replies with a random
# classic answer. All other messages are acknowledged with a no-op so the
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

eightball_result() {
  sender=$1
  seed=$(od -An -N4 -tu4 </dev/urandom 2>/dev/null | tr -d ' ')
  [ -n "$seed" ] || seed=$$

  awk -v seed="$seed" -v sender="$sender" '
    BEGIN {
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
      printf "\xF0\x9F\x8E\xB1 %s: %s\n", sender, a[pick]
    }
  '
}

while IFS= read -r line; do
  if printf '%s\n' "$line" | grep -q '"type"[[:space:]]*:[[:space:]]*"handshake"'; then
    protocol=$(extract_string protocol "$line")
    if [ "$protocol" = "tnt.module.v1" ]; then
      printf '{"type":"handshake.ok","protocol":"tnt.module.v1","module":{"name":"8ball-module","version":"0.1.0"}}\n'
    else
      printf '{"type":"error","code":"unsupported_protocol","message":"requires tnt.module.v1"}\n'
    fi
  elif printf '%s\n' "$line" | grep -q '"type"[[:space:]]*:[[:space:]]*"message.created"'; then
    plain_text=$(extract_string plain_text "$line")
    case "$plain_text" in
      "/8ball"|"/8ball "*)
        sender=$(extract_string sender "$line")
        result=$(eightball_result "$sender")
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
