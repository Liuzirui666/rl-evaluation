"""Central configuration for non-splitting (baseline Monte Carlo) experiments.

Provides paths and a Config dataclass shared by the runner and CLI. CLI
overrides default values at invocation time.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Optional


# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
PROJECT_ROOT = Path(__file__).resolve().parent.parent
FUZZBENCH_DIR = PROJECT_ROOT / "fuzzbench"
RUN_EXPERIMENT_PY = FUZZBENCH_DIR / "experiment" / "run_experiment.py"

DEFAULT_EXPERIMENT_FILESTORE = PROJECT_ROOT / "results" / "experiment-data"
DEFAULT_REPORT_FILESTORE = PROJECT_ROOT / "results" / "report-data"
DEFAULT_TMP_DIR = PROJECT_ROOT / "tmp"

# ---------------------------------------------------------------------------
# FuzzBench / Docker defaults
# ---------------------------------------------------------------------------
DOCKER_REGISTRY = "gcr.io/fuzzbench"
DEFAULT_CONCURRENT_BUILDS = 5
DEFAULT_SNAPSHOT_SECONDS = 360            # 6 min (matches FuzzBench patch)
DEFAULT_TOTAL_DURATION_HOURS = 23.0       # T (paper baseline)


@dataclass
class RunConfig:
    """Configuration for one non-splitting (baseline MC) run.

    A single FuzzBench experiment runs `num_trials` independent Monte-Carlo
    replications of (fuzzer, benchmark) for `total_duration_hours`. Each
    trial is a fresh, independent run; no branching, no seed harvesting.
    """

    # Identity
    experiment_name: str
    fuzzer: str
    benchmark: str

    # Paths
    project_root: Path = PROJECT_ROOT
    fuzzbench_dir: Path = FUZZBENCH_DIR
    experiment_filestore: Path = DEFAULT_EXPERIMENT_FILESTORE
    report_filestore: Path = DEFAULT_REPORT_FILESTORE
    tmp_dir: Path = DEFAULT_TMP_DIR

    # Run parameters
    num_trials: int = 5                            # M independent MC trials
    total_duration_hours: float = DEFAULT_TOTAL_DURATION_HOURS

    # CPU allocation
    runners_cpus: int = 20
    measurers_cpus: int = 8
    cpu_offset: int = 0
    runner_num_cpu_cores: int = 1

    # FuzzBench knobs
    docker_registry: str = DOCKER_REGISTRY
    concurrent_builds: int = DEFAULT_CONCURRENT_BUILDS
    allow_uncommitted: bool = True
    snapshot_seconds: int = DEFAULT_SNAPSHOT_SECONDS

    # Custom seeds (None => use benchmark's default oss-fuzz seeds)
    custom_seed_corpus_dir: Optional[Path] = None

    @property
    def run_experiment_py(self) -> Path:
        return self.fuzzbench_dir / "experiment" / "run_experiment.py"

    @property
    def work_dir(self) -> Path:
        return self.tmp_dir / self.experiment_name

    @property
    def per_run_filestore(self) -> Path:
        """Per-experiment filestore (isolates SQLite local.db between runs)."""
        return self.experiment_filestore / self.experiment_name
