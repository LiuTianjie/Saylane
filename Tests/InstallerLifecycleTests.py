#!/usr/bin/env python3
"""Static contracts for safe install, upgrade, activation, and uninstall flows."""

from __future__ import annotations

import os
from pathlib import Path
import re
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parents[1]
os.environ["TZ"] = "Asia/Shanghai"
if hasattr(time, "tzset"):
    time.tzset()

failures: list[str] = []


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def check(condition: bool, message: str) -> None:
    if not condition:
        failures.append(message)


def swift_function(source: str, name: str) -> str:
    declaration = re.search(rf"\b(?:static\s+)?func\s+{re.escape(name)}\b", source)
    if declaration is None:
        return ""
    opening = source.find("{", declaration.end())
    if opening < 0:
        return ""
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1:index]
    return ""


def shell_function(source: str, name: str) -> str:
    declaration = re.search(rf"(?m)^\s*{re.escape(name)}\s*\(\)\s*\{{", source)
    if declaration is None:
        return ""
    end = re.search(r"(?m)^\s*}\s*$", source[declaration.end():])
    if end is None:
        return ""
    return source[declaration.end():declaration.end() + end.start()]


def active_shell_lines(source: str) -> list[str]:
    return [line.strip() for line in source.splitlines()
            if line.strip() and not line.lstrip().startswith("#")]


def logical_shell(source: str) -> str:
    """Join backslash continuations so one shell command can be inspected as one line."""
    return re.sub(r"\\\n\s*", " ", source)


scripts = [
    "scripts/package.sh",
    "scripts/package-local.sh",
    "scripts/stage-bundles.sh",
    "scripts/pkg/preinstall",
    "scripts/pkg/postinstall",
    "scripts/uninstall.sh",
]
syntax = subprocess.run(
    ["/bin/bash", "-n", *scripts],
    cwd=ROOT,
    env={**os.environ, "TZ": "Asia/Shanghai"},
    capture_output=True,
    text=True,
)
check(syntax.returncode == 0, f"installer shell syntax failed: {syntax.stderr.strip()}")

for path in scripts:
    script = read(path)
    check("set -euo pipefail" in script, f"{path} must fail fast with strict shell options")
    check("export TZ=Asia/Shanghai" in script, f"{path} must force Shanghai time")


# Upgrade safety. Installer replaces each bundle atomically, so nothing may be
# deleted before the payload is in place. And the input method is restarted
# exactly once per install: macOS counts every exit of an input-method process,
# and past ten in half an hour every running application drops it until that
# application is relaunched (docs/DESIGN_0.3.md §0).
preinstall = read("scripts/pkg/preinstall")
pre_lines = active_shell_lines(preinstall)
check(
    not any(re.search(r"(^|[;&|]\s*|\s)(/bin/rm|rm)\s", line) for line in pre_lines),
    "preinstall must not delete anything: a failed payload must leave the previous version intact",
)
check(
    not any("Input Methods" in line for line in pre_lines),
    "preinstall must not stop or touch the input method; postinstall restarts it once",
)
check(
    any("pkill -TERM -f" in line and "$MAIN" in line for line in pre_lines)
    and "MAIN='/Applications/Saylane.app/Contents/MacOS/Saylane'" in preinstall,
    "preinstall must quit the main program by its exact path",
)
check(
    not any(re.search(r"pkill\s+(-\w+\s+)*-x\s", line) for line in pre_lines),
    "preinstall must not stop processes by bare name: both processes of this product could match",
)

postinstall = read("scripts/pkg/postinstall")
post_lines = active_shell_lines(postinstall)
old_pids = postinstall.find("OLD_PIDS=")
register = postinstall.find("--register-input-source")
restart = postinstall.find('for pid in $OLD_PIDS')
launch = postinstall.find("/usr/bin/open")
check(
    0 <= old_pids < register < restart < launch,
    "postinstall must note the running input method, register, restart it, then open the main program",
)
check(
    '"$APP_BIN" --register-input-source' in postinstall,
    "registration must run from the main program's binary, never from the input method's",
)
# Besides the main program, postinstall may restart exactly three programs of
# the system's own — the ones that keep an input method's icon in memory — by
# their exact names. Nothing that could match either of this product's processes.
system_agents = [
    "as_user /usr/bin/killall TextInputMenuAgent 2>/dev/null || true",
    "as_user /usr/bin/killall -KILL TextInputSwitcher CursorUIViewService 2>/dev/null || true",
]
stops = [line for line in post_lines if "pkill" in line or "killall" in line]
check(
    all("$APP_BIN" in line or line in system_agents for line in stops) and all(line in post_lines for line in system_agents),
    "postinstall must stop the input method only by the pids it found before registering",
)
check(
    not any("Saylane" in line or "rtranslate" in line.lower() for line in system_agents),
    "the system agents are named exactly and never match this product",
)
tcc = [line for line in post_lines if "tccutil" in line]
check(
    len(tcc) == 2 and all("reset All com.rtranslate.inputmethod.rtranslate" in line for line in tcc)
    and not any("com.rtranslate.saylane" in line for line in tcc),
    "postinstall removes the grants of the input method's identity only, never the main program's",
)
check(
    0 <= postinstall.find('pkill -TERM -f "^$APP_BIN"') < launch,
    "postinstall must make sure no main program from the previous files is left running before opening it",
)
kill_lines = [line for line in post_lines if re.search(r"/bin/kill\s+-TERM", line)]
check(
    len(kill_lines) == 1 and '"$pid"' in kill_lines[0],
    "postinstall must send exactly one TERM, to a pid that was running the previous version",
)
check(
    "launchctl asuser" in logical_shell(postinstall) and 'as_user /usr/bin/open "$APP" --args --installed' in logical_shell(postinstall),
    "postinstall must open the main program in the console user's session",
)
for script_name, script in (("preinstall", preinstall), ("postinstall", postinstall)):
    check(
        "Contents/MacOS/SaylaneIME" not in script,
        f"{script_name} must never execute the input method's binary",
    )
