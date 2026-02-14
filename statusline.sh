#!/usr/bin/env bash
# Claude Code Statusline — v4.0
#
# Uses Claude Code's native statusline JSON for accurate cost, context,
# and duration metrics. Falls back to JSONL only for tool/message stats.
#
# Layout:
#  1) 📁 <dir>  🤖 <model>  📟 <version>  🌿 <git-branch>
#  2) 🧠 Context: <used>/<max> (<pct>%) • Until compact: <time> <bar>
#  3) 💰 $<cost> ($<rate>/hr) • In:<in-tok> Out:<out-tok> Cache:<cache-tok>
#  4) ⏱️  Session: <wall> (API: <api>) • Cache: <hit>%
#  5) 📊 <tokens> tok • 💬 <msgs> msgs • 🔧 R:<n> E:<n> B:<n> W:<n>
#  6) 📂 <files> files • ⚡ <velocity>/min • ✅ <success>% tools • 📝 +<add>/-<del> lines
#  7) 📈 Peak: <peak> [• 🔄 <n>x compact]
#  8) 🌐 ALL <n> sessions: $<cost> (<tokens>) • $<rate>/hr
#  9) <status-message>
#
# Requires: bash, jq, bc; optional: git

# ---------- Single-run sentinel ----------
now_ts=$(date +%s)
if [ -n "$STATUSLINE_LAST_RENDER" ] && [ $(( now_ts - STATUSLINE_LAST_RENDER )) -lt 2 ]; then
  exit 0
fi
export STATUSLINE_LAST_RENDER=$now_ts

# ---------- Setup & input ----------
input=$(cat)
HAS_JQ=0; command -v jq >/dev/null 2>&1 && HAS_JQ=1
HAS_BC=0; command -v bc >/dev/null 2>&1 && HAS_BC=1

if [ "$HAS_JQ" -ne 1 ]; then
  echo "⚠️ jq required for statusline"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- Extract ALL fields from Claude Code's native JSON ----------
