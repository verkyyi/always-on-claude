#!/bin/bash
# test-lib.sh — Shared test runner, assertions, and fixtures.
# Sourced by each test-*.sh file.

set -euo pipefail

_PASS=0
_FAIL=0
_SKIP=0
_CURRENT_TEST=""

# --- Colors ---
_RED=$'\033[0;31m'
_GREEN=$'\033[0;32m'
_YELLOW=$'\033[1;33m'
_RESET=$'\033[0m'

# --- Runner ---

# Called before each test. Override in test files for custom setup.
setup() { :; }

# Called after each test. Override in test files for custom teardown.
teardown() { :; }

# Run all test_* functions in the calling script
run_tests() {
    local test_funcs
    test_funcs=$(declare -F | awk '$3 ~ /^test_/ {print $3}' | sort)

    for func in $test_funcs; do
        _CURRENT_TEST="$func"
        TEST_DIR=$(mktemp -d)
        mkdir -p "$TEST_DIR/home" "$TEST_DIR/bin" "$TEST_DIR/markers"
        export HOME="$TEST_DIR/home"
        export PATH="$TEST_DIR/bin:$_ORIG_PATH"

        local result=0
        setup
        if ! "$func"; then
            result=$?
        fi
        teardown
        rm -rf "$TEST_DIR"

        if [[ $result -eq 200 ]]; then
            echo "  ${_YELLOW}SKIP${_RESET} $func"
            ((_SKIP++)) || true
        elif [[ $result -ne 0 ]]; then
            echo "  ${_RED}FAIL${_RESET} $func"
            ((_FAIL++)) || true
        else
            echo "  ${_GREEN}PASS${_RESET} $func"
            ((_PASS++)) || true
        fi
    done
}

print_summary() {
    local total=$((_PASS + _FAIL + _SKIP))
    echo ""
    if [[ $_FAIL -eq 0 ]]; then
        if [[ $_SKIP -gt 0 ]]; then
            echo "${_GREEN}All $((_PASS + _SKIP)) tests passed${_RESET} (${_SKIP} skipped)"
        else
            echo "${_GREEN}All $total tests passed${_RESET}"
        fi
    else
        echo "${_RED}$_FAIL/$total tests failed${_RESET}"
    fi
    return $_FAIL
}

# Save original PATH before any mocks
_ORIG_PATH="$PATH"
_ORIG_HOME="$HOME"

# --- Assertions ---

_fail() {
    local msg="${1:-}"
    echo "    ASSERT FAILED${msg:+: $msg}" >&2
    return 1
}

assert_eq() {
    local expected="$1" actual="$2" msg="${3:-expected '$1' got '$2'}"
    [[ "$expected" == "$actual" ]] || _fail "$msg"
}

assert_neq() {
    local a="$1" b="$2" msg="${3:-expected '$1' != '$2'}"
    [[ "$a" != "$b" ]] || _fail "$msg"
}

assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-'$1' does not contain '$2'}"
    [[ "$haystack" == *"$needle"* ]] || _fail "$msg"
}

assert_file_exists() {
    local path="$1"
    [[ -e "$path" ]] || _fail "file does not exist: $path"
}

assert_file_not_exists() {
    local path="$1"
    [[ ! -e "$path" ]] || _fail "file should not exist: $path"
}

assert_exit_code() {
    local expected="$1"; shift
    local actual=0
    "$@" >/dev/null 2>&1 || actual=$?
    assert_eq "$expected" "$actual" "exit code: expected $expected got $actual"
}

assert_output_contains() {
    local needle="$1"; shift
    local output
    output=$("$@" 2>&1) || true
    assert_contains "$output" "$needle" "output does not contain '$needle'"
}

skip_test() {
    local reason="${1:-}"
    echo "    SKIP${reason:+: $reason}"
    return 200
}

# --- Fixtures ---

create_test_repo() {
    local name="${1:-test-repo}"
    local repo="$HOME/$name"
    git init -q "$repo"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config user.email "test@test.com"
    touch "$repo/README.md"
    git -C "$repo" add .
    git -C "$repo" commit -q -m "Initial commit"
    echo "$repo"
}

create_test_worktree() {
    local repo="$1" branch="$2"
    git -C "$repo" worktree add -q -b "$branch" "${repo}--${branch}" 2>/dev/null
    echo "${repo}--${branch}"
}

mock_binary() {
    local name="$1" output="${2:-}"
    local mock="$TEST_DIR/bin/$name"
    cat > "$mock" <<MOCK
#!/bin/bash
echo "\$0 \$*" >> "$TEST_DIR/bin/${name}.log"
echo "$output"
MOCK
    chmod +x "$mock"
}

# Mock binary that writes a marker file (for exec detection)
mock_binary_marker() {
    local name="$1" marker_name="${2:-$1}"
    local mock="$TEST_DIR/bin/$name"
    cat > "$mock" <<MOCK
#!/bin/bash
echo "\$0 \$*" > "$TEST_DIR/markers/${marker_name}"
MOCK
    chmod +x "$mock"
}
