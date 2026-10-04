# stb, vendored

* Files: `stb_image.h` (v2.30) and `stb_image_write.h` (v1.16), with `LICENSE`
* Source: `https://github.com/nothings/stb`, commit
  `2c980bb59875b0d32144a71867fbdebb2f77cd20` (2026-08-02); stb has no
  releases, so the commit is the version
* SHA-256:
  * `stb_image.h` `594c2fe35d49488b4382dbfaec8f98366defca819d916ac95becf3e75f4200b3`
  * `stb_image_write.h` `cbd5f0ad7a9cf4468affb36354a1d2338034f2c12473cf1a8e32053cb6914a05`
  * `LICENSE` `bebfe904b14301657e4e5d655c811d51fd31b97c455b9cc2d8600d6bac6cff63`
* License: MIT or public domain, at the user's choice (`LICENSE`)

## What it is for

* `stb_image.h` decodes the MJPEG frames V4L2 hands the Linux backend
  (`capture/jpeg_decoder.cpp`), JPEG only, as `capture/stb_image_config.h`
  configures it. It is compiled into the product.
* `stb_image_write.h` encodes drawn barcodes as JPEG for the tests, the
  synthetic camera and the V4L2 loopback feeder
  (`platform/synthetic/jpeg_writer.cpp`). It is never linked into the product.

Nothing in the vendored files is modified. Both are compiled in files of
their own (`capture/stb_image_jpeg.c`, `platform/synthetic/
stb_image_write_impl.c`) with their warnings off.

## Updating

Download both headers and `LICENSE` from one commit, check their hashes into
this file, then run the native tests — `jpeg_test.cpp` checks decoding against
the encoder and against an ffmpeg-encoded UVC frame (`test/data/`), frames
without Huffman tables, truncation, and 1,500 corrupted frames — and the
sanitizer builds, where the corrupt-frame test means most. Things this
library relies on that a new version could change: `stbi_load_from_memory`
decoding a frame with no DHT segment *silently wrong* (which is why the
standard tables are inserted) and a truncated one silently as zeros (why
frames without EOI are refused), and `STBI_MAX_DIMENSIONS` being honoured
before allocation.
