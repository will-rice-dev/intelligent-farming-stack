#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Intelligent Farming Foundation
#
# Renders the farm stack's image list, farm-stack-images.json, from its source
# release/farm-stack-images.in.json -- and refuses to when that source and
# docker-compose.yml disagree.
#
# The list is what a farm box installs from: every image the box runs, the
# registry reference it is published under, its digest, the platforms it is
# published for, and the environment it needs. A consumer pins one release's
# list by its own digest and installs nothing that is not on it. See
# docs/farm-stack-images.md for the shape and for how to pin it.
#
# Three kinds of image, by `publisher` in the source:
#   intelligent-farming-stack  built from a context in this repository by the
#                              publish workflow; its digest is passed in with
#                              --digest NAME=sha256:... and its tag is the
#                              release version.
#   telemetry-bridge           published by the telemetry-bridge repository on
#                              its own releases; the source pins the version,
#                              and the digest is resolved from the registry.
#   upstream                   third-party images; the digest is resolved from
#                              the tag the bench runs, unless the source pins
#                              one, in which case the tag must still resolve
#                              to it.
#
# Checks against docker-compose.yml (`docker compose --profile farm config`,
# with no .env, so the bench's own defaults are what is compared):
#   - every service the farm profile starts is listed, or named bench-only;
#   - an upstream image's reference is the one the bench runs;
#   - an image built here is built from the context the bench builds it from;
#   - every variable the bench sets on a listed service is listed (or named
#     bench-only), every required variable the list sets is set by the bench,
#     and a listed value is the bench's value.
#
# Usage:
#   scripts/farm-stack-images.py --check-only
#   scripts/farm-stack-images.py --version 0.5.0 \
#       --digest provisioner=sha256:... --digest farmdata-api=sha256:... \
#       --source-repository OWNER/REPO --source-ref refs/tags/v0.5.0 \
#       --source-commit SHA --output farm-stack-images.json
#   scripts/farm-stack-images.py --allow-unpublished --output /tmp/list.json
#
# --allow-unpublished is for a dry run before every image exists: an image
# that is not in its registry yet is written with "unpublished": true and no
# digest, the shape a consumer's manifest already uses for one. A release
# never passes it.
#
# Needs python3 (stdlib only) and docker with the compose and buildx plugins.

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONTRACT = "intelligent-farming/farm-stack-images"
SCHEMA_VERSION = 1
PUBLISHERS = ("intelligent-farming-stack", "telemetry-bridge", "upstream")
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$")


class ListError(Exception):
    pass


def run(argv):
    proc = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True)
    if proc.returncode != 0:
        raise ListError(f"{' '.join(argv[:4])} ... failed: {proc.stderr.strip() or proc.stdout.strip()}")
    return proc.stdout


# ── the source ────────────────────────────────────────────────────────────────


def load_source(path):
    source = json.loads(Path(path).read_text())
    errors = []
    if source.get("contract") != CONTRACT:
        errors.append(f"contract is {source.get('contract')!r}, expected {CONTRACT!r}")
    if source.get("schemaVersion") != SCHEMA_VERSION:
        errors.append(f"schemaVersion is {source.get('schemaVersion')!r}, expected {SCHEMA_VERSION}")
    seen_names, seen_services = set(), set()
    for entry in source.get("images", []):
        name = entry.get("name")
        where = f"image {name!r}"
        if not name or name in seen_names:
            errors.append(f"{where}: missing or duplicate name")
        seen_names.add(name)
        if entry.get("publisher") not in PUBLISHERS:
            errors.append(f"{where}: publisher must be one of {', '.join(PUBLISHERS)}")
        image = entry.get("image") or {}
        if not image.get("name"):
            errors.append(f"{where}: image.name is required")
        if entry.get("publisher") == "intelligent-farming-stack":
            if not (entry.get("build") or {}).get("context"):
                errors.append(f"{where}: an image built here needs build.context")
            if "tag" in image or "digest" in image:
                errors.append(f"{where}: an image built here takes its tag and digest from the release")
        elif not image.get("tag"):
            errors.append(f"{where}: image.tag is required")
        if "digest" in image and not DIGEST_RE.match(image["digest"]):
            errors.append(f"{where}: image.digest is not a sha256 digest")
        services = entry.get("services") or []
        if not services:
            errors.append(f"{where}: services is empty")
        for service in services:
            if service in seen_services:
                errors.append(f"{where}: service {service!r} is listed twice")
            seen_services.add(service)
        for var, spec in (entry.get("env") or {}).items():
            if not isinstance(spec, dict) or not isinstance(spec.get("required"), bool):
                errors.append(f"{where}: env {var} needs a boolean `required`")
                continue
            if spec.get("secret") and "value" in spec:
                errors.append(f"{where}: env {var} is a secret and must not carry a value")
    for service in source.get("benchOnly", []):
        if service in seen_services:
            errors.append(f"service {service!r} is both listed and bench-only")
    if errors:
        raise ListError("the source is malformed:\n  " + "\n  ".join(errors))
    return source


