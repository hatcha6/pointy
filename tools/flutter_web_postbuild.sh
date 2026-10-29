#!/usr/bin/env bash
# Readies `flutter build web --wasm` output for a host the relay serves —
# cards.dftr.ly (cards/) and app.dftr.ly (frontend/) — whose users are on
# Libyan mobile networks and pay for every byte and every round trip:
#
#   1. The app's code gets its content's hash in its name (main.<hash>.dart.js,
#      main.<hash>.dart.wasm, flutter_bootstrap.<hash>.js), so the relay lets
#      browsers keep it for good (relay/internal/webbuild) and a return visit
#      fetches none of it.
#   2. index.html starts the downloads that would otherwise wait their turn:
#      the code this browser will run (WebAssembly on Chrome and Edge, the
#      JavaScript build elsewhere) and the fonts begin with the page, and the
#      connections to the rendering engine's and the fallback font's hosts
#      open at once.
#   3. Every file that compresses is stored beside a Brotli and a gzip copy,
#      which the relay sends to browsers that take them.
#
# Run from the app's directory after the build, with the build directory as
# the argument (default build/web): `make cards-web-build` and
# `make frontend-web-build` do both.
set -euo pipefail

web="${1:-build/web}"
cd "$web"

hash_of() { sha256sum "$1" 2>/dev/null | cut -c1-16 || shasum -a 256 "$1" | cut -c1-16; }

# 1. Fingerprints: each file the bootstrap names, then the bootstrap.
fingerprint() { # file, its key in the bootstrap's build config
  local file=$1 key=$2 base=${1%%.*} rest=${1#*.} named
  named="${base}.$(hash_of "$file").${rest}"
  mv "$file" "$named"
  sed -i.bak "s/\"${key}\":\"${file}\"/\"${key}\":\"${named}\"/" flutter_bootstrap.js
  rm flutter_bootstrap.js.bak
  grep -q "\"${key}\":\"${named}\"" flutter_bootstrap.js || {
    echo "flutter_web_postbuild: flutter_bootstrap.js no longer names ${file} as ${key}" >&2
    exit 1
  }
  echo "$named"
}
main_js=$(fingerprint main.dart.js mainJsPath)
main_wasm=$(fingerprint main.dart.wasm mainWasmPath)
main_mjs=$(fingerprint main.dart.mjs jsSupportRuntimePath)
boot_js="flutter_bootstrap.$(hash_of flutter_bootstrap.js).js"
mv flutter_bootstrap.js "$boot_js"

# 2. Early hints, and the bootstrap under its new name.
fonts=$(grep -o '"asset":"[^"]*IBMPlexSansArabic[^"]*"' assets/FontManifest.json |
  sed 's/"asset":"//; s/"$//')
python3 - "$boot_js" "$main_js" "$main_wasm" "$main_mjs" "$fonts" <<'PY'
import sys
boot, js, wasm, mjs, fonts = sys.argv[1:]
font_links = "".join(
    f'  <link rel="preload" href="assets/{font}" as="fetch" crossorigin="anonymous">\n'
    for font in fonts.split()
)
# The loader's own choice (flutter_bootstrap.js): WebAssembly where the
# browser is Chromium and runs WasmGC, JavaScript everywhere else.
hints = f"""  <link rel="preconnect" href="https://www.gstatic.com" crossorigin>
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
{font_links}  <script>
    (function () {{
      var chromium = navigator.vendor === "Google Inc." || navigator.userAgent.includes("Edg/");
      var wasmGC = false;
      try {{
        wasmGC = WebAssembly.validate(new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 95, 1, 120, 0]));
      }} catch (_) {{}}
      function hint(rel, href, as, cors) {{
        var link = document.createElement("link");
        link.rel = rel;
        link.href = href;
        if (as) link.as = as;
        if (cors) link.crossOrigin = "anonymous";
        document.head.appendChild(link);
      }}
      if (chromium && wasmGC) {{
        hint("preload", "{wasm}", "fetch", true);
        hint("modulepreload", "{mjs}");
      }} else {{
        hint("preload", "{js}", "script");
      }}
    }})();
  </script>
"""
page = open("index.html", encoding="utf-8").read()
assert page.count("</head>") == 1 and 'src="flutter_bootstrap.js"' in page
page = page.replace("</head>", hints + "</head>", 1)
page = page.replace('src="flutter_bootstrap.js"', f'src="{boot}"', 1)
open("index.html", "w", encoding="utf-8").write(page)
PY

# The web's copy of the Arabic font, trimmed to what the app can show: all
# of Arabic (shaping keeps every form it reaches), Latin-1, punctuation and
# currency; without TrueType hinting, which the web's renderer does not run.
# A quarter smaller per weight; the phone apps keep the whole font.
if command -v pyftsubset >/dev/null; then
  for font in $(grep -o '"asset":"[^"]*IBMPlexSansArabic[^"]*"' assets/FontManifest.json |
    sed 's/"asset":"//; s/"$//'); do
    pyftsubset "assets/${font}" --output-file="assets/${font}.subset" \
      --unicodes="U+0000-00FF,U+0600-06FF,U+0750-077F,U+08A0-08FF,U+FB50-FDFF,U+FE70-FEFF,U+2000-206F,U+20A0-20CF,U+2190-21FF,U+2212,U+25CC" \
      --layout-features='*' --name-IDs='*' --notdef-outline --no-hinting \
      --drop-tables+=meta 2>/dev/null
    mv "assets/${font}.subset" "assets/${font}"
  done
else
  echo "flutter_web_postbuild: pyftsubset (pip install fonttools) not found; fonts left whole" >&2
fi

# The service worker Flutter still writes is never registered (the loader
# is not given one); it would only be served stale.
rm -f flutter_service_worker.js

# 3. Compressed copies, best first, kept only where they are smaller.
find . -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.wasm' -o -name '*.json' -o -name '*.html' \
  -o -name '*.css' -o -name '*.svg' -o -name '*.ttf' -o -name '*.otf' -o -name '*.txt' \
  -o -name 'NOTICES' -o -name '*.bin' \) -print0 |
  while IFS= read -r -d '' file; do
    size=$(wc -c <"$file")
    brotli --quality=11 --force --keep --output="${file}.br" "$file"
    gzip -9 --no-name --keep --force --stdout "$file" >"${file}.gz"
    for copy in "${file}.br" "${file}.gz"; do
      [ "$(wc -c <"$copy")" -lt "$size" ] || rm "$copy"
    done
  done

echo "flutter_web_postbuild: ${main_wasm}, ${main_js}, ${boot_js}; $(find . -name '*.br' | wc -l | tr -d ' ') files compressed"
