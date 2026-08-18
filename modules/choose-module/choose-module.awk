BEGIN {
  runtime = 1
}

function trim(value) {
  sub(/^[ \t]+/, "", value)
  sub(/[ \t]+$/, "", value)
  return value
}

function clear_choices(    item) {
  for (item in raw_choice) delete raw_choice[item]
  for (item in choice) delete choice[item]
}

{
  if (!begin_event("choose-module", "0.2.0")) next
  text = safe_string("message", "plain_text")
  if (text == "/choose" || substr(text, 1, 8) == "/choose ") {
    rest = trim(substr(text, 8))
    sender = safe_string("message", "sender")
    if (sender == "") sender = "someone"
    random_value = next_random()
    clear_choices()
    raw_count = split(rest, raw_choice, "[|]")
    choice_count = 0
    for (i = 1; i <= raw_count; i++) {
      item = trim(raw_choice[i])
      if (item != "") choice[++choice_count] = item
    }
    if (choice_count < 2) {
      result = "🤔 choose usage: /choose a | b | c"
    } else {
      pick = int(random_value * choice_count) + 1
      result = "🤔 " sender " chose: " choice[pick]
    }
    emit_message(result)
  }
  emit_event_ok()
}
