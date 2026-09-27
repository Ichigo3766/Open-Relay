"""Copy a reviewed synthetic screenshot without EXIF/text metadata.

This does not redact pixels. Never pass a screenshot containing private data.
The PNG image bytes are preserved exactly; only ancillary metadata is removed.
"""
import argparse
import struct
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("source", type=Path)
parser.add_argument("destination", type=Path)
args = parser.parse_args()
data = args.source.read_bytes()
assert data[:8] == b"\x89PNG\r\n\x1a\n"
output = bytearray(data[:8])
offset = 8
while offset < len(data):
    length = struct.unpack(">I", data[offset:offset + 4])[0]
    end = offset + length + 12
    assert end <= len(data)
    kind = data[offset + 4:offset + 8]
    if kind not in {b"eXIf", b"iTXt", b"tEXt", b"zTXt", b"tIME"}:
        output.extend(data[offset:end])
    offset = end
args.destination.parent.mkdir(parents=True, exist_ok=True)
args.destination.write_bytes(output)
