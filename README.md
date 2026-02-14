```markdown
# Claude Code… Status Line Metrics

## Building a Smarter Claude Code Statusline (With Costs and Suggestions)

**I Built a Real-Time Dashboard Into Claude Code’s Status Line (And It Uses Data You Didn’t Know Existed)**

### TL;DR

Claude Code sends a rich JSON payload to custom statusline scripts on every interaction — actual cost, context usage, session duration, token counts, and more. I built a ~400 line bash script that turns this into a live dashboard showing everything you need to make smart decisions about pacing, context management, and parallel sessions.

---

### The Problem: Flying Blind

My workflow with Claude Code isn’t one terminal, one task. It’s multiple terminals, multiple projects, all sharing the same Anthropic account. Each instance burns tokens independently, but the rate limit is shared.

I couldn’t see:

- How much I was spending right now (not after the fact)
- How fast my context window was filling — and when auto-compaction would wipe my conversation state
- Whether my tools were failing silently in retry loops
- What my actual aggregate burn rate was across all sessions

I needed a status line. Not a separate monitoring tool, not a browser tab, not a TUI — something *inside* Claude Code that updates on every interaction.

### The Insight: Claude Code Sends You Everything

Here’s what most people don’t realize: Claude Code’s statusline hook doesn’t just call your script — it pipes a JSON payload via stdin containing the current session’s actual metrics. Cost, context, duration, model, token breakdown — all of it. No estimation needed.

```json
{
  "session_id": "420c9207-5fd1-4456-abd0-e14456ee16ba",
  "transcript_path": "/Users/naveen/.claude/projects/.../420c9207.jsonl",
  "model": {"id": "claude-opus-4-6", "display_name": "Opus 4.6"},
  "version": "2.1.39",
  "cost": {
    "total_cost_usd": 3.56,
    "total_duration_ms": 1472713,
    "total_api_duration_ms": 772588,
    "total_lines_added": 306,
    "total_lines_removed": 554
  },
  "context_window": {
    "total_input_tokens": 20147,
    "total_output_tokens": 42321,
    "context_window_size": 200000,
    "current_usage": {
      "input_tokens": 3,
      "output_tokens": 9,
      "cache_creation_input_tokens": 4,
      "cache_read_input_tokens": 43791
    },
    "used_percentage": 22,
    "remaining_percentage": 78
  }
}
```

That `cost.total_cost_usd` is the **real** number — not an estimate from a pricing table. The `context_window.used_percentage` is Claude’s own calculation. No guessing.

The previous version of this script estimated cost by parsing JSONL session files and multiplying token counts by model-specific rates. It worked, but it was always approximate. Now? The source of truth comes straight from Claude Code.

JSONL files (at `~/.claude/projects/<project-dir>/<session-id>.jsonl`) are still useful for one thing: tool and message stats. Claude’s native JSON doesn’t include tool breakdowns, so the script parses the session transcript for those.

### What I Built: 9 Lines of Real-Time Intelligence

Claude Code supports a custom status line via `settings.json`. Point it at a shell script, and it renders the output below your prompt on every interaction. Here’s what mine looks like:

```
📁 ~/my-project  🤖 Opus 4.6  📟 2.1.39  🌿 main*(+2~3?1)
🧠 Context: 43.8K/200.0K (22%) • Until compact: 1h 27m ▓▓░░░░░░░░
💰 $3.56 ($8.70/hr) • In:20.1K Out:42.3K Cache:43.8K
⏱️  Session: 0h 24m (API: 12m 52s) • Cache: 99%
📊 62.5K tok • 💬 18 msgs • 🔧 R:12 E:5 B:8 W:2
📂 4 files • ⚡ 1.8K/min • ✅ 98% tools • 📝 +306/-554 lines
📈 Peak: 43.8K
✅ All good
```

At a glance, I know exactly where I stand. Let me walk through what each line does and why it matters.

### Line by Line: What You’re Looking At

#### Line 1 — Session Context

```
📁 ~/my-project  🤖 Opus 4.6  📟 2.1.39  🌿 main*(+2~3?1)
```

The basics: where you are, which model is running (this directly affects pricing), your CLI version, and your git state. The dirty indicators are compact but information-dense:

- `+2` = 2 files staged
- `~3` = 3 files modified but unstaged
- `?1` = 1 untracked file
- `*` = uncommitted changes exist

**Why include git?** Because I’ve kicked off expensive Claude operations on the wrong branch more times than I’d like to admit.

#### Line 2 — Context Window & Compaction Countdown

```
🧠 Context: 43.8K/200.0K (22%) • Until compact: 1h 27m ▓▓░░░░░░░░
```

This is the line that changed how I work. Claude Code has a 200K token context window. When it fills, auto-compaction fires — the conversation gets summarized, detail is lost, and you burn extra tokens in the process.

The “Until compact” timer calculates context velocity (tokens consumed per minute based on your session history) and projects when you’ll hit the wall:

```bash
context_velocity=$(( actual_context_tokens * 60 / session_elapsed ))
tokens_remaining=$(( MAX_CONTEXT - actual_context_tokens ))
minutes_to_full=$(( tokens_remaining / context_velocity ))
```

When this says 12m, I know to run `/compact` proactively rather than letting Claude do it mid-task and lose important context.

#### Line 3 — Cost & Token Breakdown

```
💰 $3.56 ($8.70/hr) • In:20.1K Out:42.3K Cache:43.8K
```

The cost is **actual** — pulled directly from `cost.total_cost_usd` in Claude Code's native JSON. No pricing tables, no estimation. The hourly rate is calculated from the real cost and session wall time.

The token breakdown shows cumulative session totals: input tokens, output tokens, and cache read tokens. This tells you where the tokens are going. A high Cache number relative to Input means prompt caching is working well.

#### Line 4 — Session Timing & Cache Efficiency

```
⏱️  Session: 0h 24m (API: 12m 52s) • Cache: 99%
```

Wall clock time vs. actual API time. In this example, the session is 24 minutes old but Claude spent 12m 52s of that on API calls. The rest is you reading output, thinking, and typing.

The cache hit rate shows what percentage of your prompt tokens were served from cache vs. sent fresh. Higher = faster responses and lower cost per interaction. Both timing values come from Claude Code’s native `total_duration_ms` and `total_api_duration_ms`.

#### Line 5 — Token & Tool Analytics

```
📊 62.5K tok • 💬 18 msgs • 🔧 R:12 E:5 B:8 W:2
```

Total token consumption, conversation length, and a tool usage breakdown:

- **R** = Read (file reads)
- **E** = Edit (file modifications)
- **B** = Bash (shell commands)
- **W** = Write (new file creation)

This breakdown is surprisingly useful. If I see `B:47` and the session is only 20 minutes old, something is probably in a retry loop. If `W:12` is high, I'm generating a lot of new files and should check nothing was duplicated. These stats come from parsing the session JSONL file — the one metric that still requires file parsing.

#### Line 6 — Activity & Code Impact

```
📂 4 files • ⚡ 1.8K/min • ✅ 98% tools • 📝 +306/-554 lines
```

Files touched (unique files edited or written), context velocity (how fast tokens are being consumed — your “speedometer”), tool success rate (calculated from `tool_use_error` counts in the session log), and lines of code changed (from Claude Code's native `total_lines_added` / `total_lines_removed`).

The tool success rate is an early warning. If it drops below 90%, the status message changes to flag it:

```bash
if [ "$tool_success_rate" -lt 90 ]; then
  status_msg="⚠️ ${tool_success_rate}% tool success — Errors may be causing retries, check output"
