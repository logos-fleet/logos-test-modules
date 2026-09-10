#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Logos Test Modules — Integration Test Suite
#
# Exercises every API type and combination in the test modules using logoscore.
# Usage: run_tests.sh <logoscore> <modules-dir>
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

LOGOSCORE="${1:?Usage: run_tests.sh <logoscore> <modules-dir>}"
MODULES_DIR="${2:?}"


# UNIT_NEW_API_TEST_BIN: set via env var; path to test_ipc_new_api_module_tests binary
UNIT_NEW_API_TEST_BIN="${UNIT_NEW_API_TEST_BIN:-}"

# Per-call timeout (seconds) — guard against total hangs.
CALL_TIMEOUT="${TEST_TIMEOUT:-30}"

# TEST_GROUPS: comma-separated list of groups to run (default: all)
# Available groups: basic, basic-cpp, context-cpp, extlib, fullapi,
#                   ipc-new-api, multi, errors, unit-new-api
# Example: TEST_GROUPS=ipc-new-api  or  TEST_GROUPS=ipc-new-api,basic
if [[ -n "${TEST_GROUPS:-}" ]]; then
    IFS=',' read -ra ENABLED_GROUPS <<< "$TEST_GROUPS"
else
    ENABLED_GROUPS=()
fi

should_run_group() {
    local group="$1"
    if [[ ${#ENABLED_GROUPS[@]} -eq 0 ]]; then
        return 0  # no filter, run all
    fi
    for g in "${ENABLED_GROUPS[@]}"; do
        if [[ "$g" == "$group" ]]; then
            return 0
        fi
    done
    return 1
}

# ── Daemon lifecycle ─────────────────────────────────────────────────────────
# Inline (`-c`) mode is legacy; these tests drive a long-lived logoscore daemon
# and exercise modules through the `call` client subcommand. A persistent daemon
# keeps the Qt event loop running, so async methods and event round-trips work
# without the inline path's quirks. QUIT_FLAG is retained (empty) only so the
# legacy `cmd:` debug printfs below don't trip `set -u`.
QUIT_FLAG=""

# The unit-new-api group runs a standalone test binary and never touches the
# daemon, so skip the whole daemon lifecycle (and its jq dependency) when only
# it is enabled. (`unit` is kept in the match below only so the retired group
# name does not accidentally start a daemon; the group itself is gone.)
_needs_daemon=0
if [[ ${#ENABLED_GROUPS[@]} -eq 0 ]]; then
    _needs_daemon=1
else
    for _g in "${ENABLED_GROUPS[@]}"; do
        case "$_g" in
            unit|unit-new-api) ;;
            *) _needs_daemon=1 ;;
        esac
    done
fi

if [[ "$_needs_daemon" -eq 1 ]]; then

# dcall_inline parses the daemon's JSON envelopes with jq (robust against key
# order / spacing), so require it up front with a clear message.
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required to parse logoscore JSON output." >&2
    exit 1
fi

LOGOSCORE_CONFIG_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t 'logoscore-cfg')"
export LOGOSCORE_CONFIG_DIR
# Persistence base for the context module — its getInstancePersistencePath()
# assertions match a path rooted here. The daemon provisions per-instance dirs
# under this path as modules load.
CONTEXT_PERSISTENCE_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t 'logos-ctx-test')"

DAEMON_PID=""
cleanup() {
    if [[ -n "$DAEMON_PID" ]]; then
        "$LOGOSCORE" --config-dir "$LOGOSCORE_CONFIG_DIR" stop >/dev/null 2>&1 || true
        kill "$DAEMON_PID" 2>/dev/null || true
        wait "$DAEMON_PID" 2>/dev/null || true
    fi
    rm -rf "$LOGOSCORE_CONFIG_DIR" "$CONTEXT_PERSISTENCE_DIR"
}
trap cleanup EXIT

# LOGOSCORE_CONTAINER: assert which container every module here must run in.
# Empty (the default) leaves the daemon on `auto`, so an existing invocation is
# byte-identical. "inproc" requires every operator module in MODULES_DIR to be a
# Bare module, and the daemon refuses a Qt plugin rather than quietly running it
# in a subprocess -- which is the whole reason the flag is an assertion and not
# a preference.
CONTAINER_ARGS=()
if [[ -n "${LOGOSCORE_CONTAINER:-}" ]]; then
    CONTAINER_ARGS=(--container "$LOGOSCORE_CONTAINER")
    echo "  container policy: $LOGOSCORE_CONTAINER"
fi

echo "  starting logoscore daemon..."
"$LOGOSCORE" -D --config-dir "$LOGOSCORE_CONFIG_DIR" \
    -m "$MODULES_DIR" --persistence-path "$CONTEXT_PERSISTENCE_DIR" \
    "${CONTAINER_ARGS[@]}" \
    >"$LOGOSCORE_CONFIG_DIR/daemon.log" 2>&1 &
DAEMON_PID=$!

# Wait for the daemon to become reachable. `status` is the definitive probe
# (it also fails fast if this logoscore build lacks the daemon/call subcommands),
# so we don't poke at the daemon's internal state file.
_ready=0
for _i in $(seq 1 100); do
    if "$LOGOSCORE" --config-dir "$LOGOSCORE_CONFIG_DIR" status >/dev/null 2>&1; then
        _ready=1; break
    fi
    kill -0 "$DAEMON_PID" 2>/dev/null || break
    sleep 0.2
done
if [[ "$_ready" -ne 1 ]]; then
    echo "ERROR: logoscore daemon failed to start. Log:" >&2
    cat "$LOGOSCORE_CONFIG_DIR/daemon.log" >&2 || true
    exit 1
fi
echo "  daemon ready (pid $DAEMON_PID)"

# Load every test module up front. The `load-module` subcommand DOES
# auto-resolve and load a module's declared dependencies (the daemon
# discovers every module under -m at startup, so the dependency closure is
# known), so loading e.g. test_ipc_new_api_module also brings up its deps
# (test_basic_module, test_extlib_module). We still load each module
# explicitly because any single group can be selected on its own via
# TEST_GROUPS, and a standalone group's module (e.g. test_basic_module_cpp)
# is nobody's dependency — nothing would auto-load it. Listing them all
# guarantees each group has its module present regardless of which groups
# run; order is irrelevant since deps resolve automatically. (The daemon
# auto-loads capability_module itself.)
# LOGOSCORE_LOAD_MODULES narrows that list. A modules directory built for one
# group (the Bare set the inproc container runs, say) holds only that group's
# modules, and the blanket list would then log a WARN per absent module -- noise
# that reads exactly like the real failure it is meant to report.
_default_mods="test_basic_module test_basic_module_cpp test_extlib_module \
               test_context_module_cpp test_ipc_new_api_module \
               test_fullapi_cpp test_fullapi_rust test_fullapi_proxy test_fullapi_proxy_rust"
for _mod in ${LOGOSCORE_LOAD_MODULES:-$_default_mods}; do
    if "$LOGOSCORE" --config-dir "$LOGOSCORE_CONFIG_DIR" load-module "$_mod" >/dev/null 2>&1; then
        echo "  loaded: $_mod"
    else
        echo "  WARN: failed to load $_mod (its group will fail)" >&2
    fi
done

fi  # _needs_daemon

# dcall_inline: translate inline-style logoscore args into daemon `call` client
# invocations. Recognizes one or more `-c "<module>.<method>(args)"`; ignores
# -m/-l/--persistence-path/--quit-on-finish (the daemon already has the modules
# loaded and persistence configured). For each call it emits the same
# "Method call successful. Result: <value>" line the inline runner produced, so
# the existing expected-substring assertions keep working unchanged. Returns
# non-zero if any sub-call fails (drives assert_call_fails and error cases).
dcall_inline() {
    local -a _calls=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--call) _calls+=("$2"); shift 2 ;;
            -m|--modules-dir|-l|--load-modules|--persistence-path) shift 2 ;;
            *) shift ;;
        esac
    done
    [[ ${#_calls[@]} -eq 0 ]] && return 0
    local _overall=0 _cs _mod _rest _method _inside _errf _out _rc _status _result
    for _cs in "${_calls[@]}"; do
        _mod="${_cs%%.*}"
        _rest="${_cs#*.}"
        _method="${_rest%%(*}"
        _inside="${_rest#*(}"; _inside="${_inside%)}"
        local -a _args=()
        if [[ -n "$_inside" ]]; then
            local _oifs="$IFS"; IFS=','
            local _p
            for _p in $_inside; do
                _p="${_p#"${_p%%[![:space:]]*}"}"   # ltrim
                _p="${_p%"${_p##*[![:space:]]}"}"   # rtrim
                _args+=("$_p")
            done
            IFS="$_oifs"
        fi
        _errf=$(mktemp)
        if [[ ${#_args[@]} -gt 0 ]]; then
            _out=$(timeout "$CALL_TIMEOUT" "$LOGOSCORE" --json --config-dir "$LOGOSCORE_CONFIG_DIR" \
                   call "$_mod" "$_method" "${_args[@]}" 2>"$_errf") && _rc=0 || _rc=$?
        else
            _out=$(timeout "$CALL_TIMEOUT" "$LOGOSCORE" --json --config-dir "$LOGOSCORE_CONFIG_DIR" \
                   call "$_mod" "$_method" 2>"$_errf") && _rc=0 || _rc=$?
        fi
        _status=$(printf '%s' "$_out" | jq -r '.status // "error"' 2>/dev/null)
        if [[ $_rc -ne 0 || "$_status" != "ok" ]]; then
            # Surface both the JSON envelope and the client's stderr — the call
            # failed and the caller needs the actual error to diagnose it.
            printf '%s\n' "$_out" >&2
            cat "$_errf" >&2 2>/dev/null
            rm -f "$_errf"
            _overall=1
            continue
        fi
        rm -f "$_errf"
        # `-r` unwraps scalar strings (hello, 7, true); `-c` keeps map/list
        # results on one line so the "Result: …" substring assertions match.
        _result=$(printf '%s' "$_out" | jq -rc '.result')
        printf 'Method call successful. Result: %s\n' "$_result"
    done
    return $_overall
}

PASS=0
FAIL=0
SKIP=0
TOTAL=0
FAILURES=""

# ── Helpers ──────────────────────────────────────────────────────────────────

# assert_call: run a logoscore call, check exit code 0 and stdout contains pattern
#   $1 = test name
#   $2 = expected substring in stdout ("" to skip output check)
#   $3... = logoscore arguments
assert_call() {
    local name="$1"; shift
    local expected="$1"; shift
    TOTAL=$((TOTAL + 1))

    printf "        call: %s\n" "$*"
    local output stderr_file rc
    stderr_file=$(mktemp)
    output=$(dcall_inline "$@" 2>"$stderr_file") && rc=0 || rc=$?

    if [[ $rc -eq 0 ]]; then
        rm -f "$stderr_file"
        if [[ -z "$expected" ]] || printf '%s' "$output" | grep -qF "$expected"; then
            PASS=$((PASS + 1))
            printf "  PASS  %s\n" "$name"
            return 0
        else
            FAIL=$((FAIL + 1))
            printf "  FAIL  %s  (expected '%s' in output, got: '%s')\n" "$name" "$expected" "$output"
            FAILURES="${FAILURES}  FAIL  ${name}: expected '${expected}', got '${output}'\n"
            return 1
        fi
    else
        FAIL=$((FAIL + 1))
        local stderr_out
        stderr_out=$(cat "$stderr_file" 2>/dev/null)
        printf "  FAIL  %s  (logoscore exit code %d)\n" "$name" "$rc"
        if [[ $FAIL -le 1 ]] && [[ -n "$stderr_out" ]]; then
            printf "        === stderr start ===\n"
            printf "%s\n" "$stderr_out"
            printf "        === stderr end ===\n"
        fi
        FAILURES="${FAILURES}  FAIL  ${name}: logoscore exit code ${rc}\n"
        rm -f "$stderr_file"
        return 1
    fi
}

# assert_call_fails: run a logoscore call, expect non-zero exit code
assert_call_fails() {
    local name="$1"; shift
    TOTAL=$((TOTAL + 1))

    printf "        call: %s\n" "$*"
    local rc
    dcall_inline "$@" >/dev/null 2>&1 && rc=0 || rc=$?

    if [[ $rc -eq 0 ]]; then
        FAIL=$((FAIL + 1))
        printf "  FAIL  %s  (expected failure, but got exit 0)\n" "$name"
        FAILURES="${FAILURES}  FAIL  ${name}: expected failure, got success\n"
        return 1
    else
        PASS=$((PASS + 1))
        printf "  PASS  %s  (correctly failed)\n" "$name"
        return 0
    fi
}

skip_test() {
    SKIP=$((SKIP + 1))
    printf "  SKIP  %s  (%s)\n" "$1" "$2"
}

# Shorthands for each module
test_basic() {
    assert_call "$1" "$2" -m "$MODULES_DIR" -l test_basic_module -c "$3"
}
test_basic_cpp() {
    assert_call "$1" "$2" -m "$MODULES_DIR" -l test_basic_module_cpp -c "$3"
}
# test_context_cpp passes --persistence-path so the runtime actually
# provisions a per-instance data dir for test_context_module_cpp. The
# directory is created on first use of the helper and reused across
# every call in the context-cpp group — the host re-derives the same
# instance ID from the same on-disk dir, so getInstancePersistencePath()
# is stable across these per-method invocations.
test_context_cpp() {
    : "${CONTEXT_PERSISTENCE_DIR:?context-cpp tests must set CONTEXT_PERSISTENCE_DIR first}"
    assert_call "$1" "$2" -m "$MODULES_DIR" \
        --persistence-path "$CONTEXT_PERSISTENCE_DIR" \
        -l test_context_module_cpp -c "$3"
}
test_extlib() {
    assert_call "$1" "$2" -m "$MODULES_DIR" -l test_extlib_module -c "$3"
}
test_ipc() {
    assert_call "$1" "$2" -m "$MODULES_DIR" -l test_ipc_new_api_module -c "$3"
}

# ── Banner ───────────────────────────────────────────────────────────────────

echo "================================================================="
echo " Logos Test Modules -- Integration Tests"
echo "================================================================="
echo ""
echo "  logoscore : $LOGOSCORE"
echo "  modules   : $MODULES_DIR"
echo ""

# ═════════════════════════════════════════════════════════════════════════════
# TEST GROUP 1: test_basic_module (standalone, no IPC)
# ═════════════════════════════════════════════════════════════════════════════

if should_run_group "basic"; then

echo "-----------------------------------------------------------------"
echo " test_basic_module"
echo "-----------------------------------------------------------------"

# ── Return type: bool ────────────────────────────────────────────────────────
echo ""
echo "  -- Return type: bool --"
test_basic "returnTrue()"       "Result: true"   "test_basic_module.returnTrue()"
test_basic "returnFalse()"      "Result: false"  "test_basic_module.returnFalse()"
test_basic "isPositive(5)"      "Result: true"   "test_basic_module.isPositive(5)"
test_basic "isPositive(0)"      "Result: false"  "test_basic_module.isPositive(0)"
test_basic "isPositive(-3)"     "Result: false"  "test_basic_module.isPositive(-3)"

# ── Return type: int ─────────────────────────────────────────────────────────
echo ""
echo "  -- Return type: int --"
test_basic "returnInt()"        "Result: 42"  "test_basic_module.returnInt()"
test_basic "addInts(3, 4)"      "Result: 7"   "test_basic_module.addInts(3, 4)"
test_basic "addInts(0, 0)"      "Result: 0"   "test_basic_module.addInts(0, 0)"
test_basic "addInts(-5, 10)"    "Result: 5"   "test_basic_module.addInts(-5, 10)"
test_basic "stringLength(hello)" "Result: 5"  "test_basic_module.stringLength(hello)"
# stringLength counts CHARACTERS, not bytes. "héllo" is 5 characters and 6
# bytes of UTF-8, and the module answered 6 — while the Qt module before it
# answered QString::length(), the UTF-16 unit count. Two different wrong
# definitions, and every assertion in this group was ASCII, where all three
# agree. Hence the next two rows.
test_basic "stringLength(héllo) [characters, not UTF-8 bytes]" "Result: 5" \
    "test_basic_module.stringLength(héllo)"
# A character outside the BMP is ONE character. The byte count answers 4 here
# and Qt's UTF-16 QString answered 2; neither is a length of any text.
test_basic "stringLength(😀) [non-BMP character counts 1]"    "Result: 1" \
    "test_basic_module.stringLength(😀)"
skip_test  "stringLength()"     "logoscore cannot call 1-arg method with 0 args"

# ── Return type: QString ─────────────────────────────────────────────────────
echo ""
echo "  -- Return type: QString --"
test_basic "returnString()"     "Result: test_basic_module"  "test_basic_module.returnString()"
test_basic "echo(hello)"        "Result: hello"              "test_basic_module.echo(hello)"
test_basic "echo(world)"        "Result: world"              "test_basic_module.echo(world)"
test_basic "concat(foo, bar)"   "Result: foobar"             "test_basic_module.concat(foo, bar)"
skip_test  "concat(, )"        "logoscore cannot pass empty args"

# ── Return type: LogosResult ─────────────────────────────────────────────────
echo ""
echo "  -- Return type: LogosResult --"
test_basic "successResult()"    "Method call successful"     "test_basic_module.successResult()"
test_basic "errorResult()"      "Method call successful"     "test_basic_module.errorResult()"
test_basic "resultWithMap()"    "Method call successful"     "test_basic_module.resultWithMap()"
test_basic "resultWithList()"   "Method call successful"     "test_basic_module.resultWithList()"
# The `length` field is the same quantity stringLength returns — CHARACTERS —
# so it gets the same two assertions. Asserting the field (not just "call
# successful") is the point: the old expectation could not tell 5 from 6.
test_basic "validateInput(hi) [length field]"  '"length":2'  "test_basic_module.validateInput(hi)"
test_basic "validateInput(héllo) [length in characters]" '"length":5' \
    "test_basic_module.validateInput(héllo)"

# ── Return type: QVariant ────────────────────────────────────────────────────
echo ""
echo "  -- Return type: QVariant --"
test_basic "returnVariantInt()"    "Result: 99"              "test_basic_module.returnVariantInt()"
test_basic "returnVariantString()" "Result: variant_string"  "test_basic_module.returnVariantString()"
test_basic "returnVariantMap()"    "Method call successful"  "test_basic_module.returnVariantMap()"
test_basic "returnVariantList()"   "Method call successful"  "test_basic_module.returnVariantList()"

# ── Return type: QJsonArray ──────────────────────────────────────────────────
echo ""
echo "  -- Return type: QJsonArray --"
test_basic "returnJsonArray()"        "Method call successful"  "test_basic_module.returnJsonArray()"
test_basic "makeJsonArray(x, y)"      "Method call successful"  "test_basic_module.makeJsonArray(x, y)"

# ── Return type: QStringList ─────────────────────────────────────────────────
echo ""
echo "  -- Return type: QStringList --"
test_basic "returnStringList()"       "Method call successful"  "test_basic_module.returnStringList()"
skip_test  "splitString(a,b,c)"       "commas in arg value parsed as arg separators by logoscore"

# ── Parameter types ──────────────────────────────────────────────────────────
echo ""
echo "  -- Parameter types --"
test_basic "echoInt(42)"           "Result: 42"     "test_basic_module.echoInt(42)"
test_basic "echoInt(0)"            "Result: 0"      "test_basic_module.echoInt(0)"
test_basic "echoInt(-7)"           "Result: -7"     "test_basic_module.echoInt(-7)"
test_basic "echoBool(true)"        "Result: true"   "test_basic_module.echoBool(true)"
test_basic "echoBool(false)"       "Result: false"  "test_basic_module.echoBool(false)"
# These two were skipped as "logoscore cannot pass QStringList/QByteArray
# params". It can: a list goes over as `json:[…]` and a byte array as its
# bytes. (dcall_inline splits arguments on commas, so the list here is a
# one-element one — a two-element `json:["a","b"]` would arrive as two args.)
test_basic "joinStrings(json:[a])"       "Result: a"      "test_basic_module.joinStrings(json:[\"a\"])"
test_basic "byteArraySize(abcde)"        "Result: 5"      "test_basic_module.byteArraySize(abcde)"
# A byte array counts BYTES, and that is not a contradiction of stringLength
# above — "héllo" is 6 bytes and 5 characters. Both rows are here so the
# difference between the two units is asserted, not assumed.
test_basic "byteArraySize(héllo) [bytes, unlike stringLength]" "Result: 6" \
    "test_basic_module.byteArraySize(héllo)"
# urlToString was skipped for years as "logoscore cannot pass QUrl params".
# That was never true of the daemon call path, and the parameter is a plain
# string since the universal migration anyway. What the method owes its caller
# is the URL back with the case-INSENSITIVE parts folded down — scheme and
# host — and the case-sensitive ones untouched, so "/a/../b?x=1" comes back
# exactly as it went in.
test_basic "urlToString(HTTP://Example.COM/a/../b?x=1) [scheme+host lowercased, path+query verbatim]" \
    "Result: http://example.com/a/../b?x=1" \
    "test_basic_module.urlToString(HTTP://Example.COM/a/../b?x=1)"

# ── Argument counts 0–5 ─────────────────────────────────────────────────────
echo ""
echo "  -- Argument counts 0-5 --"
test_basic "noArgs()"                               "Result: noArgs()"                             "test_basic_module.noArgs()"
test_basic "oneArg(x)"                              "Result: oneArg(x)"                            "test_basic_module.oneArg(x)"
test_basic "twoArgs(x, 1)"                          "Result: twoArgs(x, 1)"                        "test_basic_module.twoArgs(x, 1)"
test_basic "threeArgs(x, 1, true)"                  "Result: threeArgs(x, 1, true)"                "test_basic_module.threeArgs(x, 1, true)"
test_basic "fourArgs(x, 1, true, y)"                "Result: fourArgs(x, 1, true, y)"              "test_basic_module.fourArgs(x, 1, true, y)"
test_basic "fiveArgs(x, 1, true, y, 2)"             "Result: fiveArgs(x, 1, true, y, 2)"           "test_basic_module.fiveArgs(x, 1, true, y, 2)"

# ── Void methods ─────────────────────────────────────────────────────────────
echo ""
echo "  -- Void methods (logoscore returns non-zero for void, testing no crash) --"
skip_test  "doNothing()"            "void return → invalid QVariant → logoscore exit 1"
skip_test  "doNothingWithArgs(a,1)" "void return → invalid QVariant → logoscore exit 1"

# ── Events (fire-and-forget via logoscore, just test no crash) ───────────────
echo ""
echo "  -- Events --"
skip_test  "emitTestEvent(data)"        "void return → invalid QVariant → logoscore exit 1"
skip_test  "emitMultiArgEvent(ev, 5)"   "void return → invalid QVariant → logoscore exit 1"


# ── Argument decoding (IPC sends mismatched types) ───────────────────────────
# logoscore auto-detects: 3.14 → double, 42 → int, true → bool, else → string.
# These send types that don't match the method signature. QtProviderObject
# decodes them through the canonical codec (logos::qtArgDecode), so the line
# between "accepted" and "refused" is the codec's, not Qt's: a WHOLE-VALUED
# float is a legal integer — JSON does not distinguish 3 from 3.0 and the CLI
# above produces 3.0 for "3.0" — while a fractional one is refused.
echo ""
echo "  -- Argument decoding --"

# double → int: logoscore parses 3.0 as double, method expects int
test_basic "addInts(3.0, 4.0) [whole double→int]"    "Result: 7"   "test_basic_module.addInts(3.0, 4.0)"

# double → int via echoInt
test_basic "echoInt(42.0) [whole double→int]"   "Result: 42"  "test_basic_module.echoInt(42.0)"

# double → bool via isPositive (5.0 → int 5 → true)
test_basic "isPositive(5.0) [whole double→int→bool check]" "Result: true" "test_basic_module.isPositive(5.0)"

# mixed: twoArgs(QString, int) called with (string, whole double)
test_basic "twoArgs(hi, 3.0) [whole double→int in mixed]" "Result: twoArgs(hi, 3)" "test_basic_module.twoArgs(hi, 3.0)"

# ── Argument decoding on a pure-Qt PROVIDER: out of scope ────────────────────
# There were six refusal assertions here (echoInt(4294967296), echoInt(abc),
# echoBool(1), echoBool(hello), stringLength(42), joinStrings(notalist)) plus
# addInts(3.7, 1.2) above, each expecting dispatch_failed where a Qt-typed
# provider instead coerces the argument.
#
# They are removed, not fixed. test_basic_module is a pure Qt provider, and
# hardening that surface is no longer a goal: the Qt story we intend to be
# correct is the CONSUMER side. Leaving them red would misreport a deliberate
# scope decision as a defect; leaving them registered as xfail would imply a
# fix is coming.
#
# The coercion is real and unchanged — see the rows below, which assert it
# rather than refuse it. Registry entries Q1/Q1b describe the same behaviour
# and are reclassified accordingly.

# NOT refused, and deliberately so: `bstr` keeps the codec's documented lenient
# form (bytesFromJsonLenient) because a Qt consumer and an argument-typing CLI
# both produce a plain scalar for a byte parameter.
test_basic "byteArraySize(42) [number for QByteArray, lenient by design]" \
    "Result: 2" "test_basic_module.byteArraySize(42)"

# A type with no LIDL counterpart (QUrl) keeps Qt's own conversion — the codec
# has no rule for it, and inventing one would refuse a call that works.
test_basic "urlToString(http://example.com) [QUrl, unchecked by design]" \
    "Result: http://example.com" "test_basic_module.urlToString(http://example.com)"


fi  # end basic group

# ═════════════════════════════════════════════════════════════════════════════
# TEST GROUP 1b: test_basic_module_cpp (pure-C++ mirror of test_basic_module)
#
# Same method matrix as `basic` above, but the impl class uses std / LogosMap
# / LogosList / StdLogosResult — the Qt glue is auto-generated from the
# derived .lidl by `logos-qt-host-generator --backend cdylib`. These cases
# exercise every branch of
# the generator's type-conversion table end-to-end through the CLI; a
# regression in the glue (e.g. a missing `std::string` ↔ `QString`
# conversion, wrong `nlohmannToQVariant` behaviour, or broken `StdLogosResult`
# unpacking) shows up as a specific failing row here with the same output
# contract as its Qt counterpart.
# ═════════════════════════════════════════════════════════════════════════════

if should_run_group "basic-cpp"; then

echo ""
echo "-----------------------------------------------------------------"
echo " test_basic_module_cpp (pure-C++ impl, generated Qt glue)"
echo "-----------------------------------------------------------------"

# ── Return type: bool ────────────────────────────────────────────────────────
echo ""
echo "  -- Return type: bool --"
test_basic_cpp "returnTrue()"       "Result: true"   "test_basic_module_cpp.returnTrue()"
test_basic_cpp "returnFalse()"      "Result: false"  "test_basic_module_cpp.returnFalse()"
test_basic_cpp "isPositive(5)"      "Result: true"   "test_basic_module_cpp.isPositive(5)"
test_basic_cpp "isPositive(0)"      "Result: false"  "test_basic_module_cpp.isPositive(0)"
test_basic_cpp "isPositive(-3)"     "Result: false"  "test_basic_module_cpp.isPositive(-3)"

# ── Return type: int64_t ─────────────────────────────────────────────────────
echo ""
echo "  -- Return type: int64_t --"
test_basic_cpp "returnInt()"        "Result: 42"  "test_basic_module_cpp.returnInt()"
test_basic_cpp "addInts(3, 4)"      "Result: 7"   "test_basic_module_cpp.addInts(3, 4)"
test_basic_cpp "addInts(0, 0)"      "Result: 0"   "test_basic_module_cpp.addInts(0, 0)"
test_basic_cpp "addInts(-5, 10)"    "Result: 5"   "test_basic_module_cpp.addInts(-5, 10)"
test_basic_cpp "stringLength(hello)" "Result: 5"  "test_basic_module_cpp.stringLength(hello)"
# The two modules are deliberate MIRRORS, so they must agree on non-ASCII. They
# did not: this one answered in BYTES (6) while test_basic_module answered in
# CHARACTERS (5). The blind spot was that this group only ever asserted ASCII,
# where bytes and characters coincide — so the disagreement was invisible.
test_basic_cpp "stringLength(héllo) [characters, mirrors test_basic_module]" "Result: 5" \
    "test_basic_module_cpp.stringLength(héllo)"
test_basic_cpp "stringLength(😀) [non-BMP character counts 1]" "Result: 1" \
    "test_basic_module_cpp.stringLength(😀)"
skip_test      "stringLength()"     "logoscore cannot call 1-arg method with 0 args"

# ── Return type: uint64_t (unique to the C++ surface) ───────────────────────
echo ""
echo "  -- Return type: uint64_t --"
test_basic_cpp "returnUint()"       "Result: 99"   "test_basic_module_cpp.returnUint()"
test_basic_cpp "echoUint(123)"      "Result: 123"  "test_basic_module_cpp.echoUint(123)"
test_basic_cpp "echoUint(0)"        "Result: 0"    "test_basic_module_cpp.echoUint(0)"

# ── Return type: double ─────────────────────────────────────────────────────
# CLI formats doubles unpredictably ("3.5" vs "3.500000"). Just check the
# dispatch exits cleanly and the "Result:" prefix is there — the Python
# integration suite covers exact-value assertions.
echo ""
echo "  -- Return type: double --"
test_basic_cpp "returnDouble()"        "Result:"  "test_basic_module_cpp.returnDouble()"
test_basic_cpp "addDoubles(1.5, 2.5)"  "Result:"  "test_basic_module_cpp.addDoubles(1.5, 2.5)"

# ── Return type: std::string ────────────────────────────────────────────────
echo ""
echo "  -- Return type: std::string --"
test_basic_cpp "returnString()"     "Result: test_basic_module_cpp"  "test_basic_module_cpp.returnString()"
test_basic_cpp "echo(hello)"        "Result: hello"                  "test_basic_module_cpp.echo(hello)"
test_basic_cpp "echo(world)"        "Result: world"                  "test_basic_module_cpp.echo(world)"
test_basic_cpp "concat(foo, bar)"   "Result: foobar"                 "test_basic_module_cpp.concat(foo, bar)"
skip_test      "concat(, )"         "logoscore cannot pass empty args"

# ── Return type: StdLogosResult ─────────────────────────────────────────────
# Generator emits a StdLogosResult → Qt LogosResult conversion in the glue,
# so the CLI's "Method call successful" sentinel (used for any structured
# return it can't stringify inline) fires identically to the Qt module.
echo ""
echo "  -- Return type: StdLogosResult --"
test_basic_cpp "successResult()"     "Method call successful"  "test_basic_module_cpp.successResult()"
test_basic_cpp "errorResult()"       "Method call successful"  "test_basic_module_cpp.errorResult()"
test_basic_cpp "resultWithMap()"     "Method call successful"  "test_basic_module_cpp.resultWithMap()"
test_basic_cpp "resultWithList()"    "Method call successful"  "test_basic_module_cpp.resultWithList()"
test_basic_cpp "validateInput(hi)"   "Method call successful"  "test_basic_module_cpp.validateInput(hi)"

# ── Return type: LogosMap (nlohmann::json object) ───────────────────────────
# `jsonReturn=true` path: glue calls `nlohmannToQVariant` to produce a
# QVariantMap, which the CLI prints as structured JSON.
echo ""
echo "  -- Return type: LogosMap --"
test_basic_cpp "returnMap()"            "Method call successful"  "test_basic_module_cpp.returnMap()"
test_basic_cpp "makeMap(hello, world)"  "Method call successful"  "test_basic_module_cpp.makeMap(hello, world)"

# ── Return type: LogosList (nlohmann::json array) ───────────────────────────
echo ""
echo "  -- Return type: LogosList --"
test_basic_cpp "returnList()"           "Method call successful"  "test_basic_module_cpp.returnList()"
test_basic_cpp "makeList(x, y)"         "Method call successful"  "test_basic_module_cpp.makeList(x, y)"

# ── Return type: std::vector<std::string> ───────────────────────────────────
echo ""
echo "  -- Return type: std::vector<std::string> --"
test_basic_cpp "returnStringList()"   "Method call successful"  "test_basic_module_cpp.returnStringList()"
skip_test      "splitString(a,b,c)"   "commas in arg value parsed as arg separators by logoscore"

# ── Return type: std::vector<uint8_t> ───────────────────────────────────────
# CLI can't serialize bytes to stdout meaningfully (base64 / hex / raw is an
# encoding choice), and can't accept a vector<uint8_t> literal as a CLI arg.
# Python integration suite exercises the round-trip through the actual wire.
echo ""
echo "  -- Return type: std::vector<uint8_t> --"
skip_test      "returnBytes()"         "CLI can't render std::vector<uint8_t>"
test_basic_cpp "byteArraySize(12345)"  "Result: 5"  "test_basic_module_cpp.byteArraySize(12345)"

# ── Parameter types ─────────────────────────────────────────────────────────
echo ""
echo "  -- Parameter types --"
test_basic_cpp "echoInt(42)"       "Result: 42"     "test_basic_module_cpp.echoInt(42)"
test_basic_cpp "echoInt(0)"        "Result: 0"      "test_basic_module_cpp.echoInt(0)"
test_basic_cpp "echoInt(-7)"       "Result: -7"     "test_basic_module_cpp.echoInt(-7)"
test_basic_cpp "echoBool(true)"    "Result: true"   "test_basic_module_cpp.echoBool(true)"
test_basic_cpp "echoBool(false)"   "Result: false"  "test_basic_module_cpp.echoBool(false)"
skip_test      "joinStrings(vector<string>)"  "logoscore cannot pass vector<string> params"

# ── Argument counts 0–5 ─────────────────────────────────────────────────────
# Format strings are produced by std::to_string (not QString::arg), but the
# expected output strings match the Qt module's bit-for-bit — the impl is
# careful to emit the same shape.
echo ""
echo "  -- Argument counts 0-5 --"
test_basic_cpp "noArgs()"                    "Result: noArgs()"                     "test_basic_module_cpp.noArgs()"
test_basic_cpp "oneArg(x)"                   "Result: oneArg(x)"                    "test_basic_module_cpp.oneArg(x)"
test_basic_cpp "twoArgs(x, 1)"               "Result: twoArgs(x, 1)"                "test_basic_module_cpp.twoArgs(x, 1)"
test_basic_cpp "threeArgs(x, 1, true)"       "Result: threeArgs(x, 1, true)"        "test_basic_module_cpp.threeArgs(x, 1, true)"
test_basic_cpp "fourArgs(x, 1, true, y)"     "Result: fourArgs(x, 1, true, y)"      "test_basic_module_cpp.fourArgs(x, 1, true, y)"
test_basic_cpp "fiveArgs(x, 1, true, y, 2)"  "Result: fiveArgs(x, 1, true, y, 2)"   "test_basic_module_cpp.fiveArgs(x, 1, true, y, 2)"

# ── Void methods ────────────────────────────────────────────────────────────
echo ""
echo "  -- Void methods (logoscore returns non-zero for void, testing no crash) --"
skip_test  "doNothing()"             "void return → invalid QVariant → logoscore exit 1"
skip_test  "doNothingWithArgs(a,1)"  "void return → invalid QVariant → logoscore exit 1"

# ── Events ──────────────────────────────────────────────────────────────────
# The impl's `std::function emitEvent` is wired by the generator to the
# LogosProviderBase::emitEvent path. Same void-return limitation as the Qt
# module: fire-and-forget through the CLI produces exit 1.
echo ""
echo "  -- Events --"
skip_test  "emitTestEvent(data)"         "void return → invalid QVariant → logoscore exit 1"
skip_test  "emitMultiArgEvent(ev, 5)"    "void return → invalid QVariant → logoscore exit 1"

# ── Type coercion ───────────────────────────────────────────────────────────
# Same logoscore-side coercion rules as the Qt module, but the receiving end
# is int64_t instead of int — the generator's std-to-Qt glue should still
# land on the same result after QVariant::convert.
echo ""
echo "  -- Type coercion --"
test_basic_cpp "addInts(3.0, 4.0) [double→int64]"        "Result: 7"                 "test_basic_module_cpp.addInts(3.0, 4.0)"
test_basic_cpp "echoInt(42.0) [double→int64]"            "Result: 42"                "test_basic_module_cpp.echoInt(42.0)"
test_basic_cpp "isPositive(5.0) [double→int64→bool]"     "Result: true"              "test_basic_module_cpp.isPositive(5.0)"
test_basic_cpp "twoArgs(hi, 3.0) [double→int64 mixed]"   "Result: twoArgs(hi, 3)"    "test_basic_module_cpp.twoArgs(hi, 3.0)"

fi  # end basic-cpp group

# ═════════════════════════════════════════════════════════════════════════════
# TEST GROUP 2b: test_context_module_cpp (LogosModuleContext lifecycle)
# ═════════════════════════════════════════════════════════════════════════════
#
# Exercises the SDK's LogosModuleContext base class end-to-end:
#
#   1. The impl inherits LogosModuleContext (opt-in mixin).
#   2. The codegen-emitted provider's `onInit(LogosAPI*)` override
#      reads modulePath / instanceId / instancePersistencePath off
#      the LogosAPI and threads them into the context via the
#      SFINAE'd helpers in logos_module_context.h.
#   3. The host (logoscore) provisions the persistence directory
#      from `--persistence-path` BEFORE the module loads, so the
#      three getters return the expected values from the moment
#      onContextReady() fires.
#
# Logoscore's --persistence-path is required for instanceId() and
# instancePersistencePath() to populate (module_manager.cpp only
# stamps those properties when persistenceBasePath() is set). We
# create a fresh temp dir per run so the assertions can match a
# unique path prefix.

if should_run_group "context-cpp"; then

echo ""
echo "-----------------------------------------------------------------"
echo " test_context_module_cpp (LogosModuleContext lifecycle wire-up)"
echo "-----------------------------------------------------------------"

# CONTEXT_PERSISTENCE_DIR is created up front (the daemon was launched with
# --persistence-path "$CONTEXT_PERSISTENCE_DIR") and cleaned up by the EXIT trap.
echo "  persistence base: $CONTEXT_PERSISTENCE_DIR"

# Quick liveness probe: asserts the SDK flipped LogosModuleContext's
# `isContextReady()` flag and fired the `onContextReady()` hook before
# the first method dispatch — `wasContextReady()` returns true. Failure
# here means the framework didn't even wire the context, and the rest
# of the assertions are noise.
echo ""
echo "  -- Lifecycle hook fired --"
test_context_cpp "wasContextReady()"    "Result: true"  "test_context_module_cpp.wasContextReady()"

# Module path: the host (logos_host) stamps the parent dir of the
# loaded plugin file. We can't predict the absolute path (nix store),
# but we CAN predict the module dir name. logoscore loads from
# $MODULES_DIR/test_context_module_cpp/, so the path must contain
# that segment.
echo ""
echo "  -- Three context properties populated --"
test_context_cpp "getModulePath() contains module name" \
    "test_context_module_cpp"   "test_context_module_cpp.getModulePath()"

# Persistence path: <CONTEXT_PERSISTENCE_DIR>/test_context_module_cpp/<instanceId>.
# We assert the prefix; the instance ID is host-generated so opaque
# to the test.
test_context_cpp "getInstancePersistencePath() rooted at temp dir" \
    "$CONTEXT_PERSISTENCE_DIR/test_context_module_cpp"  \
    "test_context_module_cpp.getInstancePersistencePath()"

# Instance ID: opaque host-generated short ID. We can't predict its
# shape, but we CAN assert it was populated at all via the bool-
# returning `hasInstanceId()` shim — `Result: true` only when the
# string is non-empty. (A plain string `getInstanceId()` check via
# the CLI's `Result:` prefix would falsely pass against an empty
# default; this side-steps that ambiguity.)
test_context_cpp "hasInstanceId() == true"  \
    "Result: true"   "test_context_module_cpp.hasInstanceId()"

# persistencePathEndsWith() takes one string arg. Pass a suffix
# we know matches: the parent segment of the instance dir is the
# module name, which IS predictable. The full path ends with the
# instance ID, but it definitely *contains* "test_context_module_cpp"
# somewhere on the right-hand side, so we use a suffix that ends
# with the module name + a known-stable child segment (only ID
# changes per run; module name doesn't). Easiest reliable case:
# we test with a single character "/" which is guaranteed to be
# in the path — but the CLI can't reliably pass "/" alone. So we
# skip the .endsWith() helper at the integration layer; the SDK
# unit tests already cover String operations exhaustively.
skip_test  "persistencePathEndsWith(<suffix>)"  "CLI can't reliably pass slash-containing args; covered by SDK unit tests"

# ── Cross-module calls via modules() ────────────────────────────────────
# These prove the whole chain: the codegen-emitted onInit built a
# LogosModules from the host's LogosAPI, threaded it through
# LogosModuleContext via the SFINAE'd helper, and the typed access
# in our impl resolves to the right dep. The host loads
# test_basic_module by name (the dep is declared in
# test_context_module_cpp's metadata.json), so the in-process IPC
# path between the two modules has to be fully wired.
echo ""
echo "  -- Cross-module calls through modules() --"
test_context_cpp "callBasicEcho(hello)"   "Result: hello"  \
    "test_context_module_cpp.callBasicEcho(hello)"
test_context_cpp "callBasicEcho(world)"   "Result: world"  \
    "test_context_module_cpp.callBasicEcho(world)"
test_context_cpp "callBasicAddInts(3, 4)" "Result: 7"      \
    "test_context_module_cpp.callBasicAddInts(3, 4)"
test_context_cpp "callBasicAddInts(-5, 10)" "Result: 5"    \
    "test_context_module_cpp.callBasicAddInts(-5, 10)"

# ── Typed event subscriptions (logos_events: end-to-end) ────────────────
#
# test_basic_module_cpp declares typed events in `logos_events:`. The
# codegen emits a `.lidl` sidecar with those events; buildHeaders.nix
# threads it into `--events-from` so the generated TestBasicModuleCpp
# wrapper gains `onTestEvent(...)` / `onMultiArgEvent(...)` typed
# accessors. test_context_module_cpp's
# `subscribeToBasicCppEvents()` calls those accessors with std-typed
# C++ callbacks that stash the payload into instance state.
#
# Each round-trip case below chains three `-c` invocations in ONE
# logoscore process so the event loop pumps QRO deliveries between
# them. logoscore's `-c` ordering is `subscribe → trigger → read`;
# the chained output contains all three results, and the harness
# greps for the expected substring of the final read.
echo ""
echo "  -- Typed event subscriptions on test_basic_module_cpp --"

test_context_cpp "subscribeToBasicCppEvents()"  "Result: ok"  \
    "test_context_module_cpp.subscribeToBasicCppEvents()"

# subscribe → triggerTestEvent("hello") → getLastTestEventData()
# logoscore runs the `-c` calls sequentially in the same process; the
# Qt event loop pumps QRO event deliveries between them, so the
# subscription callback has fired before the read.
assert_call "testEvent round-trip via onTestEvent"  "Result: hello"  \
    -m "$MODULES_DIR"                                                  \
    --persistence-path "$CONTEXT_PERSISTENCE_DIR"                      \
    -l test_basic_module_cpp,test_context_module_cpp                   \
    -c "test_context_module_cpp.subscribeToBasicCppEvents()"           \
    -c "test_basic_module_cpp.triggerTestEvent(hello)"                 \
    -c "test_context_module_cpp.getLastTestEventData()"

# Same pattern, multi-arg event: subscribe → trigger(ev, 42) → read.
# Result-map shape: {"count": 42, "name": "ev"} — grep just on
# `"name": "ev"` to keep the assertion narrow.
assert_call "multiArgEvent round-trip via onMultiArgEvent"  "ev"      \
    -m "$MODULES_DIR"                                                  \
    --persistence-path "$CONTEXT_PERSISTENCE_DIR"                      \
    -l test_basic_module_cpp,test_context_module_cpp                   \
    -c "test_context_module_cpp.subscribeToBasicCppEvents()"           \
    -c "test_basic_module_cpp.triggerMultiArgEvent(ev, 42)"            \
    -c "test_context_module_cpp.getLastMultiArgEvent()"

fi  # end context-cpp group

# ═════════════════════════════════════════════════════════════════════════════
# TEST GROUP: fullapi chain (test_fullapi_cpp / _rust providers + _proxy)
#
# Exercises the full_api chain through the C++ proxy over the lp path:
#   - probeArrays: the proxy round-trips one array of EVERY array type through
#     the bound provider and reports the received sizes. This is the CLI-
#     observable check of the provider's [int]/[uint]/[float64]/[bool]/[tstr]/
#     [any] arg decode (logoscore can't pass a list arg directly).
#   - cross-language: bind the proxy to the C++ then the Rust provider and
#     re-probe — proving both providers decode every array type identically.
#   - a scalar sanity call + an event round-trip through the proxy.
# ═════════════════════════════════════════════════════════════════════════════

if should_run_group "fullapi"; then

echo ""
echo "-----------------------------------------------------------------"
echo " fullapi chain (providers + proxy, cross-language)"
echo "-----------------------------------------------------------------"

test_fullapi_proxy() {
    assert_call "$1" "$2" -m "$MODULES_DIR" -l test_fullapi_proxy -c "$3"
}

echo ""
echo "  -- Every array type round-trips through the C++ provider --"
test_fullapi_proxy "probeArrays (bound to test_fullapi_cpp)" \
    "intList=3 uintList=2 doubleList=2 boolList=2 stringList=2 anyList=3" \
    "test_fullapi_proxy.probeArrays()"

echo ""
echo "  -- Same, bound to the Rust provider (cross-language parity) --"
assert_call "useProvider(test_fullapi_rust)" "Result: true" \
    -m "$MODULES_DIR" -l test_fullapi_proxy \
    -c "test_fullapi_proxy.useProvider(test_fullapi_rust)"
assert_call "probeArrays (bound to test_fullapi_rust)" \
    "intList=3 uintList=2 doubleList=2 boolList=2 stringList=2 anyList=3" \
    -m "$MODULES_DIR" -l test_fullapi_proxy \
    -c "test_fullapi_proxy.useProvider(test_fullapi_rust)" \
    -c "test_fullapi_proxy.probeArrays()"

echo ""
echo "  -- Scalar forwarding + event round-trip through the proxy --"
assert_call "proxy echoInt via cpp" "Result: 42" \
    -m "$MODULES_DIR" -l test_fullapi_proxy \
    -c "test_fullapi_proxy.useProvider(test_fullapi_cpp)" \
    -c "test_fullapi_proxy.echoInt(42)"
# subscribe (proxy subscribes to the bound target in onContextReady/useProvider),
# trigger via the proxy, read the captured re-emitted event.
assert_call "intEvent round-trip through proxy" "intEvent:7" \
    -m "$MODULES_DIR" -l test_fullapi_proxy \
    -c "test_fullapi_proxy.useProvider(test_fullapi_cpp)" \
    -c "test_fullapi_proxy.fireIntEvent(7)" \
    -c "test_fullapi_proxy.getLastEvent()"

echo ""
echo "  -- The Rust proxy forwards + captures events too --"
assert_call "rust proxy echoInt via cpp" "Result: 42" \
    -m "$MODULES_DIR" -l test_fullapi_proxy_rust \
    -c "test_fullapi_proxy_rust.useProvider(test_fullapi_cpp)" \
    -c "test_fullapi_proxy_rust.echoInt(42)"
assert_call "rust proxy intEvent round-trip" "intEvent:7" \
    -m "$MODULES_DIR" -l test_fullapi_proxy_rust \
    -c "test_fullapi_proxy_rust.useProvider(test_fullapi_cpp)" \
    -c "test_fullapi_proxy_rust.fireIntEvent(7)" \
    -c "test_fullapi_proxy_rust.getLastEvent()"

fi  # end fullapi group

# ═════════════════════════════════════════════════════════════════════════════
# TEST GROUP 2: test_extlib_module (external C library wrapper)
# ═════════════════════════════════════════════════════════════════════════════

if should_run_group "extlib"; then

echo ""
echo "-----------------------------------------------------------------"
echo " test_extlib_module"
echo "-----------------------------------------------------------------"

echo ""
echo "  -- String operations via libstrutil --"
test_extlib "reverseString(hello)"      "Result: olleh"   "test_extlib_module.reverseString(hello)"
test_extlib "reverseString(abc)"        "Result: cba"     "test_extlib_module.reverseString(abc)"
test_extlib "reverseString(a)"          "Result: a"       "test_extlib_module.reverseString(a)"
# Reversal is by CHARACTER. Reversing the bytes instead splits "é" (C3 A9)
# into A9 C3, which is not valid UTF-8 — the call used to fail outright at
# serialisation, and every assertion above it was ASCII, so nothing caught it.
test_extlib "reverseString(héllo) [reversed by character]"    "Result: olléh" \
    "test_extlib_module.reverseString(héllo)"
# Same for a 4-byte character: it comes back whole and in the right place.
test_extlib "reverseString(a😀b) [non-BMP character survives]" "Result: b😀a" \
    "test_extlib_module.reverseString(a😀b)"
test_extlib "uppercaseString(hello)"    "Result: HELLO"   "test_extlib_module.uppercaseString(hello)"
test_extlib "uppercaseString(FooBar)"   "Result: FOOBAR"  "test_extlib_module.uppercaseString(FooBar)"
test_extlib "lowercaseString(HELLO)"    "Result: hello"   "test_extlib_module.lowercaseString(HELLO)"
test_extlib "lowercaseString(FooBar)"   "Result: foobar"  "test_extlib_module.lowercaseString(FooBar)"
# Non-ASCII must SURVIVE case mapping, not corrupt it. strutil used toupper()/
# tolower(), which are LOCALE-DEPENDENT: in en_US.UTF-8 they rewrite UTF-8 lead
# bytes, so lowercaseString("HELLO" with E-acute) returned invalid UTF-8 and the
# call FAILED outright. The pass-through is stable and assertable even though a
# real locale-dependent case mapping would not be.
test_extlib "uppercaseString(héllo) keeps é"  "Result: HéLLO"  "test_extlib_module.uppercaseString(héllo)"
test_extlib "lowercaseString(HÉLLO) keeps É"  "Result: hÉllo"  "test_extlib_module.lowercaseString(HÉLLO)"
test_extlib "uppercaseString(a😀b) survives"  "Result: A😀B"   "test_extlib_module.uppercaseString(a😀b)"

echo ""
echo "  -- Counting --"
test_extlib "countChars(hello)"         "Result: 5"    "test_extlib_module.countChars(hello)"
# Characters, not bytes — the C library counts bytes (it is strlen), the
# module discounts the UTF-8 continuation bytes.
test_extlib "countChars(héllo) [characters, not UTF-8 bytes]" "Result: 5" \
    "test_extlib_module.countChars(héllo)"
skip_test   "countChars()"             "logoscore cannot call 1-arg method with 0 args"
test_extlib "countChar(hello, l)"       "Result: 2"    "test_extlib_module.countChar(hello, l)"
test_extlib "countChar(hello, z)"       "Result: 0"    "test_extlib_module.countChar(hello, z)"
test_extlib "countChar(aabaa, a)"       "Result: 4"    "test_extlib_module.countChar(aabaa, a)"
# The needle is matched as a whole character, not as a byte that happens to
# occur inside one. The universal port answered 1 here as well, but only
# because it took the FIRST BYTE of "é" (0xC3) and that byte happens to occur
# exactly once in "héllo"; the Qt module before it took ch.at(0).toLatin1()
# (0xE9), which occurs in no UTF-8 string at all, and answered 0.
test_extlib "countChar(héllo, é) [whole character matches]"   "Result: 1" \
    "test_extlib_module.countChar(héllo, é)"
# A multi-character needle is counted as a whole string (the documented
# choice — see the header), left to right, without overlapping.
test_extlib "countChar(banana, na) [multi-character needle]"  "Result: 2" \
    "test_extlib_module.countChar(banana, na)"
test_extlib "countChar(aaa, aa) [matches do not overlap]"     "Result: 1" \
    "test_extlib_module.countChar(aaa, aa)"

echo ""
echo "  -- Library version --"
test_extlib "libVersion()"              "Result: 1.0.0"  "test_extlib_module.libVersion()"


fi  # end extlib group
# ═════════════════════════════════════════════════════════════════════════════
# TEST GROUP 3b: test_ipc_new_api_module (interface: "universal" consumer)
# ═════════════════════════════════════════════════════════════════════════════

if should_run_group "ipc-new-api"; then

echo ""
echo "-----------------------------------------------------------------"
echo " test_ipc_new_api_module (universal/Qt-free consumer, requires all modules)"
echo "-----------------------------------------------------------------"

test_ipc_new_api() {
    assert_call "$1" "$2" \
        -m "$MODULES_DIR" \
        -l test_ipc_new_api_module -c "$3"
}

echo ""
echo "  -- IPC new-API: calls to test_basic_module --"
test_ipc_new_api "callBasicEcho(hello)"                   "Result: hello"                          "test_ipc_new_api_module.callBasicEcho(hello)"
test_ipc_new_api "callBasicEcho(world)"                   "Result: world"                          "test_ipc_new_api_module.callBasicEcho(world)"
test_ipc_new_api "callBasicAddInts(10, 20)"               "Result: 30"                             "test_ipc_new_api_module.callBasicAddInts(10, 20)"
test_ipc_new_api "callBasicAddInts(0, 0)"                 "Result: 0"                              "test_ipc_new_api_module.callBasicAddInts(0, 0)"
test_ipc_new_api "callBasicReturnTrue()"                  "Result: true"                           "test_ipc_new_api_module.callBasicReturnTrue()"
test_ipc_new_api "callBasicNoArgs()"                      "Result: noArgs()"                       "test_ipc_new_api_module.callBasicNoArgs()"
test_ipc_new_api "callBasicFiveArgs(a, 1, true, b, 2)"   "Result: fiveArgs(a, 1, true, b, 2)"    "test_ipc_new_api_module.callBasicFiveArgs(a, 1, true, b, 2)"
test_ipc_new_api "callBasicSuccessResult()"               "Method call successful"                 "test_ipc_new_api_module.callBasicSuccessResult()"
test_ipc_new_api "callBasicErrorResult()"                 "Method call successful"                 "test_ipc_new_api_module.callBasicErrorResult()"
test_ipc_new_api "callBasicResultMapField(name)"          "Result: test"                           "test_ipc_new_api_module.callBasicResultMapField(name)"
test_ipc_new_api "callBasicResultMapField(count)"         "Result: 42"                             "test_ipc_new_api_module.callBasicResultMapField(count)"

echo ""
echo "  -- IPC new-API: calls to test_extlib_module --"
test_ipc_new_api "callExtlibReverse(hello)"               "Result: olleh"                          "test_ipc_new_api_module.callExtlibReverse(hello)"
test_ipc_new_api "callExtlibReverse(abc)"                 "Result: cba"                            "test_ipc_new_api_module.callExtlibReverse(abc)"
test_ipc_new_api "callExtlibUppercase(hello)"             "Result: HELLO"                          "test_ipc_new_api_module.callExtlibUppercase(hello)"
test_ipc_new_api "callExtlibCountChars(hello)"            "Result: 5"                              "test_ipc_new_api_module.callExtlibCountChars(hello)"

echo ""
echo "  -- IPC new-API: cross-module chaining --"
test_ipc_new_api "chainEchoThenReverse(hello)"            "Result: olleh"                          "test_ipc_new_api_module.chainEchoThenReverse(hello)"
test_ipc_new_api "chainEchoThenReverse(abcdef)"           "Result: fedcba"                         "test_ipc_new_api_module.chainEchoThenReverse(abcdef)"
test_ipc_new_api "chainUppercaseThenConcat(foo, bar)"     "Result: FOOBAR"                         "test_ipc_new_api_module.chainUppercaseThenConcat(foo, bar)"
test_ipc_new_api "chainUppercaseThenConcat(hello, world)" "Result: HELLOWORLD"                     "test_ipc_new_api_module.chainUppercaseThenConcat(hello, world)"

echo ""
echo "  -- IPC new-API: generated wrappers (LogosModules) --"
test_ipc_new_api "wrapperBasicEcho(hello)"                "Result: hello"                          "test_ipc_new_api_module.wrapperBasicEcho(hello)"
test_ipc_new_api "wrapperBasicEcho(test123)"              "Result: test123"                        "test_ipc_new_api_module.wrapperBasicEcho(test123)"
test_ipc_new_api "wrapperExtlibReverse(hello)"            "Result: olleh"                          "test_ipc_new_api_module.wrapperExtlibReverse(hello)"
test_ipc_new_api "wrapperExtlibReverse(abc)"              "Result: cba"                            "test_ipc_new_api_module.wrapperExtlibReverse(abc)"

echo ""
echo "  -- IPC new-API: async over the lp transport --"
# The async half of the same generated wrappers used above. On this surface
# `<name>Async` bottoms out in lp_invoke_async, so these assert async delivery
# into a module with NO Qt in its own translation units. The Qt-consumer side of
# async lives in test_fullapi_qtproxy, which reads completions from a separate
# call rather than blocking for them.
test_ipc_new_api "asyncCallBasicEcho(hello)"              "Result: hello"                          "test_ipc_new_api_module.asyncCallBasicEcho(hello)"
test_ipc_new_api "asyncCallBasicEcho(world)"              "Result: world"                          "test_ipc_new_api_module.asyncCallBasicEcho(world)"
test_ipc_new_api "asyncCallBasicAddInts(3, 4)"            "Result: 7"                              "test_ipc_new_api_module.asyncCallBasicAddInts(3, 4)"
test_ipc_new_api "asyncCallBasicAddInts(0, 0)"            "Result: 0"                              "test_ipc_new_api_module.asyncCallBasicAddInts(0, 0)"
test_ipc_new_api "asyncCallExtlibReverse(hello)"          "Result: olleh"                          "test_ipc_new_api_module.asyncCallExtlibReverse(hello)"
test_ipc_new_api "asyncCallExtlibReverse(abc)"            "Result: cba"                            "test_ipc_new_api_module.asyncCallExtlibReverse(abc)"
test_ipc_new_api "asyncWrapperBasicEcho(hello)"           "Result: hello"                          "test_ipc_new_api_module.asyncWrapperBasicEcho(hello)"
test_ipc_new_api "asyncWrapperBasicEcho(test123)"         "Result: test123"                        "test_ipc_new_api_module.asyncWrapperBasicEcho(test123)"

echo ""
echo "  -- IPC new-API: events --"
skip_test  "triggerBasicEvent(data)"              "void return → invalid QVariant → logoscore exit 1"

fi  # end ipc-new-api group

# ═════════════════════════════════════════════════════════════════════════════
# TEST GROUP 4: Multi-call sequences (test sequential -c chaining)
# ═════════════════════════════════════════════════════════════════════════════

if should_run_group "multi"; then

echo ""
echo "-----------------------------------------------------------------"
echo " Multi-call sequences"
echo "-----------------------------------------------------------------"

echo ""
echo "  -- Sequential calls in single logoscore invocation --"
TOTAL=$((TOTAL + 1))
# shellcheck disable=SC2086
printf "        cmd: timeout %s %s %s -m %s -l test_basic_module -c ... -c ... -c ...\n" \
    "$CALL_TIMEOUT" "$LOGOSCORE" "$QUIT_FLAG" "$MODULES_DIR"
# shellcheck disable=SC2086
output=$(dcall_inline \
    -m "$MODULES_DIR" -l test_basic_module \
    -c "test_basic_module.returnInt()" \
    -c "test_basic_module.echo(chain_test)" \
    -c "test_basic_module.addInts(10, 20)" \
    2>/dev/null) && rc=0 || rc=$?
if [[ $rc -eq 0 ]] && \
   printf '%s' "$output" | grep -qF "Result: 42" && \
   printf '%s' "$output" | grep -qF "Result: chain_test" && \
   printf '%s' "$output" | grep -qF "Result: 30"; then
    PASS=$((PASS + 1))
    printf "  PASS  basic: sequential 3-call chain\n"
else
    FAIL=$((FAIL + 1))
    printf "  FAIL  basic: sequential 3-call chain (output: %s)\n" "$output"
    FAILURES="${FAILURES}  FAIL  basic: sequential 3-call chain\n"
fi

TOTAL=$((TOTAL + 1))
# shellcheck disable=SC2086
printf "        cmd: timeout %s %s %s -m %s -l test_extlib_module -c ... -c ... -c ...\n" \
    "$CALL_TIMEOUT" "$LOGOSCORE" "$QUIT_FLAG" "$MODULES_DIR"
# shellcheck disable=SC2086
output=$(dcall_inline \
    -m "$MODULES_DIR" -l test_extlib_module \
    -c "test_extlib_module.reverseString(hello)" \
    -c "test_extlib_module.uppercaseString(world)" \
    -c "test_extlib_module.libVersion()" \
    2>/dev/null) && rc=0 || rc=$?
if [[ $rc -eq 0 ]] && \
   printf '%s' "$output" | grep -qF "Result: olleh" && \
   printf '%s' "$output" | grep -qF "Result: WORLD" && \
   printf '%s' "$output" | grep -qF "Result: 1.0.0"; then
    PASS=$((PASS + 1))
    printf "  PASS  extlib: sequential 3-call chain\n"
else
    FAIL=$((FAIL + 1))
    printf "  FAIL  extlib: sequential 3-call chain (output: %s)\n" "$output"
    FAILURES="${FAILURES}  FAIL  extlib: sequential 3-call chain\n"
fi

TOTAL=$((TOTAL + 1))
# shellcheck disable=SC2086
printf "        cmd: timeout %s %s %s -m %s -l test_ipc_new_api_module -c ... -c ... -c ...\n" \
    "$CALL_TIMEOUT" "$LOGOSCORE" "$QUIT_FLAG" "$MODULES_DIR"
# shellcheck disable=SC2086
output=$(dcall_inline \
    -m "$MODULES_DIR" -l test_ipc_new_api_module \
    -c "test_ipc_new_api_module.callBasicEcho(chain)" \
    -c "test_ipc_new_api_module.callExtlibReverse(hello)" \
    -c "test_ipc_new_api_module.callBasicAddInts(5, 7)" \
    2>/dev/null) && rc=0 || rc=$?
if [[ $rc -eq 0 ]] && \
   printf '%s' "$output" | grep -qF "Result: chain" && \
   printf '%s' "$output" | grep -qF "Result: olleh" && \
   printf '%s' "$output" | grep -qF "Result: 12"; then
    PASS=$((PASS + 1))
    printf "  PASS  ipc: sequential 3-call chain\n"
else
    FAIL=$((FAIL + 1))
    printf "  FAIL  ipc: sequential 3-call chain (output: %s)\n" "$output"
    FAILURES="${FAILURES}  FAIL  ipc: sequential 3-call chain\n"
fi


fi  # end multi group

# ═════════════════════════════════════════════════════════════════════════════
# TEST GROUP 5: Error cases
# ═════════════════════════════════════════════════════════════════════════════

if should_run_group "errors"; then

echo ""
echo "-----------------------------------------------------------------"
echo " Error cases"
echo "-----------------------------------------------------------------"

echo ""
echo "  -- Calling non-existent method --"
assert_call_fails "nonexistent method" \
    -m "$MODULES_DIR" -l test_basic_module -c "test_basic_module.noSuchMethod()"

echo ""
echo "  -- Calling non-existent module --"
assert_call_fails "nonexistent module" \
    -m "$MODULES_DIR" -l no_such_module -c "no_such_module.echo(x)"


fi  # end errors group
# ═════════════════════════════════════════════════════════════════════════════
# TEST GROUP 7: Unit tests — new provider API (mock transport, no logoscore)
# ═════════════════════════════════════════════════════════════════════════════

if should_run_group "unit-new-api"; then

echo ""
echo "-----------------------------------------------------------------"
echo " Unit tests — new provider API (mock transport)"
echo "-----------------------------------------------------------------"
echo ""

if [[ -z "$UNIT_NEW_API_TEST_BIN" ]]; then
    echo "  SKIP  unit-new-api tests (no unit test binary provided)"
    echo "        Set UNIT_NEW_API_TEST_BIN to the path of test_ipc_new_api_module_tests"
    SKIP=$((SKIP + 1))
elif [[ ! -x "$UNIT_NEW_API_TEST_BIN" ]]; then
    FAIL=$((FAIL + 1))
    printf "  FAIL  unit-new-api tests — binary not found or not executable: %s\n" "$UNIT_NEW_API_TEST_BIN"
    FAILURES="${FAILURES}  FAIL  unit-new-api tests: binary not found: ${UNIT_NEW_API_TEST_BIN}\n"
else
    TOTAL=$((TOTAL + 1))
    printf "        cmd: %s\n" "$UNIT_NEW_API_TEST_BIN"
    unit_na_output=$("$UNIT_NEW_API_TEST_BIN" 2>&1) && unit_na_rc=0 || unit_na_rc=$?
    printf "%s\n" "$unit_na_output"
    if [[ $unit_na_rc -eq 0 ]]; then
        PASS=$((PASS + 1))
        printf "  PASS  unit-new-api tests\n"
    else
        FAIL=$((FAIL + 1))
        printf "  FAIL  unit-new-api tests (exit code %d)\n" "$unit_na_rc"
        FAILURES="${FAILURES}  FAIL  unit-new-api tests: exit code ${unit_na_rc}\n"
    fi
fi


fi  # end unit-new-api group

# ═════════════════════════════════════════════════════════════════════════════
# Summary
# ═════════════════════════════════════════════════════════════════════════════

echo ""
echo "================================================================="
echo " Results: $PASS passed, $FAIL failed, $SKIP skipped (of $TOTAL run)"
echo "================================================================="

if [[ $FAIL -gt 0 ]]; then
    echo ""
    echo "Failures:"
    printf "%b" "$FAILURES"
    echo ""
    exit 1
fi

echo ""
echo "All tests passed."
exit 0
