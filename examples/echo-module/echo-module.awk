BEGIN {
  runtime = 1
}

{
  if (!begin_event("echo-module", "0.2.0")) next
  text = safe_string("message", "plain_text")
  if (text != "") emit_message("echo: " text)
  emit_event_ok()
}
