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
- [ ] Deleting a note removes it from the list (and its audio file from disk), plus any pending voice-review cards from that recording.
- [ ] Deny mic permission → Record tab shows the warning banner with a working Settings shortcut.
- [ ] On a non-Apple-Intelligence device: notes still generate via the basic summarizer and the info banner explains why.

## Multilingual + speaker models (Settings)
- [ ] Record tab shows the one-time "Download the multilingual models" banner; "Set up" opens Settings.
- [ ] Settings → Download models shows progress for the language model; both rows flip to "Installed".
- [ ] Kill the app mid-download, reopen, download again → completes (or resumes) without a corrupt state.
- [ ] Switch the model picker between Best and Compact → the other variant shows "Not downloaded" until fetched.
- [ ] Remove downloaded models → rows return to "Not downloaded"; recording still works like v1 (enrichment skipped).

## Multilingual transcription (models installed)
- [ ] Record a session switching languages in ~1-minute blocks (e.g. Hindi → English → Spanish) → after "Processing transcript…", segments carry the right text per language; non-dominant languages get a capsule badge (e.g. "Hindi").
- [ ] Devanagari (and any accented text) renders correctly and stays selectable in the transcript.
- [ ] Tap a timestamp on an enriched segment → playback starts at that moment (Whisper timestamps line up with the audio).
- [ ] On a device set to an unsupported language (e.g. Hindi locale): recording is NOT blocked; an info banner explains live transcription is off; the post-session transcript still arrives.
- [ ] While a session is being processed, the note row shows "Processing transcript…" and the transcript view shows the preliminary banner; both clear when done.
- [ ] Summary of a multilingual recording is written in English and doesn't invent content for the non-English parts ⭐.

## Speaker recognition (models installed)
- [ ] Record a 2–3 person conversation → transcript groups lines under "Speaker 1/2/3" with colored dots.
- [ ] People tab badge shows the new-voice count; each card plays a ~10 s sample of the right voice.
- [ ] Naming a card (new name, "Me", or an existing person) immediately labels that speaker's lines in the transcript.
- [ ] A voice named once is auto-tagged in the next recording without a new review card.
- [ ] Two similar voices (e.g. siblings) are NOT silently cross-tagged — the borderline one shows an "Is this X?" card instead.
- [ ] Rename / merge / remove in People behaves: merge moves all lines to the kept person; remove reverts lines to "Speaker n".
- [ ] Action items name the responsible speaker when the transcript makes it clear ⭐.

## Enrichment robustness
- [ ] 30+ minute session: processing completes; watch Instruments → memory stays flat across windows (chunked decode), no thermal runaway (processing pauses if the device gets hot).
- [ ] Force-quit mid-processing, relaunch → the session re-processes from the start and ends with a single, non-duplicated transcript.
- [ ] Enrichment failure (e.g. delete the audio file mid-flight in a debug build) → note falls back to the preliminary transcript and the detail view offers Retry.
- [ ] Airplane-mode proof again AFTER installing the models: recording, multilingual transcription, speaker tagging, and notes all work offline.
