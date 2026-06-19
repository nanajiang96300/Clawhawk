#!/usr/bin/env bash
# ============================================================
# clawhawk.sh — Single-Agent ClaudeClaw Session Manager
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAW_DIR="$SCRIPT_DIR/.claude/claudeclaw"
HISTORY_DIR="$CLAW_DIR/history"
SETTINGS_FILE="$CLAW_DIR/settings.json"
ENV_FILE="$SCRIPT_DIR/.env"
ENV_TEMPLATE="$SCRIPT_DIR/.env.template"

# ============================================================
# Secrets (loaded from .env, never committed)
# ============================================================

load_env() {
  if [ -f "$ENV_FILE" ]; then
    set -a
    . "$ENV_FILE"
    set +a
  fi
}

# Load env immediately for all commands
load_env

# Bun 路径 (winget 安装)
BUN_EXE="/c/Users/35583/AppData/Local/Microsoft/WinGet/Packages/Oven-sh.Bun_Microsoft.Winget.Source_8wekyb3d8bbwe/bun-windows-x64/bun.exe"
CLAUDE_PLUGIN_ROOT="/c/Users/35583/.claude/plugins/cache/claudeclaw/claudeclaw/1.0.39"

# ============================================================
# Helpers
# ============================================================

green()  { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
red()    { echo -e "\033[31m$1\033[0m"; }
bold()   { echo -e "\033[1m$1\033[0m"; }

check_env() {
  local ok=true
  if [ ! -f "$BUN_EXE" ]; then
    red "  ✗ Bun not found at $BUN_EXE"
    ok=false
  fi
  if ! which node &>/dev/null; then
    red "  ✗ Node.js not found"
    ok=false
  fi
  $ok
}

read_token() {
  grep '"token"' "$SETTINGS_FILE" 2>/dev/null | head -1 | sed 's/.*"token": *"//' | sed 's/".*//'
}

read_port() {
  grep '"port"' "$SETTINGS_FILE" 2>/dev/null | head -1 | sed 's/.*"port": *//' | sed 's/[^0-9]//g'
}

read_web_token() {
  cat "$CLAW_DIR/web.token" 2>/dev/null
}

read_session() {
  if [ -f "$CLAW_DIR/session.json" ]; then
    grep '"sessionId"' "$CLAW_DIR/session.json" | sed 's/.*"sessionId": *"//' | sed 's/[",]//g'
  fi
}

read_session_short() {
  read_session | cut -c1-8
}

read_turn_count() {
  grep '"turnCount"' "$CLAW_DIR/session.json" 2>/dev/null | sed 's/.*"turnCount": *//' | sed 's/[^0-9]//g'
}

read_created_at() {
  grep '"createdAt"' "$CLAW_DIR/session.json" 2>/dev/null | sed 's/.*"createdAt": *"//' | sed 's/[",]//g'
}

daemon_pid() {
  cat "$CLAW_DIR/daemon.pid" 2>/dev/null
}

is_daemon_alive() {
  # Check 1: PID file exists and process is in tasklist
  local pid=$(daemon_pid)
  if [ -n "$pid" ]; then
    # use tasklist (no nested quotes needed)
    tasklist 2>/dev/null | grep -q "bun.exe" && return 0
  fi
  return 1
}

# ----- Bot Rename -----

compute_bot_name() {
  local target="${1:-$SCRIPT_DIR}"
  local current=$(basename "$target")
  local parent=$(basename "$(dirname "$target")")

  # 根目录下的项目只取一级
  if [ "$parent" = "/" ] || [ "$parent" = "" ] || [ "$parent" = "." ]; then
    parent=""
  fi

  local raw
  if [ -n "$parent" ]; then
    raw="Claude_Code_${parent}/${current}"
  else
    raw="Claude_Code_${current}"
  fi

  # 清理非法字符 (Discord 只允许字母数字下划线连字符)
  raw=$(echo "$raw" | sed 's/[^a-zA-Z0-9_\/-]/-/g')

  # Discord 32 字符限制
  if [ ${#raw} -gt 32 ]; then
    # 截断父目录名
    local prefix="Claude_Code_"
    local max_path=$((32 - ${#prefix}))
    local truncated="${parent:0:$((max_path - ${#current} - 1))}/${current}"
    raw="${prefix}${truncated}"
    [ ${#raw} -gt 32 ] && raw="${raw:0:32}"
  fi

  echo "$raw"
}

do_rename() {
  local token=$(read_token)
  local name="$1"

  if [ -z "$token" ]; then
    red "No bot token configured. Run 'clawhawk init' first."
    return 1
  fi

  if [ -z "$name" ]; then
    name=$(compute_bot_name)
  fi

  echo -n "Renaming bot to '$name'... "

  local resp=$(curl -s -X PATCH "https://discord.com/api/v10/users/@me" \
    -H "Authorization: Bot $token" \
    -H "Content-Type: application/json" \
    -d "{\"username\": \"$name\"}" 2>&1)

  if echo "$resp" | grep -q '"username"'; then
    local new_name=$(echo "$resp" | sed 's/.*"username":"//' | sed 's/".*//')
    green "✓ $new_name"
  elif echo "$resp" | grep -q '"message"'; then
    local err=$(echo "$resp" | sed 's/.*"message":"//' | sed 's/".*//')

    # 频繁改名 → 非致命
    if echo "$err" | grep -qi "rate\|too fast\|too many"; then
      yellow "⏳ Rate limited (2/hr max). Will retry later."
      return 0
    fi

    # 名称相同 → 跳过
    if echo "$err" | grep -qi "already"; then
      echo "Name unchanged."
      return 0
    fi

    # 其他错误
    yellow "Discord: $err"
    return 0
  else
    echo "Done."
  fi
}

# ----- Session Backup -----

backup_current() {
  local session_id=$(read_session)
  if [ -z "$session_id" ]; then
    return 0  # 没有活动会话，无需备份
  fi

  mkdir -p "$HISTORY_DIR"

  local suffix=1
  while [ -f "$HISTORY_DIR/session_${suffix}.backup" ]; do
    suffix=$((suffix + 1))
  done

  cp "$CLAW_DIR/session.json" "$HISTORY_DIR/session_${suffix}.backup"
  echo "session_${suffix}.backup"
}

list_backups() {
  if [ ! -d "$HISTORY_DIR" ]; then
    echo ""
    return
  fi

  local files=$(ls -1t "$HISTORY_DIR"/session_*.backup 2>/dev/null)
  if [ -z "$files" ]; then
    echo ""
    return
  fi

  local i=1
  for f in $files; do
    local sid=$(grep '"sessionId"' "$f" 2>/dev/null | sed 's/.*"sessionId": *"//' | sed 's/[",]//g' | cut -c1-8)
    local created=$(grep '"createdAt"' "$f" 2>/dev/null | sed 's/.*"createdAt": *"//' | sed 's/[",]//g' | cut -c1-16)
    local turns=$(grep '"turnCount"' "$f" 2>/dev/null | sed 's/.*"turnCount": *//' | sed 's/[^0-9]//g')
    local basename=$(basename "$f")
    printf "  %-3d %-12s %-20s %-5s turns  %s\n" "$i" "$sid" "$created" "${turns:-0}" "$basename"
    i=$((i + 1))
  done
}

# ============================================================
# Commands
# ============================================================

cmd_init() {
  local bot_name=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name|-n) bot_name="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  echo ""
  bold "  🦅 ClawHawk Agent Setup"
  echo "  ========================"
  echo ""

  # 1. Check environment
  echo "  Checking environment..."
  check_env
  echo ""

  # 2. Load or create .env
  if [ ! -f "$ENV_FILE" ]; then
    if [ -f "$ENV_TEMPLATE" ]; then
      cp "$ENV_TEMPLATE" "$ENV_FILE"
      green "  ✓ .env created from template"
      echo ""
      bold "  ⚠  Edit .env with your real credentials before running 'up':"
      echo "     1. Open .env in your editor"
      echo "     2. Fill in CLAWHAWK_DISCORD_TOKEN and CLAWHAWK_DISCORD_USER_ID"
      echo "     3. Run: ./clawhawk.sh up"
      echo ""
      return 0
    else
      red "  No .env.template found. Creating minimal .env..."
      cat > "$ENV_FILE" << 'EOF'
CLAWHAWK_DISCORD_TOKEN=your_bot_token_here
CLAWHAWK_DISCORD_USER_ID=your_discord_user_id_here
CLAWHAWK_TIMEZONE=UTC+8
CLAWHAWK_SECURITY=moderate
EOF
      green "  ✓ .env created — edit it before running 'up'"
      echo ""
      return 0
    fi
  fi

  # Reload env if just created
  load_env

  # 3. Create directories
  echo "  Creating directories..."
  mkdir -p "$CLAW_DIR/logs"
  mkdir -p "$CLAW_DIR/jobs"
  mkdir -p "$HISTORY_DIR"
  green "  ✓ .claude/claudeclaw/"
  green "  ✓ .claude/claudeclaw/history/"
  echo ""

  # 4. Write settings.json from .env
  local token="${CLAWHAWK_DISCORD_TOKEN:-}"
  local user="${CLAWHAWK_DISCORD_USER_ID:-}"
  local tz="${CLAWHAWK_TIMEZONE:-UTC+8}"
  local sec="${CLAWHAWK_SECURITY:-moderate}"

  if [ "$token" = "your_bot_token_here" ] || [ -z "$token" ]; then
    red "  CLAWHAWK_DISCORD_TOKEN not set in .env"
    echo "  Edit .env and fill in your credentials."
    return 1
  fi

  cat > "$SETTINGS_FILE" << EOF
{
  "model": "",
  "api": "",
  "fallback": { "model": "", "api": "" },
  "agentic": { "enabled": false },
  "timezone": "$tz",
  "heartbeat": {
    "enabled": false,
    "interval": 15,
    "prompt": "",
    "excludeWindows": [],
    "forwardToTelegram": true
  },
  "discord": {
    "token": "$token",
    "allowedUserIds": ["$user"],
    "listenChannels": []
  },
  "telegram": { "token": "", "allowedUserIds": [] },
  "session": {
    "autoRotate": false,
    "maxMessages": 50,
    "maxAgeHours": 24,
    "summaryPath": ""
  },
  "security": {
    "level": "$sec",
    "allowedTools": [],
    "disallowedTools": []
  },
  "web": {
    "enabled": true,
    "host": "127.0.0.1",
    "port": 4632
  }
}
EOF
  green "  ✓ settings.json (from .env)"
  echo ""

  # 5. Create CLAUDE.md if not exists
  if [ ! -f "$SCRIPT_DIR/CLAUDE.md" ] || [ ! -s "$SCRIPT_DIR/CLAUDE.md" ]; then
    cat > "$SCRIPT_DIR/CLAUDE.md" << 'EOF'
# CLAUDE.md — ClawHawk Agent

**Agent Name:** {{NAME}}
**Created:** {{DATE}}

## Who I Am

A helpful AI agent running in this project. I maintain persistent context across sessions and respond to Discord messages.

## Project Context

_(Describe your project here. What am I helping you build?)_

## My Capabilities

- Code reading, writing, and refactoring
- Running shell commands
- Web searches and research
- File and project management

## Communication Style

- Direct and concise
- Use code blocks for code
- React with emoji when appropriate
EOF
    green "  ✓ CLAUDE.md (template — please customize)"
  else
    yellow "  ⚠ CLAUDE.md exists — skipping"
  fi

  echo ""
  bold "  Next Steps:"
  echo "    1. Edit CLAUDE.md to define your agent's personality"
  echo "    2. Run: ./clawhawk.sh up"
  echo "    3. DM your bot on Discord"
  echo ""
}

cmd_up() {
  local web_flag=false
  local web_port=""
  local no_rename=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --web) web_flag=true; shift ;;
      --port) web_port="$2"; shift 2 ;;
      --no-rename) no_rename=true; shift ;;
      *) shift ;;
    esac
  done

  # Check if already running
  if is_daemon_alive; then
    local pid=$(daemon_pid)
    local sid=$(read_session_short)
    yellow "Agent already running (PID: $pid, Session: $sid)"
    cmd_status
    return 0
  fi

  # Check settings exist
  if [ ! -f "$SETTINGS_FILE" ]; then
    red "No settings.json found. Run './clawhawk.sh init --with-discord' first."
    exit 1
  fi

  local token=$(read_token)
  if [ -z "$token" ]; then
    red "No Discord token configured. Run './clawhawk.sh init --with-discord' first."
    exit 1
  fi

  echo ""
  bold "  🦅 Starting ClawHawk Agent"
  echo "  =========================="
  echo ""

  # 1. Rename bot
  if ! $no_rename; then
    local bot_name=$(compute_bot_name)
    do_rename "$bot_name"
  fi

  # 2. Clean stale PID
  rm -f "$CLAW_DIR/daemon.pid"

  # 3. Start daemon
  local extra_args=""
  $web_flag && extra_args="--web"
  if [ -n "$web_port" ]; then
    extra_args="$extra_args --web-port $web_port"
  fi

  echo -n "Starting daemon... "
  nohup "$BUN_EXE" run "${CLAUDE_PLUGIN_ROOT}/src/index.ts" start $extra_args \
    > "$CLAW_DIR/logs/daemon.log" 2>&1 &
  local outer_pid=$!

  # Wait for internal PID
  sleep 3

  if ! is_daemon_alive; then
    red "✗ Daemon failed to start. Check logs:"
    echo ""
    tail -20 "$CLAW_DIR/logs/daemon.log"
    exit 1
  fi

  local pid=$(daemon_pid)
  green "✓ PID: $pid"

  # 4. Wait for Discord Ready
  echo -n "Waiting for Discord... "
  local waited=0
  while [ $waited -lt 30 ]; do
    if grep -q "Ready as" "$CLAW_DIR/logs/daemon.log" 2>/dev/null; then
      local ready_line=$(grep "Ready as" "$CLAW_DIR/logs/daemon.log" | tail -1)
      local bot_info=$(echo "$ready_line" | sed 's/.*Ready as //' | sed 's/ (.*//')
      local bot_id=$(echo "$ready_line" | sed 's/.*(//' | sed 's/).*//')
      green "✓ $bot_info ($bot_id)"
      break
    fi
    sleep 2
    waited=$((waited + 2))
    echo -n "."
  done

  if [ $waited -ge 30 ]; then
    yellow "⚠ Discord not ready yet. Check: ./clawhawk.sh status"
  fi

  # 5. Session info
  local sid=$(read_session_short)
  local turns=$(read_turn_count)
  if [ -n "$sid" ]; then
    echo "  Session:    ${sid} (${turns:-0} turns)"
  else
    echo "  Session:    bootstrapping..."
  fi

  # 6. Web UI
  local port=$(read_port)
  local web_token=$(read_web_token)
  if [ -n "$port" ] && [ -n "$web_token" ]; then
    echo "  Web UI:     http://127.0.0.1:${port}/?token=${web_token}"
  fi

  # 7. Discord link
  if [ -n "$bot_id" ]; then
    echo ""
    echo "  DM your bot: https://discord.com/users/${bot_id}"
  fi

  echo ""
}

cmd_down() {
  local force=false
  [[ "$1" == "--force" ]] && force=true

  if ! is_daemon_alive; then
    yellow "Agent is not running."
    rm -f "$CLAW_DIR/daemon.pid"
    return 0
  fi

  local pid=$(daemon_pid)
  echo -n "Stopping agent (PID: $pid)... "

  if $force; then
    taskkill //F //PID "$pid" 2>/dev/null || true
  else
    taskkill //PID "$pid" 2>/dev/null || true
  fi

  sleep 2
  rm -f "$CLAW_DIR/daemon.pid"
  green "✓ Stopped"
}

cmd_new() {
  local keep_backup=true

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-backup) keep_backup=false; shift ;;
      --keep-backup) keep_backup=true; shift ;;
      *) shift ;;
    esac
  done

  echo ""

  local current=$(read_session)
  local backup_name=""

  if [ -n "$current" ]; then
    if $keep_backup; then
      echo -n "Backing up current session... "
      backup_name=$(backup_current)
      green "✓ $backup_name"
    else
      yellow "Discarding current session (--no-backup)"
    fi
    rm -f "$CLAW_DIR/session.json"
  else
    echo "No active session to backup."
  fi

  # Restart daemon if running
  if is_daemon_alive; then
    echo "Restarting daemon..."
    cmd_down
    sleep 1
    cmd_up --no-rename  # 名称已经设置过，不用再改
  else
    cmd_up --no-rename
  fi

  # Wait for new session
  sleep 5
  local new_sid=$(read_session_short)
  if [ -n "$new_sid" ]; then
    echo ""
    green "✨ New session: $new_sid"
    [ -n "$backup_name" ] && echo "   Backup: $backup_name"
  fi
  echo ""
}

