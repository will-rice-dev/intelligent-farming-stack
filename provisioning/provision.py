#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Intelligent Farming Foundation
#
# One-shot provisioner for the intelligent-farming-stack bench.
#
# ChirpStack's REST gateway (chirpstack-rest-api) deliberately does NOT expose
# the InternalService (login) or ApiKeyService (api-keys) — only resource
# services like TenantService. So bootstrap auth + key minting go over gRPC
# (chirpstack:8080) using the chirpstack-api package; the minted tenant key is
# then handed to the REST-based tooling (Leftenant, attach-codecs.py).
#
# After ChirpStack is up it:
#   1. logs in over gRPC as the bootstrap admin, first rotating the password
#      ChirpStack seeded it with (admin) to CHIRPSTACK_ADMIN_PASSWORD when that
#      is set to anything else,
#   2. ensures an "Intelligent Farming" tenant exists,
#   3. mints a tenant-scoped API key (once; reused on later runs),
#   4. writes the connection artifacts the rest of the stack consumes:
#        /shared/config.json              -> Leftenant runtime config (browser-facing URLs)
#        /shared/leftenant.env            -> the same values as an env file
#        /shared/leftenant-connection.txt -> REST URL/API key/Tenant UUID format
#                                            that intelligent-farming-hub/codecs/attach-codecs.py reads
#   5. best-effort: if codec .js files are mounted at /codecs, runs attach-codecs.py.

import json
import os
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import urlparse

import grpc
from chirpstack_api import api
from google.protobuf import empty_pb2

# ── Config (from the environment; see docker-compose.yml) ────────────────────
GRPC_TARGET = os.environ.get("CHIRPSTACK_GRPC", "chirpstack:8080")
ADMIN_EMAIL = os.environ.get("CHIRPSTACK_ADMIN_EMAIL", "admin")
ADMIN_PASSWORD = os.environ.get("CHIRPSTACK_ADMIN_PASSWORD", "admin")
# The password ChirpStack seeds its admin user with on first boot. When
# CHIRPSTACK_ADMIN_PASSWORD is anything else, the seeded one is rotated away.
ADMIN_INITIAL_PASSWORD = os.environ.get("CHIRPSTACK_ADMIN_INITIAL_PASSWORD", "admin")
TENANT_NAME = os.environ.get("TENANT_NAME", "Intelligent Farming")
API_KEY_NAME = os.environ.get("API_KEY_NAME", "intelligent-farming-stack")

# Internal REST endpoint handed to attach-codecs.py (compose network).
REST_URL_INTERNAL = os.environ.get("CHIRPSTACK_REST_URL", "http://chirpstack-rest-api:8090").rstrip("/")

# Browser-facing URLs baked into config.json (how the operator's browser, NOT
# the compose network, reaches ChirpStack). Override for non-localhost hosts.
PUBLIC_CHIRPSTACK_URL = os.environ.get("LEFTENANT_CHIRPSTACK_URL", "http://localhost:8090")
PUBLIC_MQTT_URL = os.environ.get("LEFTENANT_MQTT_URL", "ws://localhost:9001")


def _default_bridge_host():
    """Host a physical gateway forwards LoRaWAN packets to (ChirpStack Gateway
    Bridge, published on the host at :1700 / :3001). A gateway can never reach
    `localhost`, so this must be the bench's LAN IP. Prefer an explicit override
    (setup.sh auto-detects the host IP into it); otherwise reuse the host from the
    browser-facing ChirpStack URL, which the operator already sets for LAN access."""
    override = os.environ.get("LEFTENANT_GATEWAY_BRIDGE_HOST", "").strip()
    if override:
        return override
    return urlparse(PUBLIC_CHIRPSTACK_URL).hostname or ""


PUBLIC_GATEWAY_BRIDGE_HOST = _default_bridge_host()

SHARED_DIR = Path(os.environ.get("SHARED_DIR", "/shared"))
CODECS_DIR = Path(os.environ.get("CODECS_DIR", "/codecs"))

LOGIN_RETRIES = int(os.environ.get("LOGIN_RETRIES", "60"))


