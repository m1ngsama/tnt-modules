#!/bin/sh
# TNT choose-module: a random picker for tnt.module.v1.
#
# Reacts to chat messages that begin with "/choose" and replies with one of the
# pipe-separated options chosen at random. All other messages are acknowledged
# with a no-op so the module stays quiet during normal chat.

LC_ALL=C
export LC_ALL

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

# Copy at most LIMIT UTF-8 bytes from stdin without splitting a code point.
# LC_ALL=C makes awk's string offsets byte-based on both macOS and Linux.
utf8_truncate() {
  limit=$1
  LC_ALL=C awk -v limit="$limit" '
    BEGIN {
      ORS = ""
      for (i = 1; i <= 255; i++) byte[sprintf("%c", i)] = i
    }
    {
      out = ""
      out_bytes = 0
      pos = 1
      total = length($0)
      while (pos <= total) {
        first = byte[substr($0, pos, 1)]
        if (first <= 127) width = 1
        else if (first >= 194 && first <= 223) width = 2
        else if (first >= 224 && first <= 239) width = 3
        else if (first >= 240 && first <= 244) width = 4
        else exit 1

        if (pos + width - 1 > total) exit 1
        for (j = 1; j < width; j++) {
          continuation = byte[substr($0, pos + j, 1)]
          if (continuation < 128 || continuation > 191) exit 1
        }

        second = width > 1 ? byte[substr($0, pos + 1, 1)] : 0
        if ((first == 224 && second < 160) ||
            (first == 237 && second > 159) ||
            (first == 240 && second < 144) ||
            (first == 244 && second > 143)) exit 1

        if (out_bytes + width > limit) break
        out = out substr($0, pos, width)
        out_bytes += width
        pos += width
      }
      printf "%s", out
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

choose_result() {
  options=$1
  sender=$2
  seed=$3

  # Pass untrusted strings as input records. awk -v assignments interpret
  # backslash escapes, which would turn a literal "\t" or "\n" into controls.
  {
    printf '%s\n' "$sender"
    printf '%s\n' "$options"
  } | LC_ALL=C awk -v seed="$seed" '
    function trim(s) {
      gsub(/^[ \t]+/, "", s)
      gsub(/[ \t]+$/, "", s)
      return s
    }
    NR == 1 { sender = $0; next }
    NR == 2 { options = $0; next }
    END {
      srand(seed)
      if (sender == "") sender = "someone"
      n = split(options, raw, "[|]")
      m = 0
      for (i = 1; i <= n; i++) {
        t = trim(raw[i])
        if (t != "") opt[++m] = t
      }
      if (m < 2) {
        printf "🤔 choose usage: /choose a | b | c\n"
        exit 0
      }
      pick = int(rand() * m) + 1
      printf "🤔 %s chose: %s\n", sender, opt[pick]
    }
  '
}

while IFS= read -r line; do
  type=$(json_string_field "" type "$line")
  if [ "$type" = "handshake" ]; then
    protocol=$(json_string_field "" protocol "$line")
    if [ "$protocol" = "tnt.module.v1" ]; then
      printf '{"type":"handshake.ok","protocol":"tnt.module.v1","module":{"name":"choose-module","version":"0.1.0"}}\n'
    else
      printf '{"type":"error","code":"unsupported_protocol","message":"requires tnt.module.v1"}\n'
    fi
  elif [ "$type" = "message.created" ]; then
    plain_text=$(json_string_field message plain_text "$line")
    case "$plain_text" in
      "/choose"|"/choose "*)
        sender=$(json_string_field message sender "$line")
        rest=${plain_text#/choose}
        while [ "${rest# }" != "$rest" ]; do rest=${rest# }; done
        while [ "${rest% }" != "$rest" ]; do rest=${rest% }; done
        next_seed
        result=$(choose_result "$rest" "$sender" "$event_seed")
        if [ "${#result}" -le 1023 ]; then
          bounded_result=$result
        else
          bounded_result=$(printf '%s' "$result" | utf8_truncate 1023) || bounded_result=
        fi
        if [ -n "$bounded_result" ]; then
          escaped=$(json_escape "$bounded_result")
          printf '{"type":"message.create","plain_text":"%s"}\n' "$escaped"
        fi
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
