# Release signing

The bundle's `sha256` proves the download was not corrupted. It proves nothing
about **who produced it**, because the relay serves the bundle and its hash from
the same place — so a relay compromise, or a leaked agent token, is remote code
execution on every shop with no second gate.

The signature is that second gate. It is made with a key that never touches the
relay, and `update-agent.sh` refuses a bundle that fails it.

We sign the 64-character sha256 hex rather than the multi-gigabyte zip: the same
binding to the content, but verification on a shop machine costs nothing. Ed25519
via `openssl`, which the installer already requires, so shops need no new tool.

## One-time setup

**1. Generate the keypair somewhere offline.** The private key must never be
committed, never be pasted into a chat, and never reach the relay.

```bash
openssl genpkey -algorithm ed25519 -out pointy-release.key
openssl pkey -in pointy-release.key -pubout -out pointy-release.pub
```

**2. Store the private key as a GitHub Actions secret** named
`POINTY_RELEASE_SIGNING_KEY`, pasting the full PEM including the BEGIN/END lines.
Keep an offline backup: losing it means every already-deployed shop stops
accepting updates until you ship a new public key by hand.

**3. Publish the public key to shops.** Put the PEM in `update-agent.sh`:

```bash
POINTY_RELEASE_PUBKEY="${POINTY_RELEASE_PUBKEY:-}"   # <- replace the default
```

with

```bash
POINTY_RELEASE_PUBKEY="${POINTY_RELEASE_PUBKEY:------BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEA…
-----END PUBLIC KEY-----}"
```

## Order of operations — this one matters

Verification is **fail-closed**: once a shop has a public key, a bundle with no
signature is refused. So the rollout order is fixed:

1. Ship a release that is **signed** (secret set) while shops still have an empty
   `POINTY_RELEASE_PUBKEY`. They ignore the signature; nothing changes.
2. Teach the relay to serve `bundle.signature` (base64, from the `.sig` file
   the release workflow produces) in the `/v1/agent/manifest` response.
3. Only then ship the public key to shops.

Doing 3 before 2 strands every shop on its current version: the agent asks for a
signature, the relay does not send one, and the update is refused. The refusal is
correct — it is also an outage of the update path, which is how you find out.

## Verifying a bundle by hand

For the physical-media install path, where an operator carries a USB stick:

```bash
openssl pkeyutl -verify -pubin -inkey pointy-release.pub -rawin \
  -in <(sha256sum pointy-onprem-*.zip | awk '{printf "%s", $1}') \
  -sigfile <(base64 -d < pointy-onprem-*.zip.sig)
```

`Signature Verified Successfully` and nothing else is acceptable.

Note that `install.sh` does **not** verify itself: it runs from inside the
already-extracted bundle, so anyone who could tamper with the zip could tamper
with the check. Verify the zip before extracting it, or rely on the auto-update
path, where the script doing the verifying was already on the machine.
