# EchoNotes — on-device smoke checklist

Run on a real device (iOS 26+). Items marked ⭐ need an Apple Intelligence-capable
device (iPhone 15 Pro or newer / M-series iPad) with Apple Intelligence enabled.

## First launch
- [ ] App launches to the Record tab with the big Off button.
- [ ] Turning the toggle on prompts for microphone access; allowing it moves to "Listening for speech".
- [ ] If the speech model isn't installed yet, a download banner with progress appears and listening starts when it finishes.

## Core loop
- [ ] Speak for ~30 seconds → status becomes "Recording" with a running timer; live transcript streams (dimmed text firms up as it finalizes).
- [ ] Turn the toggle off → within a few seconds the note appears in the Notes tab with a title, overview, key points, tags ⭐ (basic summary otherwise).
- [ ] Note detail: Transcript shows timestamped lines; tapping a timestamp plays audio from that moment; Audio tab scrubs and changes speed.

## Always-on behavior
- [ ] Start listening, lock the screen, keep talking → transcript continued (check the note afterward). Orange mic indicator stays visible.
- [ ] Switch to another app while recording → recording continues in the background.
- [ ] Receive/place a phone call mid-recording → status shows "Paused by the system"; after the call, listening resumes automatically and a new note starts at the next speech.
- [ ] Stay silent for ~2 minutes mid-session, then talk again → the first session becomes its own note and a second one starts.
- [ ] Plug in / unplug wired or Bluetooth headphones mid-recording → recording keeps going (session survives the route change).

## Everything-local proof
- [ ] Enable Airplane Mode (after the one-time model download) → recording, transcription, and note generation all still work.

## Recovery & edge cases
- [ ] Force-quit the app mid-recording, relaunch → the interrupted session appears as a note built from what was already transcribed (or is cleaned up if nothing was said).
- [ ] A brief noise (< 5 s of speech) does not create a note.
- [ ] Deleting a note removes it from the list (and its audio file from disk).
- [ ] Deny mic permission → Record tab shows the warning banner with a working Settings shortcut.
- [ ] On a non-Apple-Intelligence device: notes still generate via the basic summarizer and the info banner explains why.