cmd_resume() {
  local target="$1"

  # --list flag: show backups and exit
  if [ "$target" = "--list" ]; then
    cmd_history
    return
  fi

  # No target: interactive selection
  if [ -z "$target" ]; then
    if [ ! -d "$HISTORY_DIR" ] || [ -z "$(ls "$HISTORY_DIR"/session_*.backup 2>/dev/null)" ]; then
      red "No session backups found."
      echo ""
      echo "Create a backup first with:"
      echo "  ./clawhawk.sh new    (backs up current, starts fresh)"
      exit 1
    fi

    cmd_history
    echo ""
    echo -n "Enter session # or ID prefix: "
    read target
  fi

  # Find the backup
  local backup_file=""

  # Try as index number
  if echo "$target" | grep -q '^[0-9]\+$'; then
    backup_file=$(ls -1t "$HISTORY_DIR"/session_*.backup 2>/dev/null | sed -n "${target}p")
  fi

  # Try as session ID prefix (8 chars)
  if [ -z "$backup_file" ]; then
    for f in "$HISTORY_DIR"/session_*.backup; do
      [ ! -f "$f" ] && continue
      local sid=$(grep '"sessionId"' "$f" | sed 's/.*"sessionId": *"//' | sed 's/[",]//g')
      if echo "$sid" | grep -q "^$target"; then
        backup_file="$f"
        break
      fi
    done
  fi

  if [ -z "$backup_file" ] || [ ! -f "$backup_file" ]; then
    red "No backup matched '$target'."
    echo "Use './clawhawk.sh history' to see available sessions."
    exit 1
  fi

  echo ""
  echo -n "Restoring $(basename "$backup_file")... "

  # Backup current first
  local current=$(read_session)
  [ -n "$current" ] && backup_current > /dev/null

  # Restore
  cp "$backup_file" "$CLAW_DIR/session.json"
  green "✓ Restored"

  # Restart
  if is_daemon_alive; then
    cmd_down
    sleep 1
  fi
  cmd_up --no-rename

  echo ""
  green "↩ Session restored."
  echo ""
}

