"""
tests/common.sage -- loads the project (p=37, R=6 by default) and the check helpers.
"""

import os, random, sys

if "attack" not in globals():
    os.environ.setdefault("SKY_P", "37")
    os.environ.setdefault("SKY_ROUNDS", "6")
    os.environ.setdefault("SKY_LOG", "warning")
    load(os.path.join(SKY_DIR, "main.sage"))

_failures = []


def check(name, ok, detail=""):
    print(f"  [{'ok' if ok else 'FAIL'}] {name}" + (f": {detail}" if detail else ""), flush=True)
    if not ok:
        _failures.append(name)


def raises(exc, fn):
    try:
        fn()
    except exc:
        return True
    return False


def fd_count():
    return len(os.listdir("/proc/self/fd"))


def finish():
    print()
    if _failures:
        print(f"FAILED ({len(_failures)}): {_failures}")
        sys.exit(1)
    print("all checks passed")
