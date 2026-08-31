#!/usr/bin/env python3
import sys, zipfile, os

src, dest = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dest, 'w', zipfile.ZIP_DEFLATED) as zf:
    for root, dirs, files in os.walk(src):
        for name in files:
            full = os.path.join(root, name)
            rel = os.path.relpath(full, src)
            zf.write(full, rel)
print(f"wrote {dest}: {sum(1 for _ in zipfile.ZipFile(dest).namelist())} entries")
