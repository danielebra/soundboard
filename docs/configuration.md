# Editing the config files

Everything below can be set in the Soundboard window. If you'd rather edit the files,
use Menu → **Edit config.json** (or **Open Soundboard Folder**). Changes apply as
soon as you save. `config.json` holds the sounds and keys, which [sync](../README.md#sync-between-your-macs) between
Macs. `local.json` holds this Mac's audio settings, which don't sync:

```jsonc
// local.json
{
  "outputDevice": "BlackHole 2ch",       // what other apps use as their mic
  "micDevice": null,                     // null = macOS default input
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
  "syncRemote": null                     // Git repository to sync with (Sync tab)
}

// config.json
{
  "version": 2,
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
