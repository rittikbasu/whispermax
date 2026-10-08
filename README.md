# whispermax

a local-first macos dictation app built because i got annoyed enough to make my own.

<p>
  <a href="https://github.com/rittikbasu/whispermax/releases/latest/download/whispermax-macos.dmg">
    <img alt="download whispermax for macos" src="docs/assets/download-macos.svg">
  </a>
</p>

## why i built it

i type a lot.

for a while, people around me kept telling me to try apps like superwhisper or wispr flow instead of doing everything with my keyboard. so i did.

i ended up using superwhisper with its local `ultra v3 turbo` model and honestly the experience was great at first. it was fast, the transcription quality was good, and it felt like i could get used to this.

then after using it a bit more, i hit a paywall.

that really pissed me off because i was not using some expensive cloud model. i was using a local model on my own machine. after digging into it, that “special” model turned out to basically be whisper large v3 turbo.

so i built my own version.

whispermax is my attempt at the sharper version of this product:

- one really good local transcription path
- no subscription
- no cloud dependency in the core workflow
- no weird mode soup
- no unnecessary ai fluff
- just press a shortcut, talk, and get text back

## what it does

- records locally on macos with a global hotkey
- transcribes on-device with Phonon-2 on Apple's Neural Engine
- inserts text into the focused app
- falls back to clipboard when insertion cannot be trusted
- keeps a simple local transcript history
- includes a local dictionary that preserves preferred capitalization for recognized terms
- stays lightweight and focused instead of trying to be an everything app

## why whispermax exists

most dictation apps are trying to become giant ai workspaces.

i did not want that.

i wanted something that feels like a native mac utility:

- fast to start
- calm ui
- private by default
- reliable enough to use every day

that is the whole point of this app.

## install

download the latest dmg, open it, drag `whispermax.app` into `Applications`, and open it.

the zip is still available on the release page for updates and fallback installs.

because this app is currently **not notarized**, macos may block it on first launch. if that happens:

1. try opening the app once
2. open **system settings → privacy & security**
3. click **open anyway**
4. reopen whispermax

### build from source

#### requirements

- macos 15+ on Apple silicon
- xcode
- [xcodegen](https://github.com/yonaskolb/XcodeGen)

#### quickstart

1. clone the repo:

   ```bash
   git clone https://github.com/rittikbasu/whispermax.git
   cd whispermax
   ```

2. install the audio and speech activity framework:

   ```bash
   ./Scripts/install-whisper-framework.sh
   ```

3. generate the xcode project:

   ```bash
   xcodegen generate
   ```

4. open the project in xcode and run it, or use the local dev script:

   ```bash
   ./Scripts/build-debug.sh
   ```

the dev script installs the latest debug build into `~/Applications/whispermax.app`.

## first run

on first launch, whispermax walks you through three things:

1. download and prepare the 345 MB Phonon-2 model
2. permissions
3. hotkey setup

The model is stored locally in Application Support. First launch may take a little longer while Core ML prepares it for your Mac.

## how it works

- Phonon-2 Core ML performs local speech recognition using the Neural Engine
- Silero VAD rejects recordings without speech before recognition
- the audio and transcript stay on your Mac
- insertion tries the most reliable path for the current app surface
- browser-family apps use a paste-first path
- native text fields use a stricter direct insertion path when possible
- when whispermax cannot confidently insert text, it falls back to **copied to clipboard** instead of pretending it pasted successfully

## privacy

whispermax is designed to keep the core workflow local:

- audio is recorded locally
- transcription is local
- word dictionary is local
- transcript history is local

the core product does **not** depend on a subscription or a cloud api.

## current state

this is an early public release.

it is already usable, but there are still rough edges i want to keep improving, especially around:

- cross-app insertion edge cases
- release/distribution polish
- automatic updates

## contributing

open a pr if you want.

bug fixes, insertion reliability improvements, performance work, ui polish, and better local-first workflows are all welcome.
