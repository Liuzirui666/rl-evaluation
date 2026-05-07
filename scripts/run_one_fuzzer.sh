#!/usr/bin/env bash
# =============================================================================
# run_one_fuzzer.sh — Build & run ONE fuzzer × ONE benchmark (non-splitting).
#
# Wraps FuzzBench's local run_experiment.py for a single (fuzzer, benchmark)
# pair with `num-trials` independent Monte-Carlo replications. After the run,
# the script cleans up its own dispatcher containers and per-pair images,
# never touching anything outside the gcr.io/fuzzbench/* namespace.
#
# Usage:
#   ./scripts/run_one_fuzzer.sh <fuzzer> <benchmark> [exp_prefix] [duration_seconds] [num_trials]
#
# Defaults: exp_prefix=baseline, duration=82800s (23h), num_trials=5
# =============================================================================
set -euo pipefail

MIN_FREE_DISK_GB=300
export DOCKER_BUILDKIT=0

VALID_FUZZERS=(afl aflfast aflplusplus aflsmart entropic fairfuzz honggfuzz libfuzzer mopt)
VALID_BENCHMARKS=(
    arrow_parquet-arrow-fuzz aspell_aspell_fuzzer ffmpeg_ffmpeg_demuxer_fuzzer
    grok_grk_decompress_fuzzer harfbuzz-1.3.2 libgit2_objects_fuzzer
    libhevc_hevc_dec_fuzzer libhtp_fuzz_htp
    libxml2_libxml2_xml_reader_for_file_fuzzer matio_matio_fuzzer
    njs_njs_process_script_fuzzer openh264_decoder_fuzzer
    php_php-fuzz-parser-2020-07-25 poppler_pdf_fuzzer quickjs_eval-2020-01-05
    stb_stbi_read_fuzzer systemd_fuzz-link-parser wireshark_fuzzshark_ip
)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
FUZZBENCH_DIR="${PROJECT_DIR}/fuzzbench"
CONFIG_DIR="${PROJECT_DIR}/configs"
TIMESTAMP="$(date +%Y%m%d-%H%M)"

FUZZER="${1:?Usage: $0 <fuzzer> <benchmark> [exp_prefix] [duration_seconds] [num_trials]}"
BENCHMARK="${2:?Usage: $0 <fuzzer> <benchmark> [exp_prefix] [duration_seconds] [num_trials]}"
EXP_PREFIX="${3:-baseline}"
DURATION_SECONDS="${4:-82800}"        # 23h default (paper baseline)
NUM_TRIALS="${5:-5}"

# Optional: activate conda env if NONSPLIT_CONDA_ENV is set
if [ -n "${NONSPLIT_CONDA_ENV:-}" ]; then
    eval "$(conda shell.bash hook)"
    conda activate "$NONSPLIT_CONDA_ENV"
fi
export PYTHONPATH="${FUZZBENCH_DIR}:${PYTHONPATH:-}"

abort_msg() { echo "!!!! ABORT: $1" >&2; exit 1; }

check_disk_or_abort() {
    local free_gb
    free_gb=$(df --output=avail -BG / | tail -1 | tr -d ' G')
    [ "$free_gb" -lt "$MIN_FREE_DISK_GB" ] && abort_msg "DISK ${free_gb}GB < ${MIN_FREE_DISK_GB}GB ($1)"
    echo "[disk-check] ${free_gb}GB free ($1)"
}

# Validate inputs
found=0; for v in "${VALID_FUZZERS[@]}"; do [ "$v" = "$FUZZER" ] && found=1; done
[ "$found" -eq 0 ] && abort_msg "Invalid fuzzer: ${FUZZER}"
found=0; for v in "${VALID_BENCHMARKS[@]}"; do [ "$v" = "$BENCHMARK" ] && found=1; done
[ "$found" -eq 0 ] && abort_msg "Invalid benchmark: ${BENCHMARK}"

check_disk_or_abort "before starting"

EXP_NAME="${EXP_PREFIX}-${FUZZER}-${TIMESTAMP}"
[ "${#EXP_NAME}" -gt 30 ] && abort_msg "Experiment name too long (${#EXP_NAME} > 30): ${EXP_NAME}"

echo "============================================================"
echo "  Non-splitting baseline: ${FUZZER} × ${BENCHMARK}"
echo "  trials=${NUM_TRIALS} duration=${DURATION_SECONDS}s name=${EXP_NAME}"
echo "============================================================"

