# EchoNotes — Always-On, All-Local AI Note Taker

A native SwiftUI app for iPhone and iPad that does what the Plaud AI note taker does — without the extra hardware. Flip one switch and your device listens, transcribes, and turns conversations into organized notes (title, summary, key points, action items, tags). **Every AI model runs on-device.** No cloud, no account, no audio ever leaves your phone.

- **Transcription:** Apple `SpeechAnalyzer` / `SpeechTranscriber` (iOS 26) — on-device, streaming, unlimited length
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

Two tabs:

- **Record** — one big button. Turn it on and leave it on: the app keeps listening (including with the screen locked or the app in the background), waits for speech, and automatically cuts recordings into sessions when a long silence occurs. Each session becomes a note.
- **Notes** — your library, newest first, grouped by day, searchable. Each note has three views: **Transcript** (timestamped, tap a line to hear that moment), **Summary** (overview, key points, action items, tags — regenerate anytime), and **Audio** (playback with scrubbing).

### What "always on" really means on iOS

iOS allows continuous background microphone recording only while the app is actively capturing audio, and it always shows the orange microphone indicator. Phone calls, Siri, and other exclusive audio apps interrupt recording; EchoNotes resumes automatically as soon as the system allows. Force-quitting the app (or rebooting) stops recording until you reopen the app — that's a platform rule, not a bug. In-flight sessions are recovered on next launch.

## Privacy

Everything — audio, transcripts, summaries — is processed and stored on your device. The app makes no network requests. Airplane mode is a fine way to verify.
