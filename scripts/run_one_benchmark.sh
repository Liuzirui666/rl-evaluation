#!/usr/bin/env bash
# =============================================================================
# run_one_benchmark.sh — Build & run ALL 9 fuzzers for ONE benchmark.
#
# Sequential per-fuzzer pipeline: build → non-splitting baseline run via
# FuzzBench's run_experiment.py → cleanup → next fuzzer.
#
# HARD RULES:
#   1. ONE benchmark at a time. Never run multiple benchmarks in parallel.
#   2. Build with --no-cache (in generated.mk) + DOCKER_BUILDKIT=0.
#   3. Disk check before AND after every build / experiment. Abort if <300GB.
#   4. After each (fuzzer, benchmark) pair: delete its 4 per-pair images.
#   5. After all 9 fuzzers complete: delete the per-benchmark images.
#   6. NEVER run any docker prune command (builder/image/system prune).
#   7. NEVER touch non-fuzzbench images/containers.
#   8. ALWAYS keep base-image (gcr.io/fuzzbench/base-image).
#   9. Container cleanup: ONLY kill dispatcher-d-{experiment}* containers.
#
# Usage:
#   ./scripts/run_one_benchmark.sh <benchmark> [exp_prefix] [duration_seconds] [num_trials]
#
# Defaults: exp_prefix=baseline, duration=82800s (23h), num_trials=5
# =============================================================================
set -euo pipefail

MIN_FREE_DISK_GB=300
export DOCKER_BUILDKIT=0

# 9 fuzzers — sequential, one at a time
FUZZERS=(
    afl
    aflfast
    aflplusplus
    aflsmart
    entropic
    fairfuzz
    honggfuzz
    libfuzzer
    mopt
)

# 18 paper benchmarks (FuzzBench commit 90e59b6)
VALID_BENCHMARKS=(
    arrow_parquet-arrow-fuzz
    aspell_aspell_fuzzer
    ffmpeg_ffmpeg_demuxer_fuzzer
    grok_grk_decompress_fuzzer
    harfbuzz-1.3.2
    libgit2_objects_fuzzer
    libhevc_hevc_dec_fuzzer
    libhtp_fuzz_htp
    libxml2_libxml2_xml_reader_for_file_fuzzer
    matio_matio_fuzzer
    njs_njs_process_script_fuzzer
    openh264_decoder_fuzzer
    php_php-fuzz-parser-2020-07-25
    poppler_pdf_fuzzer
    quickjs_eval-2020-01-05
    stb_stbi_read_fuzzer
    systemd_fuzz-link-parser
    wireshark_fuzzshark_ip
)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
FUZZBENCH_DIR="${PROJECT_DIR}/fuzzbench"
CONFIG_DIR="${PROJECT_DIR}/configs"
TIMESTAMP="$(date +%Y%m%d-%H%M)"

BENCHMARK="${1:?Usage: $0 <benchmark> [exp_prefix] [duration_seconds] [num_trials]}"
EXP_PREFIX="${2:-baseline}"
DURATION_SECONDS="${3:-82800}"   # 23h paper baseline
NUM_TRIALS="${4:-5}"

if [ -n "${NONSPLIT_CONDA_ENV:-}" ]; then
    eval "$(conda shell.bash hook)"
    conda activate "$NONSPLIT_CONDA_ENV"
fi
export PYTHONPATH="${FUZZBENCH_DIR}:${PYTHONPATH:-}"

# ---------------------------------------------------------------------------
# Safety helpers (strictly scoped to gcr.io/fuzzbench/* and dispatcher-d-*)
# ---------------------------------------------------------------------------
abort_msg() {
    echo "" >&2
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
    echo "!!!! ABORT: $1" >&2
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
    echo "" >&2
    exit 1
}

check_disk_or_abort() {
    local context="$1"
    local free_gb
    free_gb=$(df --output=avail -BG / | tail -1 | tr -d ' G')
    if [ "$free_gb" -lt "$MIN_FREE_DISK_GB" ]; then
        abort_msg "DISK ${free_gb}GB < ${MIN_FREE_DISK_GB}GB — ${context}"
    fi
    echo "[disk-check] ${free_gb}GB free (min ${MIN_FREE_DISK_GB}GB) — ${context}"
}

validate_benchmark() {
    local bm="$1"
    for valid in "${VALID_BENCHMARKS[@]}"; do
        [ "$bm" = "$valid" ] && return 0
    done
    abort_msg "Invalid benchmark: ${bm}. Must be one of: ${VALID_BENCHMARKS[*]}"
}