cmd_history() {
  local detail=false

  [[ "$1" == "--detail" ]] && detail=true
  [[ "$1" == "--json" ]] && { echo "TODO: JSON output"; return; }

  echo ""
  bold "  📋 Session History"
  echo "  ================="
  echo ""

  if [ ! -d "$HISTORY_DIR" ] || [ -z "$(ls "$HISTORY_DIR"/session_*.backup 2>/dev/null)" ]; then
    yellow "  No backed-up sessions yet."
    echo ""
    echo "  Sessions are backed up when you run 'clawhawk new'."
    echo ""
    return
  fi

  printf "  %-3s %-12s %-20s %-10s %s\n" "#" "ID" "Created" "Turns" "File"
  printf "  %-3s %-12s %-20s %-10s %s\n" "───" "──────────" "──────────────────" "────────" "────"

  local current_sid=$(read_session)
  local current_short=""
  [ -n "$current_sid" ] && current_short=$(echo "$current_sid" | cut -c1-8)

  local i=1
  for f in $(ls -1t "$HISTORY_DIR"/session_*.backup 2>/dev/null); do
    local sid=$(grep '"sessionId"' "$f" 2>/dev/null | sed 's/.*"sessionId": *"//' | sed 's/[",]//g' | cut -c1-8)
    local created=$(grep '"createdAt"' "$f" 2>/dev/null | sed 's/.*"createdAt": *"//' | sed 's/[",]//g' | sed 's/T/ /' | cut -c1-16)
    local turns=$(grep '"turnCount"' "$f" 2>/dev/null | sed 's/.*"turnCount": *//' | sed 's/[^0-9]//g')
    local fname=$(basename "$f")
    local marker=" "
    [ "$sid" = "$current_short" ] && marker="*"
    printf "  %-3s %-12s %-20s %-5s turns  %s\n" "${i}${marker}" "$sid" "${created:-unknown}" "${turns:-0}" "$fname"
    i=$((i + 1))
  done

  echo ""
  echo "  * = current session"
  echo ""
  echo "  Resume:  ./clawhawk.sh resume <# or ID>"
  echo ""
}

