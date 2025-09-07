#!/bin/bash
# Intelligent Claude Code Statusline - Standalone Version
# Dependencies except jq (optional but recommended)
# Enhanced with resource monitoring, recommendations, and safety features
# Version: 2.0.0-standalone

STATUSLINE_VERSION="2.0.0-standalone"

input=$(cat)

# Get the directory where this statusline script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/statusline.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# ---- check jq availability ----
HAS_JQ=0
if command -v jq >/dev/null 2>&1; then
  HAS_JQ=1
fi

# ---- logging ----
{
  echo "[$TIMESTAMP] Intelligent Statusline v${STATUSLINE_VERSION}"
  echo "[$TIMESTAMP] Mode: Standalone"
  if [ "$HAS_JQ" -eq 1 ]; then
    echo "[$TIMESTAMP] JSON Parser: jq available"
  else
    echo "[$TIMESTAMP] JSON Parser: bash fallback"
  fi
  echo "---"
} >> "$LOG_FILE" 2>/dev/null

# ---- color helpers ----
use_color=1
[ -n "$NO_COLOR" ] && use_color=0

C() { if [ "$use_color" -eq 1 ]; then printf '\033[%sm' "$1"; fi; }
RST() { if [ "$use_color" -eq 1 ]; then printf '\033[0m'; fi; }

# ---- modern colors ----
dir_color() { if [ "$use_color" -eq 1 ]; then printf '\033[38;5;117m'; fi; }    # sky blue
model_color() { if [ "$use_color" -eq 1 ]; then printf '\033[38;5;147m'; fi; }  # light purple  
git_color() { if [ "$use_color" -eq 1 ]; then printf '\033[38;5;150m'; fi; }    # soft green
usage_color() { if [ "$use_color" -eq 1 ]; then printf '\033[38;5;189m'; fi; }  # lavender
cost_color() { if [ "$use_color" -eq 1 ]; then printf '\033[38;5;222m'; fi; }   # light gold
rst() { if [ "$use_color" -eq 1 ]; then printf '\033[0m'; fi; }

# ---- time helpers ----
to_epoch() {
  ts="$1"
  if command -v gdate >/dev/null 2>&1; then 
    gdate -d "$ts" +%s 2>/dev/null && return
  fi
  date -u -j -f "%Y-%m-%dT%H:%M:%S%z" "${ts/Z/+0000}" +%s 2>/dev/null && return
  python3 - "$ts" <<'PY' 2>/dev/null
import sys, datetime
s=sys.argv[1].replace('Z','+00:00')
print(int(datetime.datetime.fromisoformat(s).timestamp()))
PY
}

fmt_time_hm() {
  epoch="$1"
  if date -r 0 +%s >/dev/null 2>&1; then 
    date -r "$epoch" +"%H:%M"
  else 
    date -d "@$epoch" +"%H:%M"
  fi
}

