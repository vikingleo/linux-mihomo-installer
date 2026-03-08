#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
TARGET_USER=${TARGET_USER:-${SUDO_USER:-$(id -un)}}
TARGET_UID=$(id -u "$TARGET_USER")
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

MIHOMO_DIR=${MIHOMO_DIR:-/etc/mihomo}
MIHOMO_RULESET_DIR=$MIHOMO_DIR/ruleset
MIHOMO_PROVIDER_DIR=$MIHOMO_DIR/providers
MIHOMO_BIN=${MIHOMO_BIN:-/usr/local/bin/mihomo}
MIHOMO_SYSTEMD_UNIT=${MIHOMO_SYSTEMD_UNIT:-/etc/systemd/system/mihomo.service}
CONFIG_TEMPLATE_PATH=${CONFIG_TEMPLATE_PATH:-$SCRIPT_DIR/config.yaml}
MIHOMO_VERSION=${MIHOMO_VERSION:-latest}
MIHOMO_RELEASES_API=${MIHOMO_RELEASES_API:-https://api.github.com/repos/MetaCubeX/mihomo/releases}
MIHOMO_RELEASE_URL_BASE=${MIHOMO_RELEASE_URL_BASE:-https://github.com/MetaCubeX/mihomo/releases}
MIHOMO_DOWNLOAD_URL=${MIHOMO_DOWNLOAD_URL:-}
MIHOMO_DOWNLOAD_FILE=${MIHOMO_DOWNLOAD_FILE:-}
MIHOMO_DOWNLOAD_MIRROR_PREFIXES=${MIHOMO_DOWNLOAD_MIRROR_PREFIXES:-}
MIHOMO_OFFLINE_SEARCH_DIRS=${MIHOMO_OFFLINE_SEARCH_DIRS:-$SCRIPT_DIR:$SCRIPT_DIR/dist:/opt/packages:/opt/distfiles:/var/cache/mihomo}
MIHOMO_ASSET_NAME=${MIHOMO_ASSET_NAME:-}
MIHOMO_SUBSCRIPTION_URL=${MIHOMO_SUBSCRIPTION_URL:-}
MIHOMO_SECRET=${MIHOMO_SECRET:-}
USER_SYSTEMD_DIR=$TARGET_HOME/.config/systemd/user
LEGACY_USER_BIN_DIR=$TARGET_HOME/.local/bin
LEGACY_USER_CONFIG_DIR=$TARGET_HOME/.config/mihomo

log() {
  printf '[mihomo-migrate] %s\n' "$*"
}

run_as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

need_cmd() {
  local cmd=$1
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log "Missing required command: $cmd"
    exit 1
  fi
}

has_downloader() {
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1
}

download_to_file() {
  local output=$1
  shift
  local url last_error=''
  if [ "$#" -eq 0 ]; then
    log 'No download candidates provided'
    exit 1
  fi
  for url in "$@"; do
    [ -n "$url" ] || continue
    log "Trying download: $url"
    if command -v curl >/dev/null 2>&1; then
      if curl -fsSL --retry 3 --connect-timeout 15 -o "$output" "$url"; then
        return
      fi
      last_error="curl failed: $url"
      continue
    fi
    if command -v wget >/dev/null 2>&1; then
      if wget -qO "$output" "$url"; then
        return
      fi
      last_error="wget failed: $url"
      continue
    fi
  done
  log 'Neither curl nor wget succeeded for Mihomo download'
  if [ -n "$last_error" ]; then
    log "$last_error"
  fi
  exit 1
}

run_user_systemctl() {
  local runtime_dir="/run/user/$TARGET_UID"
  if [ "$(id -un)" = "$TARGET_USER" ]; then
    systemctl --user "$@"
    return
  fi
  if [ -d "$runtime_dir" ]; then
    run_as_root env XDG_RUNTIME_DIR="$runtime_dir" sudo -u "$TARGET_USER" systemctl --user "$@"
    return
  fi
  log "User systemd runtime not found at $runtime_dir; skipped legacy watchdog cleanup in user systemd"
  return 1
}

remove_legacy_user_file() {
  local path=$1
  if [ -e "$path" ] || [ -L "$path" ]; then
    rm -f -- "$path"
    log "Removed legacy file: $path"
  fi
}

read_existing_mihomo_secret() {
  python3 - "$MIHOMO_DIR/config.yaml" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
if not path.exists():
    raise SystemExit(1)

text = path.read_text()
match = re.search(r"^secret:\s*'?(.*?)'?$", text, re.M)
if not match:
    raise SystemExit(1)

value = match.group(1).strip()
if value and not value.startswith('__'):
    print(value)
else:
    raise SystemExit(1)
PY
}

read_existing_subscription_url() {
  python3 - "$MIHOMO_DIR/config.yaml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
if not path.exists():
    raise SystemExit(1)

lines = path.read_text().splitlines()
in_proxy_providers = False
in_subscription = False

for line in lines:
    stripped = line.strip()
    if not stripped:
        continue
    if not line.startswith(' '):
        in_proxy_providers = stripped == 'proxy-providers:'
        in_subscription = False
        continue
    if in_proxy_providers and line.startswith('  ') and not line.startswith('    '):
        in_subscription = stripped.startswith('subscription:')
        continue
    if in_subscription and line.startswith('    url:'):
        value = line.split(':', 1)[1].strip().strip("'\"")
        if value and not value.startswith('__'):
            print(value)
            raise SystemExit(0)
        raise SystemExit(1)

raise SystemExit(1)
PY
}

generate_mihomo_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
    return
  fi
  python3 - <<'PY'
import secrets
print(secrets.token_hex(16))
PY
}

resolve_mihomo_secret() {
  if [ -n "$MIHOMO_SECRET" ]; then
    printf '%s\n' "$MIHOMO_SECRET"
    return
  fi
  if existing_secret=$(read_existing_mihomo_secret 2>/dev/null); then
    printf '%s\n' "$existing_secret"
    return
  fi
  generate_mihomo_secret
}

prompt_subscription_url() {
  local current_default=${1:-}
  local prompt='请输入 Mihomo 订阅地址'
  local value=''

  if [ -n "$current_default" ]; then
    prompt="$prompt [$current_default]"
  fi
  prompt="$prompt: "

  if [ ! -t 0 ]; then
    return 1
  fi

  read -r -p "$prompt" value
  if [ -z "$value" ] && [ -n "$current_default" ]; then
    value=$current_default
  fi
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
    return 0
  fi
  return 1
}

resolve_subscription_url() {
  if [ -n "$MIHOMO_SUBSCRIPTION_URL" ]; then
    printf '%s\n' "$MIHOMO_SUBSCRIPTION_URL"
    return
  fi

  local current_subscription=''
  if current_subscription=$(read_existing_subscription_url 2>/dev/null); then
    if new_subscription=$(prompt_subscription_url "$current_subscription"); then
      printf '%s\n' "$new_subscription"
      return
    fi
    printf '%s\n' "$current_subscription"
    return
  fi

  if new_subscription=$(prompt_subscription_url ''); then
    printf '%s\n' "$new_subscription"
    return
  fi

  log 'Missing Mihomo subscription URL. Set MIHOMO_SUBSCRIPTION_URL or run interactively.'
  exit 1
}

render_config_template() {
  local src=$1
  local dest=$2
  local subscription_url=$3
  local mihomo_secret=$4
  python3 - "$src" "$dest" "$subscription_url" "$mihomo_secret" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1])
