# Test data

## `uvc_422_nodht_ean13.jpg`

One MJPEG frame as a UVC webcam sends it, for `jpeg_test.cpp`: 4:2:2
chroma, the standard (JPEG Annex K.3) Huffman tables, and no DHT segment.
Encoded by ffmpeg rather than stb_image_write, so the decoder is checked
against a second encoder, and against the subsampling the tests' own writer
cannot produce.

The picture is the tests' own drawn counter: `RenderScene` with EAN-13
`3600523434725`, 640x360, 2 px a module, tilted 8°, noise 4 — written out as
a PGM, then:

```sh
ffmpeg -i scene.pgm -vf format=yuvj422p -q:v 4 -huffman default -c:v mjpeg with_dht.jpg
```

and the one DHT segment (`FF C4`) removed from `with_dht.jpg` (22,597 bytes
→ 22,177).