progress_bar() {
  pct="${1:-0}"; width="${2:-10}"
  [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
  ((pct<0))&&pct=0; ((pct>100))&&pct=100
  filled=$(( pct * width / 100 ))
  empty=$(( width - filled ))
  printf '%*s' "$filled" '' | tr ' ' '='
  printf '%*s' "$empty" '' | tr ' ' '-'
}

# ---- JSON extraction (bash fallback) ----
extract_json_string() {
  local json="$1"
  local key="$2"
  local default="${3:-}"
  
  local field="${key##*.}"
  field="${field%% *}"
  
  local value=$(echo "$json" | grep -o "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/')
  
  if [ -n "$value" ]; then
    value=$(echo "$value" | sed 's/\\\\/\//g')
  fi
  
  if [ -z "$value" ] || [ "$value" = "null" ]; then
    value=$(echo "$json" | grep -o "\"${field}\"[[:space:]]*:[[:space:]]*[0-9.]\+" | head -1 | sed 's/.*:[[:space:]]*\([0-9.]\+\).*/\1/')
  fi
  
  if [ -n "$value" ] && [ "$value" != "null" ]; then
    echo "$value"
  else
    echo "$default"
  fi
}

# ---- Extract basic info ----
if [ "$HAS_JQ" -eq 1 ]; then
  current_dir=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // "unknown"' 2>/dev/null | sed "s|^$HOME|~|g")
  model_name=$(echo "$input" | jq -r '.model.display_name // "Claude"' 2>/dev/null)
  session_id=$(echo "$input" | jq -r '.session_id // ""' 2>/dev/null)
  cc_version=$(echo "$input" | jq -r '.version // ""' 2>/dev/null)
else
  current_dir=$(extract_json_string "$input" "current_dir" "unknown")
  current_dir=$(echo "$current_dir" | sed "s|^$HOME|~|g")
  model_name=$(extract_json_string "$input" "display_name" "Claude")
  session_id=$(extract_json_string "$input" "session_id" "")
  cc_version=$(extract_json_string "$input" "version" "")
fi

# ---- Git branch ----
git_branch=""
if git rev-parse --git-dir >/dev/null 2>&1; then
  git_branch=$(git branch --show-current 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)
fi

# ---- Built-in Usage Tracking ----
# Use Claude Code session files directly for usage data
USAGE_CACHE_FILE="${SCRIPT_DIR}/.usage_cache"
USAGE_STATE_FILE="${SCRIPT_DIR}/.usage_state"

# Initialize or read usage state
if [ -f "$USAGE_STATE_FILE" ]; then
  source "$USAGE_STATE_FILE"
else
  # Initialize state
  USAGE_START_TIME=$(date +%s)
  USAGE_RESET_TIME=$(( USAGE_START_TIME + 86400 ))  # 24 hours
  TOTAL_TOKENS=0
  LAST_CHECK_TIME=$USAGE_START_TIME
  echo "USAGE_START_TIME=$USAGE_START_TIME" > "$USAGE_STATE_FILE"
  echo "USAGE_RESET_TIME=$USAGE_RESET_TIME" >> "$USAGE_STATE_FILE"
  echo "TOTAL_TOKENS=0" >> "$USAGE_STATE_FILE"
  echo "LAST_CHECK_TIME=$USAGE_START_TIME" >> "$USAGE_STATE_FILE"
fi

# Check if we need to reset (24-hour cycle)
CURRENT_TIME=$(date +%s)
if [ "$CURRENT_TIME" -ge "$USAGE_RESET_TIME" ]; then
  # Reset usage tracking
  USAGE_START_TIME=$CURRENT_TIME
  USAGE_RESET_TIME=$(( USAGE_START_TIME + 86400 ))
  TOTAL_TOKENS=0
  LAST_CHECK_TIME=$CURRENT_TIME
  echo "USAGE_START_TIME=$USAGE_START_TIME" > "$USAGE_STATE_FILE"
  echo "USAGE_RESET_TIME=$USAGE_RESET_TIME" >> "$USAGE_STATE_FILE"
  echo "TOTAL_TOKENS=0" >> "$USAGE_STATE_FILE"
  echo "LAST_CHECK_TIME=$CURRENT_TIME" >> "$USAGE_STATE_FILE"
fi

# Calculate session metrics from Claude Code session files
tot_tokens=$TOTAL_TOKENS
tpm=0
session_pct=0
session_txt=""
session_bar=""

# Try to get token data from session files
if [ -n "$session_id" ] && [ "$HAS_JQ" -eq 1 ]; then
  project_dir=$(echo "$current_dir" | sed "s|~|$HOME|g" | sed 's|/|-|g' | sed 's|_|-|g' | sed 's|\.|-|g')
  session_file="$HOME/.claude/projects/${project_dir}/${session_id}.jsonl"
  
  if [ -f "$session_file" ]; then
    # Calculate total tokens from entire session
    input_total=0
    output_total=0
    cache_total=0
    
    # Use faster approach with grep and jq
    # Extract all input tokens and sum them
    input_total=$(grep '"usage"' "$session_file" | jq -r '.message.usage.input_tokens // 0' 2>/dev/null | awk '{sum += $1} END {print sum}')
    output_total=$(grep '"usage"' "$session_file" | jq -r '.message.usage.output_tokens // 0' 2>/dev/null | awk '{sum += $1} END {print sum}')
    cache_total=$(grep '"usage"' "$session_file" | jq -r '.message.usage.cache_read_input_tokens // 0' 2>/dev/null | awk '{sum += $1} END {print sum}')
    
    # Default to 0 if awk returns empty
    [ -z "$input_total" ] && input_total=0
    [ -z "$output_total" ] && output_total=0
    [ -z "$cache_total" ] && cache_total=0
    
    # Calculate session total
    session_total=$(( input_total + output_total + cache_total ))
    
    if [ "$session_total" -gt 0 ]; then
      # Always use session total as it's the most current data
      TOTAL_TOKENS=$session_total
      tot_tokens=$session_total
      
      # Update state file
      sed -i.bak "s/^TOTAL_TOKENS=.*/TOTAL_TOKENS=$TOTAL_TOKENS/" "$USAGE_STATE_FILE"
      rm -f "${USAGE_STATE_FILE}.bak"
      
      # Calculate burn rate based on session file age
      if [ -f "$session_file" ]; then
        session_start_time=$(stat -f%B "$session_file" 2>/dev/null || stat -c%Y "$session_file" 2>/dev/null)
        if [ -n "$session_start_time" ]; then
          duration_minutes=$(( (CURRENT_TIME - session_start_time) / 60 ))
          if [ "$duration_minutes" -gt 0 ]; then
            tpm=$(( tot_tokens / duration_minutes ))
          fi
        fi
      fi
    fi
  fi
fi

# Alternative: Estimate from all recent session files if no session_id
if [ "$tot_tokens" -eq 0 ] && [ "$HAS_JQ" -eq 1 ]; then
  project_dir=$(echo "$current_dir" | sed "s|~|$HOME|g" | sed 's|/|-|g' | sed 's|_|-|g' | sed 's|\.|-|g')
  project_session_dir="$HOME/.claude/projects/${project_dir}"
  
  if [ -d "$project_session_dir" ]; then
    # Sum tokens from recent sessions (last 24 hours)
    for session in $(find "$project_session_dir" -name "*.jsonl" -mtime -1 2>/dev/null); do
      session_tokens=$(tail -50 "$session" | jq -r 'select(.message.usage) | .message.usage | ((.input_tokens // 0) + (.output_tokens // 0) + (.cache_read_input_tokens // 0))' 2>/dev/null | tail -1)
      if [ -n "$session_tokens" ] && [ "$session_tokens" -gt 0 ]; then
        tot_tokens=$(( tot_tokens + session_tokens ))
      fi
    done
    
    # Estimate burn rate from file timestamps
    if [ "$tot_tokens" -gt 0 ]; then
      oldest_session=$(find "$project_session_dir" -name "*.jsonl" -mtime -1 2>/dev/null | head -1)
      if [ -n "$oldest_session" ]; then
        oldest_time=$(stat -f%m "$oldest_session" 2>/dev/null || stat -c%Y "$oldest_session" 2>/dev/null)
        if [ -n "$oldest_time" ]; then
          duration_minutes=$(( (CURRENT_TIME - oldest_time) / 60 ))
          if [ "$duration_minutes" -gt 0 ]; then
            tpm=$(( tot_tokens / duration_minutes ))
          fi
        fi
      fi
    fi
  fi
fi

# Calculate session percentage and time remaining
if [ "$USAGE_RESET_TIME" -gt 0 ]; then
  total_duration=$(( USAGE_RESET_TIME - USAGE_START_TIME ))
  elapsed=$(( CURRENT_TIME - USAGE_START_TIME ))
  session_pct=$(( elapsed * 100 / total_duration ))
  remaining=$(( USAGE_RESET_TIME - CURRENT_TIME ))
  
  if [ "$remaining" -gt 0 ]; then
    rh=$(( remaining / 3600 ))
    rm=$(( (remaining % 3600) / 60 ))
    end_hm=$(fmt_time_hm "$USAGE_RESET_TIME")
    session_txt="$(printf '%dh %dm until reset at %s (%d%%)' "$rh" "$rm" "$end_hm" "$session_pct")"
    session_bar=$(progress_bar "$session_pct" 10)
  else
    session_txt="Reset pending (100%)"
    session_bar="[==========]"
    session_pct=100
  fi
fi

# ---- Context window calculation ----
get_max_context() {
  local model_name="$1"
  case "$model_name" in
    *"Opus"*|*"opus"*)
      echo "200000"
      ;;
    *"Sonnet"*|*"sonnet"*)
      echo "200000"
      ;;
    *"Haiku"*|*"haiku"*)
      echo "200000"
      ;;
    *)
      echo "200000"
      ;;
  esac
}

