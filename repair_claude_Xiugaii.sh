#!/usr/bin/env bash
set -Eeuo pipefail

API_BASE_URL="${API_BASE_URL:-}"
API_KEY="${API_KEY:-}"
MODEL_ID="${MODEL_ID:-claude-opus-4-8}"
AUTH_MODE="${AUTH_MODE:-both}" # both, x-api-key, bearer
TARGET_USERS="${TARGET_USERS:-root admin}"
SKIP_API_TEST="${SKIP_API_TEST:-0}"

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

prompt_required() {
  local var_name="$1"
  local prompt_text="$2"
  local current_value="${!var_name:-}"

  while [ -z "$current_value" ]; do
    read -r -p "$prompt_text: " current_value
  done

  printf -v "$var_name" '%s' "$current_value"
}

prompt_secret_required() {
  local var_name="$1"
  local prompt_text="$2"
  local current_value="${!var_name:-}"

  while [ -z "$current_value" ]; do
    read -r -s -p "$prompt_text: " current_value
    printf '\n'
  done

  printf -v "$var_name" '%s' "$current_value"
}

[ "$(id -u)" -eq 0 ] || fail "Please run this script as root"

need_cmd python3
need_cmd getent
need_cmd install
need_cmd id

prompt_required API_BASE_URL "请输入 API 地址，例如 https://api.example.com"
prompt_secret_required API_KEY "请输入 API Key"

case "$AUTH_MODE" in
  both|x-api-key|bearer) ;;
  *) fail "AUTH_MODE must be one of: both, x-api-key, bearer" ;;
esac

API_BASE_URL="${API_BASE_URL%/}"
[ -n "$API_BASE_URL" ] || fail "API_BASE_URL cannot be empty"
[ -n "$API_KEY" ] || fail "API_KEY cannot be empty"
[ -n "$MODEL_ID" ] || fail "MODEL_ID cannot be empty"

export API_BASE_URL API_KEY MODEL_ID AUTH_MODE

update_user_settings() {
  local target_user="$1"
  local target_home
  local target_group
  local claude_dir
  local settings_file
  local tmp_file

  if ! id "$target_user" >/dev/null 2>&1; then
    warn "User not found, skipping: $target_user"
    return 0
  fi

  target_home="$(getent passwd "$target_user" | cut -d: -f6)"
  [ -n "$target_home" ] || fail "Cannot find home directory for $target_user"
  target_group="$(id -gn "$target_user")"
  claude_dir="$target_home/.claude"
  settings_file="$claude_dir/settings.json"

  log "Updating Claude config for user: $target_user"
  install -d -m 0700 -o "$target_user" -g "$target_group" "$claude_dir"

  if [ -f "$settings_file" ]; then
    cp "$settings_file" "$settings_file.bak.$(date +%Y%m%d-%H%M%S)"
  fi

  tmp_file="$(mktemp)"
  export SETTINGS_FILE="$settings_file" TMP_FILE="$tmp_file"

  python3 <<'PY'
import json
import os
from pathlib import Path

settings_path = Path(os.environ["SETTINGS_FILE"])
tmp_path = Path(os.environ["TMP_FILE"])
api_base = os.environ["API_BASE_URL"]
api_key = os.environ["API_KEY"]
model_id = os.environ["MODEL_ID"]
auth_mode = os.environ["AUTH_MODE"]

try:
    settings = json.loads(settings_path.read_text(encoding="utf-8"))
    if not isinstance(settings, dict):
        settings = {}
except FileNotFoundError:
    settings = {}
except json.JSONDecodeError:
    settings = {}

env = settings.get("env")
if not isinstance(env, dict):
    env = {}

env.update(
    {
        "ANTHROPIC_BASE_URL": api_base,
        "ANTHROPIC_DEFAULT_OPUS_MODEL": model_id,
        "ANTHROPIC_DEFAULT_SONNET_MODEL": model_id,
        "ANTHROPIC_DEFAULT_HAIKU_MODEL": model_id,
        "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME": "Claude Opus 4.8 via ZJAPI",
        "ANTHROPIC_DEFAULT_OPUS_MODEL_DESCRIPTION": "Claude Opus 4.8 routed through ZJAPI gateway",
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
settings["effortLevel"] = "high"

tmp_path.write_text(json.dumps(settings, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

  cp "$tmp_file" "$settings_file"
  rm -f "$tmp_file"
  chown "$target_user:$target_group" "$settings_file"
  chmod 0600 "$settings_file"
}

for user_name in $TARGET_USERS; do
  update_user_settings "$user_name"
done

if [ "$SKIP_API_TEST" != "1" ]; then
  need_cmd curl
  log "Testing $API_BASE_URL/v1/messages"
  test_body="$(mktemp)"
  headers=(
    -H "Content-Type: application/json"
    -H "anthropic-version: 2023-06-01"
  )
  case "$AUTH_MODE" in
    both)
      headers+=(-H "X-Api-Key: $API_KEY" -H "Authorization: Bearer $API_KEY")
      ;;
    x-api-key)
      headers+=(-H "X-Api-Key: $API_KEY")
      ;;
    bearer)
      headers+=(-H "Authorization: Bearer $API_KEY")
      ;;
  esac

  set +e
  http_code="$(
    curl -sS -o "$test_body" -w '%{http_code}' \
      --connect-timeout 20 \
      --max-time 120 \
      "${headers[@]}" \
      "$API_BASE_URL/v1/messages" \
      -d "{\"model\":\"$MODEL_ID\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}"
  )"
  curl_status=$?
  set -e

  if [ "$curl_status" -eq 0 ] && [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
    log "API test passed with HTTP $http_code"
  else
    warn "API test failed: curl=$curl_status, HTTP=$http_code"
    sed -n '1,12p' "$test_body" >&2 || true
  fi
  rm -f "$test_body"
fi

cat <<EOF

Repair complete.

API base URL: $API_BASE_URL
Model: $MODEL_ID
Users updated: $TARGET_USERS
Auth mode: $AUTH_MODE

Next steps:
  su - admin
  claude --model opus -p "Please reply with: connection ok"

EOF
