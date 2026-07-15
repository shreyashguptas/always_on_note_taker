# EchoNotes — Always-On, All-Local AI Note Taker

A native SwiftUI app for iPhone and iPad that does what the Plaud AI note taker does — without the extra hardware. Flip one switch and your device listens, transcribes, and turns conversations into organized notes (title, summary, key points, action items, tags). **Every AI model runs on-device.** No cloud, no account, no audio or transcript ever leaves your phone; the network is used only for one-time model downloads.

- **Live transcription:** Apple `SpeechAnalyzer` / `SpeechTranscriber` (iOS 26) — on-device, streaming, powers the live view while you record
- **Multilingual transcription:** after each session, an on-device Whisper model ([WhisperKit](https://github.com/argmaxinc/WhisperKit), Core ML) re-transcribes the audio with automatic language detection — Hindi, Spanish, English, German, French, Italian and ~95 more, including conversations that switch languages mid-stream
- **Speaker recognition:** on-device diarization + voiceprints ([FluidAudio](https://github.com/FluidInference/FluidAudio), Core ML) tell voices apart; name a voice once in the People tab and it's tagged automatically in every future transcript
- **Note generation:** Apple Foundation Models framework (the on-device Apple Intelligence LLM), with a NaturalLanguage-framework fallback when Apple Intelligence is unavailable
- **Storage:** SwiftData + per-session `.m4a` audio files, all local

## Requirements

- **Xcode 26** on macOS
- An iPhone or iPad running **iOS 26 or later**
- For AI-generated summaries: an **Apple Intelligence-capable device** (iPhone 15 Pro or newer, or an M-series iPad) with Apple Intelligence enabled in Settings. On other devices the app still records and transcribes, and uses a simpler on-device extractive summarizer.

## Building

The Xcode project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) (the `.xcodeproj` is not committed):

```sh
brew install xcodegen   # once
xcodegen generate       # at the repo root
open EchoNotes.xcodeproj
```

Then in Xcode:

1. Select the **EchoNotes** target → Signing & Capabilities → pick your **Team** (automatic signing).
2. Select your device and Run.
3. On first launch, allow **microphone** access and let the on-device speech model finish downloading (a banner in the Record tab shows progress).

## Using the app

Three tabs:

- **Record** — one big button. Turn it on and leave it on: the app keeps listening (including with the screen locked or the app in the background), waits for speech, and automatically cuts recordings into sessions when a long silence occurs. Each session becomes a note. The gear icon opens Settings, where you download the optional multilingual + speaker models (one-time; the "Best" Whisper model is ~626 MB).
- **Notes** — your library, newest first, grouped by day, searchable. Each note has three views: **Transcript** (timestamped, speaker-labeled, language-badged; tap a line to hear that moment), **Summary** (overview, key points, action items with owners' names, tags — regenerate anytime), and **Audio** (playback with scrubbing).
- **People** — when a recording is processed, each new voice becomes a review card: play a ten-second sample and name the person (or tap "Me"). Named voices are recognized automatically from then on; you can rename, merge, or remove people anytime.

### How transcription works

While you record, the live view uses Apple's streaming transcriber in your device language. When a session ends, the recording is re-processed on-device: Whisper detects languages as the conversation moves between them, the diarizer works out who spoke when, and the transcript is replaced with the accurate multilingual, speaker-tagged version (a ~10-minute recording takes a couple of minutes; long ones proportionally more, paused automatically if the phone runs hot). If the models aren't downloaded, the app behaves like v1 — live transcript only.

### What "always on" really means on iOS

iOS allows continuous background microphone recording only while the app is actively capturing audio, and it always shows the orange microphone indicator. Phone calls, Siri, and other exclusive audio apps interrupt recording; EchoNotes resumes automatically as soon as the system allows. Force-quitting the app (or rebooting) stops recording until you reopen the app — that's a platform rule, not a bug. In-flight sessions are recovered on next launch.

## Known limitations (v1)

- **Playing a note while recording is on**: playback comes out of the speaker while the mic keeps capturing, so the recording (and its transcript) will pick up the played audio. Pause listening if you don't want that.
- **Toggling recording on/off while a note is playing** reconfigures the shared audio session and may stop the playback.
- UI strings and duration formatting are English-only (transcription handles ~100 languages once the multilingual model is installed; the live view follows your device language when supported).
- **Language detection granularity:** Whisper detects one language per ~30-second stretch, so a mid-sentence switch ("Hinglish") is transcribed in whichever language dominates that stretch.
- **The live transcript is preliminary** when the multilingual models are installed — it's replaced by the accurate version shortly after each session ends.

## Privacy

Everything — audio, transcripts, voiceprints, summaries — is processed and stored on your device. The app's only network use is downloading AI models once (Apple's speech model, and the optional Whisper + speaker models from Hugging Face). After that, airplane mode is a fine way to verify nothing leaves the device.
