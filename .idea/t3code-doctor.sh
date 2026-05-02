#!/bin/zsh

# T3 Code environment doctor.
# Verifies the toolchain expected by this repo:
#   - Node / Bun versions pinned in .mise.toml and package.json engines
#   - mise, git
#   - Provider CLIs (codex, claude) and their auth status
#   - Dependencies installed (node_modules)
#   - Formatter, linter, and type-check health (bun fmt:check, bun lint, bun typecheck)

set -u

RUN_FULL=0
for arg in "$@"; do
  case "$arg" in
    --full) RUN_FULL=1 ;;
  esac
done

PASS=0
WARN=0
FAIL=0

ok()   { print -P "%F{green}[OK]%f   $1"; PASS=$((PASS + 1)); }
warn() { print -P "%F{yellow}[WARN]%f $1"; WARN=$((WARN + 1)); }
fail() { print -P "%F{red}[FAIL]%f $1"; FAIL=$((FAIL + 1)); }
info() { print -P "%F{cyan}[..]%f   $1"; }
hdr()  { print -P "\n%F{magenta}== $1 ==%f"; }

hdr "System"
print "  OS:   $(uname -s) $(uname -r) ($(uname -m))"
print "  Dir:  $(pwd)"

hdr "Bootstrap"

if command -v mise >/dev/null 2>&1; then
  ok "mise installed ($(mise --version))"

  if [[ -f ".mise.toml" ]]; then
    info "trusting .mise.toml …"
    if mise trust >/tmp/t3code-doctor-mise-trust.log 2>&1; then
      ok "mise config trusted"
    else
      warn "mise trust failed — see /tmp/t3code-doctor-mise-trust.log"
    fi

    info "running mise install …"
    if mise install 2>&1 | tee /tmp/t3code-doctor-mise-install.log; then
      ok "mise install complete"
    else
      fail "mise install failed — see /tmp/t3code-doctor-mise-install.log"
    fi
  else
    warn "no .mise.toml at repo root"
  fi
else
  warn "mise not found (optional; used to pin Node/Bun) — install from https://mise.jdx.dev"
fi

if command -v bun >/dev/null 2>&1; then
  info "running bun install …"
  if bun install 2>&1 | tee /tmp/t3code-doctor-bun-install.log; then
    ok "bun install complete"
  else
    fail "bun install failed — see /tmp/t3code-doctor-bun-install.log"
  fi
else
  fail "bun not found — install via mise or https://bun.sh"
fi

hdr "Toolchain versions"

EXPECTED_NODE_MAJOR="24"
if command -v node >/dev/null 2>&1; then
  NODE_V=$(node --version)
  if [[ "$NODE_V" == v${EXPECTED_NODE_MAJOR}.* ]]; then
    ok "node $NODE_V (expected v${EXPECTED_NODE_MAJOR}.x)"
  else
    warn "node $NODE_V (expected v${EXPECTED_NODE_MAJOR}.x per .mise.toml)"
  fi
else
  fail "node not found"
fi

EXPECTED_BUN_MAJOR="1.3"
if command -v bun >/dev/null 2>&1; then
  BUN_V=$(bun --version)
  if [[ "$BUN_V" == ${EXPECTED_BUN_MAJOR}.* ]]; then
    ok "bun $BUN_V (expected ${EXPECTED_BUN_MAJOR}.x)"
  else
    warn "bun $BUN_V (expected ${EXPECTED_BUN_MAJOR}.x per package.json engines)"
  fi
else
  fail "bun not found"
fi

if command -v git >/dev/null 2>&1; then
  ok "git $(git --version | awk '{print $3}')"
else
  fail "git not found"
fi

hdr "Git remotes"

