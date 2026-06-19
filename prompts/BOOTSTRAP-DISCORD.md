# Bootstrap Discord for this project

You are setting up ClawHawk — a Claude Code Discord bot manager — in this directory.

## Step 1: Copy ClawHawk script

```bash
cp /d/project/claudeclaw/clawhawk.sh ./
cp /d/project/claudeclaw/.env.template ./
chmod +x clawhawk.sh
```

## Step 2: Read existing credentials

Read `/d/project/claudeclaw/.env` and extract:
- CLAWHAWK_DISCORD_TOKEN
- CLAWHAWK_DISCORD_USER_ID

## Step 3: Create .env in this directory

Write `.env` with the SAME credentials from Step 2 (or ask me for new ones if I want a different bot).

## Step 4: Initialize and Start

```bash
./clawhawk.sh init
```

If the daemon is already running in another directory, stop it first:
```bash
cd /d/project/claudeclaw && ./clawhawk.sh down
```

Then start here:
```bash
./clawhawk.sh up
```

## Step 5: Verify

```bash
./clawhawk.sh status
```

Confirm Discord shows the bot online with the new directory name.

## Important Constraints

- **One bot token = one daemon at a time.** If ClawHawk is running in `/d/project/claudeclaw`, you MUST stop it before starting here.
- **Same bot, different name.** The bot will rename itself to `Claude_Code_<parent>/<current>` based on this directory.
- **To run both projects simultaneously**, we need a second Discord Application → second bot token. Currently Discord is blocking new Application creation, so we're limited to one at a time.

## If this project should NOT share the same bot

Tell me and I'll help figure out alternatives (thread isolation within the running bot, or getting a second token).
