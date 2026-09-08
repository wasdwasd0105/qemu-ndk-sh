#!/usr/bin/env bash
set -euo pipefail

# =====================================================================
# build_all.sh — orchestrate the full Vectras QEMU + SPICE pipeline.
#
# Runs every numbered script in the correct dependency order, tee'ing each
# phase's output to logs/<step>.log so failures are easy to inspect after
# the fact. Fail-fast: any non-zero exit aborts the whole run.
#
# Dependency order (left-to-right = each step needs the ones before it):
#   1 → 1b → 1d → 1e → 1c → 2 → 3
#
#     1   base deps (libffi, pcre2, glib, pixman, sdl2, gmp)
#     1b  SPICE server (opus, openssl, libjpeg-turbo, spice-protocol,
#         spice-server) — consumed by 2_ (QEMU's -Dspice=enabled)
#     1d  GStreamer (libs only) — needed by 1c_ at link time
#     1e  WebDAV (libxml2, libpsl, libsoup-3, libphodav-3) — needed by
#         1c_ when built with -Dwebdav=enabled
#     1c  SPICE client (json-glib, spice-gtk) — consumed by the Android app
#     2   QEMU itself
#     3   stage bin/libs + unversion SONAMEs into opt/qemu/<abi>/
#
# Usage:
#   ./build_all.sh                  # build everything for arm64-v8a
#   APP_ABI=x86_64 ./build_all.sh   # different ABI
#   ./build_all.sh --from 1c        # resume starting at step 1c (1, 1b,
#                                   # 1d, 1e are skipped)
#   ./build_all.sh --only 2,3       # only run steps 2 and 3
#   ./build_all.sh --skip 1d        # run all but skip 1d
#   ./build_all.sh --list           # show step plan and exit
#
# Env vars passed through to children (set them as you'd normally do):
#   NDK_PATH, API_LEVEL, APP_ABI, JOBS, BUILD_ROOT, PREFIX, …
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"

# Step id (used in --from/--only/--skip) → filename. Order here IS the
# execution order, so don't reshuffle without re-reading the dep graph
# in the header.
STEP_IDS=(1   1b  1d  1e  1c  2   3)
STEP_FILES=(
    "1_build_deps_android.sh"
    "1b_build_spice_deps.sh"
    "1d_build_gstreamer_for_android.sh"
    "1e_build_webdav_deps.sh"
    "1c_build_spice_client_deps.sh"
    "2_build_qemu_android.sh"
    "3_retag_so.sh"
)
STEP_DESCS=(
    "base deps (glib/pixman/sdl2/…)"
    "SPICE server"
    "GStreamer (libs only)"
    "WebDAV deps (libsoup/libphodav)"
    "SPICE client (spice-gtk)"
    "QEMU"
    "stage + retag .so"
)

# ---------- arg parse ----------
FROM=""
ONLY=""
SKIP=""
LIST_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --from)  FROM="$2"; shift 2 ;;
        --only)  ONLY="$2"; shift 2 ;;
        --skip)  SKIP="$2"; shift 2 ;;
        --list)  LIST_ONLY=1; shift ;;
        -h|--help)
            sed -n '/^# ====/,/^# ====/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Unknown arg: $1" >&2
            echo "Run with --help for usage." >&2
            exit 2
            ;;
    esac
done

# Allow multiple comma-separated values: "--skip 1d,1e"
csv_contains() {
    local needle="$1" haystack="$2"
    [[ ",$haystack," == *",$needle,"* ]]
}

step_index() {
    local target="$1"
    for i in "${!STEP_IDS[@]}"; do
        if [[ "${STEP_IDS[$i]}" == "$target" ]]; then echo "$i"; return 0; fi
    done
    return 1
}

# Validate --from / --only / --skip refer to known step ids.
validate_ids() {
    local arg_name="$1" arg_val="$2"
    [[ -z "$arg_val" ]] && return 0
    local IFS=','
    for id in $arg_val; do
        if ! step_index "$id" >/dev/null; then
            echo "$arg_name=$id: unknown step id." >&2
            echo "Valid ids: ${STEP_IDS[*]}" >&2
            exit 2
        fi
    done
}
validate_ids "--from" "$FROM"
validate_ids "--only" "$ONLY"
validate_ids "--skip" "$SKIP"