# Project convention: GitHub remotes must use SSH (git@github.com:owner/repo.git),
# not HTTPS. HTTPS pushes prompt for credentials in non-interactive shells
# (IntelliJ run configs, cron, CI-lite scripts) and break silently.
if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
  REMOTES=$(git remote)
  if [[ -z "$REMOTES" ]]; then
    warn "no git remotes configured"
  else
    for remote in ${(f)REMOTES}; do
      url=$(git remote get-url "$remote" 2>/dev/null)
      case "$url" in
        git@github.com:*)
          ok "remote '$remote' uses SSH ($url)"
          ;;
        https://github.com/*)
          owner_repo=${url#https://github.com/}
          owner_repo=${owner_repo%.git}
          warn "remote '$remote' uses HTTPS — switch with:"
          print "         git remote set-url $remote git@github.com:${owner_repo}.git"
          ;;
        *)
          ok "remote '$remote' ($url)"
          ;;
      esac
    done
  fi

  if command -v ssh >/dev/null 2>&1; then
    # ssh -T git@github.com always exits non-zero; match the welcome line instead.
    SSH_OUT=$(ssh -T -o BatchMode=yes -o ConnectTimeout=5 git@github.com 2>&1 || true)
    if print -r -- "$SSH_OUT" | grep -q "successfully authenticated"; then
      ok "ssh to git@github.com works"
    else
      warn "ssh to git@github.com failed — add your key with: ssh-add ~/.ssh/id_ed25519"
    fi
  fi
else
  info "not a git repo — skipping remote checks"
fi

hdr "Provider CLIs"

if command -v codex >/dev/null 2>&1; then
  ok "codex CLI installed ($(codex --version 2>/dev/null | head -1))"
  if [[ -d "$HOME/.codex" ]] || [[ -f "$HOME/.codex/auth.json" ]]; then
    ok "codex appears authenticated (~/.codex present)"
  else
    warn "codex not authenticated — run: codex login"
  fi
else
  warn "codex CLI not found — install from https://github.com/openai/codex"
fi

if command -v claude >/dev/null 2>&1; then
  ok "claude CLI installed ($(claude --version 2>/dev/null | head -1))"
  if [[ -d "$HOME/.claude" ]] || [[ -f "$HOME/.claude/.credentials.json" ]]; then
    ok "claude appears authenticated (~/.claude present)"
  else
    warn "claude not authenticated — run: claude auth login"
  fi
else
  warn "claude CLI not found — install Claude Code first"
fi

hdr "Workspace"

if [[ -d "node_modules" ]]; then
  ok "node_modules present (root)"
else
  fail "node_modules missing — run: bun install"
fi

for pkg in apps/server apps/web apps/desktop packages/contracts packages/shared; do
  if [[ -d "$pkg/node_modules" || -L "$pkg/node_modules" ]]; then
    ok "deps linked: $pkg"
  else
    warn "no node_modules in $pkg (may be fine with workspace hoisting)"
  fi
done

if [[ $RUN_FULL -eq 1 ]]; then
  hdr "Health checks (bun) — --full"

  if [[ -d "node_modules" ]]; then
    info "running bun fmt:check …"
    if bun fmt:check >/tmp/t3code-doctor-fmt.log 2>&1; then
      ok "fmt clean"
    else
      warn "fmt issues — see /tmp/t3code-doctor-fmt.log (fix: bun fmt)"
    fi

    info "running bun lint …"
    if bun lint >/tmp/t3code-doctor-lint.log 2>&1; then
      ok "lint clean"
    else
      warn "lint issues — see /tmp/t3code-doctor-lint.log"
    fi

    info "running bun typecheck …"
    if bun typecheck >/tmp/t3code-doctor-tsc.log 2>&1; then
      ok "typecheck clean"
    else
      fail "typecheck failed — see /tmp/t3code-doctor-tsc.log"
    fi
  else
    warn "skipping fmt/lint/typecheck (install deps first)"
  fi
else
  info "skipping fmt/lint/typecheck (pass --full to run them)"
fi

hdr "Summary"
print -P "  %F{green}pass:%f $PASS   %F{yellow}warn:%f $WARN   %F{red}fail:%f $FAIL"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
