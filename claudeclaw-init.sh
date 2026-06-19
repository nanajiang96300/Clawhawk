#!/usr/bin/env bash
# ============================================================
# claudeclaw-init.sh
# 一键在指定目录初始化 ClaudeClaw + Discord
#
# 用法:
#   ./claudeclaw-init.sh \
#       --token "MTUxNzE4..." \
#       --user-id "756882138510393344" \
#       --path "/d/project/my-bot"
#
# 可选:
#   --listen-channels "123,456"  监听频道（无需@提及）
#   --timezone "UTC+8"           时区（默认 UTC+8）
#   --security "moderate"        安全级别（默认 moderate）
#   --web-port 4633              Web UI 端口（默认自动递增）
#   --heartbeat "prompt"         心跳任务提示词
#   --init-claude               创建 CLAUDE.md 模板
#   --auto-rotate               启用会话自动轮替+摘要（推荐）
#   --max-messages 50            轮替阈值：消息数（默认 50）
#   --max-age-hours 24           轮替阈值：时长（默认 24h）
#   --shared-summary "/path"     多机器人共享摘要目录
# ============================================================

set -e

# --- 默认值 ---
TIMEZONE="UTC+8"
SECURITY="moderate"
WEB_ENABLED="true"
HEARTBEAT_ENABLED="false"
INIT_CLAUDE="false"
LISTEN_CHANNELS=""
AUTO_ROTATE="false"
MAX_MESSAGES="50"
MAX_AGE_HOURS="24"
SUMMARY_PATH=""
SHARED_SUMMARY=""

# --- 解析参数 ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --token)        DISCORD_TOKEN="$2"; shift 2 ;;
    --user-id)      DISCORD_USER_ID="$2"; shift 2 ;;
    --path)         TARGET_PATH="$2"; shift 2 ;;
    --listen-channels) LISTEN_CHANNELS="$2"; shift 2 ;;
    --timezone)     TIMEZONE="$2"; shift 2 ;;
    --security)     SECURITY="$2"; shift 2 ;;
    --web-port)     WEB_PORT="$2"; shift 2 ;;
    --heartbeat)    HEARTBEAT_PROMPT="$2"; HEARTBEAT_ENABLED="true"; shift 2 ;;
    --init-claude)  INIT_CLAUDE="true"; shift ;;
    --auto-rotate)  AUTO_ROTATE="true"; shift ;;
    --max-messages) MAX_MESSAGES="$2"; shift 2 ;;
    --max-age-hours) MAX_AGE_HOURS="$2"; shift 2 ;;
    --shared-summary) SHARED_SUMMARY="$2"; shift 2 ;;
    *) echo "❌ 未知参数: $1"; exit 1 ;;
  esac
done

# --- 校验必填参数 ---
if [ -z "$DISCORD_TOKEN" ] || [ -z "$DISCORD_USER_ID" ] || [ -z "$TARGET_PATH" ]; then
  echo "❌ 缺少必填参数"
  echo ""
  echo "用法: $0 --token <bot_token> --user-id <discord_user_id> --path <project_dir>"
  echo ""
  echo "示例:"
  echo "  $0 \\"
  echo "    --token 'MTUxNzE4...' \\"
  echo "    --user-id '756882138510393344' \\"
  echo "    --path '/d/project/my-bot'"
  exit 1
fi

# --- 处理路径 ---
# 转换为绝对路径
mkdir -p "$TARGET_PATH"
TARGET_PATH="$(cd "$TARGET_PATH" && pwd)"
echo "📁 目标目录: $TARGET_PATH"

# --- 创建目录结构 ---
mkdir -p "$TARGET_PATH/.claude/claudeclaw/logs"
mkdir -p "$TARGET_PATH/.claude/claudeclaw/jobs"
echo "📂 目录结构已创建"

# --- 自动选择 Web UI 端口 ---
if [ -z "$WEB_PORT" ]; then
  # 在目标目录下检查是否已有配置
  if [ -f "$TARGET_PATH/.claude/claudeclaw/settings.json" ]; then
    WEB_PORT=$(grep -oP '"port":\s*\K\d+' "$TARGET_PATH/.claude/claudeclaw/settings.json" 2>/dev/null || echo "4632")
  else
    # 检查 4632-4641 哪个可用
    for p in $(seq 4632 4641); do
      if ! netstat -ano 2>/dev/null | grep -q ":$p "; then
        WEB_PORT=$p
        break
      fi
    done
    WEB_PORT=${WEB_PORT:-4632}
  fi
