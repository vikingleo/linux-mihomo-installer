#!/usr/bin/env bash
set -euo pipefail

MIHOMO_DIR=${MIHOMO_DIR:-/etc/mihomo}
MIHOMO_CONFIG=${MIHOMO_CONFIG:-$MIHOMO_DIR/config.yaml}
MIHOMO_CONTROLLER_URL=${MIHOMO_CONTROLLER_URL:-http://127.0.0.1:9090}
OPENCLAW_CONFIG=${OPENCLAW_CONFIG:-$HOME/.openclaw/openclaw.json}
TARGET_GROUP=${TARGET_GROUP:-专项代理}

ok() {
  printf '[OK] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*"
}

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  local cmd=$1
  command -v "$cmd" >/dev/null 2>&1 || fail "Missing required command: $cmd"
}

extract_mihomo_secret() {
  python3 - "$MIHOMO_CONFIG" <<'PY'
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
if value:
    print(value)
    raise SystemExit(0)
raise SystemExit(1)
PY
}

check_file_exists() {
  local path=$1
  [ -e "$path" ] || fail "Missing file: $path"
  ok "Found file: $path"
}

check_mihomo_binary() {
  command -v mihomo >/dev/null 2>&1 || fail 'mihomo binary not found in PATH'
  ok "Found mihomo binary: $(command -v mihomo)"
}

check_mihomo_config() {
  check_file_exists "$MIHOMO_CONFIG"
  mihomo -t -d "$MIHOMO_DIR" -f "$MIHOMO_CONFIG" >/dev/null || fail "mihomo config validation failed: $MIHOMO_CONFIG"
  ok 'Mihomo config validation passed'
}

check_rulesets() {
  local dir=$MIHOMO_DIR/ruleset
  [ -d "$dir" ] || fail "Missing ruleset directory: $dir"
  for name in direct.list gfw.list aiti-ad.list cncidr.list; do
    [ -f "$dir/$name" ] || fail "Missing ruleset file: $dir/$name"
  done
  ok 'Required ruleset files are present'
}

check_group_in_config() {
  python3 - "$MIHOMO_CONFIG" "$TARGET_GROUP" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
group = sys.argv[2]
if f"name: {group}" in text or f"name: '{group}'" in text or f'name: "{group}"' in text:
    raise SystemExit(0)
raise SystemExit(1)
PY
  ok "Found target group in config: $TARGET_GROUP"
}

check_mihomo_service() {
  systemctl is-enabled mihomo >/dev/null 2>&1 || warn 'mihomo service is not enabled'
  systemctl is-active mihomo >/dev/null 2>&1 || fail 'mihomo service is not active'
  ok 'mihomo service is active'
}

check_controller() {
  local secret url
  secret=$(extract_mihomo_secret) || fail 'Unable to extract Mihomo controller secret from config'
  url="$MIHOMO_CONTROLLER_URL/version"
  curl -fsS -H "Authorization: Bearer $secret" "$url" >/dev/null || fail "Unable to access Mihomo controller: $url"
  ok 'Mihomo controller is reachable'

  local encoded_group
  encoded_group=$(python3 - <<'PY' "$TARGET_GROUP"
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=''))
PY
)
  curl -fsS -H "Authorization: Bearer $secret" "$MIHOMO_CONTROLLER_URL/proxies/$encoded_group" >/dev/null || fail "Unable to query target group via Mihomo controller: $TARGET_GROUP"
  ok "Mihomo controller can query group: $TARGET_GROUP"
}

check_openclaw_config() {
  [ -f "$OPENCLAW_CONFIG" ] || fail "OpenClaw config not found: $OPENCLAW_CONFIG"
  python3 - "$OPENCLAW_CONFIG" "$TARGET_GROUP" <<'PY'
from pathlib import Path
import json
import sys

path = Path(sys.argv[1])
target_group = sys.argv[2]
obj = json.loads(path.read_text())

channels = obj.get('channels', {})
telegram = channels.get('telegram', {})
if not telegram.get('enabled'):
    raise SystemExit('Telegram channel is not enabled')
if not telegram.get('botToken'):
    raise SystemExit('Telegram botToken is missing')

plugins = obj.get('plugins', {})
entries = plugins.get('entries', {})
entry = entries.get('network-proxy-watchdog', {})
if not entry.get('enabled'):
    raise SystemExit('network-proxy-watchdog plugin is not enabled')

cfg = entry.get('config', {})
driver = cfg.get('driver', {})
if driver.get('type') != 'mihomo':
    raise SystemExit('network-proxy-watchdog driver.type is not mihomo')
if driver.get('groupName') != target_group:
    raise SystemExit(f'network-proxy-watchdog driver.groupName != {target_group}')
if cfg.get('healthCheck', {}).get('kind') != 'telegram-bot-api':
    raise SystemExit('network-proxy-watchdog healthCheck.kind is not telegram-bot-api')
print('ok')
PY
  ok 'OpenClaw config contains expected Telegram and network-proxy-watchdog settings'
}

check_openclaw_cli() {
  if ! command -v openclaw >/dev/null 2>&1; then
    warn 'openclaw CLI not found; skipping proxy-watchdog CLI checks'
    return
  fi
  openclaw proxy-watchdog status >/dev/null || fail 'openclaw proxy-watchdog status failed'
  openclaw proxy-watchdog describe-driver >/dev/null || fail 'openclaw proxy-watchdog describe-driver failed'
  openclaw proxy-watchdog current-target >/dev/null || fail 'openclaw proxy-watchdog current-target failed'
  ok 'OpenClaw proxy-watchdog CLI checks passed'
}

check_legacy_cleanup() {
  local legacy_files=(
    "$HOME/.local/bin/mihomo-telegram-watchdog.sh"
    "$HOME/.local/bin/mihomo-persist-telegram-policy.sh"
    "$HOME/.config/systemd/user/mihomo-telegram-watchdog.service"
    "$HOME/.config/systemd/user/mihomo-telegram-watchdog.timer"
    "$HOME/.config/mihomo/telegram-watchdog.env"
  )
  local path
  for path in "${legacy_files[@]}"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      warn "Legacy file still exists: $path"
    fi
  done

  if systemctl --user status mihomo-telegram-watchdog.service >/dev/null 2>&1; then
    warn 'Legacy user unit still exists: mihomo-telegram-watchdog.service'
  fi
  if systemctl --user status mihomo-telegram-watchdog.timer >/dev/null 2>&1; then
    warn 'Legacy user unit still exists: mihomo-telegram-watchdog.timer'
  fi
  ok 'Legacy watchdog cleanup check completed'
}

main() {
  need_cmd python3
  need_cmd curl
  need_cmd systemctl

  check_mihomo_binary
  check_mihomo_config
  check_rulesets
  check_group_in_config
  check_mihomo_service
  check_controller
  check_openclaw_config
  check_openclaw_cli
  check_legacy_cleanup
  ok 'Self-check completed successfully'
}

main "$@"