# ── agreement with docker-compose.yml ─────────────────────────────────────────


def normalize_reference(ref):
    """docker.io/library/postgres:14-alpine for postgres:14-alpine, and so on."""
    name, _, tag = ref.rpartition(":")
    if not name or "/" in tag:
        name, tag = ref, "latest"
    first = name.split("/", 1)[0]
    if "." not in first and ":" not in first and first != "localhost":
        name = f"docker.io/{name}" if "/" in name else f"docker.io/library/{name}"
    return f"{name}:{tag}"


def check_compose(source, compose_file):
    config = json.loads(
        run(
            [
                "docker", "compose", "-f", str(compose_file), "--env-file", "/dev/null",
                "--profile", "farm", "config", "--format", "json",
            ]
        )
    )
    services = config.get("services", {})
    errors = []
    listed = {s: e for e in source["images"] for s in e["services"]}
    bench_only = set(source.get("benchOnly", []))

    for service in sorted(services):
        if service not in listed and service not in bench_only:
            errors.append(
                f"compose service {service!r} runs under --profile farm but is neither listed "
                f"nor bench-only: decide whether a farm box runs it"
            )
    for service in sorted(set(listed) | bench_only):
        if service not in services:
            errors.append(f"service {service!r} is named in the source but not in the compose file")

    for entry in source["images"]:
        for service in entry["services"]:
            spec = services.get(service)
            if spec is None:
                continue
            where = f"{entry['name']} (service {service})"
            publisher = entry["publisher"]
            if publisher == "upstream":
                want = f"{entry['image']['name']}:{entry['image']['tag']}"
                got = normalize_reference(spec.get("image", ""))
                if got != want:
                    errors.append(f"{where}: the bench runs {got}, the source lists {want}")
            elif publisher == "intelligent-farming-stack":
                context = (spec.get("build") or {}).get("context", "")
                want = (ROOT / entry["build"]["context"]).resolve()
                if not context or Path(context).resolve() != want:
                    errors.append(f"{where}: the bench builds from {context or 'nothing'}, the source from {want}")
            elif publisher == "telemetry-bridge":
                # The bench runs these from a local build of the bridge until it
                # moves to the published references, so only the repository name
                # is comparable.
                got = spec.get("image", "").split("@")[0].rpartition(":")[0].rsplit("/", 1)[-1]
                want = entry["image"]["name"].rsplit("/", 1)[-1]
                if got != want:
                    errors.append(f"{where}: the bench runs {spec.get('image')!r}, not a build of {want}")

            env = spec.get("environment") or {}
            listed_env = entry.get("env") or {}
            bench_env = set(entry.get("benchOnlyEnv") or [])
            for var in sorted(env):
                if var not in listed_env and var not in bench_env:
                    errors.append(f"{where}: the bench sets {var}, which the source neither lists nor names bench-only")
            for var, var_spec in listed_env.items():
                if var_spec["required"] and "from" not in var_spec and var not in env:
                    errors.append(f"{where}: {var} is required but the bench does not set it")
                if "value" in var_spec and var in env and str(env[var]) != var_spec["value"]:
                    errors.append(f"{where}: {var} is {env[var]!r} on the bench, {var_spec['value']!r} in the source")
    if errors:
        raise ListError("the source and docker-compose.yml disagree:\n  " + "\n  ".join(errors))


# ── the registry ──────────────────────────────────────────────────────────────


