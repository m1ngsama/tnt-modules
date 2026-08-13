#!/bin/sh

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

while IFS= read -r line; do
  type=$(json_string_field "" type "$line")

  if [ "$type" = "handshake" ]; then
    protocol=$(json_string_field "" protocol "$line")
    if [ "$protocol" = "tnt.module.v1" ]; then
      printf '{"type":"handshake.ok","protocol":"tnt.module.v1","module":{"name":"echo-module","version":"0.1.0"}}\n'
    else
      printf '{"type":"error","code":"unsupported_protocol","message":"requires tnt.module.v1"}\n'
    fi
  elif [ "$type" = "message.created" ]; then
    plain_text=$(json_string_field message plain_text "$line")
    if [ -n "$plain_text" ]; then
      bounded_text=$(printf '%s' "echo: $plain_text" | utf8_truncate 1023) || bounded_text=
      if [ -n "$bounded_text" ]; then
        escaped_text=$(json_escape "$bounded_text")
        printf '{"type":"message.create","plain_text":"%s"}\n' "$escaped_text"
      fi
    fi
    printf '{"type":"event.ok"}\n'
  else
    printf '{"type":"event.ok"}\n'
  fi
done
