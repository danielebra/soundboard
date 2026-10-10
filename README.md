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
- **One small, separate helper does the YouTube downloads.** `SoundboardFetch` (about
  150 lines) runs only when you press Fetch. It runs the open-source
  [yt-dlp](https://github.com/yt-dlp/yt-dlp) and exits. The main app hands it the link
  through a file and never touches the network itself.
- **No third-party code.** About 2,900 lines of Swift on Apple frameworks only
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
   *Background noise suppression* to **Low** (or tick *Original sound for musicians*),
   otherwise Zoom filters out the sound effects as "noise".

Use **Open at Login** in the menu to have it start automatically.

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

## Customising keys

Menu bar icon → **Configure Keys…** (⌘,) opens a window that mirrors your Stream Deck:

- Click a key to set what it does (a sound, Stop All, or a hold-to-bleep key), its
  label, its image or background colour, how it plays (tap to start/stop, or overlay)
  and its volume.
- Drag a sound or image file from Finder onto a key, or drag one key onto another to
  swap them.
- Add or delete pages, and choose your mic, output and monitor devices and volumes.

Changes are saved to `config.json` and appear on the Stream Deck straight away.

## Clipping sounds from YouTube

**New Sound from YouTube…** (in the menu, or **Clip from YouTube…** on a key):

1. Paste a link and press **Fetch**. A small 480p copy downloads; this is the only step
   that uses the internet. You can also **Open File…** for a video or audio file you
   already have.
2. Drag across the waveform to select the moment. Drag the handles to adjust, use
   **Zoom In** for fine-tuning, and press **Play Selection** (or P) to hear it.
3. Name it and press **Save Sound**. The clip is saved as a WAV with short fades so it
   doesn't click. By default it's evened out in volume, and the video frame becomes the
   key's image.

The downloaded video is deleted when you close the window. This needs `yt-dlp`:
`brew install yt-dlp`. Only clip things you're allowed to use; downloading from
YouTube may be against its terms.

## Using it

- **Toggle keys** (the default): press to play, press again to stop.
- **Overlay keys**: every press plays another copy on top of whatever is already
  playing, so they work well for quick stings like an airhorn or a rimshot.
- A green border shows what's playing.
- **The two touch buttons under the Neo's screen** switch pages. The screen shows
  what's playing, the page, and whether your mic is live.
- **A `censor` key** (hold it) mutes your mic and sends a bleep instead.
- **A `stop` key** stops everything.

## Configuration

Everything below can be set in **Configure Keys…**. If you'd rather edit the file,
use Menu → **Edit config.json** (or **Open Soundboard Folder**). Changes apply as
soon as you save.

```jsonc
{
  "outputDevice": "BlackHole 2ch",       // what Zoom listens to
  "micDevice": "fifine Microphone",      // null = macOS default input
  "micPassthrough": true,                // mix your mic into the output
  "micVolume": 1.0,
  "monitorDevice": null,                 // where you hear sounds; null = default output
  "monitor": true,
  "monitorVolume": 0.5,
  "soundVolume": 0.8,                    // sound level that Zoom hears
  "stopOthers": true,                    // a toggle sound stops other toggle sounds
  "brightness": 70,
  "pages": [
    [                                    // keys left→right, top→bottom; null = blank
      { "label": "Airhorn", "sound": "airhorn.mp3", "color": "#dc2626" },
      { "image": "cat.png", "sound": "meow.wav", "name": "Meow", "volume": 0.6, "mode": "overlay" },
      { "label": "STOP", "action": "stop" },
      { "label": "BLEEP", "action": "censor" },
      null
    ]
  ]
}
```

- `sound` is a file in `sounds/`, or an absolute or `~/` path. Supported formats are
  wav, mp3, m4a, aiff, caf and flac. Ogg isn't supported, so convert it with
  `ffmpeg -i in.ogg out.wav`.
- `image` is a file in `icons/` (png, jpg, webp or gif), cropped to fill the key.
- `label` is drawn on the key. `name` is shown on the Neo's screen while the sound plays.
- `color` is the key's background colour when it has no image.
- `mode` is `"toggle"` (the default: tap to start, tap again to stop) or `"overlay"`
  (each tap layers another copy, and the sound is never cut off by other sounds).

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
open build/Soundboard.app --args --settings          # open straight into the settings window
open build/Soundboard.app --args --clip <file|link>  # open the clip editor
SOUNDBOARD_DEBUG=1 .build/release/Soundboard   # log raw key reports
```

| File | Purpose |
| --- | --- |
| `StreamDeck.swift` | USB HID protocol: key presses, JPEG key images, brightness |
| `AudioRouter.swift` | Audio engines: sounds + mic → BlackHole, sounds → headphones |
| `RingBuffer.swift` | Lock-free hand-off of mic audio between two device clocks |
| `KeyRenderer.swift` | Draws keys and the Neo info screen |
| `AppController.swift` | Menu bar, config loading, key → action wiring |
| `UI/SettingsView.swift` | Key customisation window |
| `UI/ClipEditor.swift` | Waveform clip selection and export |
| `Fetcher.swift`, `SoundboardFetch/` | YouTube download helper (the only networked part) |
