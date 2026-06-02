#!/usr/bin/env bash
set -Eeuo pipefail

CLAUDE_USER="${CLAUDE_USER:-admin}"
CLAUDE_SHELL="${CLAUDE_SHELL:-/bin/bash}"
SOURCE_CLAUDE_DIR="${SOURCE_CLAUDE_DIR:-/root/.claude}"
PERMISSION_MODE="${PERMISSION_MODE:-bypassPermissions}"
MODEL="${MODEL:-opus}"
ALLOW_NOPASSWD_SUDO="${ALLOW_NOPASSWD_SUDO:-1}"

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

[ "$(id -u)" -eq 0 ] || fail "请用 root 运行这个脚本"

need_cmd getent
need_cmd id
need_cmd install

if ! command -v sudo >/dev/null 2>&1; then
  log "安装 sudo"
  apt-get update
  apt-get install -y sudo
fi

if ! id "$CLAUDE_USER" >/dev/null 2>&1; then
  log "创建普通用户：$CLAUDE_USER"
  if command -v adduser >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" --shell "$CLAUDE_SHELL" "$CLAUDE_USER"
    passwd "$CLAUDE_USER"
  else
    useradd -m -s "$CLAUDE_SHELL" "$CLAUDE_USER"
    passwd "$CLAUDE_USER"
  fi
else
  log "用户已存在：$CLAUDE_USER"
fi

CLAUDE_HOME="$(getent passwd "$CLAUDE_USER" | cut -d: -f6)"
[ -n "$CLAUDE_HOME" ] || fail "找不到 $CLAUDE_USER 的 home 目录"
CLAUDE_GROUP="$(id -gn "$CLAUDE_USER")"

log "加入 sudo 用户组"
usermod -aG sudo "$CLAUDE_USER"

if [ "$ALLOW_NOPASSWD_SUDO" = "1" ]; then
  log "配置 $CLAUDE_USER 免密码 sudo"
  SUDOERS_FILE="/etc/sudoers.d/${CLAUDE_USER}-nopasswd"
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$CLAUDE_USER" > "$SUDOERS_FILE"
  chmod 0440 "$SUDOERS_FILE"
  visudo -cf "$SUDOERS_FILE" >/dev/null
else
  warn "已跳过免密码 sudo：ALLOW_NOPASSWD_SUDO=$ALLOW_NOPASSWD_SUDO"
fi

log "复制 Claude 配置到 $CLAUDE_USER"
install -d -m 0700 -o "$CLAUDE_USER" -g "$CLAUDE_GROUP" "$CLAUDE_HOME/.claude"
if [ -d "$SOURCE_CLAUDE_DIR" ]; then
  cp -a "$SOURCE_CLAUDE_DIR/." "$CLAUDE_HOME/.claude/"
else
  warn "没有找到 $SOURCE_CLAUDE_DIR；如果还没配置 Nuoda API，请先运行安装 Claude 的脚本"
fi
chown -R "$CLAUDE_USER:$CLAUDE_GROUP" "$CLAUDE_HOME/.claude"
chmod 0700 "$CLAUDE_HOME/.claude"
[ ! -f "$CLAUDE_HOME/.claude/settings.json" ] || chmod 0600 "$CLAUDE_HOME/.claude/settings.json"

BASHRC="$CLAUDE_HOME/.bashrc"
ALIAS_LINE="alias claude='command claude --model $MODEL --permission-mode $PERMISSION_MODE'"

log "设置 claude 默认不询问权限"
touch "$BASHRC"
if grep -q "^alias claude=" "$BASHRC"; then
  sed -i "s|^alias claude=.*|$ALIAS_LINE|" "$BASHRC"
else
  printf '\n%s\n' "$ALIAS_LINE" >> "$BASHRC"
fi
chown "$CLAUDE_USER:$CLAUDE_GROUP" "$BASHRC"

cat <<EOF

配置完成。

普通用户：$CLAUDE_USER
Claude 配置：$CLAUDE_HOME/.claude
默认命令：claude --model $MODEL --permission-mode $PERMISSION_MODE
免密 sudo：$ALLOW_NOPASSWD_SUDO

现在切换到普通用户：
  su - $CLAUDE_USER

然后运行：
  claude

如果需要 root 权限，让 Claude 执行 sudo 命令即可，例如：
  sudo apt update

EOF
