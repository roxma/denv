#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -x "${SCRIPT_DIR}/../build/denv" ]]; then
    DENV="${SCRIPT_DIR}/../build/denv"
elif [[ -x "${SCRIPT_DIR}/../denv" ]]; then
    DENV="${SCRIPT_DIR}/../denv"
else
    echo "SKIP: denv binary not found"
    exit 0
fi

TEST_TMP="${SCRIPT_DIR}/tmp"
mkdir -p "$TEST_TMP"
TMPDIR=$(mktemp -d "${TEST_TMP}/XXXXXX")
trap 'rm -rf "$TMPDIR"' EXIT

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

assert_contains() {
    local file="$1"
    local needle="$2"
    if ! grep -Fq "$needle" "$file"; then
        fail "'$file' missing: $needle"
    fi
}

assert_not_contains() {
    local file="$1"
    local needle="$2"
    if grep -Fq "$needle" "$file"; then
        fail "'$file' unexpectedly contains: $needle"
    fi
}

# Spawn denv through the real bash integration and capture stdout.
# The wrapper triggers PROMPT_COMMAND once, sources .denv.bash, then prints
# CAPTURED_TEST_VAR so the caller can verify the variable was exported.
denv_spawn() {
    local dir="$1"
    local wrapper="${dir}/bash_wrapper.sh"
    cat > "$wrapper" <<'EOF'
#!/bin/bash
eval "$PROMPT_COMMAND"
echo "CAPTURED_TEST_VAR=$TEST_VAR"
EOF
    chmod +x "$wrapper"
    (
        export PROMPT_COMMAND='eval "$( '"$DENV"' prompt)"'
        export DENV_BASH="$wrapper"
        cd "$dir"
        bash -c 'eval "$PROMPT_COMMAND"'
    )
}

# ---------------------------------------------------------------------------
# Test functions — each wrapped in a named function for selective execution.
# Run:  bash test/run.sh            (all)
#       bash test/run.sh 08         (test 8)
#       bash test/run.sh allow      (tests matching "allow")
# ---------------------------------------------------------------------------

# allow adds entry to config; deny removes it and blocks sourcing
test_01_allow_sources_deny_blocks() { (
    TEST1_DIR="${TMPDIR}/test1"
    mkdir -p "$TEST1_DIR"
    export DENV_CONFIG="${TEST1_DIR}/config.json"
    echo 'export TEST_VAR="it_works"' > "${TEST1_DIR}/.denv.bash"

    cd "$TEST1_DIR"
    "$DENV" allow
    assert_contains "$DENV_CONFIG" "${TEST1_DIR}/.denv.bash"

    output=$(denv_spawn "$TEST1_DIR")
    [[ "$output" == *"CAPTURED_TEST_VAR=it_works"* ]] \
        || fail "expected TEST_VAR=it_works in spawn output, got: $output"

    "$DENV" deny
    assert_not_contains "$DENV_CONFIG" "${TEST1_DIR}/.denv.bash"

    output=$(denv_spawn "$TEST1_DIR")
    [[ "$output" != *"CAPTURED_TEST_VAR=it_works"* ]] \
        || fail "denied .denv.bash was still sourced"
    pass "allow sources .denv.bash, deny blocks it and removes config entry"
) }

