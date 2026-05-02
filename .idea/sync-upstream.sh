#!/bin/zsh

set -e

REPO="ImNag/t3code"
WORKFLOW="sync-upstream.yml"
REF="main"

# Ensure GH_TOKEN is available. If the 1Password-backed wrapper from
# ~/.dotfiles/zsh/tools/gh.zsh hasn't exported it into this environment
# (e.g. IntelliJ launched a non-interactive shell), fetch directly.
if [[ -z "$GH_TOKEN" ]] && command -v op >/dev/null 2>&1; then
  GH_TOKEN="$(op read 'op://Private/ImNag - GitHub PAT/credential' 2>/dev/null)"
  export GH_TOKEN
fi

if [[ -z "$GH_TOKEN" ]]; then
  echo "ERROR: GH_TOKEN not set and 'op' CLI unavailable." >&2
  echo "       Install 1Password CLI (brew install --cask 1password-cli)" >&2
  echo "       or run from a terminal where GH_TOKEN is already exported." >&2
  exit 1
fi

echo "Triggering workflow '${WORKFLOW}' on ${REPO}@${REF}..."
gh workflow run "${WORKFLOW}" --repo "${REPO}" --ref "${REF}"

# GitHub takes a moment to register the dispatched run before it shows up.
sleep 3

echo
echo "Latest runs:"
gh run list --workflow="${WORKFLOW}" --repo "${REPO}" --limit 3

RUN_ID=$(gh run list --workflow="${WORKFLOW}" --repo "${REPO}" --limit 1 --json databaseId --jq '.[0].databaseId')
if [[ -n "${RUN_ID}" ]]; then
  echo
  echo "Watching run ${RUN_ID} (Ctrl+C to detach; the workflow keeps running)..."
  gh run watch "${RUN_ID}" --repo "${REPO}" --exit-status
fi
