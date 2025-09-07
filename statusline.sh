#!/usr/bin/env bash
# Intelligent Claude Code Statusline — Clean Consolidated Build
# Layout (6 lines):
#  1) 📁 <dir>  🤖 <model>  📟 <version>  [optional update notice]
#  2) ⌛ <hh>h <mm>m until reset at <HH:MM> (<session %>) <====---->
#  3) 📊 <tokens> tok • 🧠 Context: <mode/status> • 💰 ~$<cost>
#  4) 💡 🌊 Wave:5 • <recommendation>
#  5) ✅ API <min%> • <in> in • <out> out • reset <Sun Sep 07, 12:18 PM>
#  6) 🎯 🟢 GREEN
#
# Key env toggles:
#   SHOW_UPDATE_NOTICE=1|0   (default 1)
#   UPDATE_NOTICE_MESSAGE="✗ Auto-update failed …"
#   RESET_SOURCE=session|api|env  (default session)
#   RESET_LOCAL_HHMM="13:00" or RESET_RFC3339="2025-09-07T13:00:00-04:00" (used when RESET_SOURCE=env)
#   API_PROBE_ENABLED=1|0    (default 0) - Set to 1 to call Anthropic API for real-time limits
#   API_CACHE_TTL=60         (seconds)
#   WINDOW_SECS=18000        (5h default)
# Requires: bash, date, awk; optional: jq, python3, curl

# ---------- Single-run sentinel ----------
now_ts=$(date +%s)
if [ -n "$STATUSLINE_LAST_RENDER" ] && [ $(( now_ts - STATUSLINE_LAST_RENDER )) -lt 2 ]; then
  exit 0
fi
export STATUSLINE_LAST_RENDER=$now_ts

# ---------- Setup & input ----------
input=$(cat)
HAS_JQ=0
command -v jq >/dev/null 2>&1 && HAS_JQ=1

# Colors
use_color=1; [ -n "$NO_COLOR" ] && use_color=0
rst() { [ "$use_color" -eq 1 ] && printf '\033[0m'; }
zone_color() { :; } # will be set later

# Extract fields from Claude statusline JSON
if [ "$HAS_JQ" -eq 1 ]; then
  current_dir=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // "unknown"' 2>/dev/null | sed "s|^$HOME|~|g")
  model_name=$(echo "$input" | jq -r '.model.display_name // "Claude"' 2>/dev/null)
  cc_version=$(echo "$input" | jq -r '.version // ""' 2>/dev/null)
  session_id=$(echo "$input" | jq -r '.session_id // ""' 2>/dev/null)
