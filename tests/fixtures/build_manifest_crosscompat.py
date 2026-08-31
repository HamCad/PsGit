#!/usr/bin/env python3
"""Capture ground-truth facts about the crosscompat fixture repo into ../manifest.json.
Run with cwd inside the fixture repo itself (see New-CrossCompatFixture.sh) - the manifest is
written one level UP, beside repo/, not inside the working tree it describes, matching
build_manifest.py's convention (see that file for why).

Standalone rather than importing build_manifest.py: this fixture's extra sections (case-clash,
backslash-path, reserved-names, gitlink, packed-refs) don't apply to the other three fixtures,
and keeping this file self-contained means rebuilding it can't accidentally change what basic/
packed/refdelta assert against."""
import json, subprocess, sys, base64, os

def git(*args):
    return subprocess.run(['git'] + list(args), capture_output=True, check=True).stdout

def git_text(*args):
    return git(*args).decode('utf-8').rstrip('\n')

def ls_tree_raw(treeish):
    """git ls-tree -r -z: recursive (so a gitlink/file nested under a real subdirectory, like
    vendor/thing or sub/lpt1.log, still shows up with its full path) and NUL-separated/UNQUOTED
    (required for paths containing bytes - like a literal backslash - that git's normal
    quoted-path output would otherwise escape, corrupting exactly the byte sequence under test).
    -r does not descend into a gitlink (mode 160000) itself - it has no tree of its own in this
    repo's object store - so it still comes back as a single flat entry, which is the point."""
    raw = git('ls-tree', '-r', '-z', treeish)
    entries = []
    for chunk in raw.split(b'\x00'):
        if not chunk:
            continue
        meta, path = chunk.split(b'\t', 1)
        mode, otype, sha = meta.decode('ascii').split(' ')
        entries.append({'mode': mode, 'type': otype, 'sha': sha, 'path': path.decode('utf-8')})
    return entries

def blob_map(entries):
    out = {}
    for e in entries:
        if e['type'] == 'blob':
            out[e['sha']] = base64.b64encode(git('cat-file', 'blob', e['sha'])).decode('ascii')
    return out

def main():
    manifest = {}
    manifest['head_sha'] = git_text('rev-parse', 'HEAD')
    manifest['head_branch'] = git_text('symbolic-ref', '--short', 'HEAD')

    log_raw = git_text('log', '--all', '--format=%H|%P|%an|%ae|%ad|%s', '--date=iso-strict')
    commits = []
    for line in log_raw.splitlines():
        h, p, an, ae, ad, s = line.split('|', 5)
        commits.append({'sha': h, 'parents': p.split(' ') if p else [], 'author_name': an,
                         'author_email': ae, 'date': ad, 'subject': s})
    manifest['commits'] = commits

    head_tree = ls_tree_raw('HEAD')
    manifest['head_tree'] = head_tree
    manifest['tracked_files'] = git_text('ls-files').splitlines()
    manifest['blob_content_b64'] = blob_map(head_tree)

    branches_raw = git_text('for-each-ref', '--format=%(refname:short)|%(objectname)', 'refs/heads')
    manifest['branches'] = [dict(zip(('name', 'sha'), l.split('|'))) for l in branches_raw.splitlines()]

    # zero loose refs/heads/* files must remain after `git pack-refs --all` - New-CrossCompatFixture.sh
    # already asserts this at build time; re-derive it here too so the manifest is self-describing
    # for whoever reads it later without having to re-run the build script to know why it matters.
    loose_head_refs = []
    for root, _dirs, files in os.walk('.git/refs/heads'):
        for f in files:
            loose_head_refs.append(os.path.relpath(os.path.join(root, f), '.git/refs/heads'))
    manifest['packed_refs_only'] = (len(loose_head_refs) == 0)

    # --- tree sort-order collision: explicit, so the Pester test doesn't have to re-derive
    # "which three head_tree entries are the interesting ones" from the general list.
    manifest['tree_sort_paths'] = ['lib-old.txt', 'lib.txt', 'lib/inner.txt']

    # --- gitlink (submodule) entry: explicit pointer, though it's also present in head_tree
    # (as a type=='commit' entry, which blob_content_b64 correctly skips - a gitlink id is a
    # commit sha in a DIFFERENT repo's object store, not a blob in this one).
    gitlink = [e for e in head_tree if e['type'] == 'commit']
    if len(gitlink) != 1 or gitlink[0]['path'] != 'vendor/thing':
        raise RuntimeError(f"expected exactly one gitlink entry at vendor/thing, got: {gitlink}")
    manifest['gitlink'] = {'path': gitlink[0]['path'], 'sha': gitlink[0]['sha'], 'mode': gitlink[0]['mode']}

    # --- history-only branches: each one's commit/tree/entries/blob content, read purely from
    # the object graph (see New-CrossCompatFixture.sh for why none of these are ever checked out).
    def history_section(branch):
        commit_sha = git_text('rev-parse', f'refs/heads/{branch}')
        tree_sha = git_text('rev-parse', f'{commit_sha}^{{tree}}')
        entries = ls_tree_raw(tree_sha)
        return {'commit': commit_sha, 'tree': tree_sha, 'entries': entries, 'blob_content_b64': blob_map(entries)}

    manifest['case_clash'] = history_section('history/case-clash')
    manifest['backslash_path'] = history_section('history/backslash-path')
    manifest['reserved_names'] = history_section('history/reserved-names')

    with open('../manifest.json', 'w') as f:
        json.dump(manifest, f, indent=2)
    print(f"wrote ../manifest.json ({len(commits)} commits, {len(head_tree)} head_tree entries, "
          f"packed_refs_only={manifest['packed_refs_only']})")

if __name__ == '__main__':
    main()
