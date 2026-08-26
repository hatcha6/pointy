"""Zip a directory's contents — a stand-in for `zip -qr` on hosts without it.

Used only by the tests, to build a real release bundle for the staging and
download paths. Kept as a file rather than an inline heredoc so the shell around
it stays readable.

    python3 zipdir.py <output.zip> <directory>
"""

import os
import sys
import zipfile

out, root = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w") as archive:
    for base, _dirs, files in os.walk(root):
        for name in files:
            full = os.path.join(base, name)
            archive.write(full, os.path.relpath(full, root))
