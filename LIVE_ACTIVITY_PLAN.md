# Live Activity plan — recording indicator on the Lock Screen (future feature)

Goal: while EchoNotes is listening/recording, show a Live Activity on the
Lock Screen (and in the Dynamic Island on supported devices) with the
recording state, the running session timer, and a **Stop** button — so the
mic is never on without a glanceable, actionable indicator.

Not implemented yet. This is the blueprint for whoever picks it up (human or
agent). Estimated size: one new widget-extension target + ~4 small files +
~40 lines in `RecordingCoordinator`.

## Architecture

1. **New widget extension target** (`EchoNotesWidgets`) in `project.yml`:
   - `type: app-extension`, `platform: iOS`, point `sources` at a new
     `EchoNotesWidgets/` directory.
   - `INFOPLIST_KEY_NSExtension...` boilerplate comes from a
     `WidgetKit` extension template: `NSExtensionPointIdentifier =
     com.apple.widgetkit-extension`.
   - Signing: same team, bundle id `com.shreyashg.echonotes.widgets`.
     **Free personal teams allow a limited number of App IDs** — this adds a
     second one; plan around the weekly cap.
   - Re-run `xcodegen generate` after editing `project.yml`.

2. **Shared attributes file**, compiled into BOTH targets (add the file's
   path to both `sources` lists):

   ```swift
   import ActivityKit

   struct RecordingActivityAttributes: ActivityAttributes {
       struct ContentState: Codable, Hashable {
           var state: String            // "listening" | "recording" | "interrupted"
           var sessionStartedAt: Date?  // drives the live timer via Text(timerInterval:)
       }
   }
   ```

3. **App side (`RecordingCoordinator`)** — start/update/end the activity
   where `state` already changes:
   - `enable()` success → `Activity.request(attributes:content:)`.
   - `state` transitions (`listening`/`recording`/`interrupted`) and
     `currentSessionStartedAt` changes → `activity.update(...)`.
   - `disable()` → `activity.end(..., dismissalPolicy: .immediate)`.
   - Gate everything on `ActivityAuthorizationInfo().areActivitiesEnabled`,
     and always end stale activities at launch (`Activity<...>.activities`)
     so a crash never leaves a zombie "Recording" on the Lock Screen.
   - No push updates needed: the app runs continuously in the background
     while recording (audio background mode), so local `update()` calls are
     enough. That's the happy coincidence that makes this feature cheap.

4. **Widget side** (`EchoNotesWidgets/RecordingLiveActivity.swift`):
   - `ActivityConfiguration(for: RecordingActivityAttributes.self)` with a
     Lock Screen view (mic glyph, state text, `Text(timerInterval:)` timer,
     Stop button) and `DynamicIsland { ... }` compact/expanded views.
   - **Stop button**: `Button(intent: StopRecordingIntent())` (iOS 17+
     interactive Live Activity buttons).

5. **The stop intent** — shared file in both targets:

   ```swift
   import AppIntents

   struct StopRecordingIntent: LiveActivityIntent {
       static let title: LocalizedStringResource = "Stop Recording"
       func perform() async throws -> some IntentResult {
           // LiveActivityIntent runs IN THE APP'S PROCESS, so it can reach
           // the live coordinator (expose a shared reference or post a
           // Darwin/NotificationCenter signal the coordinator observes).
           await RecordingCoordinator.stopFromIntent()
           return .result()
       }
   }
   ```

   `LiveActivityIntent.perform()` executing in the app process is the key
   detail — no app group, no IPC needed to flip the same `setEnabled(false)`
   the Record tab uses.

6. **Info.plist**: add `NSSupportsLiveActivities = YES` to the APP's
   Info.plist (not the extension's).

## Testing checklist (goes into TESTING.md when built)

- Toggle on → Live Activity appears on Lock Screen within a second; timer
  ticks while recording; state flips to "Paused by the system" during a
  phone call and back after.
- Stop button on the Lock Screen stops listening (orange mic dot goes away)
  and the activity disappears.
- Force-quit while recording → relaunch → no zombie activity.
- Live Activities disabled in Settings → app behaves normally (no crash).
- 8+ hour session: Live Activities have a system lifetime (~8 h active,
  12 h on screen) — verify the app re-requests or gracefully lets it lapse.

## Constraints to remember

- Every model/inference constraint of this app is untouched: Live
  Activities are pure UI, no network.
- The widget extension cannot access the microphone or SwiftData store —
  everything it shows must come through `ContentState`.
- iOS 26 baseline for this repo means all APIs above are available; the
  interactive button needs no fallback path.
