BEGIN {
  runtime = 1
}

function roll_result(spec, sender,    dpos, ncount, rest, mod, mpos, i, c,
                     sides, n, s, total, rolls, label, result, modifier) {
  if (spec == "") spec = "1d6"
  gsub(/D/, "d", spec)
  if (spec !~ /^[0-9]*d[0-9]+([+-][0-9]+)?$/) return ""

  dpos = index(spec, "d")
  ncount = substr(spec, 1, dpos - 1)
  rest = substr(spec, dpos + 1)
  mod = 0
  mpos = 0
  for (i = 1; i <= length(rest); i++) {
    c = substr(rest, i, 1)
    if (c == "+" || c == "-") {
      mpos = i
      break
    }
  }
  if (mpos > 0) {
    sides = substr(rest, 1, mpos - 1)
    mod = substr(rest, mpos) + 0
  } else {
    sides = rest
  }

  n = ncount == "" ? 1 : ncount + 0
  s = sides + 0
  if (n < 1 || n > 20 || s < 2 || s > 1000 ||
      mod < -10000 || mod > 10000) return ""

  reseed_random()
  total = 0
  rolls = ""
  for (i = 0; i < n; i++) {
    result = int(rand() * s) + 1
    total += result
    rolls = rolls (i == 0 ? "" : " + ") result
  }
  label = (ncount == "" ? "" : n) "d" s
  if (mod != 0) label = label (mod > 0 ? "+" mod : mod)
  result = total + mod
  if (n == 1 && mod == 0) {
    return "🎲 " sender " rolled " label " → " total
  }
  modifier = mod > 0 ? " (+" mod ")" : (mod < 0 ? " (" mod ")" : "")
  return "🎲 " sender " rolled " label " → " rolls modifier " = " result
}

{
  if (!begin_event("roll-module", "0.2.0")) next
  text = safe_string("message", "plain_text")
  if (text == "/roll" || substr(text, 1, 6) == "/roll ") {
    rest = substr(text, 6)
    sub(/^ +/, "", rest)
    sub(/ +$/, "", rest)
    sender = safe_string("message", "sender")
    if (sender == "") sender = "someone"
    result = roll_result(rest, sender)
    if (result == "") {
      result = "🎲 roll usage: /roll [N]d<sides>[+/-K]  e.g. " \
               "/roll 2d6, /roll d20, /roll 3d6+2"
    }
    emit_message(result)
  }
  emit_event_ok()
}
