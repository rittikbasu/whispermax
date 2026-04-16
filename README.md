# whispermax

a local-first macos dictation app built because i got annoyed enough to make my own.

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
- transcribes on-device with `whisper.cpp` and `ggml-large-v3-turbo`
- inserts text into the focused app
- falls back to clipboard when insertion cannot be trusted
- keeps a simple local transcript history
- includes a word dictionary for names, product terms, and phrases whispermax tends to miss
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

### download a release

download the latest `whispermax-*.zip` from github releases, unzip it, move `whispermax.app` into `/Applications`, and open it.

because this app is currently **not notarized**, macos may block it on first launch. if that happens:

1. try opening the app once
2. open **system settings → privacy & security**
3. click **open anyway**
4. reopen whispermax

### build from source

#### requirements

- macos 14+
- xcode
- [xcodegen](https://github.com/yonaskolb/XcodeGen)

#### quickstart

1. clone the repo:

   ```bash
   git clone https://github.com/rittikbasu/whispermax.git
   cd whispermax
   ```

2. install the whisper framework:

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

1. speech model setup
2. permissions
3. hotkey setup

if superwhisper is already installed on your mac and its local model is present, whispermax will try to **hardlink** that model instantly instead of making you download the same file again.

## how it works

- the core transcription path is built around `whisper.cpp`
- the local speech model is `ggml-large-v3-turbo.bin`
- transcription runs on-device
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
