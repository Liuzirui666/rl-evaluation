"""Parallel non-splitting runner.

Runs the SAME single FuzzBench experiment with `num_trials` Monte-Carlo
replications via run_experiment.py. FuzzBench itself parallelises trials
internally; this module exists so that you can pin the experiment to a
specific CPU range and to keep parity with the original splitting CLI.

Use this for one (fuzzer, benchmark) pair at a time. To run multiple
fuzzers or benchmarks in parallel, allocate non-overlapping CPU ranges
and invoke the runner once per pair (see scripts/run_one_benchmark.sh).
"""
from __future__ import annotations

from dataclasses import dataclass

from .config import RunConfig
from .runner import run as run_one
from .utils import check_disk_or_abort


@dataclass
class CPULayout:
    """How CPU cores are allocated for one (fuzzer, benchmark) experiment."""
    total_cores: int
    num_trials: int
    runners_per_trial: int
    measurers_per_trial: int
    base_cpu_offset: int = 0

    @property
    def cores_per_trial(self) -> int:
        return self.runners_per_trial + self.measurers_per_trial

    @property
    def total_used(self) -> int:
        return self.num_trials * self.cores_per_trial

    def validate(self) -> None:
        if self.total_used > self.total_cores:
            raise ValueError(
                f"CPU overcommit: need {self.total_used} cores "
                f"({self.num_trials} trials × {self.cores_per_trial} per trial) "
                f"but only {self.total_cores} available. "
                f"Reduce --num-trials or per-trial cpu allocation."
            )


def compute_cpu_layout(
    total_cores: int,
    num_trials: int,
    min_measurers: int = 1,
    base_cpu_offset: int = 0,
) -> CPULayout:
    """Compute a sensible CPU layout for `num_trials` parallel MC trials.

    Splits available cores evenly across trials, reserving at least
    `min_measurers` measurer cores per trial.
    """
    if num_trials <= 0:
        raise ValueError("num_trials must be positive")
    cores_per_trial = (total_cores - base_cpu_offset) // num_trials
    if cores_per_trial < min_measurers + 1:
        raise ValueError(
            f"Cannot fit {num_trials} trials in {total_cores - base_cpu_offset} "
            f"cores (need at least {min_measurers + 1} per trial)."
        )
    measurers = max(min_measurers, cores_per_trial // 4)
    runners = cores_per_trial - measurers
    layout = CPULayout(
        total_cores=total_cores,
        num_trials=num_trials,
        runners_per_trial=runners,
        measurers_per_trial=measurers,
        base_cpu_offset=base_cpu_offset,
    )
    layout.validate()
    return layout


def run_parallel(cfg: RunConfig, layout: CPULayout) -> bool:
    """Run one experiment with the given CPU layout.

    FuzzBench's run_experiment.py already parallelises across `num_trials`
    runner containers; we hand it the per-trial cpu budget via
    `runners_cpus` + `measurers_cpus` and the global offset.
    """
    check_disk_or_abort(context=f"parallel run for {cfg.experiment_name}")

    cfg.runners_cpus = layout.runners_per_trial * layout.num_trials
    cfg.measurers_cpus = layout.measurers_per_trial * layout.num_trials
    cfg.cpu_offset = layout.base_cpu_offset
    cfg.num_trials = layout.num_trials

    print(f"[parallel] CPU layout: total={layout.total_cores} "
          f"trials={layout.num_trials} "
          f"runners/trial={layout.runners_per_trial} "
          f"measurers/trial={layout.measurers_per_trial} "
          f"used={layout.total_used} offset={layout.base_cpu_offset}")
    return run_one(cfg)