fi
```

#### Line 7 — Peak Context & Compaction History

```
📈 Peak: 43.8K • 🔄 2x compact
```

Peak context tracks the highest context window usage during the session — persisted across compactions in a state file. The compaction counter detects when context drops by 50%+ (the signature of auto-compaction):

```bash
if [ "$actual_context_tokens" -lt $(( LAST_CONTEXT_TOKENS / 2 )) ]; then
  COMPACTION_COUNT=$(( ${COMPACTION_COUNT:-0} + 1 ))
fi
```

On heavy sessions I’ve seen `🔄 138x compact`. That number is a wake-up call about how much context you're churning through.

#### Line 8 — Multi-Session Awareness (Conditional)

```
🌐 +2 other session(s): $8.45 (650.2K tok) • $12.30/hr
```

This line only appears when other Claude Code sessions are actively running (any session JSONL file modified in the last 5 minutes, excluding your current session). It sums costs and tokens across every other active instance.

**Why 5 minutes instead of 60?** Active sessions write to their JSONL file on every interaction, so a 5-minute window catches real concurrent sessions without false positives from old session files that happened to be touched recently. And by excluding the current session, you’ll never see “1 session running” — you already know about your own.

#### Line 9 — Status & Recommendations

The bottom line runs through a priority-ordered decision tree and tells you what matters right now:

| Message                                      | Trigger                  | What To Do                                      |
|----------------------------------------------|--------------------------|-------------------------------------------------|
| 🚨 **Memory almost full (92%)** — Run `/compact` now or start a new session | Context >90%            | Auto-compaction is imminent. You'll lose detail. |
| ⚠️ **Memory filling up (78%)** — Run `/compact` soon to free space | Context 75–90%          | Getting tight. Proactively compact before it's forced. |
| ⚡ **Using memory fast (3.2K/min)** — Break task into smaller steps | Velocity >3K/min        | Your prompts/responses are large. Chunk the work. |
| 🔄 **Compacted 5x** — Session is long. Consider starting fresh (`/clear`) | >3 compactions          | You're losing context repeatedly. Start a new session. |
| ⚠️ **82% tool success** — Errors may be causing retries, check output | Success <90%            | Something is failing. Check for retry loops.    |
| ✅ **2 other session(s) also running** — $12.30/hr combined | Other sessions active   | FYI — your parallel sessions are spending this much. |
| ✅ **All good**                              | Nothing to worry about  | Carry on.                                       |

**The design philosophy:** every message explains what’s happening **and** what to do about it. No jargon like “cache hit rate” or unexplained numbers. If you need to act, the message tells you how.

---

### The Architecture: Native JSON + JSONL Hybrid

The v4.0 script uses a two-source approach:

**Primary source:** Claude Code’s native JSON (piped via stdin)

- Cost (`cost.total_cost_usd`) — actual, not estimated
- Context usage (`context_window.*`) — percentage, token counts, window size
- Duration (`cost.total_duration_ms`, `cost.total_api_duration_ms`)
- Code changes (`cost.total_lines_added`, `cost.total_lines_removed`)
- Model, version, session ID, transcript path

**Secondary source:** Session JSONL (file parsing, for tool stats only)

- Message count
- Tool breakdown (Read, Edit, Bash, Write)
- Tool success rate
- Files touched

```bash
# Extract everything from native JSON in one pass
native=$(echo "$input" | jq '{
  cost_usd:    (.cost.total_cost_usd // 0),
  wall_ms:     (.cost.total_duration_ms // 0),
  ctx_used_pct: (.context_window.used_percentage // 0),
  # ... 15+ more fields
}')
```

```bash
# JSONL only for tool stats
tool_metrics=$(jq -s '{
  tool_read: [.[] | select(.message.content[]?.name == "Read")] | length,
  # ... tool breakdowns
}' "$session_file")
```

### Performance: It Has to Be Fast

A status line that lags is worse than no status line. Several optimizations keep render time negligible:

- **Render throttling:** Skip if last render was <2 seconds ago.
- **Native JSON first:** Most metrics come from a single `jq` extraction of the stdin payload — no file I/O at all. Only tool stats require reading the JSONL file.
- **Single-pass JSONL extraction:** When we do read the session file, one `jq -s` call returns all tool metrics at once.
- **Persistent state:** Peak context, compaction count, and session start time are persisted to a `.usage_state` file.
- **Tight aggregate window:** Only scanning JSONL files modified in the last 5 minutes.

### Setup (2 Minutes)

1. **Save the script**

   ```bash
   # Save statusline.sh to ~/.claude/statusline.sh
   chmod +x ~/.claude/statusline.sh
   ```

2. **Configure Claude Code**

   Add to `~/.claude/settings.json`:

   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "~/.claude/statusline.sh",
       "padding": 0
     }
   }
   ```

3. **Install dependencies**

   ```bash
   # macOS
   brew install jq bc

   # Ubuntu/Debian
   apt install jq bc
   ```

That’s it. Next time Claude Code renders, you’ll see the full dashboard.

### Why This Approach Works

I tried the other approach first — a separate monitoring utility. It meant:

- Version drift between the monitor and Claude Code
- Stale data from polling intervals
- Cost estimates that drifted from reality
- Another process to babysit

The status line script uses only what’s already there:

- `bash` — it’s your shell
- Claude Code’s native JSON — piped to your script on every render
- Session JSONL files — already written by Claude Code (only for tool stats)
- `git` — you’re already in a repo
- `jq`/`bc` — standard utilities

No daemon. No network calls. No pricing tables to keep updated. The cost is actual, not estimated. Less ceremony, more clarity.

### From Numbers to Decisions: The Wave Strategy

The status line wasn’t the end goal — it was the input to a decision framework. The whole point is answering: “What can I safely hand off to Claude right now?”

#### The Delegation Decision Tree

| Status Line Says                          | What I Do                                      |
|-------------------------------------------|------------------------------------------------|
| **Context <50%, ✅ All good**             | Go wide. Spin up parallel sessions. Run the big refactor. Let Claude loose on multi-file changes. |
| **Context 50–75%, velocity moderate**     | Stay focused. One session at a time. Targeted edits, not open-ended exploration. |
| **Context 75–90%, ⚠️ Memory filling up**  | Wrap up. Finish current tasks, don't start new ones. Run `/compact` proactively. |
| **Context >90%, 🚨 Memory almost full**   | Compact or restart. `/compact` now, or start a fresh session with `/clear`. |

#### Wave Mode: Staged Orchestration

When I have a large task — say, implementing a full feature across 8 files — I don’t throw it all at Claude in one shot. I run it in **waves**, using the status line to pace each stage:

- **Wave 1 (Architecture):** Ask Claude to plan the approach. Low token cost, high value.
- **Wave 2 (Core Implementation):** Implement the main logic. This is the expensive wave.
- **Wave 3 (Integration):** Wire everything together. If context is getting high from Wave 2, `/compact` first.
- **Wave 4 (Testing & Cleanup):** Run tests, fix edge cases.

The `📈 Peak: 156.2K • 🔄 2x compact` line tells you how many waves you've effectively been through.

### Pro Tips for High-Throughput Workflows

- **When context velocity spikes:** Run `/compact` to reclaim context, then switch to `/model sonnet` for routine work. Sonnet is cheaper than Opus for output tokens.
- **When context is high:** Add “Be concise. Code only, minimal explanation.” to your `CLAUDE.md` — this persistently reduces verbose output across all sessions.
- **Long sessions:** Watch the compaction counter. If it’s climbing fast (`🔄 5x compact` in an hour), your tasks are too broad. Break them into focused, disposable sessions.
- **Cost-aware model switching:** The `🤖` model indicator reminds you which pricing tier you're on. Use `/model sonnet` mid-session for tasks that don't need Opus-level reasoning and watch the $/hr rate drop.

### What I Learned Running This for Months

- **Compaction count is a better metric than token count.** My `.usage_state` file shows `COMPACTION_COUNT=138` on one project. That's 138 times the context was auto-summarized. Each compaction loses nuance.
- **Native JSON beats estimation.** The previous version estimated cost from token counts and a pricing table. Getting `total_cost_usd` directly eliminated an entire class of bugs.
- **Active session detection needs a tight window.** Tightening to 5 minutes and excluding the current session fixed false positives completely.
- **Tool breakdown catches pathological patterns.** When Bash calls spike (`B:40+` in a short session), something is usually in a retry loop.
- **Status messages must be human-readable.** The current version says exactly what’s happening and what to do.

### Customization Ideas

The script is ~400 lines of bash and every metric is modular. Some things to try:

- Add per-model cost tracking
- Burn rate smoothing (average over last N minutes)
- Auto-compact triggers via Claude Code hooks
- Slack/webhook alerts when aggregate spend crosses a threshold
- Session tagging

### Final Thought

Sometimes the cleanest fix isn’t “one more tool” — it’s using what you already have, better. Claude Code’s native statusline JSON was sitting there the whole time, containing everything I needed to make informed decisions about pacing, context, and cost.

~400 lines of bash. No daemon. No dependencies. Real-time visibility into every metric that matters.

**Repo:** [claude-code-status-line](https://github.com/yourusername/claude-code-status-line)  
*(Built with Claude Code, tracked with this very status line.)*

---

*Made with ❤️ and too many Claude tokens by Naveen*
