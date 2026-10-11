# Soundboard: notes for agents

A private, offline macOS soundboard and mic mixer: a Stream Deck (or the on-screen
palette) triggers sound effects that are mixed with the user's mic into a virtual audio
device (BlackHole 2ch) that meeting and streaming apps use as their microphone. User-facing docs
are in `README.md`; this file is the architecture and the lessons learned.

**Prime directive: privacy.** The main app must stay offline (sandbox, no network
entitlement) and dependency-free (Apple frameworks only). Anything that needs the
network goes in the separate `SoundboardFetch` helper. Don't add packages.

## Build, run, test

```bash
swift build -c release                 # both products
make app                               # → build/Soundboard.app (helper embedded, ad-hoc signed)
make install                           # → /Applications
make dmg VERSION=1.2.0                 # → build/Soundboard.dmg
open build/Soundboard.app --args --settings            # open the window (Sounds & Keys)
open build/Soundboard.app --args --audio               # … on the Audio tab
open build/Soundboard.app --args --app-settings        # … on the Settings tab
open build/Soundboard.app --args --sync                # … on the Sync tab
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
- macOS 15+ (uses `Synchronization.Atomic`).
- There's no test target. Verification has been done with snapshots, small `swiftc`
  harnesses and helper runs (see Testing).
- After `pkill -x Soundboard`, wait ~2s before `open`, or `open` just reactivates the
  dying instance and the `--args` are ignored.

- **CI:** `push-trunk.yml` and `manual-release.yml` only chain `reusable-*` workflows, which run
  `make` targets. Keep logic in the Makefile.

## Runtime layout

```
Stream Deck ─HID─▶ Soundboard.app (sandboxed, no network)
                    ├─ mic engine ──ring buffer──┐
                    ├─ broadcast engine ◀────────┘ + sound voices ─▶ BlackHole 2ch ─▶ meeting app
                    └─ monitor engine (sound voices) ─▶ headphones
                   NSWorkspace launch + files in downloads/
                    └─▶ SoundboardFetch.app (not sandboxed; yt-dlp, URLSession, ffmpeg)
