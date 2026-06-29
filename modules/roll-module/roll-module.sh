#!/bin/sh
# TNT roll-module: a dice roller for tnt.module.v1.
#
# Reacts to chat messages that begin with "/roll" and replies with a public
# dice result. All other messages are acknowledged with a no-op so the module
# stays quiet and is never flagged for protocol errors during normal chat.
#
# Supported syntax (case-insensitive d):
#   /roll              -> 1d6
#   /roll d20          -> one 20-sided die
#   /roll 3d6          -> three 6-sided dice, summed
#   /roll 2d6+3        -> with a flat modifier (+/-)
# Bounds: 1..20 dice, 2..1000 sides, modifier within +/-10000.

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

# Compute the plain-text dice result for a spec like "2d6+3".
# Prints exactly the user-visible line to emit.
roll_result() {
  spec=$1
  sender=$2

  seed=$(od -An -N4 -tu4 </dev/urandom 2>/dev/null | tr -d ' ')
  [ -n "$seed" ] || seed=$$

  awk -v seed="$seed" -v sender="$sender" -v spec="$spec" '
    function usage() {
      printf "\xF0\x9F\x8E\xB2 roll usage: /roll [N]d<sides>[+/-K]  e.g. /roll 2d6, /roll d20, /roll 3d6+2\n"
      exit 0
    }
    BEGIN {
      srand(seed)
      if (sender == "") sender = "someone"
      if (spec == "") spec = "1d6"
      gsub(/D/, "d", spec)

      if (spec !~ /^[0-9]*d[0-9]+([+-][0-9]+)?$/) usage()

      dpos = index(spec, "d")
      ncount = substr(spec, 1, dpos - 1)
      rest = substr(spec, dpos + 1)

      mod = 0
      mpos = 0
      for (i = 1; i <= length(rest); i++) {
        c = substr(rest, i, 1)
        if (c == "+" || c == "-") { mpos = i; break }
      }
      if (mpos > 0) {
        sides = substr(rest, 1, mpos - 1)
        mod = substr(rest, mpos) + 0
      } else {
        sides = rest
      }

      n = (ncount == "") ? 1 : ncount + 0
      s = sides + 0
      if (n < 1 || n > 20) usage()
      if (s < 2 || s > 1000) usage()
      if (mod > 10000 || mod < -10000) usage()

      total = 0
      out = ""
      for (i = 0; i < n; i++) {
        r = int(rand() * s) + 1
        total += r
        out = out (i == 0 ? "" : " + ") r
      }
      label = ((ncount == "") ? "" : n) "d" s
      if (mod != 0) label = label (mod > 0 ? "+" mod : mod)
      res = total + mod

      if (n == 1 && mod == 0) {
        printf "\xF0\x9F\x8E\xB2 %s rolled %s \xE2\x86\x92 %d\n", sender, label, total
      } else {
        modtxt = (mod > 0 ? " (+" mod ")" : (mod < 0 ? " (" mod ")" : ""))
        printf "\xF0\x9F\x8E\xB2 %s rolled %s \xE2\x86\x92 %s%s = %d\n", sender, label, out, modtxt, res
      }
    }
  '
}

while IFS= read -r line; do
  if printf '%s\n' "$line" | grep -q '"type"[[:space:]]*:[[:space:]]*"handshake"'; then
    protocol=$(extract_string protocol "$line")
    if [ "$protocol" = "tnt.module.v1" ]; then
      printf '{"type":"handshake.ok","protocol":"tnt.module.v1","module":{"name":"roll-module","version":"0.1.0"}}\n'
    else
      printf '{"type":"error","code":"unsupported_protocol","message":"requires tnt.module.v1"}\n'
    fi
  elif printf '%s\n' "$line" | grep -q '"type"[[:space:]]*:[[:space:]]*"message.created"'; then
    plain_text=$(extract_string plain_text "$line")
    case "$plain_text" in
      "/roll"|"/roll "*)
        sender=$(extract_string sender "$line")
        rest=${plain_text#/roll}
        # trim leading spaces from the dice spec
        rest=$(printf '%s' "$rest" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        result=$(roll_result "$rest" "$sender")
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
