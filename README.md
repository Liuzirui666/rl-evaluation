# rl-evaluation

Code release accompanying our paper on RL evaluation.

> **Status:** 🚧 Work in progress. Experiments are still running; this repository
> is reserved as the permanent code-release link for our submission. The full
> codebase, scripts, configs, and instructions to reproduce the paper's results
> will be pushed here before the camera-ready deadline.

## Planned contents

- `src/` — training, evaluation, and analysis code
- `scripts/` — SLURM / shell entry points used to launch experiments
- `configs/` — experiment configurations (one file per reported run)
- `notebooks/` — analysis notebooks that produce the paper's figures
- `data/` — pointers / download scripts for any external datasets used
- `requirements.txt` / `environment.yml` — pinned dependencies

## Reproducing results

A complete reproduction guide will be added once the experiments are finalized.
At that point this section will cover:

1. Environment setup (Python version, CUDA, key library versions)
2. Data download / preparation
3. Commands to reproduce each table and figure in the paper
4. Expected wall-clock and hardware (we used NVIDIA A100 GPUs on a SLURM cluster)

## Citation

A BibTeX entry will be added here once the paper is finalized.

## License

To be decided before the camera-ready release.

## Contact

Open an issue on this repository for questions about the code or paper.
