#!/usr/bin/env bash
#
# mayhem/test.sh — functional oracle for Tulip Indicators. RUNS upstream's OWN known-answer test
# suite (build-oracle/smoke, produced by mayhem/build.sh). smoke.c drives every indicator/candle
# against reference values from tests/*.txt (Technical Analysis from A to Z, etc.) plus the
# buffer/localbuffer/version unit tests — it ASSERTS computed values, so a PATCH that neuters the
# library to no-op / exit(0) produces no "ALL TESTS PASSED" marker and FAILS here (anti-reward-hack).
#
# This is upstream's real suite, not an authored oracle. We do NOT rely on the process exit code
# alone (the sabotage check LD_PRELOADs a _exit(0) so a broken build would still "exit 0"); we
# require smoke's success marker AND a positive asserted-test count.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "${SRC:-/mayhem}"

BIN=build-oracle/smoke
LOG=/tmp/ti_smoke.log

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}"
  local tests=$(( passed + failed + skipped ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": { "tests": $tests, "passed": $passed, "failed": $failed, "pending": 0, "skipped": $skipped, "other": 0 }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":0,"skipped":%d,"other":0}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$skipped"
  [ "$failed" -eq 0 ]
}

if [ ! -x "$BIN" ]; then
  echo "test.sh: $BIN missing — mayhem/build.sh must build it (not rebuilding here)" >&2
  emit_ctrf minctest 0 1; exit 1
fi

"$BIN" > "$LOG" 2>&1; rc=$?
cat "$LOG"

# smoke prints "ALL TESTS PASSED (N/N)" on success or "M TESTS FAILED (of T)" on failure.
if grep -qE 'ALL TESTS PASSED \([0-9]+/[0-9]+\)' "$LOG" && [ "$rc" -eq 0 ]; then
  total=$(sed -nE 's/.*ALL TESTS PASSED \(([0-9]+)\/[0-9]+\).*/\1/p' "$LOG" | tail -1)
  : "${total:=0}"
  if [ "$total" -lt 1 ]; then
    echo "test.sh: success marker present but 0 tests ran — treating as failure" >&2
    emit_ctrf minctest 0 1; exit 1
  fi
  emit_ctrf minctest "$total" 0
else
  failed=$(sed -nE 's/.*([0-9]+) TESTS FAILED \(of ([0-9]+)\).*/\1/p' "$LOG" | tail -1)
  total=$(sed -nE 's/.*[0-9]+ TESTS FAILED \(of ([0-9]+)\).*/\1/p' "$LOG" | tail -1)
  : "${failed:=1}"; : "${total:=$failed}"
  passed=$(( total - failed )); [ "$passed" -lt 0 ] && passed=0
  emit_ctrf minctest "$passed" "$failed"
fi
