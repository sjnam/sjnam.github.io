#!/usr/bin/env bash
#
# deploy.sh — commit, push, and wait until GitHub Pages actually serves it.
#
# Pages rebuilds by itself on every push to main, so this script exists only
# to answer the question "is it live yet?" honestly. It waits for a build
# whose commit is *this* commit — polling the latest build alone is not
# enough, because right after a push the newest build is still the previous
# one, sitting at "built" and looking finished.
#
#   ./deploy.sh -m "message"   commit everything, push, wait, verify
#   ./deploy.sh                nothing to commit: just push (if needed) and verify
#   ./deploy.sh -n             skip committing; push what is already committed
#
set -euo pipefail

SLUG="sjnam/sjnam.github.io"
URL="https://sjnam.github.io/"
BRANCH="main"
FILE="index.html"
TIMEOUT=300           # give up waiting for the build after this many seconds
INTERVAL=8            # seconds between polls

cd "$(dirname "$0")"

msg=""
nocommit=0
while [ $# -gt 0 ]; do
  case "$1" in
    -m|--message)  msg="${2:-}"; shift 2 ;;
    -n|--no-commit) nocommit=1; shift ;;
    -h|--help)
      cat <<'EOF'
deploy.sh — commit, push, and wait until GitHub Pages actually serves it.

  ./deploy.sh -m "message"   commit everything, push, wait, verify
  ./deploy.sh                nothing to commit: just push (if needed) and verify
  ./deploy.sh -n             skip committing; push what is already committed
EOF
      exit 0 ;;
    *) printf 'deploy.sh: unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

command -v gh >/dev/null || { echo "deploy.sh: gh is not installed" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "deploy.sh: gh is not logged in" >&2; exit 1; }

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }

# ── 1. commit ────────────────────────────────────────────────────────────
if [ -n "$(git status --porcelain)" ]; then
  if [ "$nocommit" = 1 ]; then
    say "uncommitted changes left alone (-n)"
  elif [ -z "$msg" ]; then
    echo "deploy.sh: there are uncommitted changes; pass -m \"message\"" >&2
    git status --short >&2
    exit 2
  else
    say "committing"
    git add -A
    git commit -q -m "$msg"
  fi
else
  say "nothing to commit"
fi

# ── 2. push ──────────────────────────────────────────────────────────────
head=$(git rev-parse HEAD)
if [ "$(git rev-parse "origin/$BRANCH" 2>/dev/null || true)" = "$head" ]; then
  say "origin/$BRANCH already at ${head:0:7}"
else
  say "pushing ${head:0:7} to origin/$BRANCH"
  git push -q origin "$BRANCH"
fi

# ── 3. wait for Pages to build *this* commit ─────────────────────────────
say "waiting for the Pages build of ${head:0:7}"
deadline=$(( $(date +%s) + TIMEOUT ))
while :; do
  info=$(gh api "repos/$SLUG/pages/builds/latest" \
           --jq '[.commit, .status, (.error.message // "")] | @tsv' 2>/dev/null || true)
  IFS=$'\t' read -r bcommit bstatus berr <<<"${info:-$'\t\t'}"

  if [ "$bcommit" = "$head" ]; then
    case "$bstatus" in
      built)   say "built"; break ;;
      errored) echo "deploy.sh: Pages build failed: ${berr:-unknown error}" >&2; exit 1 ;;
    esac
  fi

  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "deploy.sh: timed out after ${TIMEOUT}s (latest build: ${bcommit:0:7} ${bstatus:-?})" >&2
    exit 1
  fi
  sleep "$INTERVAL"
done

# ── 4. verify the bytes on the wire match the file on disk ───────────────
# The build being done does not mean the CDN has stopped serving the old
# copy, so compare checksums and give the cache a few seconds to catch up.
say "verifying $URL"
want=$(shasum -a 256 < "$FILE" | cut -d' ' -f1)
for attempt in 1 2 3 4 5; do
  # Pipe straight into shasum: $(curl ...) would strip the trailing newline
  # and never match the file on disk.
  got=$(curl -fsSL --max-time 20 "$URL" | shasum -a 256 | cut -d' ' -f1) || got=""
  if [ "$got" = "$want" ]; then
    say "live and identical to local $FILE"
    exit 0
  fi
  [ "$attempt" -lt 5 ] && sleep 6
done

echo "deploy.sh: built, but $URL still differs from local $FILE" >&2
echo "  (usually a stale CDN copy — try again in a minute, or hard-reload)" >&2
exit 1