# envrc fallback, ignore_envrc config, .denv.bash takes precedence
test_03_envrc_compatibility() { (
    TEST3_DIR="${TMPDIR}/test3"
    mkdir -p "$TEST3_DIR"

    # Only .envrc exists — should be found when ignore_envrc is unset
    echo 'export TEST_VAR="envrc_compat"' > "${TEST3_DIR}/.envrc"
    export DENV_CONFIG="${TEST3_DIR}/config1.json"
    cd "$TEST3_DIR"
    "$DENV" allow
    assert_contains "$DENV_CONFIG" "${TEST3_DIR}/.envrc"

    output=$(denv_spawn "$TEST3_DIR")
    [[ "$output" == *"CAPTURED_TEST_VAR=envrc_compat"* ]] \
        || fail "expected TEST_VAR=envrc_compat, got: $output"

    # ignore_envrc = true — .envrc should be ignored
    export DENV_CONFIG="${TEST3_DIR}/config2.json"
    cat > "$DENV_CONFIG" <<EOF
{
    "ignore_envrc": true,
    "allow_list": []
}
EOF
    output=$(denv_spawn "$TEST3_DIR")
    [[ "$output" != *"CAPTURED_TEST_VAR=envrc_compat"* ]] \
        || fail "ignore_envrc=true but .envrc was still sourced"

    # .denv.bash takes precedence over .envrc
    echo 'export TEST_VAR="denv_wins"' > "${TEST3_DIR}/.denv.bash"
    export DENV_CONFIG="${TEST3_DIR}/config3.json"
    cd "$TEST3_DIR"
    "$DENV" allow
    assert_contains "$DENV_CONFIG" "${TEST3_DIR}/.denv.bash"
    assert_not_contains "$DENV_CONFIG" "${TEST3_DIR}/.envrc"

    pass ".envrc compatibility and ignore_envrc config work"
) }

# prune removes config entries for deleted files, keeps existing ones
test_04_prune() { (
    TEST4_DIR="${TMPDIR}/test4"
    mkdir -p "${TEST4_DIR}/still_here"
    echo 'echo alive' > "${TEST4_DIR}/still_here/.denv.bash"

    cat > "${TEST4_DIR}/config.json" <<EOF
{
    "allow_list": [
        {"path": "${TMPDIR}/test4/gone/.denv.bash"},
        {"path": "${TEST4_DIR}/still_here/.denv.bash"}
    ]
}
EOF

    export DENV_CONFIG="${TEST4_DIR}/config.json"
    cd "$TEST4_DIR"
    "$DENV" prune

    assert_not_contains "$DENV_CONFIG" "${TMPDIR}/test4/gone/.denv.bash"
    assert_contains "$DENV_CONFIG" "${TEST4_DIR}/still_here/.denv.bash"
    pass "prune drops deleted paths and keeps existing ones"
) }

# different DENV_CONFIG paths are isolated from each other
test_05_config_isolates() { (
    TEST5_DIR="${TMPDIR}/test5"
    mkdir -p "${TEST5_DIR}/a" "${TEST5_DIR}/b"
    echo 'echo a' > "${TEST5_DIR}/a/.denv.bash"
    echo 'echo b' > "${TEST5_DIR}/b/.denv.bash"

    export DENV_CONFIG="${TEST5_DIR}/custom.json"
    cd "${TEST5_DIR}/a"
    "$DENV" allow
    assert_contains "$DENV_CONFIG" "${TEST5_DIR}/a/.denv.bash"

    export DENV_CONFIG="${TEST5_DIR}/another.json"
    cd "${TEST5_DIR}/b"
    "$DENV" allow
    assert_contains "$DENV_CONFIG" "${TEST5_DIR}/b/.denv.bash"
    assert_not_contains "${TEST5_DIR}/custom.json" "${TEST5_DIR}/b/.denv.bash"
    pass "DENV_CONFIG isolates each config path"
) }

# .denv/denv.bash directory form sources correctly
test_06_denv_dir_form() { (
    TEST6_DIR="${TMPDIR}/test6"
    mkdir -p "${TEST6_DIR}/.denv"
    export DENV_CONFIG="${TEST6_DIR}/config.json"
    echo 'export TEST_VAR="dir_form_works"' > "${TEST6_DIR}/.denv/denv.bash"

    cd "$TEST6_DIR"
    "$DENV" allow
    assert_contains "$DENV_CONFIG" "${TEST6_DIR}/.denv/denv.bash"

    output=$(denv_spawn "$TEST6_DIR")
    [[ "$output" == *"CAPTURED_TEST_VAR=dir_form_works"* ]] \
        || fail "expected TEST_VAR=dir_form_works, got: $output"
    pass "directory form .denv/denv.bash sources correctly"
) }