dest = Path(sys.argv[2])
subscription_url = sys.argv[3]
mihomo_secret = sys.argv[4]

text = src.read_text()
text = text.replace('__MIHOMO_SUBSCRIPTION_URL__', subscription_url.replace("'", "''"))
text = text.replace('__MIHOMO_SECRET__', mihomo_secret.replace("'", "''"))
dest.write_text(text)
PY
}

normalize_mihomo_tag() {
  if [ "$MIHOMO_VERSION" = latest ]; then
    printf 'latest\n'
    return
  fi
  case "$MIHOMO_VERSION" in
    v*) printf '%s\n' "$MIHOMO_VERSION" ;;
    *) printf 'v%s\n' "$MIHOMO_VERSION" ;;
  esac
}

resolve_release_api_url() {
  local tag
  tag=$(normalize_mihomo_tag)
  if [ "$tag" = latest ]; then
    printf '%s/latest\n' "$MIHOMO_RELEASES_API"
  else
    printf '%s/tags/%s\n' "$MIHOMO_RELEASES_API" "$tag"
  fi
}

build_release_download_url() {
  local asset_name=$1
  local tag
  tag=$(normalize_mihomo_tag)
  if [ "$tag" = latest ]; then
    printf '%s/latest/download/%s\n' "$MIHOMO_RELEASE_URL_BASE" "$asset_name"
  else
    printf '%s/download/%s/%s\n' "$MIHOMO_RELEASE_URL_BASE" "$tag" "$asset_name"
  fi
}

