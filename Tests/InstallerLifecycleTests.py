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


# Upgrade safety: Installer must atomically replace the live payload. The preinstall
# script may remove legacy/user copies, but must never pre-delete the system Saylane.
preinstall = read("scripts/pkg/preinstall")
destructive_lines = [
    line for line in active_shell_lines(preinstall)
    if re.search(r"(^|[;&|]\s*|\s)(cleanup|/bin/rm|rm)\s", line)
]
check(
    not any(
        re.search(r"(?:^|\s)[\"']?/Library/Input Methods/Saylane\.app(?:[\"']|\s|$)", line)
        for line in destructive_lines
    ),
    "preinstall must not delete the live /Library/Input Methods/Saylane.app before payload validation",
)
pre_stop = shell_function(preinstall, "stop_process")
term = pre_stop.find("pkill -TERM -x")
first_probe = pre_stop.find("pgrep -x", term + 1)
wait = pre_stop.find("sleep", first_probe + 1)
kill = pre_stop.find("pkill -KILL -x", wait + 1)
final_probe = pre_stop.find("pgrep -x", kill + 1)
check(
    min(term, first_probe, wait, kill, final_probe) >= 0
    and term < first_probe < wait < kill < final_probe
    and "exit 1" in pre_stop[final_probe:],
    "preinstall must TERM, poll/wait, KILL if needed, and fail if the old process still runs",
)
first_cleanup = preinstall.find("cleanup '/Library/Input Methods/RTranslate.app'")
check(
    first_cleanup < 0
    or (0 <= preinstall.find("stop_process Saylane") < first_cleanup
        and 0 <= preinstall.find("stop_process RTranslate") < first_cleanup),
    "preinstall must finish stopping Saylane and RTranslate before touching old bundles",
)


# Uninstall safety: the app performs the TIS transition while its executable still
# exists, in the console user's bootstrap/session. A failed disable must leave the
# bundle in place so the user can retry. LaunchServices deregistration is user state.
uninstall = read("scripts/uninstall.sh")
uninstall_logical = logical_shell(uninstall)
disable_lines = [line.strip() for line in uninstall_logical.splitlines()
                 if "--disable-input-source" in line]
check(len(disable_lines) == 1, "uninstall must invoke exactly one input-source disable command")
if disable_lines:
    disable_command = disable_lines[0]
    check(
        "launchctl asuser" in disable_command
        and "/usr/bin/sudo" in disable_command
        and re.search(r"\s-u\s+\"?\$USER_NAME\"?", disable_command) is not None,
        "uninstall must run input-source disable in the logged-in console user's context",
    )

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
user_unregister_lines = [
    line.strip() for line in between_disable_and_remove.splitlines()
    if "lsregister" in line and " -u " in f" {line} "
]
remove_body = logical_shell(shell_function(uninstall, "remove_bundle"))
remove_user_unregister_lines = [
    line.strip() for line in remove_body.splitlines()
    if "lsregister" in line and " -u " in f" {line} "
]
helper_unregisters_before_delete = (
    any("launchctl asuser" in line and "/usr/bin/sudo" in line
        for line in remove_user_unregister_lines)
    and 0 <= remove_body.find("lsregister") < remove_body.find("/bin/rm")
)
check(
    any("launchctl asuser" in line and "/usr/bin/sudo" in line for line in user_unregister_lines)
    or helper_unregisters_before_delete,
    "uninstall must run lsregister -u in the console user's context after TIS disable and before bundle removal",
)

input_source = read("Sources/IME/InputSourceInstall.swift")
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


# Release gates: both version axes must match build/source/project, app signing
# must be a stable Developer ID from the expected team, and the final PKG must be
# installer-signed. An unsigned intermediate must never be renamed to a final PKG.
package = read("scripts/package.sh")
required_version_terms = [
    "CFBundleShortVersionString",
    "CFBundleVersion",
    "MARKETING_VERSION",
    "CURRENT_PROJECT_VERSION",
    "$BUILD_VERSION",
    "$SOURCE_BUILD_VERSION",
    "$PROJECT_BUILD_VERSION",
]
for term in required_version_terms:
    check(term in package, f"package version gate is missing {term}")
version_failure = package.find("Version mismatch:")
staging = package.find("ROOT=")
version_gate_start = package.rfind("[[", 0, version_failure)
version_gate = package[version_gate_start:version_failure] if version_gate_start >= 0 else ""
for variable in (
    "$VERSION", "$SOURCE_VERSION", "$PROJECT_VERSION",
    "$BUILD_VERSION", "$SOURCE_BUILD_VERSION", "$PROJECT_BUILD_VERSION",
):
    check(variable in version_gate, f"package mismatch gate does not compare {variable}")
check(
    0 <= version_failure < staging,
    "short and build version mismatches must abort before staging the package",
)

identity_guard = package.find('[[ -n "$IDENTITY" ]]')
first_app_sign = package.find("codesign --force")
check(
    0 <= identity_guard < first_app_sign and "exit 1" in package[identity_guard:first_app_sign],
    "a non-empty application signing identity must be required before codesign",
)
for variable in ("INSTALLER", "NOTARY_PROFILE"):
    guard = package.find(f'[[ -n "${variable}" ]]')
    check(0 <= guard < first_app_sign,
          f"{variable} must be validated before accessing any signing key")
check(
    "--options runtime" in package and "--timestamp" in package
    and "--entitlements Sources/Saylane.entitlements" in package,
    "release app signing must use hardened runtime, a timestamp, and Saylane entitlements",
)
strict_verify = package.find("codesign --verify --strict")
pkgbuild = package.find("pkgbuild --analyze")
team_region = package[strict_verify:pkgbuild] if 0 <= strict_verify < pkgbuild else ""
check(
    "TeamIdentifier" in team_region and "L95PYLFT86" in team_region,
    "after signing, package.sh must verify the app TeamIdentifier is L95PYLFT86 before pkgbuild",
)
check(
    "designated => cdhash" in package and package.find("designated => cdhash") < pkgbuild,
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
