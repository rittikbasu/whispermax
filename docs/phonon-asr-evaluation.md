# Phonon-2 evaluation

## Decision

Keep Whisper as WhisperMax’s default until Phonon-2 is checked on paired recordings of the user’s own dictation and through the actual capture-to-insertion path. The evidence does not justify rejecting Phonon: our first public accuracy comparison used a scorer that mishandled ordinary number and filler differences, and our first memory comparison used a high-memory server runtime rather than Detta’s specialized adapter. The corrected results are mixed: Phonon leads on the small public speech sample; Whisper leads on the synthetic dictation set.

The 164 MB Phonon download is real, and the same model checkpoint can run quickly with a lower-memory packed path. That does not mean every Phonon runtime uses less memory. On this M1 Pro, Detta’s default dense path peaked above Whisper; its packed path peaked below Whisper only after its conversion cache was present. The first conversion still used more memory than Whisper.

## What was tested

The runs used a 16 GB M1 Pro on macOS 27.0. The Mac was locked during this investigation, so I could not exercise the app UI, microphone permission, hotkey capture, or insertion into another app. I inspected the signed Detta 1.0.21 bundle and replayed its bundled speech adapter headlessly without launching the GUI or signing in.

The evaluation uses two screening sets:

- Twenty short clips from separate Earnings-22 source recordings, with 301 reference words after normalization.
- Seventy-two synthetic dictation clips in clean, noisy, and rushed variants, with 642 normalized reference words and eight generated voices.

All engines in each comparison received the same canonical 16 kHz mono PCM WAV files. We verified the public clip IDs and offsets against the references and found no corrupt or mismatched audio. Re-encoding the public clips changed one transcript for some engines, so the final tables use the canonical waveforms for every row. Detta’s adapter also adds 250 ms of silence to each end; that is a real preprocessing difference, and its effect on accuracy was mixed.

