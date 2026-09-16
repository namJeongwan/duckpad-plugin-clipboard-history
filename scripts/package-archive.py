#!/usr/bin/env python3
"""Create an immutable catalog ZIP from an already signed flat plugin package."""
import hashlib
import pathlib
import sys
import zipfile

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
if source.suffix != ".duckpad-plugin" or source.is_symlink() or not source.is_dir():
    raise SystemExit("Expected a signed .duckpad-plugin directory")
files = sorted(source.iterdir())
if len(files) > 64 or any(p.is_symlink() or not p.is_file() for p in files):
    raise SystemExit("Package must contain at most 64 regular files")
if not {"plugin.json", "module.dylib", "SHA256SUMS", "SIGNATURE.ed25519"}.issubset(p.name for p in files):
    raise SystemExit("Missing signed package files")
with destination.open("xb") as output:
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for file in files:
            info = zipfile.ZipInfo(file.name, (1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, file.read_bytes())
print(f"{hashlib.sha256(destination.read_bytes()).hexdigest()}  {destination.name}")
