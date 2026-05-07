"""Command-line interface for non-splitting (baseline MC) experiments.

Usage examples:

  # Run a single (fuzzer, benchmark) experiment with M independent trials
  python -m src.cli run \
      --fuzzer afl --benchmark stb_stbi_read_fuzzer \
      --experiment-name baseline-stb-afl \
      --num-trials 5 --total-hours 23 \
      --runners-cpus 20 --measurers-cpus 8 --cpu-offset 0

  # Run with auto-computed CPU layout (parallel command)
  python -m src.cli parallel \
      --fuzzer afl --benchmark stb_stbi_read_fuzzer \
      --experiment-name baseline-stb-afl \
      --num-trials 5 --total-cores 188 --cpu-offset 0
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import List, Optional

from .config import (
    RunConfig,
    PROJECT_ROOT,
    DEFAULT_EXPERIMENT_FILESTORE,
    DEFAULT_REPORT_FILESTORE,
)
from .runner import run as run_one
from .parallel_runner import compute_cpu_layout, run_parallel


def _build_run_config(args: argparse.Namespace) -> RunConfig:
    cfg = RunConfig(
        experiment_name=args.experiment_name,
        fuzzer=args.fuzzer,
        benchmark=args.benchmark,
        experiment_filestore=Path(args.experiment_filestore),
        report_filestore=Path(args.report_filestore),
        tmp_dir=Path(args.tmp_dir) if args.tmp_dir else PROJECT_ROOT / "tmp",
        num_trials=args.num_trials,
        total_duration_hours=args.total_hours,
        runners_cpus=args.runners_cpus,
        measurers_cpus=args.measurers_cpus,
        cpu_offset=args.cpu_offset,
        runner_num_cpu_cores=args.runner_num_cpu_cores,
        concurrent_builds=args.concurrent_builds,
        snapshot_seconds=args.snapshot_seconds,
        allow_uncommitted=not args.no_allow_uncommitted,
    )
    if args.custom_seeds:
        cfg.custom_seed_corpus_dir = Path(args.custom_seeds)
    return cfg


def cmd_run(args: argparse.Namespace) -> int:
    cfg = _build_run_config(args)
    return 0 if run_one(cfg) else 1


def cmd_parallel(args: argparse.Namespace) -> int:
    cfg = _build_run_config(args)
    layout = compute_cpu_layout(
        total_cores=args.total_cores,
        num_trials=args.num_trials,
        min_measurers=args.min_measurers,
        base_cpu_offset=args.cpu_offset,
    )
    return 0 if run_parallel(cfg, layout) else 1


def _add_common_args(p: argparse.ArgumentParser) -> None:
    p.add_argument("--experiment-name", required=True)
    p.add_argument("--fuzzer", required=True)
    p.add_argument("--benchmark", required=True)
    p.add_argument("--num-trials", type=int, default=5,
                   help="M independent Monte-Carlo trials")
    p.add_argument("--total-hours", type=float, default=23.0)
    p.add_argument("--cpu-offset", type=int, default=0)
    p.add_argument("--runner-num-cpu-cores", type=int, default=1)
    p.add_argument("--concurrent-builds", type=int, default=5)
    p.add_argument("--snapshot-seconds", type=int, default=360)
    p.add_argument("--experiment-filestore",
                   default=str(DEFAULT_EXPERIMENT_FILESTORE))
    p.add_argument("--report-filestore",
                   default=str(DEFAULT_REPORT_FILESTORE))
    p.add_argument("--tmp-dir", default=None)
    p.add_argument("--custom-seeds", default=None,
                   help="Optional custom seed corpus directory")
    p.add_argument("--no-allow-uncommitted", action="store_true")


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Non-splitting (baseline MC) fuzzing-evaluation framework",
        prog="python -m src.cli",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_run = sub.add_parser("run", help="Run one experiment with explicit cpu pinning")
    _add_common_args(p_run)
    p_run.add_argument("--runners-cpus", type=int, default=20)
    p_run.add_argument("--measurers-cpus", type=int, default=8)
    p_run.set_defaults(func=cmd_run)

    p_par = sub.add_parser("parallel", help="Run one experiment with auto cpu layout")
    _add_common_args(p_par)
    p_par.add_argument("--total-cores", type=int, default=188,
                       help="Total CPU cores available on this machine")
    p_par.add_argument("--min-measurers", type=int, default=1,
                       help="Minimum measurer cores per trial")
    # parallel command doesn't expose runners-/measurers-cpus directly;
    # they are computed from --total-cores and --num-trials.
    p_par.set_defaults(func=cmd_parallel)

    args = parser.parse_args(argv if argv is not None else sys.argv[1:])
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
