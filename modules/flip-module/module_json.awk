# Extract one string field from a TNT JSONL record without a runtime dependency
# beyond POSIX awk. Invoke with:
#   LC_ALL=C awk -v scope='' -v key=type -f ./module_json.awk
#   LC_ALL=C awk -v scope=message -v key=plain_text -f ./module_json.awk
# The C locale makes numeric %c byte-oriented on awk implementations such as
# gawk, which is required when decoding JSON Unicode escapes into UTF-8.
#
# Exit status: 0 = transport-safe string found (possibly empty), 1 = absent or
# non-string, 2 = invalid JSON or a control character in the requested string
# that TNT cannot accept in module-created plain text. Controls in unrelated
# fields remain valid JSON and are ignored. The decoded string is written
# without a trailing newline.

BEGIN {
  # All callers force LC_ALL=C, so numeric %c builds a byte lookup table on
  # both one-true-awk and GNU/mawk implementations.
  for (byte_value = 1; byte_value <= 255; byte_value++) {
    byte[sprintf("%c", byte_value)] = byte_value
  }
}

function fail() {
  invalid = 1
}

function skip_ws(    c) {
  while (pos <= source_length) {
    c = substr(source, pos, 1)
    if (c !~ /[ \t\r\n]/) break
    pos++
  }
}

function hex_digit(c) {
  return index("0123456789abcdef", tolower(c)) - 1
}

function hex_number(value,    i, result) {
  result = 0
  for (i = 1; i <= length(value); i++) {
    result = (result * 16) + hex_digit(substr(value, i, 1))
  }
  return result
}

function utf8(code) {
  if (code < 128) return sprintf("%c", code)
  if (code < 2048) {
    return sprintf("%c%c", 192 + int(code / 64), 128 + (code % 64))
  }
  if (code < 65536) {
    return sprintf("%c%c%c", 224 + int(code / 4096),
                   128 + (int(code / 64) % 64), 128 + (code % 64))
  }
  return sprintf("%c%c%c%c", 240 + int(code / 262144),
                 128 + (int(code / 4096) % 64),
                 128 + (int(code / 64) % 64), 128 + (code % 64))
}

function valid_utf8(value, reject_controls,    i, total, first, second,
                    width, j, continuation) {
  i = 1
  total = length(value)
  while (i <= total) {
    first = byte[substr(value, i, 1)]
    if (first <= 127) {
      width = 1
    } else if (first >= 194 && first <= 223) {
      width = 2
    } else if (first >= 224 && first <= 239) {
      width = 3
    } else if (first >= 240 && first <= 244) {
      width = 4
    } else {
      return 0
    }

    if (i + width - 1 > total) return 0
    for (j = 1; j < width; j++) {
      continuation = byte[substr(value, i + j, 1)]
      if (continuation < 128 || continuation > 191) return 0
    }

    second = width > 1 ? byte[substr(value, i + 1, 1)] : 0
    if ((first == 224 && second < 160) ||
        (first == 237 && second > 159) ||
        (first == 240 && second < 144) ||
        (first == 244 && second > 143)) return 0
    if (reject_controls &&
        ((width == 1 && (first < 32 || first == 127)) ||
         (first == 194 && second >= 128 && second <= 159))) return 0
    i += width
  }
  return 1
}

function control_marker(code) {
  # Raw JSON cannot contain SUBSEP (U+001C), so this representation cannot
  # collide with ordinary key text. It also normalizes \n and \u000a so
  # duplicate object keys retain their decoded-string semantics.
  return SUBSEP "control:" code SUBSEP
}