emit_mirror_prefixes() {
  printf '%s' "$MIHOMO_DOWNLOAD_MIRROR_PREFIXES" | tr ',;' '\n' | while IFS= read -r prefix; do
    prefix=$(printf '%s' "$prefix" | awk '{gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print}')
    [ -n "$prefix" ] || continue
    printf '%s\n' "$prefix"
  done
}

emit_offline_search_dirs() {
  printf '%s' "$MIHOMO_OFFLINE_SEARCH_DIRS" | tr ':,;' '\n' | while IFS= read -r dir; do
    dir=$(printf '%s' "$dir" | awk '{gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print}')
    [ -n "$dir" ] || continue
    printf '%s\n' "$dir"
  done
}

emit_download_candidates() {
  local base_url=$1
  printf '%s\n' "$base_url"
  while IFS= read -r prefix; do
    [ -n "$prefix" ] || continue
    case "$prefix" in
      */) printf '%s%s\n' "$prefix" "$base_url" ;;
      *) printf '%s/%s\n' "$prefix" "$base_url" ;;
    esac
  done < <(emit_mirror_prefixes)
}

find_local_mihomo_package() {
  local tmpfile
  tmpfile=$(mktemp)
  while IFS= read -r dir; do
    [ -d "$dir" ] || continue
    find "$dir" -maxdepth 2 -type f -name 'mihomo-*.gz' 2>/dev/null >>"$tmpfile"
  done < <(emit_offline_search_dirs)

  if [ ! -s "$tmpfile" ]; then
    rm -f -- "$tmpfile"
    return 1
  fi

  python3 - "$MIHOMO_ASSET_NAME" "$(normalize_mihomo_tag)" <<'PY' <"$tmpfile"
import os
import sys

asset_name = sys.argv[1].strip()
tag = sys.argv[2].strip()
paths = [line.strip() for line in sys.stdin.read().splitlines() if line.strip()]

if not paths:
    raise SystemExit(1)

patterns = [line.strip() for line in os.environ.get("MIHOMO_ARCH_PATTERNS", "").splitlines() if line.strip()]

def acceptable(name: str) -> bool:
    return name.endswith('.gz') and '.deb' not in name and '.rpm' not in name and '.pkg.tar.zst' not in name

def score(path: str):
    name = os.path.basename(path)
    is_exact = 1 if asset_name and name == asset_name else 0
    has_tag = 1 if (tag == 'latest' or f'-{tag}.gz' in name) else 0
    arch_match = 1 if any(name.startswith(f'mihomo-{pattern}-') for pattern in patterns) else 0
    no_go_variant = 1 if ('go120' not in name and 'go123' not in name) else 0
    return (is_exact, has_tag, arch_match, no_go_variant, name)

candidates = [path for path in paths if acceptable(os.path.basename(path))]
if asset_name:
    candidates = [path for path in candidates if os.path.basename(path) == asset_name]
    if not candidates:
        raise SystemExit(1)
else:
    candidates = [path for path in candidates if any(os.path.basename(path).startswith(f'mihomo-{pattern}-') for pattern in patterns)]
    if tag != 'latest':
        tagged = [path for path in candidates if f'-{tag}.gz' in os.path.basename(path)]
        if tagged:
            candidates = tagged
    if not candidates:
        raise SystemExit(1)

chosen = sorted(candidates, key=score, reverse=True)[0]
print(chosen)
PY
  local status=$?
  rm -f -- "$tmpfile"
  return "$status"
}

