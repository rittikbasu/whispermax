# Phonon-2 evaluation

## Decision

Keep Whisper large-v3-turbo as WhisperMax’s default. The playback-confirmed v2 personal set shows Phonon-2 is faster, but every tested runtime makes more word errors overall and materially more errors on the twelve short takes closest to ordinary dictation. Phonon is markedly better on the two long takes, which account for 286 of the set’s 538 words and pull its aggregate CER down. That is useful evidence for long-form dictation, but it does not justify replacing the current default.

The 164 MB Phonon download is real, and the same model checkpoint can run quickly with a lower-memory packed path. That does not mean every Phonon runtime uses less memory. On this M1 Pro, Detta’s default dense path peaked above Whisper; its packed path peaked below Whisper only after its conversion cache was present. The first conversion still used more memory than Whisper.

## What was tested

The runs used a 16 GB M1 Pro on macOS 27.0. I inspected the signed Detta 1.0.21 bundle and replayed its bundled speech adapter headlessly without signing in. I also reran the public set with `fermion-research` 0.2.6 using canonical 16 kHz mono files. The hotkey-to-insertion path remains untested because the v2 results do not justify starting a Phonon integration.

The earlier external screen uses twenty short clips from separate Earnings-22 source recordings (1.26–15.28 seconds), with 301 reference words after normalization. It is a small, separate public check; the personal recordings are the primary accuracy set for this project.

The public canonical manifest retains the same clip IDs, source recording IDs, offsets, and references as the source manifest; its resampled file durations differ from the reference durations by at most 0.25 ms. Re-encoding the public clips changed one transcript for some engines, so the table uses the canonical waveforms for every row. Detta’s adapter also adds 250 ms of silence to each end; that is a real preprocessing difference, and its effect on accuracy was mixed.

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

## Personal benchmark v2

On 2026-10-02, the user playback-confirmed all fourteen recorded speech references in the private v2 set. The set includes short requests, technical terms, numbers, two longer Mac-mic dictations, and two room-noise controls. No synthetic audio or synthetic result is used here. The private report, recordings, references, and raw predictions remain under the ignored .private-bench/personal-asr-v2/ directory.

The direct model comparison fed each engine the same canonical 16 kHz mono WAV. I then repeated the app's current VAD preprocessing: six speech clips were trimmed, eight other speech files were left whole because they exceeded the 12-second trim limit, and VAD rejected both room-noise controls. This checks the current audio windowing without changing model input files between engines.

| Engine/path | Word edits / words | WER | Character edits / characters | CER | Exact takes |
| --- | ---: | ---: | ---: | ---: | ---: |
| Whisper large-v3-turbo + app VAD | 48 / 538 | 8.92% | 119 / 3,003 | 3.96% | 3/14 |
| Phonon-2 MLX + app VAD windows | 58 / 538 | 10.78% | 73 / 3,003 | 2.43% | 4/14 |
| Phonon-2 CPU + app VAD windows | 59 / 538 | 10.97% | 70 / 3,003 | 2.33% | 4/14 |
| Phonon-2 Core ML + app VAD windows | 58 / 538 | 10.78% | 74 / 3,003 | 2.46% | 4/14 |

Twelve short takes (252 words) are closest to ordinary dictation. Whisper scored 33 edits (13.10% WER; 3.04% CER). Phonon scored 57–58 edits (22.62–23.02% WER; 4.47–4.53% CER) across MLX, CPU, and Core ML. On the two longer takes, Phonon scored one word edit versus Whisper's fifteen. Those two takes supply 286 of the 538 reference words, so overall WER alone hides the short-form regression. The lower Phonon CER indicates closer character strings, but it does not overcome its higher word error rate on typical short requests.

The VAD-window rerun did not rescue Phonon. The direct no-VAD run had WER of 8.92% for Whisper, 10.59% for MLX, 11.15% for CPU, and 10.41% for Core ML. Whisper's current VAD left WER unchanged, improved CER by three characters, and rejected both noise controls; its no-VAD path transcribed both. These two controls are too few to estimate a general false-positive rate.