# Build
cd "$FUZZBENCH_DIR"
check_disk_or_abort "before build"
echo "[build] Building ${FUZZER}×${BENCHMARK}…"
make -j1 -f docker/generated.mk "build-${FUZZER}-${BENCHMARK}" 2>&1 | tail -20
docker image inspect "gcr.io/fuzzbench/runners/${FUZZER}/${BENCHMARK}" >/dev/null 2>&1 || \
    abort_msg "Build FAILED — runner image not found"
check_disk_or_abort "after build"
cd "$PROJECT_DIR"

# Write FuzzBench experiment config
mkdir -p "$CONFIG_DIR"
FILESTORE="${PROJECT_DIR}/results/experiment-data/${EXP_NAME}"
REPORT_STORE="${PROJECT_DIR}/results/report-data/${EXP_NAME}"
mkdir -p "$FILESTORE" "$REPORT_STORE"
CONFIG_PATH="${CONFIG_DIR}/${EXP_NAME}.yaml"
cat > "$CONFIG_PATH" <<YAML
trials: ${NUM_TRIALS}
max_total_time: ${DURATION_SECONDS}
docker_registry: gcr.io/fuzzbench
experiment_filestore: ${FILESTORE}
report_filestore: ${REPORT_STORE}
local_experiment: true
snapshot_period: 360
runner_num_cpu_cores: 1
YAML

# Run
echo "[run] FuzzBench local experiment: ${EXP_NAME}"
cd "$FUZZBENCH_DIR"
set +e
python experiment/run_experiment.py \
    --experiment-config "$CONFIG_PATH" \
    --experiment-name "$EXP_NAME" \
    --fuzzers "$FUZZER" \
    --benchmarks "$BENCHMARK" \
    --runners-cpus 4 \
    --measurers-cpus 4 \
    --concurrent-builds 1 \
    --allow-uncommitted-changes
rc=$?
set -e
cd "$PROJECT_DIR"

# Cleanup — strictly scoped to our containers/images
for name in $(docker ps -a --format '{{.Names}}' 2>/dev/null); do
    [[ "$name" == dispatcher-d-${EXP_NAME}* ]] && docker rm -f "$name" >/dev/null 2>&1
    [[ "$name" == dispatcher-d-${EXP_PREFIX}* ]] && docker rm -f "$name" >/dev/null 2>&1
done
for cname in $(docker ps -a --filter "status=exited" --format '{{.Names}}' 2>/dev/null); do
    cenvs=$(docker inspect "$cname" --format '{{.Config.Env}}' 2>/dev/null)
    if echo "$cenvs" | grep -q "FUZZING_ENGINE\|FUZZBENCH\|OSS_FUZZ"; then
        docker rm -f "$cname" >/dev/null 2>&1
    fi
done
for img in \
    "gcr.io/fuzzbench/builders/${FUZZER}/${BENCHMARK}-intermediate" \
    "gcr.io/fuzzbench/builders/${FUZZER}/${BENCHMARK}" \
    "gcr.io/fuzzbench/runners/${FUZZER}/${BENCHMARK}-intermediate" \
    "gcr.io/fuzzbench/runners/${FUZZER}/${BENCHMARK}"; do
    [[ "$img" == gcr.io/fuzzbench/* ]] && docker rmi -f "$img" 2>/dev/null || true
done
docker rmi -f "gcr.io/fuzzbench/dispatcher-image" 2>/dev/null || true
docker rmi -f "gcr.io/fuzzbench/worker" 2>/dev/null || true
for did in $(docker images --filter "dangling=true" --format '{{.ID}}' 2>/dev/null); do
    denvs=$(docker image inspect "$did" --format '{{.Config.Env}}' 2>/dev/null)
    dlabels=$(docker image inspect "$did" --format '{{.Config.Labels}}' 2>/dev/null)
    if echo "$denvs" | grep -q "FUZZING_ENGINE\|FUZZBENCH\|OSS_FUZZ"; then
        docker rmi -f "$did" >/dev/null 2>&1
    elif echo "$dlabels" | grep -q "ubuntu"; then
        docker rmi -f "$did" >/dev/null 2>&1
    fi
done

# experiment data is owned by docker containers — sudo rm if available
sudo rm -rf "$FILESTORE" "$REPORT_STORE" 2>/dev/null || rm -rf "$FILESTORE" "$REPORT_STORE" 2>/dev/null
rm -f "$CONFIG_PATH"

echo "[cleanup] containers, images, data — done"
check_disk_or_abort "after cleanup"

if [ "$rc" -eq 0 ]; then
    echo "[OK] ${FUZZER} × ${BENCHMARK} succeeded"
else
    echo "[FAIL] ${FUZZER} × ${BENCHMARK} failed (exit=${rc})" >&2
    exit "$rc"
fi