# ctime change blocks loading until re-allow
test_07_modify_requires_allow() { (
    TEST7_DIR="${TMPDIR}/test7"
    mkdir -p "$TEST7_DIR"
    export DENV_CONFIG="${TEST7_DIR}/config.json"
    echo 'export TEST_VAR="original"' > "${TEST7_DIR}/.denv.bash"

    cd "$TEST7_DIR"
    "$DENV" allow
    assert_contains "$DENV_CONFIG" "${TEST7_DIR}/.denv.bash"

    output=$(denv_spawn "$TEST7_DIR")
    [[ "$output" == *"CAPTURED_TEST_VAR=original"* ]] \
        || fail "expected TEST_VAR=original, got: $output"

    # Modify the file without re-allowing
    echo 'export TEST_VAR="modified"' > "${TEST7_DIR}/.denv.bash"

    output=$(denv_spawn "$TEST7_DIR")
    [[ "$output" != *"CAPTURED_TEST_VAR=modified"* ]] \
        || fail "modified .denv.bash was still sourced without re-allow"
    [[ "$output" == *"NOT ALLOWED"* ]] \
        || fail "expected NOT ALLOWED warning after file change, got: $output"

    # Re-allow and verify it works again
    "$DENV" allow
    output=$(denv_spawn "$TEST7_DIR")
    [[ "$output" == *"CAPTURED_TEST_VAR=modified"* ]] \
        || fail "expected TEST_VAR=modified after re-allow, got: $output"

    pass "modifying an allowed file requires re-allow"
) }

# multiple allowed denv files in ancestor chain load from outer to inner
test_08_multiple_load_outer_inner() { (
    TEST8_DIR="${TMPDIR}/test8"
    mkdir -p "${TEST8_DIR}/mid/sub"
    export DENV_CONFIG="${TEST8_DIR}/config.json"

    cat > "$DENV_CONFIG" <<EOF
{"ignore_envrc":true,"allow_list":[]}
EOF

    echo 'export TEST_VAR="$TEST_VAR:outer"' > "${TEST8_DIR}/.denv.bash"
    echo 'export TEST_VAR="$TEST_VAR:mid"'   > "${TEST8_DIR}/mid/.denv.bash"
    echo 'export TEST_VAR="$TEST_VAR:inner"' > "${TEST8_DIR}/mid/sub/.denv.bash"

    cd "${TEST8_DIR}/mid/sub"
    "$DENV" allow

    assert_contains "$DENV_CONFIG" "${TEST8_DIR}/.denv.bash"
    assert_contains "$DENV_CONFIG" "${TEST8_DIR}/mid/.denv.bash"
    assert_contains "$DENV_CONFIG" "${TEST8_DIR}/mid/sub/.denv.bash"

    output=$(denv_spawn "${TEST8_DIR}/mid/sub")
    [[ "$output" == *"CAPTURED_TEST_VAR=:outer:mid:inner"* ]] \
        || fail "expected CAPTURED_TEST_VAR=:outer:mid:inner, got: $output"
    pass "multiple denv files load from outer to inner"
) }

# denied ancestor prevents any child from loading
test_09_not_allowed_prevents_loading() { (
    TEST9_DIR="${TMPDIR}/test9"
    mkdir -p "${TEST9_DIR}/sub"
    export DENV_CONFIG="${TEST9_DIR}/config.json"

    cat > "$DENV_CONFIG" <<EOF
{"ignore_envrc":true,"allow_list":[]}
EOF

    echo 'export TEST_VAR="outer"' > "${TEST9_DIR}/.denv.bash"
    echo 'export TEST_VAR="sub"'   > "${TEST9_DIR}/sub/.denv.bash"

    cd "${TEST9_DIR}/sub"
    "$DENV" allow

    # Deny only the parent, leaving sub still allowed
    "$DENV" deny "${TEST9_DIR}/.denv.bash"

    assert_not_contains "$DENV_CONFIG" "${TEST9_DIR}/.denv.bash"
    assert_contains "$DENV_CONFIG" "${TEST9_DIR}/sub/.denv.bash"

    output=$(denv_spawn "${TEST9_DIR}/sub")
    [[ "$output" == *"NOT ALLOWED"* ]] \
        || fail "expected NOT ALLOWED warning, got: $output"
    [[ "$output" != *"CAPTURED_TEST_VAR=sub"* ]] \
        || fail "denv was loaded despite not-allowed ancestor"
    pass "not-allowed ancestor prevents loading"
) }