```

User data lives in `~/Library/Application Support/Soundboard/` (`config.json`, `local.json`,
`sounds/`, `icons/`, `downloads/` temp; `.git/` once sync is on). This is the **real** home folder, not the
sandbox container: `Paths.home` uses `getpwuid`, and the entitlements grant a
`temporary-exception.files.home-relative-path.read-write` for that folder only.

## Files

| File | What it does |
| --- | --- |
| `Config.swift` | `Config` (v2), `SoundEntry` (library), `ButtonConfig` (key), `KeyFace`, v1→v2 `upgrade`, config.json/local.json split, `Paths` |
| `AppController.swift` | App delegate: config load/save/apply, file watchers, deck events → actions, menu bar, status |
| `AudioRouter.swift` | The three AVAudioEngines (started on demand), voice pool, play/stop/overlay, bleep (censor), async device setup |
| `RingBuffer.swift` | Lock-free SPSC mic buffer with drift control (target 20 ms, resync at 80 ms) |
| `AudioDevices.swift` | CoreAudio device enumeration (timeout-guarded), change listener with snapshot dedupe |
| `AudioListeners.swift` | Whether another app reads input from the output device (CoreAudio process objects) |
| `StreamDeck.swift` | IOHIDManager + Stream Deck gen-2 protocol; retries when another app holds the device |
| `Palette.swift` | On-screen palette for use without a deck: `CornerTrigger` (hot corner) + non-activating panel |
| `KeyRenderer.swift` | CoreGraphics key/screen images, JPEG (rotated 180°) for the device |
| `AssetCache.swift` | Decoded sounds (48 kHz stereo) and icons, cached by file mtime; renders `KeyFace` |
| `Fetcher.swift` | App side of the helper protocol (`fetch` stream) + `PreviewPlayer` (streaming previews) |
| `Sync.swift` | `SyncService`: when to run the helper's `sync` (connect, launch, 15 s after a change, Sync Now; no timer), its state |
| `UI/MainWindow.swift` | The single window: tabs (Sounds & Keys, Sound Editor, Audio, Settings), status strip, main menu |
| `UI/SettingsView.swift` | `SettingsModel` + Sounds & Keys tab (library, pad, inspectors) |
| `UI/AudioTab.swift` | Audio tab (input → processing → test → output → monitor), meters, `AudioMonitor` |
| `UI/SettingsTab.swift` | Settings tab: Stream Deck, on-screen palette, playback, open at login. Not signal settings |
| `UI/ClipEditor.swift` | Sound Editor: sources (file/YouTube/website), waveform selection, export to WAV |
| `UI/SyncTab.swift` | Sync tab: connect / disconnect a repository, status, setup help |
| `SoundboardFetch/main.swift` | Helper: `info`, `preview`, `video`, `page`, `direct`, `sync` modes |
| `SoundboardFetch/GitSync.swift` | `sync` mode: commit, fetch, merge, push with the Mac's git (`Git` runner) |
| `SoundboardFetch/ConfigMerge.swift` | config.json three-way merge driver (`--merge-config %O %A %B`) |

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
- **Two files:** `config.json` holds only `Config.sharedKeys` (`version`, `library`, `pages`),
  which sync. Everything else (devices, volumes, noise removal, brightness, `hotCorner`, `syncRemote`) is
  per Mac, in `local.json`. Without `local.json` (older configs) those keys are read from
  config.json and split out on the next save; with it, any audio keys in config.json are
  ignored. Both are written with sorted keys and tidy decimals so synced diffs stay small.
- `AppController.save` writes both files and records `lastWritten`, so the file watcher
  ignores the app's own writes. `apply` only rebuilds audio when routing fields change;
  volumes go through `router.setVolumes`.
- `SettingsModel.update` debounces commits (0.25 s). `external(_:)` ignores incoming
  configs while a commit is pending, so in-flight edits aren't clobbered.

## Audio engine: lessons learned

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
- **Setup runs in two stages** on `setupQueue`: `buildLocal` (mic + monitor) is installed first,
  then `buildBroadcast` (the output device). A hung BlackHole therefore only blocks the output;
  the input meter, monitor and input test still work. `install` merges each stage.
- **A hung mic blocks everything behind it.** Once, a USB mic's `MicCapture.init` blocked in a HAL
  call forever, and since `buildLocal` runs before `buildBroadcast` on one queue, no sound reached
  the headphones or BlackHole. The mic now opens through `openMic` with a 5 s timeout (shown as a mic problem).
- **Engines run on demand.** All three engines are built but not started. `Demand` decides
  which run: `.listener` (another app reads from the output device; see `AudioListeners`) and
  `.audioTab` run everything; `.playback` (a sound played in the last 30 s) runs only the monitor.
  Starting is immediate; stopping waits 3 s after the last reason goes away. With no demand,
  nothing is open: no mic indicator, no isolation model, ~0% CPU, and no coreaudiod
  `PreventUserIdleSystemSleep` assertions, which an open output device holds and which stop the
  Mac from idle-sleeping (check with `pmset -g assertions`). A key pressed while the monitor is
  stopped claims its voice and waits in `pending` until the engine runs (measured ~90 ms to built-in
  headphones). Completions are scheduled on the first running bus, now the monitor, which can't
  stop while a sound plays. Noise removal is bypassed while the mic is paused. Live flags
  (`status.micLive` …) are only set once `start()` succeeded, and cleared before `stop()`, so
  `needsRebuild` treats "stopped" as a failure only while an engine is meant to run.
- **`AudioListeners`** uses the macOS 14 process objects (`kAudioHardwarePropertyProcessObjectList`,
  then per process `IsRunningInput` + input-scope `Devices`), with property listeners, no polling;
  it works from the sandbox. Verified with Zoom: Test Mic shows `us.zoom.xos` reading BlackHole
  (everything running ~100 ms later); it drops off when the test stops, and stays while muted. A
  process's device list includes every device it has open in each direction the device supports
  (Zoom's output list includes BlackHole too), so an app that only plays to BlackHole while
  recording another mic also counts; that errs toward running. Soundboard excludes its own pid.
  If the query fails it reports "listening", so calls never lose the mic.
- **Meters and the input test** use engine taps (`TapState`, lock-based; taps aren't real-time):
  raw input on the mic engine's input node (works without the output), processed on the
  isolation unit, mix on the broadcast mixer. The test records raw input and replays it on the
  monitor bus through an offline copy of the input chain (`render`), so new settings apply to
  the same recording. UI terms are generic (Input / Output / Monitor); config keys keep the old
  `mic*` / `outputDevice` / `monitor*` names.
- **Stuck drivers block HAL calls forever.** After `sudo killall coreaudiod`, BlackHole
  hung: even `say -a "BlackHole 2ch"` hangs. So device setup runs on
  `AudioRouter.setupQueue` (generation-guarded, `status.connecting` meanwhile), and
  `AudioDevices.all()` times out after 0.5 s and returns a cached list. Keep any new HAL
  calls off the main thread.
- **Noise suppression** is `AUSoundIsolation` (Apple, macOS 13+) between the mic source node and
  the broadcast mixer, so it never touches the sounds and the meeting app's own noise filter can stay off. It
  stays in the graph and is toggled by `bypass` and its wet/dry parameter, both live. Measured:
  ~56 ms latency at any mic rate (the dry path is delay-aligned, so partial strength doesn't comb),
  zero when bypassed, ~50–70 dB off broadband noise, ~1 dB off speech. The censor bleep is a
  separate node on each bus, because the isolation would remove a bleep mixed into the mic.
- **Taps ignore `bufferSize`**: they deliver 4800 frames (100 ms) at a time, 10 per second.
  Anything faster (the deck's 20 fps input graph) has to split buffers into chunks
  (`TapState.addChunks`) rather than poll the latest level, or alternate frames see no update.
  The graph taps both sides of the noise removal on the output engine so the chunks line up.
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
- The info screen is a `ScreenFrame`: a static message, the playing sound's waveform
  (`AssetCache.waveform`, peaks per pixel column) with a playhead taken from the player's
  sample time (`AudioRouter.progress`), or the input level history. A 20 fps timer runs only
  while a sound plays or the input is on. Levels are quantized and frames that compare equal
  aren't sent, so silence costs no USB traffic. `setScreenImage` keeps only the newest
  pending frame, so a slow device drops frames instead of falling behind.
  `SOUNDBOARD_DEBUG=1` logs the average screen write time. Measured on the Neo (USB high
  speed): ~5 KB per frame, a 2 ms write, and about +0.3% of a core over the ~7% the audio
  engines use, so 20 fps leaves plenty of room.
- **Without a deck**, `Palette` mirrors the current page (`keyLayout` falls back to the Neo's
  4×2) and calls the same `AppController.press(index:pressed:)` / `turnPage(by:)` as the deck.
  `CornerTrigger` uses `NSEvent` mouse-moved monitors (global + local); mouse monitors need no
  Accessibility permission and work from the sandbox (verified). It waits 0.15 s in the corner,
  then re-arms once the pointer leaves. The panel is `.nonactivatingPanel` at `.popUpMenu` level
  and can't become key, so clicks never take focus from the meeting app. It closes on a click elsewhere
  (global mouse-down monitor) or when a 10 Hz poll, which runs only while it's open, finds the pointer gone.
  `open … --args --palette --snapshot 2` shows and snapshots it (rendered from its layers).
  Synthetic mouse events from the agent shell are dropped (no Accessibility), so the hot corner
  itself has to be tried by hand.
- The vendor's own app opens the device exclusively (`0xe00002c5`), so `StreamDeckManager` retries every 2 s.
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
| `sync` | `link` is a Git remote. Status `synced` (message) or `error`. See below. |

How `page` finds sounds:
- It decodes entities, including Angular's `&q;`, and parses embedded JSON records (`name` + media file + `url` slug).
- It scans for quoted media links.
- Bare file names get their folder by sending HEAD requests to common folders (`uploads/` …).
- A page whose last path segment matches a record's slug returns just that one sound.

Non-playable formats (ogg/webm/opus) are converted to WAV with ffmpeg. yt-dlp and
ffmpeg come from Homebrew (`/opt/homebrew/bin`). The helper sets `PATH` so yt-dlp finds
ffmpeg/deno. The app clears `downloads/` at launch, and the editor deletes its download
and thumbnail on reset.

## Sync (`sync` mode)

- The Soundboard folder itself is the work tree. The helper (re)writes `.gitignore` (local.json,
  downloads/, `*/Deleted/`, backups) and `.gitattributes` (`config.json merge=soundboard`), and
  points `merge.soundboard.driver` in `.git/config` at its own executable on every run.
- Steps: `add -A` + commit ("Changes from <Mac name>", author "Soundboard (<Mac name>)", never
  signed) → `ls-remote --symref` for the branch (none = empty repo, push `main`) → fetch →
  `merge --allow-unrelated-histories -X theirs` → push, retrying up to 3 times if the push races.
  Leftover conflicts (modify/delete, a failed driver) resolve to theirs, else ours: an edit
  beats a deletion.
- `ConfigMerge` merges the library by `id` (field by field when both edited a sound) and pages
  key by key (whole keys); conflicts go to theirs (the repository). An empty base means a Mac
  is joining: it takes the repo's keys, and its unused `/System/Library/Sounds` starter sounds
  are dropped. Deleting a page shifts indices, so concurrent page deletes can mix keys up.
- Safety: a non-empty remote without `config.json` is refused; a newly set remote gets a
  `push --dry-run` to a scratch ref first (a public repo you can read but not write would
  otherwise be merged in before the push failed, as testing against octocat/Hello-World showed).
- git never prompts: `GIT_TERMINAL_PROMPT=0`, stdin is /dev/null, and `ssh -o BatchMode=yes`
  unless the user set `core.sshCommand`. The error shown is the server's/ssh's line (GitHub's
  `ERROR: Repository not found.`), not git's generic "Could not read from remote repository".
  Homebrew git is preferred; `/usr/bin/git` only if `xcode-select -p` succeeds (otherwise it's a stub that pops an installer).
- Test without touching real data: `SOUNDBOARD_ROOT=<folder>` points the helper elsewhere; write
  `<folder>/downloads/<job>.request.json` and run `.build/release/SoundboardFetch` directly.
  Two such folders and a local bare repo exercise joins, merges and conflicts.

## Gotchas

- **Ad-hoc signing changes every build**, so macOS privacy (TCC) treats each build as a new
  app. The mic permission prompt can reappear, and the TCC check can block until it's answered.
- **`screencapture` isn't permitted** from the agent shell; use `--snapshot`. It draws
  the largest visible window via `cacheDisplay`, so AVPlayerView content shows black
  and views need an explicit background.
- **Don't make audible test noise** on the dev machine: preview tests used a silent file
  served by `python3 -m http.server` on 127.0.0.1. Test videos were Big Buck Bunny (open-licensed, Blender).
- **Live SwiftUI views must not invalidate the window.** The Audio tab once used ~24% of a core on
  the main thread just for its meters. Three things fixed it: each meter is its own `LevelMeter`
  observed only by its `MeterView` (and it publishes only when what's drawn changes), the meter is
  drawn in a `Canvas` so a new level doesn't change any layout, and the window's
  `NSHostingController` has `sizingOptions = []` (otherwise every update re-measures the whole
  window). Profile with `sample <pid> 5` and look at the main thread.
- **`rm` on a shell variable gets blocked** by a safety check; use `"${VAR:?}"`.
- **Commits:** small and incremental, **no Co-Authored-By trailer**.
