# Phonon-2 evaluation

## Current status — 2026-10-09

The fresh 67-recording personal run puts Phonon-2 Core ML (10-second function) at the same 96 word edits as production Whisper across 1,166 normalized reference words (8.23% WER). Phonon is better on short and long clips, worse on medium clips, and worse on the small AirPods/full-fan slice. This is evidence for speed and practical fit, not a claim that Phonon is more accurate in every condition. The user has chosen to proceed with Phonon as WhisperMax's sole recognizer, with no runtime Whisper rollback path.

Three pinned 1.1.2 recipes were compared on the same corpus. The existing single-function 10-second recipe scored 96 edits; lowering the window band's minimum to eight seconds scored 109; the official four-function ladder scored 100. Keep the original 10-second recipe. Its repeated warm inference p50 was 64–75 ms and p95 was 158–173 ms. Including audio decode and VAD, speech clips measured 99 ms p50 and 256 ms p95 through inference; capture, UI, and insertion are excluded. The app VAD gate rejected all six silence controls and accepted all 61 speech clips.

The production branch now routes all recognition through Phonon. It prepares Phonon and VAD before reporting ready, warms the encoder with non-silent input, and passes the original recording to Phonon's windowing. The app no longer selects Whisper through environment variables. The Whisper recognizer source stays in the repository for the offline comparison harness and is excluded from the app target; `whisper.xcframework` remains for Silero VAD. Dictionary terms now preserve capitalization after a matching term is recognized; Phonon 1.1.2 has no decode-time vocabulary-bias API.

The app downloads a pinned 345 MB Core ML bundle into a staging directory, verifies each file against SHA-256, resumes interrupted downloads, and installs the verified bundle with rollback and startup recovery for an interrupted replacement. On 2026-10-09, a fresh app download completed, all eight assets matched their pinned byte counts and SHA-256 hashes, Phonon and VAD prepared, and the UI enabled Continue/Get Started only after readiness. A same-size malformed manifest produced the preparation error; Retry detected the hash mismatch, downloaded and installed a valid package, prepared Phonon/VAD, and returned onboarding to Ready without manually repairing the file. The earlier installed-model readiness path and `.previous` backup restoration also pass. After the checks, the original installed package and onboarding marker were restored, all eight original assets were reverified, and the generated fresh duplicates were removed. A retry after an actual network download failure and an installed-model relaunch with networking disabled remain unverified. No personal audio or references were added to Git.

Core ML's first compile on this Mac took 93.7 seconds in an earlier process; with its cache present, a later preparation took 0.52 seconds. Earlier GUI runs saw the separate ANE compiler service peak around 1.17 GB RSS while the app process remained around 80 MB; that was during model preparation and is not the app's own memory. A settled post-setup idle sample measured about 85 MB app physical footprint, 127 MB app high-water, and 127 MiB RSS; `footprint` reported 64 KB current and 336 MB peak Neural Engine allocation, while ANECompilerService was about 1.1 MB RSS at rest. That process had not dictated, so these are startup/idle readings. A separate earlier post-dictation sample measured 90 MB app footprint and 138 MB app high-water. These counters and phases differ and cannot be added or compared directly with Detta's whole-app figures. Earlier GUI smoke checks included a cold 10.8-second insertion dominated by VAD preparation and a 727 ms warm insertion; these are isolated observations, not a repeated latency distribution. The latest unified-log query returned no timing records. A duplicate insertion coincided with two app copies running; the installed copy has been stopped, but a single-process repeat remains. Silence rejection was confirmed once; cancellation during inference, clipboard fallback, microphone switching, sleep/wake, offline installed-model launch, download failure/retry, repeated live latency, and real-speech first/final syllable checks remain open.

### Paired take-level results — 2026-10-08

These comparisons use the same 67-recording manifest and Open ASR EnglishTextNormalizer scoring. Take wins compare normalized word-edit counts per speech recording; condition buckets are small development-set slices. References are marked reviewed, but 16 recordings still have condition metadata marked `needs-human-audit`, so condition-specific results should be read with that caveat.

Across the 61 speech takes, Whisper has fewer edits on 20, Phonon on 16, and they tie on 25. Both are exact on 22 takes; only Phonon is exact on 11, only Whisper on 6, and neither on 22. Their equal 96-edit total also has a different error shape: Whisper has 55 substitutions, 21 deletions, and 20 insertions; Phonon has 60 substitutions, 5 deletions, and 31 insertions. The WER tie therefore does not mean the outputs fail in the same places or in the same way.

