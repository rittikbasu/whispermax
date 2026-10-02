# Personal ASR benchmark

This small, private set compares transcription models on the owner’s voice, microphones, and ordinary dictation. Synthetic audio is excluded from all benchmark scores and model-adoption decisions.

## Recording set v2

The private recording page in `.private-bench/recorder/v2/` prepares sixteen takes: fourteen speech samples and two no-speech controls. The prompts total about five minutes of speech; allow extra time to switch microphones and review each recording:

1. Three short prompts and two optional longer requests on the built-in Mac microphone, room fan off.
2. The three short prompts on the AirPods microphone, room fan off.
3. The three short prompts and a six-second no-speech control on the AirPods microphone, room fan on.
4. The three short prompts and a six-second no-speech control on the built-in Mac microphone, room fan on.

The prompts reflect common shapes in the owner's dictation history: short implementation requests, technical terms, a clarification, numbers, and longer debugging requests. The first long take repeats the earlier natural dictation; the second is a longer workflow prompt. Prompt wording and history-derived material remain private. History informs prompt design; it is not a verified reference for old recordings.

Use the normal seated distance and normal voice used for the app, including with the fan on. Keep the Mac-to-speaker geometry consistent across the paired fan conditions. A closer recording can be a separately labelled diagnostic, but should not replace the usual-distance baseline. Read at an ordinary pace without saying punctuation or deliberately adding fillers. Natural hesitations can remain if the reference matches them.

Confirm the actual named input and room fan setting for each group. Record the usual fan speed and available macOS Mic Mode/AirPods listening settings. Wait for “Speak now”: capture starts first and retains a two-second settling lead-in. The microphone stays connected between takes until the input changes, the session ends, or it is disconnected. Audio outside a take is discarded. Listen and check complete first/last words before keeping; rerecord if startup hiss obscures speech or words are missing.

The page records mono WAV locally in the browser. It requests disabled echo cancellation, noise suppression, and automatic gain control, then records the actual track settings in the manifest. Browser and device processing can still differ from WhisperMax's AVAudioEngine path, so use these clips for same-file model comparisons, not as a byte-identical reproduction of app capture.

## Scoring and interpretation

- Use only playback-checked references. The page requires confirmation before keeping a take and allows editing the reference to the words actually captured.
- Assess no-speech controls separately for false-positive transcription, rather than including them in WER.
- Feed every candidate model the same WAV file. Keep each result paired by clip and recording condition.
- Report WER and exact-match count, with a small error review for names, technical terms, dates, amounts, insertions, and omissions. Apply the same normalizer to every model.
- Keep this single-speaker result separate from public benchmark scores. The set provides a useful personal signal, not enough evidence for a universal or statistically precise ranking.
- Preserve v1 separately. V2 has its own browser database and manifest version. Do not silently relabel old AirPods fan conditions or mix unverified v1 references into a checked v2 result.

## Privacy

- Keep recordings, private references, and exported archives under `.private-bench/`; do not commit them.
- The benchmark guide and scorer can be committed, but no per-clip personal audio or transcript belongs in Git.
- Export the session before clearing browser storage. Browser data and exported ZIP files are separate copies.
