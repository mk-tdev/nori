"""Package the generated PNG resolutions into the macOS ICNS container."""
from pathlib import Path
import struct
import sys

source, destination = map(Path, sys.argv[1:])
representations = {
    "icp4": "16x16", "icp5": "32x32", "ic07": "128x128",
    "ic08": "256x256", "ic09": "512x512", "ic10": "512x512@2x",
    "ic11": "16x16@2x", "ic12": "32x32@2x",
    "ic13": "128x128@2x", "ic14": "256x256@2x",
}
chunks = []
for kind, resolution in representations.items():
    png = (source / f"icon_{resolution}.png").read_bytes()
    if not png.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError(f"Invalid PNG: {resolution}")
    chunks.append(kind.encode("ascii") + struct.pack(">I", len(png) + 8) + png)
body = b"".join(chunks)
destination.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
