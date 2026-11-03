#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's fuzz harness(es). EDIT per repo.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

HARNESSES="fuzz-lxc-cgroup-init fuzz-lxc-config-read fuzz-lxc-define-load"
B="$SRC/mayhem/_build"
rm -rf "$B"
mkdir -p "$B"

# Feature set matches upstream's OSS-Fuzz build (src/tests/oss-fuzz.sh), minus docs/examples (no
# docbook needed) and with the systemd unit dir given explicitly so meson never probes for systemd.
MESON_OPTS=(
  -Dprefix=/usr -Db_lundef=false -Db_lto=false -Db_pie=false -Dwerror=false
  -Dpam-cgroup=false -Dtools=false -Dcommands=false -Dcapabilities=false -Dapparmor=false
  -Dopenssl=false -Dselinux=false -Dseccomp=false -Dthread-safety=false -Ddbus=false
  -Dman=false -Dexamples=false -Dsystemd-unitdir=/lib/systemd/system
)

# 1) Sanitized fuzz build. upstream's meson links the harnesses with `find_library('FuzzingEngine')`
#    (the OSS-Fuzz convention), so provide one: a linker script naming the libFuzzer runtime (fuzz
#    build) or the run-once driver (standalone build), plus the LeakSanitizer-off hook.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$B/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$B/standalone_main.o"
rm -f "$B/libstandalone_main.a"
ar rcs "$B/libstandalone_main.a" "$B/standalone_main.o"   # archive member, so meson's link probe (its own main) still links
FUZZER_RT="$($CC -print-file-name=libclang_rt.fuzzer-x86_64.a)"

# $1 = build name, $2 = engine linker-script body, $3 = extra compile flags
build_fuzz() {
  local name="$1" engine="$2" extra="$3" dir="$B/$1"
  mkdir -p "$dir/engine"
  echo "INPUT($engine $B/lsan_off.o)" > "$dir/engine/libFuzzingEngine.a"
  CFLAGS="-O1 $SANITIZER_FLAGS $DEBUG_FLAGS $extra" \
  CXXFLAGS="-O1 $SANITIZER_FLAGS $DEBUG_FLAGS $extra" \
  LDFLAGS="$SANITIZER_FLAGS -L$dir/engine" \
    meson setup "$dir/out" -Dbuildtype=plain -Doss-fuzz=true -Dtests=false "${MESON_OPTS[@]}"
  ninja -C "$dir/out" -j"$MAYHEM_JOBS" $(for h in $HARNESSES; do echo "src/tests/$h"; done)
}

# libFuzzer coverage (fuzzer-no-link) must instrument the library itself, not just the harness TU.
build_fuzz fuzz "$FUZZER_RT -lstdc++" "-fsanitize=fuzzer-no-link"
build_fuzz standalone "$B/libstandalone_main.a" ""

for h in $HARNESSES; do
  cp "$B/fuzz/out/src/tests/$h" "$SRC/$h"
  cp "$B/standalone/out/src/tests/$h" "$SRC/$h-standalone"
done

# 3) The project's own test suite and a known-answer probe, with NORMAL flags (no sanitizers,
#    no -gdwarf-3, no coverage-for-fuzzing) in a separate build dir so test.sh only RUNS them.
UNIT_TESTS="arch-parse config-jump-table get_item getkeys lxcpath parse-config-file"
CFLAGS="$COVERAGE_FLAGS" CXXFLAGS="$COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" \
  meson setup "$B/test" -Dtests=true "${MESON_OPTS[@]}"
ninja -C "$B/test" -j"$MAYHEM_JOBS" src/lxc/liblxc.a \
  $(for t in $UNIT_TESTS; do echo "src/tests/lxc-test-$t"; done)
$CC -O1 $COVERAGE_FLAGS -I"$B/test/src" "$SRC/mayhem/kat_config.c" "$B/test/src/lxc/liblxc.a" \
  -lcap -lutil -lpthread -o "$B/test/kat_config"
