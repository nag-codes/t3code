#!/bin/zsh

set -e

RELEASE_DIR="release"
BEDROCK_BRANCH="feat/claude-bedrock-model-override"

# Trust the project's .mise.toml so non-interactive IDE shells don't block.
if command -v mise >/dev/null 2>&1; then
  mise trust --quiet 2>/dev/null || true
fi

# ── Flavor selection ──────────────────────────────────────────────────
echo
echo "Build flavor?"
echo "  [1] Bedrock"
echo "  [2] Vanilla"
echo
printf "Choice [1/2]: "
read -r flavor_input

case "${flavor_input}" in
  1|bedrock|Bedrock|BEDROCK) flavor="bedrock" ;;
  2|vanilla|Vanilla|VANILLA) flavor="vanilla" ;;
  *)
    echo "Invalid choice: '${flavor_input}'. Aborting." >&2
    exit 1
    ;;
esac

current_branch=$(git rev-parse --abbrev-ref HEAD)

# ── Pre-flight checks ─────────────────────────────────────────────────
if [ "${flavor}" = "bedrock" ]; then
  if [ "${current_branch}" != "${BEDROCK_BRANCH}" ]; then
    cat <<EOF >&2

✗ Bedrock build requires the '${BEDROCK_BRANCH}' branch (currently on '${current_branch}').
  The wrap that activates Bedrock at runtime only exists on that branch.

  Switch with:
    git checkout ${BEDROCK_BRANCH}

EOF
    exit 1
  fi

  if [ -z "${CLAUDE_CODE_USE_BEDROCK}" ]; then
    cat <<'EOF' >&2

✗ CLAUDE_CODE_USE_BEDROCK is not set in this shell.

  The dmg will build, but Bedrock won't activate at runtime unless the
  launching process has this env var. Persist it before re-running:

  • Shell launches (terminal `open`, direct binary invocation):
      echo 'export CLAUDE_CODE_USE_BEDROCK=1' >> ~/.zshrc
      exec zsh

  • Finder / Dock launches (GUI):
      launchctl setenv CLAUDE_CODE_USE_BEDROCK 1
      # For persistence across reboots, install a LaunchAgent .plist.

  Then verify with `echo $CLAUDE_CODE_USE_BEDROCK` in a fresh shell and
  re-run this build.

EOF
    exit 1
  fi

  echo "→ Bedrock flavor on '${current_branch}'. Env var present. Proceeding."
else
  # Vanilla flavor: no branch enforcement.
  # The Bedrock wrap on feat/... is a pure passthrough when
  # CLAUDE_CODE_USE_BEDROCK is unset, so a feat-built dmg with no env
  # behaves byte-for-byte like a main-built dmg.
  echo "→ Vanilla flavor on '${current_branch}'. Proceeding."
fi

# ── Build ─────────────────────────────────────────────────────────────
echo
echo "Installing dependencies..."
bun install

echo "Cleaning ${RELEASE_DIR} folder..."
rm -rf "${RELEASE_DIR}"

echo "Building Mac ARM64 (M1) DMG..."
bun run dist:desktop:dmg:arm64

echo "Build complete. Artifacts in ${RELEASE_DIR}/"

DMG_FILE=$(find "${RELEASE_DIR}" -name "*.dmg" -type f | head -1)
if [ -n "${DMG_FILE}" ]; then
  echo "Opening ${DMG_FILE}..."
  open "${DMG_FILE}"
else
  echo "No .dmg file found in ${RELEASE_DIR}/"
fi