# ---------- plan ----------
START_IDX=0
if [[ -n "$FROM" ]]; then
    START_IDX=$(step_index "$FROM")
fi

PLAN=()
for i in "${!STEP_IDS[@]}"; do
    (( i < START_IDX )) && continue
    id="${STEP_IDS[$i]}"
    if [[ -n "$ONLY" ]] && ! csv_contains "$id" "$ONLY"; then continue; fi
    if [[ -n "$SKIP" ]] && csv_contains "$id" "$SKIP"; then continue; fi
    PLAN+=("$i")
done

# ---------- pretty output ----------
if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; CYAN=$'\033[36m'; GREEN=$'\033[32m'
    RED=$'\033[31m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
    BOLD=""; DIM=""; CYAN=""; GREEN=""; RED=""; YELLOW=""; RESET=""
fi

echo
echo "${BOLD}Vectras QEMU + SPICE build plan${RESET}"
echo "  ABI:  ${APP_ABI:-arm64-v8a}"
echo "  NDK:  ${NDK_PATH:-(default in each script — likely ~/android-ndk-r29)}"
echo "  jobs: ${JOBS:-(auto)}"
echo "  logs: $LOG_DIR/"
echo
printf "  %-4s %-36s %s\n" "id" "script" "description"
printf "  %-4s %-36s %s\n" "----" "------------------------------------" "------------------------------"
for i in "${PLAN[@]}"; do
    printf "  ${CYAN}%-4s${RESET} %-36s %s\n" \
        "${STEP_IDS[$i]}" "${STEP_FILES[$i]}" "${STEP_DESCS[$i]}"
done
if (( ${#PLAN[@]} == 0 )); then
    echo "  ${YELLOW}(nothing to do — filters left the plan empty)${RESET}"
fi
echo

if (( LIST_ONLY )); then exit 0; fi
if (( ${#PLAN[@]} == 0 )); then exit 0; fi

# ---------- run ----------
TOTAL=${#PLAN[@]}
N=0
OVERALL_START=$(date +%s)

for i in "${PLAN[@]}"; do
    N=$((N + 1))
    id="${STEP_IDS[$i]}"
    script="${STEP_FILES[$i]}"
    desc="${STEP_DESCS[$i]}"
    log="$LOG_DIR/${id}_${script%.sh}.log"

    echo "${BOLD}[$N/$TOTAL] $id — $desc${RESET}  ${DIM}(log: $log)${RESET}"
    step_start=$(date +%s)

    # Run the child script in its own shell. tee'd output stays visible
    # on the console AND lands in the log so failures are inspectable
    # after the fact. PIPESTATUS[0] preserves the child's exit code past
    # the tee pipe so set -e still aborts on failure.
    if ( cd "$SCRIPT_DIR" && bash "./$script" ) 2>&1 | tee "$log"; then
        rc="${PIPESTATUS[0]}"
    else
        rc="${PIPESTATUS[0]}"
    fi

    step_end=$(date +%s)
    step_dur=$((step_end - step_start))

    if [[ "$rc" != "0" ]]; then
        echo
        echo "${RED}${BOLD}✘ Step $id failed${RESET} (exit $rc, after ${step_dur}s)"
        echo "  Full output: $log"
        echo "  Tail:"
        tail -n 20 "$log" | sed 's/^/    /'
        exit "$rc"
    fi
    echo "${GREEN}✓ $id done${RESET} (${step_dur}s)"
    echo
done

overall_end=$(date +%s)
total_dur=$((overall_end - OVERALL_START))
mins=$((total_dur / 60))
secs=$((total_dur % 60))
echo "${GREEN}${BOLD}All ${TOTAL} step(s) completed in ${mins}m${secs}s.${RESET}"
echo "Staged output: $SCRIPT_DIR/opt/qemu/${APP_ABI:-arm64-v8a}/"
