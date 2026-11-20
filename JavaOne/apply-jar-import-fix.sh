#!/bin/bash
set -euo pipefail

PBX="JavaOne.xcodeproj/project.pbxproj"

python3 - "$PBX" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

old = """\\t\\t\\t\\tGENERATE_INFOPLIST_FILE = YES;
\\t\\t\\t\\tINFOPLIST_KEY_CFBundleDisplayName = CoreJ2;"""
new = """\\t\\t\\t\\tGENERATE_INFOPLIST_FILE = NO;
\\t\\t\\t\\tINFOPLIST_FILE = JavaOne/Info.plist;
\\t\\t\\t\\tINFOPLIST_KEY_CFBundleDisplayName = CoreJ2;"""

count = s.count(old)
if count != 2:
    raise SystemExit(f"Expected 2 app-target Info.plist settings, found {count}")

s = s.replace(old, new)

p.write_text(s)
print("Updated JavaOne target Debug/Release Info.plist settings.")
PY

cp "JavaOne/Features/Library/Views/LibraryView.swift" \
   "JavaOne/Features/Library/Views/LibraryView.swift"

cp "JavaOne/Info.plist" "JavaOne/Info.plist"

echo "Done."