cleanup = shell_function(postinstall, "cleanup_old_copy")
check(
    "com.rtranslate.saylane" not in cleanup and "Preserved unexpected bundle" in cleanup,
    "legacy cleanup must only remove bundles with the old identifiers",
)
check(
    "cleanup_old_copy '/Applications/Saylane.app'" not in postinstall
    and "cleanup_old_copy '/Library/Input Methods/Saylane.app'" not in postinstall,
    "postinstall must never remove the two bundles it has just installed",
)

components = read("scripts/component-plist.py")
check(
    'component["BundleIsRelocatable"] = False' in components
    and '"Applications/Saylane.app", "Library/Input Methods/Saylane.app"' in components,
    "both bundles must be installed exactly where the package says",
)
for packager in ("scripts/package.sh", "scripts/package-local.sh"):
    check("scripts/component-plist.py" in read(packager), f"{packager} must use the shared component list")
check(
    "--allow-same-version" not in read("scripts/package.sh"),
    "a release package must keep the installer's version check",
)


# Uninstall safety: the app performs the TIS transition while its executable still
# exists, in the console user's bootstrap/session. A failed disable must leave the
# bundle in place so the user can retry. LaunchServices deregistration is user state.
uninstall = read("scripts/uninstall.sh")
uninstall_logical = logical_shell(uninstall)
disable_lines = [line.strip() for line in uninstall_logical.splitlines()
                 if "--disable-input-source" in line and not line.strip().startswith("#")]
check(len(disable_lines) == 1, "uninstall must invoke exactly one input-source disable command")
as_user = uninstall_logical[uninstall_logical.find("as_user()"):]
as_user = as_user[:as_user.find("\n")]
check(
    "launchctl asuser" in as_user and "/usr/bin/sudo" in as_user
    and re.search(r"\s-u\s+\"?\$USER_NAME\"?", as_user) is not None,
    "as_user must run its command in the logged-in console user's session",
)
if disable_lines:
    check(disable_lines[0].startswith("as_user "),
          "uninstall must run input-source disable in the logged-in console user's context")

disable_position = uninstall_logical.find("--disable-input-source")
remove_loop_position = uninstall_logical.find("for path in ", disable_position + 1)
disable_if_end = uninstall_logical.find("\nfi", disable_position + 1)
disable_line_end = uninstall_logical.find("\n", disable_position + 1)
disable_guard_end = disable_if_end if disable_if_end >= 0 else disable_line_end
disable_guard_region = (
    uninstall_logical[disable_position:disable_guard_end]
    if disable_position >= 0 and disable_guard_end > disable_position
    else ""
)
check(
    "||" not in disable_guard_region or "exit 1" in disable_guard_region,
    "uninstall must stop on input-source disable failure instead of warning and deleting the retry binary",
)
between_disable_and_remove = (
    uninstall_logical[disable_position:remove_loop_position]
    if disable_position >= 0 and remove_loop_position > disable_position
    else ""
)
remove_body = logical_shell(shell_function(uninstall, "remove_bundle"))
check(
    "as_user" in remove_body and 0 <= remove_body.find("lsregister") < remove_body.find("/bin/rm"),
    "uninstall must run lsregister -u in the console user's context before each bundle is removed",
)
check(
    0 <= uninstall_logical.find("--disable-input-source") < uninstall_logical.find("stop_matching '")
    < uninstall_logical.find("for path in "),
    "uninstall must leave the input source, then stop both processes, then remove the bundles",
)
check(
    "com.rtranslate.saylane|com.rtranslate.app|com.rtranslate.inputmethod.rtranslate" in remove_body
    and "Refusing unexpected bundle" in remove_body,
    "uninstall must remove only bundles that carry this product's identifiers",
)

input_source = read("Sources/Services/InputSourceInstall.swift")
disable_body = swift_function(input_source, "disableForUninstall")
ascii_helpers = []
for helper in re.findall(r"\bstatic\s+func\s+(\w+)", input_source):
    helper_body = swift_function(input_source, helper)
    if "TISSelectInputSource" in helper_body and (
        "ascii" in helper.lower() or "asciiLayout" in helper_body
    ):
        ascii_helpers.append(helper)
