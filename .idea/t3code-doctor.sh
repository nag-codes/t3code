#!/bin/zsh

# T3 Code environment doctor.
# Verifies the toolchain expected by this repo:
#   - Node version pinned in .mise.toml and package.json engines
#   - pnpm (the repo's package manager, declared via package.json "packageManager")
#   - mise, git
#   - Provider CLIs (codex, claude) and their auth status
#   - Dependencies installed (node_modules)
#   - Formatter, linter, and type-check health (pnpm fmt:check, pnpm lint, pnpm typecheck)

set -u
set -o pipefail

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

    # Use the mise-managed Node (per .mise.toml) for the rest of this run, so
    # install + checks match upstream's pinned Node instead of whatever Node is
    # first on PATH (e.g. a Homebrew install shadowing it in IntelliJ's shell).
    if NODE_BIN=$(mise which node 2>/dev/null) && [[ -n "$NODE_BIN" ]]; then
      export PATH="${NODE_BIN:h}:$PATH"
    fi
  else
    warn "no .mise.toml at repo root"
  fi
else
  warn "mise not found (optional; used to pin Node) — install from https://mise.jdx.dev"
fi

# This repo's package manager is pnpm (declared via package.json
# "packageManager"); upstream's CI installs the same lockfile. --frozen-lockfile
# reproduces it exactly and never rewrites pnpm-lock.yaml, so the Doctor can't
# silently drift the lockfile away from upstream.
if command -v pnpm >/dev/null 2>&1; then
  info "running pnpm install --frozen-lockfile …"
  if pnpm install --frozen-lockfile 2>&1 | tee /tmp/t3code-doctor-pnpm-install.log; then
    ok "pnpm install complete"
  else
    fail "pnpm install failed — see /tmp/t3code-doctor-pnpm-install.log"
  fi
else
  fail "pnpm not found — enable it with 'corepack enable pnpm' (honors the packageManager field in package.json) or install via mise"
fi

hdr "Toolchain versions"

EXPECTED_NODE_MAJOR="24"
if command -v node >/dev/null 2>&1; then
  NODE_V=$(node --version)
  if [[ "$NODE_V" == v${EXPECTED_NODE_MAJOR}.* ]]; then
    ok "node $NODE_V (expected v${EXPECTED_NODE_MAJOR}.x)"
  else
    warn "node $NODE_V (expected v${EXPECTED_NODE_MAJOR}.x per .mise.toml)"
    print "         mise provides v${EXPECTED_NODE_MAJOR}.x; make sure this shell uses it (mise activate, or point IntelliJ at the mise shims)"
  fi
else
  fail "node not found"
fi

# The repo declares its pnpm version via package.json "packageManager"
# (e.g. "pnpm@10.24.0"). Compare against that field rather than hardcoding a
# version, so this check automatically tracks whatever upstream pins.
EXPECTED_PNPM=$(grep -oE 'pnpm@[0-9][0-9.]*' package.json 2>/dev/null | head -1 | cut -d'@' -f2)
if command -v pnpm >/dev/null 2>&1; then
  PNPM_V=$(pnpm --version)
  if [[ -z "$EXPECTED_PNPM" ]]; then
    ok "pnpm $PNPM_V"
  elif [[ "$PNPM_V" == "$EXPECTED_PNPM" ]]; then
    ok "pnpm $PNPM_V (matches packageManager pnpm@$EXPECTED_PNPM)"
  else
    warn "pnpm $PNPM_V (package.json pins pnpm@$EXPECTED_PNPM — run 'corepack use pnpm@$EXPECTED_PNPM' to match)"
  fi
else
  fail "pnpm not found"
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
  fail "node_modules missing — run: pnpm install"
fi

for pkg in apps/server apps/web apps/desktop packages/contracts packages/shared; do
  if [[ -d "$pkg/node_modules" || -L "$pkg/node_modules" ]]; then
    ok "deps linked: $pkg"
  else
    warn "no node_modules in $pkg (may be fine with workspace hoisting)"
  fi
done

if [[ $RUN_FULL -eq 1 ]]; then
  hdr "Health checks (pnpm) — --full"

  if [[ -d "node_modules" ]]; then
    info "running pnpm fmt:check …"
    if pnpm fmt:check >/tmp/t3code-doctor-fmt.log 2>&1; then
      ok "fmt clean"
    else
      warn "fmt issues — see /tmp/t3code-doctor-fmt.log (fix: pnpm fmt)"
    fi

    info "running pnpm lint …"
    if pnpm lint >/tmp/t3code-doctor-lint.log 2>&1; then
      ok "lint clean"
    else
      warn "lint issues — see /tmp/t3code-doctor-lint.log"
    fi

    info "running pnpm typecheck …"
    if pnpm typecheck >/tmp/t3code-doctor-tsc.log 2>&1; then
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
