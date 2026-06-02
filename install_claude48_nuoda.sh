#!/usr/bin/env bash
set -Eeuo pipefail

API_BASE_URL="${API_BASE_URL:-https://api.nuoda.vip}"
MODEL_ID="${MODEL_ID:-claude-opus-4-8}"
CHANNEL="${CHANNEL:-latest}"
AUTH_MODE="${AUTH_MODE:-both}" # both, x-api-key, bearer
SKIP_API_TEST="${SKIP_API_TEST:-0}"
STRICT_API_TEST="${STRICT_API_TEST:-0}"

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
  command -v "$1" >/dev/null 2>&1 || fail "缺少命令：$1"
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
[ -n "$TARGET_HOME" ] || fail "找不到用户 $TARGET_USER 的 home 目录"
TARGET_GROUP="$(id -gn "$TARGET_USER")"

case "$CHANNEL" in
  latest|stable) ;;
  *) fail "CHANNEL 只能是 latest 或 stable，当前是：$CHANNEL" ;;
esac

case "$AUTH_MODE" in
  both|x-api-key|bearer) ;;
  *) fail "AUTH_MODE 只能是 both、x-api-key 或 bearer，当前是：$AUTH_MODE" ;;
esac

API_BASE_URL="${API_BASE_URL%/}"
[ -n "$MODEL_ID" ] || fail "MODEL_ID 不能为空"

if [ -z "${NUODA_API_KEY:-}" ]; then
  if [ -t 0 ]; then
    printf '请输入 Nuoda API Key（输入时不会显示）：'
    stty -echo
    IFS= read -r NUODA_API_KEY
    stty echo
    printf '\n'
  else
    IFS= read -r NUODA_API_KEY
  fi
fi
[ -n "$NUODA_API_KEY" ] || fail "API Key 不能为空"

export API_BASE_URL MODEL_ID AUTH_MODE NUODA_API_KEY CHANNEL

log "安装基础依赖"
$SUDO apt-get update
$SUDO apt-get install -y ca-certificates curl gnupg python3 ripgrep

log "配置 Claude Code apt 源（$CHANNEL 渠道）"
$SUDO install -d -m 0755 /etc/apt/keyrings
$SUDO curl -fsSL https://downloads.claude.ai/keys/claude-code.asc \
  -o /etc/apt/keyrings/claude-code.asc

if command -v gpg >/dev/null 2>&1; then
  if ! gpg_output="$(gpg --show-keys --fingerprint /etc/apt/keyrings/claude-code.asc 2>/dev/null)"; then
    fail "无法读取 Claude Code 签名密钥"
  fi
  if ! printf '%s\n' "$gpg_output" | tr -d '[:space:]' | grep -Fq "$KEY_FINGERPRINT_COMPACT"; then
    printf '%s\n' "$gpg_output" >&2
    fail "Claude Code 签名密钥指纹不匹配"
  fi
fi

printf 'deb [signed-by=/etc/apt/keyrings/claude-code.asc] https://downloads.claude.ai/claude-code/apt/%s %s main\n' "$CHANNEL" "$CHANNEL" \
  | $SUDO tee /etc/apt/sources.list.d/claude-code.list >/dev/null

$SUDO apt-get update
$SUDO apt-get install -y claude-code

need_cmd claude
CLAUDE_VERSION="$(claude --version 2>/dev/null | grep -Eo '[0-9]+(\.[0-9]+)+' | head -n 1 || true)"
[ -n "$CLAUDE_VERSION" ] || fail "已安装 claude，但无法解析版本号：$(claude --version 2>/dev/null || true)"

if ! version_ge "$CLAUDE_VERSION" "$MIN_CLAUDE_VERSION"; then
  fail "Claude Code 当前版本 $CLAUDE_VERSION 低于 Opus 4.8 所需的 $MIN_CLAUDE_VERSION，请稍后重试 latest 渠道或手动升级"
fi
log "Claude Code 版本：$CLAUDE_VERSION"

CLAUDE_DIR="$TARGET_HOME/.claude"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"

log "写入 Claude Code 用户配置：$SETTINGS_FILE"
$SUDO install -d -m 0700 -o "$TARGET_USER" -g "$TARGET_GROUP" "$CLAUDE_DIR"

if [ -f "$SETTINGS_FILE" ]; then
  BACKUP_FILE="$SETTINGS_FILE.bak.$(date +%Y%m%d-%H%M%S)"
  $SUDO cp "$SETTINGS_FILE" "$BACKUP_FILE"
  $SUDO chown "$TARGET_USER:$TARGET_GROUP" "$BACKUP_FILE"
  $SUDO chmod 0600 "$BACKUP_FILE"
  log "已备份旧配置：$BACKUP_FILE"
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
    raise SystemExit(f"现有 settings.json 不是合法 JSON：{exc}") from exc

env = settings.get("env")
if not isinstance(env, dict):
    env = {}

env.update(
    {
        "ANTHROPIC_BASE_URL": api_base,
        "ANTHROPIC_DEFAULT_OPUS_MODEL": model_id,
        "ANTHROPIC_DEFAULT_SONNET_MODEL": model_id,
        "ANTHROPIC_DEFAULT_HAIKU_MODEL": model_id,
        "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME": "Claude Opus 4.8 via Nuoda",
        "ANTHROPIC_DEFAULT_OPUS_MODEL_DESCRIPTION": "Claude Opus 4.8 routed through Nuoda API gateway",
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
  log "测试 Nuoda Anthropic /v1/messages 接口"
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
    log "API 测试通过（HTTP $HTTP_CODE）"
  else
    warn "API 测试未通过（curl=$CURL_STATUS, HTTP=$HTTP_CODE）"
    warn "响应预览："
    sed -n '1,12p' "$TEST_BODY" >&2 || true
    warn "如果服务商使用 Bearer 鉴权，可重新运行：AUTH_MODE=bearer bash install_claude48_nuoda.sh"
    warn "如果服务商模型名不同，可重新运行：MODEL_ID=你的模型名 bash install_claude48_nuoda.sh"
    if [ "$STRICT_API_TEST" = "1" ]; then
      rm -f "$TEST_BODY"
      fail "STRICT_API_TEST=1，API 测试失败后退出"
    fi
  fi
  rm -f "$TEST_BODY"
fi

cat <<EOF

完成。

配置用户：$TARGET_USER
配置文件：$SETTINGS_FILE
API 地址：$API_BASE_URL
默认模型：opus -> $MODEL_ID
鉴权模式：$AUTH_MODE

现在可以运行：
  claude

如果要切换模型：
  claude --model opus

EOF
