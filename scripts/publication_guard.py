#!/usr/bin/env python3
"""Check Git-eligible source files without printing their contents.

This is a publication guard, not a replacement for secret scanning or review.
It deliberately includes untracked, non-ignored files so it works before commit.
"""

from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PRIVATE_NAMES = {
    "auth.json", "velvet-admin-key", "access-key.txt", "local.properties",
    "signing.properties", "Config.local.xcconfig", "velvet.toml",
}
PRIVATE_SUFFIXES = {
    ".keystore", ".jks", ".p12", ".p8", ".mobileprovision", ".key",
    ".ipa", ".apk", ".aab", ".zip", ".db", ".sqlite", ".sqlite3",
}
GENERATED_PARTS = {
    ".gradle", ".kotlin", "node_modules", "target", "build", "dist",
    "releases", "xcuserdata", ".git",
}
CHECKS = {
    "private key material": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"),
    "personal macOS path": re.compile(rb"/Users/[A-Za-z0-9][A-Za-z0-9_.-]+/"),
    "personal Windows path": re.compile(rb"[A-Za-z]:\\+Users\\+[A-Za-z0-9][A-Za-z0-9_.-]+\\+"),
}


def main() -> int:
    listed = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=ROOT,
    )
    files = sorted(set(listed.decode().rstrip("\0").split("\0")) - {""})
    failures = []
    for name in files:
        relative = PurePosixPath(name)
        path = ROOT / name
        if not path.exists():
            continue  # A tracked deletion is checked by Git itself.
        if path.is_symlink():
            failures.append((name, "symlink requires publication review"))
            continue
        if not path.is_file():
            failures.append((name, "non-file entry"))
            continue
        if (relative.name in PRIVATE_NAMES or relative.suffix.lower() in PRIVATE_SUFFIXES
                or re.search(r"\.(?:db|sqlite|sqlite3)-(?:wal|shm|journal)$", relative.name)):
            failures.append((name, "private/generated file type"))
        if any(part in GENERATED_PARTS or part.startswith("DerivedData") for part in relative.parts):
            failures.append((name, "generated directory"))
        if relative.name.startswith(".env") and relative.name != ".env.example":
            failures.append((name, "private environment file"))
        data = path.read_bytes()
        for label, pattern in CHECKS.items():
            if pattern.search(data):
                failures.append((name, label))
    for name, reason in failures:
        print(f"FAIL {name}: {reason}")
    print(f"Publication guard: {len(files)} files checked; {len(failures)} findings.")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