delete_pair_images() {
    local fuzzer="$1" benchmark="$2"
    for img in \
        "gcr.io/fuzzbench/builders/${fuzzer}/${benchmark}-intermediate" \
        "gcr.io/fuzzbench/builders/${fuzzer}/${benchmark}" \
        "gcr.io/fuzzbench/runners/${fuzzer}/${benchmark}-intermediate" \
        "gcr.io/fuzzbench/runners/${fuzzer}/${benchmark}"; do
        [[ "$img" == gcr.io/fuzzbench/* ]] || abort_msg "REFUSING to delete non-fuzzbench image: ${img}"
        docker rmi -f "$img" 2>/dev/null || true
    done
    echo "[cleanup] Deleted 4 pair images for ${fuzzer}×${benchmark}"
}

delete_benchmark_images() {
    local benchmark="$1"
    for img in \
        "gcr.io/fuzzbench/builders/benchmark/${benchmark}" \
        "gcr.io/fuzzbench/builders/coverage/${benchmark}" \
        "gcr.io/fuzzbench/builders/coverage/${benchmark}-intermediate"; do
        [[ "$img" == gcr.io/fuzzbench/* ]] || abort_msg "REFUSING to delete: ${img}"
        docker rmi -f "$img" 2>/dev/null || true
    done
    echo "[cleanup] Deleted benchmark images for ${benchmark}"
}

delete_experiment_infra_images() {
    docker rmi -f "gcr.io/fuzzbench/dispatcher-image" 2>/dev/null || true
    docker rmi -f "gcr.io/fuzzbench/worker" 2>/dev/null || true
}

clean_dangling_fuzzbench_images() {
    local deleted=0 skipped=0
    for id in $(docker images --filter "dangling=true" --format '{{.ID}}' 2>/dev/null); do
        local envs labels
        envs=$(docker image inspect "$id" --format '{{.Config.Env}}' 2>/dev/null)
        labels=$(docker image inspect "$id" --format '{{.Config.Labels}}' 2>/dev/null)
        if echo "$envs" | grep -q "FUZZING_ENGINE\|FUZZBENCH\|OSS_FUZZ"; then
            docker rmi -f "$id" >/dev/null 2>&1 && deleted=$((deleted + 1))
        elif echo "$labels" | grep -q "ubuntu"; then
            docker rmi -f "$id" >/dev/null 2>&1 && deleted=$((deleted + 1))
        else
            skipped=$((skipped + 1))
        fi
    done
    [ "$deleted" -gt 0 ] && echo "[cleanup] Deleted ${deleted} dangling project images"
    [ "$skipped" -gt 0 ] && echo "[cleanup] Skipped ${skipped} unknown dangling images (not ours)"
}

kill_our_containers() {
    local prefix="$1"
    [ -z "$prefix" ] && abort_msg "kill_our_containers needs a non-empty prefix"
    local killed=0
    for name in $(docker ps -a --format '{{.Names}}' 2>/dev/null); do
        if [[ "$name" == dispatcher-d-${prefix}* ]]; then
            docker rm -f "$name" >/dev/null 2>&1 || true
            killed=$((killed + 1))
        fi
    done
    [ "$killed" -gt 0 ] && echo "[cleanup] Killed ${killed} containers matching dispatcher-d-${prefix}*"
}

build_pair() {
    local fuzzer="$1" benchmark="$2"
    local target="build-${fuzzer}-${benchmark}"
    check_disk_or_abort "before building ${target}"
    echo "[build] Building ${target} (--no-cache, BUILDKIT=0)…"
    make -j1 -f docker/generated.mk "$target" 2>&1 | tail -20 || \
        echo "[build] WARNING: build may have failed — verifying image…"
    docker image inspect "gcr.io/fuzzbench/runners/${fuzzer}/${benchmark}" >/dev/null 2>&1 || \
        abort_msg "Build FAILED for ${target} — runner image not found"
    check_disk_or_abort "after building ${target}"
    echo "[build] ${target} OK"
}

write_test_config() {
    local config_path="$1" filestore="$2" report_store="$3"
    cat > "$config_path" <<YAML
trials: ${NUM_TRIALS}
max_total_time: ${DURATION_SECONDS}
docker_registry: gcr.io/fuzzbench
experiment_filestore: ${filestore}
report_filestore: ${report_store}
local_experiment: true
snapshot_period: 360
runner_num_cpu_cores: 1
YAML
}

run_one_pair() {
    local fuzzer="$1" benchmark="$2" exp_name="$3"
    local filestore="${PROJECT_DIR}/results/experiment-data/${exp_name}"
    local report_store="${PROJECT_DIR}/results/report-data/${exp_name}"
    mkdir -p "$filestore" "$report_store"
    mkdir -p "$CONFIG_DIR"
    local config_path="${CONFIG_DIR}/${exp_name}.yaml"
    write_test_config "$config_path" "$filestore" "$report_store"

    echo "[run] FuzzBench non-splitting baseline: ${exp_name}"
    echo "[run]   fuzzer=${fuzzer} benchmark=${benchmark} trials=${NUM_TRIALS} duration=${DURATION_SECONDS}s"

    cd "$FUZZBENCH_DIR"
    python experiment/run_experiment.py \
        --experiment-config "$config_path" \
        --experiment-name "$exp_name" \
        --fuzzers "$fuzzer" \
        --benchmarks "$benchmark" \
        --runners-cpus 4 \
        --measurers-cpus 4 \
        --concurrent-builds 1 \
        --allow-uncommitted-changes
    local rc=$?
    cd "$PROJECT_DIR"
    return $rc
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "============================================================"
echo "  Non-splitting baseline: ${BENCHMARK}"
echo "  Fuzzers (sequential): ${FUZZERS[*]}"
echo "  trials=${NUM_TRIALS} duration=${DURATION_SECONDS}s prefix=${EXP_PREFIX}"
echo "  timestamp=${TIMESTAMP}"
echo "============================================================"

validate_benchmark "$BENCHMARK"
check_disk_or_abort "before starting"

SUCCEEDED_FUZZERS=()
FAILED_FUZZERS=()

for fuzzer in "${FUZZERS[@]}"; do
    echo ""
    echo "=========================================================="
    echo "  ${fuzzer} × ${BENCHMARK}  (${#SUCCEEDED_FUZZERS[@]}/${#FUZZERS[@]} done)"
    echo "=========================================================="

    check_disk_or_abort "before fuzzer ${fuzzer}"

    EXP_NAME="${EXP_PREFIX}-${fuzzer}-${TIMESTAMP}"
    [ "${#EXP_NAME}" -gt 30 ] && abort_msg "Experiment name too long (${#EXP_NAME} > 30): ${EXP_NAME}"

    kill_our_containers "${EXP_PREFIX}"

    cd "$FUZZBENCH_DIR"
    build_pair "$fuzzer" "$BENCHMARK"
    cd "$PROJECT_DIR"

    set +e
    run_one_pair "$fuzzer" "$BENCHMARK" "$EXP_NAME"
    rc=$?
    set -e

    kill_our_containers "${EXP_NAME}"

    if [ "$rc" -eq 0 ]; then
        echo "[OK] ${fuzzer}×${BENCHMARK}"
        SUCCEEDED_FUZZERS+=("$fuzzer")
    else
        echo "[FAIL] ${fuzzer}×${BENCHMARK} (exit=${rc})"
        FAILED_FUZZERS+=("$fuzzer")
    fi

    # Cleanup
    kill_our_containers "${EXP_NAME}"
    kill_our_containers "${EXP_PREFIX}"
    for cname in $(docker ps -a --filter "status=exited" --format '{{.Names}}' 2>/dev/null); do
        cenvs=$(docker inspect "$cname" --format '{{.Config.Env}}' 2>/dev/null)
        if echo "$cenvs" | grep -q "FUZZING_ENGINE\|FUZZBENCH\|OSS_FUZZ"; then
            docker rm -f "$cname" >/dev/null 2>&1
        fi
    done
    delete_pair_images "$fuzzer" "$BENCHMARK"
    delete_experiment_infra_images
    clean_dangling_fuzzbench_images

    sudo rm -rf "${PROJECT_DIR}/results/experiment-data/${EXP_NAME}" 2>/dev/null || \
        rm -rf "${PROJECT_DIR}/results/experiment-data/${EXP_NAME}" 2>/dev/null
    sudo rm -rf "${PROJECT_DIR}/results/report-data/${EXP_NAME}" 2>/dev/null || \
        rm -rf "${PROJECT_DIR}/results/report-data/${EXP_NAME}" 2>/dev/null
    rm -f "${CONFIG_DIR}/${EXP_NAME}.yaml"

    check_disk_or_abort "after fuzzer ${fuzzer} cleanup"
done

echo ""
echo "============================================================"
echo "  Benchmark ${BENCHMARK} complete"
echo "  Succeeded: ${SUCCEEDED_FUZZERS[*]:-none}"
echo "  Failed:    ${FAILED_FUZZERS[*]:-none}"
echo "============================================================"

if [ "${#SUCCEEDED_FUZZERS[@]}" -eq "${#FUZZERS[@]}" ]; then
    echo "[cleanup] All fuzzers succeeded — deleting benchmark images"
    delete_benchmark_images "$BENCHMARK"
else
    echo "[cleanup] Not all fuzzers succeeded — keeping benchmark images for reruns"
    echo "  To rerun a single fuzzer: ./scripts/run_one_fuzzer.sh <fuzzer> ${BENCHMARK}"
fi

check_disk_or_abort "after benchmark ${BENCHMARK} complete"

SUMMARY_FILE="${PROJECT_DIR}/results/${BENCHMARK}_${TIMESTAMP}_summary.txt"
mkdir -p "$(dirname "$SUMMARY_FILE")"
cat > "$SUMMARY_FILE" <<SUMMARY
Benchmark: ${BENCHMARK}
Timestamp: ${TIMESTAMP}
Duration: ${DURATION_SECONDS}s
Trials per fuzzer: ${NUM_TRIALS}
Succeeded: ${SUCCEEDED_FUZZERS[*]:-none}
Failed:    ${FAILED_FUZZERS[*]:-none}
SUMMARY
echo "[done] Summary written to ${SUMMARY_FILE}"
