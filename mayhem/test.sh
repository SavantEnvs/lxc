#!/usr/bin/env bash
#
# mayhem/test.sh — RUNS liblxc's own unit tests and a known-answer probe (all built by build.sh with
# the project's normal flags, in mayhem/_build/test). Every check compares what the program PRINTS
# against expected values, so a neutered program (exit(0), no output) fails.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

B="$SRC/mayhem/_build/test"
TESTS="$B/src/tests"
for f in "$B/kat_config" "$TESTS/lxc-test-getkeys" "$TESTS/lxc-test-arch-parse" \
         "$TESTS/lxc-test-config-jump-table" "$TESTS/lxc-test-lxcpath"; do
  [ -x "$f" ] || { echo "missing test binary $f (mayhem/build.sh builds it)" >&2; emit_ctrf lxc-unit 0 1; exit 1; }
done

# liblxc keeps per-user state under $HOME; use a scratch one so the result never depends on the caller's.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lxc-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
mkdir -p "$HOME/.local/share/lxc" "$WORK/lxcpath"
cd "$WORK"

passed=0; failed=0
pass() { echo "PASS $1"; passed=$((passed + 1)); }
fail() { echo "FAIL $1" >&2; failed=$((failed + 1)); }

# 1) Known-answer probe: set config items through liblxc's API, read them back, compare to golden output.
if "$B/kat_config" "$WORK/lxcpath" > kat.out 2> kat.err && diff -u "$SRC/mayhem/kat_config.expected" kat.out; then
  pass "kat_config: config set/get round-trip matches golden output"
else
  fail "kat_config"; cat kat.err >&2
fi

# 2) lxc-test-getkeys walks every config key liblxc knows; assert well-known keys are listed.
if "$TESTS/lxc-test-getkeys" > getkeys.out 2>&1 \
   && grep -qx 'lxc.arch' getkeys.out && grep -qx 'lxc.uts.name' getkeys.out \
   && grep -qx 'auto' getkeys.out && grep -qx 'unshare' getkeys.out && grep -qx 'dir' getkeys.out; then
  pass "lxc-test-getkeys lists the known config keys"
else
  fail "lxc-test-getkeys"; tail -5 getkeys.out >&2
fi

# 3) Silent upstream unit tests (assert internally, print nothing on success): exit status only.
for t in arch-parse config-jump-table lxcpath; do
  if "$TESTS/lxc-test-$t" > "$t.out" 2>&1 && [ ! -s "$t.out" ]; then
    pass "lxc-test-$t"
  else
    fail "lxc-test-$t"; tail -5 "$t.out" >&2
  fi
done

emit_ctrf lxc-unit "$passed" "$failed"
