# Personal ASR benchmark recording guide

This is a short, repeatable recording set for comparing local transcription models on the way WhisperMax is actually used. It complements public speech benchmarks; it does not replace them.

## Controlled prompts

Read each line naturally as if dictating it. Do not read punctuation aloud, over-enunciate, or correct a stumble. Keep one recording per prompt. Use a reviewed human transcript as the reference; do not make either model's output the ground truth. For numbers, preserve the intended value in a separate checklist so a spelling-versus-digit formatting choice is not mistaken for a wrong value.

1. Please move my check-in with Neha to Friday at eleven and send her the notes before lunch.
2. The total is four thousand seven hundred eighty rupees and fifty paise, due on 14 October at 6:15 p.m. Please round the estimate up to five thousand rupees.
3. Rittik, ask Ananya Mukherjee to review the WhisperMax release notes before the macOS build goes out.
4. Open System Settings, choose Keyboard, then check the Shortcuts page for the recording action.
5. Let’s meet at, uh, four—actually, make that four thirty near the north entrance.
6. Keep VAD enabled for silence, then compare Phonon against Whisper on the same recording.
7. I’ll send the draft this afternoon. First, check the transcript against the original recording, then save the correction for tomorrow’s build. If anything sounds wrong, leave it untouched until I can review it.
8. I want to write a short note about why the right microphone matters, then leave a clean copy in Notes.

## Recording conditions

Use the same eight prompts in these conditions, keeping each recording as a separate file:

1. Mac microphone, fan off.
2. AirPods microphone, fan off.
3. Mac microphone, fan on, for prompts 1, 2, 5, and 7.
4. AirPods microphone, fan on, for prompts 1, 2, 5, and 7.

That gives 24 paired speech clips without turning the exercise into a long session. The Mac microphone with the fan off is the primary personal baseline; the other conditions show whether the model choice changes with the input device or background noise. Use WhisperMax’s normal capture path so the benchmark includes its actual audio format and levels.

## Natural dictation

Add two 20–30 second recordings on the Mac microphone with the fan off. Dictate something you would genuinely say to WhisperMax, without reading a prepared sentence. Review each recording yourself and write a verbatim reference, preserving spoken words and self-corrections while using ordinary written punctuation. Score these separately from the controlled prompts.

## Keeping the set useful

- Keep one local manifest that pairs each audio file with its exact reference, model, and recording condition.
- Do not commit the audio, private references, or per-clip transcripts. Keep them under the ignored `.private-bench/` directory; only aggregate scores and non-private test code belong in Git.
- Compare candidate models on the exact same files. Keep the prompt set fixed when testing a new model; add new prompts as a separate version rather than replacing the old ones.
- Report word error rate and character error rate, plus exact-match count and the errors on names, dates, and numbers. Keep public-benchmark scores separate from personal scores.