cmd_rename() {
  local name="$1"

  if [ -z "$name" ]; then
    name=$(compute_bot_name)
    echo "Auto-computed name: $name"
  fi

  do_rename "$name"
}

cmd_status() {
  echo ""
  bold "  🦅 ClawHawk Status"
  echo "  ================="
  echo ""

  # Daemon status
  if is_daemon_alive; then
    local pid=$(daemon_pid)
    green "  Status:     🟢 Running (PID: $pid)"
  else
    red "  Status:     ⚫ Stopped"
  fi

  # Discord status
  if is_daemon_alive; then
    local log="$CLAW_DIR/logs/daemon.log"
    if grep -q "Ready as" "$log" 2>/dev/null; then
      local ready=$(grep "Ready as" "$log" 2>/dev/null | tail -1 | sed 's/.*Ready as //' | sed 's/ (.*//')
      local bot_id=$(grep "Ready as" "$log" 2>/dev/null | tail -1 | sed 's/.*(//' | sed 's/).*//')
      green "  Discord:    ✅ $ready ($bot_id)"
    else
      yellow "  Discord:    ⏳ Connecting..."
    fi
  else
    echo "  Discord:    —"
  fi

  # Session
  local sid=$(read_session)
  if [ -n "$sid" ]; then
    local short=$(echo "$sid" | cut -c1-8)
    local turns=$(read_turn_count)
    local created=$(read_created_at | sed 's/T/ /' | cut -c1-16)
    echo "  Session:    ${short} (${turns:-0} turns, created ${created:-unknown})"
  else
    echo "  Session:    none"
  fi

  # Web UI
  local port=$(read_port)
  if is_daemon_alive && [ -n "$port" ]; then
    local web_token=$(read_web_token)
    if [ -n "$web_token" ]; then
      echo "  Web UI:     http://127.0.0.1:${port}/?token=${web_token}"
    fi
  fi

  # Token configured?
  local token=$(read_token)
  if [ -n "$token" ]; then
    echo "  Bot Token:  configured (${#token} chars)"
  else
    red "  Bot Token:  NOT CONFIGURED"
  fi

  # History
  if [ -d "$HISTORY_DIR" ]; then
    local count=$(ls "$HISTORY_DIR"/session_*.backup 2>/dev/null | wc -l)
    echo "  History:    ${count// /} backed-up sessions"
  fi

  # Bot name
  local bot_name=$(compute_bot_name)
  echo "  Bot Name:   $bot_name"

  echo ""
  echo "  Commands: up | down | new | resume | history | rename | status"
  echo ""
}

