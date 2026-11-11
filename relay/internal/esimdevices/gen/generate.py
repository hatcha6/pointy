#!/usr/bin/env python3
"""Builds ../devices.tsv, the relay's own list of devices that take eSIMs.

    python3 generate.py [supported_devices.csv]

Without a path it downloads Google Play's device catalogue, which maps the name
a phone is sold under to the model code it reports. capable.txt says which
names take eSIMs; apple.txt is Apple's identifiers, kept by hand. Names with no
match in the catalogue are printed: fix their spelling, or give their codes
with "=" lines.
"""
import csv
import io
import pathlib
import re
import sys
import urllib.request

HERE = pathlib.Path(__file__).parent
PLAY = "https://storage.googleapis.com/play_public/supported_devices.csv"

# The brands Google Play files a maker's phones under.
BRANDS = {
    "xiaomi": {"xiaomi", "redmi", "poco", "blackshark"},
    "oppo": {"oppo"},
    "oneplus": {"oneplus"},
    "realme": {"realme"},
    "vivo": {"vivo", "iqoo"},
    "zte": {"zte", "nubia"},
    "nokia": {"nokia", "hmd", "hmdglobal"},
    "hmd": {"hmd", "hmdglobal", "nokia"},
    "tcl": {"tcl", "tctalcatel"},
    "hammer": {"hammer", "myphonepl", "myphone"},
}
# Words that never tell two models apart.
NOISE = ("samsung", "xiaomi", "oppo", "vivo", "honor", "huawei", "motorola",
         "sony", "sharp", "nokia", "google", "asus", "tcl", "tmobile", "nothing",
         "tecno", "infinix", "oneplus")


def squash(text):
    return re.sub(r"[^a-z0-9+]", "", text.lower()).replace("+", "plus")


def key(name):
    """A sold-under name, loosely: no case, spaces, brand or "5G"."""
    text = squash(name).replace("porschedesign", "")
    for word in NOISE:
        if text.startswith(word) and len(text) > len(word):
            text = text[len(word):]
    return re.sub(r"5g", "", text)


def regional_no(brand, code):
    """Variants of a capable model that are sold without the eSIM."""
    if brand == "Samsung":
        # SM-S9110: mainland China, Hong Kong and Taiwan. On a tablet the
        # trailing 0 is the Wi-Fi model, which has no eSIM either.
        return re.fullmatch(r"SM-[A-Z]\d{3}0", code) is not None
    return False


def regional_unknown(brand, code):
    """Home-market variants nobody lists: left out, so the relay says nothing."""
    if brand == "Samsung":
        # Japan's carrier models (SC-51A, SCG01): only some have the eSIM.
        if re.match(r"SC[-GVT5]", code):
            return True
        # North America's S20, Note20, Z Flip and Z Fold2 shipped without it.
        if re.fullmatch(r"SM-(G98\d|N98\d|F700|F707|F916)(U|U1|W)", code):
            return True
        # Korea's models before the Z Fold4 and S23 had none.
        return re.fullmatch(r"SM-(G98|G99|N98|S90|F70|F71|F90|F91|F92)\dN", code) is not None
    if brand in ("Oppo", "OnePlus"):
        return re.fullmatch(r"P[A-Z]{2}[A-Z0-9]\d{2}", code) is not None
    if brand == "vivo":
        return re.fullmatch(r"V\d{4}[A-Z]{1,2}", code) is not None
    if brand == "Honor":
        return re.search(r"-AN\d\d", code) is not None
    if brand == "Xiaomi":
        return re.fullmatch(r"\d{5,}[A-Z0-9]*C", code) is not None
    return False


def main():
    if len(sys.argv) > 1:
        raw = pathlib.Path(sys.argv[1]).read_bytes()
    else:
        raw = urllib.request.urlopen(PLAY, timeout=120).read()
    text = raw.decode("utf-16") if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else raw.decode("utf-8-sig")
    play = {}  # (brand, name key) -> {model code}
    for row in list(csv.reader(io.StringIO(text)))[1:]:
        if len(row) < 4 or not row[1] or not row[3]:
            continue
        # "Reno14 F 5G/Reno14 FS 5G": one row, two names.
        for sold_as in row[1].split("/"):
            play.setdefault((squash(row[0]), key(sold_as)), set()).add(row[3].strip())

    entries = {}  # code -> (brand, name, supported)
    names = []    # (brand, name, supported)
    unmatched = []
    given = set()  # (brand, name) with codes of their own

    def put(code, brand, name, supported):
        known = entries.get(code)
        # A code two names share keeps the yes: the no is about the other model.
        if known is None or (supported and not known[2]):
            entries[code] = (brand, name, supported)

    for line in (HERE / "capable.txt").read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("="):
            code, brand, name = (part.strip() for part in line[1:].split("|"))
            entries[code] = (brand, name, True)
            given.add((brand, name))
            continue
        supported = not line.startswith("!")
        brand, name = (part.strip() for part in line.lstrip("!").split(":", 1))
        names.append((brand, name, supported))
        codes = set()
        for filed in BRANDS.get(squash(brand), {squash(brand)}):
            codes |= play.get((filed, key(name)), set())
        if not codes and supported and (brand, name) not in given:
            unmatched.append(f"{brand}: {name}")
        for code in codes:
            if not supported:
                put(code, brand, name, False)
            elif regional_no(brand, code):
                put(code, brand, name, False)
            elif not regional_unknown(brand, code):
                put(code, brand, name, True)

    for line in (HERE / "apple.txt").read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        code, name, verdict = (part.strip() for part in line.split("|"))
        put(code, "Apple", name, verdict == "yes")
        # "iPhone" and "iPhone SE" name more than one model.
        if code.startswith("iPhone") and name not in ("iPhone", "iPhone SE"):
            names.append(("Apple", name, verdict == "yes"))

    out = ["# Generated by gen/generate.py: do not edit. kind, key, brand, name, takes eSIMs."]
    for code in sorted(entries):
        brand, name, supported = entries[code]
        out.append("\t".join(("model", code, brand, name, "1" if supported else "0")))
    seen = set()
    for brand, name, supported in names:
        if (brand, name) in seen:
            continue
        seen.add((brand, name))
        out.append("\t".join(("name", name, brand, name, "1" if supported else "0")))
    (HERE.parent / "devices.tsv").write_text("\n".join(out) + "\n")
    print(f"{len(entries)} model codes, {len(seen)} names")
    if unmatched:
        print("no model code found for:\n  " + "\n  ".join(unmatched))


if __name__ == "__main__":
    main()
