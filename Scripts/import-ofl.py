#!/usr/bin/env python3
"""Convert Open Fixture Library fixtures into RAYS fixture profiles.

Maintainer tool, never run by the app. Usage:

    git clone --depth 1 https://github.com/OpenLightingProject/open-fixture-library.git /tmp/ofl
    python3 -I Scripts/import-ofl.py /tmp/ofl --out Profiles/ofl [--manufacturers chauvet-dj,cameo] [--report]

Open Fixture Library: MIT licence, (c) Florian & Felix Edelmann and contributors.
Only channel maps are converted; no manual text or images are copied.

A mode is imported only when RAYS can drive it safely:
  * it has red, green and blue channels (single-purpose ColorIntensity channels);
  * every other channel is either a plain Intensity channel (-> dimmer), a white/amber/warm/cold
    white intensity, a shutter channel with an "Open" range (-> constant inside that range), or a
    channel whose function at DMX 0 is harmless (-> ignore, always sent as 0): no function, UV or
    other unsupported colours off, pan/tilt/zoom/focus positions, speeds, sound sensitivity...
  * a channel whose value 0 selects a colour macro, an effect, a programme, a strobe or anything
    else active makes the whole mode unusable, so it is skipped.
Moving heads, scanners, lasers, fog machines and similar fixtures are skipped entirely.
"""
import argparse
import json
import os
import re
import subprocess
import sys

CURATED = ["american-dj", "ayra", "beamz", "cameo", "chauvet-dj", "elation", "eurolite",
           "fun-generation", "martin", "showtec", "stairville", "varytec"]
INCLUDE_CATEGORIES = {"Color Changer", "Pixel Bar", "Blinder", "Dimmer", "Matrix", "Strobe"}
EXCLUDE_CATEGORIES = {"Moving Head", "Scanner", "Barrel Scanner", "Laser", "Smoke", "Hazer", "Fan",
                      "Flower", "Effect", "Stand"}
COLOR_KINDS = {"Red": "red", "Green": "green", "Blue": "blue", "White": "white", "Warm White": "white",
               "Cold White": "white", "Amber": "amber"}
OFF_AT_ZERO = {"UV", "Cyan", "Magenta", "Yellow", "Lime", "Indigo"}   # unsupported colours: kept at 0
HARMLESS_AT_ZERO = {"NoFunction", "Pan", "Tilt", "PanTiltSpeed", "Focus", "Zoom", "Iris", "BeamAngle",
                    "EffectSpeed", "EffectDuration", "SoundSensitivity", "Speed", "Time", "StrobeSpeed",
                    "StrobeDuration", "BeamPosition", "Frost"}
MAX_SEGMENTS = 64


def caps_of(channel):
    if "capability" in channel:
        c = dict(channel["capability"])
        c.setdefault("dmxRange", [0, 255])
        return [c]
    return channel.get("capabilities", [])


def cap_at(caps, value):
    for c in caps:
        lo, hi = c.get("dmxRange", [0, 255])
        if lo <= value <= hi:
            return c
    return None


def is_open_shutter(cap):
    return cap.get("type") == "ShutterStrobe" and cap.get("shutterEffect") == "Open"


class Unusable(Exception):
    pass


def classify(name, channel, resolved_from=None):
    """Returns (kind, value, reason) for one channel or raises Unusable."""
    caps = caps_of(channel)
    if not caps:
        raise Unusable(f"{name}: no capabilities")
    types = {c.get("type") for c in caps}
    if types == {"Intensity"}:
        return "dimmer", 0, None
    if types == {"ColorIntensity"}:
        colors = {c.get("color") for c in caps}
        if len(colors) == 1:
            color = colors.pop()
            if color in COLOR_KINDS:
                return COLOR_KINDS[color], 0, None
            if color in OFF_AT_ZERO:
                return "ignore", 0, f"{name} ({color}) kept at 0"
        raise Unusable(f"{name}: mixed colours")
    opens = [c for c in caps if is_open_shutter(c)]
    if "ShutterStrobe" in types and opens:
        lo, hi = opens[0].get("dmxRange", [0, 255])
        at0 = cap_at(caps, 0)
        if at0 is not None and is_open_shutter(at0):
            return "ignore", 0, f"{name} kept at 0 (shutter open)"
        return "constant", (lo + hi) // 2, f"{name} fixed at {(lo + hi) // 2} (shutter open)"
    at0 = cap_at(caps, 0)
    if at0 is None:
        raise Unusable(f"{name}: value 0 undefined")
    t = at0.get("type")
    if t in HARMLESS_AT_ZERO or (t == "ColorIntensity" and at0.get("color") in OFF_AT_ZERO):
        return "ignore", 0, f"{name} kept at 0"
    raise Unusable(f"{name}: value 0 is {t}")