native=$(echo "$input" | jq '{
  cwd:            (.workspace.current_dir // .cwd // "unknown"),
  model:          (.model.display_name // "Claude"),
  model_id:       (.model.id // ""),
  version:        (.version // ""),
  session_id:     (.session_id // ""),
  transcript:     (.transcript_path // ""),
  cost_usd:       (.cost.total_cost_usd // 0),
  wall_ms:        (.cost.total_duration_ms // 0),
  api_ms:         (.cost.total_api_duration_ms // 0),
  lines_added:    (.cost.total_lines_added // 0),
  lines_removed:  (.cost.total_lines_removed // 0),
  ctx_input:      (.context_window.total_input_tokens // 0),
  ctx_output:     (.context_window.total_output_tokens // 0),
  ctx_size:       (.context_window.context_window_size // 200000),
  ctx_used_pct:   (.context_window.used_percentage // 0),
  cur_input:      (.context_window.current_usage.input_tokens // 0),
  cur_output:     (.context_window.current_usage.output_tokens // 0),
  cur_cache_read: (.context_window.current_usage.cache_read_input_tokens // 0),
  cur_cache_create: (.context_window.current_usage.cache_creation_input_tokens // 0)
}' 2>/dev/null)

# Helper to safely extract from native JSON
n() { echo "$native" | jq -r ".$1 // \"$2\"" 2>/dev/null; }
ni() { local v; v=$(echo "$native" | jq -r ".$1 // 0" 2>/dev/null); echo "${v%%.*}"; }

# ---------- Primary metrics from native JSON ----------
current_dir=$(n cwd "unknown" | sed "s|^$HOME|~|g")
model_name=$(n model "Claude")
model_id=$(n model_id "")
cc_version=$(n version "")
session_id=$(n session_id "")
transcript_path=$(n transcript "")

# Cost & duration (actual data from Claude Code)
calc_cost=$(n cost_usd "0")
wall_ms=$(ni wall_ms)
api_ms=$(ni api_ms)
lines_added=$(ni lines_added)
lines_removed=$(ni lines_removed)

# Context (actual data from Claude Code)
input_total=$(ni ctx_input)
output_total=$(ni ctx_output)
MAX_CONTEXT=$(ni ctx_size)
context_pct=$(ni ctx_used_pct)

# Current turn token breakdown
cur_input=$(ni cur_input)
cur_output=$(ni cur_output)
cache_read=$(ni cur_cache_read)
cache_create=$(ni cur_cache_create)

# Total tokens this session
tot_tokens=$(( input_total + output_total ))

# Current context tokens (for peak tracking)
actual_context_tokens=$(( cur_input + cache_read + cache_create ))

# Cache hit rate
total_prompt_tokens=$(( cur_input + cache_read + cache_create ))
cache_hit_rate=0
if [ "$total_prompt_tokens" -gt 0 ]; then
  cache_hit_rate=$(( cache_read * 100 / total_prompt_tokens ))
fi

# ---------- State files ----------
USAGE_STATE_FILE="${SCRIPT_DIR}/.usage_state"
CURRENT_TIME=$(date +%s)

if [ -f "$USAGE_STATE_FILE" ]; then
  source "$USAGE_STATE_FILE"
else
  SESSION_START_TIME=$CURRENT_TIME
  LAST_CONTEXT_TOKENS=0
  LAST_CHECK_TIME=$CURRENT_TIME
  PEAK_CONTEXT=0
  COMPACTION_COUNT=0
fi

# ---------- Git branch info ----------
git_info=""
expanded_dir=$(echo "$current_dir" | sed "s|~|$HOME|g")
if command -v git >/dev/null 2>&1 && [ -d "$expanded_dir" ]; then
  git_branch=$(git -C "$expanded_dir" symbolic-ref --short HEAD 2>/dev/null)
  if [ -n "$git_branch" ]; then
    git_dirty=""
    git_staged=$(git -C "$expanded_dir" diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
    git_modified=$(git -C "$expanded_dir" diff --numstat 2>/dev/null | wc -l | tr -d ' ')
    git_untracked=$(git -C "$expanded_dir" ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
    [ "$git_staged" -gt 0 ] && git_dirty="+${git_staged}"
    [ "$git_modified" -gt 0 ] && git_dirty="${git_dirty}~${git_modified}"
    [ "$git_untracked" -gt 0 ] && git_dirty="${git_dirty}?${git_untracked}"
    if [ -n "$git_dirty" ]; then
      git_info="🌿 ${git_branch}*(${git_dirty})"
    else
      git_info="🌿 ${git_branch}"
    fi
  fi
fi

# ---------- JSONL parsing (only for tool/message stats) ----------
message_count=0
tool_read=0; tool_edit=0; tool_bash=0; tool_write=0
tool_total=0; tool_success_rate=100; files_touched=0

# Determine session file path
session_file=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  session_file="$transcript_path"
elif [ -n "$session_id" ]; then
  project_dir=$(echo "$expanded_dir" | sed 's|/|-|g; s|_|-|g; s|\.|-|g')
  candidate="$HOME/.claude/projects/${project_dir}/${session_id}.jsonl"
  [ -f "$candidate" ] && session_file="$candidate"
fi

if [ -n "$session_file" ] && [ -f "$session_file" ]; then
  tool_metrics=$(jq -s '{
    message_count: [.[] | select(.type == "user" or .type == "assistant")] | length,
    tool_read: [.[] | select(.message.content[]?.name == "Read")] | length,
    tool_edit: [.[] | select(.message.content[]?.name == "Edit")] | length,
    tool_bash: [.[] | select(.message.content[]?.name == "Bash")] | length,
    tool_write: [.[] | select(.message.content[]?.name == "Write")] | length,
    tool_total: [.[] | select(.message.content[]?.type == "tool_use")] | length,
    files_touched: [.[] | select(.message.content[]?.name == "Edit" or .message.content[]?.name == "Write") | .message.content[] | select(.name == "Edit" or .name == "Write") | .input.file_path] | unique | length
  }' "$session_file" 2>/dev/null)

  if [ -n "$tool_metrics" ]; then
    message_count=$(echo "$tool_metrics" | jq -r '.message_count // 0')
    tool_read=$(echo "$tool_metrics" | jq -r '.tool_read // 0')
    tool_edit=$(echo "$tool_metrics" | jq -r '.tool_edit // 0')
    tool_bash=$(echo "$tool_metrics" | jq -r '.tool_bash // 0')
    tool_write=$(echo "$tool_metrics" | jq -r '.tool_write // 0')
    tool_total=$(echo "$tool_metrics" | jq -r '.tool_total // 0')
    files_touched=$(echo "$tool_metrics" | jq -r '.files_touched // 0')
  fi

  # Tool success rate
  if [ "$tool_total" -gt 0 ]; then
    tool_errors=$(grep -c '"tool_use_error"' "$session_file" 2>/dev/null || echo "0")
    tool_errors=$(echo "$tool_errors" | tr -d '[:space:]')
    [ -z "$tool_errors" ] && tool_errors=0
    if [ "$tool_errors" -gt 0 ] 2>/dev/null; then
      tool_success_rate=$(( (tool_total - tool_errors) * 100 / tool_total ))
      [ "$tool_success_rate" -lt 0 ] && tool_success_rate=0
    fi
  fi
fi

# ---------- Peak context & compaction tracking ----------
[ -z "$PEAK_CONTEXT" ] && PEAK_CONTEXT=0
[ "$actual_context_tokens" -gt "$PEAK_CONTEXT" ] && PEAK_CONTEXT=$actual_context_tokens

if [ "$LAST_CONTEXT_TOKENS" -gt 0 ] && [ "$actual_context_tokens" -gt 0 ]; then
  if [ "$actual_context_tokens" -lt $(( LAST_CONTEXT_TOKENS / 2 )) ]; then
    COMPACTION_COUNT=$(( ${COMPACTION_COUNT:-0} + 1 ))
  fi
fi

# ---------- Session timing ----------
# Prefer wall_ms from Claude Code; fall back to state file
if [ "$wall_ms" -gt 0 ]; then
  session_elapsed=$(( wall_ms / 1000 ))
else
  session_elapsed=$(( CURRENT_TIME - SESSION_START_TIME ))
fi
[ "$session_elapsed" -lt 1 ] && session_elapsed=1

# Context velocity & time to full
time_to_full="N/A"
context_velocity=0
if [ "$actual_context_tokens" -gt 0 ] && [ "$session_elapsed" -gt 60 ]; then
  context_velocity=$(( actual_context_tokens * 60 / session_elapsed ))
  if [ "$context_velocity" -gt 0 ]; then
    tokens_remaining=$(( MAX_CONTEXT - actual_context_tokens ))
    minutes_to_full=$(( tokens_remaining / context_velocity ))
    if [ "$minutes_to_full" -lt 1 ]; then time_to_full="<1m"
    elif [ "$minutes_to_full" -lt 60 ]; then time_to_full="${minutes_to_full}m"
    elif [ "$minutes_to_full" -lt 1440 ]; then time_to_full="$((minutes_to_full / 60))h $((minutes_to_full % 60))m"
    else time_to_full=">24h"
    fi
  fi
fi

# ---------- Save state ----------
{
  echo "SESSION_START_TIME=${SESSION_START_TIME:-$CURRENT_TIME}"
  echo "LAST_CONTEXT_TOKENS=$actual_context_tokens"
  echo "LAST_CHECK_TIME=$CURRENT_TIME"
  echo "PEAK_CONTEXT=$PEAK_CONTEXT"
  echo "COMPACTION_COUNT=${COMPACTION_COUNT:-0}"
} > "$USAGE_STATE_FILE"

# ---------- Cost per hour ----------
cost_per_hour="0.00"
if [ "$HAS_BC" -eq 1 ] && [ "$session_elapsed" -gt 0 ]; then
  session_hours=$(echo "scale=4; $session_elapsed / 3600" | bc)
  [ "$(echo "$session_hours < 0.0167" | bc -l 2>/dev/null || echo "0")" -eq 1 ] && session_hours="0.0167"
  cost_check=$(echo "$calc_cost > 0" | bc -l 2>/dev/null || echo "0")
  if [ "$cost_check" -eq 1 ]; then
    cost_per_hour=$(echo "scale=2; $calc_cost / $session_hours" | bc)
    [[ "$cost_per_hour" == .* ]] && cost_per_hour="0$cost_per_hour"
  fi
fi

# ---------- API time formatting ----------
api_time_display="0s"
if [ "$api_ms" -gt 0 ]; then
  api_secs=$((api_ms / 1000))
  if [ "$api_secs" -lt 60 ]; then api_time_display="${api_secs}s"
  elif [ "$api_secs" -lt 3600 ]; then api_time_display="$((api_secs / 60))m $((api_secs % 60))s"
  else api_time_display="$((api_secs / 3600))h $((api_secs % 3600 / 60))m"
  fi
fi

# ---------- Progress bar ----------
[ "$context_pct" -gt 100 ] && context_pct=100
width=10
filled=$(( context_pct * width / 100 ))
[ "$filled" -gt "$width" ] && filled=$width
[ "$filled" -lt 0 ] && filled=0
empty=$(( width - filled ))
bar=""
[ "$filled" -gt 0 ] && bar=$(printf '▓%.0s' $(seq 1 $filled))
[ "$empty" -gt 0 ] && bar="${bar}$(printf '░%.0s' $(seq 1 $empty))"

# ---------- Format helpers ----------
fmt_tokens() {
  local n="$1"
  if [ "$n" -ge 1000000 ] 2>/dev/null; then
    printf "%.1fM" "$(echo "$n / 1000000" | bc -l 2>/dev/null || echo "$((n / 1000000))")"
  elif [ "$n" -ge 1000 ] 2>/dev/null; then
    printf "%.1fK" "$(echo "$n / 1000" | bc -l 2>/dev/null || echo "$((n / 1000))")"
  else
    echo "$n"
  fi
}

# ---------- Aggregate tracking (other active sessions, last 5 min) ----------
# Only counts OTHER sessions modified in last 5 min (active sessions write frequently)
other_sessions=0
aggregate_cost="0.00"
aggregate_tokens=0
aggregate_rate="0.00"

if [ "$HAS_BC" -eq 1 ]; then
  # Find recently-active JSONL files, excluding current session
  current_jsonl=""
  [ -n "$transcript_path" ] && current_jsonl=$(basename "$transcript_path")
  other_session_files=""
  while IFS= read -r sf; do
    [ -z "$sf" ] && continue
    sf_base=$(basename "$sf")
    [ "$sf_base" = "$current_jsonl" ] && continue
    other_session_files="${other_session_files}${other_session_files:+ }$sf"
  done < <(find "$HOME/.claude/projects" -name "*.jsonl" -type f -mmin -5 2>/dev/null)

  if [ -n "$other_session_files" ]; then
    for sf in $other_session_files; do
      [ -f "$sf" ] || continue
      other_sessions=$(( other_sessions + 1 ))
      sf_metrics=$(jq -s '{
        i: ([.[] | select(.message.usage) | .message.usage.input_tokens // 0] | add // 0),
        o: ([.[] | select(.message.usage) | .message.usage.output_tokens // 0] | add // 0),
        cr: ([.[] | select(.message.usage) | .message.usage.cache_read_input_tokens // 0] | add // 0),
        cc: ([.[] | select(.message.usage) | .message.usage.cache_creation_input_tokens // 0] | add // 0)
      }' "$sf" 2>/dev/null) || continue

      sf_i=$(echo "$sf_metrics" | jq -r '.i // 0'); [ "$sf_i" = "null" ] && sf_i=0
      sf_o=$(echo "$sf_metrics" | jq -r '.o // 0'); [ "$sf_o" = "null" ] && sf_o=0
      sf_cr=$(echo "$sf_metrics" | jq -r '.cr // 0'); [ "$sf_cr" = "null" ] && sf_cr=0
      sf_cc=$(echo "$sf_metrics" | jq -r '.cc // 0'); [ "$sf_cc" = "null" ] && sf_cc=0

      sf_cost=$(echo "scale=4; (($sf_i + $sf_cc) * 15.00 + $sf_o * 75.00 + $sf_cr * 1.875) / 1000000" | bc 2>/dev/null || echo "0")
      aggregate_cost=$(echo "scale=2; $aggregate_cost + $sf_cost" | bc 2>/dev/null || echo "$aggregate_cost")
      aggregate_tokens=$(( aggregate_tokens + sf_i + sf_o + sf_cr + sf_cc ))
    done
    [[ "$aggregate_cost" == .* ]] && aggregate_cost="0$aggregate_cost"

    if [ "$other_sessions" -gt 0 ]; then
      # Hourly rate from oldest other session's birth time
      agg_start=$CURRENT_TIME
      for sf in $other_session_files; do
        sf_birth=$(stat -f %B "$sf" 2>/dev/null || stat -c %W "$sf" 2>/dev/null || echo "$CURRENT_TIME")
        [ "$sf_birth" -gt 0 ] && [ "$sf_birth" -lt "$agg_start" ] && agg_start=$sf_birth
      done
      agg_elapsed=$((CURRENT_TIME - agg_start))
      [ "$agg_elapsed" -lt 60 ] && agg_elapsed=60
      agg_hours=$(echo "scale=4; $agg_elapsed / 3600" | bc)
      [ "$(echo "$agg_hours < 0.0167" | bc -l 2>/dev/null || echo "0")" -eq 1 ] && agg_hours="0.0167"
      aggregate_rate=$(echo "scale=2; $aggregate_cost / $agg_hours" | bc 2>/dev/null || echo "0.00")
      [[ "$aggregate_rate" == .* ]] && aggregate_rate="0$aggregate_rate"
    fi
  fi
fi

# ---------- Session time display ----------
session_hours_display=$(( session_elapsed / 3600 ))
session_mins_display=$(( (session_elapsed % 3600) / 60 ))
session_time="${session_hours_display}h ${session_mins_display}m"

# ---------- Status & Recommendations ----------
# Priority order: critical issues first, then warnings, then positive signals
status_msg=""

if [ "$context_pct" -ge 90 ]; then
  status_msg="🚨 Memory almost full (${context_pct}%) — Run /compact now or start a new session"
elif [ "$context_pct" -ge 75 ]; then
  status_msg="⚠️ Memory filling up (${context_pct}%) — Run /compact soon to free space"
elif [ "$context_velocity" -gt 3000 ] 2>/dev/null; then
  status_msg="⚡ Using memory fast ($(fmt_tokens $context_velocity)/min) — Break task into smaller steps"
elif [ "${COMPACTION_COUNT:-0}" -gt 3 ] 2>/dev/null; then
  status_msg="🔄 Compacted ${COMPACTION_COUNT}x — Session is long. Consider starting fresh (/clear)"
elif [ "$tool_success_rate" -lt 90 ] 2>/dev/null; then
  status_msg="⚠️ ${tool_success_rate}% tool success — Errors may be causing retries, check output"
elif [ "$other_sessions" -gt 0 ]; then
  status_msg="✅ ${other_sessions} other session(s) also running — \$${aggregate_rate}/hr combined"
else
  status_msg="✅ All good"
fi

# ---------- Format displays ----------
tok_display=$(fmt_tokens "$tot_tokens")
context_tokens_display=$(fmt_tokens "$actual_context_tokens")
max_context_display=$(fmt_tokens "$MAX_CONTEXT")
peak_display=$(fmt_tokens "$PEAK_CONTEXT")
velocity_display=$(fmt_tokens "$context_velocity")
input_display=$(fmt_tokens "$input_total")
output_display=$(fmt_tokens "$output_total")
cache_read_display=$(fmt_tokens "$cache_read")

cost_display=$(printf "%.2f" "$calc_cost" 2>/dev/null || echo "$calc_cost")

# ---------- Render ----------
# Line 1: Directory, Model, Version, Git
printf '📁 %s  🤖 %s  📟 %s' "$current_dir" "$model_name" "${cc_version:-?}"
[ -n "$git_info" ] && printf '  %s' "$git_info"

# Line 2: Context
printf '\n🧠 Context: %s/%s (%d%%) • Until compact: %s %s' \
  "$context_tokens_display" "$max_context_display" "$context_pct" "$time_to_full" "$bar"

# Line 3: Cost
printf '\n💰 $%s ($%s/hr) • In:%s Out:%s Cache:%s' \
  "$cost_display" "$cost_per_hour" "$input_display" "$output_display" "$cache_read_display"

# Line 4: Timing
printf '\n⏱️  Session: %s (API: %s) • Cache: %d%%' \
  "$session_time" "$api_time_display" "$cache_hit_rate"

# Line 5: Tokens, Messages, Tools
printf '\n📊 %s tok • 💬 %d msgs • 🔧 R:%d E:%d B:%d W:%d' \
  "$tok_display" "$message_count" "$tool_read" "$tool_edit" "$tool_bash" "$tool_write"

# Line 6: Files, Velocity, Success, Code Changes
printf '\n📂 %d files • ⚡ %s/min • ✅ %d%% tools • 📝 +%d/-%d lines' \
  "$files_touched" "$velocity_display" "$tool_success_rate" "$lines_added" "$lines_removed"

# Line 7: Peak & Compactions
printf '\n📈 Peak: %s' "$peak_display"
[ "${COMPACTION_COUNT:-0}" -gt 0 ] && printf ' • 🔄 %dx compact' "$COMPACTION_COUNT"

# Line 8: Aggregate (only if other sessions are running)
if [ "$other_sessions" -gt 0 ]; then
  agg_cost_display=$(printf "%.2f" "$aggregate_cost" 2>/dev/null || echo "$aggregate_cost")
  agg_tokens_display=$(fmt_tokens "$aggregate_tokens")
  printf '\n🌐 +%d other session(s): $%s (%s tok) • $%s/hr' \
    "$other_sessions" "$agg_cost_display" "$agg_tokens_display" "$aggregate_rate"
fi

# Line 9: Status
printf '\n%s' "$status_msg"

printf '\n'
