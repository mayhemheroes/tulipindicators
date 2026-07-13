#!/usr/bin/env bash
#
# mayhem/build.sh — build the Tulip Indicators fuzz target and the functional oracle.
#
# Tulip Indicators is a C99 library of ~104 technical-analysis indicators. The library sources
# (indicators.c, candles.c, indicators/*.c, utils/*.c) plus the generated headers are committed,
# so the build needs no code generation (no tclsh) and no network.
#
# We build:
#   /mayhem/cli              sanitized in-process libFuzzer harness over the indicator library
#                            (target name `cli`, preserving the historical Mayhem target).
#   /mayhem/cli-standalone   run-once reproducer (LLVM StandaloneFuzzTargetMain, no libFuzzer rt).
#   build-oracle/smoke       clean (unsanitized) build of upstream's own known-answer test suite,
#                            which mayhem/test.sh RUNS as the functional oracle.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs from the environment (base image exports the defaults); fall back for a bare run.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-gdwarf-3}"
: "${CC:=clang}"
: "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
# The base's SANITIZER_FLAGS carries a plain -g (DWARF-5 under clang-19); force DWARF-3 for triage.
DEBUG_FLAGS="$DEBUG_FLAGS -gdwarf-3"
export SANITIZER_FLAGS DEBUG_FLAGS CC LIB_FUZZING_ENGINE STANDALONE_FUZZ_MAIN MAYHEM_JOBS COVERAGE_FLAGS

cd "${SRC:-/mayhem}"

LIB_SRCS=(indicators.c candles.c indicators/*.c utils/*.c)

# 1) Sanitized library objects — the PROJECT ITSELF is instrumented so ASan/UBSan see bugs
#    inside the indicator code, not just the harness. DWARF < 4 for Mayhem triage.
mkdir -p build-san
san_objs=()
for src in "${LIB_SRCS[@]}"; do
  obj="build-san/$(echo "$src" | tr '/' '_').o"
  # shellcheck disable=SC2086
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -std=c99 -I. -c "$src" -o "$obj"
  san_objs+=("$obj")
done

# 2) libFuzzer target -> /mayhem/cli  (target name `cli`)
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -std=c99 -I. \
    mayhem/fuzz_indicators.c "${san_objs[@]}" $LIB_FUZZING_ENGINE -lm \
    -o /mayhem/cli

# 3) standalone reproducer (no libFuzzer runtime; reads one input file) -> /mayhem/cli-standalone
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -std=c99 -I. \
    mayhem/fuzz_indicators.c "$STANDALONE_FUZZ_MAIN" "${san_objs[@]}" -lm \
    -o /mayhem/cli-standalone

# 4) Clean oracle build (NO sanitizers) of upstream's own test suite so mayhem/test.sh only RUNS it.
#    smoke.c is the full known-answer suite (buffer/localbuffer/version + tests/*.txt).
mkdir -p build-oracle
oracle_objs=()
for src in "${LIB_SRCS[@]}"; do
  obj="build-oracle/$(echo "$src" | tr '/' '_').o"
  # shellcheck disable=SC2086
  $CC -O2 $COVERAGE_FLAGS -std=c99 -I. -c "$src" -o "$obj"
  oracle_objs+=("$obj")
done
# shellcheck disable=SC2086
$CC -O2 $COVERAGE_FLAGS -std=c99 -I. smoke.c "${oracle_objs[@]}" -lm -o build-oracle/smoke

echo "build.sh: built /mayhem/cli (libFuzzer) + /mayhem/cli-standalone + build-oracle/smoke"
