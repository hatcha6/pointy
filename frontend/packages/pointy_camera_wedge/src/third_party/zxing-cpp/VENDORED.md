# zxing-cpp, vendored

* Version: **3.1.1** (released 2026-07-29)
* Source: `https://github.com/zxing-cpp/zxing-cpp/releases/download/v3.1.1/zxing-cpp-3.1.1.tar.gz`
  (the release asset, not GitHub's auto-generated archive, which lacks the
  submodules)
* SHA-256 of that tarball: `c3c02c29c0b519de7bd4e25b376e606e87f0761befd1282815642a2246613d14`
* License: Apache-2.0 (`LICENSE`)

## What was taken

`LICENSE` and `core/` — its `CMakeLists.txt`, the `*.in` templates it
configures, and `src/` — **except `core/src/libzint/`**, the bundled Zint
encoder, which is only compiled for the "new" writer API (`ZXING_WRITERS`
`NEW`/`ON`/`BOTH`). This library builds readers only for the product and the
dependency-free "old" writers for its tests, so libzint is never referenced.

Nothing in the vendored files is modified.

## Updating

Download the release asset, check its hash, replace `core/` the same way
(without `libzint/`), then run the native tests (`make
frontend-camera-wedge-test`, which also exercises UPC-A/UPC-E reporting and
every orientation) and a sanitizer build. Things this library depends on that
a new version could change: `BarcodeFormat` names (`src/vision/
barcode_reader.cpp`), UPC normalisation, and the CMake options set in
`../../CMakeLists.txt`.
