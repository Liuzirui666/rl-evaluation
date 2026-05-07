"""Shared utilities for the non-splitting framework."""
from __future__ import annotations

import subprocess
import sys


# Disk safety floor (GB). Aborts experiments when free space drops below this.
MIN_FREE_DISK_GB = 300


def get_total_ram_gb() -> float:
    """Return total system RAM in GB."""
    import psutil
    return psutil.virtual_memory().total / (1024 ** 3)


def get_available_ram_gb() -> float:
    """Return available system RAM in GB."""
    import psutil
    return psutil.virtual_memory().available / (1024 ** 3)


def check_ram_safety(min_available_gb: float = 20.0) -> bool:
    """Return True if at least min_available_gb of RAM is free."""
    avail = get_available_ram_gb()
    if avail < min_available_gb:
        print(f"[utils] WARNING: only {avail:.1f}GB RAM available (need {min_available_gb}GB)")
        return False
    return True


def free_disk_gb(path: str = "/") -> int:
    """Return the integer GB free on the filesystem holding `path`."""
    out = subprocess.run(
        ["df", "--output=avail", "-BG", path],
        capture_output=True, text=True, check=True,
    ).stdout
    return int(out.strip().split("\n")[-1].replace("G", ""))


def check_disk_or_abort(context: str = "", floor_gb: int = MIN_FREE_DISK_GB) -> int:
    """Abort the process if free disk is below `floor_gb`.

    Returns the current free GB on success.
    """
    free = free_disk_gb("/")
    if free < floor_gb:
        print(f"\n!!!! ABORT: free disk {free}GB < floor {floor_gb}GB", file=sys.stderr)
        if context:
            print(f"  context: {context}", file=sys.stderr)
        sys.exit(1)
    return free


def kill_only_our_dispatcher_containers(experiment_prefix: str) -> int:
    """Forcibly remove dispatcher containers that belong to the given prefix.

    Strictly scoped: only `dispatcher-d-{prefix}*` containers are touched.
    Non-fuzzbench containers and other experiments are left alone.
    """
    if not experiment_prefix:
        print("[utils] kill_only_our_dispatcher_containers needs a non-empty prefix",
              file=sys.stderr)
        return 0
    out = subprocess.run(
        ["docker", "ps", "--format", "{{.Names}}"],
        capture_output=True, text=True,
    ).stdout
    killed = 0
    for name in out.strip().split("\n"):
        if name.startswith(f"dispatcher-d-{experiment_prefix}"):
            subprocess.run(["docker", "rm", "-f", name],
                           capture_output=True, timeout=30)
            killed += 1
    return killed