Warm model processing medians were about 0.956 s for Whisper, 0.179 s for MLX, 0.334 s for CPU, and 0.129 s for Core ML. These method-level times exclude load, recording, VAD analysis, the hotkey/UI, and text insertion; the runners do not measure identical intervals, so they are not end-to-end latency claims.

On this Mac, Phonon MLX peaked at 5.81 GB process footprint and still held 5.80 GB after 20 seconds idle. The packed CPU path used 1.54 GB, only modestly below Whisper's 1.81 GB in the VAD run. Core ML used 74.9 MB within its process, but this excludes separate Neural Engine memory; its compiled model directory was 357.6 MB and FluidAudio requires macOS 15. Phonon's base checkpoint is 177.4 MB, while the CPU conversion cache adds 303.8 MB (about 481.5 MB together). Whisper's model file is 1.625 GB. MLX model load took 14.18 seconds; CPU load took 9.78 seconds with its conversion cache already present; Core ML load was 0.285 seconds with the compiled model already cached. Clean-cache Core ML compilation was not measured.

This is a small, paired personal pilot, not a universal model ranking. Its references were checked, but two first AirPods takes have unknown microphone/listening-mode metadata. See the ignored private report for the full condition split, runtime details, and limitations. No shortcut-to-insertion test was run because none of the Phonon paths met the short-form accuracy gate.

## Process memory

These are peak physical-footprint measurements for separate inference processes on the same M1 Pro, read with macOS `footprint -p`. Each process loaded its model once and replayed the full set without VAD; the refreshed public runs sampled after every clip. Values are decimal GB. They include the Python/MLX server, not just the checkpoint, and exclude WhisperMax’s UI process and total system memory.

| Engine/runtime | Public 20 clips |
| --- | ---: |
| Whisper large-v3-turbo | 1.880 GB |
| Fermion MLX 0.2.6 default, `tdt16,dense16` | 4.647 GB |
| Fermion MLX 0.2.6 packed, `tdt16` | 5.612 GB |
| Detta C4 default, BF16 `tdt16,dense16` | 2.248 GB |
| Detta C4 packed, BF16 `tdt16` | 1.647 GB |

The earlier public default summary sampled only through clip 12. A refreshed run measured 4.647 GB after clip 20. The package default (`tdt16,dense16`) decoded at 85 ms p50; the packed-only `tdt16` run used 5.612 GB and decoded at 146 ms p50 on the same public clips. Model-ready startup took 9–13 seconds; keeping a default worker warm can hide that delay but held about 3.05 GB while idle in these runs. Both generic paths produced the same normalized WER and exact-clip counts on this screen, although their raw transcript strings differed for 2/20 clips. In this generic runner, packed-only was slower and did not reduce process peak memory. Detta’s lower packed-path footprint therefore reflects its runtime controls and weight cache, not just a different invocation of the same generic server.

On the public screen, Detta’s packed path used 12.4% less process footprint than Whisper and warm decode was about 6 times faster on these short clips. Its default dense path was 19.6% above Whisper’s peak. Packed Phonon remains a promising speed-and-memory option, but its margin depends on the conversion cache: on a cache miss the packed adapter took 9.89 seconds to load, 0.16 seconds to warm, and peaked at 2.85 GB. With a conversion cache present, measured load ranged from 1.9 to 3.3 seconds in these runs. The cache is stored on disk by the adapter. These are measurements from Detta’s custom adapter, not from Fermion’s generic `tdt16` setting.

## What differs in the runtimes

The model file inside Detta has the same SHA-256 as the checkpoint used by the Fermion runner: `4b6bfa3a12cc3c4e0a54f2ab3ec4ca7a842b09e5c7ecfc8e7ca0ac6cc8c11468`. The difference is how each runtime prepares and holds its weights:

