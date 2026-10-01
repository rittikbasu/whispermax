# Phonon-2 evaluation

## Decision

Keep Whisper as WhisperMax’s default until Phonon-2 is checked on paired recordings of the user’s own dictation and through the actual capture-to-insertion path. The evidence does not justify rejecting Phonon: our first public accuracy comparison used a scorer that mishandled ordinary number and filler differences, and our first memory comparison used a high-memory server runtime rather than Detta’s specialized adapter. The corrected results are mixed: Phonon leads on the small public speech sample; Whisper leads on the synthetic dictation set.

The 164 MB Phonon download is real, and the same model checkpoint can run quickly with a lower-memory packed path. That does not mean every Phonon runtime uses less memory. On this M1 Pro, Detta’s default dense path peaked above Whisper; its packed path peaked below Whisper only after its conversion cache was present. The first conversion still used more memory than Whisper.

## What was tested

The runs used a 16 GB M1 Pro on macOS 27.0. I inspected the signed Detta 1.0.21 bundle and replayed its bundled speech adapter headlessly without signing in. I also reran the public set with `fermion-research` 0.2.6 using the canonical 16 kHz mono files. The Mac screen was locked when Computer Use attempted the app check, so the hotkey, microphone capture, and insertion path remain untested.

The evaluation uses two screening sets:

- Twenty short clips from separate Earnings-22 source recordings (1.26–15.28 seconds), with 301 reference words after normalization.
- Seventy-two synthetic dictation clips (1.78–4.21 seconds): 24 unique prompts, each rendered as clean, noisy, and rushed audio across eight generated voices, with 642 normalized reference words.

All engines in each comparison received the same canonical 16 kHz mono PCM WAV files. I rechecked all 20 public files and all 72 synthetic files: every file is readable, and the synthetic audio is 16 kHz mono. The public canonical manifest retains the same clip IDs, source recording IDs, offsets, and references as the source manifest; its resampled file durations differ from the reference durations by at most 0.25 ms. Re-encoding the public clips changed one transcript for some engines, so the final tables use the canonical waveforms for every row. Detta’s adapter also adds 250 ms of silence to each end; that is a real preprocessing difference, and its effect on accuracy was mixed.

