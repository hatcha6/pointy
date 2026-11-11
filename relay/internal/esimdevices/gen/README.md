# The relay's eSIM device list

`../devices.tsv` is generated from three hand-kept inputs:

- `capable.txt`: the models that take eSIMs, by the name they are sold under.
- `apple.txt`: Apple's hardware identifiers, with a yes or no each.
- Google Play's device catalogue, which turns a name into the model codes
  phones report. `generate.py` downloads it.

When new phones come out, add their names to `capable.txt` (and new iPads to
`apple.txt`; a new iPhone needs nothing), then:

```bash
python3 relay/internal/esimdevices/gen/generate.py
```

It prints the names it found no model code for. Fix their spelling to the
catalogue's, or give the codes with `=` lines. Then run
`go test ./internal/esimdevices ./internal/relay` from `relay/`.
