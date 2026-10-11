# Soundboard

A private soundboard for your Mac. Press a key and a sound effect plays into your
Zoom, Meet, Teams or Discord call, or your OBS stream, mixed live with your voice. You
hear it in your headphones too.

Play the keys from a **Stream Deck**, or from an **on-screen palette** that pops out of a
corner of your screen.

```
 your keys ──┐                ┌──▶ virtual mic ──▶ your meeting or stream
             ├──▶ Soundboard ─┤
 your mic  ──┘                └──▶ your headphones
```

## Features

- **Your own sound library.** Drop in audio files, give each sound a label, picture and
  colour, and lay them out on your keys.
- **Clip sounds from anywhere.** The Sound Editor cuts the exact moment you want from a
  file, a YouTube video or a soundboard website. Listen first, download only what you keep.
- **Cleaner mic.** Built-in noise removal (Apple's Voice Isolation) cleans up your voice
  without filtering out your sound effects.
- **A bleep button.** Hold it to mute your mic and play a censor tone.
- **A live display.** On the Stream Deck Neo, the screen shows the playing sound's
  waveform, or your voice level during a call.
- **Sync between your Macs.** Keep the same sounds and keys on every Mac, through a private
  repository you own.
- **Quiet when you're not using it.** Between calls, your mic and audio devices stay
  closed, so the mic indicator stays off and your Mac can sleep.

## Private by design

- **The app can't go online.** macOS itself blocks it from making any network connection.
- **Downloads are separate.** When you fetch a sound or sync, a small helper does just that
  one job and quits. The main app never touches the internet.
- **No tracking.** No analytics, no crash reporting, no accounts, no auto-updater.
- **Nothing but Apple's own frameworks**, so all of the code is in this repository for
  anyone to read.

## Get started

1. **Install BlackHole**, a free virtual audio cable that carries the mix to your other
   apps. It asks for your password, because it installs an audio driver.
   ```bash
   brew install blackhole-2ch
   ```
2. **Install Soundboard.** Download `Soundboard.dmg` from
   [Releases](https://github.com/danielebra/soundboard/releases) and drag it to
   Applications. The first time you open it, allow it in **System Settings → Privacy &
   Security**.
3. **Open Soundboard.** A grid icon appears in the menu bar. Allow microphone access when
   asked. If you use a Stream Deck, quit Elgato's Stream Deck app first.
4. **In your meeting or streaming app**, choose **BlackHole 2ch** as the microphone and
   turn off its own noise suppression (it would treat your sound effects as noise). Then
   turn on **Noise removal** in Soundboard's Audio tab instead.
   - **Zoom:** Settings → Audio → tick *Original sound for musicians*.
   - **Other apps:** turn the noise suppression or "background noise" setting off or to
     its lowest level.

Wear **headphones**, or your mic picks the sounds up from your speakers and everyone
hears them twice. To start Soundboard automatically, turn on **Open at Login** in the
Settings tab.

> When Soundboard isn't running, apps hear silence from BlackHole. Switch back to your
> real mic, or keep Soundboard open.

## Using Soundboard

Click the menu bar icon to open the Soundboard window.

### Sounds & Keys

Your library is on the left and your keys in the middle. Drag a sound onto a key, drag
keys around to rearrange them, and select a key or sound to change its name, picture,
colour and volume.

Each sound plays in one of two ways:

- **Toggle** (the default): press to play, press again to stop. By default, starting
  one stops the one that's playing.
- **Overlay**: every press plays another copy on top, which suits quick stings like an
  airhorn or a rimshot.

There are also two special keys: **Stop** stops everything, and **Bleep** (hold it) mutes
your mic and sends a censor tone instead. A green border shows what's playing.

Double-click a sound or key to play it to the call, like pressing it on the deck. To hear it
yourself first, right-click it in the library and choose **Preview**, or press **Preview**
in its settings: only you hear a preview, in your headphones.

### Sound Editor

Make a new sound from a file on your Mac, a YouTube link, or a soundboard website. Preview
it first, then download just the part you need, drag across the waveform to pick the
moment, and press **Save**. Clips get smooth fades and even volume, and a clip from a video
gets a frame as its key picture.

YouTube and other video sites need [yt-dlp](https://github.com/yt-dlp/yt-dlp)
(`brew install yt-dlp`). Only clip sounds you're allowed to use.

### Audio

Pick your mic and your headphones, set the volumes of your voice and the sounds, and
turn on noise removal. **Test input** records you so you can hear how you sound with and
without noise removal.

### Without a Stream Deck

Rest the pointer in the **bottom-left corner** of the screen and a palette of your keys
fans out. Click a key to play it. The palette never takes focus away from your meeting,
and folds away when you move on. You can change the corner, or turn it off, in the
Settings tab.

Or use the keyboard, from any app: **⌃⌥1** to **⌃⌥0** (number row or keypad) play keys 1 to 10 of the current
page, **⌃⌥[** and **⌃⌥]** turn the page, **⌃⌥.** stops all sounds and **⌃⌥P** shows the
palette. You can pick other modifier keys, or turn the shortcuts off, in the Settings tab.

### Sync between your Macs

1. Create an empty **private** repository (on GitHub, GitLab or your own server).
2. Make sure this Mac can reach it: `git ls-remote <address>` in Terminal should finish
   without asking for a password.
3. Paste the address into the **Sync** tab and press **Connect**. Do the same on your
   other Macs.

Your sounds and keys sync; audio devices and volumes stay per Mac. Soundboard syncs when
you make a change, open the app, or press **Sync Now**, never in the background. Edits
from different Macs are merged, and every version is kept in the repository's history.

## Hardware

Made for the **Stream Deck Neo**. The original Stream Deck, MK.2 and XL should work too,
but haven't been tested. No Stream Deck? Use the on-screen palette.

Stream Deck is a trademark of Elgato. This project isn't affiliated with or endorsed by Elgato.

## More

- [Editing the config files](docs/configuration.md) by hand.
- **Building from source:** `make install` builds the app and copies it to Applications.
  See [CLAUDE.md](CLAUDE.md) for how it works inside.