def pixel_keys(fixture):
    m = fixture.get("matrix") or {}
    if "pixelKeys" in m:
        keys = []
        for z in m["pixelKeys"]:
            for y in z:
                for x in y:
                    if x is not None:
                        keys.append(x)
        return keys
    if "pixelCount" in m:
        x, y, z = (m["pixelCount"] + [1, 1, 1])[:3]
        if y == 1 and z == 1:
            return [str(i + 1) for i in range(x)]
        return [f"({i + 1}, {j + 1}, {k + 1})" for k in range(z) for j in range(y) for i in range(x)]
    return []


def expand(fixture, mode):
    """Mode channel list with matrix insertions expanded: [(name, channel, pixelIndex|None)]."""
    out = []
    keys = pixel_keys(fixture)
    templates = fixture.get("templateChannels", {})
    for entry in mode.get("channels", []):
        if entry is None:
            out.append((None, None, None))
        elif isinstance(entry, str):
            out.append((entry, None, None))
        elif isinstance(entry, dict) and entry.get("insert") == "matrixChannels":
            repeat = entry.get("repeatFor")
            if isinstance(repeat, list):
                pixels = repeat
            elif repeat in ("eachPixelABC",):
                pixels = sorted(keys)
            elif repeat in ("eachPixelXYZ", "eachPixelXZY", "eachPixelYXZ", "eachPixelYZX", "eachPixelZXY", "eachPixelZYX"):
                pixels = keys
            else:
                raise Unusable(f"matrix repeatFor {repeat}")
            order = entry.get("channelOrder", "perPixel")
            names = entry.get("templateChannels", [])
            pairs = ([(p, t) for p in pixels for t in names] if order == "perPixel"
                     else [(p, t) for t in names for p in pixels])
            for p, t in pairs:
                if t is None:
                    out.append((None, None, None))
                    continue
                name = t.replace("$pixelKey", p)
                template = templates.get(t)
                if template is None:
                    raise Unusable(f"template {t}")
                index = pixels.index(p) if p in keys or isinstance(repeat, list) else None
                out.append((name, template, index))
        else:
            raise Unusable(f"unsupported mode entry {entry!r}")
    return out


def lookup(fixture, name):
    chans = fixture.get("availableChannels", {})
    if name in chans:
        return "channel", chans[name]
    templates = fixture.get("templateChannels", {})
    keys = pixel_keys(fixture) + list((fixture.get("matrix") or {}).get("pixelGroups", {}).keys())
    for t, tc in templates.items():
        for k in keys:
            if t.replace("$pixelKey", k) == name:
                return "channel", tc
    every = dict(chans)
    for t, tc in templates.items():
        every[t] = tc
    for cname, ch in every.items():
        for alias in ch.get("fineChannelAliases", []):
            if alias == name or re.fullmatch(re.escape(alias).replace(re.escape("$pixelKey"), ".+"), name):
                return "fine", ch
    for cname, ch in chans.items():
        for cap in caps_of(ch):
            if name in (cap.get("switchChannels") or {}):
                return "switch", (cname, ch)
    raise Unusable(f"unknown channel {name}")


