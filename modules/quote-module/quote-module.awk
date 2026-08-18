BEGIN {
  runtime = 1
  quote[++quote_count] = "Well begun is half done."
  quote[++quote_count] = \
    "A journey of a thousand miles begins with a single step."
  quote[++quote_count] = "Fortune favors the bold."
  quote[++quote_count] = "Still waters run deep."
  quote[++quote_count] = "Where there is a will, there is a way."
  quote[++quote_count] = "Actions speak louder than words."
  quote[++quote_count] = "The early bird catches the worm."
  quote[++quote_count] = "Necessity is the mother of invention."
  quote[++quote_count] = "Better late than never."
  quote[++quote_count] = "Practice makes perfect."
  quote[++quote_count] = "A picture is worth a thousand words."
  quote[++quote_count] = "Slow and steady wins the race."
  quote[++quote_count] = "Knowledge is power."
  quote[++quote_count] = "Hope for the best, prepare for the worst."
  quote[++quote_count] = "Measure twice, cut once."
}

{
  if (!begin_event("quote-module", "0.2.0")) next
  text = safe_string("message", "plain_text")
  if (text == "/quote" || substr(text, 1, 7) == "/quote ") {
    pick = int(next_random() * quote_count) + 1
    emit_message("❝ " quote[pick] " ❞")
  }
  emit_event_ok()
}
