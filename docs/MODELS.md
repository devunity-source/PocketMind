# AI models

PocketMind ships without models. You install them once from inside the app
(**Settings → AI Models**); after that the app works with Airplane Mode on.

A model download is an *initial download*, not cloud processing: the file is fetched,
verified and stored, and all inference then runs on the iPhone.

## Speech to text (whisper.cpp, multilingual)

| Model | Download | Working memory (approx.) | Use it when |
| --- | --- | --- | --- |
| Whisper Base | 148 MB | ~0.4 GB | You want the fastest result and record clear English |
| Whisper Small (q5_1) — **recommended** | 190 MB | ~0.65 GB | General use across English, Arabic, Ukrainian, Dutch, French |
| Whisper Large v3 Turbo (q5_0) | 574 MB | ~1.7 GB | Accuracy matters most, especially Arabic and Ukrainian |

All are multilingual; English-only (`.en`) models are deliberately not offered. Language
is detected from the first 30 seconds, or you can fix it in Settings or per recording.

## Language model (llama.cpp, optional)

| Model | Download | Working memory (approx.) | Licence |
| --- | --- | --- | --- |
| Qwen 2.5 1.5B Instruct Q4_K_M | 1.12 GB | ~1.8 GB | Apache-2.0 |
| Llama 3.2 3B Instruct Q4_K_M — **recommended on 8 GB** | 2.02 GB | ~3.0 GB | Llama 3.2 Community License |
| Phi-4 mini Instruct Q4_K_M | 2.49 GB | ~3.6 GB | MIT |

Without a language model the app still works: summaries become sentences quoted from the
transcript (labelled as such) and Memory lists matching passages instead of writing an
answer.

Working-memory figures are estimates used for the compatibility check, not measurements.
iOS gives an app roughly half of the device's RAM; a model whose estimate exceeds that is
blocked, and one close to it carries a warning. The app never keeps a speech model and a
language model loaded at the same time, and unloads both when the queue is empty or iOS
reports memory pressure.

## Integrity

Each catalog entry (`Packages/PocketMindCore/Sources/PocketMindCore/ModelCatalog.swift`)
pins the download URL to an exact repository revision and carries the file's SHA-256,
taken from the Hugging Face file metadata when this project was written:

| File | SHA-256 |
| --- | --- |
| `ggml-base.bin` | `60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe` |
| `ggml-small-q5_1.bin` | `ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb` |
| `ggml-large-v3-turbo-q5_0.bin` | `394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2` |
| `qwen2.5-1.5b-instruct-q4_k_m.gguf` | `6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e` |
| `Llama-3.2-3B-Instruct-Q4_K_M.gguf` | `6c1a2b41161032677be168d354123594c0e6e67d2b9227c84f296ad037c728ff` |
| `microsoft_Phi-4-mini-instruct-Q4_K_M.gguf` | `01999f17c39cc3074afae5e9c539bc82d45f2dd7faa3917c66cbef76fce8c0c2` |

A downloaded file is hashed on the device and installed only if it matches; otherwise it
is deleted. The model files themselves were not downloaded or run while writing this
project, so "this model loads with the pinned llama.cpp build" is an expectation, not a
tested fact.

## Benchmarks

There are no benchmark numbers in this repository, because none could be measured: the
app has not yet run on an iPhone. Published figures from other devices would not be
honest estimates for yours.

Instead the app measures on your device:

- **Settings → AI Models → Benchmark** on a speech model transcribes the first 30 seconds
  of one of your recordings and stores the real-time factor (processing seconds per
  second of audio). Run it for at least two models to compare speed against accuracy.
- The same button on a language model generates a fixed short text and stores tokens per
  second.
- Every real transcription updates the stored figure.

Time estimates shown in the app ("about 4 min") come only from these measurements; until
one exists, the app says "Not measured yet".

Things that are known from how the libraries work: speed scales roughly with model size;
Metal acceleration is used in the foreground only (iOS forbids GPU work in the
background, where the app falls back to much slower CPU inference); long recordings are
processed in 5-minute windows so memory use does not grow with recording length.

## Adding or changing a model

Add a `ModelDescriptor` to `ModelCatalog` with a revision-pinned `/resolve/<commit>/` URL,
the exact byte size and the SHA-256. The catalog tests enforce HTTPS, the host allow-list,
revision pinning and checksum format. Whisper models must be `ggml` multilingual files;
language models must be GGUF chat models whose template llama.cpp recognises (others fall
back to ChatML formatting).
