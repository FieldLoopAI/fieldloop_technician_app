# Seed clips (build 180 item A)

Optional. Put WAV files here to have scripted replies play from a clip on the
very first use instead of being spoken by Gemini once first.

- Name: `<clipFileKey(text)>.wav` or `confirmation_clip_<clipFileKey(text)>.wav`
  (the name the app itself uses on the device).
- Format: PCM, mono, 16-bit, 24000 Hz, 0.6–8 s (the app refuses anything else).
- At session start the app copies each file into its clip store only when the
  store has no clip for that key yet, then logs
  `SCRIPTED CLIP: seeded N from assets (skipped M existing)`.

No WAV files are checked in.