def login(internal, password):
    """The admin's JWT for this password ("" if ChirpStack returned none), or
    None when ChirpStack refuses the password. Any other failure, such as
    ChirpStack not listening yet, is raised for the caller to retry."""
    try:
        return internal.Login(api.LoginRequest(email=ADMIN_EMAIL, password=password)).jwt
    except grpc.RpcError as err:
        if err.code() == grpc.StatusCode.UNAUTHENTICATED:
            return None
        raise


def rotate_initial_password(channel, internal, jwt):
    """Set the admin's password, signed in with the seeded one, to ADMIN_PASSWORD."""
    auth = [("authorization", f"Bearer {jwt}")]
    user_id = internal.Profile(empty_pb2.Empty(), metadata=auth).user.id
    api.UserServiceStub(channel).UpdatePassword(
        api.UpdateUserPasswordRequest(user_id=user_id, password=ADMIN_PASSWORD), metadata=auth)
    print(f"[provision] rotated {ADMIN_EMAIL}'s seeded password to CHIRPSTACK_ADMIN_PASSWORD", flush=True)


def connect_and_login():
    """ChirpStack seeds the admin user during its first-boot migrations and the
    gRPC server needs to be listening. Retry login until both are ready.

    When CHIRPSTACK_ADMIN_PASSWORD differs from the seeded password
    (CHIRPSTACK_ADMIN_INITIAL_PASSWORD, "admin" by default), the seeded one is
    rotated away: a login that ChirpStack refuses with the configured password
    is tried with the seeded one, and when that is accepted the admin's password
    is set to the configured one and the login repeated with it. Every later run
    logs in with the configured password at once, and a ChirpStack still on the
    seeded password (provisioned before one was configured) converges on the next
    run. Neither password is ever printed. Returns (channel, internal_stub,
    auth_metadata)."""
    channel = grpc.insecure_channel(GRPC_TARGET)
    internal = api.InternalServiceStub(channel)
    rotate = ADMIN_PASSWORD != ADMIN_INITIAL_PASSWORD
    last = None
    for attempt in range(1, LOGIN_RETRIES + 1):
        try:
            jwt = login(internal, ADMIN_PASSWORD)
            if jwt is None and rotate:
                seeded = login(internal, ADMIN_INITIAL_PASSWORD)
                if seeded:
                    rotate_initial_password(channel, internal, seeded)
                    jwt = login(internal, ADMIN_PASSWORD)
            if jwt:
                print(f"[provision] logged in as {ADMIN_EMAIL} over gRPC (attempt {attempt})", flush=True)
                return channel, internal, [("authorization", f"Bearer {jwt}")]
            if jwt is None:
                last = "ChirpStack refused CHIRPSTACK_ADMIN_PASSWORD" + (" and the seeded password" if rotate else "")
            else:
                last = "login returned no jwt"
        except grpc.RpcError as err:
            last = f"{err.code()}: {err.details()}"
        print(f"[provision] waiting for ChirpStack gRPC… ({attempt}/{LOGIN_RETRIES}: {last})", flush=True)
        time.sleep(2)
    sys.exit(f"[provision] ERROR: could not log in after {LOGIN_RETRIES} attempts: {last}")


def ensure_tenant(channel, auth):
    svc = api.TenantServiceStub(channel)
    listed = svc.List(api.ListTenantsRequest(limit=100), metadata=auth)
    for t in listed.result:
        if t.name == TENANT_NAME:
            print(f"[provision] tenant '{TENANT_NAME}' already exists: {t.id}", flush=True)
            return t.id
    created = svc.Create(api.CreateTenantRequest(tenant=api.Tenant(
        name=TENANT_NAME,
        description="Created by intelligent-farming-stack provisioner.",
        can_have_gateways=True,
        max_gateway_count=0,
        max_device_count=0,
        private_gateways_up=False,
        private_gateways_down=False,
    )), metadata=auth)
    print(f"[provision] created tenant '{TENANT_NAME}': {created.id}", flush=True)
    return created.id