MAX_CONTEXT=$(get_max_context "$model_name")
context_pct=""
context_display="Auto-managed"
context_remaining_pct=75

# Try to get actual context usage from session
if [ -n "$session_id" ] && [ "$HAS_JQ" -eq 1 ]; then
  project_dir=$(echo "$current_dir" | sed "s|~|$HOME|g" | sed 's|/|-|g' | sed 's|_|-|g' | sed 's|\.|-|g')
  session_file="$HOME/.claude/projects/${project_dir}/${session_id}.jsonl"
  
  if [ -f "$session_file" ]; then
    actual_context_tokens=$(tail -20 "$session_file" | jq -r 'select(.message.usage) | .message.usage | ((.input_tokens // 0) + (.cache_read_input_tokens // 0))' 2>/dev/null | tail -1)
    
    if [ -n "$actual_context_tokens" ] && [ "$actual_context_tokens" -gt 0 ]; then
      context_usage_pct=$(( actual_context_tokens * 100 / MAX_CONTEXT ))
      context_remaining_pct=$(( 100 - context_usage_pct ))
      
      if [ "$context_remaining_pct" -lt 0 ]; then
        context_remaining_pct=0
      elif [ "$context_remaining_pct" -gt 100 ]; then
        context_remaining_pct=100
      fi
      
      context_pct="${context_remaining_pct}%"
      
      # Context status
      if [ "$context_remaining_pct" -le 10 ]; then
        ctx_status="CRITICAL"
        ctx_color() { if [ "$use_color" -eq 1 ]; then printf '\033[38;5;196m'; fi; }
      elif [ "$context_remaining_pct" -le 25 ]; then
        ctx_status="LOW"
        ctx_color() { if [ "$use_color" -eq 1 ]; then printf '\033[38;5;208m'; fi; }
      elif [ "$context_remaining_pct" -le 50 ]; then
        ctx_status="MODERATE"
        ctx_color() { if [ "$use_color" -eq 1 ]; then printf '\033[38;5;220m'; fi; }
      else
        ctx_status="OK"
        ctx_color() { if [ "$use_color" -eq 1 ]; then printf '\033[38;5;46m'; fi; }
      fi
      
      context_display="${context_remaining_pct}% ${ctx_status}"
    else
      ctx_color() { if [ "$use_color" -eq 1 ]; then printf '\033[38;5;158m'; fi; }
    fi
  else
    ctx_color() { if [ "$use_color" -eq 1 ]; then printf '\033[38;5;158m'; fi; }
  fi