def convert_mode(fixture, mode, mode_channels):
    channels, notes = [], []
    switching_values = {}
    for name, template, pixel in mode_channels:
        if name is None:
            channels.append({"kind": "ignore", "value": 0})
            continue
        if template is not None:
            kind, value, reason = classify(name, template)
        else:
            what, ch = lookup(fixture, name)
            if what == "fine":
                channels.append({"kind": "ignore", "value": 0})
                continue
            if what == "switch":
                switch_name, switch_ch = ch
                at0 = cap_at(caps_of(switch_ch), switching_values.get(switch_name, 0))
                target = (at0 or {}).get("switchChannels", {}).get(name)
                if target is None:
                    raise Unusable(f"{name}: switch undefined at 0")
                what, resolved = lookup(fixture, target)
                if what == "fine":
                    channels.append({"kind": "ignore", "value": 0})
                    continue
                if what != "channel":
                    raise Unusable(f"{name}: nested switch")
                kind, value, reason = classify(name, resolved)
            else:
                kind, value, reason = classify(name, ch)
                if kind in ("ignore", "constant"):
                    switching_values[name] = value
        if reason:
            notes.append(reason)
        entry = {"kind": kind, "value": value}
        if pixel is not None and kind in ("red", "green", "blue", "amber", "white"):
            if pixel >= MAX_SEGMENTS:
                raise Unusable("too many pixels")
            entry["segment"] = pixel
        channels.append(entry)
    kinds = [c["kind"] for c in channels]
    if not {"red", "green", "blue"} <= set(kinds):
        raise Unusable("no RGB")
    if len(channels) > 512:
        raise Unusable("more than 512 channels")
    return channels, notes


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("ofl", help="path to an open-fixture-library checkout")
    ap.add_argument("--out", default="Profiles/ofl")
    ap.add_argument("--manufacturers", default=",".join(CURATED))
    ap.add_argument("--report", action="store_true", help="print skipped modes and reasons")
    args = ap.parse_args()

    fixtures_dir = os.path.join(args.ofl, "fixtures")
    manufacturers = json.load(open(os.path.join(fixtures_dir, "manufacturers.json")))
    try:
        commit = subprocess.run(["git", "-C", args.ofl, "rev-parse", "--short", "HEAD"],
                                capture_output=True, text=True, check=True).stdout.strip()
    except Exception:
        commit = "unknown"

    written = skipped_fixtures = 0
    skipped_modes = []
    for man in sorted(m for m in args.manufacturers.split(",") if m):
        mdir = os.path.join(fixtures_dir, man)
        if not os.path.isdir(mdir):
            print(f"warning: no manufacturer {man}", file=sys.stderr)
            continue
        man_name = manufacturers.get(man, {}).get("name", man)
        profiles_by_fixture = {}
        for fname in sorted(os.listdir(mdir)):
            if not fname.endswith(".json"):
                continue
            key = fname[:-5]
            fixture = json.load(open(os.path.join(mdir, fname)))
            cats = set(fixture.get("categories", []))
            if cats & EXCLUDE_CATEGORIES or not cats & INCLUDE_CATEGORIES:
                skipped_fixtures += 1
                continue
            profiles = []
            used_ids = set()
            for mode in fixture.get("modes", []):
                mode_name = mode.get("name") or mode.get("shortName") or "mode"
                try:
                    channels, notes = convert_mode(fixture, mode, expand(fixture, mode))
                except Unusable as e:
                    skipped_modes.append(f"{man}/{key} [{mode_name}]: {e}")
                    continue
                pid = f"ofl.{man}.{key}.{slug(mode.get('shortName') or mode_name)}"
                n = 2
                while pid in used_ids:
                    pid = f"ofl.{man}.{key}.{slug(mode.get('shortName') or mode_name)}-{n}"; n += 1
                used_ids.add(pid)
                note = (f"Converted from the Open Fixture Library (MIT, (c) Florian & Felix Edelmann and "
                        f"contributors), fixture {man}/{key} at commit {commit}. Not verified on hardware.")
                if notes:
                    note += " " + "; ".join(dict.fromkeys(notes)) + "."
                profiles.append({
                    "id": pid, "name": fixture.get("name", key), "manufacturer": man_name,
                    "mode": f"{mode_name} · {len(channels)} CH" if not re.search(r"\d+\s*ch", mode_name, re.I) else mode_name,
                    "isGeneric": False, "isVerified": False, "notes": note, "channels": channels,
                })
            if profiles:
                profiles_by_fixture[key] = profiles
            else:
                skipped_fixtures += 1
        if profiles_by_fixture:
            os.makedirs(os.path.join(args.out, man), exist_ok=True)
            for key, profiles in profiles_by_fixture.items():
                with open(os.path.join(args.out, man, f"{key}.json"), "w") as fh:
                    json.dump(profiles, fh, indent=2, ensure_ascii=False)
                    fh.write("\n")
                written += 1
    print(f"OFL {commit}: {written} fixtures written to {args.out}, {skipped_fixtures} fixtures skipped, "
          f"{len(skipped_modes)} modes skipped")
    if args.report:
        print("\n".join(skipped_modes))


if __name__ == "__main__":
    main()
