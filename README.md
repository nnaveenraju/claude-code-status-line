# Building a Smarter Claude Code Statusline (Without the Dependency Headache)

*Claude Code… Status Line Metrics*

> **Code & Repo:** **[nnaveenraju/claude-code-status-line →](https://github.com/nnaveenraju/claude-code-status-line)**
> Minimal Bash utility that reads Claude Code’s local `.jsonl` session logs, computes usage, and renders a compact statusline with “resource zones,” time-to-reset, and actionable tips.

---

My Claude Code task delegation wasn’t just about telling CC what to do—it was about **visibility**. I couldn’t see my available usage in Claude Code, so planning became guesswork (or yet another trip to the account dashboard). I built a statusline to show limits at a glance *before* deciding what to hand off to Claude.

## TL;DR

* **Problem:** A statusline that depended on an external utility (`ccusage`) kept breaking or lagging.
* **Fix:** Read **Claude Code’s session `.jsonl` files** directly and compute everything locally.
* **Bonus:** Add smart **resource zones**, **time-to-reset**, and **actionable suggestions** instead of raw numbers.

---

## The Problem: When Your Statusline Needs Its Own Statusline

I wanted to see—quickly and reliably:

* How many tokens I’d burned,
* How close I was to limits,
* How much time until reset,

…without babysitting a fragile dependency. Relying on a separate utility meant version drift, stale data, and “works on my machine” failure modes.

## The Insight: Claude Already Tracks Everything

Claude Code writes session events—timestamps, input/output tokens, model, etc.—to JSONL under `~/.claude/projects/…`. That’s **truth on disk**. No extra process. No network jitter. No waiting. Just parse the file you’re already generating.

---

## Quick Start

> Full instructions & updates are in the repo: **[github.com/nnaveenraju/claude-code-status-line](https://github.com/nnaveenraju/claude-code-status-line)**

```bash
# 1) Install (clone wherever you like)
git clone https://github.com/nnaveenraju/claude-code-status-line.git
cd claude-code-status-line

# 2) Make the script executable
chmod +x claude-statusline.sh

# 3) (Optional) Put it on your PATH
# Example:
#   mv claude-statusline.sh ~/.local/bin/
#   echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc

# 4) Run it
./claude-statusline.sh

# 5) (Optional) Wire into your prompt/statusline (tmux, lualine, etc.)
# Example tmux right-status:
#   set -g status-right '#(claude-statusline.sh)'
```

**Requirements:** `bash` (always), `jq` (optional but recommended). Falls back to simple parsing if `jq` isn’t present.

---

## The Approach

### 1) Locate the session file

```bash
# Example: derive the path for the current project/session
project_dir="$(basename "$(pwd)")"
session_id="$(cat .claude-session-id 2>/dev/null || echo "current")"
session_file="$HOME/.claude/projects/-${project_dir}/${session_id}.jsonl"
```

*Tip:* If you don’t persist `session_id`, grab the latest `.jsonl` under the project dir.

### 2) Parse usage from the latest event (with `jq`)

```bash
latest_entry="$(tail -200 "$session_file" | jq -c 'select(.message.usage) | last')"
input_tokens="$(echo "$latest_entry" | jq -r '.message.usage.input_tokens // 0')"
output_tokens="$(echo "$latest_entry" | jq -r '.message.usage.output_tokens // 0')"
total_tokens="$(( input_tokens + output_tokens ))"
```

Pull the latest entry with a `message.usage` field, then compute totals. Use a slightly larger `tail` window in case the last few lines aren’t usage events.

### 3) Add an “intelligence layer”

Raw numbers don’t help you decide *what to do*. Layer meaning on top:

```bash
limit_tokens="${CLAUDE_TOKEN_LIMIT:-200000}"   # example; set via env
pct=$(( 100 * total_tokens / limit_tokens ))

zone="🟢 GREEN"; advice="All good."
if   [ "$pct" -ge 95 ]; then zone="🔴 CRITICAL"; advice="Stop and save. Consider summarizing/compacting."
elif [ "$pct" -ge 85 ]; then zone="🟠 HIGH";     advice="Wrap up. Reduce context, chunk tasks."
elif [ "$pct" -ge 60 ]; then zone="🟡 ORANGE";   advice="Monitor burn rate. Consider lighter prompts."
fi

# Time-to-reset & progress bar
reset_at_epoch="$(date -d 'today 23:59' +%s)"    # example daily reset target
now_epoch="$(date +%s)"
mins_left=$(( (reset_at_epoch - now_epoch) / 60 ))
filled=$(( pct / 10 ))
bar="$(printf '%*s' "$filled" '' | tr ' ' '=')$(printf '%*s' $((10-filled)) '' | tr ' ' '-')"
```

---

## The Output (What You Actually See)

```
📁 ~/my-project   🌿 feature/auth   🤖 Sonnet-4   📟 v2.1.0
⌛ 2h 15m until reset (75%) [=======---]
📊 45,230 tok (≈3,200/min) • 🧠 Context ~85% • 💵 ~$1
🎯 🟡 ORANGE • ⚠️ API ~25% left • 🌊 Wave:5 • 💡 Consider compacting / lighter prompts
```

At a glance you know:

* **Where** you are (dir/branch/model/version),
* **How much runway** remains (tokens & time),
* **Whether to worry**, and
* **What action to take**.

---

## Why Go Dependency-Free

* ✅ Works anywhere Bash works (`jq` optional)
* ✅ Real-time numbers from Claude’s own logs
* ✅ “Zones” that translate numbers → decisions
* ✅ Concrete advice when you’re near limits
* ✅ Fewer moving parts (less to break)

---

## Drop-In Script (Minimal)

> The maintained version lives in the repo and may evolve. Prefer this snippet for a quick demo, but **use the repo script** for the latest fixes and improvements.

```bash
#!/usr/bin/env bash
set -euo pipefail

project_dir="$(basename "$(pwd)")"
session_id="$(cat .claude-session-id 2>/dev/null || echo "current")"
session_file="$HOME/.claude/projects/-${project_dir}/${session_id}.jsonl"

get_latest() {
  if command -v jq >/dev/null 2>&1; then
    tail -200 "$session_file" | jq -c 'select(.message.usage) | last'
  else
    tail -200 "$session_file" | grep -F '"usage"' | tail -1
  fi
}

extract() {
  local json="$1" key="$2"
  if command -v jq >/dev/null 2>&1; then
    echo "$json" | jq -r ".message.usage.$key // 0"
  else
    echo "$json" \
      | grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"*[^\","}]*" \
      | head -1 \
      | sed -E "s/\"$key\"[[:space:]]*:[[:space:]]*\"?([^\",}]*)\"?/\1/"
  fi
}

latest="$(get_latest)"
input_tokens="$(extract "$latest" input_tokens)"
output_tokens="$(extract "$latest" output_tokens)"
total="$(( ${input_tokens:-0} + ${output_tokens:-0} ))"

limit="${CLAUDE_TOKEN_LIMIT:-200000}"
pct=$(( 100 * total / limit ))

zone="🟢 GREEN"; advice="All good."
[ "$pct" -ge 95 ] && zone="🔴 CRITICAL" && advice="Stop and save; compact context."
[ "$pct" -ge 85 ] && zone="🟠 HIGH"     && advice="Wrap up; reduce context."
[ "$pct" -ge 60 ] && zone="🟡 ORANGE"   && advice="Monitor burn; consider lighter prompts."

filled=$(( pct / 10 ))
bar="$(printf '%*s' "$filled" '' | tr ' ' '=')$(printf '%*s' $((10-filled)) '' | tr ' ' '-')"

reset_at_epoch="$(date -d 'today 23:59' +%s 2>/dev/null || gdate -d 'today 23:59' +%s)"
now_epoch="$(date +%s)"
mins_left=$(( (reset_at_epoch - now_epoch) / 60 ))
hrs=$(( mins_left / 60 )); mins=$(( mins_left % 60 ))

echo "📁 $(pwd)   🌿 $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '-')"
echo "⌛ ${hrs}h ${mins}m until reset (${pct}%) [${bar}]"
echo "📊 ${total} tok • ${zone} • 💡 ${advice}"
```

## Setup / Install steps

For detailed, step-by-step instructions (macOS/Linux/WSL) and troubleshooting, see **[setup.md in the repo](https://github.com/nnaveenraju/claude-code-status-line/blob/main/setup.md)**.


---

## Final Thought

Sometimes the cleanest fix isn’t “one more tool,” but **using what you already have—better**. Claude’s logs were enough to build a statusline that’s faster, sturdier, and more helpful than the dependency it replaced. Less ceremony, more clarity.

If you adapt this for your workflow, I’d love to hear what you add—burn-rate smoothing, per-model budgets, auto-compact triggers, you name it.

---
