#!/usr/bin/env python3
"""
One-off migration: copies the Voicemod sounds you had on your Stream Deck (with their
button artwork and page layout) into Soundboard's folder and writes a config.json.

Everything is read from local files Voicemod and the Elgato app already left on disk;
nothing is downloaded. Needs ffmpeg (macOS can't decode Voicemod's .ogg files).

    python3 tools/import_voicemod.py [--dry-run]
"""
import argparse
import base64
import glob
import json
import os
import re
import shutil
import subprocess
import sys

HOME = os.path.expanduser("~")
SUPPORT = os.path.join(HOME, "Library", "Application Support")
PROFILES = os.path.join(SUPPORT, "com.elgato.StreamDeck", "ProfilesV3")
VOICEMOD = os.path.join(SUPPORT, "VoicemodV3")
DEST = os.path.join(SUPPORT, "Soundboard")

PLAY_SOUND = "net.voicemod.windowsdesktop.pushtomemesound"
CENSOR = "net.voicemod.windowsdesktop.badlanguage"
AUDIO_EXT = (".ogg", ".mp3", ".wav", ".m4a", ".flac", ".aac")
IMAGE_EXT = {"image/png": "png", "image/jpeg": "jpg", "image/webp": "webp", "image/gif": "gif"}


def logged_paths():
    """Voicemod's log records `playSound id=<id>, path=<file>` for every sound you played."""
    paths = {}
    for log in sorted(glob.glob(os.path.join(VOICEMOD, "logs", "*.log"))):
        with open(log, errors="ignore") as f:
            for m in re.finditer(r"playSound id=([0-9a-f-]{36}), path=(.+?), repMode", f.read()):
                paths[m.group(1)] = m.group(2)
    return paths


def find_sound(sound_id, logged):
    for candidate in sorted(glob.glob(os.path.join(VOICEMOD, "cache", sound_id + "*"))):
        if candidate.lower().endswith(AUDIO_EXT) and os.path.getsize(candidate) > 0:
            return candidate
    path = logged.get(sound_id)
    if path and os.path.exists(path) and os.path.getsize(path) > 0:
        return path
    return None


def slug(text):
    return re.sub(r"[^A-Za-z0-9]+", "-", text).strip("-").lower() or "sound"


def nice_name(path):
    """'Prankster - 05 - Sad Trombone.ogg' -> 'Sad Trombone'; uuid-named files -> None."""
    stem = os.path.splitext(os.path.basename(path))[0]
    if re.match(r"^[0-9a-f]{8}-|^[0-9a-f]{64}$", stem):
        return None
    return stem.split(" - ")[-1].strip()


def profile_pages():
    """Yields (page_manifest, columns) in the order the pages appear on the device."""
    for profile in sorted(glob.glob(os.path.join(PROFILES, "*.sdProfile"))):
        with open(os.path.join(profile, "manifest.json")) as f:
            root = json.load(f)
        columns = 4  # Neo; Stream Deck positions are "column,row"
        for page_id in root.get("Pages", {}).get("Pages", []):
            manifest = os.path.join(profile, "Profiles", page_id.upper(), "manifest.json")
            if os.path.exists(manifest):
                with open(manifest) as f:
                    yield json.load(f), columns


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true", help="show what would be imported")
    args = parser.parse_args()

    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg and not args.dry_run:
        sys.exit("ffmpeg not found. Install it with: brew install ffmpeg")

    logged = logged_paths()
    sounds_dir = os.path.join(DEST, "sounds")
    icons_dir = os.path.join(DEST, "icons")
    os.makedirs(sounds_dir, exist_ok=True)
    os.makedirs(icons_dir, exist_ok=True)

    pages, converted, missing = [], {}, []
    for manifest, columns in profile_pages():
        keys = {}
        for controller in manifest.get("Controllers", []):
            for position, action in (controller.get("Actions") or {}).items():
                uuid = action.get("UUID", "")
                if uuid not in (PLAY_SOUND, CENSOR):
                    continue
                col, row = (int(x) for x in position.split(","))
                index = row * columns + col
                title = ((action.get("States") or [{}])[0].get("Title") or "").strip() or None

                if uuid == CENSOR:
                    keys[index] = {"label": title or "BLEEP", "action": "censor", "color": "#111827"}
                    continue

                settings = action.get("Settings") or {}
                sound_id = settings.get("selected-sound")
                if not sound_id:
                    continue
                button = {}
                if title:
                    button["label"] = title

                image = settings.get("button-images", "")
                m = re.match(r"data:(image/[a-z]+);base64,(.*)", image, re.S)
                if m and m.group(1) in IMAGE_EXT:
                    icon = f"{sound_id[:8]}.{IMAGE_EXT[m.group(1)]}"
                    if not args.dry_run:
                        with open(os.path.join(icons_dir, icon), "wb") as f:
                            f.write(base64.b64decode(m.group(2)))
                    button["image"] = icon

                source = find_sound(sound_id, logged)
                if not source:
                    missing.append(title or sound_id)
                    button["label"] = button.get("label") or "missing"
                    keys[index] = button
                    continue
                name = title or nice_name(source)
                if name:
                    button["name"] = name
                if sound_id not in converted:
                    filename = f"{slug(name) if name else sound_id[:8]}-{sound_id[:4]}.wav"
                    print(f"  {os.path.basename(source)} -> sounds/{filename}")
                    if not args.dry_run:
                        result = subprocess.run([ffmpeg, "-nostdin", "-loglevel", "error", "-y", "-i", source,
                                                 "-c:a", "pcm_s16le", os.path.join(sounds_dir, filename)])
                        if result.returncode != 0:
                            # Key keeps its artwork and shows ⚠︎ until this file exists.
                            if os.path.exists(os.path.join(sounds_dir, filename)):
                                os.remove(os.path.join(sounds_dir, filename))
                            missing.append(f"{name or sound_id} (save as sounds/{filename})")
                    converted[sound_id] = filename
                button["sound"] = converted[sound_id]
                keys[index] = button
        if keys:
            size = max(8, max(keys) + 1)
            pages.append([keys.get(i) for i in range(size)])

    if not pages:
        sys.exit("No Voicemod buttons found in your Stream Deck profiles.")

    config_path = os.path.join(DEST, "config.json")
    config = {}
    if os.path.exists(config_path):
        with open(config_path) as f:
            config = json.load(f)
    config["pages"] = pages

    print(f"\n{len(pages)} pages, {len(converted) - len(missing)} sounds imported.")
    if missing:
        print("Couldn't import (Voicemod's built-in library sounds are stored scrambled — save your own copy at the path shown):", ", ".join(missing))
    if args.dry_run:
        print("(dry run — nothing written)")
        return
    if os.path.exists(config_path):
        shutil.copy(config_path, config_path + ".bak")
    with open(config_path, "w") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"Wrote {config_path}")


if __name__ == "__main__":
    main()