cmd_autostart() {
  local action="${1:-install}"

  if [ "$action" = "remove" ] || [ "$action" = "uninstall" ]; then
    # Remove from startup
    rm -f "$APPDATA/Microsoft/Windows/Start Menu/Programs/Startup/ClawHawk-$USER.bat" 2>/dev/null
    schtasks /Delete /TN "ClawHawk" /F 2>/dev/null || true
    green "✓ Auto-start removed"
    return 0
  fi

  echo ""
  bold "  🔧 Configuring Auto-Start"
  echo "  =========================="
  echo ""

  # Determine Windows Startup folder
  local startup_dir=$(cmd.exe /c "echo %APPDATA%" 2>/dev/null | tr -d '\r\n')
  startup_dir="${startup_dir}\\Microsoft\\Windows\\Start Menu\\Programs\\Startup"
  startup_dir=$(echo "$startup_dir" | sed 's/\\/\//g' | sed 's/^C:/\/c/')

  if [ ! -d "$startup_dir" ]; then
    red "  Cannot find Startup folder"
    return 1
  fi

  # Create batch file that launches clawhawk
  local bat_path="${startup_dir}/ClawHawk-${USER}.bat"
  cat > "$bat_path" << BAT_EOF
@echo off
start "ClawHawk" /MIN "C:\\Program Files\\Git\\bin\\bash.exe" -c "cd ${SCRIPT_DIR} && ./clawhawk.sh up >> .claude/claudeclaw/logs/autostart.log 2>&1"
BAT_EOF

  green "  ✓ Startup script created"
  echo "     $bat_path"
  echo ""
  echo "  The agent will start automatically when you log in."
  echo "  Logs: .claude/claudeclaw/logs/autostart.log"
  echo ""
  echo "  To remove: ./clawhawk.sh autostart remove"
  echo ""
}

