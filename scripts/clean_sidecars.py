#!/usr/bin/env python3
"""Remove only verified AppleDouble sidecars inside the generated bundle."""
import pathlib
import sys
root = pathlib.Path(sys.argv[1]).resolve()
for path in root.rglob('._*'):
    if path.is_file() and not path.is_symlink():
        with path.open('rb') as stream:
            header = stream.read(4)
        if header == b'\x00\x05\x16\x07':
            path.unlink()