detect_asset_patterns() {
  if [ -n "$MIHOMO_ASSET_NAME" ]; then
    return
  fi

  case "$(uname -m)" in
    x86_64|amd64)
      printf '%s\n' 'linux-amd64-v1'
      printf '%s\n' 'linux-amd64-compatible'
      printf '%s\n' 'linux-amd64'
      ;;
    aarch64|arm64)
      printf '%s\n' 'linux-arm64'
      ;;
    armv7l|armv7)
      printf '%s\n' 'linux-armv7'
      ;;
    armv6l|armv6)
      printf '%s\n' 'linux-armv6'
      ;;
    armv5l|armv5)
      printf '%s\n' 'linux-armv5'
      ;;
    i386|i686)
      printf '%s\n' 'linux-386'
      ;;
    riscv64)
      printf '%s\n' 'linux-riscv64'
      ;;
    s390x)
      printf '%s\n' 'linux-s390x'
      ;;
    ppc64le)
      printf '%s\n' 'linux-ppc64le'
      ;;
    loongarch64)
      printf '%s\n' 'linux-loong64-abi1'
      printf '%s\n' 'linux-loong64-abi2'
      ;;
    *)
      log "Unsupported architecture: $(uname -m). Set MIHOMO_ASSET_NAME or MIHOMO_DOWNLOAD_URL manually."
      exit 1
      ;;
  esac
}

resolve_mihomo_download() {
  if [ -n "$MIHOMO_DOWNLOAD_FILE" ]; then
    local local_name=${MIHOMO_ASSET_NAME:-$(basename "$MIHOMO_DOWNLOAD_FILE")}
    printf '%s\n%s\n%s\n%s\n' "$local_name" "$MIHOMO_DOWNLOAD_FILE" 'local-file' 'file'
    return
  fi

  local detected_local_file=''
  local arch_patterns=''
  if [ -z "$MIHOMO_ASSET_NAME" ]; then
    arch_patterns=$(detect_asset_patterns)
  fi
  if detected_local_file=$(MIHOMO_ARCH_PATTERNS="$arch_patterns" find_local_mihomo_package 2>/dev/null); then
    local detected_name
    detected_name=$(basename "$detected_local_file")
    printf '%s\n%s\n%s\n%s\n' "$detected_name" "$detected_local_file" 'auto-local-file' 'file'
    return
  fi

  if [ -n "$MIHOMO_DOWNLOAD_URL" ]; then
    local custom_name=${MIHOMO_ASSET_NAME:-$(basename "$MIHOMO_DOWNLOAD_URL")}
    printf '%s\n%s\n%s\n%s\n' "$custom_name" "$MIHOMO_DOWNLOAD_URL" 'custom-url' 'url'
    return
  fi

  if [ -n "$MIHOMO_ASSET_NAME" ]; then
    printf '%s\n%s\n%s\n%s\n' "$MIHOMO_ASSET_NAME" "$(build_release_download_url "$MIHOMO_ASSET_NAME")" "$(normalize_mihomo_tag)" 'url'
    return
  fi

  local release_api_url
  release_api_url=$(resolve_release_api_url)

  python3 - "$release_api_url" "$MIHOMO_ASSET_NAME" <<'PY'
import json
import sys
import urllib.request

release_api_url = sys.argv[1]
asset_name = sys.argv[2].strip()
patterns = [line.strip() for line in sys.stdin.read().splitlines() if line.strip()]

req = urllib.request.Request(release_api_url, headers={"User-Agent": "mihomo-migrate-installer"})
with urllib.request.urlopen(req, timeout=30) as response:
    release = json.load(response)

assets = release.get("assets", [])

def acceptable(name: str) -> bool:
    return name.endswith('.gz') and '.deb' not in name and '.rpm' not in name and '.pkg.tar.zst' not in name

if asset_name:
    for asset in assets:
        name = asset.get("name", "")
        if name == asset_name:
            print(name)
            print(asset.get("browser_download_url", ""))
            print(release.get("tag_name", ""))
            print("url")
            raise SystemExit(0)
    raise SystemExit(f"Asset not found in release: {asset_name}")

for pattern in patterns:
    candidates = [asset for asset in assets if asset.get("name", "").startswith(f"mihomo-{pattern}-") and acceptable(asset.get("name", ""))]
    preferred = [asset for asset in candidates if 'go120' not in asset.get('name', '') and 'go123' not in asset.get('name', '')]
    source = preferred or candidates
    if source:
        chosen = source[0]
        print(chosen.get("name", ""))
        print(chosen.get("browser_download_url", ""))
        print(release.get("tag_name", ""))
        print("url")
        raise SystemExit(0)

raise SystemExit(f"No matching Mihomo asset found for patterns: {patterns}")
PY
}