The checked-in `Scripts/score_asr_benchmark.py` only case-folds and tokenizes punctuation. It does not implement the [Open ASR English normalizer](https://github.com/huggingface/open_asr_leaderboard/blob/7ce09ca6c5fb4aac32b4a528d906356a21ad5399/normalizer/normalizer.py), which also reconciles number forms, fillers, and spelling variants. The first public result incorrectly counted outputs such as “seventeen point six percent” and “17.6%” as different words. The tables below use the leaderboard’s English normalizer pinned at commit `7ce09ca6c5fb4aac32b4a528d906356a21ad5399`; they measure recognized content, not formatting or insertion quality.

## Accuracy and warm decode time

The latency column is the median warm per-clip time for the model front end and decode on an already prepared waveform; model load, microphone capture, WhisperMax’s hotkey, UI, and text insertion are excluded.

### Public Earnings-22 screen

| Engine/path | Word edits / words | WER | Exact clips | Warm p50 |
| --- | ---: | ---: | ---: | ---: |
| Whisper large-v3-turbo | 17 / 301 | 5.65% | 11/20 | 843 ms |
| Fermion MLX 0.2.6 default, `tdt16,dense16` | 11 / 301 | 3.65% | 15/20 | 85 ms |
| Fermion MLX 0.2.6 packed, `tdt16` | 11 / 301 | 3.65% | 15/20 | 146 ms |
| Detta C4 default, BF16 `tdt16,dense16` | 13 / 301 | 4.32% | 13/20 | 85 ms |
| Detta C4 packed, BF16 `tdt16` | 13 / 301 | 4.32% | 13/20 | 140 ms |

One word changes this sample’s WER by 0.33 percentage points. The two-edit difference between generic Fermion and Detta is too small to establish a quality gap. This subset favors Phonon over Whisper; it is not a broad benchmark result or a proxy for personal dictation.

### Synthetic dictation screen

| Engine/path | Word edits / words | WER | Exact clips | Warm p50 |
| --- | ---: | ---: | ---: | ---: |
| Whisper large-v3-turbo | 41 / 642 | 6.39% | 56/72 | 860 ms |
| Fermion MLX 0.2.6 default, `tdt16,dense16` | 74 / 642 | 11.53% | 47/72 | 66 ms |
| Fermion MLX 0.2.6 packed, `tdt16` | 74 / 642 | 11.53% | 47/72 | 101 ms |
| Detta C4 default, BF16 `tdt16,dense16` | 63 / 642 | 9.81% | 48/72 | 55 ms |
| Detta C4 packed, BF16 `tdt16` | 64 / 642 | 9.97% | 49/72 | 98 ms |

Whisper leads the generic Fermion path by 33 word edits and Detta’s paths by 22–23. Detta’s adapter improves on the generic path by 10–11 edits, but it does not close the gap. The 72 clips are 24 prompts repeated across three TTS conditions, not 72 independent prompts. I have not listened through and verified each synthesized utterance against its intended reference, so treat this as screening evidence; it does not establish how either engine handles the user’s voice or longer dictation.

## Process memory

These are peak physical-footprint measurements for separate inference processes on the same M1 Pro, read with macOS `footprint -p`. Each process loaded its model once and replayed the full set without VAD; the refreshed public runs sampled after every clip. Values are decimal GB. They include the Python/MLX server, not just the checkpoint, and exclude WhisperMax’s UI process and total system memory.

| Engine/runtime | Public 20 clips | Synthetic 72 clips |
| --- | ---: | ---: |
| Whisper large-v3-turbo | 1.880 GB | 1.882 GB |
| Fermion MLX 0.2.6 default, `tdt16,dense16` | 4.647 GB | 3.904 GB |
| Fermion MLX 0.2.6 packed, `tdt16` | 5.612 GB | 6.003 GB |
| Detta C4 default, BF16 `tdt16,dense16` | 2.248 GB | 2.102 GB |
| Detta C4 packed, BF16 `tdt16` | 1.647 GB | 1.495 GB |

The earlier public default summary sampled only through clip 12. A refreshed run measured 4.647 GB after clip 20. The package default (`tdt16,dense16`) decoded at 85 ms p50; the packed-only `tdt16` run used 5.612 GB and decoded at 146 ms p50 on the same public clips. On the synthetic set, `tdt16` peaked at 6.003 GB and decoded at 101 ms p50, versus 3.904 GB and 66 ms for the default. Model-ready startup took 9–13 seconds; keeping a default worker warm can hide that delay but held about 3.05 GB while idle in these runs. Both generic paths produced the same normalized WER and exact-clip counts on these sets, although their raw transcript strings differed for 2/20 public and 1/72 synthetic clips. In this generic runner, packed-only was slower and did not reduce process peak memory. Detta’s lower packed-path footprint therefore reflects its runtime controls and weight cache, not just a different invocation of the same generic server.

Detta’s packed path used 12.5% less process footprint than Whisper on the public set and 20.5% less on the synthetic set, with warm decode about 6–9 times faster on these short clips. Its default dense path was 11.8–19.4% above Whisper’s peak. Packed Phonon remains a promising speed-and-memory option, but its margin depends on the conversion cache: on a cache miss the packed adapter took 9.89 seconds to load, 0.16 seconds to warm, and peaked at 2.85 GB. With a conversion cache present, measured load ranged from 1.9 to 3.3 seconds in these runs. The cache is stored on disk by the adapter. These are measurements from Detta’s custom adapter, not from Fermion’s generic `tdt16` setting.

## What differs in the runtimes

The model file inside Detta has the same SHA-256 as the checkpoint used by the Fermion runner: `4b6bfa3a12cc3c4e0a54f2ab3ec4ca7a842b09e5c7ecfc8e7ca0ac6cc8c11468`. The difference is how each runtime prepares and holds its weights:

- Replaying both Fermion paths produced the same normalized WER and exact-clip counts on these two screening sets, but 3 raw transcript strings differed. Fermion documents the dense encoder conversion as not bit-exact, so outputs can vary by path and the observed agreement in aggregate scores should not be generalized to other audio.
- Detta’s bundled adapter uses BF16 activations, an FP32 log-mel front end, explicit MLX cache and wired-memory limits, and an on-disk converted-weight cache. Its default enables `tdt16,dense16`; setting only `tdt16` keeps the encoder packed and cuts warm-cache memory at the cost of about 55 ms per public clip in this sample.
- The shipped Phonon model is roughly 178 MB on disk versus 1.62 GB for Whisper large-v3-turbo. Its packed weights are expanded or converted for particular runtimes, so download size does not equal peak inference memory.

The generic Fermion runs used `fermion-research` 0.2.6 offline. Its package source sets `FERMION_P2_FAST=tdt16,dense16` as the default; Fermion’s report describes the Apple-silicon path as MLX with a dense 16-bit encoder and a batched GPU TDT loop. On the M1 Pro, the package default reproduced the earlier 0.2.4 normalized transcripts exactly on both sets. The packed-only `tdt16` path was slower and peaked higher on both sets. Default peaks were 4.65 GB public and 3.90 GB synthetic, versus 1.88 GB for Whisper. This is consistent with weights being expanded into runtime buffers and with the generic server’s allocation behavior; the 164 MB download is not a prediction of process RAM.

The authenticated Hugging Face read succeeded. The published Phonon-2 repository contains the packed model archive and reference/container code; it does not contain a separate Core ML Phonon artifact. Fermion’s published 174× result is MLX on an M5 with model load excluded. Its comparison table’s 104.9× Core ML row is FluidAudio running Parakeet TDT, not Phonon-2. The published 164 MB download/178 MB on-disk figure describes model size, not peak process RAM.

Fermion’s [Phonon-2 report](https://www.fermionresearch.com/research/phonon-2/) reports 5.21% average WER on seven full public English sets and 174× realtime on an M5 MacBook Air with model load excluded. Its table shows Phonon ahead of Whisper large-v3-turbo on the seven-set average, but not on every individual set. The report publishes download/on-disk size and throughput, not a comparable peak-RAM measurement. Its M5 throughput number is not an app-level latency claim for this M1 Pro.

The Detta bundle also includes a warm engine daemon and local cleanup model. Static inspection shows hold-to-talk capture, partial decoding, and a cleanup fallback to raw text if a structural guard or timeout fails. The cleanup code describes an 8-bit Qwen3-0.6B fine-tune with roughly 367 MB of weights. The [public Detta repository](https://github.com/fermionresearch/detta-releases) currently publishes signed releases and a README, not the app source; I also found no separate Gluon model in [Fermion’s public model catalog](https://huggingface.co/FermionResearch). The shipped code and weights are inspectable inside the app bundle, but I cannot verify Gluon as a separately published open-source model. Its release README says recordings and transcripts are shared for improvement unless sharing is turned off in Settings. I did not sign in, launch the GUI, send user audio, or measure cleanup quality, latency, or memory.

## VAD

Inference speed alone does not say whether a hotkey activation contains speech or when speech has ended. On the four local silence/noise/cough controls, VAD rejected all four in 50–129 ms, while no-VAD Whisper emitted text for all four. On the synthetic speech set, VAD added about 12 ms to Whisper’s median and increased WER by 1.12 points. Earlier no-VAD Phonon screening emitted text for the cough control and suppressed the other three.

Keep VAD on the existing Whisper path. For a Phonon experiment, preserve VAD until the capture flow is tested. Detta’s hold-to-talk behavior could replace some endpointing work by making the user define the recording boundaries, but that should be evaluated against false starts, silence, and cancellation in the real app.

## Next step

The repository’s [recording guide](asr-personal-benchmark.md) already prepares a small controlled Mac-mic/AirPods set plus natural dictations. The saved reference texts do not have paired speech recordings. A few human-checked recordings from the user’s own voice are still the highest-value accuracy gate; keep the audio, references, and predictions in ignored local storage and out of Git.

When the Mac is unlocked, finish the actual hotkey-to-visible-insertion path, silence rejection, cancellation, repeated dictation, clipboard fallback, and offline restart. Before reconsidering a model change, compare Whisper and Phonon on a few human-checked recordings of the user’s own dictation. For this personal-use stage, defer clean-account relocation, notarization, install accounting, and a physical macOS 14 machine.
