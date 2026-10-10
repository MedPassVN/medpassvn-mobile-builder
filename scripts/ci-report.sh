#!/usr/bin/env bash
# Posts (or updates) one CI status comment on the source PR. Called by the
# `report` job of ci.yml; reads job results and failing-test annotations of the
# current run, so it needs GH_TOKEN with actions:read + checks:read here, and
# COMMENT_TOKEN with pull-requests:write on $SOURCE_REPO.
set -euo pipefail

marker='<!-- medpass-builder-ci -->'
run_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"

jobs=$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/attempts/$GITHUB_RUN_ATTEMPT/jobs?per_page=100" \
  --jq '[.jobs[] | select(.name != "Report") | {name, conclusion, html_url, check_run_url}]')

failed=$(jq -c '[.[] | select(.conclusion != "success" and .conclusion != "skipped")]' <<<"$jobs")
total=$(jq 'length' <<<"$jobs")
n_failed=$(jq 'length' <<<"$failed")

body="$marker"$'\n'
if [ "$n_failed" -eq 0 ]; then
  body+="### ✅ CI passed"$'\n\n'
else
  body+="### ❌ CI failed: $n_failed/$total jobs"$'\n\n'
fi
body+="Commit \`${COMMIT_SHA:0:7}\` · [run]($run_url)"$'\n'

if [ "$n_failed" -gt 0 ]; then
  body+=$'\n'
  while IFS= read -r job; do
    name=$(jq -r '.name' <<<"$job")
    conclusion=$(jq -r '.conclusion // "unknown"' <<<"$job")
    url=$(jq -r '.html_url' <<<"$job")
    body+="**[$name]($url)**: $conclusion"$'\n'
    check_run=$(jq -r '.check_run_url' <<<"$job")
    tests=$(gh api "${check_run#https://api.github.com/}/annotations?per_page=50" \
      --jq '.[] | select(.annotation_level == "failure" and .title == "Test failed") | .message' || true)
    if [ -n "$tests" ]; then
      while IFS= read -r t; do body+="- \`$t\`"$'\n'; done <<<"$tests"
    fi
  done < <(jq -c '.[]' <<<"$failed")
fi

existing=$(GH_TOKEN="$COMMENT_TOKEN" gh api --paginate "repos/$SOURCE_REPO/issues/$PR_NUMBER/comments?per_page=100" \
  --jq ".[] | select(.body | startswith(\"$marker\")) | .id" | tail -n 1)

if [ -n "$existing" ]; then
  GH_TOKEN="$COMMENT_TOKEN" gh api -X PATCH "repos/$SOURCE_REPO/issues/comments/$existing" -f body="$body" >/dev/null
else
  GH_TOKEN="$COMMENT_TOKEN" gh api -X POST "repos/$SOURCE_REPO/issues/$PR_NUMBER/comments" -f body="$body" >/dev/null
fi
echo "Reported to $SOURCE_REPO#$PR_NUMBER."
