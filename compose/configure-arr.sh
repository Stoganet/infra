#!/bin/bash
set -euo pipefail
# configure-arr.sh — Idempotently apply Sonarr, Radarr, and qBittorrent settings.
# Run once after `docker compose up -d`, or re-run any time to re-apply.
# Usage: ./configure-arr.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/arrconfig"
ENV_FILE="$SCRIPT_DIR/.env"

# ── Load .env ──────────────────────────────────────────────────────────────────
if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
else
    echo "Warning: .env not found. API keys will be auto-detected from containers."
fi

# ── Check containers are running ───────────────────────────────────────────────
check_container() {
    local name=$1
    if ! docker inspect "$name" &>/dev/null || \
       [ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" != "true" ]; then
        echo "Error: Container '$name' is not running."
        echo "Start services with: docker compose up -d"
        exit 1
    fi
}

check_container sonarr
check_container radarr
check_container gluetun
check_container prowlarr

# ── Detect API keys ────────────────────────────────────────────────────────────
detect_key() {
    local container=$1
    docker exec "$container" sed -n 's|.*<ApiKey>\(.*\)</ApiKey>.*|\1|p' /config/config.xml 2>/dev/null || true
}

SONARR_KEY="${SONARR_API_KEY:-$(detect_key sonarr)}"
RADARR_KEY="${RADARR_API_KEY:-$(detect_key radarr)}"
PROWLARR_KEY="${PROWLARR_API_KEY:-$(detect_key prowlarr)}"

if [ -z "$SONARR_KEY" ]; then
    echo "Error: Could not read Sonarr API key. Is Sonarr fully initialised?"
    exit 1
fi
if [ -z "$RADARR_KEY" ]; then
    echo "Error: Could not read Radarr API key. Is Radarr fully initialised?"
    exit 1
fi
if [ -z "$PROWLARR_KEY" ]; then
    echo "Error: Could not read Prowlarr API key. Is Prowlarr fully initialised?"
    exit 1
fi

echo "Configuring arr stack..."
printf "  Sonarr key:   %.8s...\n" "$SONARR_KEY"
printf "  Radarr key:   %.8s...\n" "$RADARR_KEY"
printf "  Prowlarr key: %.8s...\n" "$PROWLARR_KEY"
echo ""

# ── Run configuration via Python ───────────────────────────────────────────────
export SONARR_KEY RADARR_KEY PROWLARR_KEY CONFIG_DIR
export MAM_ID="${MAM_ID:-}"
export QBIT_USERNAME="${QBIT_USERNAME:-}"
export QBIT_PASSWORD="${QBIT_PASSWORD:-}"

python3 - << 'PYEOF'
import json, os, subprocess, sys

CONFIG_DIR = os.environ["CONFIG_DIR"]
SONARR_KEY = os.environ["SONARR_KEY"]
RADARR_KEY = os.environ["RADARR_KEY"]

# ── API helpers ─────────────────────────────────────────────────────────────────
def arr_api(container, port, key, method, path, data=None):
    args = [
        "docker", "exec", container,
        "curl", "-sf", "-X", method,
        f"http://localhost:{port}/api/v3{path}",
        "-H", f"X-Api-Key: {key}",
        "-H", "Content-Type: application/json",
    ]
    if data is not None:
        args += ["-d", json.dumps(data)]
    r = subprocess.run(args, capture_output=True, text=True)
    if not r.stdout.strip():
        return None
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        print(f"  WARNING: unexpected response from {container}: {r.stdout[:200]}")
        return None

def sonarr(method, path, data=None):
    return arr_api("sonarr", 8989, SONARR_KEY, method, path, data)

def radarr(method, path, data=None):
    return arr_api("radarr", 7878, RADARR_KEY, method, path, data)

def qbit_set(prefs: dict):
    payload = f"json={json.dumps(prefs)}"
    subprocess.run(
        ["docker", "exec", "gluetun", "wget", "-qO-",
         "--post-data", payload,
         "http://localhost:8080/api/v2/app/setPreferences"],
        capture_output=True,
    )

def load_json(filename):
    with open(os.path.join(CONFIG_DIR, filename)) as f:
        return json.load(f)

# ═══════════════════════════════════════════════════════════════════════════════
# 1. Quality definitions — file size limits
#    Radarr: GB total per movie file
#    Sonarr: MB/min per episode (e.g. 150 MB/min × 45 min = 6.75 GB/episode)
# ═══════════════════════════════════════════════════════════════════════════════
print("[1/5] Applying quality size limits...")

def apply_quality_defs(app_fn, app_name, config_file):
    limits = {d["name"]: d for d in load_json(config_file)}
    current = app_fn("GET", "/qualitydefinition") or []
    count = 0
    for d in current:
        name = d.get("quality", {}).get("name", "")
        if name in limits:
            d["minSize"] = limits[name]["minSize"]
            d["maxSize"] = limits[name]["maxSize"]
            count += 1
    app_fn("PUT", "/qualitydefinition/update", current)
    print(f"  {app_name}: {count} qualities updated")

apply_quality_defs(radarr, "Radarr", "radarr-quality-definitions.json")
apply_quality_defs(sonarr, "Sonarr", "sonarr-quality-definitions.json")

# ═══════════════════════════════════════════════════════════════════════════════
# 2. Custom formats
# ═══════════════════════════════════════════════════════════════════════════════
print("\n[2/5] Applying custom formats...")

desired_formats = load_json("custom-formats.json")

def apply_custom_formats(app_fn, app_name):
    existing = app_fn("GET", "/customformat") or []
    by_name = {c["name"]: c for c in existing}
    cf_ids = {}

    for fmt in desired_formats:
        name = fmt["name"]
        if name in by_name:
            cf_id = by_name[name]["id"]
            app_fn("PUT", f"/customformat/{cf_id}", {**fmt, "id": cf_id})
            print(f"  {app_name}: updated '{name}'")
        else:
            result = app_fn("POST", "/customformat", fmt) or {}
            cf_id = result.get("id")
            if not cf_id:
                print(f"  {app_name}: ERROR creating '{name}'")
                continue
            print(f"  {app_name}: created '{name}' (id={cf_id})")
        cf_ids[name] = cf_id

    return cf_ids

radarr_cf_ids = apply_custom_formats(radarr, "Radarr")
sonarr_cf_ids = apply_custom_formats(sonarr, "Sonarr")

# ═══════════════════════════════════════════════════════════════════════════════
# 3. Quality profiles — language and custom format scores
#    language=Original: each title uses its TMDB original language, so French
#    films get French audio and English films get English. Bazarr handles subs.
# ═══════════════════════════════════════════════════════════════════════════════
print("\n[3/5] Applying quality profile settings...")

def apply_profile_settings(app_fn, app_name, cf_ids):
    langs = app_fn("GET", "/language") or []
    original = next((l for l in langs if l.get("name") == "Original"), None)
    if not original:
        print(f"  {app_name}: WARNING — 'Original' language option not found, skipping")
        return

    profiles = app_fn("GET", "/qualityprofile") or []
    for p in profiles:
        p["language"] = {"id": original["id"], "name": "Original"}

        scores = [s for s in p.get("formatItems", [])
                  if s.get("format") not in cf_ids.values()]
        for fmt_name, cf_id in cf_ids.items():
            scores.append({"format": cf_id, "name": fmt_name, "score": -10000})
        p["formatItems"] = scores

        app_fn("PUT", f"/qualityprofile/{p['id']}", p)

    print(f"  {app_name}: {len(profiles)} profiles updated (language=Original, CF scores applied)")

apply_profile_settings(radarr, "Radarr", radarr_cf_ids)
apply_profile_settings(sonarr, "Sonarr", sonarr_cf_ids)

# ═══════════════════════════════════════════════════════════════════════════════
# 4. qBittorrent preferences
# ═══════════════════════════════════════════════════════════════════════════════
print("\n[4/5] Applying qBittorrent preferences...")

raw = load_json("qbittorrent-preferences.json")
prefs = {k: v for k, v in raw.items() if not k.startswith("_")}
qbit_set(prefs)
print(f"  qBittorrent: {len(prefs)} settings applied")


# ═══════════════════════════════════════════════════════════════════════════════
# 5. Prowlarr — qBittorrent download client and MAM indexer
# ═══════════════════════════════════════════════════════════════════════════════
print("\n[5/5] Configuring Prowlarr...")

PROWLARR_KEY = os.environ["PROWLARR_KEY"]
MAM_ID = os.environ.get("MAM_ID", "")
QBIT_USERNAME = os.environ.get("QBIT_USERNAME", "")
QBIT_PASSWORD = os.environ.get("QBIT_PASSWORD", "")

def prowlarr(method, path, data=None):
    args = [
        "docker", "exec", "prowlarr",
        "curl", "-sf", "-X", method,
        f"http://localhost:9696/api/v1{path}",
        "-H", f"X-Api-Key: {PROWLARR_KEY}",
        "-H", "Content-Type: application/json",
    ]
    if data is not None:
        args += ["-d", json.dumps(data)]
    r = subprocess.run(args, capture_output=True, text=True)
    if not r.stdout.strip():
        return None
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        print(f"  WARNING: unexpected response from prowlarr: {r.stdout[:200]}")
        return None

# qBittorrent download client
existing_clients = prowlarr("GET", "/downloadclient") or []
qbit_exists = any(c.get("implementation") == "QBittorrent" for c in existing_clients)
if qbit_exists:
    print("  Prowlarr: qBittorrent already configured")
else:
    schemas = prowlarr("GET", "/downloadclient/schema") or []
    qbit_schema = next((s for s in schemas if s.get("implementation") == "QBittorrent"), None)
    if qbit_schema:
        for f in qbit_schema["fields"]:
            if f["name"] == "host":
                f["value"] = "gluetun"
            elif f["name"] == "port":
                f["value"] = 8080
            elif f["name"] == "username" and QBIT_USERNAME:
                f["value"] = QBIT_USERNAME
            elif f["name"] == "password" and QBIT_PASSWORD:
                f["value"] = QBIT_PASSWORD
        qbit_schema["name"] = "qBittorrent"
        qbit_schema["enable"] = True
        result = prowlarr("POST", "/downloadclient", qbit_schema)
        if result and result.get("id"):
            print(f"  Prowlarr: qBittorrent added (id={result['id']})")
        else:
            print("  Prowlarr: ERROR adding qBittorrent")

# MAM indexer
if not MAM_ID:
    print("  Prowlarr: MAM_ID not set in .env, skipping MyAnonamouse indexer")
else:
    existing_indexers = prowlarr("GET", "/indexer") or []
    mam_exists = any("anonamouse" in i.get("name", "").lower() for i in existing_indexers)
    if mam_exists:
        print("  Prowlarr: MyAnonamouse already configured")
    else:
        schemas = prowlarr("GET", "/indexer/schema") or []
        mam_schema = next((s for s in schemas if s.get("implementation") == "MyAnonamouse"), None)
        if mam_schema:
            for f in mam_schema["fields"]:
                if f["name"] == "mamId":
                    f["value"] = MAM_ID
            mam_schema["name"] = "MyAnonamouse"
            mam_schema["enable"] = True
            mam_schema["appProfileId"] = 1
            result = prowlarr("POST", "/indexer", mam_schema)
            if result and result.get("id"):
                print(f"  Prowlarr: MyAnonamouse added (id={result['id']})")
            else:
                print("  Prowlarr: ERROR adding MyAnonamouse indexer")

print("\nDone.")
PYEOF

# ── Offer to persist detected API keys into .env ───────────────────────────────
KEYS_SAVED=0
if [ -z "${SONARR_API_KEY:-}" ]; then
    if grep -q "^SONARR_API_KEY=" "$ENV_FILE" 2>/dev/null; then
        sed -i "s/^SONARR_API_KEY=.*/SONARR_API_KEY=$SONARR_KEY/" "$ENV_FILE"
    else
        echo "SONARR_API_KEY=$SONARR_KEY" >> "$ENV_FILE"
    fi
    KEYS_SAVED=$((KEYS_SAVED + 1))
fi
if [ -z "${RADARR_API_KEY:-}" ]; then
    if grep -q "^RADARR_API_KEY=" "$ENV_FILE" 2>/dev/null; then
        sed -i "s/^RADARR_API_KEY=.*/RADARR_API_KEY=$RADARR_KEY/" "$ENV_FILE"
    else
        echo "RADARR_API_KEY=$RADARR_KEY" >> "$ENV_FILE"
    fi
    KEYS_SAVED=$((KEYS_SAVED + 1))
fi
if [ -z "${PROWLARR_API_KEY:-}" ]; then
    if grep -q "^PROWLARR_API_KEY=" "$ENV_FILE" 2>/dev/null; then
        sed -i "s/^PROWLARR_API_KEY=.*/PROWLARR_API_KEY=$PROWLARR_KEY/" "$ENV_FILE"
    else
        echo "PROWLARR_API_KEY=$PROWLARR_KEY" >> "$ENV_FILE"
    fi
    KEYS_SAVED=$((KEYS_SAVED + 1))
fi
if [ "$KEYS_SAVED" -gt 0 ]; then
    echo ""
    echo "Auto-detected API keys saved to .env ($KEYS_SAVED key(s))."
fi