| Slice | Recordings and reference words | Whisper edits (WER) | Phonon edits (WER) | Paired pattern |
| --- | --- | ---: | ---: | --- |
| Short, under 8 seconds | 47 speech + 1 control; 567 words | 49 (8.64%) | 35 (6.17%) | Phonon wins on 15 speech takes, Whisper on 10, and 22 tie; Phonon has 14 fewer edits. |
| Medium, 8–30 seconds | 12 speech + 5 controls; 313 words | 39 (12.46%) | 58 (18.53%) | Phonon is worse on 10 of 12 speech takes, ties on 2, and wins on none. It also emits text on 1 of the 5 silence controls. |
| Long, 30 seconds or more | 2 speech; 286 words | 8 (2.80%) | 3 (1.05%) | Phonon wins on 1 take and ties on 1; this is only two recordings. |
| AirPods, full fan | 6 speech + 2 controls; 76 words | 3 (3.95%) | 11 (14.47%) | On speech, Phonon ties Whisper on 3 takes and has more edits on the other 3. It emits text on 1 of the 2 silence controls; Whisper emits none. |

On the same six AirPods/full-fan speech takes, Qwen3-ASR 1.7B 8-bit and Whisper each have 3 edits; Qwen3-ASR 0.6B 8-bit has 6, compared with Phonon's 11. The 1.7B errors do not necessarily occur on the same takes as Whisper's. This does not isolate a Phonon-specific noise weakness. Qwen 1.7B still leads overall at 53/1,166 edits, while Qwen 0.6B scores 86/1,166 (7.38%) with a 3.64 GB sampled process peak. Both Qwen runs emitted text on all six silence controls before any VAD gate. The app's integrated VAD rejected all six controls in the Phonon engine runner, so raw-model control results should not be confused with app-gated behavior.

The result supports the user's choice to ship Phonon as WhisperMax's sole recognizer for its very low warm inference cost and overall tie on this development set. It does not show that Phonon is more accurate in every condition. Do not add duration-based routing from these buckets or claim general accuracy superiority. Inspect the paired medium and AirPods errors for semantic impact before changing the recipe again.

## Earlier evaluation — 2026-10-02

The earlier playback-confirmed v2-only result kept Whisper as default: the tested Phonon paths made more word errors overall and materially more errors on twelve short takes. Phonon performed markedly better on two long takes, which account for 286 of the set's 538 words. Those earlier results were superseded as an integration gate by the larger v2–v4 plus AirPods set and fresh production Whisper rerun on 2026-10-08.

## Historical setup and runtime comparison

The runs used a 16 GB M1 Pro on macOS 27.0. I inspected the signed Detta 1.0.21 bundle and replayed its bundled speech adapter headlessly without signing in. I also reran the public set with `fermion-research` 0.2.6 using canonical 16 kHz mono files. That standalone runtime comparison predates the current native app prototype. At that point, the hotkey-to-insertion path had not been tested; current prototype validation is tracked below.

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

The production Phonon path uses VAD only as a post-stop speech gate, then passes the original recording to Phonon. It does not crop speech or choose the recognizer's long-audio windows. If VAD is unavailable, the app reports an error instead of sending unchecked audio to the recognizer. The corpus has only six silence controls, so this is an initial false-positive check, not a reliable rate estimate. VAD does not perform live endpointing; the hotkey defines the recording boundary.

## Integration acceptance

The branch is `feat/phonon-asr`; XcodeGen pins `phonon-coreml` 1.1.2 and macOS 15. The app bundle contains no Whisper or Qwen recognition backend. It keeps the Whisper framework only for Silero VAD, and keeps the Whisper engine in the offline comparison harness. No rollback setting is exposed to users.

The model download and eight-file verification were completed previously. A controlled TTS phrase reached TextEdit through the hotkey path; one cold attempt took several seconds after stop, while a warm repeat felt immediate. Those are a few smoke checks, not broad acceptance. The patched installed-model onboarding and simulated backup restoration have passed. Still exercise a fresh download through preparation and retry after a forced preparation failure, installed-model relaunch without network access, silence rejection, Cancel-button behavior during inference, microphone switching, clipboard fallback, repeat dictation, and sleep/wake. Measure repeated whole-app stop-to-insert latency and physical footprint with the UI and ANE compiler service reported separately. Keep all personal recordings, references, and derived predictions in Yaplab's ignored private benchmark storage.