else
  # very light fallback
  current_dir=$(echo "$input" | sed -n 's/.*"current_dir"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  [ -z "$current_dir" ] && current_dir="unknown"
  current_dir=$(echo "$current_dir" | sed "s|^$HOME|~|g")
  model_name=$(echo "$input" | sed -n 's/.*"display_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  [ -z "$model_name" ] && model_name="Claude"
  cc_version=$(echo "$input" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  session_id=$(echo "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
fi

# ---------- Window & state ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USAGE_STATE_FILE="${SCRIPT_DIR}/.usage_state"
API_STATE_FILE="${SCRIPT_DIR}/.api_state"
WINDOW_SECS=${WINDOW_SECS:-18000}  # default 5 hours

parse_reset_ts() {
  local r="$1"
  # RFC3339 or "YYYY-mm-dd HH:MM"
  if date -d "$r" +%s >/dev/null 2>&1; then
    date -d "$r" +%s; return 0
  fi
  # HH:MM today
  if [[ "$r" =~ ^([0-2]?[0-9]):([0-5][0-9])$ ]]; then
    local hh="${BASH_REMATCH[1]}"; local mm="${BASH_REMATCH[2]}"
    local today="$(date +%Y-%m-%d)"
    date -d "${today} ${hh}:${mm}" +%s 2>/dev/null && return 0
  fi
  return 1
}

CURRENT_TIME=$(date +%s)
if [ -f "$USAGE_STATE_FILE" ]; then
  source "$USAGE_STATE_FILE"
else
  USAGE_START_TIME=$CURRENT_TIME
  USAGE_RESET_TIME=$(( CURRENT_TIME + WINDOW_SECS ))
  TOTAL_TOKENS=0
  LAST_CHECK_TIME=$CURRENT_TIME
  {
    echo "USAGE_START_TIME=$USAGE_START_TIME"
    echo "USAGE_RESET_TIME=$USAGE_RESET_TIME"
    echo "TOTAL_TOKENS=$TOTAL_TOKENS"
    echo "LAST_CHECK_TIME=$LAST_CHECK_TIME"
  } > "$USAGE_STATE_FILE"
fi

# Env overrides for UI-truth reset
applied_env=0
if [ -n "$RESET_RFC3339" ]; then
  if ts=$(parse_reset_ts "$RESET_RFC3339"); then
    [ "$CURRENT_TIME" -ge "$ts" ] && ts=$(( ts + 24*60*60 ))
    USAGE_RESET_TIME="$ts"
    USAGE_START_TIME=$(( USAGE_RESET_TIME - WINDOW_SECS ))
    applied_env=1
  fi
elif [ -n "$RESET_LOCAL_HHMM" ]; then
  if ts=$(parse_reset_ts "$RESET_LOCAL_HHMM"); then
    [ "$CURRENT_TIME" -ge "$ts" ] && ts=$(( ts + 24*60*60 ))
    USAGE_RESET_TIME="$ts"
    USAGE_START_TIME=$(( USAGE_RESET_TIME - WINDOW_SECS ))
    applied_env=1
  fi
fi

# Roll forward if we've crossed the reset boundary
CURRENT_TIME=$(date +%s)
if [ "$CURRENT_TIME" -ge "$USAGE_RESET_TIME" ]; then
  USAGE_START_TIME=$CURRENT_TIME
  USAGE_RESET_TIME=$(( CURRENT_TIME + WINDOW_SECS ))
  TOTAL_TOKENS=0
  LAST_CHECK_TIME=$CURRENT_TIME
  {
    echo "USAGE_START_TIME=$USAGE_START_TIME"
    echo "USAGE_RESET_TIME=$USAGE_RESET_TIME"
    echo "TOTAL_TOKENS=$TOTAL_TOKENS"
    echo "LAST_CHECK_TIME=$LAST_CHECK_TIME"
  } > "$USAGE_STATE_FILE"
fi

# ---------- Token & context (lightweight) ----------
tok_display="0"
tot_tokens=$TOTAL_TOKENS
tpm=0
MAX_CONTEXT=200000
context_display="Auto-managed"
context_remaining_pct=75

if [ -n "$session_id" ] && [ "$HAS_JQ" -eq 1 ]; then
  project_dir=$(echo "$current_dir" | sed "s|~|$HOME|g" | sed 's|/|-|g; s|_|-|g; s|\.|-|g')
  session_file="$HOME/.claude/projects/${project_dir}/${session_id}.jsonl"
  if [ -f "$session_file" ]; then
    input_total=$(grep -a '"usage"' "$session_file" | jq -r '.message.usage.input_tokens // 0' 2>/dev/null | awk '{s+=$1} END{print s}')
    output_total=$(grep -a '"usage"' "$session_file" | jq -r '.message.usage.output_tokens // 0' 2>/dev/null | awk '{s+=$1} END{print s}')
    cache_total=$(grep -a '"usage"' "$session_file" | jq -r '.message.usage.cache_read_input_tokens // 0' 2>/dev/null | awk '{s+=$1} END{print s}')
    [ -z "$input_total" ] && input_total=0
    [ -z "$output_total" ] && output_total=0
    [ -z "$cache_total" ] && cache_total=0
    tot_tokens=$(( input_total + output_total + cache_total ))
    TOTAL_TOKENS=$tot_tokens
    sed -i.bak "s/^TOTAL_TOKENS=.*/TOTAL_TOKENS=$TOTAL_TOKENS/" "$USAGE_STATE_FILE" 2>/dev/null; rm -f "${USAGE_STATE_FILE}.bak"
    # context approx from last message
    actual_context_tokens=$(tail -200 "$session_file" | jq -r 'select(.message.usage) | .message.usage | ((.input_tokens // 0) + (.cache_read_input_tokens // 0))' 2>/dev/null | tail -1)
    if [ -n "$actual_context_tokens" ] && [ "$actual_context_tokens" -gt 0 ] 2>/dev/null; then
      usage_pct=$(( actual_context_tokens * 100 / MAX_CONTEXT ))
      context_remaining_pct=$(( 100 - usage_pct )); [ "$context_remaining_pct" -lt 0 ] && context_remaining_pct=0
      [ "$context_remaining_pct" -gt 100 ] && context_remaining_pct=100
      ctx_label="OK"; ctx_color="\033[38;5;46m"
      [ "$context_remaining_pct" -le 50 ] && { ctx_label="MODERATE"; ctx_color="\033[38;5;220m"; }
      [ "$context_remaining_pct" -le 25 ] && { ctx_label="LOW"; ctx_color="\033[38;5;208m"; }
      [ "$context_remaining_pct" -le 10 ] && { ctx_label="CRITICAL"; ctx_color="\033[38;5;196m"; }
      context_display="${context_remaining_pct}% ${ctx_label}"
    fi
  fi
fi

# token display
if [ "$tot_tokens" -gt 1000000 ]; then
  tok_display="$(( tot_tokens / 1000000 ))M"
elif [ "$tot_tokens" -gt 1000 ]; then
  tok_display="$(( tot_tokens / 1000 ))K"
else
  tok_display="$tot_tokens"
fi

# crude cost estimate (placeholder)
if [ "$tot_tokens" -gt 0 ]; then
  # ~$3 per 1M tokens baseline
  est_cents=$(( tot_tokens * 3 / 10000 ))
  [ "$est_cents" -lt 1 ] && est_cents=1
  cost_display="💰 ~\$${est_cents}"
else
  cost_display="💰 ~$0"
fi

# ---------- Session progress ----------
total_duration=$(( USAGE_RESET_TIME - USAGE_START_TIME ))
[ "$total_duration" -le 0 ] && total_duration=1
elapsed=$(( CURRENT_TIME - USAGE_START_TIME ))
[ "$elapsed" -lt 0 ] && elapsed=0
session_pct=$(( elapsed * 100 / total_duration ))
[ "$session_pct" -gt 100 ] && session_pct=100
remaining=$(( USAGE_RESET_TIME - CURRENT_TIME ))
[ "$remaining" -lt 0 ] && remaining=0
rh=$(( remaining / 3600 ))
rm=$(( (remaining % 3600) / 60 ))
# Ensure minutes are always 0-59
[ "$rm" -gt 59 ] && rm=59
end_hm=$(date -d "@$USAGE_RESET_TIME" +"%H:%M" 2>/dev/null || date -r "$USAGE_RESET_TIME" +"%H:%M")
# progress bar
width=10; filled=$(( session_pct * width / 100 )); ((filled>width))&&filled=$width
empty=$(( width - filled ))
# Use different characters for better visibility
if [ "$filled" -gt 0 ]; then
  bar="$(printf '▓%.0s' $(seq 1 $filled))$(printf '░%.0s' $(seq 1 $empty))"
else
  bar="$(printf '░%.0s' $(seq 1 $width))"
fi

# Countdown source - prefer API if available
RESET_SOURCE=${RESET_SOURCE:-session}
# Auto-switch to API if we have API data
[ -n "$API_PROBE_USED" ] && [ -n "$api_reset_epoch" ] && RESET_SOURCE=api
api_countdown_used=""
api_reset_epoch=""; api_reset_local=""
api_req_rem=""; api_in_rem=""; api_out_rem=""; api_pct_rem=""; API_PROBE_USED=""

# ---------- API probe (optional but precise) ----------
# Only call API if explicitly enabled AND API key is available
API_PROBE_ENABLED=${API_PROBE_ENABLED:-0}  # Changed default to 0 (disabled)

# Smart caching: extend TTL when limits are high, reduce when critical
API_CACHE_TTL=${API_CACHE_TTL:-60}
# Dynamic TTL based on usage patterns
if [ -f "$HOME/.claude/statusline_api_cache.txt" ]; then
  last_pct=$(grep -o 'API [0-9]*%' "$HOME/.claude/statusline_api_cache.txt" 2>/dev/null | grep -o '[0-9]*' | head -1)
  if [ -n "$last_pct" ] && [ "$last_pct" -gt 80 ] 2>/dev/null; then
    API_CACHE_TTL=300  # 5min when >80%
  elif [ -n "$last_pct" ] && [ "$last_pct" -lt 20 ] 2>/dev/null; then
    API_CACHE_TTL=30   # 30s when <20%
  fi
fi

# First check if we have environment variables from wrapper
if [ -n "$API_REQ_REMAINING" ] && [ -n "$API_RESET_EPOCH" ]; then
  # Use pre-fetched API data from wrapper
  api_req_rem="$API_REQ_REMAINING"
  api_req_lim="$API_REQ_LIMIT"
  api_in_rem="$API_IN_REMAINING"
  api_in_lim="$API_IN_LIMIT"
  api_out_rem="$API_OUT_REMAINING"
  api_out_lim="$API_OUT_LIMIT"
  api_reset_epoch="$API_RESET_EPOCH"
  if [ -n "$api_reset_epoch" ]; then
    api_reset_local=$(date -d "@$api_reset_epoch" +"%a %b %d, %I:%M %p" 2>/dev/null || date -r "$api_reset_epoch" +"%a %b %d, %I:%M %p")
  fi
  API_PROBE_USED=1
elif [ "$API_PROBE_ENABLED" -eq 1 ] && [ -n "$CLAUDE_STATS_API_KEY" ] && command -v curl >/dev/null 2>&1; then
  API_CACHE_DIR="$HOME/.claude"; mkdir -p "$API_CACHE_DIR" 2>/dev/null
  API_CACHE_FILE="$API_CACHE_DIR/statusline_api_cache.txt"
  # API_CACHE_TTL already set dynamically above
  do_probe=1
  
  # Enhanced cache logic: skip if recent call with same session
  if [ -f "$API_STATE_FILE" ]; then
    source "$API_STATE_FILE" 2>/dev/null
    if [ -n "$SESSION_ID_AT_CALL" ] && [ "$SESSION_ID_AT_CALL" = "$session_id" ]; then
      token_delta=$(( tot_tokens - ${TOTAL_TOKENS_AT_CALL:-0} ))
      # Skip API call if <1K new tokens since last call
      [ "$token_delta" -lt 1000 ] && do_probe=0
    fi
  fi
  
  if [ -f "$API_CACHE_FILE" ] && [ "$do_probe" -eq 1 ]; then
    cache_age=$(( now_ts - $(stat -f %m "$API_CACHE_FILE" 2>/dev/null || stat -c %Y "$API_CACHE_FILE" 2>/dev/null) ))
    [ "$cache_age" -lt "$API_CACHE_TTL" ] && do_probe=0
  fi
  if [ "$do_probe" -eq 1 ]; then
    api_hdrs="$(curl -sS -D - https://api.anthropic.com/v1/messages \
      -H "x-api-key: $CLAUDE_STATS_API_KEY" \
      -H "anthropic-version: 2023-06-01" \
      -H "content-type: application/json" \
      -d '{"model":"claude-3-haiku-20240307","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' \
      -o /dev/null)"
    printf "%s" "$api_hdrs" > "$API_CACHE_FILE" 2>/dev/null
    # Track session usage to reduce API calls
    {
      echo "LAST_API_CALL=$now_ts"
      echo "TOTAL_TOKENS_AT_CALL=$tot_tokens"
      echo "SESSION_ID_AT_CALL=$session_id"
    } > "$API_STATE_FILE" 2>/dev/null
  else
    api_hdrs="$(cat "$API_CACHE_FILE" 2>/dev/null)"
  fi
  # Extract headers
  api_req_rem=$(printf "%s" "$api_hdrs" | awk -F': ' 'tolower($1)=="anthropic-ratelimit-requests-remaining"{print $2}' | tr -d '\r')
  api_req_lim=$(printf "%s" "$api_hdrs" | awk -F': ' 'tolower($1)=="anthropic-ratelimit-requests-limit"{print $2}' | tr -d '\r')
  api_in_rem=$(printf "%s" "$api_hdrs" | awk -F': ' 'tolower($1)=="anthropic-ratelimit-input-tokens-remaining"{print $2}' | tr -d '\r')
  api_in_lim=$(printf "%s" "$api_hdrs" | awk -F': ' 'tolower($1)=="anthropic-ratelimit-input-tokens-limit"{print $2}' | tr -d '\r')
  api_out_rem=$(printf "%s" "$api_hdrs" | awk -F': ' 'tolower($1)=="anthropic-ratelimit-output-tokens-remaining"{print $2}' | tr -d '\r')
  api_out_lim=$(printf "%s" "$api_hdrs" | awk -F': ' 'tolower($1)=="anthropic-ratelimit-output-tokens-limit"{print $2}' | tr -d '\r')
  api_req_reset=$(printf "%s" "$api_hdrs" | awk -F': ' 'tolower($1)=="anthropic-ratelimit-requests-reset"{print $2}' | tr -d '\r')
  if [ -n "$api_req_reset" ]; then
    # local string
    api_reset_local=$(python3 - "$api_req_reset" <<'PY'
import sys, datetime
s=sys.argv[1].strip()
if s.endswith("Z"): s=s[:-1]+"+00:00"
dt=datetime.datetime.fromisoformat(s)
print(dt.astimezone().strftime("%a %b %d, %I:%M %p"))
PY
)
    # epoch
    api_reset_epoch=$(python3 - "$api_req_reset" <<'PY'
import sys, datetime
s=sys.argv[1].strip()
if s.endswith("Z"): s=s[:-1]+"+00:00"
dt=datetime.datetime.fromisoformat(s)
print(int(dt.timestamp()))
PY
)
  fi
  # percent remaining (conservative min across buckets)
  pct_calc() { rem="$1"; lim="$2"; case "$rem:$lim" in (":"|"":*|*:"") echo ""; return;; esac
    case "$rem$lim" in (*[!0-9]*) echo ""; return;; esac
    [ "$lim" -gt 0 ] 2>/dev/null && echo $(( rem * 100 / lim )) || echo ""; }
  req_pct=$(pct_calc "$api_req_rem" "$api_req_lim")
  in_pct=$(pct_calc "$api_in_rem" "$api_in_lim")
  out_pct=$(pct_calc "$api_out_rem" "$api_out_lim")
  for v in "$req_pct" "$in_pct" "$out_pct"; do
    [ -n "$v" ] && { if [ -z "$api_pct_rem" ] || [ "$v" -lt "$api_pct_rem" ]; then api_pct_rem="$v"; fi; }
  done
  API_PROBE_USED=1
fi

# If caller wants countdown to follow API reset:
if [ "$RESET_SOURCE" = "api" ] && [ -n "$api_reset_epoch" ]; then
  remaining=$(( api_reset_epoch - CURRENT_TIME )); [ "$remaining" -lt 0 ] && remaining=0
  rh=$(( remaining / 3600 )); rm=$(( (remaining % 3600) / 60 ))
  # Ensure minutes are always 0-59
  [ "$rm" -gt 59 ] && rm=59
  end_hm=$(python3 - "$api_reset_epoch" <<'PY'
import sys, datetime
ts=int(sys.argv[1])
print(datetime.datetime.fromtimestamp(ts).astimezone().strftime("%H:%M"))
PY
)
  api_countdown_used=1
fi

# ---------- Status zones & recommendation ----------
if [ "$session_pct" -ge 95 ]; then
  zone_name="CRITICAL"; zone_dot="🔴"; zone_color(){ [ "$use_color" -eq 1 ] && printf '\033[38;5;196m'; }
elif [ "$session_pct" -ge 85 ]; then
  zone_name="RED"; zone_dot="🟠"; zone_color(){ [ "$use_color" -eq 1 ] && printf '\033[38;5;208m'; }
elif [ "$session_pct" -ge 75 ]; then
  zone_name="ORANGE"; zone_dot="🟡"; zone_color(){ [ "$use_color" -eq 1 ] && printf '\033[38;5;220m'; }
elif [ "$session_pct" -ge 60 ]; then
  zone_name="YELLOW"; zone_dot="🟡"; zone_color(){ [ "$use_color" -eq 1 ] && printf '\033[38;5;226m'; }
else
  zone_name="GREEN"; zone_dot="🟢"; zone_color(){ [ "$use_color" -eq 1 ] && printf '\033[38;5;46m'; }
fi

recommendation=""
if [ "$session_pct" -ge 90 ]; then
  recommendation="🚨 API Critical - Save work, use /pause"
elif [ "$session_pct" -ge 80 ]; then
  recommendation="⚠️ API Low - Use --uc --max-waves 3"
elif [ "$session_pct" -ge 60 ]; then
  recommendation="💡 API Medium - Consider --uc"
elif [ "$context_remaining_pct" -le 10 ]; then
  recommendation="🧠 Context Critical - Will auto-compact soon"
else
  recommendation="🚀 Optimal - Ready for --wave-mode"
fi

# API line (humanized) if probe ran; otherwise fallback to session-based pct-left
fmt_num() { n="$1"; case "$n" in (""|*[!0-9]*) echo "?";; *)
  if [ "$n" -ge 1000000 ] 2>/dev/null; then echo "$(( n / 1000000 ))M"
  elif [ "$n" -ge 1000 ] 2>/dev/null; then echo "$(( n / 1000 ))k"
  else echo "$n"; fi;; esac; }
if [ -n "$API_PROBE_USED" ]; then
  api_limit_status="✅ API ${api_pct_rem:+${api_pct_rem}% • }$(fmt_num "$api_in_rem") in • $(fmt_num "$api_out_rem") out${api_reset_local:+ • reset ${api_reset_local}}"
else
  api_remaining_pct=$(( 100 - session_pct ))
  api_limit_status="✅ API ${api_remaining_pct}% LEFT"
fi

# ---------- UI Rendering (exact layout) ----------
# Line 1
SHOW_UPDATE_NOTICE=${SHOW_UPDATE_NOTICE:-1}
if [ "$SHOW_UPDATE_NOTICE" -eq 1 ]; then
  printf '📁 %s  🤖 %s  📟 %s  %s' "$current_dir" "$model_name" "${cc_version:-1.0.81}" "$UPDATE_NOTICE_MESSAGE"
else
  printf '📁 %s  🤖 %s  📟 %s' "$current_dir" "$model_name" "${cc_version:-1.0.81}"
fi

# Line 2
if [ -n "$api_countdown_used" ]; then
  printf '\n⌛ %dh %02dm until API reset at %s (%d%%) %s' "$rh" "$rm" "$end_hm" "$session_pct" "$bar"
else
  printf '\n⌛ %dh %02dm until reset at %s (%d%%) %s' "$rh" "$rm" "$end_hm" "$session_pct" "$bar"
fi

# Line 3
printf '\n📊 %s tok • 🧠 Context: %s • %s' "$tok_display" "$context_display" "$cost_display"

# Line 4
RECO_ICON=${RECO_ICON:-"💡"}
printf '\n%s 🌊 Wave:5 • %s' "$RECO_ICON" "$recommendation"

# Line 5
printf '\n%s' "$api_limit_status"

# Line 6
printf '\n🎯 %s %s' "$zone_dot" "$zone_name"
printf '\n'
