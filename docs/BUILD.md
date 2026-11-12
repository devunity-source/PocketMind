# Building and installing PocketMind

## What is and is not possible

An iOS app can only be compiled with Xcode, and Xcode only runs on macOS. It also has to
be code-signed with an Apple ID before an iPhone will run it. There is no way to compile
and install a native iOS app using Windows or Linux alone.

Realistic routes:

| You have | Route |
| --- | --- |
| A Mac | **A** — build and install with Xcode. Simplest. |
| Windows/Linux + a GitHub account | **B** — GitHub Actions builds an unsigned IPA; sign and install it from Windows with Sideloadly or AltStore. |
| A paid Apple Developer account (99 USD/year) | Either route, plus TestFlight and one-year signing instead of seven days. |
| None of the above | A rented cloud Mac (MacinCloud, AWS EC2 Mac, Scaleway) — then route A. |

Requirements for every route: Xcode 26 (the version CI builds with; Xcode 16 may work
but is untested), an iPhone on iOS 18 or later, an Apple ID.

## Dependencies

Resolved automatically by Swift Package Manager on the first build:

| Dependency | Version | How it is pinned |
| --- | --- | --- |
| whisper.cpp | 1.9.5 (build `b5454`) | Official XCFramework release asset, SHA-256 in `Packages/LocalAI/Package.swift` |
| llama.cpp | build `b12317` | Official XCFramework release asset, SHA-256 in `Packages/LocalAI/Package.swift` |
| SQLite (with FTS5), CryptoKit, AVFoundation | system | Part of iOS |
| XcodeGen | any recent | Build tool only (`brew install xcodegen`) |

The app has no other third-party code: no analytics, advertising or crash-reporting SDKs.
(`swift-crypto` is used only when running the core tests on Linux.)

## Route A — Mac with Xcode

1. Clone the repository and generate the project:

   ```bash
   bash scripts/bootstrap.sh
   ```

2. Open `PocketMind.xcodeproj`. Select the **PocketMind** target → *Signing &
   Capabilities* → tick *Automatically manage signing* and choose your team (a free
   personal team works).
3. Change the **Bundle Identifier** to something unique to you, for example
   `com.yourname.pocketmind`. Make the same change in `project.yml`
   (`PRODUCT_BUNDLE_IDENTIFIER`) so it survives regeneration.
4. Connect the iPhone by cable, unlock it, tap *Trust*. On the phone enable
   *Settings → Privacy & Security → Developer Mode* and restart when asked.
5. Choose the iPhone as run destination and press **Run**. (A simulator destination
   fails to link unless Xcode was started with `POCKETMIND_SIMULATOR_BUILD=1` in its
   environment; see LIMITATIONS.md.)
6. First launch with a free Apple ID: on the phone open *Settings → General → VPN &
   Device Management*, tap your Apple ID and trust it. Then open the app.

Apps signed with a free Apple ID stop opening after 7 days; press Run again to renew.
Your data stays on the phone across renewals as long as the bundle identifier is the same
and you do not delete the app.

## Route B — Windows or Linux, via GitHub Actions

1. Create a GitHub repository and push this folder to it.
2. The **CI** workflow (`.github/workflows/ci.yml`) runs on every push: core tests on
   Linux, then on a macOS runner the app build, simulator tests, and an unsigned IPA.
   Private repositories consume paid macOS minutes at a 10× rate; public ones are free.
3. When the run finishes, download the **PocketMind-unsigned-ipa** artifact and unzip it.
4. Sign and install from Windows with one of:
   - **Sideloadly** — connect the iPhone, drop the IPA in, enter your Apple ID. It
     re-signs the app with a free 7-day certificate and installs it.
   - **AltStore** (with AltServer for Windows) — also refreshes the signature over Wi-Fi.

   Both need iTunes/Apple Devices installed for the device drivers, and both send your
   Apple ID credentials to Apple to obtain the signing certificate. Use an app-specific
   or secondary Apple ID if that concerns you. These are third-party tools; this
   project does not ship or vouch for them.
5. On the phone: enable Developer Mode and trust the certificate as in route A, steps 4
   and 6.

The workflow builds twice: once for the simulator to run the tests (without llama.cpp,
whose release framework has no simulator slice) and once for a real device, which is the
build that goes into the IPA and includes both whisper.cpp and llama.cpp.

### TestFlight (paid account)

With a paid developer account you can archive in Xcode (*Product → Archive*) and upload
to App Store Connect, or extend the workflow with signing secrets. That removes the 7-day
limit. Signing in CI is deliberately not preconfigured, so no credentials have to be
stored in the repository.

## After installing

1. Open PocketMind and allow microphone access when you make the first recording.
2. **Settings → AI Models**: download a speech model (Whisper Small is the recommended
   start) and optionally a language model. This is the only step that needs a
   connection; Wi-Fi is required unless you turn that setting off.
3. Optional: assign the Action Button (*iPhone Settings → Action Button → Shortcut →
   PocketMind → Start Recording*).
4. Turn on Airplane Mode and try recording, transcribing, summarising and asking a
   question to confirm for yourself that everything works offline.

## Tests and checks

| Command | Where | What |
| --- | --- | --- |
| `bash scripts/test-core.sh` | macOS, Linux, WSL | 57 core unit tests |
| `bash scripts/check-syntax.sh` | macOS, Linux, WSL | Parses all app sources (syntax only) |
| `bash scripts/test.sh` | macOS | Core tests + app tests on a simulator |
| `bash scripts/build-ipa.sh` | macOS | Unsigned release IPA in `build/` |

### Running the core tests on Windows (WSL)

Install the Swift toolchain for your Ubuntu version from swift.org plus
`libsqlite3-dev pkg-config build-essential`, then:

```bash
POCKETMIND_SCRATCH=~/.cache/pocketmind-build bash scripts/test-core.sh
```

Keeping the build directory on the Linux file system avoids the slow `/mnt/c` mount.

## Things only a device can verify

Check these on the first real install; none of them could be tested during development:

- Recording continues with the screen locked and resumes after a phone call.
- Whisper and llama models load and run with Metal; the two frameworks coexist.
- Transcription speed (run **Benchmark** in Settings → AI Models) and battery use.
- Face ID lock, the app-switcher cover, and the Action Button shortcut.
- Memory use with the largest models (watch for the app being closed by iOS).
