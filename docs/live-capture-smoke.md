# Debug live-capture smoke

The DEBUG-only seam calls production `toggleRecording()`/`cancelRecording()` and the real mic, VAD, Phonon-2, and insertion path. Generic TTS checks plumbing, not recognition quality.

## Preconditions
- Use a signed Debug bundle (`com.whispermax.app`); quit Release first and keep a verified Release backup outside `/Applications`.
- Phonon-2 and existing Microphone/Direct Insert grants are required; stop on permission prompts. The opt-in suppresses Debug's global hotkey.

## Opt in
```sh
set -eu
DOMAIN=com.whispermax.app; KEY=WhisperMaxDebugLiveCaptureSmokeDirectory
if defaults read "$DOMAIN" "$KEY" >/dev/null 2>&1; then echo 'opt-in key exists; stop'; exit 1; fi
RUN_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"; CONTROL_DIR="/private/tmp/whispermax-live-capture-$RUN_ID"
umask 077; mkdir -m 700 "$CONTROL_DIR"; defaults write "$DOMAIN" "$KEY" -string "$CONTROL_DIR"
```
Use a fresh UUID directory with neither `command.json` nor `state.json`. Launch only Debug; startup consumes the key. Require owner-only `state.json` with matching `runID`; if absent, stop without commands.

## Control and target gate
Write mode-0600 commands through a temporary file and atomic rename:
```sh
write_command(){ printf '{"runID":"%s","sequence":%s,"action":"%s"}' "$RUN_ID" "$1" "$2" > "$CONTROL_DIR/command.tmp"; chmod 600 "$CONTROL_DIR/command.tmp"; mv -f "$CONTROL_DIR/command.tmp" "$CONTROL_DIR/command.json"; }
```
Schema: `{"runID":"<lowercase UUID>","sequence":1,"action":"start"}`. Actions are `start`, `stop`, `cancel`; increment sequence each time. State includes `runID`, `commandSequence`, `commandStatus`, `phase`, optional `insertionMethod`, `issue`, `capturedInsertionTargetBundleIdentifier`, `frontmostBundleIdentifier`; phases include `loadingModel`, `ready`, `starting`, `recording`, `transcribing`, `inserted`, `error`.
Open a blank TextEdit scratch via Finder/Launch Services. Send start only at `ready` with frontmost `com.apple.TextEdit`; play audio only after `recording` captures that target. Otherwise cancel and play nothing. After stop, wait for `inserted`/`error`; cancel is the no-audio path and should leave scratch unchanged.

## Cleanup
Quit Debug via its normal app menu; confirm it exited, remove the remaining opt-in key and only known control files, then `rmdir` the UUID directory. Move Debug out of `/Applications`, restore the verified Release backup to `/Applications/whispermax.app`, verify signature/readiness, and leave other app copies and user data untouched.