The checked-in `Scripts/score_asr_benchmark.py` only case-folds and tokenizes punctuation. It does not implement the [Open ASR English normalizer](https://github.com/huggingface/open_asr_leaderboard/blob/7ce09ca6c5fb4aac32b4a528d906356a21ad5399/normalizer/normalizer.py), which also reconciles number forms, fillers, and spelling variants. The first public result incorrectly counted outputs such as “seventeen point six percent” and “17.6%” as different words. The tables below use the leaderboard’s English normalizer pinned at commit `7ce09ca6c5fb4aac32b4a528d906356a21ad5399`; they measure recognized content, not formatting or insertion quality.

## Accuracy and warm decode time

The latency column is the median warm per-clip time from each engine path; model load is excluded. It includes that path’s audio front end and decode, but not WhisperMax’s hotkey, UI, or text insertion work.

### Public Earnings-22 screen

| Engine/path | Word edits / words | WER | Exact clips | Warm p50 |
| --- | ---: | ---: | ---: | ---: |
| Whisper large-v3-turbo | 17 / 301 | 5.65% | 11/20 | 861 ms |
| Fermion HTTP, `tdt16,dense16` | 11 / 301 | 3.65% | 15/20 | 81 ms |
| Detta C4 default, BF16 `tdt16,dense16` | 13 / 301 | 4.32% | 13/20 | 85 ms |
| Detta C4 packed, BF16 `tdt16` | 13 / 301 | 4.32% | 13/20 | 140 ms |

One word changes this sample’s WER by 0.33 percentage points, so the 2-edit difference between the Phonon paths is not meaningful evidence of a quality gap. This small subset favors Phonon over Whisper; it is not a broad benchmark result or a proxy for personal dictation.

### Synthetic dictation screen

| Engine/path | Word edits / words | WER | Exact clips | Warm p50 |
| --- | ---: | ---: | ---: | ---: |
| Whisper large-v3-turbo | 41 / 642 | 6.39% | 56/72 | 837 ms |
| Fermion HTTP, `tdt16,dense16` | 74 / 642 | 11.53% | 47/72 | 53 ms |
| Detta C4 default, BF16 `tdt16,dense16` | 63 / 642 | 9.81% | 48/72 | 55 ms |
| Detta C4 packed, BF16 `tdt16` | 64 / 642 | 9.97% | 49/72 | 98 ms |

Whisper leads this synthetic set by 22–23 word edits. Detta’s adapter improves on the HTTP path by 10–11 edits, but it does not close the gap. Synthetic voices can reveal number, name, and disfluency errors; they cannot settle which engine will work better on the user’s real voice.

## Process memory

These are peak physical-footprint measurements for separate inference processes on the same M1 Pro. Whisper used `/usr/bin/time -l`; the Python Phonon processes used `footprint -p` and recorded `phys_footprint_peak`. Each process loaded its model once and replayed the whole matching set. Values are decimal GB. They do not include WhisperMax’s UI process or represent total system memory.

| Engine/runtime | Public 20 clips | Synthetic 72 clips |
| --- | ---: | ---: |
| Whisper large-v3-turbo | 1.882 GB | 1.880 GB |
| Fermion HTTP, `tdt16,dense16` | 4.637 GB | 3.898 GB |
| Detta C4 default, BF16 `tdt16,dense16` | 2.248 GB | 2.102 GB |
| Detta C4 packed, BF16 `tdt16` | 1.647 GB | 1.495 GB |

The first HTTP memory report stopped sampling before the last public clip and reported 3.98 GB. The corrected run sampled through all 20 clips and peaked at 4.64 GB. This was a runtime and measurement-window problem, not an intrinsic memory requirement of the packed checkpoint.

Detta’s packed path used 12.5% less process footprint than Whisper on the public set and 20.5% less on the synthetic set, with warm decode about 6–9 times faster on these short clips. Its default dense path was 11.8–19.4% above Whisper’s peak. Packed Phonon remains a promising speed-and-memory option, but its margin depends on the conversion cache: on a cache miss the packed adapter took 9.89 seconds to load, 0.16 seconds to warm, and peaked at 2.85 GB. With a conversion cache present, measured load ranged from 1.9 to 3.3 seconds in these runs. The cache is stored on disk by the adapter.

## What differs in the runtimes

The model file inside Detta has the same SHA-256 as the checkpoint used by the Fermion runner: `4b6bfa3a12cc3c4e0a54f2ab3ec4ca7a842b09e5c7ecfc8e7ca0ac6cc8c11468`. The difference is how each runtime prepares and holds its weights:

- The initial WhisperMax screen used Fermion’s HTTP service with the dense encoder path. Its first run also omitted the `tdt16` fast decode setting. Replays with `tdt16,dense16` produced the same transcripts; the flag changes the decode path, not recognition quality.
- Detta’s bundled adapter uses BF16 activations, an FP32 log-mel front end, explicit MLX cache and wired-memory limits, and an on-disk converted-weight cache. Its default enables `tdt16,dense16`; setting only `tdt16` keeps the encoder packed and cuts warm-cache memory at the cost of about 55 ms per public clip in this sample.
- The shipped Phonon model is roughly 178 MB on disk versus 1.62 GB for Whisper large-v3-turbo. Its packed weights are expanded or converted for particular runtimes, so download size does not equal peak inference memory.

The generic Fermion server comparison used `fermion-research` 0.2.4 with `FERMION_P2_FAST=tdt16,dense16`. The current 0.2.6 package retains identical Phonon-2 engine and fast-decoder source; its source was inspected but not executed, so the stored measurements remain from 0.2.4. The default `dense16` path replaces packed 2-bit encoder operations with FP16 GEMM; Fermion's code comments describe this as its speed path, with about 0.4 GB extra peak memory and 174× versus 109× realtime on an M5 for long audio. `tdt16` without `dense16` keeps the packed, bit-exact path. Thus the generic run used Fermion's speed-oriented default, not its lower-memory setting. Its 3.9–4.6 GB peak belongs to that Python/MLX server process and is not an intrinsic memory requirement of the 164 MB model.

Fermion now also advertises a separate Core ML Phonon-2 path at up to 212× realtime on an M5 with a 631 MB package. The linked Hugging Face repository was not accessible to this account during review, so that runtime has not been inspected or measured here.

Fermion’s [Phonon-2 report](https://www.fermionresearch.com/research/phonon-2/) reports 5.21% average WER on seven full public English sets and 174× realtime on an M5 MacBook Air with model load excluded. Its table shows Phonon ahead of Whisper large-v3-turbo on the seven-set average, but not on every individual set. The report publishes download/on-disk size and throughput, not a comparable peak-RAM measurement. Its M5 throughput number is not an app-level latency claim for this M1 Pro.

The Detta bundle also includes a warm engine daemon and local cleanup model. Static inspection shows hold-to-talk capture, partial decoding, and a cleanup fallback to raw text if a structural guard or timeout fails. The cleanup code describes an 8-bit Qwen3-0.6B fine-tune with roughly 367 MB of weights. The [public Detta repository](https://github.com/fermionresearch/detta-releases) currently publishes signed releases and a README, not the app source; I also found no separate Gluon model in [Fermion’s public model catalog](https://huggingface.co/FermionResearch). The shipped code and weights are inspectable inside the app bundle, but I cannot verify Gluon as a separately published open-source model. Its release README says recordings and transcripts are shared for improvement unless sharing is turned off in Settings. I did not sign in, launch the GUI, send user audio, or measure cleanup quality, latency, or memory.

## VAD

Inference speed alone does not say whether a hotkey activation contains speech or when speech has ended. On the four local silence/noise/cough controls, VAD rejected all four in 50–129 ms, while no-VAD Whisper emitted text for all four. On the synthetic speech set, VAD added about 12 ms to Whisper’s median and increased WER by 1.12 points. Earlier no-VAD Phonon screening emitted text for the cough control and suppressed the other three.

Keep VAD on the existing Whisper path. For a Phonon experiment, preserve VAD until the capture flow is tested. Detta’s hold-to-talk behavior could replace some endpointing work by making the user define the recording boundaries, but that should be evaluated against false starts, silence, and cancellation in the real app.

## Next step

The repository’s [recording guide](asr-personal-benchmark.md) already prepares a small controlled Mac-mic/AirPods set plus natural dictations. The saved reference texts do not have paired speech recordings. A few human-checked recordings from the user’s own voice are still the highest-value accuracy gate; keep the audio, references, and predictions in ignored local storage and out of Git.

Once the Mac is unlocked, run Whisper and cached packed Phonon on identical recordings, then exercise the actual hotkey-to-visible-insertion path, silence rejection, cancellation, repeated dictation, clipboard fallback, and offline restart. For this personal-use stage, defer clean-account relocation, notarization, install accounting, and a physical macOS 14 machine.
