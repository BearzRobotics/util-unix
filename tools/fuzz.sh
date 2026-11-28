#!/bin/sh
# fuzz.sh [ITERATIONS] [SEED]
#
# The only supported way to run a fuzz campaign (decision 0010). It runs `zig build fuzz`
# with FUZZ_ITERATIONS mutations per target inside a transient systemd scope that has a
# memory cap and a wall-clock limit; when either is hit systemd kills every process in
# the scope. Without the scope a runaway test binary can eat all memory, and the kernel's
# out-of-memory kill then takes the whole terminal session with it (it happened twice).
#
#   FUZZ_MEM       memory cap for the run                (default 3G)
#   FUZZ_SECONDS   wall-clock limit                      (default 600)
#   FUZZ_FINDINGS  where failing inputs are saved        (default ./fuzz-findings)
#   FUZZ_CURRENT   file holding the input being run; after a crash or hang it IS the
#                  reproducer                            (default ./fuzz-current.bin)
#
# Examples:  sh tools/fuzz.sh                  # 20000 iterations per target
#            sh tools/fuzz.sh 1000000 7        # longer, different seed
iters=${1:-20000}
seed=${2:-1}
mem=${FUZZ_MEM:-3G}
secs=${FUZZ_SECONDS:-600}
export FUZZ_ITERATIONS="$iters" FUZZ_SEED="$seed"
export FUZZ_FINDINGS="${FUZZ_FINDINGS:-$PWD/fuzz-findings}"
export FUZZ_CURRENT="${FUZZ_CURRENT:-$PWD/fuzz-current.bin}"
command -v systemd-run >/dev/null 2>&1 || { echo "fuzz.sh: systemd-run is required (it provides the memory cap)" >&2; exit 125; }
rm -f "$FUZZ_CURRENT"
systemd-run --user --scope --quiet --collect --setenv=FUZZ_ITERATIONS --setenv=FUZZ_SEED \
    --setenv=FUZZ_FINDINGS --setenv=FUZZ_CURRENT \
    -p MemoryMax="$mem" -p MemorySwapMax=0 -p RuntimeMaxSec="$secs" \
    zig build fuzz
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "fuzz.sh: failed (exit $rc). Findings: $FUZZ_FINDINGS ; last input run (reproducer after a crash/hang): $FUZZ_CURRENT" >&2
fi
left=$(ps -eo comm | grep -c '^test$')
[ "$left" -gt 0 ] && echo "fuzz.sh: WARNING: $left leftover 'test' process(es) running; stop them by pid" >&2
exit $rc
