# PocketMind

A private, offline AI memory assistant for iPhone. It records conversations, transcribes
them on the device with whisper.cpp, summarises them and extracts action items with a
local language model (llama.cpp), and answers questions about past recordings with
citations back to the exact recording and timestamp.

No account, no cloud, no analytics. The only network traffic the app can produce is the
one-time model download you start yourself.

## Status — read this first

| Part | State |
| --- | --- |
| `PocketMindCore` (database, FTS5 search, RAG, summarisation logic, encryption, parsing, export) | **Compiled and tested**: 57 unit tests pass on Linux and macOS in CI. |
| App and `LocalAI` bridges (SwiftUI, AVFoundation, whisper.cpp, llama.cpp) | **Compiles and links** in CI with Xcode 26.6, for the simulator and for a real device; CI produces an unsigned IPA with both frameworks embedded. |
| App tests on the iOS simulator | **13 pass, 1 skipped** (the Keychain test needs a signed host): vault encryption, audio decoding, recorder lifecycle, interruptions, model manager. |
| Running on an iPhone: the interface, real transcription and summaries, speed, battery | **Not verified.** Nobody has launched the app yet. The whisper.cpp and llama.cpp bridges compile against the real headers but have never run with a model. |

"The build is green" means the code compiles and the logic that can be tested without a
phone works. It does not yet mean the app behaves correctly on a device. See
[docs/LIMITATIONS.md](docs/LIMITATIONS.md).

## Features

- **Recording**: one tap or the Action Button, pause/resume, timer, live waveform,
  background recording, Bluetooth microphones, three AAC quality levels, titles, tags,
  import of existing audio files, recovery of captures after interruptions.
- **Transcription**: whisper.cpp, fully offline, automatic language detection, tuned for
  English, Arabic, Ukrainian, Dutch and French, timestamped segments, manual correction,
  progress, cancel and retry, TXT and Markdown export.
- **Summaries**: overview, key points, decisions, action items, deadlines, facts and
  follow-up questions as structured output (grammar-constrained JSON), custom templates,
  multi-pass summarisation for long recordings, and a grounding filter that drops items
  the transcript does not support. Without a language model, a clearly labelled
  extractive fallback quotes sentences from the transcript.
- **Memory**: ask questions in plain language; answers are generated only from retrieved
  transcript passages and cite recording + timestamp. With nothing retrieved, the model
  is not consulted at all.
- **Tasks**: extracted action items with resolved due dates, linked to the moment they
  were said; manual tasks.
- **Library**: search across titles and transcript text, filters (type, date, language,
  tag, folder, favourites), playback with timestamp navigation, trash and restore.
- **Speakers**: manual speaker labels per transcript line (no automatic diarization).
- **Security**: AES-256-GCM encrypted audio, key in the Keychain (this device only),
  iOS Data Protection, Face ID app lock, app-switcher privacy cover, backup exclusion,
  retention rules, secure deletion, and a privacy dashboard with a network activity log.

## Repository layout

```
project.yml                  XcodeGen definition (generates PocketMind.xcodeproj)
App/                         SwiftUI app: Services/, UI/, Support/, Resources/
AppTests/                    XCTest suite that runs on the iOS simulator
Packages/PocketMindCore/     Platform-independent logic + 57 unit tests
Packages/LocalAI/            whisper.cpp / llama.cpp wrappers (pinned XCFrameworks)
scripts/                     bootstrap, test, test-core, build-ipa, check-syntax
.github/workflows/ci.yml     Linux core tests + macOS build, tests, unsigned IPA
docs/                        BUILD, SECURITY, MODELS, LIMITATIONS
```

## Quick start

On a Mac with Xcode 16 or newer:

```bash
bash scripts/bootstrap.sh
```

```bash
open PocketMind.xcodeproj
```

Select your team under *Signing & Capabilities*, change the bundle identifier to one you
own, choose your iPhone and press Run. Then, in the app: **Settings → AI Models** and
download one speech model (start with *Whisper Small*) and, optionally, one language
model.

No Mac? Push the repository to GitHub; the included workflow builds an unsigned IPA on
a macOS runner, which you can sign and install from Windows. Full instructions for both
routes are in [docs/BUILD.md](docs/BUILD.md).

## Tests

```bash
bash scripts/test-core.sh
```

runs the core tests anywhere Swift runs (macOS, Linux, WSL).

```bash
bash scripts/test.sh
```

runs everything, including the app tests on a simulator (macOS only).

What the tests cover: recording library and filters, transcript persistence, search
accuracy in all five languages, FTS query injection safety, trash/restore/permanent
deletion (including that deleted text is gone from the database files), retention,
encryption round trips and tamper/truncation detection, checksum verification,
structured-output parsing and repair, grounding, due-date parsing, single- and multi-pass
summarisation, a three-hour transcript, RAG answers with citations, the no-evidence path,
model catalog pinning and compatibility rules, export formats, crash-recovery journals,
and a repository-wide audit that networking APIs exist only in the model downloader.
App tests add vault behaviour, audio decoding, the recorder lifecycle, interruptions and
permission/storage checks.

## Documentation

- [docs/BUILD.md](docs/BUILD.md) — building, signing, installing on a physical iPhone, CI
- [docs/MODELS.md](docs/MODELS.md) — models, sizes, checksums, benchmarking
- [docs/SECURITY.md](docs/SECURITY.md) — security architecture and threat model
- [docs/LIMITATIONS.md](docs/LIMITATIONS.md) — known limitations and future work

## A note on recording other people

Record only with the knowledge and consent of the people being recorded. Recording laws
differ between countries and regions. PocketMind never records silently: it must be on
screen to start, and iOS shows its microphone indicator for as long as it records.
