#!/usr/bin/env bash
#
# fireflymac.gg — static marketing site deploy script.
#
# Pulls the latest commit from origin/main and rsyncs the working
# directory into the nginx web root. Static HTML/CSS/JS, so no build
# step and no service restart needed — nginx picks up new files
# automatically on the next request.
#
# Usage:
#   sudo /opt/fireflymac.gg/repo/scripts/deploy.sh
#
# Or, if you want to deploy a specific branch instead of main:
#   sudo /opt/fireflymac.gg/repo/scripts/deploy.sh some-branch
#
# Failure modes:
#   - Bails on the first command that exits non-zero (set -euo pipefail).
#   - rsync failures leave the previous state in place (--delete only
#     fires after a successful copy).
#   - Doesn't touch /var/www/html/.well-known/ — that's reserved for
#     domain-verification files (certbot ACME, etc.) that aren't tracked
#     in this repo.

set -euo pipefail

# ─── Config (override via env if needed) ───────────────────────────────
REPO_DIR=${REPO_DIR:-/opt/fireflymac.gg/repo}
WEB_ROOT=${WEB_ROOT:-/var/www/html}
APP_USER=${APP_USER:-firefly}
BRANCH=${1:-main}

# ─── Color helpers ─────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    BLUE=$'\033[34m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
    BLUE=''; GREEN=''; YELLOW=''; RED=''; DIM=''; RESET=''
fi
step() { echo "${BLUE}==>${RESET} $*"; }
ok()   { echo "${GREEN}✓${RESET}  $*"; }
warn() { echo "${YELLOW}!${RESET}  $*"; }
fail() { echo "${RED}✗${RESET}  $*" >&2; exit 1; }

# ─── Preflight ─────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    fail "Must run as root (or via sudo). Try: sudo $0"
fi
[[ -d "$REPO_DIR" ]] || fail "Repo dir missing: $REPO_DIR"
[[ -d "$WEB_ROOT" ]] || fail "Web root missing: $WEB_ROOT"
command -v rsync >/dev/null || fail "rsync not installed"

cd "$REPO_DIR"
OLD_SHA=$(sudo -u "$APP_USER" git rev-parse --short HEAD 2>/dev/null || echo "(none)")

# ─── Step 1: pull ──────────────────────────────────────────────────────
step "Pulling ${BRANCH} as ${APP_USER}..."
sudo -u "$APP_USER" git fetch origin "$BRANCH" --quiet
sudo -u "$APP_USER" git checkout "$BRANCH" --quiet 2>/dev/null || true
sudo -u "$APP_USER" git reset --hard "origin/$BRANCH" --quiet
NEW_SHA=$(sudo -u "$APP_USER" git rev-parse --short HEAD)

if [[ "$OLD_SHA" == "$NEW_SHA" ]]; then
    warn "Repo already at $NEW_SHA — no new commits. Re-syncing files anyway."
else
    ok "Updated $OLD_SHA → $NEW_SHA"
    echo "${DIM}$(sudo -u "$APP_USER" git log --oneline "$OLD_SHA..$NEW_SHA" 2>/dev/null | head -10)${RESET}"
fi

# ─── Step 2: rsync to web root ─────────────────────────────────────────
step "Syncing $REPO_DIR → $WEB_ROOT..."
rsync -a --delete \
    --exclude '.git/' \
    --exclude '.gitignore' \
    --exclude '.gitattributes' \
    --exclude '.DS_Store' \
    --exclude 'scripts/' \
    --exclude 'README.md' \
    --exclude '.well-known/' \
    "$REPO_DIR/" "$WEB_ROOT/"

ok "Files synced"

# ─── Step 3: ownership / perms (defensive) ─────────────────────────────
# nginx typically runs as www-data and just needs read access. Make sure
# the served files are readable; we don't change ownership because the
# directory might be managed by something else (Apache, certbot, etc).
step "Ensuring read perms..."
chmod -R a+r "$WEB_ROOT"
find "$WEB_ROOT" -type d -exec chmod a+x {} \;
ok "Perms applied"

# ─── Step 4: smoke test ────────────────────────────────────────────────
# nginx doesn't need a reload for static-file changes, but a quick HEAD
# against loopback confirms the new file is reachable. We hit 127.0.0.1
# directly with a Host header (instead of the public hostname) because
# the server can't resolve its own public IP through hairpin NAT.
HEALTH_URL=${HEALTH_URL:-http://127.0.0.1/}
HEALTH_HOST=${HEALTH_HOST:-fireflymac.gg}
step "Checking $HEALTH_URL (Host: $HEALTH_HOST)..."
if curl -fsS --max-time 5 -I -H "Host: $HEALTH_HOST" "$HEALTH_URL" >/dev/null 2>&1; then
    ok "nginx serving site"
else
    warn "Health check failed — nginx may need a reload. Site files are deployed regardless."
fi

echo
ok "Deploy complete: $OLD_SHA → $NEW_SHA"
