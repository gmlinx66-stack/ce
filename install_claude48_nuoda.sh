#!/usr/bin/env bash
set -Eeuo pipefail

API_BASE_URL="${API_BASE_URL:-https://api.nuoda.vip}"
MODEL_ID="${MODEL_ID:-claude-opus-4-8}"
CHANNEL="${CHANNEL:-latest}"
AUTH_MODE="${AUTH_MODE:-both}" # both, x-api-key, bearer
SKIP_API_TEST="${SKIP_API_TEST:-0}"
STRICT_API_TEST="${STRICT_API_TEST:-0}"
NUODA_API_KEY="${NUODA_API_KEY:-}"

MIN_CLAUDE_VERSION="2.1.154"
KEY_FINGERPRINT_COMPACT="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"

log() {
  printf '\033[1;34m[INFO]\033[0m %s\n' "$*"
}

warn() {
  printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2
}

fail() {
  printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"
}

prompt_value() {
  local prompt_text="$1"
  local default_value="${2:-}"
  local secret_mode="${3:-0}"
  local result=""

  if [ -t 0 ]; then
    if [ "$secret_mode" = "1" ]; then
      printf '%s' "$prompt_text"
      stty -echo
      IFS= read -r result
      stty echo
      printf '\n'
    else
      if [ -n "$default_value" ]; then
        printf '%s [%s]: ' "$prompt_text" "$default_value"
      else
        printf '%s: ' "$prompt_text"
      fi
      IFS= read -r result
    fi
  else
    IFS= read -r result
  fi

  if [ -z "$result" ]; then
    result="$default_value"
  fi

  printf '%s' "$result"
}

version_ge() {
  python3 - "$1" "$2" <<'PY'
import re
import sys

def parts(value):
    return [int(x) for x in re.findall(r"\d+", value)[:3]]

left = parts(sys.argv[1])
right = parts(sys.argv[2])
left += [0] * (3 - len(left))
right += [0] * (3 - len(right))
raise SystemExit(0 if left >= right else 1)
PY
}

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
  TARGET_USER="${SUDO_USER:-root}"
else
  need_cmd sudo
  SUDO="sudo"
  TARGET_USER="$(id -un)"
fi

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[ -n "$TARGET_HOME" ] || fail "Cannot find home directory for $TARGET_USER"
TARGET_GROUP="$(id -gn "$TARGET_USER")"

case "$CHANNEL" in
  latest|stable) ;;
  *) fail "CHANNEL must be latest or stable" ;;
esac

case "$AUTH_MODE" in
  both|x-api-key|bearer) ;;
  *) fail "AUTH_MODE must be one of: both, x-api-key, bearer" ;;
esac

API_BASE_URL="$(prompt_value 'Enter API base URL' "$API_BASE_URL")"
API_BASE_URL="${API_BASE_URL%/}"
NUODA_API_KEY="${NUODA_API_KEY:-$(prompt_value 'Enter API key (hidden): ' '' 1)}"

[ -n "$API_BASE_URL" ] || fail "API base URL cannot be empty"
[ -n "$NUODA_API_KEY" ] || fail "API key cannot be empty"
[ -n "$MODEL_ID" ] || fail "MODEL_ID cannot be empty"

export API_BASE_URL MODEL_ID AUTH_MODE NUODA_API_KEY CHANNEL

log "Installing dependencies"
$SUDO apt-get update
$SUDO apt-get install -y ca-certificates curl gnupg python3 ripgrep

log "Configuring Claude Code apt repository ($CHANNEL channel)"
$SUDO install -d -m 0755 /etc/apt/keyrings
$SUDO curl -fsSL https://downloads.claude.ai/keys/claude-code.asc \
  -o /etc/apt/keyrings/claude-code.asc

if command -v gpg >/dev/null 2>&1; then
  if ! gpg_output="$(gpg --show-keys --fingerprint /etc/apt/keyrings/claude-code.asc 2>/dev/null)"; then
    fail "Unable to read Claude Code signing key"
  fi
  if ! printf '%s\n' "$gpg_output" | tr -d '[:space:]' | grep -Fq "$KEY_FINGERPRINT_COMPACT"; then
    printf '%s\n' "$gpg_output" >&2
    fail "Claude Code signing key fingerprint mismatch"
  fi
fi

printf 'deb [signed-by=/etc/apt/keyrings/claude-code.asc] https://downloads.claude.ai/claude-code/apt/%s %s main\n' "$CHANNEL" "$CHANNEL" \
  | $SUDO tee /etc/apt/sources.list.d/claude-code.list >/dev/null

$SUDO apt-get update
$SUDO apt-get install -y claude-code

need_cmd claude
CLAUDE_VERSION="$(claude --version 2>/dev/null | grep -Eo '[0-9]+(\.[0-9]+)+' | head -n 1 || true)"
[ -n "$CLAUDE_VERSION" ] || fail "Installed claude, but could not parse version"

if ! version_ge "$CLAUDE_VERSION" "$MIN_CLAUDE_VERSION"; then
  fail "Claude Code version $CLAUDE_VERSION is lower than required $MIN_CLAUDE_VERSION"
fi
log "Claude Code version: $CLAUDE_VERSION"

CLAUDE_DIR="$TARGET_HOME/.claude"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"

log "Writing Claude Code config: $SETTINGS_FILE"
$SUDO install -d -m 0700 -o "$TARGET_USER" -g "$TARGET_GROUP" "$CLAUDE_DIR"