switch_positions = [disable_body.find(f"{helper}(") for helper in ascii_helpers]
switch_position = min((position for position in switch_positions if position >= 0), default=-1)
child_disable = disable_body.find("TISDisableInputSource(mode)")
parent_disable = disable_body.find("TISDisableInputSource(parent)")
check(
    min(switch_position, child_disable, parent_disable) >= 0
    and switch_position < child_disable < parent_disable,
    "uninstall TIS flow must switch to an enabled ASCII layout, then disable the child mode, then the parent",
)
check(
    "TISCopyCurrentASCIICapableKeyboardLayoutInputSource" in input_source,
    "uninstall source transition must use the current enabled ASCII-capable keyboard layout",
)


# Activation must not infer that the child-mode request happened merely because
# the parent happened to become enabled at the requestEnable() return boundary.
permissions = read("Sources/Services/PermissionsController.swift")
check(
    re.search(r"var\s+requestedMode\s*=\s*InputSourceInstall\.parentEnabled", permissions) is None,
    "activation loop must not initialize requestedMode from parentEnabled; that can skip the child-mode request",
)


# Release gates: both version axes of both bundles must match project.yml, both
# bundles must be signed with a stable Developer ID from the expected team, and
# the final PKG must be installer-signed. An unsigned intermediate must never be
# renamed to a final PKG.
package = read("scripts/package.sh")
stage = read("scripts/stage-bundles.sh")
for term in ("CFBundleShortVersionString", "CFBundleVersion", "MARKETING_VERSION", "CURRENT_PROJECT_VERSION",
             "$PROJECT_VERSION", "$PROJECT_BUILD", "SaylaneIME.app", "Saylane.app"):
    check(term in stage, f"staging version gate is missing {term}")
check(
    0 <= stage.find("Version mismatch") < stage.find('rm -rf "$ROOT"'),
    "short and build version mismatches must abort before anything is staged",
)
check(
    "AVFAudio|AVFoundation|Speech" in stage and stage.find("otool -L") < stage.find('if [[ -n "$IDENTITY" ]]'),
    "staging must refuse an input method that links what belongs to the main program, before signing",
)

identity_guard = package.find('[[ -n "$IDENTITY" ]]')
staging_call = package.find("scripts/stage-bundles.sh")
check(
    0 <= identity_guard < staging_call and "exit 1" in package[identity_guard:staging_call],
    "a non-empty application signing identity must be required before anything is signed",
)
for variable in ("INSTALLER", "NOTARY_PROFILE"):
    guard = package.find(f'[[ -n "${variable}" ]]')
    check(0 <= guard < staging_call,
          f"{variable} must be validated before accessing any signing key")
check(
    stage.count("--options runtime --timestamp") >= 4
    and "--entitlements Sources/App/Saylane.entitlements" in stage,
    "both bundles and their native code must be signed with hardened runtime and a timestamp",
)
ime_sign = [line for line in logical_shell(stage).splitlines() if 'codesign --force' in line and line.rstrip().endswith('"$IME"')]
check(
    len(ime_sign) == 1 and "--entitlements" not in ime_sign[0],
    "the input method is signed without entitlements: it asks for nothing",
)
check(
    stage.count("codesign --verify --strict") == 2,
    "both staged bundles must pass strict signature verification",
)
component_step = package.find("scripts/component-plist.py")
team_region = package[staging_call:component_step] if 0 <= staging_call < component_step else ""
check(
    "TeamIdentifier" in team_region and "L95PYLFT86" in team_region and "for STAGED_APP in" in team_region,
    "after signing, package.sh must verify the TeamIdentifier of both bundles before pkgbuild",
)
check(
    "designated => cdhash" in team_region,
    "package.sh must reject an ad-hoc cdhash requirement before pkgbuild",
)

installer_guard = (
    re.search(r"\[\[\s+-n\s+\"\$INSTALLER\"\s+\]\]\s*\|\|[\s\S]{0,240}?\bexit\s+1", package)
    or re.search(r"if\s+\[\[\s+-z\s+\"\$INSTALLER\"\s+\]\];\s*then[\s\S]{0,240}?\bexit\s+1", package)
)
check(
    installer_guard is not None,
    "package.sh must fail when no Developer ID Installer identity is available",
)
check(
    not re.search(r"(?m)^\s*mv\s+\"?\$UNSIGNED\"?\s+\"?\$SIGNED\"?\s*$", package),
    "package.sh must never rename an unsigned intermediate to the final .pkg path",
)
productsign = package.find("productsign --sign")
signature_check = package.find("pkgutil --check-signature")
check(
    0 <= productsign < signature_check,
    "the installer-signed PKG must pass pkgutil --check-signature before success",
)


if failures:
    print(f"FAIL: installer lifecycle contracts ({len(failures)} problem(s))", file=sys.stderr)
    for failure in failures:
        print(f" - {failure}", file=sys.stderr)
    raise SystemExit(1)

print("PASS: installer upgrade, activation, uninstall, version, and signing contracts")
