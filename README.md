# EchoNotes — Always-On, All-Local AI Note Taker

A native SwiftUI app for iPhone and iPad that does what the Plaud AI note taker does — without the extra hardware. Flip one switch and your device listens, transcribes, and turns conversations into organized notes (title, summary, key points, action items, tags). **Every AI model runs on-device.** No cloud, no account, no audio or transcript ever leaves your phone; the network is used only for one-time model downloads.

- **Transcription:** an on-device Whisper model ([WhisperKit](https://github.com/argmaxinc/WhisperKit), Core ML) transcribes each session right after it ends, detecting the language automatically — Hindi, Spanish, English, German, French, Italian and ~95 more, including conversations that switch languages mid-stream
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
3. On first launch, allow **microphone** access and download the on-device transcription models (the Record tab's banner or the gear icon takes you there; recordings made before the download are transcribed once it finishes).

## Using the app

Three tabs:

- **Record** — one big button. Turn it on and leave it on: the app keeps listening (including with the screen locked or the app in the background), waits for speech, and automatically cuts recordings into sessions when a long silence occurs. Each session becomes a note; while one is being transcribed, a progress card shows on this screen. The gear icon opens Settings, where you download the transcription + speaker models (one-time; the "Best" Whisper model is ~626 MB).
- **Notes** — your library, newest first, grouped by day, searchable. Each note has three views: **Transcript** (timestamped, speaker-labeled, language-badged; tap a line to hear that moment), **Summary** (overview, key points, action items with owners' names, tags — regenerate anytime), and **Audio** (playback with scrubbing).
- **People** — when a recording is processed, each new voice becomes a review card: play a ten-second sample and name the person (or tap "Me"). Named voices are recognized automatically from then on; you can rename, merge, or remove people anytime.

### How transcription works

Recording is just capture — nothing is transcribed while the mic is hot, which keeps all-day listening cheap on battery. The moment a session ends, it's processed entirely on-device: Whisper transcribes the audio, detecting languages as the conversation moves between them, and the diarizer works out who spoke when; the finished transcript is multilingual and speaker-tagged (a ~10-minute recording takes a couple of minutes; long ones proportionally more, paused automatically if the phone runs hot). If the models aren't downloaded yet, recordings are kept and transcribed automatically once they are.

### What "always on" really means on iOS

iOS allows continuous background microphone recording only while the app is actively capturing audio, and it always shows the orange microphone indicator. Phone calls, Siri, and other exclusive audio apps interrupt recording; EchoNotes resumes automatically as soon as the system allows. Force-quitting the app (or rebooting) stops recording until you reopen the app — that's a platform rule, not a bug. In-flight sessions are recovered on next launch.

## Known limitations (v1)

- **Playing a note while recording is on**: playback comes out of the speaker while the mic keeps capturing, so the recording (and its transcript) will pick up the played audio. Pause listening if you don't want that.
- **Toggling recording on/off while a note is playing** reconfigures the shared audio session and may stop the playback.
- UI strings and duration formatting are English-only (transcription itself handles ~100 languages).
- **No live transcript while recording** — by design: transcription runs right after each session ends, so the accurate multilingual version is the only one you ever see, and all-day listening stays battery-friendly.
- **Language detection granularity:** Whisper detects one language per ~30-second stretch, so a mid-sentence switch ("Hinglish") is transcribed in whichever language dominates that stretch.

## Privacy

Everything — audio, transcripts, voiceprints, summaries — is processed and stored on your device. The app's only network use is downloading the Whisper + speaker models once (from Hugging Face). After that, airplane mode is a fine way to verify nothing leaves the device.
