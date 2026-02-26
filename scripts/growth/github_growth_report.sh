#!/usr/bin/env bash
set -euo pipefail

OWNER="${1:-mjmkk}"
REPO="${2:-opencodex}"

if ! command -v gh >/dev/null 2>&1; then
  echo "[error] gh CLI is required" >&2
  exit 1
fi

repo_json=$(gh api "repos/${OWNER}/${REPO}")
traffic_views=$(gh api "repos/${OWNER}/${REPO}/traffic/views" 2>/dev/null || echo '{}')
traffic_clones=$(gh api "repos/${OWNER}/${REPO}/traffic/clones" 2>/dev/null || echo '{}')

name=$(echo "$repo_json" | jq -r '.full_name')
stars=$(echo "$repo_json" | jq -r '.stargazers_count')
watchers=$(echo "$repo_json" | jq -r '.subscribers_count')
forks=$(echo "$repo_json" | jq -r '.forks_count')
open_issues=$(echo "$repo_json" | jq -r '.open_issues_count')

views_14=$(echo "$traffic_views" | jq -r '.count // 0')
unique_views_14=$(echo "$traffic_views" | jq -r '.uniques // 0')
clones_14=$(echo "$traffic_clones" | jq -r '.count // 0')
unique_clones_14=$(echo "$traffic_clones" | jq -r '.uniques // 0')

if [ "$unique_views_14" -gt 0 ]; then
  conversion=$(awk -v w="$watchers" -v v="$unique_views_14" 'BEGIN { printf "%.2f", (w / v) * 100 }')
else
  conversion="0.00"
fi

cat <<REPORT
# GitHub Growth Report

Repository: ${name}
Stars: ${stars}
Watchers: ${watchers}
Forks: ${forks}
Open Issues: ${open_issues}

Last 14 Days Traffic
- Views: ${views_14} (unique: ${unique_views_14})
- Clones: ${clones_14} (unique: ${unique_clones_14})

Watch Conversion (Watchers / Unique Views): ${conversion}%
REPORT