show_help() {
  echo ""
  bold "  🦅 ClawHawk — Single-Agent Session Manager"
  echo "  =========================================="
  echo ""
  echo "  Usage: ./clawhawk.sh <command> [options]"
  echo ""
  echo "  Commands:"
  echo "    init          Initialize agent project from .env"
  echo "    up            Start daemon + rename bot + connect Discord"
  echo "    down          Stop daemon"
  echo "    new           Backup current session, start fresh"
  echo "    resume [id]   Restore historical session"
  echo "    history       List backed-up sessions"
  echo "    rename [name] Set Discord bot display name"
  echo "    autostart     Configure Windows auto-start at login"
  echo "    status        Show current agent status"
  echo ""
  echo "  Examples:"
  echo "    cp .env.template .env  # then edit .env with real credentials"
  echo "    ./clawhawk.sh init"
  echo "    ./clawhawk.sh up"
  echo "    ./clawhawk.sh autostart"
  echo ""
}

# ============================================================
# Main
# ============================================================

cd "$SCRIPT_DIR"

case "${1:-}" in
  init)     shift; cmd_init "$@" ;;
  up|start) shift; cmd_up "$@" ;;
  down|stop) shift; cmd_down "$@" ;;
  new|fresh) shift; cmd_new "$@" ;;
  resume|restore) shift; cmd_resume "$@" ;;
  history|list) shift; cmd_history "$@" ;;
  rename|name) shift; cmd_rename "$@" ;;
  autostart) shift; cmd_autostart "$@" ;;
  status|st) shift; cmd_status "$@" ;;
  help|-h|--help) show_help ;;
  *)
    show_help
    exit 1
    ;;
esac