def inspect(reference):
    """(digest, platforms) of a published image or index, or None if absent."""
    proc = subprocess.run(
        ["docker", "buildx", "imagetools", "inspect", reference, "--format", "{{json .Manifest}}"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return None
    manifest = json.loads(proc.stdout)
    platforms = []
    for child in manifest.get("manifests") or []:
        platform = child.get("platform") or {}
        if platform.get("os") in (None, "unknown"):
            continue  # attestation manifests
        label = f"{platform['os']}/{platform['architecture']}"
        if platform.get("variant"):
            label += f"/{platform['variant']}"
        platforms.append(label)
    return manifest["digest"], sorted(set(platforms))


def covers(platforms, required):
    # linux/arm64 is published as linux/arm64 or linux/arm64/v8.
    return all(p in platforms or f"{p}/v8" in platforms for p in required)


def resolve(source, version, built_digests, allow_unpublished):
    images, errors = [], []
    required_platforms = source.get("requiredPlatforms", [])
    for entry in source["images"]:
        image = dict(entry["image"])
        where = entry["name"]
        if entry["publisher"] == "intelligent-farming-stack":
            image["tag"] = version
            digest = built_digests.pop(entry["name"], None)
            reference = f"{image['name']}@{digest}" if digest else None
        elif "digest" in image:
            digest = image["digest"]
            reference = f"{image['name']}:{image['tag']}"
        else:
            digest = None
            reference = f"{image['name']}:{image['tag']}"

        found = inspect(reference) if reference else None
        out = {
            "name": entry["name"],
            "description": entry.get("description", ""),
            "publisher": entry["publisher"],
            "services": entry["services"],
        }
        if found is None:
            if not allow_unpublished:
                errors.append(f"{where}: {reference or image['name'] + ' (no --digest given)'} is not in its registry")
            image.pop("digest", None)
            image["unpublished"] = True
            out["image"] = image
        else:
            got, platforms = found
            if digest and got != digest:
                errors.append(
                    f"{where}: {reference} resolves to {got}, but {digest} is pinned -- the tag "
                    "moved upstream; re-pin it deliberately in the source"
                )
            if not covers(platforms, required_platforms):
                errors.append(
                    f"{where}: published for {', '.join(platforms) or 'no platform'}, "
                    f"needs {', '.join(required_platforms)}"
                )
            image["digest"] = got
            out["image"] = image
            out["platforms"] = platforms
        out["oneshot"] = bool(entry.get("oneshot", False))
        out["optional"] = bool(entry.get("optional", False))
        out["env"] = entry.get("env") or {}
        images.append(out)
    for name in built_digests:
        errors.append(f"--digest {name}=... names no image built here")
    if errors:
        raise ListError("cannot render the list:\n  " + "\n  ".join(errors))
    return images


# ── main ──────────────────────────────────────────────────────────────────────


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", default=str(ROOT / "release" / "farm-stack-images.in.json"))
    parser.add_argument("--compose", default=str(ROOT / "docker-compose.yml"))
    parser.add_argument("--check-only", action="store_true", help="check the source against the compose file and stop")
    parser.add_argument("--version", default="0.0.0-dev", help="the release version, without the leading v")
    parser.add_argument("--digest", action="append", default=[], metavar="NAME=sha256:...",
                        help="the digest an image built here was pushed with")
    parser.add_argument("--source-repository", default="intelligent-farming/intelligent-farming-stack")
    parser.add_argument("--source-ref", default="")
    parser.add_argument("--source-commit", default="")
    parser.add_argument("--allow-unpublished", action="store_true")
    parser.add_argument("--output", default="-")
    args = parser.parse_args()

    try:
        source = load_source(args.source)
        check_compose(source, args.compose)
        if args.check_only:
            print(f"farm-stack-images: the source agrees with {Path(args.compose).name} ({len(source['images'])} images)")
            return 0
        if not VERSION_RE.match(args.version):
            raise ListError(f"--version {args.version!r} is not a semantic version without a leading v")
        built = {}
        for pair in args.digest:
            name, _, digest = pair.partition("=")
            if not DIGEST_RE.match(digest):
                raise ListError(f"--digest {pair!r} is not NAME=sha256:<64 hex>")
            built[name] = digest
        images = resolve(source, args.version, built, args.allow_unpublished)
    except ListError as err:
        print(f"farm-stack-images: {err}", file=sys.stderr)
        return 1

    document = {
        "$comment": (
            "The images a farm box runs, their digests and the environment each needs, as of "
            f"release {args.version} of {args.source_repository}. Pin this file by its sha256 and "
            "install nothing that is not on it; docs/farm-stack-images.md in that repository says how. "
            "SPDX-License-Identifier: AGPL-3.0-or-later. Copyright (C) 2026 Intelligent Farming Foundation."
        ),
        "contract": CONTRACT,
        "schemaVersion": SCHEMA_VERSION,
        "version": args.version,
        "source": {
            "repository": args.source_repository,
            "ref": args.source_ref,
            "commit": args.source_commit,
        },
        "requiredPlatforms": source.get("requiredPlatforms", []),
        "images": images,
    }
    text = json.dumps(document, indent=2, ensure_ascii=False) + "\n"
    if args.output == "-":
        sys.stdout.write(text)
    else:
        Path(args.output).write_text(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
