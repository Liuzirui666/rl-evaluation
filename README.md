# Non-Splitting Evaluation Framework for Mutation-Based Fuzzers

Reproducible non-splitting (baseline Monte-Carlo) evaluation pipeline used to
study mutation-based fuzzers as Markov chains. The framework runs `M`
independent baseline campaigns of one (fuzzer, benchmark) pair on FuzzBench,
with strict CPU pinning, automatic per-pair cleanup, and a 300 GB free-disk
floor.

This repository contains **only the non-splitting code path**. No splitting
orchestration, no sparsity computation, no online split tracking. The
upstream-FuzzBench fork that lives under [`fuzzbench/`](./fuzzbench/) is
mode-agnostic and used as-is for both running and measuring.

## Repository layout

```
.
├── fuzzbench/             # FuzzBench fork (commit 90e59b6 + benchmark/build fixes)
├── src/                   # Non-splitting framework (Python)
│   ├── cli.py             # python -m src.cli {run,parallel}
│   ├── config.py          # RunConfig dataclass and path defaults
│   ├── runner.py          # Single-experiment runner around run_experiment.py
│   ├── parallel_runner.py # CPU-layout helper (auto runners/measurers split)
│   └── utils.py           # Disk floor, RAM check, scoped container cleanup
├── scripts/
│   ├── run_one_fuzzer.sh        # Build + run ONE (fuzzer, benchmark) pair
│   ├── run_one_benchmark.sh     # Build + run all 9 fuzzers for ONE benchmark
│   └── patch_generated_mk.py    # Post-`make generate-makefile` patch
├── LICENSE                # Apache 2.0 (inherited from FuzzBench)
└── README.md
```

## Fuzzers (9)

`afl`, `aflfast`, `aflplusplus`, `aflsmart`, `entropic`, `fairfuzz`,
`honggfuzz`, `libfuzzer`, `mopt`.

## Benchmarks (18, FuzzBench commit `90e59b6`)

`arrow_parquet-arrow-fuzz`, `aspell_aspell_fuzzer`,
`ffmpeg_ffmpeg_demuxer_fuzzer`, `grok_grk_decompress_fuzzer`,
`harfbuzz-1.3.2`, `libgit2_objects_fuzzer`, `libhevc_hevc_dec_fuzzer`,
`libhtp_fuzz_htp`, `libxml2_libxml2_xml_reader_for_file_fuzzer`,
`matio_matio_fuzzer`, `njs_njs_process_script_fuzzer`,
`openh264_decoder_fuzzer`, `php_php-fuzz-parser-2020-07-25`,
`poppler_pdf_fuzzer`, `quickjs_eval-2020-01-05`, `stb_stbi_read_fuzzer`,
`systemd_fuzz-link-parser`, `wireshark_fuzzshark_ip`.

## Requirements

- Linux x86_64, Docker (legacy builder; the framework sets `DOCKER_BUILDKIT=0`)
- Python 3.10
- ≥ 300 GB free disk on `/` (the framework aborts otherwise)
- For the 18-benchmark × 9-fuzzer matrix, plan ≥ 188 CPU cores

Set up the FuzzBench Python environment (per upstream FuzzBench docs):

```bash
cd fuzzbench
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cd ..
```

If you use Conda, set `NONSPLIT_CONDA_ENV=<env-name>` before invoking the
shell scripts and they will activate that environment for you.

## Quick start

### Run one (fuzzer, benchmark) baseline

```bash
# 5 trials × 23 h on stb with afl, auto pre-flight + cleanup
./scripts/run_one_fuzzer.sh afl stb_stbi_read_fuzzer baseline 82800 5
```

### Run all 9 fuzzers on one benchmark sequentially

```bash
./scripts/run_one_benchmark.sh stb_stbi_read_fuzzer baseline 82800 5
```

### Use the Python CLI directly

```bash
# Single experiment with explicit CPU pinning
python -m src.cli run \
    --fuzzer afl --benchmark stb_stbi_read_fuzzer \
    --experiment-name baseline-stb-afl \
    --num-trials 5 --total-hours 23 \
    --runners-cpus 20 --measurers-cpus 8 --cpu-offset 0

# Auto-computed CPU layout (parallel command)
python -m src.cli parallel \
    --fuzzer afl --benchmark stb_stbi_read_fuzzer \
    --experiment-name baseline-stb-afl \
    --num-trials 5 --total-cores 188 --cpu-offset 0
```

`run` runs FuzzBench's local experiment runner with `M` independent trials
of `(fuzzer, benchmark)`. `parallel` is identical except it computes a
balanced runners/measurers split from `--total-cores` and `--num-trials`.

## What this framework does *not* do

- No splitting, no sparsity computation, no online split detection.
- No corpus harvesting, no per-branch seed management, no cross-trial
  seed unions.
- No `1/k_t`-weighted estimators. Bug detection rate is the plain
  Monte-Carlo mean over `M` independent trials.

## Operational rules baked into the scripts

1. **One benchmark at a time.** Never run multiple benchmarks in parallel.
2. Disk check before *and* after every build / experiment. Aborts at < 300 GB.
3. **No** `docker prune` of any flavour (builder, image, system, volume).
4. After each (fuzzer, benchmark) pair: delete only its 4 per-pair images.
5. After all 9 fuzzers complete on a benchmark: delete only that benchmark's
   3 build/coverage images.
6. Container cleanup is strictly scoped to `dispatcher-d-<experiment_prefix>*`
   and exited containers verified by `FUZZING_ENGINE` / `FUZZBENCH` /
   `OSS_FUZZ` env markers.
7. `gcr.io/fuzzbench/base-image` is never deleted.

## License

Apache License 2.0. The `fuzzbench/` subtree retains FuzzBench's upstream
Apache 2.0 license (see [`fuzzbench/LICENSE`](fuzzbench/LICENSE)) and the
top-level [`LICENSE`](LICENSE) inherits the same terms.

## Acknowledgements

Built on top of Google's [FuzzBench](https://github.com/google/fuzzbench)
benchmarking infrastructure.
