# EchoNotes — on-device smoke checklist

Run on a real device (iOS 26+). Items marked ⭐ need an Apple Intelligence-capable
device (iPhone 15 Pro or newer / M-series iPad) with Apple Intelligence enabled.

## First launch
- [ ] App launches to the Record tab with the big Off button.
- [ ] A "Download the on-device models" banner shows until the transcription models are installed; "Set up" opens Settings.
- [ ] Turning the toggle on prompts for microphone access; allowing it moves to "Listening for speech" (recording works even before the models are downloaded).
- [ ] Recordings made BEFORE the model download are transcribed automatically right after the download completes (and on next launch).

## Core loop
- [ ] Speak for ~30 seconds → status becomes "Recording" with a running timer (no live transcript — transcription runs after the session).
- [ ] Turn the toggle off → the "Transcribing your last recording…" progress card appears on the Record tab, then the note appears in the Notes tab with a transcript, title, overview, key points, tags ⭐ (basic summary otherwise).
- [ ] Note detail: Transcript shows timestamped lines; tapping a timestamp plays audio from that moment; Audio tab scrubs and changes speed.

## Long-conversation robustness
- [ ] 10+ minutes of dense, continuous conversation (family dinner) → stays one session; the recording is NOT cut mid-talk by the voice detector.
- [ ] A loud steady noise starting near the phone (fan, AC) without speech → the session still ends a couple of minutes after people stop talking (noise is eventually reclassified).

## Always-on behavior
- [ ] Start listening, lock the screen, keep talking → transcript continued (check the note afterward). Orange mic indicator stays visible.
- [ ] Switch to another app while recording → recording continues in the background.
- [ ] Receive/place a phone call mid-recording → status shows "Paused by the system"; after the call, listening resumes automatically and a new note starts at the next speech.
- [ ] Long call while EchoNotes is backgrounded, then reopen the app → listening resumes on foreground even if iOS never delivered the interruption-ended signal (no permanent "Paused by the system").
- [ ] Play a note, then receive a call → playback pauses and the button shows "play" (not a frozen "playing" state).
- [ ] Stay silent for ~2 minutes mid-session, then talk again → the first session becomes its own note and a second one starts.
- [ ] Plug in / unplug wired or Bluetooth headphones mid-recording → recording keeps going (session survives the route change).

## Everything-local proof
- [ ] Enable Airplane Mode (after the one-time model download) → recording, transcription, and note generation all still work.

## Recovery & edge cases
- [ ] Force-quit the app mid-recording, relaunch → the interrupted session's audio is kept and transcribed (or cleaned up if it holds under ~5 s of audio).
- [ ] A brief noise (< 5 s of speech) does not create a note.
- [ ] Deleting a note removes it from the list (and its audio file from disk), plus any pending voice-review cards from that recording.
- [ ] Deny mic permission → Record tab shows the warning banner with a working Settings shortcut.
- [ ] Fill the device storage, then talk → the Record tab shows the "speech can't be saved" warning instead of a healthy Listening screen; it clears once a session starts successfully.
- [ ] Swipe-deleting the row of the session currently being recorded does nothing (it becomes deletable when the session ends).
- [ ] Delete a recording that shares an unknown voice with other recordings → the review card survives, re-anchored to a surviving recording with a playable sample.
- [ ] On a non-Apple-Intelligence device: notes still generate via the basic summarizer and the info banner explains why; key points do NOT repeat the overview sentences.

## Transcription + speaker models (Settings)
- [ ] Settings → Download models shows progress for the language model; both rows flip to "Installed"; the Record tab banner disappears.
- [ ] Kill the app mid-download, reopen, download again → completes (or resumes) without a corrupt state.
- [ ] Switch the model picker between Best and Compact → the other variant shows "Not downloaded" until fetched.
- [ ] Remove downloaded models → rows return to "Not downloaded"; recording still works (sessions parked audio-only until models return); removal is blocked while a recording is being transcribed.
- [ ] Download Best, switch the picker to Compact → "Remove downloaded models" is still offered (the Best install must not be stranded); switching back to Best flips it to Installed and sweeps any parked recordings.

## Multilingual transcription (models installed)
- [ ] Record a session switching languages in ~1-minute blocks (e.g. Hindi → English → Spanish) → after "Transcribing…", segments carry the right text per language; non-dominant languages get a capsule badge (e.g. "Hindi").
- [ ] Devanagari (and any accented text) renders correctly and stays selectable in the transcript.
- [ ] Tap a timestamp on a transcript line → playback starts at that moment (Whisper timestamps line up with the audio).
- [ ] While a session is being transcribed, the Record tab shows the progress card and the note row shows "Transcribing…"; both clear when done.
- [ ] Summary of a multilingual recording is written in English and doesn't invent content for the non-English parts ⭐.

## Speaker recognition (models installed)
- [ ] Record a 2–3 person conversation → transcript groups lines under "Speaker 1/2/3" with colored dots.
- [ ] The person icon in the Notes tab's top bar shows a red badge with the new-voice count; tapping it opens the People sheet, and each card plays a ~10 s sample of the right voice.
- [ ] Naming a card (new name, "Me", or an existing person) immediately labels that speaker's lines in the transcript.
- [ ] A voice named once is auto-tagged in the next recording without a new review card.
- [ ] Two similar voices (e.g. siblings) are NOT silently cross-tagged — the borderline one shows an "Is this X?" card instead.
- [ ] Rename / merge / remove in People behaves: merge moves all lines to the kept person; remove reverts lines to "Speaker n".
- [ ] Action items name the responsible speaker when the transcript makes it clear ⭐.

## Transcription robustness
- [ ] 30+ minute session: processing completes; watch Instruments → memory stays flat across windows (chunked decode), no thermal runaway (processing pauses if the device gets hot).
- [ ] Force-quit mid-processing, relaunch → the session re-processes from the start and ends with a single, non-duplicated transcript.
- [ ] Transcription failure (e.g. corrupt the audio file in a debug build) → the recording is kept, the row shows a warning icon, and the detail view explains WHY it failed next to Retry; Retry hides when the audio itself is unreadable.
- [ ] Delete a note while it's being transcribed → processing stops (no zombie CPU burn), later recordings still get transcribed, and Settings' "Remove models" does not stay disabled by a phantom job.
- [ ] Kill the app while a finished transcript's note is still generating, relaunch → the note is generated WITHOUT re-running speaker identification (no duplicate "heard in N recordings" inflation on pending voice cards).
- [ ] Airplane-mode proof again AFTER installing the models: recording, multilingual transcription, speaker tagging, and notes all work offline.
