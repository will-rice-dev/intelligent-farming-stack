<!-- SPDX-License-Identifier: AGPL-3.0-or-later
     Copyright (C) 2026 Intelligent Farming Foundation -->

# The farm stack's image list

Every release of this repository carries one file, `farm-stack-images.json`, attached to the GitHub
release beside its checksum, `farm-stack-images.json.sha256`. It names every image a **farm box**
runs, pinned by digest, with the environment each one needs. A consumer that installs the farm stack
somewhere other than this bench pins one release's list and installs nothing that is not on it.

It is published by `.github/workflows/publish.yml` and rendered by `scripts/farm-stack-images.py`
from its source, `release/farm-stack-images.in.json`, which is the file to edit.

## What is on it

The farm stack is what a box needs to land telemetry: ChirpStack and its database, Redis and broker,
the REST gateway and the gateway bridges, the provisioner, and the `farm` profile's four services.
The bench's other services — Leftenant, the event store and its API, Leadsman — are bench furniture
and not listed (`benchOnly` in the source). Each image is one of three kinds (`publisher`):

| `publisher` | Images | Where the digest comes from |
|---|---|---|
| `intelligent-farming-stack` | `stack-provisioner`, `farmdata-api` | Built from `provisioning/` and `farm-api/` and pushed by the release itself; tagged with the release version |
| `telemetry-bridge` | `telemetry-bridge`, `farm-postgres`, `farmdata-migrate` | Published by the telemetry-bridge repository on its own releases; the source pins the version and the release resolves its digest |
| `upstream` | ChirpStack, its REST gateway and gateway bridge, `postgres`, `redis`, `eclipse-mosquitto` | Resolved from the tag the bench runs. ChirpStack's digest is also pinned in the source, and a release fails if `4.19.2` no longer resolves to it |

`farmdata-api` is marked `optional`: nothing else in the stack depends on it.

## Shape

```json
{
  "$comment": "…licence notice…",
  "contract": "intelligent-farming/farm-stack-images",
  "schemaVersion": 1,
  "version": "0.5.0",
  "source": {
    "repository": "intelligent-farming/intelligent-farming-stack",
    "ref": "refs/tags/v0.5.0",
    "commit": "<40 hex>"
  },
  "requiredPlatforms": ["linux/amd64", "linux/arm64"],
  "images": [
    {
      "name": "chirpstack",
      "description": "ChirpStack network server",
      "publisher": "upstream",
      "services": ["chirpstack"],
      "image": {
        "name": "docker.io/chirpstack/chirpstack",
        "tag": "4.19.2",
        "digest": "sha256:cecb45bd…"
      },
      "platforms": ["linux/amd64", "linux/arm/v7", "linux/arm64"],
      "oneshot": false,
      "optional": false,
      "env": {
        "API_SECRET": { "required": true, "secret": true, "description": "…" },
        "REGION": { "required": true, "value": "us915_0", "description": "…" }
      }
    }
  ]
}
```

- **`image`** is `{name, tag, digest}`: a fully qualified repository, the tag it was resolved from,
  and the index digest. Pull by `name@digest`; the tag is for people.
- **`platforms`** are what that index is published for. Every image covers `requiredPlatforms`,
  or the release fails.
- **`services`** are the bench's compose services that run the image. One image can run as two
  services (the gateway bridge, once per packet-forwarder protocol).
- **`oneshot`**: runs to completion and exits 0 (the provisioner, `farmdata-migrate`).
  **`optional`**: the stack runs without it.
- **`env`** maps each variable the image needs in the stack to:
  - `required` — set it: the image has no default, or its default is a development value wrong
    for the stack.
  - `secret` — a credential. Supply it from a secret store, never as a literal.
  - `value` — the value the stack's wiring fixes (service names, ports, paths, switches). A
    consumer whose units use the same service names can use it as is.
  - `from` — the stack derives it at start rather than setting it: the bridge's ChirpStack API key
    and tenant come from the provisioner's `config.json`, and its default property from the
    projection seed.

  For upstream images whose configuration file the stack mounts (ChirpStack), the variables are the
  ones *this stack's* configuration interpolates. A consumer that authors its own configuration tree
  decides its own; the list does not describe mounts, ports, health checks or commands, which are the
  consumer's to author.

Fields may be added within a `schemaVersion`. A rename, a removal or a change of meaning is a new
`schemaVersion`.

## Pinning it

1. Download both files from the release and check the checksum:

   ```sh
   gh release download v0.5.0 -R intelligent-farming/intelligent-farming-stack \
     -p 'farm-stack-images.json*'
   sha256sum -c farm-stack-images.json.sha256
   ```

2. Verify it came from this repository's publish workflow:

   ```sh
   gh attestation verify farm-stack-images.json -R intelligent-farming/intelligent-farming-stack
   ```

   Every image built here carries the same kind of attestation in the registry
   (`gh attestation verify oci://ghcr.io/intelligent-farming/stack-provisioner@sha256:… -R …`).

3. Keep a copy, recording where it came from — the release tag, `source.commit` and the file's
   sha256. Map each image to your own unit by `image.name`, use `image.digest`, and cover every
   `required` variable.

4. In your CI, fail on drift: re-download the release you recorded, check its sha256 is still the
   one you pinned, and check that every image your units run is on the list at the listed digest.

## Cutting a release

1. If the telemetry bridge has released, set the three `telemetry-bridge` entries' `tag` in
   `release/farm-stack-images.in.json` to that version. The release fails if any of them is not
   published, for both platforms, and readable.
2. `scripts/farm-stack-images.py --check-only` must pass; the workflow runs it before pushing
   anything. `--allow-unpublished --output -` renders a draft with whatever the registries hold.
3. Publish a GitHub release for a tag `vX.Y.Z`. The workflow builds and pushes both images, renders
   the list and attaches it.
4. The first time only: set the `stack-provisioner` and `farmdata-api` packages on GHCR to public.
   They start private, and a consumer outside the organization cannot pull them until they are.

The bench itself still runs the bridge's images from a local build (`intelligent-farming/*:dev`,
see the README); the list is what a release vouches for.
