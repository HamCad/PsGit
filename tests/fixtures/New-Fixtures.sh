#!/usr/bin/env bash
# Rebuilds the real-git fixture repos used by PsGit's Pester suite (tests/fixtures/*.zip).
# Requires: git, python3. Run from anywhere; writes into ./out/{basic,packed,refdelta}.
#
# Re-running this WILL produce different commit shas (timestamps aren't pinned), so the
# committed *.zip + manifest.json in tests/fixtures/ are the actual source of truth for the
# test suite - this script exists for reproducibility/reference, not as a test dependency.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/out"
rm -rf "$OUT" && mkdir -p "$OUT"

# ---------------------------------------------------------------- fixture 1: "basic" (loose) --
# repo/ holds the actual git working tree; manifest.json (written below) lands beside it, not
# inside it, so it's never seen as a spurious untracked file by a status check against the fixture.
mkdir -p "$OUT/basic/repo" && cd "$OUT/basic/repo"
git init -q -b main
git config user.name "Fixture Author"
git config user.email "fixture@example.com"
git config commit.gpgsign false

mkdir -p src/lib build
echo "# Basic Fixture" > readme.md
printf 'Write-Host "main"\n' > src/main.ps1
printf 'function Get-Helper { "helper" }\n' > src/lib/helper.ps1
printf '' > src/lib/empty.ps1
printf 'café — unicode test éè emoji 🚀\n' > unicode.txt
python3 -c "
import random
random.seed(7)
with open('logo.bin','wb') as f:
    f.write(bytes(random.randrange(256) for _ in range(256)))
"
git add -A
git commit -q -m "initial commit"

echo "build/" > .gitignore
echo "ignored output" > build/output.txt
printf 'Write-Host "main"\nWrite-Host "v2"\n' > src/main.ps1
echo "a new tracked file" > extra.txt
rm src/lib/empty.ps1
git add -A
git commit -q -m "second commit: modify, add, delete, gitignore"

git branch feature/thing

# --------------------------------------------------------- fixture 2: "packed" (real pack+delta) --
mkdir -p "$OUT/packed/repo" && cd "$OUT/packed/repo"
git init -q -b main
git config user.name "Fixture Author"
git config user.email "fixture@example.com"
git config commit.gpgsign false

python3 -c "
lines = [f'line {i:04d}: the quick brown fox jumps over the lazy dog number {i}' for i in range(300)]
with open('big.txt','w') as f:
    f.write('\n'.join(lines) + '\n')
"
git add -A
git commit -q -m "commit 1: add big.txt"

for i in 1 2 3 4; do
  python3 -c "
import random
random.seed($i)
with open('big.txt') as f:
    lines = f.read().splitlines()
for _ in range(5):
    idx = random.randrange(len(lines))
    lines[idx] = lines[idx] + ' [edit $i]'
with open('big.txt','w') as f:
    f.write('\n'.join(lines) + '\n')
"
  echo "note $i" >> notes.txt
  git add -A
  git commit -q -m "commit $((i+1)): tweak big.txt, append notes"
done

git repack -a -d -q

# ------------------------------------------------------------- fixture 3: "refdelta" (ref-delta) --
# `git repack -a -d` above only ever produces OFS_DELTA locally, so "packed" never exercises the
# REF_DELTA branch of PsGitPackReader.ps1. Build a second, smaller repo and force a genuine
# REF_DELTA the same way a real `git fetch`/`clone` does: pack only what's new in HEAD relative
# to BASE as a *thin* pack (the changed blob deltas against the unavailable-in-this-pack old
# blob by its 20-byte sha, since it has no in-pack offset to reference), then
# `index-pack --fix-thin` completes it into a standalone pack by appending the missing base
# object as a full copy.
mkdir -p "$OUT/refdelta/repo" && cd "$OUT/refdelta/repo"
git init -q -b main
git config user.name "Fixture Author"
git config user.email "fixture@example.com"
git config commit.gpgsign false

python3 -c "
lines = [f'line {i:04d}: the quick brown fox jumps over the lazy dog number {i}' for i in range(300)]
with open('big.txt','w') as f:
    f.write('\n'.join(lines) + '\n')
"
git add -A
git commit -q -m "commit 1: add big.txt"
BASE=$(git rev-parse HEAD)

python3 -c "
import random
random.seed(1)
with open('big.txt') as f:
    lines = f.read().splitlines()
for _ in range(5):
    idx = random.randrange(len(lines))
    lines[idx] = lines[idx] + ' [edit 1]'
with open('big.txt','w') as f:
    f.write('\n'.join(lines) + '\n')
"
echo "note 1" > notes.txt
git add -A
git commit -q -m "commit 2: tweak big.txt, add notes"
HEAD=$(git rev-parse HEAD)

printf '%s\n^%s\n' "$HEAD" "$BASE" | git pack-objects --revs --thin --stdout \
  | git index-pack --stdin --fix-thin >/dev/null
PACK=$(ls .git/objects/pack/*.pack)

# Delete the loose copies of everything that landed in the new pack, so PsGit's reads of them
# are forced through the pack's ref-delta path rather than a loose-object fallback. BASE's own
# commit+tree are left untouched (never packed), so this fixture also exercises the mixed
# loose+pack case of walking history back past the pack boundary.
git verify-pack -v "$PACK" | awk '$2 ~ /^(commit|tree|blob|tag)$/ {print $1}' | while read -r sha; do
  rm -f ".git/objects/${sha:0:2}/${sha:2}"
done

# ------------------------------------------------------------------------------- manifests --
cd "$OUT/basic/repo"    && python3 "$HERE/build_manifest.py"
cd "$OUT/packed/repo"   && python3 "$HERE/build_manifest.py"
cd "$OUT/refdelta/repo" && python3 "$HERE/build_manifest.py"

# ------------------------------------------------------------------------------------- zip --
cd "$HERE"
python3 zip_fixture.py "$OUT/basic"    "$OUT/basic.zip"
python3 zip_fixture.py "$OUT/packed"   "$OUT/packed.zip"
python3 zip_fixture.py "$OUT/refdelta" "$OUT/refdelta.zip"
echo "fixtures rebuilt in $OUT (copy *.zip into tests/fixtures/ to update the committed fixtures)"