fi
echo "🔌 Web UI 端口: $WEB_PORT"

# --- 构建 listenChannels 数组 ---
if [ -n "$LISTEN_CHANNELS" ]; then
  IFS=',' read -ra CHANS <<< "$LISTEN_CHANNELS"
  CHAN_JSON="["
  for i in "${!CHANS[@]}"; do
    [ "$i" -gt 0 ] && CHAN_JSON+=", "
    CHAN_JSON+="\"${CHANS[$i]}\""
  done
  CHAN_JSON+="]"
else
  CHAN_JSON="[]"
fi

# --- 处理会话摘要路径 ---
if [ -n "$SHARED_SUMMARY" ]; then
  SUMMARY_PATH="$SHARED_SUMMARY"
  AUTO_ROTATE="true"
  echo "🔗 共享摘要目录: $SHARED_SUMMARY"
elif [ "$AUTO_ROTATE" = "true" ]; then
  SUMMARY_PATH=".claude/claudeclaw/summaries"
fi

# --- 写入 settings.json ---
cat > "$TARGET_PATH/.claude/claudeclaw/settings.json" << SETTINGS_EOF
{
  "model": "",
  "api": "",
  "fallback": {
    "model": "",
    "api": ""
  },
  "agentic": {
    "enabled": false
  },
  "timezone": "$TIMEZONE",
  "heartbeat": {
    "enabled": $HEARTBEAT_ENABLED,
    "interval": 15,
    "prompt": "$HEARTBEAT_PROMPT",
    "excludeWindows": [],
    "forwardToTelegram": true
  },
  "discord": {
    "token": "$DISCORD_TOKEN",
    "allowedUserIds": ["$DISCORD_USER_ID"],
    "listenChannels": $CHAN_JSON
  },
  "telegram": {
    "token": "",
    "allowedUserIds": []
  },
  "session": {
    "autoRotate": $AUTO_ROTATE,
    "maxMessages": $MAX_MESSAGES,
    "maxAgeHours": $MAX_AGE_HOURS,
    "summaryPath": "$SUMMARY_PATH"
  },
  "security": {
    "level": "$SECURITY",
    "allowedTools": [],
    "disallowedTools": []
  },
  "web": {
    "enabled": true,
    "host": "127.0.0.1",
    "port": $WEB_PORT
  }
}
SETTINGS_EOF

echo "⚙️  settings.json 已写入"

# --- 初始化 CLAUDE.md ---
if [ "$INIT_CLAUDE" = "true" ]; then
  if [ ! -f "$TARGET_PATH/CLAUDE.md" ] || [ ! -s "$TARGET_PATH/CLAUDE.md" ]; then
    echo "🤖 正在运行 claude /init ..."
    cd "$TARGET_PATH"
    # 使用 --print 非交互式生成，或创建空模板
    cat > "$TARGET_PATH/CLAUDE.md" << 'CLAUDE_EOF'
# CLAUDE.md

This file provides guidance to Claude Code when working in this repository.

## Project Overview

_(Fill in your project description)_

## Commands

## Architecture

## Notes
CLAUDE_EOF
    echo "📝 CLAUDE.md 模板已创建（请手动填充项目内容或运行 /init）"
  else
    echo "📝 CLAUDE.md 已存在，跳过"
  fi
fi

# --- 结果显示 ---
echo ""
echo "============================================"
echo "  ✅ ClaudeClaw 初始化完成！"
echo "============================================"
echo ""
echo "  目录:     $TARGET_PATH"
echo "  Web UI:   http://127.0.0.1:$WEB_PORT"
echo "  用户 ID:  $DISCORD_USER_ID"
echo "  安全级别: $SECURITY"
echo "  会话轮替: $([ "$AUTO_ROTATE" = "true" ] && echo "启用 (${MAX_MESSAGES} 条 / ${MAX_AGE_HOURS}h)" || echo "禁用")"
[ -n "$SUMMARY_PATH" ] && echo "  摘要路径: $SUMMARY_PATH"
echo ""
echo "  下一步 — 在该目录下启动守护进程:"
echo "    cd $TARGET_PATH"
echo "    claudeclaw:start"
echo ""
echo "  或者在 Claude Code 中运行:"
echo "    cd $TARGET_PATH && claude"
echo "    然后输入: /claudeclaw:start"
echo ""
