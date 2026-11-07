"""Package rendered PNG representations into the standard ICNS container."""
from pathlib import Path
import struct
import sys
source, target = map(Path, sys.argv[1:])
types = [('icp4', 'icon_16x16.png'), ('icp5', 'icon_32x32.png'),
         ('ic07', 'icon_128x128.png'), ('ic08', 'icon_256x256.png'),
         ('ic09', 'icon_512x512.png'), ('ic10', 'icon_512x512@2x.png')]
chunks = []
for kind, filename in types:
    png = (source / filename).read_bytes()
    assert png.startswith(b'\x89PNG\r\n\x1a\n')
    chunks.append(kind.encode('ascii') + struct.pack('>I', len(png) + 8) + png)
body = b''.join(chunks)
target.write_bytes(b'icns' + struct.pack('>I', len(body) + 8) + body)
