#!/bin/zsh

set -e

REPO="nag-codes/t3code"
WORKFLOW="sync-upstream.yml"
REF="main"

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: gh CLI is not installed (brew install gh)." >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: gh is not authenticated." >&2
  echo "       Run 'gh auth login' (needs 'workflow' scope) and try again." >&2
  exit 1
fi

if ! gh auth status 2>&1 | grep -q "workflow"; then
  echo "ERROR: gh token is missing the 'workflow' scope." >&2
  echo "       Run 'gh auth refresh -s workflow' and try again." >&2
  exit 1
fi

DISPATCH_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "Triggering workflow '${WORKFLOW}' on ${REPO}@${REF}..."
gh workflow run "${WORKFLOW}" --repo "${REPO}" --ref "${REF}"

# Poll until the dispatched run registers (up to ~16s). Filter by
# event=workflow_dispatch and createdAt to avoid grabbing a
# push-triggered run that happened to land first.
RUN_ID=""
for _ in 1 2 3 4 5 6 7 8; do
  sleep 2
  RUN_ID=$(gh run list --workflow="${WORKFLOW}" --repo "${REPO}" \
    --event workflow_dispatch --limit 1 \
    --json databaseId,createdAt \
    --jq ".[] | select(.createdAt >= \"${DISPATCH_TIME}\") | .databaseId")
  [[ -n "${RUN_ID}" ]] && break
done

echo
echo "Latest runs:"
gh run list --workflow="${WORKFLOW}" --repo "${REPO}" --limit 3

if [[ -z "${RUN_ID}" ]]; then
  echo
  echo "WARNING: dispatched run did not register within ~16s." >&2
  echo "         Check 'gh run list --repo ${REPO}' manually." >&2
  exit 0
fi

RUN_URL=$(gh run view "${RUN_ID}" --repo "${REPO}" --json url --jq .url)
echo
echo "Watching run ${RUN_ID}: ${RUN_URL}"
echo "(Ctrl+C to detach; the workflow keeps running.)"
gh run watch "${RUN_ID}" --repo "${REPO}" --exit-status
