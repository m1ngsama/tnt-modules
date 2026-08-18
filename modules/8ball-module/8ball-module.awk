BEGIN {
  runtime = 1
  answer[++answer_count] = "It is certain."
  answer[++answer_count] = "It is decidedly so."
  answer[++answer_count] = "Without a doubt."
  answer[++answer_count] = "Yes, definitely."
  answer[++answer_count] = "You may rely on it."
  answer[++answer_count] = "As I see it, yes."
  answer[++answer_count] = "Most likely."
  answer[++answer_count] = "Outlook good."
  answer[++answer_count] = "Yes."
  answer[++answer_count] = "Signs point to yes."
  answer[++answer_count] = "Reply hazy, try again."
  answer[++answer_count] = "Ask again later."
  answer[++answer_count] = "Better not tell you now."
  answer[++answer_count] = "Cannot predict now."
  answer[++answer_count] = "Concentrate and ask again."
  answer[++answer_count] = "Do not count on it."
  answer[++answer_count] = "My reply is no."
  answer[++answer_count] = "My sources say no."
  answer[++answer_count] = "Outlook not so good."
  answer[++answer_count] = "Very doubtful."
}

{
  if (!begin_event("8ball-module", "0.2.0")) next
  text = safe_string("message", "plain_text")
  if (text == "/8ball" || substr(text, 1, 7) == "/8ball ") {
    sender = safe_string("message", "sender")
    if (sender == "") sender = "someone"
    pick = int(next_random() * answer_count) + 1
    emit_message("🎱 " sender ": " answer[pick])
  }
  emit_event_ok()
}