function parse_string(reject_controls,    out, c, escaped, hex, code, low_hex, low) {
  string_ok = 0
  string_unsafe = 0
  if (substr(source, pos, 1) != "\"") {
    fail()
    return ""
  }

  pos++
  out = ""
  while (pos <= source_length) {
    c = substr(source, pos, 1)
    pos++
    if (c == "\"") {
      string_ok = 1
      return out
    }
    if (c != "\\") {
      if (c ~ /[[:cntrl:]]/ && c != sprintf("%c", 127)) {
        fail()
        return ""
      }
      if (c == sprintf("%c", 127)) {
        if (reject_controls) string_unsafe = 1
        out = out control_marker(127)
      } else {
        out = out c
      }
      continue
    }

    if (pos > source_length) {
      fail()
      return ""
    }
    escaped = substr(source, pos, 1)
    pos++
    if (escaped == "\"" || escaped == "\\" || escaped == "/") {
      out = out escaped
    } else if (escaped == "b" || escaped == "f" || escaped == "n" ||
               escaped == "r" || escaped == "t") {
      if (escaped == "b") code = 8
      else if (escaped == "f") code = 12
      else if (escaped == "n") code = 10
      else if (escaped == "r") code = 13
      else code = 9
      if (reject_controls) string_unsafe = 1
      out = out control_marker(code)
    } else if (escaped == "u") {
      hex = substr(source, pos, 4)
      if (length(hex) != 4 ||
          hex !~ /^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$/) {
        fail()
        return ""
      }
      pos += 4
      code = hex_number(hex)
      if (code >= 55296 && code <= 56319) {
        if (substr(source, pos, 2) != "\\u") {
          fail()
          return ""
        }
        pos += 2
        low_hex = substr(source, pos, 4)
        if (length(low_hex) != 4 ||
            low_hex !~ /^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$/) {
          fail()
          return ""
        }
        pos += 4
        low = hex_number(low_hex)
        if (low < 56320 || low > 57343) {
          fail()
          return ""
        }
        code = 65536 + ((code - 55296) * 1024) + (low - 56320)
      } else if (code >= 56320 && code <= 57343) {
        fail()
        return ""
      }
      if (code < 32 || code == 127) {
        if (reject_controls) string_unsafe = 1
        out = out control_marker(code)
      } else {
        out = out utf8(code)
      }
    } else {
      fail()
      return ""
    }
  }

  fail()
  return ""
}

function join_path(parent, child) {
  return parent == "" ? child : parent SUBSEP child
}

function parse_object(path,    object_key, child_path, seen_key, c) {
  pos++
  skip_ws()
  if (substr(source, pos, 1) == "}") {
    pos++
    return
  }

  while (!invalid) {
    object_key = parse_string(0)
    if (invalid || !string_ok) return
    seen_key = path SUBSEP object_key
    if (seen[seen_key]) {
      fail()
      return
    }
    seen[seen_key] = 1

    skip_ws()
    if (substr(source, pos, 1) != ":") {
      fail()
      return
    }
    pos++
    child_path = join_path(path, object_key)
    parse_value(child_path)
    if (invalid) return

    skip_ws()
    c = substr(source, pos, 1)
    if (c == "}") {
      pos++
      return
    }
    if (c != ",") {
      fail()
      return
    }
    pos++
    skip_ws()
  }
}

function parse_array(path,    item, c) {
  pos++
  skip_ws()
  if (substr(source, pos, 1) == "]") {
    pos++
    return
  }

  item = 0
  while (!invalid) {
    item++
    parse_value(path SUBSEP "[" item "]")
    if (invalid) return
    skip_ws()
    c = substr(source, pos, 1)
    if (c == "]") {
      pos++
      return
    }
    if (c != ",") {
      fail()
      return
    }
    pos++
    skip_ws()
  }
}

