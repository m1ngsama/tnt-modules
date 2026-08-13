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

# Compute the plain-text dice result for a spec like "2d6+3".
# Prints exactly the user-visible line to emit.
roll_result() {
  spec=$1
  sender=$2

  seed=$(od -An -N4 -tu4 </dev/urandom 2>/dev/null | tr -d ' ')
  [ -n "$seed" ] || seed=$$

  # Pass untrusted strings as input records. awk -v assignments interpret
  # backslash escapes, which can corrupt a literal sender or dice spec.
  {
    printf '%s\n' "$sender"
    printf '%s\n' "$spec"
  } | LC_ALL=C awk -v seed="$seed" '
    function usage() {
      printf "🎲 roll usage: /roll [N]d<sides>[+/-K]  e.g. /roll 2d6, /roll d20, /roll 3d6+2\n"
      exit 0
    }
    NR == 1 { sender = $0; next }
    NR == 2 { spec = $0; next }
    END {
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
        printf "🎲 %s rolled %s → %d\n", sender, label, total
      } else {
        modtxt = (mod > 0 ? " (+" mod ")" : (mod < 0 ? " (" mod ")" : ""))
        printf "🎲 %s rolled %s → %s%s = %d\n", sender, label, out, modtxt, res
      }
    }
  '
}

while IFS= read -r line; do
  type=$(json_string_field "" type "$line")
  if [ "$type" = "handshake" ]; then
    protocol=$(json_string_field "" protocol "$line")
    if [ "$protocol" = "tnt.module.v1" ]; then
      printf '{"type":"handshake.ok","protocol":"tnt.module.v1","module":{"name":"roll-module","version":"0.1.0"}}\n'
    else
      printf '{"type":"error","code":"unsupported_protocol","message":"requires tnt.module.v1"}\n'
    fi
  elif [ "$type" = "message.created" ]; then
    plain_text=$(json_string_field message plain_text "$line")
    case "$plain_text" in
      "/roll"|"/roll "*)
        sender=$(json_string_field message sender "$line")
        rest=${plain_text#/roll}
        # trim leading spaces from the dice spec
        rest=$(printf '%s' "$rest" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        result=$(roll_result "$rest" "$sender")
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
