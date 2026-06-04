#!/bin/sh

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

while IFS= read -r line; do
  protocol=$(extract_string protocol "$line")
  plain_text=$(extract_string plain_text "$line")

  if printf '%s\n' "$line" | grep -q '"type"[[:space:]]*:[[:space:]]*"handshake"'; then
    if [ "$protocol" = "tnt.module.v1" ]; then
      printf '{"type":"handshake.ok","protocol":"tnt.module.v1","module":{"name":"echo-module","version":"0.1.0"}}\n'
    else
      printf '{"type":"error","code":"unsupported_protocol","message":"requires tnt.module.v1"}\n'
    fi
  elif printf '%s\n' "$line" | grep -q '"type"[[:space:]]*:[[:space:]]*"message.created"' && [ -n "$plain_text" ]; then
    escaped_text=$(json_escape "echo: $plain_text")
    printf '{"type":"message.create","plain_text":"%s"}\n' "$escaped_text"
  else
    printf '{"type":"error","code":"bad_request","message":"expected handshake or message.created with message.plain_text"}\n'
  fi
done
