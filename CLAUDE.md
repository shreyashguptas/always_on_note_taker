# EchoNotes — agent operations guide

Instructions for an AI agent (or a human) working on this repo on a Mac:
how to build, run the tests, install on an iPhone, and execute the
on-device test plan. Read this before touching code.

## What this app is

Always-on, all-local AI note taker for iPhone/iPad. One switch: the app
listens, cuts speech into sessions, transcribes each session **after it
ends** with an on-device Whisper model (automatic language detection —
Hindi, Spanish, English, German, French, Italian and ~95 more, including
mid-conversation switches), tells voices apart with on-device diarization
(name a voice once on the People screen → auto-tagged forever), and generates
notes with Apple's on-device LLM.

**Hard constraint:** every model runs on-device. The ONLY permitted network
use is one-time model downloads (WhisperKit + FluidAudio models from
Hugging Face). Never add telemetry, cloud APIs, or any code path that sends
audio/transcripts anywhere. Airplane mode is the acceptance test.

## Repo map

| Path | What lives there |
|---|---|
| `project.yml` | XcodeGen spec — the `.xcodeproj` is NOT committed; regenerate after editing this |
| `EchoNotes/App/` | `EchoNotesApp` (entry, DI), `RootTabView` (Record / Notes tabs; People opens as a sheet from Notes) |
| `EchoNotes/Models/` | SwiftData `@Model`s: `RecordingSession`, `TranscriptSegment`, `GeneratedNote`, `Speaker`, `SpeakerReviewItem` — schema assembled in `Support/Persistence.swift`; keep changes additive (lightweight migration only) |
| `EchoNotes/Services/` | The pipeline. Capture: `AudioCaptureService` → `SessionPipeline` (VAD, pre-roll, per-session `.m4a`). Post-session: `TranscriptEnrichmentService` (WhisperKit + FluidAudio, windowed decode) → `SpeakerIdentityService` (voiceprint matching) → `SummarizationService` (FoundationModels, `FallbackSummarizer` when Apple Intelligence is unavailable). Orchestrated by `RecordingCoordinator`. Model downloads: `EnrichmentModelManager` |
| `EchoNotes/Support/` | Pure helpers: `TranscriptFormatting` (canonical speaker numbering + language markers), `VoiceEmbedding` (cosine/running-mean), `SpeakerAttribution` (word→turn merge), `AppSettings` (all tunables) |
| `EchoNotes/Views/` | SwiftUI, grouped by tab |
| `EchoNotesTests/` | Swift Testing unit tests — pure logic only, run in the simulator |
| `TESTING.md` | The on-device smoke checklist (the real acceptance suite) |

Third-party deps (SPM, declared in `project.yml`): **WhisperKit 1.0.0** and
**FluidAudio 0.12.4**, pinned **exactly** — both SDKs have had API churn.
`TranscriptEnrichmentService` and `EnrichmentModelManager` are the only two
files that touch their APIs; when bumping a pin, verify
`WhisperKit.download(variant:downloadBase:progressCallback:)`,
`WhisperKit(WhisperKitConfig)`, `transcribe(audioArray:decodeOptions:)`,
`DiarizerModels.downloadIfNeeded()`, `DiarizerManager.initialize(models:)`,
and `performCompleteDiarization(_:)` still match, then re-run the
"Transcription robustness" section of TESTING.md on a device.

## Mac prerequisites

1. **Xcode 26** (iOS 26 SDK) installed and selected:
   `sudo xcode-select -s /Applications/Xcode.app && xcodebuild -version`
2. Command-line tools working: `xcrun simctl list >/dev/null`
3. Homebrew + XcodeGen: `brew install xcodegen`
4. An Apple ID signed into Xcode (Settings → Accounts). A free personal
   team works; its provisioning profiles expire after 7 days (reinstall to
   refresh) and allow a limited number of app IDs.
5. The iPhone: iOS 26+, **Developer Mode on** (Settings → Privacy &
   Security → Developer Mode → toggle, reboot, confirm), connected via USB
   the first time (later runs can use Wi-Fi debugging).

## Build

```sh
cd always_on_note_taker
xcodegen generate          # produces EchoNotes.xcodeproj — rerun whenever project.yml changes
```

First build resolves the SPM pins (needs network once).

