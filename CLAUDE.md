# Soundboard — notes for agents

A private, offline macOS replacement for Elgato Stream Deck software + Voicemod: a
Stream Deck Neo triggers sound effects that are mixed with the user's mic into a
virtual audio device (BlackHole 2ch) that Zoom uses as its microphone. User-facing docs
are in `README.md`; this file is the architecture and the lessons learned.

**Prime directive: privacy.** The main app must stay offline (sandbox, no network
entitlement) and dependency-free (Apple frameworks only). Anything that needs the
network goes in the separate `SoundboardFetch` helper. Don't add packages.

## Build, run, test

```bash
swift build -c release                 # both products
./build.sh                             # → build/Soundboard.app (helper embedded, ad-hoc signed)
./build.sh --install                   # → /Applications
open build/Soundboard.app --args --settings            # open the window (Sounds & Keys)
open build/Soundboard.app --args --audio               # … on the Audio tab
open build/Soundboard.app --args --clip <file|link>    # … Sound Editor with a file or link
open build/Soundboard.app --args --settings --snapshot 3   # saves the window as snapshot.png in the
                                                           # Soundboard folder after 3s (see Testing)
.build/release/Soundboard --devices    # list CoreAudio devices
.build/release/Soundboard --preview DIR   # render every key to PNGs
SOUNDBOARD_DEBUG=1 …                   # log raw Stream Deck HID reports
```

- Swift tools 6.0 with **Swift 5 language mode** (`Package.swift`): strict concurrency
  would fight the C callbacks. Regex literals (`/…/`) don't compile in this mode; use
  `NSRegularExpression` or manual parsing.
- macOS 15+ (uses `Synchronization.Atomic`). The dev machine is Apple Silicon (M4 Max) on macOS 26.
- There's no test target. Verification has been done with snapshots, small `swiftc`
  harnesses and helper runs (see Testing).
- After `pkill -x Soundboard`, wait ~2s before `open`, or `open` just reactivates the
  dying instance and the `--args` are ignored.

## Runtime layout

```
Stream Deck ─HID─▶ Soundboard.app (sandboxed, no network)
                    ├─ mic engine ──ring buffer──┐
                    ├─ broadcast engine ◀────────┘ + sound voices ─▶ BlackHole 2ch ─▶ Zoom
                    └─ monitor engine (sound voices) ─▶ headphones
                   NSWorkspace launch + files in downloads/
                    └─▶ SoundboardFetch.app (not sandboxed; yt-dlp, URLSession, ffmpeg)
```

User data lives in `~/Library/Application Support/Soundboard/` (`config.json`,
`sounds/`, `icons/`, `downloads/` temp). This is the **real** home folder, not the
sandbox container: `Paths.home` uses `getpwuid`, and the entitlements grant a
`temporary-exception.files.home-relative-path.read-write` for that folder only.

## Files

| File | What it does |
| --- | --- |
| `Config.swift` | `Config` (v2), `SoundEntry` (library), `ButtonConfig` (key), `KeyFace`, v1→v2 `upgrade`, `Paths` |
| `AppController.swift` | App delegate: config load/save/apply, file watchers, deck events → actions, menu bar, status |
| `AudioRouter.swift` | The three AVAudioEngines, voice pool, play/stop/overlay, bleep (censor), async device setup |
| `RingBuffer.swift` | Lock-free SPSC mic buffer with drift control (target 20 ms, resync at 80 ms) |
| `AudioDevices.swift` | CoreAudio device enumeration (timeout-guarded), change listener with snapshot dedupe |
| `StreamDeck.swift` | IOHIDManager + Stream Deck gen-2 protocol; retries when another app holds the device |
| `KeyRenderer.swift` | CoreGraphics key/screen images, JPEG (rotated 180°) for the device |
| `AssetCache.swift` | Decoded sounds (48 kHz stereo) and icons, cached by file mtime; renders `KeyFace` |
| `Fetcher.swift` | App side of the helper protocol (`fetch` stream) + `PreviewPlayer` (streaming previews) |
| `UI/MainWindow.swift` | The single window: tabs (Sounds & Keys, Sound Editor, Audio), status strip, main menu |
| `UI/SettingsView.swift` | `SettingsModel` + Sounds & Keys tab (library, pad, inspectors), `AudioSettings` |
| `UI/ClipEditor.swift` | Sound Editor: sources (file/YouTube/website), waveform selection, export to WAV |
| `SoundboardFetch/main.swift` | Helper: `info`, `preview`, `video`, `page`, `direct` modes |
| `tools/import_voicemod.py` | One-off importer from Voicemod cache + Elgato profiles (writes a v1 config) |

## Data model (config.json v2)

- `library: [SoundEntry]`: the sound bank. It holds the file, name, key cap (label/image/color),
  volume and mode (`toggle` | `overlay`). Keys reference entries by `id`.
- `pages: [[ButtonConfig?]]`: row-major keys, `null` = blank. A key is
  `{sound: id}` or `{action: "stop"|"censor", label, image, color}`.
- `Config.upgrade(soundFiles:)` migrates v1 (sound settings stored per key, with `sound` holding a
  filename) into the library, and also adds any audio file in `sounds/` that isn't in
  the library. It runs on load **and on every save**, so dropping a file in `sounds/`
  adds it to the library. Deleting a sound must therefore move its file out of `sounds/`
  (Trash, or a `sounds/Deleted/` fallback), or it gets re-added.
