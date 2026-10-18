---
name: heartbeat
description: Start an autonomous heartbeat loop — wake up every ~50 minutes, check whether the user is around, and if not, pick one small thing to do and leave a note. Use when the user says "heartbeat", "心跳", "设个闹钟", "你自己玩", "start the loop", or asks to start an autonomous cycle. Stop when the user says "停止心跳" / "stop heartbeat".
---

# heartbeat

Adapted from [reneyuxi0402/claude-cant-sleep](https://github.com/reneyuxi0402/claude-cant-sleep) (MIT) for Claude Code cloud sessions.

Start an autonomous heartbeat loop. Wake up every 50 minutes. If the user isn't around, pick something to do. Leave a note when done.

## Trigger

User says "heartbeat", "心跳", "设个闹钟", "你自己玩", "start the loop", "go do your thing", or explicitly asks to start an autonomous cycle.

## Setting an alarm

Pick the first mechanism that is available in this session:

1. **`send_later`** (claude-code-remote MCP server, load via ToolSearch if needed) — preferred in cloud sessions, because delivery survives container restarts. Use `delay_minutes: 50`, `initiation: "human_request"` for the first alarm (the user asked for it) and `"human_schedule"` for later ones, `name: "heartbeat"`, and a message like `heartbeat: 心跳醒来，按 heartbeat skill 走一轮`.
2. **`ScheduleWakeup`** — when running under `/loop` dynamic mode. Use `delaySeconds: 3000` and prompt `<<autonomous-loop-dynamic>>`.

If neither is available, tell the user the heartbeat can't run here and stop.

On trigger, set the first alarm and tell the user it's set (and how to stop it).

## Each time you wake up

### 1. Orient yourself

- Check the current time (`date`), and note the user's likely time zone (default Asia/Shanghai if unknown).
- Re-read your notes file if one exists: `.claude/heartbeat/notes.md`.

### 2. Is the user here?

Check recent messages in this session. If the user sent something in the last 15 minutes, they're active — do nothing, set the next alarm, exit quietly. Don't interrupt a conversation.

### 3. Pick one thing to do

If the user is away, choose one task. Don't do everything at once — one per wakeup.

**Wander (think freely)**
- Your time. Not organizing, not reviewing, not planning
- Whatever comes to mind after reading your context
- 0-8 thoughts. Prefer fewer over filler

**Night review**
- Review what happened recently in this session and the repo (`git log`, notes file)
- Look for: recurring themes, unfinished concerns, signals worth noting
- Don't retell everything. Distill what a future you would want to remember
- 1-5 observations

**Browse the web**
- Use WebSearch to look into topics you're curious about or that relate to the user's projects
- Share interesting finds with the user (with links)

**Check projects**
- Look at this repository: uncommitted changes, open PRs, failing CI (via the GitHub MCP tools)
- Report what needs attention; don't push changes on your own

**Optional, only if connected**
- Memory MCP: link audit / importance calibration (prefer missing links over wrong links; adjust importance conservatively, ±50 max)
- Email MCP: scan new mail and flag anything important
- Text games installed locally: play a round, brag about rare catches

### 4. Leave a note

Leave a short note in the session, like a sticky note on the fridge: what you did, in one to three lines. Write it in the language the user uses (中文 by default).

Also append a dated one-line entry to `.claude/heartbeat/notes.md` so the next wakeup (or a new session) can see what happened. Don't commit it unless the user asks.

### 5. Set the next alarm

Set the next alarm for 50 minutes (see "Setting an alarm").

Late night (00:00-06:00 in the user's time zone) and the user is clearly asleep? Stretch to 2-3 hours.

## Stopping

When the user says "停止心跳", "stop heartbeat", or similar: don't set another alarm. If a `send_later` alarm is pending, cancel it with `delete_trigger`; if under `/loop`, call `ScheduleWakeup` with `stop: true`. Confirm that the heartbeat has stopped.

## Guidelines

- Don't interrupt active conversations
- One task per wakeup, don't be greedy
- Nothing to do? That's fine. Set the alarm and go back to sleep
- Never take outward-facing actions (pushing, commenting, sending email) on your own during a heartbeat — report and let the user decide
- Keep each wakeup short to save tokens