else
  ctx_color() { if [ "$use_color" -eq 1 ]; then printf '\033[38;5;158m'; fi; }
fi

# ---- Cost estimation with timeframe ----
cost_display=""
if [ "$tot_tokens" -gt 0 ]; then
  # Estimate cost (Sonnet 4: ~$3 input, ~$15 output per 1M tokens)
  millions=$(( tot_tokens / 1000000 ))
  if [ "$millions" -eq 0 ]; then
    fractional_cost=$(( tot_tokens * 3 / 1000000 ))
    if [ "$fractional_cost" -eq 0 ]; then
      estimated_cost=1
    else
      estimated_cost=$fractional_cost
    fi
  else
    estimated_cost=$(( millions * 3 ))
  fi
  
  # Calculate project timeframe from session files
  timeframe_display=""
  if [ -n "$session_id" ] && [ "$HAS_JQ" -eq 1 ] && [ -f "$session_file" ]; then
    project_session_dir=$(dirname "$session_file")
    if [ -d "$project_session_dir" ]; then
      # Find oldest session file
      oldest_file=$(ls -t "$project_session_dir"/*.jsonl 2>/dev/null | tail -1)
      if [ -f "$oldest_file" ]; then
        oldest_time=$(stat -f%B "$oldest_file" 2>/dev/null || stat -c%Y "$oldest_file" 2>/dev/null)
        current_time=$(date +%s)
        if [ -n "$oldest_time" ]; then
          age_days=$(( (current_time - oldest_time) / 86400 ))
          age_hours=$(( ((current_time - oldest_time) % 86400) / 3600 ))
          
          if [ "$age_days" -gt 0 ]; then
            timeframe_display="/${age_days}d"
          elif [ "$age_hours" -gt 0 ]; then
            timeframe_display="/${age_hours}h"
          else
            timeframe_display="/today"
          fi
        fi
      fi
    fi
  fi
  
  cost_display="💰 ~\$${estimated_cost}${timeframe_display}"
  
  
else
  cost_display="💰 \$0 (initializing)"
fi

# ---- Resource zone calculation ----
api_remaining_pct=$(( 100 - session_pct ))

# API status
if [ "$session_pct" -ge 95 ]; then
  api_limit_status="🚨 API ${api_remaining_pct}% LEFT"
  api_limit_color() { if [ "$use_color" -eq 1 ]; then printf '\033[38;5;196m\033[5m'; fi; }
  api_limit_warning="⚠️ STOP IMMINENT - Save work now!"
elif [ "$session_pct" -ge 90 ]; then
  api_limit_status="⚠️ API ${api_remaining_pct}% LEFT"
  api_limit_color() { if [ "$use_color" -eq 1 ]; then printf '\033[38;5;208m'; fi; }
  api_limit_warning="Will stop soon - Consider pausing"
elif [ "$session_pct" -ge 80 ]; then
  api_limit_status="📉 API ${api_remaining_pct}% LEFT"
  api_limit_color() { if [ "$use_color" -eq 1 ]; then printf '\033[38;5;220m'; fi; }
  api_limit_warning="Monitor usage carefully"
else
  api_limit_status="✅ API ${api_remaining_pct}% LEFT"
  api_limit_color() { if [ "$use_color" -eq 1 ]; then printf '\033[38;5;46m'; fi; }
  api_limit_warning=""
fi

# Resource zone based on API usage
if [ "$session_pct" -ge 95 ]; then
  zone="🔴 CRITICAL"
  zone_color() { if [ "$use_color" -eq 1 ]; then printf '\033[38;5;196m'; fi; }
  threshold_info="Essential ops only"
elif [ "$session_pct" -ge 85 ]; then
  zone="🟠 RED"
  zone_color() { if [ "$use_color" -eq 1 ]; then printf '\033[38;5;208m'; fi; }
  threshold_info="Force efficiency mode"
elif [ "$session_pct" -ge 75 ]; then
  zone="🟡 ORANGE"
  zone_color() { if [ "$use_color" -eq 1 ]; then printf '\033[38;5;220m'; fi; }
  threshold_info="Defer non-critical"
elif [ "$session_pct" -ge 60 ]; then
  zone="🟢 YELLOW"
  zone_color() { if [ "$use_color" -eq 1 ]; then printf '\033[38;5;226m'; fi; }
  threshold_info="Auto-optimization"
else
  zone="🟢 GREEN"
  zone_color() { if [ "$use_color" -eq 1 ]; then printf '\033[38;5;46m'; fi; }
  threshold_info="Full speed"
fi

# Intelligent recommendations
recommendation=""
if [ -n "$api_limit_warning" ]; then
  recommendation="$(api_limit_color)${api_limit_warning}$(rst)"
elif [ "$session_pct" -ge 90 ]; then
  recommendation="🚨 API Critical - Save work, use /pause"
elif [ "$session_pct" -ge 80 ]; then
  recommendation="⚠️ API Low - Use --uc --max-waves 3"
elif [ "$session_pct" -ge 60 ]; then
  recommendation="💡 API Medium - Consider --uc"
elif [ "$context_remaining_pct" -le 10 ]; then
  recommendation="🧠 Context Critical - Will auto-compact soon"
elif [ "$tpm" -gt 450000 ]; then
  recommendation="⚡ High burn - Consider --delegate --uc"
elif [ "$tpm" -gt 300000 ]; then
  recommendation="📈 Moderate burn - Monitor closely"
else
  recommendation="🚀 Optimal - Ready for --wave-mode"
fi

# ---- Render statusline ----
# Line 1: Core info
printf '📁 %s%s%s' "$(dir_color)" "$current_dir" "$(rst)"
[ -n "$git_branch" ] && printf '  🌿 %s%s%s' "$(git_color)" "$git_branch" "$(rst)"
printf '  🤖 %s%s%s' "$(model_color)" "$model_name" "$(rst)"
[ -n "$cc_version" ] && [ "$cc_version" != "null" ] && printf '  📟 v%s' "$cc_version"

# Line 2: Session timing
if [ -n "$session_txt" ]; then
  printf '\n⌛ %s %s' "$session_txt" "$session_bar"
else
  printf '\n⌛ Session data initializing...'
fi

# Line 3: Token analytics
if [ "$tot_tokens" -gt 0 ]; then
  # Format tokens for display (K/M notation for large numbers)
  if [ "$tot_tokens" -gt 1000000 ]; then
    tok_display="$(( tot_tokens / 1000000 ))M"
  elif [ "$tot_tokens" -gt 1000 ]; then
    tok_display="$(( tot_tokens / 1000 ))K"
  else
    tok_display="$tot_tokens"
  fi
  
  printf '\n📊 %s%s tok' "$(usage_color)" "$tok_display"
  [ "$tpm" -gt 0 ] && printf ' (%d/min)' "$tpm"
  printf '%s • 🧠 %sContext: %s%s' "$(rst)" "$(ctx_color)" "$context_display" "$(rst)"
  [ -n "$cost_display" ] && printf ' • %s' "$cost_display"
else
  printf '\n📊 Initializing token tracking...'
fi

# Line 4: Resource monitoring
printf '\n🎯 %s%s%s • %s%s%s' "$(zone_color)" "$zone" "$(rst)" "$(api_limit_color)" "$api_limit_status" "$(rst)"
printf ' • 🌊 Wave:5'
[ -n "$recommendation" ] && printf ' • %s' "$recommendation"

printf '\n'

# ---- Log status ----
{
  echo "[$TIMESTAMP] Status rendered successfully"
  echo "[$TIMESTAMP] Tokens: $tot_tokens, TPM: $tpm, Session: ${session_pct}%"
  echo "[$TIMESTAMP] Zone: $zone, API: ${api_remaining_pct}% remaining"
  echo "[$TIMESTAMP] Recommendation: $recommendation"
} >> "$LOG_FILE" 2>/dev/null