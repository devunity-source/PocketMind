# Known limitations and future improvements

## Verification gaps (most important)

- **The app has never been compiled.** It was written on Windows. `PocketMindCore` is
  compiled and tested (57 tests); the SwiftUI app, the whisper/llama bridges and the app
  tests have only passed a syntax check. Expect compile errors on the first Xcode or CI
  build — most likely in SwiftUI view code, concurrency annotations, and the C interop in
  `Packages/LocalAI`. The bridges were written against the actual `whisper.h`/`llama.h`
  of the pinned releases, but never built against them.
- **Nothing has run on a device.** Recording in the background, Metal inference, memory
  behaviour with large models, Face ID, the Action Button intent and battery use are all
  untested.
- **whisper.cpp and llama.cpp in one app.** Both XCFrameworks embed their own copy of
  ggml. They are dynamic frameworks, which should keep their symbols apart, but this
  combination was not run. If it misbehaves, the fix is one combined framework built from
  source, or matching ggml versions.
- **CI workflow** has never executed. The runner image must provide Xcode 16+.
- **Model quality.** No model was downloaded or evaluated. Small quantised models make
  mistakes; summaries of Arabic and Ukrainian recordings will be weaker than English.

## Functional limitations

- **No automatic speaker diarization.** Whisper does not identify speakers. The app
  provides speaker labels, renaming and per-line assignment by hand. A practical offline
  route for later is a small speaker-embedding model plus clustering.
- **Interrupted recordings.** A recording stopped normally, by an interruption or by
  closing the app is saved. If the app is killed outright (crash, power loss), the
  unfinished `.m4a` usually cannot be read and is discarded with a notice. Writing
  fragmented MP4 with `AVAssetWriter` would make captures crash-safe.
- **Plaintext during capture.** Audio is encrypted when the recording stops, not while it
  is being written. Until then it is protected by iOS Data Protection only.
- **Background processing is limited by iOS.** GPU inference is not allowed in the
  background, and the database is unreadable while the phone is locked. In practice,
  transcription runs while the app is open (the screen is kept on); work interrupted by
  leaving the app resumes from the last completed 5-minute window when you return. The
  scheduled background task (on charger, CPU only) is best-effort.
- **Phone calls.** iOS does not let apps record cellular or VoIP calls. "Call" recordings
  mean a call on speaker, picked up by the microphone, with everyone's consent.
- **Retrieval is lexical.** Memory search uses FTS5 keyword matching with light English
  stemming. It will miss paraphrases ("budget" vs "spending") and has no stemming for the
  other languages. Local embeddings with vector similarity are the planned improvement.
- **Question understanding is English-centric.** Date phrases ("last week") and intents
  ("tasks", "deadlines") are recognised in English. Questions in other languages still
  search by keyword.
- **Due dates** are resolved from English phrases only; others keep their original wording
  without a calendar date.
- **Grounding check is lexical.** It removes items with no word overlap with the
  transcript; it cannot catch a wrong statement built from words that do occur, and it is
  skipped when the summary is in a different language from the recording.
- **Database encryption** relies on iOS Data Protection rather than app-level encryption
  (see SECURITY.md). SQLCipher would add defence in depth.
- **No backup or device transfer.** By design nothing is backed up. There is no encrypted
  export/import of the whole library yet.
- **Memory chat is not saved** between launches, and there is no multi-turn context: each
  question is answered on its own.
- **No Live Activity / lock-screen controls** for a running recording (the mock-up shows
  one); that needs a widget extension. The system microphone indicator is shown.
- **iPhone only**, portrait only, English interface. No iPad layout, widgets or Watch app.

## Future improvements, roughly in priority order

1. First macOS build; fix compile errors; run the app test suite on a simulator.
2. On-device validation and real benchmarks on iPhone 17 for at least two Whisper and two
   language-model configurations; tune context size and thread counts from measurements.
3. Crash-safe recording with fragmented MP4 and encryption during capture.
4. Local embeddings + hybrid (lexical + vector) retrieval.
5. Offline speaker diarization.
6. Live Activity with stop/pause from the lock screen.
7. SQLCipher, and an encrypted library export for moving to a new phone.
8. Core ML encoder for Whisper (lower battery use), build frameworks from source.
9. Localised interface and multilingual date/intent parsing.