if [ -f "$SETTINGS_FILE" ]; then
  BACKUP_FILE="$SETTINGS_FILE.bak.$(date +%Y%m%d-%H%M%S)"
  $SUDO cp "$SETTINGS_FILE" "$BACKUP_FILE"
  $SUDO chown "$TARGET_USER:$TARGET_GROUP" "$BACKUP_FILE"
  $SUDO chmod 0600 "$BACKUP_FILE"
  log "Backed up previous settings to $BACKUP_FILE"
fi

TMP_SETTINGS="$(mktemp)"
export SETTINGS_FILE TMP_SETTINGS

python3 <<'PY'
import json
import os
from pathlib import Path

settings_path = Path(os.environ["SETTINGS_FILE"])
tmp_path = Path(os.environ["TMP_SETTINGS"])
api_base = os.environ["API_BASE_URL"]
model_id = os.environ["MODEL_ID"]
api_key = os.environ["NUODA_API_KEY"]
auth_mode = os.environ["AUTH_MODE"]
channel = os.environ["CHANNEL"]

try:
    settings = json.loads(settings_path.read_text(encoding="utf-8"))
    if not isinstance(settings, dict):
        settings = {}
except FileNotFoundError:
    settings = {}
except json.JSONDecodeError as exc:
    raise SystemExit(f"Existing settings.json is not valid JSON: {exc}") from exc

env = settings.get("env")
if not isinstance(env, dict):
    env = {}

env.update(
    {
        "ANTHROPIC_BASE_URL": api_base,
        "ANTHROPIC_DEFAULT_OPUS_MODEL": model_id,
        "ANTHROPIC_DEFAULT_SONNET_MODEL": model_id,
        "ANTHROPIC_DEFAULT_HAIKU_MODEL": model_id,
        "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME": "Claude Opus 4.8 via custom gateway",
        "ANTHROPIC_DEFAULT_OPUS_MODEL_DESCRIPTION": "Claude Opus 4.8 routed through a custom API gateway",
        "ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES": "effort,xhigh_effort,max_effort,thinking,adaptive_thinking,interleaved_thinking",
        "CLAUDE_CODE_SUBAGENT_MODEL": "inherit",
        "CLAUDE_CODE_EFFORT_LEVEL": "high",
        "API_TIMEOUT_MS": "1200000",
        "ENABLE_TOOL_SEARCH": "false",
        "CLAUDE_CODE_ATTRIBUTION_HEADER": "0",
        "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    }
)

if auth_mode in {"both", "x-api-key"}:
    env["ANTHROPIC_API_KEY"] = api_key
else:
    env.pop("ANTHROPIC_API_KEY", None)

if auth_mode in {"both", "bearer"}:
    env["ANTHROPIC_AUTH_TOKEN"] = api_key
else:
    env.pop("ANTHROPIC_AUTH_TOKEN", None)

settings["env"] = env
settings["model"] = "opus"
settings["autoUpdatesChannel"] = channel
settings["effortLevel"] = "high"

tmp_path.write_text(json.dumps(settings, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

$SUDO cp "$TMP_SETTINGS" "$SETTINGS_FILE"
rm -f "$TMP_SETTINGS"
$SUDO chown "$TARGET_USER:$TARGET_GROUP" "$SETTINGS_FILE"
$SUDO chmod 0600 "$SETTINGS_FILE"

if [ "$SKIP_API_TEST" != "1" ]; then
  log "Testing $API_BASE_URL/v1/messages"
  TEST_BODY="$(mktemp)"
  TEST_HEADERS=(
    -H "Content-Type: application/json"
    -H "anthropic-version: 2023-06-01"
  )
  case "$AUTH_MODE" in
    both)
      TEST_HEADERS+=(-H "X-Api-Key: $NUODA_API_KEY" -H "Authorization: Bearer $NUODA_API_KEY")
      ;;
    x-api-key)
      TEST_HEADERS+=(-H "X-Api-Key: $NUODA_API_KEY")
      ;;
    bearer)
      TEST_HEADERS+=(-H "Authorization: Bearer $NUODA_API_KEY")
      ;;
  esac

  set +e
  HTTP_CODE="$(
    curl -sS -o "$TEST_BODY" -w '%{http_code}' \
      --connect-timeout 20 \
      --max-time 120 \
      "${TEST_HEADERS[@]}" \
      "$API_BASE_URL/v1/messages" \
      -d "{\"model\":\"$MODEL_ID\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}"
  )"
  CURL_STATUS=$?
  set -e

  if [ "$CURL_STATUS" -eq 0 ] && [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
    log "API test passed (HTTP $HTTP_CODE)"
  else
    warn "API test failed (curl=$CURL_STATUS, HTTP=$HTTP_CODE)"
    warn "Response preview:"
    sed -n '1,12p' "$TEST_BODY" >&2 || true
    warn "If your provider requires Bearer auth, rerun with: AUTH_MODE=bearer bash install_claude48_nuoda.sh"
    warn "If your provider uses a different model ID, rerun with: MODEL_ID=your-model-id bash install_claude48_nuoda.sh"
    if [ "$STRICT_API_TEST" = "1" ]; then
      rm -f "$TEST_BODY"
      fail "STRICT_API_TEST=1 and API test failed"
    fi
  fi
  rm -f "$TEST_BODY"
fi

cat <<EOF

Installation complete.

Configured user: $TARGET_USER
Settings file: $SETTINGS_FILE
API base URL: $API_BASE_URL
Default model mapping: opus -> $MODEL_ID
Auth mode: $AUTH_MODE

You can now run:
  claude

EOF