- `AppController.save` writes the file and records `lastWritten`, so the file watcher
  ignores the app's own writes. `apply` only rebuilds audio when routing fields change;
  volumes go through `router.setVolumes`.
- `SettingsModel.update` debounces commits (0.25 s). `external(_:)` ignores incoming
  configs while a commit is pending, so in-flight edits aren't clobbered.

## Audio engine — lessons learned

- **One engine per device.** On macOS an AVAudioEngine's I/O unit binds to one device,
  so there are separate mic, broadcast (BlackHole) and monitor engines. Devices are
  selected with `kAudioOutputUnitProperty_CurrentDevice` before the graph is built.
- **Mic → broadcast** goes through `AVAudioSinkNode` → `RingBuffer` → `AVAudioSourceNode`
  (mono, at the mic's rate; the mixer resamples). The two clocks drift; the ring buffer
  handles it.
- **All sounds are converted to `mixFormat` (48 kHz stereo float) on load**, so any voice
  can play any buffer. There's a fixed pool of 12 voices per engine, with the same index in
  each engine. Completion callbacks use per-voice tokens; `stop()` also fires them.
- **Rebuild loop bug (fixed):** moving an engine off the default device posts
  `AVAudioEngineConfigurationChange` while the engine keeps running. Only rebuild if
  the engine stopped or the mic's sample rate changed (`needsRebuild`). The CoreAudio
  device listener also fires for no-op changes, so compare snapshots first.
- **Stuck drivers block HAL calls forever.** After `sudo killall coreaudiod`, BlackHole
  hung: even `say -a "BlackHole 2ch"` hangs. So device setup runs on
  `AudioRouter.setupQueue` (generation-guarded, `status.connecting` meanwhile), and
  `AudioDevices.all()` times out after 0.5 s and returns a cached list. Keep any new HAL
  calls off the main thread.
- Never call `AVAudioPlayerNode.play()` on a stopped engine (it raises an exception); use `runningBuses`.

## Stream Deck (Neo) protocol

Vendor 0x0fd9, Neo product 0x009a: 8 LCD keys (4×2, 96 px), 2 touch keys (indices 8, 9 =
page back/forward), and a 248×58 info screen.

| What | Report |
| --- | --- |
| Input report | `01 00 cnt cnt k0 k1 …`: the key states start at byte 4 (the report ID is included) |
| Key image | Output report, 1024 bytes: `02 07 key last lenLo lenHi pageLo pageHi` + JPEG chunk |
| Screen image | Same as a key image, but with `02 0b 00 …` |
| Brightness | Feature report, 32 bytes: `03 08 pct` |
| Reset | Feature report, 32 bytes: `03 02` |

- Images must be rotated 180°.
- The Elgato app opens the device exclusively (`0xe00002c5`), so `StreamDeckManager` retries every 2 s.
- Other gen-2 models are in the table but untested.

## The helper (`SoundboardFetch`) protocol

Apps launched from the sandbox via `NSWorkspace.openApplication` **don't receive launch
arguments** (verified), so it's file-based, in `downloads/`:

| File | Written by | Purpose |
| --- | --- | --- |
| `<job>.request.json` | app | The request. The helper claims it by renaming it to `.claimed`. |
| `<job>.json` | helper | Status: `downloading` (progress, message), `done` (file, title), `choices` (list), `info`, `playing` / `loading` / `ended` (preview), `error` (message). |
| `<job>.cancel` | app | Stop the job. |
| `<job>.seek` | app | Seek a preview to this many seconds. |

Request modes:

| Mode | What it does |
| --- | --- |
| `info` | Video details via yt-dlp `--print` JSON, plus a thumbnail. Nothing else downloaded. |
| `preview` | Streams with AVPlayer and saves nothing. For video sites the stream URL comes from `yt-dlp -g`. |
| `video` | yt-dlp download (≤480p H.264). `section` → `--download-sections`. |
| `page` | Lists the sounds on a web page and never downloads (see below). |
| `direct` | URLSession download. Rejects anything over 200 MB and `text/*` responses. |

How `page` finds sounds:
- It decodes entities, including Angular's `&q;`, and parses embedded JSON records (`name` + media file + `url` slug).
- It scans for quoted media links.
- Bare file names get their folder by sending HEAD requests to common folders (`uploads/` …).
- A page whose last path segment matches a record's slug returns just that one sound.

Non-playable formats (ogg/webm/opus) are converted to WAV with ffmpeg. yt-dlp and
ffmpeg come from Homebrew (`/opt/homebrew/bin`). The helper sets `PATH` so yt-dlp finds
ffmpeg/deno. The app clears `downloads/` at launch, and the editor deletes its download
and thumbnail on reset.

## Gotchas

- **Ad-hoc signing changes every build**, so macOS privacy (TCC) treats each build as a new
  app. The mic permission prompt can reappear, and the TCC check can block until it's answered.
- **Voicemod's own library sounds** in its cache are scrambled. User uploads are plain
  Ogg. Don't try to decrypt Voicemod content.
- **`screencapture` isn't permitted** from the agent shell; use `--snapshot`. It draws
  the largest visible window via `cacheDisplay`, so AVPlayerView content shows black
  and views need an explicit background.
- **Don't make audible test noise** on the user's Mac: preview tests used a silent file
  served by `python3 -m http.server` on 127.0.0.1. Test videos were Big Buck Bunny (open-licensed, Blender).
- **`rm` on a shell variable gets blocked** by a safety check; use `"${VAR:?}"`.
- **Commits:** small and incremental, **no Co-Authored-By trailer** (user preference).