**CLI build** (find your team ID in Xcode → Settings → Accounts → team →
it's the 10-character code, or `security find-identity -v -p codesigning`):

```sh
xcodebuild -project EchoNotes.xcodeproj -scheme EchoNotes \
  -destination generic/platform=iOS \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=<TEAMID> \
  -allowProvisioningUpdates build
```

**GUI alternative:** `open EchoNotes.xcodeproj` → EchoNotes target →
Signing & Capabilities → pick Team → select the device → Run.

`project.yml` deliberately carries no `DEVELOPMENT_TEAM` — never commit one.

## Unit tests (simulator — no device, no models needed)

```sh
xcodebuild test -project EchoNotes.xcodeproj -scheme EchoNotes \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

`EchoNotesTests` covers the pure logic: voice-activity floor adaptation,
voiceprint math, word→speaker attribution, transcript labeling
(speaker-numbering contract shared by UI and summarizer), fallback
summarizer tiers, review-item occurrence encoding. All tests must pass
before any push.

**What the simulator CANNOT verify:** WhisperKit/FluidAudio inference (need
the Neural Engine and real audio), FoundationModels summaries, background
audio capture, interruptions, thermal behavior. Those live in TESTING.md
and need the phone.

## Install on the iPhone (CLI)

```sh
xcrun devicectl list devices                    # copy the device UDID
xcodebuild -project EchoNotes.xcodeproj -scheme EchoNotes \
  -destination "platform=iOS,id=<UDID>" \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=<TEAMID> \
  -allowProvisioningUpdates -derivedDataPath build build
xcrun devicectl device install app --device <UDID> \
  build/Build/Products/Debug-iphoneos/EchoNotes.app
xcrun devicectl device process launch --device <UDID> com.shreyashg.echonotes
```

(Or just Run from Xcode — same result.)

**First launch on the phone:**
1. If iOS blocks the app: Settings → General → VPN & Device Management →
   trust the developer certificate.
2. Allow **microphone** access when prompted.
3. Tap **Set up** on the Record tab banner (or the gear icon) and download
   the models — "Best" Whisper (~626 MB) + speaker models (~80 MB), Wi-Fi
   recommended. Recordings made before the download finishes are kept and
   transcribed automatically afterwards.
4. Sanity-check the privacy claim: enable Airplane Mode and confirm
   record → transcribe → note still works end-to-end.

## Running the on-device test plan

Work through `TESTING.md` top to bottom. Recommended order and the two
highest-value checks:

1. Unit tests (above) — must be green first.
2. First launch + Core loop sections.
3. **Long-conversation robustness** — 10+ min of dense talk must NOT be cut
   mid-conversation (this guards the VAD floor fix; it's the app's core
   use case).
4. **Always-on behavior** — especially: long phone call while the app is
   backgrounded, then reopen → listening must resume (interruption-ended
   notifications are not guaranteed by iOS; the app self-heals on
   foreground).
5. Multilingual transcription (script a Hindi → English → Spanish session).
6. Speaker recognition (2–3 voices; verify review cards, auto-tagging on
   the next recording, and that similar voices go to review instead of
   silently cross-tagging).
7. Transcription + speaker models (Settings flows), Recovery & edge cases,
   Transcription robustness.

## Tuning knobs and known limitations

- `AppSettings.speakerMatchThreshold` (0.65) + `speakerMatchMargin` (0.10):
  starting points, meant to be tuned against the owner's real family audio.
  Too many "Is this X?" cards → lower the threshold slightly; any wrong
  auto-tag → raise it or widen the margin.
- Language detection is per ~30 s stretch — mid-sentence code-switching
  labels as the dominant language of that stretch.
- Deliberately deferred (do not "fix" casually; each needs on-device
  validation): main-thread SwiftData insert burst when very long recordings
  finish (would need a background ModelContext), merging
  `Status`/`EnrichmentState`, promoting review-card linked occurrences to a
  real table, Notes-search predicate push-down.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `xcodegen: command not found` | `brew install xcodegen` |
| Build errors referencing missing packages | Delete `~/Library/Developer/Xcode/DerivedData`, re-open, let SPM resolve; check network |
| Signing: "No profiles for com.shreyashg.echonotes" | Set a Team (CLI: `DEVELOPMENT_TEAM=…` + `-allowProvisioningUpdates`; GUI: Signing & Capabilities) |
| Free-account "maximum App ID limit" | Wait (limit resets weekly) or use a paid team |
| App won't launch: "Untrusted Developer" | Settings → General → VPN & Device Management → trust |
| "Developer Mode required" | Settings → Privacy & Security → Developer Mode → on → reboot |
| Model rows stuck / download failed | Settings in-app: Remove downloaded models, re-download on Wi-Fi |
| Xcode can't find scheme after `project.yml` edit | Re-run `xcodegen generate` |
| Transcription fails with "models couldn't be loaded" | In-app Settings will show the re-download; OS may have purged the model cache |
