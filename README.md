# Soundboard

A private, offline replacement for **Elgato Stream Deck software + Voicemod** on macOS.
Press a key on your Stream Deck, and the sound plays into Zoom (mixed with your mic)
and in your headphones.

```
 Stream Deck ──USB──▶ Soundboard.app ──▶ BlackHole 2ch ──▶ Zoom (as your mic)
                         ▲      │
          your mic ──────┘      └──────▶ your headphones (so you hear it too)
```

## Why it's private

- **No network access, enforced by macOS.** The app runs in the App Sandbox *without*
  the network entitlement, so the kernel refuses any connection it tries to make. You
  can check: `codesign -d --entitlements - /Applications/Soundboard.app`.
- **One small, separate helper does all downloading.** `SoundboardFetch` runs only when
  you press Fetch or Find Sounds. It downloads the link (using the open-source
  [yt-dlp](https://github.com/yt-dlp/yt-dlp) for video sites) and exits. The main app
  hands it the link through a file and never touches the network itself.
- **No third-party code.** About 4,500 lines of Swift on Apple frameworks only
  (IOKit, CoreAudio, AVFoundation, AppKit). No analytics, no crash reporter, no updater.
- **Only touches its own folder.** The sandbox allows writes to
  `~/Library/Application Support/Soundboard` and nothing else.
- **BlackHole** (the virtual audio cable) is open-source (GPL-3), driver-only, and has
  no network code: https://github.com/ExistentialAudio/BlackHole

## Setup

1. **Install BlackHole** (asks for your password, because it installs an audio driver):
   ```bash
   brew install blackhole-2ch
   ```
2. **Build and install the app:**
   ```bash
   ./build.sh --install
   ```
3. **Quit the Elgato Stream Deck app and Voicemod.** Elgato's app locks the device;
   Soundboard waits and takes over as soon as it's closed. Uninstall them if you like.
4. **Open Soundboard** from /Applications. A grid icon appears in the menu bar. Allow
   microphone access when asked.
5. **In Zoom → Settings → Audio**, set *Microphone* to **BlackHole 2ch**. Also set
   tick *Original sound for musicians* (leave *High-fidelity music mode* off, and keep
   *Echo cancellation* on if you don't wear headphones). Otherwise Zoom filters out the
   sound effects as "noise". Then turn on **Noise removal** in Soundboard's
   Audio tab: Soundboard cleans up your mic before mixing in the sounds, so you keep
   noise suppression without it eating the effects.

Use **Open at Login** in the menu (right-click the menu bar icon) to have it start
automatically.

> When Soundboard isn't running, Zoom gets silence from BlackHole. Switch Zoom back to
> your real mic, or keep Soundboard open.

### Importing your Voicemod sounds

```bash
python3 tools/import_voicemod.py
```

This reads the Stream Deck pages that had Voicemod buttons, copies each sound out of
Voicemod's local cache (converting `.ogg` to `.wav` with `ffmpeg`), keeps your button
artwork and layout, and writes `config.json`. It doesn't download anything.

Sounds from **Voicemod's own library** are stored scrambled on disk and can't be
imported. Those keys keep their artwork and show ⚠︎. Save your own copy of the sound
at the path the script prints.

## The Soundboard window

Click the menu bar icon (right-click it for the menu). It's one window with four
tabs, and a status strip along the bottom that shows the Stream Deck, the output Zoom
hears, and your mic.

### Sounds & Keys

- **Library (left):** every sound you've added, with its length and whether it's on the
  pad. Search it, rename sounds, or drop audio files onto it to add them.
- **Pad (middle):** your Stream Deck. Drag a sound from the library onto a key. Drag
  keys to swap them, onto the page arrows to move them, or back onto the library to
  take them off the pad. The sound stays in the library either way.
- **Inspector (right):** edits the selected key or sound: name, key cap (label, image,
  colour), play mode (tap to start/stop, or overlay), and volume. A sound's settings
  apply to every key it's on.

### Sound Editor

Make a new sound from any of three sources, then fine-tune it:

- **File on Disk:** choose a file, or drop any audio or video file onto the tab.
- **YouTube:** paste a link and press **Look Up**. You see the title, channel, length
  and thumbnail, with nothing downloaded yet. **Preview Audio** streams it with a seek
  bar. Then **Download to Edit** fetches either the whole video (a small 480p copy) or
  **just part of it**: mark the start and end from the preview position.
- **Website:** paste a soundboard page (or a direct link to an audio file) and press
  **Find Sounds**. It lists the sounds it finds, with their names where the site
  provides them. **▶** streams one to listen to; **Use** downloads it for editing.

Previews stream through the download helper straight to your speakers, and nothing is
saved. Downloads over 200 MB, and links that turn out to be web pages, are refused.

Then drag across the waveform to select the moment, adjust the handles, use **Zoom In**
for precision, and press **Play Selection** (P) to check it. **Save** adds it to the
library. If you started from a key (**Make a New Sound for This Key…**), it also goes on
that key. **Re-clip in Sound Editor…** on a sound replaces its audio.

Clips are saved as WAV with short fades so they don't click. By default they're evened
out in volume, and for videos a frame becomes the key image. Downloads are temporary,
and files macOS can't play (ogg, webm, opus) are converted with `ffmpeg`. YouTube and
other video sites need `yt-dlp` (`brew install yt-dlp`). Only clip sounds you're
allowed to use; some sites' terms forbid downloading.

### Audio

Laid out in the order the signal flows, with a live level meter at each stage:

- **Input**: your mic (or any input device), and whether it's routed to the output.
- **Input processing**: **Noise removal** runs Apple's voice isolation (the same engine as
  the macOS Voice Isolation mic mode) on the input only, before the sounds are mixed in.
  It runs on your Mac and adds about 56 ms of delay while it's on, none while off.
  **Strength** blends between the processed and the unprocessed input.
- **Test input**: record until you press Stop (2 minutes at most), then play it back
  processed or unprocessed. It plays on the monitor device only, never to the output.
  Change the settings and play again to hear the same recording with them.
- **Output**: the device the mix goes to (BlackHole 2ch, which your call app uses as its
  microphone), and the input and sounds volumes in that mix.
- **Monitor**: where you hear the sounds and input tests yourself.

Between calls Soundboard keeps every audio device closed, so macOS's mic indicator stays
off and your Mac can sleep. The mic and output open as soon as another app (Zoom) listens
to the output, or while this tab is open, and close a few seconds after. Pressing a key
outside a call opens your headphones for that sound (about a tenth of a second) and keeps
them open for 30 seconds after the last one.

### Settings

How you play the keys, and app-level options:

- **Stream Deck**: key brightness.
- **On-Screen Palette**: which screen corner opens the palette (see below), or Off.
- **Playback**: whether starting a sound stops the one that's playing.
- **General**: open Soundboard when you log in.

## Using it

- **Toggle keys** (the default): press to play, press again to stop.
- **Overlay keys**: every press plays another copy on top of whatever is already
  playing, so they work well for quick stings like an airhorn or a rimshot.
- A green border shows what's playing.
- **The two touch buttons under the Neo's screen** switch pages.
- **The Neo's screen** shows the playing sound's waveform, with how far it has got and
  the time left. Otherwise, while your input is on (during a call), it shows your voice level over the
  last few seconds. Green is what Zoom hears and grey is the raw input, so you can see
  noise removal working. Red means the input clipped. A green person-with-waves icon
  (Apple's Voice Isolation symbol) means noise removal is on. After a few seconds of silence the
  screen stops updating.
- **A `censor` key** (hold it) mutes your mic and sends a bleep instead.
- **A `stop` key** stops everything.

### Without a Stream Deck

Rest the pointer in the **bottom-left corner** of the screen for a moment and a small
palette fans out of it: the same keys as the pad, on the same page, with the page
switcher underneath when you have more than one. Click a key to play it; hold Bleep
like you would on the deck. The palette never takes focus, so Zoom stays in front, and
it folds away when the pointer leaves it or you click elsewhere. Menu → **Show Palette**
opens it too.

Change the corner (or turn it off) on the Settings tab. Pick one macOS isn't using for its
own Hot Corners (System Settings › Desktop & Dock › Hot Corners). On several displays,
only corners that don't touch another display count. The corner only watches where the
pointer is (no keyboard monitoring, and no Accessibility permission).

## Configuration

Everything below can be set in **Configure Keys…**. If you'd rather edit the file,
use Menu → **Edit config.json** (or **Open Soundboard Folder**). Changes apply as
soon as you save.

```jsonc
{
  "version": 2,
  "outputDevice": "BlackHole 2ch",       // what Zoom listens to
  "micDevice": "fifine Microphone",      // null = macOS default input
  "micPassthrough": true,                // route the input to the output
  "micVolume": 1.0,
  "noiseSuppression": true,              // noise removal on the input (not the sounds)
  "noiseSuppressionStrength": 1.0,       // 0…1 mix of processed vs unprocessed input
  "monitorDevice": null,                 // monitor device; null = default output
  "monitor": true,
  "monitorVolume": 0.5,
  "soundVolume": 0.8,                    // sounds volume in the output mix
  "stopOthers": true,                    // a toggle sound stops other toggle sounds
  "brightness": 70,
  "hotCorner": "bottomLeft",             // opens the on-screen palette: topLeft, topRight,
                                         // bottomLeft, bottomRight or off
  "library": [                           // every sound you've added, on the pad or not
    { "id": "airhorn", "name": "Airhorn", "file": "airhorn.mp3", "label": "Airhorn", "color": "#dc2626" },
    { "id": "meow", "name": "Meow", "file": "meow.wav", "image": "cat.png", "volume": 0.6, "mode": "overlay" }
  ],
  "pages": [
    [                                    // keys left→right, top→bottom; null = blank
      { "sound": "airhorn" },
      { "sound": "meow" },
      { "label": "STOP", "action": "stop", "color": "#dc2626" },
      { "label": "BLEEP", "action": "censor" },
      null
    ]
  ]
}
```

- **Library sounds:**
  - `file` is in `sounds/`, or an absolute or `~/` path. Supported formats are wav, mp3,
    m4a, aiff, caf and flac. Ogg isn't supported, so convert it with
    `ffmpeg -i in.ogg out.wav`.
  - `image` is in `icons/` (png, jpg, webp or gif), cropped to fill the key.
  - `label` is drawn on the key. `name` shows in the library and on the Neo's screen.
  - `color` is the key's background colour when it has no image.
  - `mode` is `"toggle"` (the default: tap to start, tap again to stop) or `"overlay"`
    (each tap layers another copy, and other sounds never cut it off).
- **Keys** point at a library sound by `id`, or are `stop` / `censor` keys with their own
  `label`, `image` and `color`. Taking a sound off a key never deletes it from the library.
- **Audio files dropped into `sounds/`** are added to the library automatically.

Use **headphones** for monitoring. If the sounds come out of your speakers, your mic
picks them up again and Zoom hears them twice.

## Hardware

Tested on the **Stream Deck Neo**. The original Stream Deck (v2), MK.2 and XL use the
same protocol and are included, but they're untested.

## Development

```bash
swift build -c release
.build/release/Soundboard --devices        # list audio devices
.build/release/Soundboard --preview out/   # render keys to PNGs
open build/Soundboard.app --args --settings          # open straight into Sounds & Keys
open build/Soundboard.app --args --audio             # open the Audio tab
open build/Soundboard.app --args --app-settings      # open the Settings tab
open build/Soundboard.app --args --clip <file|link>  # open the Sound Editor with a file or link
SOUNDBOARD_DEBUG=1 .build/release/Soundboard   # log raw key reports
```

| File | Purpose |
| --- | --- |
| `StreamDeck.swift` | USB HID protocol: key presses, JPEG key images, brightness |
| `AudioRouter.swift` | Audio engines: sounds + mic → BlackHole, sounds → headphones |
| `RingBuffer.swift` | Lock-free hand-off of mic audio between two device clocks |
| `KeyRenderer.swift` | Draws keys and the Neo info screen |
| `AppController.swift` | Menu bar, config loading, key → action wiring |
| `UI/MainWindow.swift` | The single window: tabs and status strip |
| `UI/SettingsView.swift` | Sounds & Keys tab: library, pad, inspector |
| `UI/ClipEditor.swift` | Sound Editor tab: sources, waveform trimming, export |
| `UI/SettingsTab.swift` | Settings tab: Stream Deck, palette corner, playback, open at login |
| `Palette.swift` | On-screen palette and its hot corner, for use without a Stream Deck |
| `Fetcher.swift`, `SoundboardFetch/` | Download helper for YouTube and websites (the only networked part) |
