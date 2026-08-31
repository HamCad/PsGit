#!/usr/bin/env bash
# Rebuilds tests/fixtures/crosscompat.zip - a real-git repo built specifically to probe git
# edge cases PsGit's existing fixtures (basic/packed/refdelta) never exercise: PowerShell
# hashtable case-insensitivity colliding git's case-sensitive paths, a literal backslash byte in
# a path, filenames matching Windows reserved device names, a real tree-entry sort-order
# collision (directory vs. file name prefix), a submodule/gitlink (mode 160000) entry, and
# branches resolvable only through packed-refs (no loose ref files at all).
#
# Independent of New-Fixtures.sh by design - that script and its committed *.zip/manifest.json
# stay untouched. Requires: git, python3. Run from anywhere; writes into ./out-crosscompat/.
#
# Re-running this WILL produce different commit shas (timestamps aren't pinned), so the committed
# crosscompat.zip + manifest.json in tests/fixtures/ are the actual source of truth for the test
# suite - this script exists for reproducibility/reference, not as a test dependency.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/out-crosscompat"
rm -rf "$OUT" && mkdir -p "$OUT"

# ------------------------------------------------------------- inner repo: submodule target --
# A tiny standalone repo whose HEAD commit becomes the gitlink target below. Never touched again;
# its own history/object store is irrelevant - only its HEAD commit sha matters, exactly like a
# real `git submodule add` records a commit id from another repo without embedding its objects.
mkdir -p "$OUT/_inner" && cd "$OUT/_inner"
git init -q -b main
git config user.name "Inner Author"
git config user.email "inner@example.com"
git config commit.gpgsign false
echo "inner submodule content" > inner.txt
git add -A
git commit -q -m "inner repo initial commit"
INNER_SHA=$(git rev-parse HEAD)

# ---------------------------------------------------------------------------- main repo -------
mkdir -p "$OUT/crosscompat/repo" && cd "$OUT/crosscompat/repo"
git init -q -b main
git config user.name "Fixture Author"
git config user.email "fixture@example.com"
git config commit.gpgsign false

# --- commit 1: baseline (root, shared as the parent of every branch below) ---
echo "# Crosscompat Fixture" > readme.md
git add -A
git commit -q -m "commit 1: baseline"
ROOT=$(git rev-parse HEAD)

# --- commit 2: a real tree-entry sort-order collision, checked out at HEAD -----------------
# Git sorts tree entries as if every directory name carried a trailing '/' for comparison
# purposes. Naive lexicographic sort of the bare names would order 'lib' before 'lib-old.txt'
# before 'lib.txt' (shorter-prefix-first). Git's actual order compares 'lib/' against the file
# names byte-for-byte: '-' (0x2D) < '.' (0x2E) < '/' (0x2F), so the real order is
# lib-old.txt, lib.txt, lib/ - the bare directory name sorts LAST, not first. A naive
# reimplementation that sorts directories by their bare name gets this backwards.
mkdir -p lib
echo "lib dir file" > lib/inner.txt
echo "lib.txt file" > lib.txt
echo "lib-old.txt file" > lib-old.txt
git add -A
git commit -q -m "commit 2: tree sort-order collision (lib-old.txt, lib.txt, lib/ dir)"

# --- commit 3: a submodule/gitlink entry (mode 160000), checked out at HEAD ----------------
# No .gitmodules is written on purpose - the minimal repro of the tree-entry-mode issue is just
# the mode 160000 entry itself; PsGit doesn't parse .gitmodules and none of the scenarios below
# need it to. vendor/thing is never created on disk (an uninitialized submodule has no working
# files), so this is safe to check out on any OS/filesystem - nothing to extract.
git update-index --add --cacheinfo 160000 "$INNER_SHA" vendor/thing
git commit -q -m "commit 4: add submodule/gitlink reference vendor/thing (uninitialized)"
HEAD_SHA=$(git rev-parse HEAD)