install_mihomo_binary() {
  need_cmd python3
  need_cmd gzip
  need_cmd install
  if ! has_downloader; then
    log 'curl or wget is required to download Mihomo'
    exit 1
  fi
  if [ "$(uname -s)" != Linux ]; then
    log 'Automatic Mihomo installation currently supports Linux only'
    exit 1
  fi

  local tmpdir asset_name download_url release_tag source_kind archive_path binary_path
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' RETURN

  if [ -n "$MIHOMO_ASSET_NAME" ]; then
    readarray -t release_meta < <(printf '' | resolve_mihomo_download)
  else
    readarray -t release_meta < <(detect_asset_patterns | resolve_mihomo_download)
  fi

  asset_name=${release_meta[0]:-}
  download_url=${release_meta[1]:-}
  release_tag=${release_meta[2]:-unknown}
  source_kind=${release_meta[3]:-url}
  if [ -z "$download_url" ]; then
    log 'Failed to resolve Mihomo download source'
    exit 1
  fi

  archive_path=$tmpdir/${asset_name:-mihomo.gz}
  binary_path=$tmpdir/mihomo

  if [ "$source_kind" = file ]; then
    if [ ! -f "$download_url" ]; then
      log "Offline Mihomo package not found: $download_url"
      exit 1
    fi
    log "Using offline Mihomo package: $download_url"
    cp "$download_url" "$archive_path"
  else
    log "Downloading Mihomo ${release_tag} (${asset_name})"
    readarray -t download_candidates < <(emit_download_candidates "$download_url")
    download_to_file "$archive_path" "${download_candidates[@]}"
  fi
  gzip -dc "$archive_path" > "$binary_path"
  chmod 755 "$binary_path"
  run_as_root install -m 755 "$binary_path" "$MIHOMO_BIN"
  log "Installed Mihomo binary to $MIHOMO_BIN"
}