function parse_value(path,    c, value, value_unsafe, rest) {
  skip_ws()
  c = substr(source, pos, 1)
  if (c == "\"") {
    value = parse_string(runtime || path == wanted_path)
    value_unsafe = string_unsafe || !valid_utf8(value, 1)
    if (!invalid && string_ok) {
      if (runtime) {
        if (!value_unsafe) string_value[path] = value
      } else if (path == wanted_path && !found) {
        result = value
        found = 1
        unsafe_target = value_unsafe
      }
    }
  } else if (c == "{") {
    parse_object(path)
  } else if (c == "[") {
    parse_array(path)
  } else if (substr(source, pos, 4) == "true") {
    pos += 4
  } else if (substr(source, pos, 5) == "false") {
    pos += 5
  } else if (substr(source, pos, 4) == "null") {
    pos += 4
  } else {
    rest = substr(source, pos)
    if (match(rest, /^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/)) {
      pos += RLENGTH
    } else {
      fail()
    }
  }
}

function clear_record(    item) {
  for (item in seen) delete seen[item]
  for (item in string_value) delete string_value[item]
}

function safe_string(scope_name, field_name,    path) {
  path = scope_name == "" ? field_name : scope_name SUBSEP field_name
  if (!record_valid || !(path in string_value)) return ""
  return string_value[path]
}

function json_escape(value,    out, i, c, code, hex) {
  out = ""
  hex = "0123456789abcdef"
  for (i = 1; i <= length(value); i++) {
    c = substr(value, i, 1)
    code = byte[c]
    if (c == "\\") out = out "\\\\"
    else if (c == "\"") out = out "\\\""
    else if (code == 8) out = out "\\b"
    else if (code == 12) out = out "\\f"
    else if (code == 10) out = out "\\n"
    else if (code == 13) out = out "\\r"
    else if (code == 9) out = out "\\t"
    else if (code < 32 || code == 127) {
      out = out "\\u00" substr(hex, int(code / 16) + 1, 1) \
            substr(hex, (code % 16) + 1, 1)
    } else {
      out = out c
    }
  }
  return out
}

function utf8_truncate(value, limit) {
  if (length(value) <= limit) return value
  value = substr(value, 1, limit)
  while (value != "" && !valid_utf8(value)) {
    value = substr(value, 1, length(value) - 1)
  }
  return value
}

function emit_message(value) {
  value = utf8_truncate(value, 1023)
  if (value == "" || !valid_utf8(value, 1)) return
  printf "{\"type\":\"message.create\",\"plain_text\":\"%s\"}\n", \
         json_escape(value)
}

function emit_event_ok() {
  print "{\"type\":\"event.ok\"}"
  fflush()
}

function begin_event(name, version,    type, protocol) {
  type = safe_string("", "type")
  if (type == "handshake") {
    protocol = safe_string("", "protocol")
    if (protocol == "tnt.module.v1") {
      printf "{\"type\":\"handshake.ok\",\"protocol\":\"tnt.module.v1\"," \
             "\"module\":{\"name\":\"%s\",\"version\":\"%s\"}}\n", \
             name, version
    } else {
      print "{\"type\":\"error\",\"code\":\"unsupported_protocol\"," \
            "\"message\":\"requires tnt.module.v1\"}"
    }
    fflush()
    return 0
  }
  if (type != "message.created") {
    emit_event_ok()
    return 0
  }
  return 1
}

function reseed_random(    event_seed) {
  seed_counter++
  event_seed = ((seed + seed_counter) % 2147483646) + 1
  srand(event_seed)
}

function next_random() {
  reseed_random()
  return rand()
}

{
  if (!runtime && record_seen) {
    invalid = 1
    next
  }
  if (!runtime) record_seen = 1
  clear_record()
  invalid = 0
  found = 0
  unsafe_target = 0
  result = ""
  record_valid = 0
  source = $0
  source_length = length(source)
  if (!valid_utf8(source)) {
    fail()
  } else {
    pos = 1
    wanted_path = scope == "" ? key : scope SUBSEP key
    parse_value("")
    skip_ws()
    if (pos <= source_length) fail()
    if (!invalid) record_valid = 1
  }
}

END {
  if (!runtime) {
    if (invalid || unsafe_target || !record_seen) exit 2
    if (!found) exit 1
    printf "%s", result
  }
}
