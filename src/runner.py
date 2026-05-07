"""Run a single non-splitting (baseline MC) experiment.

This is a thin wrapper around FuzzBench's local-experiment runner. One
invocation runs `num_trials` independent Monte-Carlo replications of one
(fuzzer, benchmark) pair for `total_duration_hours`, with strict CPU
pinning. No branching, no seed harvesting, no level-by-level scheduling.
"""
from __future__ import annotations

import os
import subprocess
import sys
import threading
from pathlib import Path
from typing import Optional

import yaml

from .config import RunConfig
from .utils import check_disk_or_abort


def _write_experiment_yaml(cfg: RunConfig) -> Path:
    """Write a minimal FuzzBench YAML experiment-config for this run."""
    cfg_dir = cfg.work_dir / "configs"
    cfg_dir.mkdir(parents=True, exist_ok=True)

    payload = {
        "trials": cfg.num_trials,
        "max_total_time": int(cfg.total_duration_hours * 3600),
        "docker_registry": cfg.docker_registry,
        "experiment_filestore": str(cfg.per_run_filestore),
        "report_filestore": str(cfg.report_filestore),
        "local_experiment": True,
        "snapshot_period": cfg.snapshot_seconds,
        "runner_num_cpu_cores": cfg.runner_num_cpu_cores,
    }
    out = cfg_dir / f"{cfg.experiment_name}.yaml"
    out.write_text(yaml.safe_dump(payload, sort_keys=False))
    return out


def _pump_output(prefix: str, pipe, log_path: Optional[Path] = None) -> None:
    """Tag-and-forward subprocess stdout to our stdout (and optionally a file)."""
    log_file = None
    try:
        if log_path:
            log_path.parent.mkdir(parents=True, exist_ok=True)
            log_file = open(log_path, "w")
        for line in iter(pipe.readline, ""):
            if not line:
                break
            tagged = f"[{prefix}] {line}"
            sys.stdout.write(tagged)
            sys.stdout.flush()
            if log_file:
                log_file.write(tagged)
                log_file.flush()
    except Exception:
        pass
    finally:
        if log_file:
            log_file.close()


def run(cfg: RunConfig) -> bool:
    """Run one non-splitting experiment to completion.

    Returns True iff FuzzBench's run_experiment.py exited 0.
    """
    check_disk_or_abort(context=f"start of {cfg.experiment_name}")

    # Per-run filestore isolates the SQLite DB so reruns can never inherit
    # stale trial scheduling from earlier runs.
    cfg.per_run_filestore.mkdir(parents=True, exist_ok=True)
    cfg.work_dir.mkdir(parents=True, exist_ok=True)

    config_path = _write_experiment_yaml(cfg)

    cmd = [
        sys.executable,
        str(cfg.run_experiment_py),
        "--experiment-config", str(config_path),
        "--experiment-name", cfg.experiment_name,
        "--fuzzers", cfg.fuzzer,
        "--benchmarks", cfg.benchmark,
        "--concurrent-builds", str(cfg.concurrent_builds),
        "--runners-cpus", str(cfg.runners_cpus),
        "--measurers-cpus", str(cfg.measurers_cpus),
        "--cpu-offset", str(cfg.cpu_offset),
    ]
    if cfg.custom_seed_corpus_dir and cfg.custom_seed_corpus_dir.exists():
        cmd.extend(["--custom-seed-corpus-dir", str(cfg.custom_seed_corpus_dir)])
    if cfg.allow_uncommitted:
        cmd.append("--allow-uncommitted-changes")

    env = os.environ.copy()
    env["PYTHONPATH"] = str(cfg.fuzzbench_dir)

    log_path = cfg.work_dir / "logs" / f"{cfg.experiment_name}.log"
    print(f"[runner] start {cfg.experiment_name}: "
          f"{cfg.fuzzer} on {cfg.benchmark}, "
          f"M={cfg.num_trials} T={cfg.total_duration_hours}h "
          f"cpu_offset={cfg.cpu_offset}")

    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        cwd=str(cfg.work_dir),
        env=env,
    )
    pump = threading.Thread(
        target=_pump_output,
        args=(cfg.experiment_name, proc.stdout, log_path),
        daemon=True,
    )
    pump.start()
    rc = proc.wait()
    pump.join(timeout=5)

    print(f"[runner] {cfg.experiment_name} exited with rc={rc}")
    return rc == 0