- Replaying both Fermion paths produced the same normalized WER and exact-clip counts on the public screen, but 2 raw transcript strings differed. Fermion documents the dense encoder conversion as not bit-exact, so outputs can vary by path and the observed agreement in aggregate scores should not be generalized to other audio.
- Detta’s bundled adapter uses BF16 activations, an FP32 log-mel front end, explicit MLX cache and wired-memory limits, and an on-disk converted-weight cache. Its default enables `tdt16,dense16`; setting only `tdt16` keeps the encoder packed and cuts warm-cache memory at the cost of about 55 ms per public clip in this sample.
- The shipped Phonon model is roughly 178 MB on disk versus 1.62 GB for Whisper large-v3-turbo. Its packed weights are expanded or converted for particular runtimes, so download size does not equal peak inference memory.

The generic Fermion runs used `fermion-research` 0.2.6 offline. Its package source sets `FERMION_P2_FAST=tdt16,dense16` as the default; Fermion’s report describes the Apple-silicon path as MLX with a dense 16-bit encoder and a batched GPU TDT loop. On the M1 Pro, the package default reproduced the earlier 0.2.4 normalized transcripts exactly on the public screen. The packed-only `tdt16` path was slower and peaked higher. The default peak was 4.65 GB, versus 1.88 GB for Whisper. This is consistent with weights being expanded into runtime buffers and with the generic server’s allocation behavior; the 164 MB download is not a prediction of process RAM.

The authenticated Hugging Face read succeeded. The published Phonon-2 repository contains the packed model archive and reference/container code; it does not contain a separate Core ML Phonon artifact. Fermion’s published 174× result is MLX on an M5 with model load excluded. Its comparison table’s 104.9× Core ML row is FluidAudio running Parakeet TDT, not Phonon-2. The published 164 MB download/178 MB on-disk figure describes model size, not peak process RAM.

Fermion’s [Phonon-2 report](https://www.fermionresearch.com/research/phonon-2/) reports 5.21% average WER on seven full public English sets and 174× realtime on an M5 MacBook Air with model load excluded. Its table shows Phonon ahead of Whisper large-v3-turbo on the seven-set average, but not on every individual set. The report publishes download/on-disk size and throughput, not a comparable peak-RAM measurement. Its M5 throughput number is not an app-level latency claim for this M1 Pro.

The Detta bundle also includes a warm engine daemon and local cleanup model. Static inspection shows hold-to-talk capture, partial decoding, and a cleanup fallback to raw text if a structural guard or timeout fails. The cleanup code describes an 8-bit Qwen3-0.6B fine-tune with roughly 367 MB of weights. The [public Detta repository](https://github.com/fermionresearch/detta-releases) currently publishes signed releases and a README, not the app source; I also found no separate Gluon model in [Fermion’s public model catalog](https://huggingface.co/FermionResearch). The shipped code and weights are inspectable inside the app bundle, but I cannot verify Gluon as a separately published open-source model. Its release README says recordings and transcripts are shared for improvement unless sharing is turned off in Settings. I did not sign in, launch the GUI, send user audio, or measure cleanup quality, latency, or memory.

## VAD

Inference speed alone does not say whether a hotkey activation contains speech or when speech has ended. On the four local silence/noise/cough controls, VAD rejected all four in 50–129 ms, while no-VAD Whisper emitted text for all four. Earlier no-VAD Phonon screening emitted text for the cough control and suppressed the other three.

Keep VAD on the existing Whisper path. In v2, app VAD left Whisper WER unchanged, reduced CER by three characters, and rejected both room-noise controls. The Phonon VAD-window rerun still lost on short-form WER, so VAD does not change the adoption decision. The two controls are only a small check. Detta’s hold-to-talk behavior could replace some endpointing work by making the user define recording boundaries, but that would need a separate evaluation against false starts, silence, and cancellation in the real app.

## Next step

The v2 personal references have been playback-confirmed, and all candidate paths were scored on paired canonical files. The current evidence is a no-go for replacing Whisper: keep Whisper as the default, keep the audio and raw predictions out of Git, and reuse this fixed private set when a meaningfully improved Phonon runtime or model is available. No additional recording is needed for the current decision.

Do not start the Phonon hotkey-to-insertion integration unless a future run clears the short-form accuracy gate. If that happens, test the actual capture, VAD, silence rejection, cancellation, repeated dictation, clipboard fallback, and offline restart path. For this personal-use stage, defer clean-account relocation, notarization, install accounting, and a physical macOS 14 machine.