ensure_mihomo_binary() {
  if command -v mihomo >/dev/null 2>&1; then
    local found_bin
    found_bin=$(command -v mihomo)
    if [ ! -x "$MIHOMO_BIN" ]; then
      MIHOMO_BIN=$found_bin
    fi
    log "Found Mihomo binary: $found_bin"
    return
  fi

  log 'Mihomo not found; installing from official GitHub release'
  install_mihomo_binary

  if ! command -v mihomo >/dev/null 2>&1 && [ -x "$MIHOMO_BIN" ]; then
    export PATH="$(dirname "$MIHOMO_BIN"):$PATH"
  fi

  if ! command -v mihomo >/dev/null 2>&1; then
    log 'Mihomo installation finished but binary is still not available in PATH'
    exit 1
  fi

  MIHOMO_BIN=$(command -v mihomo)
}

create_mihomo_systemd_unit() {
  local tmpfile
  tmpfile=$(mktemp)
  cat >"$tmpfile" <<EOF_UNIT
[Unit]
Description=Mihomo Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${MIHOMO_BIN} -d ${MIHOMO_DIR} -f ${MIHOMO_DIR}/config.yaml
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF_UNIT
  run_as_root install -m 644 "$tmpfile" "$MIHOMO_SYSTEMD_UNIT"
  rm -f -- "$tmpfile"
  log "Installed systemd unit: $MIHOMO_SYSTEMD_UNIT"
}

ensure_mihomo_service() {
  need_cmd systemctl
  if systemctl cat mihomo >/dev/null 2>&1; then
    log 'Found existing mihomo systemd unit'
  else
    log 'mihomo systemd unit not found; creating a managed unit'
    create_mihomo_systemd_unit
  fi
  run_as_root systemctl daemon-reload
  run_as_root systemctl enable mihomo >/dev/null 2>&1 || true
}

log 'Ensuring Mihomo is installed'
ensure_mihomo_binary
ensure_mihomo_service

MIHOMO_SECRET=$(resolve_mihomo_secret)
MIHOMO_SUBSCRIPTION_URL=$(resolve_subscription_url)

TMP_RENDERED_CONFIG=$(mktemp)
trap 'rm -f -- "$TMP_RENDERED_CONFIG"' EXIT
render_config_template "$CONFIG_TEMPLATE_PATH" "$TMP_RENDERED_CONFIG" "$MIHOMO_SUBSCRIPTION_URL" "$MIHOMO_SECRET"

log 'Validating Mihomo config'
mihomo -t -d "$SCRIPT_DIR" -f "$TMP_RENDERED_CONFIG" >/dev/null

log 'Installing Mihomo config and rulesets'
run_as_root install -d -m 755 "$MIHOMO_DIR" "$MIHOMO_RULESET_DIR" "$MIHOMO_PROVIDER_DIR"
run_as_root install -m 644 "$TMP_RENDERED_CONFIG" "$MIHOMO_DIR/config.yaml"
for file in "$SCRIPT_DIR"/ruleset/*; do
  [ -f "$file" ] || continue
  run_as_root install -m 644 "$file" "$MIHOMO_RULESET_DIR/$(basename "$file")"
done
run_as_root systemctl restart mihomo

log 'Cleaning legacy Mihomo watchdog artifacts'
if run_user_systemctl daemon-reload; then
  run_user_systemctl disable --now mihomo-telegram-watchdog.timer || true
  run_user_systemctl stop mihomo-telegram-watchdog.service || true
fi

remove_legacy_user_file "$LEGACY_USER_BIN_DIR/mihomo-telegram-watchdog.sh"
remove_legacy_user_file "$LEGACY_USER_BIN_DIR/mihomo-persist-telegram-policy.sh"
remove_legacy_user_file "$USER_SYSTEMD_DIR/mihomo-telegram-watchdog.service"
remove_legacy_user_file "$USER_SYSTEMD_DIR/mihomo-telegram-watchdog.timer"
remove_legacy_user_file "$LEGACY_USER_CONFIG_DIR/telegram-watchdog.env"

run_user_systemctl daemon-reload || true

log 'Done'
log 'Shared special route group is: 专项代理'
log "Mihomo subscription URL has been applied"
log "Mihomo controller secret: $MIHOMO_SECRET"
log 'Legacy watchdog is no longer managed by this package'
