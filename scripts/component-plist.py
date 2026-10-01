#!/usr/bin/env python3
"""Write the installer's component list for a staged root.

Both bundles are installed exactly where the package says: a relocatable
bundle would follow any other copy with the same identifier, for example a
build directory. `--allow-same-version` lets a test package replace an
installed build with the same version number.
"""
import plistlib
import subprocess
import sys

root, output = sys.argv[1], sys.argv[2]
allow_same = "--allow-same-version" in sys.argv[3:]
subprocess.run(["pkgbuild", "--analyze", "--root", root, output], check=True, capture_output=True)
with open(output, "rb") as handle:
    components = plistlib.load(handle)
paths = sorted(component["RootRelativeBundlePath"] for component in components)
expected = ["Applications/Saylane.app", "Library/Input Methods/Saylane.app"]
if paths != expected:
    sys.exit(f"unexpected bundles in package root: {paths}")
for component in components:
    component["BundleIsRelocatable"] = False
    component["BundleHasStrictIdentifier"] = True
    component["BundleOverwriteAction"] = "upgrade"
    if allow_same:
        component["BundleIsVersionChecked"] = False
with open(output, "wb") as handle:
    plistlib.dump(components, handle)