def existing_key_for(tenant_id):
    """Reuse the API key from a previous run if config.json already has one for
    this tenant — the token is only returned at creation."""
    cfg = SHARED_DIR / "config.json"
    if not cfg.is_file():
        return None
    try:
        data = json.loads(cfg.read_text())
    except (ValueError, OSError):
        return None
    if data.get("apiKey") and data.get("tenantId") == tenant_id:
        return data["apiKey"]
    return None


def mint_api_key(internal, auth, tenant_id):
    # API keys are created via InternalService (the REST gateway doesn't expose it).
    created = internal.CreateApiKey(api.CreateApiKeyRequest(api_key=api.ApiKey(
        name=API_KEY_NAME, is_admin=False, tenant_id=tenant_id,
    )), metadata=auth)
    print(f"[provision] minted tenant API key '{API_KEY_NAME}' (id {created.id})", flush=True)
    return created.token


def write_artifacts(tenant_id, token):
    SHARED_DIR.mkdir(parents=True, exist_ok=True)

    config = {
        "chirpStackUrl": PUBLIC_CHIRPSTACK_URL,
        "apiKey": token,
        "mqttUrl": PUBLIC_MQTT_URL,
        "tenantId": tenant_id,
    }
    if PUBLIC_GATEWAY_BRIDGE_HOST:
        config["gatewayBridgeHost"] = PUBLIC_GATEWAY_BRIDGE_HOST
    (SHARED_DIR / "config.json").write_text(json.dumps(config, indent=2) + "\n")

    (SHARED_DIR / "leftenant.env").write_text(
        f"LEFTENANT_CHIRPSTACK_URL={PUBLIC_CHIRPSTACK_URL}\n"
        f"LEFTENANT_API_KEY={token}\n"
        f"LEFTENANT_MQTT_URL={PUBLIC_MQTT_URL}\n"
        f"LEFTENANT_TENANT_ID={tenant_id}\n"
        f"LEFTENANT_GATEWAY_BRIDGE_HOST={PUBLIC_GATEWAY_BRIDGE_HOST}\n"
    )

    # Format consumed by intelligent-farming-hub/codecs/attach-codecs.py
    # (case-insensitive "REST URL:" / "API key:" / "Tenant UUID:" lines).
    (SHARED_DIR / "leftenant-connection.txt").write_text(
        f"REST URL: {PUBLIC_CHIRPSTACK_URL}\n"
        f"API key: {token}\n"
        f"Tenant UUID: {tenant_id}\n"
    )
    print(f"[provision] wrote config.json, leftenant.env, leftenant-connection.txt to {SHARED_DIR}",
          flush=True)


def maybe_attach_codecs(tenant_id, token):
    script = CODECS_DIR / "attach-codecs.py"
    js_files = list(CODECS_DIR.glob("*.js")) if CODECS_DIR.is_dir() else []
    if not script.is_file() or not js_files:
        print("[provision] no codecs mounted at /codecs — skipping codec attach.", flush=True)
        return
    print(f"[provision] codecs present ({len(js_files)} .js) — running attach-codecs.py --apply", flush=True)
    env = {
        **os.environ,
        "CHIRPSTACK_REST_URL": REST_URL_INTERNAL,   # attach-codecs uses REST
        "CHIRPSTACK_API_KEY": token,
        "CHIRPSTACK_TENANT_ID": tenant_id,
        "CODECS_DIR": str(CODECS_DIR),
    }
    try:
        # Best-effort: device profiles may not exist yet (Leftenant creates them).
        subprocess.run([sys.executable, str(script), "--apply"], env=env, check=False)
    except OSError as err:
        print(f"[provision] codec attach skipped/failed (non-fatal): {err}", flush=True)


def main():
    channel, internal, auth = connect_and_login()
    tenant_id = ensure_tenant(channel, auth)
    token = existing_key_for(tenant_id)
    if token:
        print("[provision] reusing API key from existing config.json", flush=True)
    else:
        token = mint_api_key(internal, auth, tenant_id)
    write_artifacts(tenant_id, token)
    maybe_attach_codecs(tenant_id, token)
    print("[provision] done.", flush=True)


if __name__ == "__main__":
    main()
