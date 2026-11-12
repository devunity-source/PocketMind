# Security architecture and threat model

PocketMind's goal is that recordings, transcripts and everything derived from them stay
on one iPhone and are unreadable without that iPhone being unlocked by its owner. This
document says how that is implemented and, just as importantly, where it stops.

## Design rules

1. **No server.** There is no backend, account, sync, analytics, advertising, telemetry
   or crash-reporting SDK. Nothing to breach, subpoena or misconfigure.
2. **One network path.** The only networking code is the model downloader
   (`App/Services/ModelManager.swift`). A unit test scans the whole repository and fails
   if a networking API or URL appears anywhere else.
3. **Inference is local.** Speech recognition and text generation run in-process through
   whisper.cpp and llama.cpp. No audio or text is sent to any API.
4. **Least privilege.** Permissions: microphone (required), Face ID and notifications
   (optional). No contacts, calendar, location, photos, speech-recognition service or
   local-network access. File sharing through Finder/iTunes is not enabled.

## Data at rest

| Data | Where | Protection |
| --- | --- | --- |
| Audio | `Application Support/PocketMind/audio/*.pmenc` | AES-256-GCM (app level) **and** iOS Data Protection class *Complete* |
| Transcripts, summaries, tasks, search index, network log | `…/db/pocketmind.sqlite` (+ WAL) | iOS Data Protection class *Complete*; `secure_delete` on |
| Audio being recorded | `…/capture/*.m4a` | Data Protection class *Complete unless open* (plaintext AAC until the recording is stopped, then encrypted and removed) |
| Temporary decrypted audio, exports | `…/scratch/` | Class *Complete*; deleted right after use and wiped at every launch |
| Vault key (256-bit) | Keychain | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, not synchronised |
| Preferences | UserDefaults | Not sensitive (toggles and model choices only) |
| AI models | `…/models/` | Public files; verified by SHA-256 |

**Audio encryption format** (`FileCipher`): 1 MiB chunks, each sealed with AES-256-GCM.
The nonce is an 8-byte random per-file prefix plus a 32-bit chunk counter; the counter and
a "final chunk" flag are authenticated, so modified, reordered, dropped or truncated
chunks are detected. Implemented with CryptoKit; no custom primitives.

**Why the database is not encrypted at the app level.** Full-text search needs an index
of the transcript words. Encrypting that index without replacing the system SQLite
(e.g. with SQLCipher) is not possible, so the database relies on iOS Data Protection:
its file key is discarded by the Secure Enclave shortly after the phone locks, and comes
back only with the passcode or biometrics. This is strong protection — but only if the
phone has a passcode. The app warns when it does not. SQLCipher is listed as future work.

**Backups.** The whole vault directory is excluded from iCloud and computer backups, and
the key is device-only. Consequence: PocketMind data is *not* restored when you move to a
new phone. Export what you need to keep.

## Access control

- **App lock**: Face ID / Touch ID with passcode fallback (`LocalAuthentication`), on by
  default, engaged every time the app leaves the screen.
- **Privacy cover**: an opaque screen replaces the interface whenever the app is not
  active, so the app-switcher snapshot shows nothing.
- **Notifications** contain no titles or transcript text.

The app lock is an interface gate against someone holding the unlocked phone. It is not
a cryptographic boundary: the vault key is released by iOS when the device is unlocked,
not by the app lock.

## Deletion

- *Delete* moves a recording to Recently Deleted (kept 7/30/90 days, configurable).
- *Permanent deletion* removes the database rows, runs an FTS5 `optimize` so the words
  leave the search index, `VACUUM`s and truncates the write-ahead log, and deletes the
  encrypted audio file. A test asserts that the deleted text no longer appears in the
  database files.
- *Retention*: optional automatic deletion after 30/90/365 days (favourites excepted).
- *Erase all data* additionally destroys the vault key and creates a new one, so any
  surviving copy of old ciphertext is undecryptable.

Flash storage cannot be reliably overwritten in place. Deletion here means: the data is
removed from the files, and iOS discards the per-file encryption keys of deleted files.
It is not a forensic-grade guarantee against an attacker with raw access to the storage
chip *and* the device keys.

## Model downloads

- Started only by an explicit tap, after a dialog stating file size, host and licence.
- HTTPS only, to `huggingface.co` and the `*.huggingface.co` / `*.hf.co` hosts it
  redirects to; redirects elsewhere are refused.
- Ephemeral session: no cookies, cache or credential storage. The request carries no
  identifier beyond a fixed `User-Agent: PocketMind`. The host still sees your IP address.
- URLs are pinned to a repository revision; the file is usable only if its SHA-256
  matches the value compiled into the app, otherwise it is deleted.
- Every request and redirect is written to the on-device network log shown in
  *Settings → Privacy & Security*.

## Threat model

| Threat | Mitigation | Residual risk |
| --- | --- | --- |
| **Lost or stolen iPhone (locked)** | Data Protection *Complete* on database and audio; audio additionally AES-GCM with a Keychain key that is unavailable while locked; nothing in backups or iCloud. | Depends on passcode strength. A capture that was in progress when the phone locked stays readable by the OS until it is sealed. No protection if the phone has no passcode. |
| **Unauthorized physical access (unlocked phone, e.g. a colleague or partner)** | App lock on every return to the app; privacy cover in the app switcher; generic notifications. | Someone who knows the device passcode can pass the app lock, since passcode fallback is allowed. |
| **Device backups** | Vault excluded from all backups; key is `ThisDeviceOnly`. | None for backups — at the cost of no automatic restore. Files you *export* are outside this protection. |
| **Compromised device (jailbreak, spyware, forensic tooling on an unlocked device)** | Sandboxing and encryption raise the cost. | **Not defended.** Code running with elevated privileges on an unlocked device can read the Keychain item, the database and the microphone. Encryption does not protect data from a compromised operating system. |
| **Malicious or vulnerable dependencies** | Two native dependencies only, both pinned to exact release builds with checksums; no SDKs with network behaviour; network-API audit test; model files are parsed only after checksum verification. | whisper.cpp/llama.cpp are large C/C++ code bases consumed as prebuilt binaries that were not audited here. A flaw in them could be triggered by a crafted audio or model file. The App Sandbox limits the blast radius; building the frameworks from source would reduce supply-chain risk further. |
| **Accidental sharing** | Every export shows a warning that the file leaves encryption; exported temp files are deleted after the share sheet closes; no share extensions or automatic exports. | Once shared, a copy is out of the app's control. |
| **Sensitive information in logs** | The app does not log transcript, title or prompt content; native library logging is disabled; no crash reporter. | iOS's own diagnostics (if the user shares analytics with Apple) can include crash stack traces, not content. |
| **Recording people without consent** | App must be on screen to start; iOS microphone indicator is always visible; no hidden or scheduled recording. | A legal/ethical matter the software cannot enforce. |
| **Prompt injection through spoken content** | The model has no tools and no network; its output is only displayed. Retrieved text is delimited as sources. | A recording could contain text that skews a summary or answer. Sources are always shown so answers can be checked. |

## What was and was not verified

Verified by tests that ran: the encryption format (round trips, tampering, truncation,
reordering, wrong key), secure deletion from the database files, backup-independent
logic, the allow-list for download hosts, and the network-API audit.

Not verified (needs a device): Data Protection classes actually applied by iOS, Keychain
accessibility behaviour, the app-switcher cover, Face ID flow, and that no plaintext
audio outlives a recording in all interruption paths. No external security review or
penetration test has been done. Treat this as a careful design, not a certified product.
