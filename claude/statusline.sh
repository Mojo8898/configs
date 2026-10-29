#!/usr/bin/env bash
input=$(cat)
get() { jq -r "$1 // empty" <<<"$input"; }

# "5h 24% (3h12m)": percent used, time until reset
limit() {
  local label=$1 pct=$2 reset=$3 left=""
  [ -z "$pct" ] && return
  if [ -n "$reset" ]; then
    local s=$(( reset - $(date +%s) ))
    if (( s > 0 )); then
      local d=$((s/86400)) h=$((s%86400/3600)) m=$((s%3600/60))
      if (( d > 0 )); then left=" (${d}d${h}h)"
      elif (( h > 0 )); then left=" (${h}h${m}m)"
      else left=" (${m}m)"; fi
    fi
  fi
  printf '%s %.0f%%%s' "$label" "$pct" "$left"
}

parts=("$(get '.model.display_name')")
ctx=$(get '.context_window.used_percentage')
[ -n "$ctx" ] && parts+=("ctx $(printf '%.0f' "$ctx")%")
five=$(limit 5h "$(get '.rate_limits.five_hour.used_percentage')" "$(get '.rate_limits.five_hour.resets_at')")
week=$(limit 7d "$(get '.rate_limits.seven_day.used_percentage')" "$(get '.rate_limits.seven_day.resets_at')")
[ -n "$five" ] && parts+=("$five")
[ -n "$week" ] && parts+=("$week")

(IFS='|'; echo "${parts[*]}" | sed 's/|/ | /g')
