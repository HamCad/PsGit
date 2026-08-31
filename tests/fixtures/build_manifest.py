#!/usr/bin/env python3
"""Capture ground-truth facts about a real-git fixture repo into ../manifest.json.
Run with cwd inside the fixture repo itself (e.g. .../basic/repo or .../packed/repo) - the
manifest is written one level UP, beside repo/, not inside the working tree it describes, so it
never shows up as a spurious untracked file when a test reads status against the fixture."""
import json, subprocess, sys, base64

def git(*args):
    return subprocess.run(['git'] + list(args), capture_output=True, check=True).stdout

def git_text(*args):
    return git(*args).decode('utf-8').rstrip('\n')

def main():
    manifest = {}
    manifest['head_sha'] = git_text('rev-parse', 'HEAD')
    manifest['head_branch'] = git_text('symbolic-ref', '--short', 'HEAD')

    log_raw = git_text('log', '--all', '--format=%H|%P|%an|%ae|%ad|%s', '--date=iso-strict')
    commits = []
    for line in log_raw.splitlines():
        h, p, an, ae, ad, s = line.split('|', 5)
        commits.append({
            'sha': h, 'parents': p.split(' ') if p else [], 'author_name': an,
            'author_email': ae, 'date': ad, 'subject': s
        })
    manifest['commits'] = commits

    tree_raw = git_text('ls-tree', '-r', 'HEAD')
    tree = []
    for line in tree_raw.splitlines():
        meta, path = line.split('\t', 1)
        mode, otype, sha = meta.split(' ')
        tree.append({'mode': mode, 'type': otype, 'sha': sha, 'path': path})
    manifest['head_tree'] = tree

    manifest['tracked_files'] = git_text('ls-files').splitlines()

    branches_raw = git_text('for-each-ref', '--format=%(refname:short)|%(objectname)', 'refs/heads')
    manifest['branches'] = [dict(zip(('name', 'sha'), l.split('|'))) for l in branches_raw.splitlines()]

    # exact content (base64) for every blob reachable at HEAD - lets Pester assert byte-exact reads
    blob_content = {}
    for entry in tree:
        if entry['type'] == 'blob':
            content = git(*['cat-file', 'blob', entry['sha']])
            blob_content[entry['sha']] = base64.b64encode(content).decode('ascii')
    manifest['blob_content_b64'] = blob_content

    # pack delta info, if this fixture has a pack (best-effort; ignored if none)
    packs = subprocess.run(['bash', '-c', 'ls .git/objects/pack/*.pack 2>/dev/null'],
                            capture_output=True, text=True).stdout.strip().splitlines()
    if packs:
        with open(packs[0], 'rb') as f:
            pack_bytes = f.read()

        def delta_encoding_at(offset):
            # Re-parse just the object header at `offset` for its type nibble (6 = ofs-delta,
            # 7 = ref-delta) - `git verify-pack -v` reports a base sha/depth for both encodings
            # alike, so this is the only way to tell which one a given delta actually used.
            p = offset
            c = pack_bytes[p]; p += 1
            otype = (c >> 4) & 7
            while c & 0x80:
                c = pack_bytes[p]; p += 1
            return {6: 'ofs-delta', 7: 'ref-delta'}.get(otype, 'unknown')

        vp = git_text('verify-pack', '-v', packs[0])
        delta_objects = []
        non_delta = 0
        for line in vp.splitlines():
            parts = line.split()
            if len(parts) >= 7 and parts[1] in ('commit', 'tree', 'blob', 'tag'):
                sha, otype, offset = parts[0], parts[1], int(parts[4])
                delta_objects.append({
                    'sha': sha, 'type': otype, 'depth': int(parts[5]), 'base': parts[6],
                    'offset': offset, 'encoding': delta_encoding_at(offset)
                })
            elif len(parts) == 5 and parts[1] in ('commit', 'tree', 'blob', 'tag'):
                non_delta += 1
        manifest['pack_delta_objects'] = delta_objects
        manifest['pack_non_delta_count'] = non_delta
        # exact content (base64) for every object involved in a delta chain, keyed by sha,
        # regardless of type (commit/tree/blob) - lets Pester byte-compare delta-resolved output
        delta_content = {}
        for d in delta_objects:
            content = git(*['cat-file', d['type'], d['sha']])
            delta_content[d['sha']] = base64.b64encode(content).decode('ascii')
            base_content = git(*['cat-file', '-t', d['base']])
            btype = base_content.decode().strip()
            base_bytes = git(*['cat-file', btype, d['base']])
            delta_content[d['base']] = base64.b64encode(base_bytes).decode('ascii')
        manifest['pack_delta_content_b64'] = delta_content

    with open('../manifest.json', 'w') as f:
        json.dump(manifest, f, indent=2)
    print(f"wrote ../manifest.json ({len(commits)} commits, {len(tree)} tree entries, "
          f"{len(blob_content)} blobs, packs={len(packs)})")

if __name__ == '__main__':
    main()