# ------------------------------------------------------- history-only branches (plumbing) -----
# Every branch below is built entirely with plumbing against a throwaway scratch index - the
# real working directory and its normal .git/index are never touched, so none of these paths
# are ever materialized as actual files and there is nothing risky to check out or extract.
# They exist purely as commits reachable by ref/sha, read only through the git object graph
# (Expand-PsGitTree / Get-PsGitObject), never through a physical working-tree checkout.
SCRATCH_IDX="$OUT/scratch.index"
export GIT_INDEX_FILE="$SCRATCH_IDX"

# history/case-clash: two paths differing only by case, coexisting in one tree - perfectly
# legal git data (ext4 is case-sensitive) that a case-insensitive PowerShell hashtable keyed by
# path can silently collide on.
rm -f "$SCRATCH_IDX"
UPPER_SHA=$(printf 'UPPER-CASE content\n' | git hash-object -w --stdin)
LOWER_SHA=$(printf 'lower-case content\n' | git hash-object -w --stdin)
git update-index --add --cacheinfo 100644 "$UPPER_SHA" Config.txt
git update-index --add --cacheinfo 100644 "$LOWER_SHA" config.txt
TREE_CC=$(git write-tree)
COMMIT_CC=$(git commit-tree "$TREE_CC" -p "$ROOT" -m "history/case-clash: Config.txt + config.txt coexist (object-graph only, never checked out)")
git update-ref refs/heads/history/case-clash "$COMMIT_CC"

# history/backslash-path: a filename containing a literal backslash byte - legal on Linux/git,
# forbidden as a path separator's escape hatch on Windows; PsGit's own path-safety check
# (Assert-PsGitSafeTreePath, added for Gitea #6/#7) is supposed to reject it.
rm -f "$SCRATCH_IDX"
BS_SHA=$(printf 'backslash path content\n' | git hash-object -w --stdin)
git update-index --add --cacheinfo 100644 "$BS_SHA" 'weird\name.txt'
TREE_BS=$(git write-tree)
COMMIT_BS=$(git commit-tree "$TREE_BS" -p "$ROOT" -m "history/backslash-path: filename containing a literal backslash byte (object-graph only)")
git update-ref refs/heads/history/backslash-path "$COMMIT_BS"

# history/reserved-names: paths matching Windows reserved device names - ordinary files on
# Linux, hazardous on Windows (see Gitea #14, which fixed this class of bug for REF names only).
rm -f "$SCRATCH_IDX"
CON_SHA=$(printf 'con device content\n' | git hash-object -w --stdin)
NUL_SHA=$(printf 'nul device content\n' | git hash-object -w --stdin)
LPT_SHA=$(printf 'lpt1 device content\n' | git hash-object -w --stdin)
git update-index --add --cacheinfo 100644 "$CON_SHA" con
git update-index --add --cacheinfo 100644 "$NUL_SHA" nul.txt
git update-index --add --cacheinfo 100644 "$LPT_SHA" sub/lpt1.log
TREE_DN=$(git write-tree)
COMMIT_DN=$(git commit-tree "$TREE_DN" -p "$ROOT" -m "history/reserved-names: con, nul.txt, sub/lpt1.log (object-graph only)")
git update-ref refs/heads/history/reserved-names "$COMMIT_DN"

unset GIT_INDEX_FILE
rm -f "$SCRATCH_IDX"

# ------------------------------------------------------------------------- pack the refs -----
# Packs every branch (main + the three history/* branches) into .git/packed-refs and removes
# the loose refs/heads/* files entirely, so Get-PsGitRef/Get-PsGitBranch are forced through the
# packed-refs parsing path with zero loose-ref fallback available - a real-git-produced
# packed-refs file (with its '# pack-refs with:' header line), not a hand-guessed format.
git pack-refs --all
if [ -n "$(find .git/refs/heads -type f 2>/dev/null)" ]; then
  echo "expected zero loose refs/heads/* files after pack-refs --all" >&2
  find .git/refs/heads -type f >&2
  exit 1
fi

# ------------------------------------------------------------------------------- manifest -----
python3 "$HERE/build_manifest_crosscompat.py"

# ------------------------------------------------------------------------------------- zip -----
cd "$HERE"
python3 zip_fixture.py "$OUT/crosscompat" "$OUT/crosscompat.zip"
echo "fixture rebuilt in $OUT (copy crosscompat.zip into tests/fixtures/ to update the committed fixture)"
