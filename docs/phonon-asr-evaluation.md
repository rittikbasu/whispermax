# Phonon-2 screening

**Date:** 2026-10-01

**Branch:** `feat/phonon-asr`

## Decision

Do not replace Whisper with Phonon-2 on the evidence available. Phonon is much faster after warm-up and its weight file is smaller, but the synthetic screen showed substantially worse strict WER and higher peak memory. A small public human-speech screen is more mixed: Phonon did better on clips without numbers, while its written-out number forms are counted as WER errors. Keep Whisper as the product path until Phonon clears a human-checked personal set and its actual memory cost is acceptable.

This is a synthetic-voice screening result, not a verdict about Rittik's own voice. The repository contains reference text from earlier dictation work, but the matching speech recordings were not found. An automated similarity pass did not recover spoken reference/audio pairs among the 41 distinct WAV fixtures; the confidently recovered sidecar pairs are no-speech controls. No audio or transcript output is tracked.

## Evaluation

The paired set has 24 reference utterances in clean, noisy, and rushed variants: 72 clips, eight synthetic voices, and 627 reference words. Every engine received the same clips. `Scripts/score_asr_benchmark.py` normalizes Unicode, case, and punctuation, then computes word error rate, character error rate, exact transcripts, and protected-term misses. The benchmark manifest, audio, and result JSONL files remain local under ignored `dist/` and `.private-bench/` paths.

The runs were made on a 16 GB M1 Pro running macOS 27.0; WhisperMax's deployment target is macOS 14.0. The Phonon prototype ran offline with Python 3.12, `fermion-research` 0.2.4, `mlx-audio` 0.4.6, and MLX 0.32.3 macOS 14-target wheels. Torch was not installed. The host was not a macOS 14 machine.

| Engine | VAD | WER | CER | Exact | Protected-term misses | Warm p50 / p95 | Peak footprint |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Whisper large-v3-turbo | On | 9.09% | 4.78% | 52/72 | 19 | 891 / 923 ms | 1.90 GB |
| Whisper large-v3-turbo | Off | 7.97% | 3.73% | 53/72 | 18 | 880 / 953 ms | 1.95 GB |
| Phonon-2 dense16 | On | 20.10% | 12.70% | 33/72 | 39 | 68 / 144 ms | 3.26 GB |
| Phonon-2 dense16 | Off | 18.82% | 10.96% | 34/72 | 36 | 66 / 74 ms | 3.72 GB |

Phonon's measurements are local HTTP request/decode times from a persistent process; VAD preprocessing time and WhisperMax UI work are not included. The first Phonon process became ready in 10.67 seconds; its first decode took 3.01 seconds while compiling the initial MLX path. A later launch, with the OS shader cache warm, had a 0.12-second first request. These are not app-level release-to-visible-text measurements. Phonon's idle process used about 0.01 CPU seconds over 60 seconds.

The Phonon weight file is 177 MB versus 1.62 GB for the installed Whisper model. Its prototype virtual environment is 395 MB and its local model cache is 325 MB; the environment still relies on a Homebrew Python interpreter, so this is not a self-contained distributable app.

## VAD result

On the four local silence/noise/cough controls, no-VAD Whisper produced text for all four; VAD rejected all four in 50–129 ms each. On the 72 speech clips, VAD changed Whisper's median processing by about 12 ms and increased WER by 1.12 percentage points. Keep VAD in the existing app path for now: the small median cost buys reliable rejection on the controls. Revisit it on the personal voice set.

Phonon also made fewer errors without VAD on the synthetic speech clips, but its accuracy remained well behind Whisper. On the no-VAD control results, it produced text for the cough clip and suppressed the other three.

## Public speech screen

The synthetic corpus is not enough to make an accuracy decision. A fixed subset from the test-only short-form configuration of [Earnings-22](https://huggingface.co/datasets/distil-whisper/earnings22) was sampled locally from 24 separate source recordings. Four samples were excluded by preset rules for a sub-second fragment, fewer than four reference words, a crosstalk annotation, or an unfinished reference. The remaining 20 clips contain 314 reference words and 124 seconds of speech. The dataset describes its short-form clips as punctuation-aligned segments, capped at 20 seconds; this is spontaneous earnings-call speech, with different vocabulary, channels, and turn-taking from personal dictation. It is a useful external screen, not a proxy for Rittik's voice. The downloaded clips, references, selection notes, and per-sample outputs stay under ignored `.private-bench/` paths.

Both models ran without VAD on the same clips, offline, on the M1 Pro. The sample is too small to call a winner, and strict WER is biased by number formatting: Phonon writes values such as `17.6%`, `2020`, and `€5.02` as words, while this scorer only normalizes case and punctuation. Those meaning-preserving format differences count as word edits. A diagnostic score on the 16 references without digits was 4.02% WER for Phonon and 8.48% for Whisper, across only 224 words; that subset deliberately does not measure numbers.

| Engine | Strict WER | CER | Exact | Warm processing/request p50 / p95 | Peak physical footprint |
| --- | ---: | ---: | ---: | ---: | ---: |
| Whisper large-v3-turbo, no VAD | 10.51% | 5.75% | 6/20 | 855 / 946 ms | 1.79 GB |
| Phonon-2 dense16, no VAD | 12.10% | 9.95% | 11/20 | 99 / 259 ms | 3.98 GB |

Whisper's timing is per-clip decode plus inference. Phonon's warm timing is a persistent local HTTP request plus inference; its server was ready in 9.0 seconds and its first decode took 113 ms. Neither is shortcut-to-visible-text timing. Phonon weights remain much smaller (177 MB versus 1.62 GB), but its observed peak footprint was about 2.2 times Whisper's on these runs. It also added a trailing "This year" to one sample and an extra "Uh" to another, so a future cleanup model cannot be assumed to fix the ASR path without its own paired test.

## Boundary and next step

No Phonon app integration or shortcut-to-microphone-to-insertion test was attempted after the quality gate failed. The current prototype proves offline inference on this macOS 27 host using macOS 14-target MLX wheels; it does not prove runtime behavior on macOS 14 or a relocatable, self-contained package. Those costs are deferred until a model first matches Whisper on a human-checked personal set.

The personal-use decision still requires a private, paired recording set from the user. [The recording guide](asr-personal-benchmark.md) prepares a small controlled mic/noise set plus two natural dictations. Keep those audio files, private references, and per-clip predictions out of Git; use public and personal scores as separate evidence.

For this personal-use stage, defer clean-account relocation, notarization/quarantine, install/update disk accounting, and a physical macOS 14 machine. Revisit distribution gates only if the candidate first clears the personal accuracy check and you decide to share it. If it does, still prove the app's real capture-to-visible-insertion path on your M1 Pro before replacing the Whisper path.
