BEGIN {
  runtime = 1
}

{
  if (!begin_event("flip-module", "0.2.0")) next
  text = safe_string("message", "plain_text")
  if (text == "/flip" || substr(text, 1, 6) == "/flip ") {
    sender = safe_string("message", "sender")
    if (sender == "") sender = "someone"
    face = int(next_random() * 2) == 0 ? "heads" : "tails"
    emit_message("🪙 " sender " flipped → " face)
  }
  emit_event_ok()
}