# .denv/ takes precedence over .denv.bash when both exist
test_10_denv_dir_precedence() { (
    TEST10_DIR="${TMPDIR}/test10"
    mkdir -p "${TEST10_DIR}/.denv"
    export DENV_CONFIG="${TEST10_DIR}/config.json"

    cat > "$DENV_CONFIG" <<EOF
{"ignore_envrc":true,"allow_list":[]}
EOF

    echo 'export TEST_VAR="dir_form"' > "${TEST10_DIR}/.denv/denv.bash"
    echo 'export TEST_VAR="file_form"' > "${TEST10_DIR}/.denv.bash"

    cd "$TEST10_DIR"
    "$DENV" allow

    assert_contains "$DENV_CONFIG" "${TEST10_DIR}/.denv/denv.bash"
    assert_not_contains "$DENV_CONFIG" "${TEST10_DIR}/.denv.bash"

    output=$(denv_spawn "$TEST10_DIR")
    [[ "$output" == *"CAPTURED_TEST_VAR=dir_form"* ]] \
        || fail "expected dir_form, got: $output"
    pass ".denv/ takes precedence over .denv.bash"
) }

# deny removes the nearest entry; outer allowed denvs still load
test_11_deny_breaks_chain() { (
    TEST11_DIR="${TMPDIR}/test11"
    mkdir -p "${TEST11_DIR}/sub"
    export DENV_CONFIG="${TEST11_DIR}/config.json"

    cat > "$DENV_CONFIG" <<EOF
{"ignore_envrc":true,"allow_list":[]}
EOF

    echo 'export TEST_VAR="outer"' > "${TEST11_DIR}/.denv.bash"
    echo 'export TEST_VAR="sub"'   > "${TEST11_DIR}/sub/.denv.bash"

    cd "${TEST11_DIR}/sub"
    "$DENV" allow

    assert_contains "$DENV_CONFIG" "${TEST11_DIR}/.denv.bash"
    assert_contains "$DENV_CONFIG" "${TEST11_DIR}/sub/.denv.bash"

    # deny without args removes the nearest one
    "$DENV" deny

    assert_not_contains "$DENV_CONFIG" "${TEST11_DIR}/sub/.denv.bash"
    assert_contains "$DENV_CONFIG" "${TEST11_DIR}/.denv.bash"

    output=$(denv_spawn "${TEST11_DIR}/sub")
    [[ "$output" == *"NOT ALLOWED"* ]] \
        || fail "expected NOT ALLOWED warning after deny, got: $output"
    [[ "$output" == *"CAPTURED_TEST_VAR=outer"* ]] \
        || fail "outer denv should still load when inner is denied, got: $output"
    pass "deny removes nearest, outer denv still loads"
) }

# ---------------------------------------------------------------------------
# Dispatch — run all tests or only those matching command-line arguments
# ---------------------------------------------------------------------------

test_funcs=(
    test_01_allow_sources_deny_blocks
    test_03_envrc_compatibility
    test_04_prune
    test_05_config_isolates
    test_06_denv_dir_form
    test_07_modify_requires_allow
    test_08_multiple_load_outer_inner
    test_09_not_allowed_prevents_loading
    test_10_denv_dir_precedence
    test_11_deny_breaks_chain
)

if [[ $# -eq 0 ]]; then
    for func in "${test_funcs[@]}"; do
        "$func"
    done
else
    declare -A ran
    for arg in "$@"; do
        for func in "${test_funcs[@]}"; do
            if [[ "$func" == *"$arg"* ]]; then
                if [[ -z "${ran[$func]:-}" ]]; then
                    echo "=== RUN   $func"
                    "$func"
                    ran[$func]=1
                fi
            fi
        done
    done
fi

echo ""
echo "All tests passed."
