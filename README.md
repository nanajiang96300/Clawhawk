# 🦅 ClawHawk

> Single-Agent Claude Code Session Manager — run your AI agent on Discord with persistent memory.

ClawHawk wraps ClaudeClaw into one script. One agent, one directory, one Discord bot — with full control over conversation sessions.

---

## Quick Start

### Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed
- A Discord Bot (create at [Discord Developer Portal](https://discord.com/developers/applications))
- Git Bash or WSL on Windows

### Install

```bash
git clone https://github.com/nanajiang96300/Clawhawk.git
cd Clawhawk
```

### Configure

```bash
# 1. Create your .env from template
cp .env.template .env

# 2. Edit .env with your real credentials
#    CLAWHAWK_DISCORD_TOKEN=your_bot_token_here     ← paste your Discord bot token
#    CLAWHAWK_DISCORD_USER_ID=your_user_id_here      ← paste your Discord user ID

# 3. Initialize
./clawhawk.sh init

# 4. Start
./clawhawk.sh up
```

Then DM your bot on Discord — the URL will be printed after startup.

---

## Commands

| Command | Description |
|---------|-------------|
| `./clawhawk.sh init` | Initialize project: create directories, .env, settings |
| `./clawhawk.sh up` | Start daemon, rename bot, connect Discord |
| `./clawhawk.sh down` | Stop daemon |
| `./clawhawk.sh new` | Backup current session, start fresh conversation |
| `./clawhawk.sh resume [id]` | Restore a historical session |
| `./clawhawk.sh history` | List all backed-up sessions |
| `./clawhawk.sh rename [name]` | Set Discord bot display name |
| `./clawhawk.sh status` | Show agent status, session info, Web UI URL |

---

## Auto-Start on Windows

To make your agent start automatically when you log in:

### Option 1: Startup Folder (Simplest)

```bash
# Run this once. Replace path with your actual ClawHawk location.
./clawhawk.sh autostart
```

This creates a shortcut in `shell:startup` that launches the agent at login.

### Option 2: Task Scheduler (More Control)

```bash
# Create a scheduled task that runs at login, restarts on failure
schtasks /Create /SC ONLOGON /TN "ClawHawk" \
  /TR "C:\Program Files\Git\bin\bash.exe -c 'cd /d/project/claudeclaw && ./clawhawk.sh up'" \
  /DELAY 0001:00 /RL HIGHEST /F
```

### Option 3: Manual

1. Press `Win + R`, type `shell:startup`
2. Create a shortcut to: `C:\Program Files\Git\bin\bash.exe`
3. Arguments: `-c "cd /d/project/claudeclaw && ./clawhawk.sh up"`

---

## Configuration

All settings are in `.env` (gitignored). The template `.env.template` shows available options:

```bash
# Required
CLAWHAWK_DISCORD_TOKEN=your_bot_token_here
CLAWHAWK_DISCORD_USER_ID=your_discord_user_id_here

# Optional
CLAWHAWK_TIMEZONE=UTC+8
CLAWHAWK_SECURITY=moderate
```

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `CLAWHAWK_DISCORD_TOKEN` | Yes | — | Discord Bot Token |
| `CLAWHAWK_DISCORD_USER_ID` | Yes | — | Your Discord User ID |
| `CLAWHAWK_TIMEZONE` | No | `UTC+8` | Timezone for logs and jobs |
| `CLAWHAWK_SECURITY` | No | `moderate` | `locked` / `strict` / `moderate` / `unrestricted` |

---

## Bot Naming

On startup, ClawHawk automatically renames your Discord bot based on the directory path:

```
Path: /d/project/my-project/agents/developer
  → Bot name: Claude_Code_agents/developer

Path: /d/project/my-bot
  → Bot name: Claude_Code_my-bot
```

This helps you identify which agent is which when running multiple bots.

Disable with: `./clawhawk.sh up --no-rename`

---

## Session Management

### Session Files

```
~/.claude/projects/<project-slug>/   ← Actual conversation data (Claude Code manages)
./.claude/claudeclaw/
├── session.json                     ← Current session UUID
└── history/                         ← Backed-up old sessions
```

### Workflow

```bash
# When you want to start a new topic without losing the old conversation:
./clawhawk.sh new
# → backs up current session, starts fresh

# Go back to a previous conversation:
./clawhawk.sh history
./clawhawk.sh resume 1
# → restores session #1

# The history shows all your backed-up sessions:
./clawhawk.sh history
  #   ID         Created               Turns   File
  ─── ─────────  ────────────────────  ──────  ─────
  1*  a1b2c3d4   Jun 15 14:30          42     session_1.backup
  2   7g8h9i0j   Jun 17 09:15          18     session_2.backup
  * = current
```

---

## Project Structure

```
ClawHawk/
├── clawhawk.sh              ← Main entry point (the only file you need)
├── CLAUDE.md                ← Agent personality (edit me!)
├── .env.template            ← Config template (copy to .env)
├── .env                     ← Your secrets (gitignored)
├── .gitignore
├── .claude/
│   └── claudeclaw/          ← Runtime (gitignored)
│       ├── settings.json
│       ├── session.json
│       ├── daemon.pid
│       └── history/
├── docs/
│   └── DESIGN.md            ← Architecture design document
└── README.md
```

---

## Security

- `.env` and `.claude/claudeclaw/` are **gitignored** — never commit them
- Bot tokens live only in `.env`
- The `.env.template` shows the structure without real values
- Security modes: `locked` (read-only), `strict` (no bash/web), `moderate` (project-scoped)

---

## Requirements

- **Windows 10/11** with Git Bash (primary target)
- **Bun** ≥ 1.1 (auto-installs via winget if needed)
- **Node.js** ≥ 18
- Claude Code with API access
- Discord Bot with Message Content Intent enabled

---

## Troubleshooting

**Bot not showing online in Discord?**
```bash
# Check if daemon is running
./clawhawk.sh status

# Check Discord connection
grep "Ready as" .claude/claudeclaw/logs/daemon.log

# Check if Discord is reachable
curl -I https://discord.com/api/v10/gateway
```

**Port conflict?**
The Web UI port auto-increments if the default is in use. Check status for actual URL:
```bash
./clawhawk.sh status
```

**VPN / network issues?**
Enable TUN mode on your VPN so traffic goes through the virtual network card, or set proxy environment variables before starting.

---

## Roadmap

- [x] Single-agent session management
- [x] Bot auto-rename by directory path
- [x] Session backup and restore
- [x] Windows auto-start
- [x] .env secrets management
- [ ] Multi-agent orchestration (v2)
- [ ] Session summary/rotation
- [ ] CLI tab completion
- [ ] macOS/Linux support

---

## License

MIT
