#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Pure-function unit tests for vps-proxy-tune.sh.
# ShellCheck cannot follow test functions passed by name to clean Bash subprocesses.
# Each test deliberately isolates its globals in a subshell.
# shellcheck disable=SC2030,SC2031,SC2317,SC2329

set -uo pipefail

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    printf 'not ok - Bash 4.4 or newer is required (found %s)\n' "${BASH_VERSION}" >&2
    exit 1
fi

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${TEST_DIR}/.." && pwd)"
PROGRAM="${PROJECT_ROOT}/vps-proxy-tune.sh"

if [[ ! -r "${PROGRAM}" ]]; then
    printf 'not ok - cannot read %s\n' "${PROGRAM}" >&2
    exit 1
fi

# Sourcing the program in this mode must only define constants and functions.
export VPS_TUNE_LIB_ONLY=1
# CI invokes ShellCheck from the repository root.
# shellcheck source=vps-proxy-tune.sh
source "${PROGRAM}"
set +e
set -uo pipefail

readonly TEST_MIB=1048576
readonly TEST_GIB=1073741824

# The small bundled Git-for-Windows Bash used by local development lacks
# chmod. Real Linux CI always exercises the actual coreutils implementation.
if ! command_exists chmod; then
    chmod() { return 0; }
fi

tests_run=0
tests_failed=0

pass() {
    tests_run=$((tests_run + 1))
    printf 'ok %d - %s\n' "${tests_run}" "$1"
}

fail() {
    tests_run=$((tests_run + 1))
    tests_failed=$((tests_failed + 1))
    printf 'not ok %d - %s' "${tests_run}" "$1" >&2
    if [[ $# -gt 1 ]]; then
        printf ' (%s)' "$2" >&2
    fi
    printf '\n' >&2
}

assert_eq() {
    local expected=$1 actual=$2 description=$3
    if [[ "${actual}" == "${expected}" ]]; then
        pass "${description}"
    else
        fail "${description}" "expected <${expected}>, got <${actual}>"
    fi
}

assert_success() {
    local description=$1 output status
    shift
    output="$( ( "$@" ) 2>&1 )"
    status=$?
    if (( status == 0 )); then
        pass "${description}"
    else
        fail "${description}" "exit ${status}${output:+: ${output}}"
    fi
}

assert_failure() {
    local description=$1
    shift
    if ( "$@" ) >/dev/null 2>&1; then
        fail "${description}" 'unexpectedly accepted input'
    else
        pass "${description}"
    fi
}

assert_output() {
    local expected=$1 description=$2 actual status
    shift 2
    actual="$("$@" 2>/dev/null)"
    status=$?
    if (( status != 0 )); then
        fail "${description}" "exit status ${status}"
    else
        assert_eq "${expected}" "${actual}" "${description}"
    fi
}

assert_output dependency_missing 'classifies missing systemctl with a space' reason_code_for_message '需要 systemctl 才能继续'
assert_success 'main program has valid Bash syntax' bash -n "$PROGRAM"
assert_output dependency_missing 'classifies missing systemd with a space' reason_code_for_message '需要 systemd 才能继续'

for required_function in \
    validate_peer validate_unit round_pow2 ram_cap_bytes \
    compute_buffer_target classify_quality confidence_from_metrics \
    parse_peer budget_rate_mbps measurement_duration_seconds \
    verification_budget_profile; do
    if ! declare -F "${required_function}" >/dev/null; then
        fail "public function ${required_function} exists"
    else
        pass "public function ${required_function} exists"
    fi
done

assert_output 'left\u0001right' 'JSON escaping encodes otherwise-invalid control bytes' \
    json_escape $'left\001right'
assert_output 'a\\b\"c' 'JSON escaping protects backslashes and quotes' \
    json_escape 'a\b"c'
assert_output '0.5' 'JSON number helper preserves canonical decimals' json_number_or_null 0.5
assert_output 'null' 'JSON number helper rejects leading-zero numbers' json_number_or_null 01.5
assert_output 'null' 'JSON number helper rejects a trailing decimal point' json_number_or_null 1.
if command_exists jq; then
    unit_main_json_error_contract() (
        local output status
        output=$(main definitely-not-a-command --json 2>/dev/null)
        status=$?
        (( status != 0 )) || return 1
        printf '%s\n' "${output}" | jq -e '
            .schema_version == "2" and
            .outcome == "failed" and
            .reason_code == "operation_failed" and
            has("run_id") and has("rollback_status")
        ' >/dev/null
    )
    assert_success 'malformed command with --json returns stable JSON error data' \
        unit_main_json_error_contract
    unit_verify_dry_run_json_error_contract() (
        local output status
        output=$(cmd_verify --dry-run --json 2>/dev/null)
        status=$?
        (( status != 0 )) || return 1
        printf '%s\n' "${output}" | jq -e '
            .schema_version == "2" and
            .outcome == "failed" and
            (.reason_code | type == "string") and
            .rollback_status == "failed"
        ' >/dev/null
    )
    assert_success 'verify rejects dry-run while preserving JSON errors in any option order' \
        unit_verify_dry_run_json_error_contract
fi
assert_failure 'audit dry-run cannot install packages' \
    cmd_audit --dry-run --install-deps
assert_failure 'measure dry-run cannot install packages' \
    cmd_measure --peer peer.example --dry-run --install-deps
assert_failure 'plan dry-run cannot install packages' \
    cmd_plan --run run-1 --dry-run --install-deps
assert_failure 'apply dry-run cannot install packages' \
    cmd_apply --run run-1 --dry-run --install-deps
assert_failure 'auto dry-run cannot install packages' \
    cmd_auto --peer peer.example --dry-run --install-deps
assert_failure 'verify rejects the parsed-but-unsupported dry-run flag' \
    cmd_verify --dry-run

# Peer parsing and validation are deliberately syntactic: they must never invoke a
# shell or require DNS. IPv6 with a port uses RFC 3986-style brackets.
for peer in \
    'iperf.example.cn' \
    'iperf.example.cn:5201' \
    '192.0.2.10' \
    '192.0.2.10:65535' \
    '[2001:db8::10]' \
    '2001:db8::10' \
    '[2001:db8::10]:5202'; do
    assert_success "validate_peer accepts ${peer}" validate_peer "${peer}"
done

for peer in \
    '' \
    '-4' \
    'https://example.cn:5201' \
    'user@example.cn:5201' \
    'example.cn:0' \
    'example.cn:65536' \
    'example.cn:18446744073709551617' \
    'example.cn:notaport' \
    '[2001:db8::10' \
    '2001:db8::10]:5201' \
    'example.cn/path' \
    'example.cn;id' \
    "example.cn\$(id)" \
    "example.cn\`id\`" \
    $'example.cn\nother'; do
    assert_failure "validate_peer rejects unsafe input $(printf %q "${peer}")" validate_peer "${peer}"
done

assert_success 'validate_unit accepts a normal service unit' validate_unit 'xray.service'
assert_success 'validate_unit accepts a hyphenated service unit' validate_unit 'sing-box.service'
assert_success 'validate_unit accepts a service instance' validate_unit 'proxy@edge-1.service'
for unit in \
    '' \
    '-xray.service' \
    'xray' \
    'xray.socket' \
    '../xray.service' \
    '/etc/systemd/system/xray.service' \
    'xray service.service' \
    'xray.service;id' \
    "xray\$(id).service" \
    "xray\`id\`.service" \
    $'xray.service\nother.service'; do
    assert_failure "validate_unit rejects unsafe input $(printf %q "${unit}")" validate_unit "${unit}"
done

assert_output '1' 'round_pow2 leaves one unchanged' round_pow2 1
assert_output '2' 'round_pow2 leaves an exact power unchanged' round_pow2 2
assert_output '4' 'round_pow2 rounds three upward' round_pow2 3
assert_output '4194304' 'round_pow2 handles the 4 MiB boundary' round_pow2 4194304
assert_output '8388608' 'round_pow2 crosses the 4 MiB boundary' round_pow2 4194305
assert_output '1073741824' 'round_pow2 handles large 64-bit-safe values' round_pow2 1000000000
assert_failure 'round_pow2 rejects zero' round_pow2 0
assert_failure 'round_pow2 rejects a negative value' round_pow2 -1
assert_failure 'round_pow2 rejects a non-canonical leading zero' round_pow2 08
assert_failure 'round_pow2 rejects non-numeric input' round_pow2 '4MiB'

# RAM caps: <1 GiB=4 MiB, 1-2=8 MiB, 2-4=16 MiB,
# 4-8=32 MiB, >=8=64 MiB.
assert_output "$((4 * TEST_MIB))" 'RAM cap just below 1 GiB' ram_cap_bytes $((TEST_GIB - 1))
assert_output "$((8 * TEST_MIB))" 'RAM cap at 1 GiB' ram_cap_bytes "${TEST_GIB}"
assert_output "$((8 * TEST_MIB))" 'RAM cap just below 2 GiB' ram_cap_bytes $((2 * TEST_GIB - 1))
assert_output "$((16 * TEST_MIB))" 'RAM cap at 2 GiB' ram_cap_bytes $((2 * TEST_GIB))
assert_output "$((32 * TEST_MIB))" 'RAM cap at 4 GiB' ram_cap_bytes $((4 * TEST_GIB))
assert_output "$((64 * TEST_MIB))" 'RAM cap at 8 GiB' ram_cap_bytes $((8 * TEST_GIB))
assert_output "$((64 * TEST_MIB))" 'RAM cap above 8 GiB' ram_cap_bytes $((32 * TEST_GIB))
assert_failure 'ram_cap_bytes rejects zero RAM' ram_cap_bytes 0
assert_failure 'ram_cap_bytes rejects non-numeric RAM' ram_cap_bytes unknown

# target = pow2-ceiling(2 * Mbps * RTT-ms * 125 bytes), with a 4 MiB
# floor and the RAM cap. CURRENT_MAX is retained when it is already larger.
assert_output "$((4 * TEST_MIB))" 'small BDP receives the 4 MiB floor' \
    compute_buffer_target 10 20 $((8 * TEST_GIB))
assert_output "$((32 * TEST_MIB))" '1000 Mbps at 100 ms rounds to 32 MiB' \
    compute_buffer_target 1000 100 $((8 * TEST_GIB))
assert_output "$((32 * TEST_MIB))" 'formatted decimal measurements are accepted' \
    compute_buffer_target 1000.000 100.000 $((8 * TEST_GIB))
assert_output "$((16 * TEST_MIB))" 'decimal BDP is rounded only after exact multiplication' \
    compute_buffer_target 335.5 200.0 $((8 * TEST_GIB))
assert_output "$((64 * TEST_MIB))" 'large BDP is capped to 64 MiB on an 8 GiB host' \
    compute_buffer_target 1000 300 $((8 * TEST_GIB))
assert_output "$((4 * TEST_MIB))" 'large BDP is capped to 4 MiB below 1 GiB RAM' \
    compute_buffer_target 10000 1000 $((TEST_GIB - 1))
assert_output "$((32 * TEST_MIB))" 'an existing larger administrator value is never reduced' \
    compute_buffer_target 10 20 "${TEST_GIB}" $((32 * TEST_MIB))
assert_output "$((8 * TEST_MIB))" 'an existing smaller value does not suppress the computed target' \
    compute_buffer_target 100 200 "${TEST_GIB}" "${TEST_MIB}"
assert_failure 'compute_buffer_target rejects zero throughput' \
    compute_buffer_target 0 100 "${TEST_GIB}"
assert_failure 'compute_buffer_target rejects zero RTT' \
    compute_buffer_target 100 0 "${TEST_GIB}"
assert_failure 'compute_buffer_target rejects malformed metrics' \
    compute_buffer_target fast 100 "${TEST_GIB}"

# Overall quality is the worst of loss, loaded-RTT increase, and retransmits.
assert_output 'good' 'all quality metrics are below/at good boundaries' \
    classify_quality 0.499 20 0.499
assert_output 'fair' '0.5 percent loss enters fair' classify_quality 0.5 0 0
assert_output 'fair' '2 percent loss remains fair' classify_quality 2 0 0
assert_output 'poor' 'loss above 2 percent is poor' classify_quality 2.001 0 0
assert_output 'fair' 'loaded RTT above 20 ms enters fair' classify_quality 0 20.001 0
assert_output 'fair' '80 ms loaded RTT increase remains fair' classify_quality 0 80 0
assert_output 'poor' 'loaded RTT increase above 80 ms is poor' classify_quality 0 80.001 0
assert_output 'fair' '0.5 percent retransmits enters fair' classify_quality 0 0 0.5
assert_output 'fair' '2 percent retransmits remains fair' classify_quality 0 0 2
assert_output 'poor' 'retransmits above 2 percent are poor' classify_quality 0 0 2.001
assert_output 'poor' 'quality result uses the worst metric' classify_quality 0 100 0
assert_failure 'classify_quality rejects negative metrics' classify_quality -1 0 0
assert_failure 'classify_quality rejects non-numeric metrics' classify_quality 0 unknown 0

# High confidence requires all four tests, a stable route, CV <=15%, background
# traffic <=10%, steal <10%, and a usable RTT measurement.
assert_output 'high' 'confidence is high at inclusive CV/background boundaries' \
    confidence_from_metrics 1 1 15 10 9.999 1
assert_output 'low' 'one missing throughput direction lowers confidence' \
    confidence_from_metrics 0 1 0 0 0 1
assert_output 'low' 'route drift lowers confidence' \
    confidence_from_metrics 1 0 0 0 0 1
assert_output 'low' 'CV above 15 percent lowers confidence' \
    confidence_from_metrics 1 1 15.001 0 0 1
assert_output 'low' 'background traffic above 10 percent lowers confidence' \
    confidence_from_metrics 1 1 0 10.001 0 1
assert_output 'low' 'CPU steal at 10 percent lowers confidence' \
    confidence_from_metrics 1 1 0 0 10 1
assert_output 'low' 'missing TCP/ICMP RTT lowers confidence' \
    confidence_from_metrics 1 1 0 0 0 0
assert_failure 'confidence rejects malformed booleans' \
    confidence_from_metrics yes 1 0 0 0 1
assert_failure 'confidence rejects non-numeric percentages' \
    confidence_from_metrics 1 1 unknown 0 0 1
assert_failure 'confidence rejects negative percentages' \
    confidence_from_metrics 1 1 -1 0 0 1

parse_tmp="${TMPDIR:-/tmp}/vps-proxy-tune-unit-${BASHPID}"
if ! (umask 077 && mkdir "${parse_tmp}") 2>/dev/null; then
    fail 'create private parse test directory'
else
    pass 'create private parse test directory'
    trap 'rm -rf -- "${parse_tmp}" "${parse_tmp}-format" "${parse_tmp}-unsafe" "${parse_tmp}-state-extra" "${parse_tmp}-sidecars" "${parse_tmp}-baseline-state" "${parse_tmp}-baseline-restore" "${parse_tmp}-baseline-restore-drift" "${parse_tmp}-ownership-history" "${parse_tmp}-baseline-staging" "${parse_tmp}-baseline-staging-recovery" "${parse_tmp}-transaction-staging" "${parse_tmp}-recovery-marker" "${parse_tmp}-recovery-pair" "${parse_tmp}-hash-write-failure" "${parse_tmp}-hash-publish-cleanup-failure" "${parse_tmp}-transaction-cleanup-failure" "${parse_tmp}-recovery-cleanup-failure" "${parse_tmp}-recovery-staging-cleanup" "${parse_tmp}-baseline-race"' EXIT

    check_parse() {
        local input=$1 expected_host=$2 expected_port=$3 description=$4
        local output_file="${parse_tmp}/parse.out"
        local -a lines=()
        PARSED_HOST='sentinel-host'
        PARSED_PORT='sentinel-port'
        if parse_peer "${input}" >"${output_file}" 2>/dev/null; then
            mapfile -t lines <"${output_file}"
            if [[ "${PARSED_HOST}" == "${expected_host}" &&
                  "${PARSED_PORT}" == "${expected_port}" &&
                  "${#lines[@]}" -eq 2 &&
                  "${lines[0]}" == "${expected_host}" &&
                  "${lines[1]}" == "${expected_port}" ]]; then
                pass "${description}"
            else
                fail "${description}" \
                    "globals=<${PARSED_HOST}:${PARSED_PORT}> output=<${lines[*]-}>"
            fi
        else
            fail "${description}" 'parse_peer returned failure'
        fi
    }

    check_parse 'iperf.example.cn' 'iperf.example.cn' '5201' \
        'parse_peer supplies the default iperf3 port'
    check_parse 'iperf.example.cn:6000' 'iperf.example.cn' '6000' \
        'parse_peer extracts an explicit IPv4/hostname port'
    check_parse '[2001:db8::10]' '2001:db8::10' '5201' \
        'parse_peer removes IPv6 brackets and supplies the default port'
    check_parse '2001:db8::10' '2001:db8::10' '5201' \
        'parse_peer accepts a bare IPv6 address without a port'
    check_parse '[2001:db8::10]:6000' '2001:db8::10' '6000' \
        'parse_peer extracts a bracketed IPv6 port'

    injection_marker="${parse_tmp}/should-not-exist"
    assert_failure 'parse_peer rejects shell metacharacters' \
        parse_peer "example.cn;touch ${injection_marker}"
    if [[ -e "${injection_marker}" ]]; then
        fail 'peer parsing never evaluates input' 'injection marker was created'
    else
        pass 'peer parsing never evaluates input'
    fi

    manifest_dir="${parse_tmp}/manifest"
    mkdir "${manifest_dir}"
    printf 'trusted payload\n' > "${manifest_dir}/payload.txt"
    if ! command_exists sha256sum; then
        printf -v unit_fake_hash '%064d' 0
        unit_fake_hash=${unit_fake_hash//0/a}
        sha256sum() {
            [[ $# -eq 1 && -f "$1" ]] || return 1
            printf '%s  %s\n' "${unit_fake_hash}" "$1"
        }
    fi
    manifest_hash="$(sha256sum "${manifest_dir}/payload.txt" | awk '{print $1}')"
    printf '%s  payload.txt\n' "${manifest_hash}" > "${manifest_dir}/manifest.sha256"
    assert_success 'hash manifest accepts a matching safe relative file' \
        verify_hash_manifest "${manifest_dir}" "${manifest_dir}/manifest.sha256"

    printf '%064d  payload.txt\n' 0 > "${manifest_dir}/manifest.sha256"
    assert_failure 'hash manifest rejects a content hash mismatch' \
        verify_hash_manifest "${manifest_dir}" "${manifest_dir}/manifest.sha256"

    printf 'outside payload\n' > "${parse_tmp}/outside.txt"
    outside_hash="$(sha256sum "${parse_tmp}/outside.txt" | awk '{print $1}')"
    printf '%s  ../outside.txt\n' "${outside_hash}" > "${manifest_dir}/manifest.sha256"
    assert_failure 'hash manifest rejects parent-directory traversal' \
        verify_hash_manifest "${manifest_dir}" "${manifest_dir}/manifest.sha256"

    printf '%s  payload.txt\n%s  payload.txt\n' "${manifest_hash}" "${manifest_hash}" > "${manifest_dir}/manifest.sha256"
    assert_failure 'hash manifest rejects duplicate records' \
        verify_hash_manifest "${manifest_dir}" "${manifest_dir}/manifest.sha256"
fi

if [[ -d "${parse_tmp}" ]]; then
    safety_dir="${parse_tmp}/safety"
    mkdir -p "${safety_dir}/proc/net" "${safety_dir}/sys/class/net/test0" \
        "${safety_dir}/etc/sysctl.d" "${safety_dir}/run/sysctl.d"

    unit_empty_effective_sysctl_scan() (
        local empty_root="${safety_dir}/empty-sysctl"
        mkdir -p "${empty_root}/etc/sysctl.d" "${empty_root}/run/sysctl.d" || return 1
        chmod 0700 "${empty_root}" "${empty_root}/etc" "${empty_root}/etc/sysctl.d" \
            "${empty_root}/run" "${empty_root}/run/sysctl.d" || return 1
        ETC_ROOT="${empty_root}/etc"
        RUN_ROOT="${empty_root}/run"
        collect_sysctl_files || return 1
        [[ "${#SYSCTL_SCAN_FILES[@]}" -eq 0 ]]
    )
    assert_success 'empty effective sysctl.d scan returns an empty set' \
        unit_empty_effective_sysctl_scan

    unit_sysctl_mask_and_priority() (
        local root="${safety_dir}/sysctl-order"
        mkdir -p "${root}/etc/sysctl.d" "${root}/lib/sysctl.d" "${root}/usr/lib/sysctl.d" "${root}/run/sysctl.d" || return 1
        chmod 0700 "${root}" "${root}/etc" "${root}/etc/sysctl.d" "${root}/lib" "${root}/lib/sysctl.d" \
            "${root}/usr" "${root}/usr/lib" "${root}/usr/lib/sysctl.d" "${root}/run" "${root}/run/sysctl.d" || return 1
        printf 'net.core.rmem_max = 1\n' > "${root}/lib/sysctl.d/50-example.conf" || return 1
        printf 'net.core.rmem_max = 2\n' > "${root}/etc/sysctl.d/50-example.conf" || return 1
        ln -s /dev/null "${root}/etc/sysctl.d/60-masked.conf" || return 1
        ETC_ROOT="${root}/etc"
        RUN_ROOT="${root}/run"
        collect_sysctl_files || return 1
        [[ "${#SYSCTL_SCAN_FILES[@]}" -eq 1 &&
           "${SYSCTL_SCAN_FILES[0]}" == "${root}/etc/sysctl.d/50-example.conf" ]]
    )
    assert_success 'sysctl scan honors basename priority and /dev/null masks' \
        unit_sysctl_mask_and_priority

    unit_sysctl_supported_syntax() (
        local case_name="$1" definition="$2" expected_key="${3:-}"
        local root="${safety_dir}/sysctl-syntax-${case_name}" definitions
        mkdir -p "${root}/etc/sysctl.d" "${root}/run/sysctl.d" || return 1
        printf '%s\n' "$definition" > "${root}/etc/sysctl.d/60-example.conf" || return 1
        ETC_ROOT="${root}/etc"
        RUN_ROOT="${root}/run"
        SYSCTL_FILE="${root}/etc/sysctl.d/90-vps-proxy-tune.conf"
        definitions=$(scan_sysctl_definitions) || return 1
        if [[ -z "$expected_key" ]]; then
            [[ -z "$definitions" ]]
        else
            [[ "$definitions" == $'local\t'"$expected_key"$'\t'"${root}/etc/sysctl.d/60-example.conf"$'\t4096' ]]
        fi
    )
    assert_success 'sysctl scan accepts distribution interface globs and exclusions' \
        unit_sysctl_supported_syntax interface $'; distro comment\nnet.ipv4.conf.*.rp_filter = 2\n-net.ipv4.conf.all.rp_filter'
    assert_success 'sysctl scan retains a wildcard assignment matching a managed key' \
        unit_sysctl_supported_syntax star 'net.*.tcp_max_syn_backlog = 4096' net.ipv4.tcp_max_syn_backlog
    assert_success 'sysctl scan retains bracket and question-mark glob matches' \
        unit_sysctl_supported_syntax bracket 'net.ipv[46].tcp_max_syn_backlo? = 4096' net.ipv4.tcp_max_syn_backlog
    assert_failure 'sysctl scan rejects malformed bracket patterns' \
        unit_sysctl_supported_syntax malformed 'net.ipv[4.tcp_max_syn_backlog = 4096'

    unit_sysctl_readable_link() (
        local root="${safety_dir}/sysctl-link" definitions
        mkdir -p "${root}/etc/sysctl.d" "${root}/run/sysctl.d" || return 1
        printf 'net.core.rmem_max = 4096\n' > "${root}/etc/sysctl.conf" || return 1
        ln -s ../sysctl.conf "${root}/etc/sysctl.d/99-sysctl.conf" || return 1
        ETC_ROOT="${root}/etc"
        RUN_ROOT="${root}/run"
        SYSCTL_FILE="${root}/etc/sysctl.d/90-vps-proxy-tune.conf"
        definitions=$(scan_sysctl_definitions) || return 1
        [[ "$definitions" == *"${root}/etc/sysctl.d/99-sysctl.conf"* ]] || return 1
        rm -- "${root}/etc/sysctl.conf" || return 1
        if scan_sysctl_definitions >/dev/null; then return 1; fi
    )
    assert_success 'sysctl scan follows readable config links and rejects dangling ones' \
        unit_sysctl_readable_link

    unit_sysctl_semicolon_is_not_a_comment() (
        local root="${safety_dir}/sysctl-semicolon"
        mkdir -p "${root}/etc/sysctl.d" "${root}/lib/sysctl.d" "${root}/usr/lib/sysctl.d" \
            "${root}/usr/local/lib/sysctl.d" "${root}/run/sysctl.d" || return 1
        chmod 0700 "${root}" "${root}/etc" "${root}/etc/sysctl.d" "${root}/lib" \
            "${root}/lib/sysctl.d" "${root}/usr" "${root}/usr/lib" "${root}/usr/lib/sysctl.d" \
            "${root}/usr/local" "${root}/usr/local/lib" "${root}/usr/local/lib/sysctl.d" \
            "${root}/run" "${root}/run/sysctl.d" || return 1
        printf 'net.core.rmem_max = 1; net.core.wmem_max = 2\n' \
            > "${root}/etc/sysctl.d/60-invalid.conf" || return 1
        ETC_ROOT="${root}/etc"
        RUN_ROOT="${root}/run"
        SYSCTL_FILE="${root}/etc/sysctl.d/90-vps-proxy-tune.conf"
        scan_sysctl_definitions >/dev/null
    )
    assert_failure 'sysctl scan rejects semicolon syntax instead of treating it as a comment' \
        unit_sysctl_semicolon_is_not_a_comment

    unit_sysctl_malformed_non_target_fails_closed() (
        local root="${safety_dir}/sysctl-malformed"
        mkdir -p "${root}/etc/sysctl.d" "${root}/lib/sysctl.d" "${root}/usr/lib/sysctl.d" \
            "${root}/usr/local/lib/sysctl.d" "${root}/run/sysctl.d" || return 1
        chmod 0700 "${root}" "${root}/etc" "${root}/etc/sysctl.d" "${root}/lib" \
            "${root}/lib/sysctl.d" "${root}/usr" "${root}/usr/lib" "${root}/usr/lib/sysctl.d" \
            "${root}/usr/local" "${root}/usr/local/lib" "${root}/usr/local/lib/sysctl.d" \
            "${root}/run" "${root}/run/sysctl.d" || return 1
        printf 'this-is-not-a-sysctl-definition\n' > "${root}/etc/sysctl.d/60-invalid.conf" || return 1
        ETC_ROOT="${root}/etc"
        RUN_ROOT="${root}/run"
        SYSCTL_FILE="${root}/etc/sysctl.d/90-vps-proxy-tune.conf"
        scan_sysctl_definitions >/dev/null
    )
    assert_failure 'sysctl scan rejects malformed non-target definitions before filtering' \
        unit_sysctl_malformed_non_target_fails_closed

    unit_sysctl_rejects_extra_equals() (
        local root="${safety_dir}/sysctl-extra-equals"
        mkdir -p "${root}/etc/sysctl.d" "${root}/lib/sysctl.d" "${root}/usr/lib/sysctl.d" \
            "${root}/usr/local/lib/sysctl.d" "${root}/run/sysctl.d" || return 1
        chmod 0700 "${root}" "${root}/etc" "${root}/etc/sysctl.d" "${root}/lib" \
            "${root}/lib/sysctl.d" "${root}/usr" "${root}/usr/lib" "${root}/usr/lib/sysctl.d" \
            "${root}/usr/local" "${root}/usr/local/lib" "${root}/usr/local/lib/sysctl.d" \
            "${root}/run" "${root}/run/sysctl.d" || return 1
        printf 'not-a-target = value = extra\n' > "${root}/etc/sysctl.d/60-invalid.conf" || return 1
        ETC_ROOT="${root}/etc"
        RUN_ROOT="${root}/run"
        SYSCTL_FILE="${root}/etc/sysctl.d/90-vps-proxy-tune.conf"
        scan_sysctl_definitions >/dev/null
    )
    assert_failure 'sysctl scan rejects extra equals in malformed non-target definitions' \
        unit_sysctl_rejects_extra_equals

    unit_sysctl_rejects_embedded_cr() (
        local root="${safety_dir}/sysctl-cr"
        mkdir -p "${root}/etc/sysctl.d" "${root}/lib/sysctl.d" "${root}/usr/lib/sysctl.d" \
            "${root}/usr/local/lib/sysctl.d" "${root}/run/sysctl.d" || return 1
        chmod 0700 "${root}" "${root}/etc" "${root}/etc/sysctl.d" "${root}/lib" \
            "${root}/lib/sysctl.d" "${root}/usr" "${root}/usr/lib" "${root}/usr/lib/sysctl.d" \
            "${root}/usr/local" "${root}/usr/local/lib" "${root}/usr/local/lib/sysctl.d" \
            "${root}/run" "${root}/run/sysctl.d" || return 1
        printf 'net.core.rmem_max = 1\r2\n' > "${root}/etc/sysctl.d/60-invalid.conf" || return 1
        ETC_ROOT="${root}/etc"
        RUN_ROOT="${root}/run"
        SYSCTL_FILE="${root}/etc/sysctl.d/90-vps-proxy-tune.conf"
        scan_sysctl_definitions >/dev/null
    )
    assert_failure 'sysctl scan rejects embedded carriage returns' \
        unit_sysctl_rejects_embedded_cr

    # ensure_state_dirs intentionally accepts only the default production path
    # or a single private /tmp/vps-proxy-tune-* test root.  Keep migration
    # fixtures within that allow-list instead of weakening the production gate.
    state_format_parent="${parse_tmp}-format"
    mkdir -p "${state_format_parent}"
    chmod 0700 "${state_format_parent}"
    unit_state_format_migration() (
        STATE_DIR="${state_format_parent}"
        ensure_state_dirs || return 1
        [[ "$(cat "${STATE_DIR}/state-format")" == 2 ]]
    )
    assert_success 'v1-style state trees receive only a v2 metadata marker' unit_state_format_migration
    unit_state_sidecars_and_drift() (
        local state_root="${parse_tmp}-sidecars"
        STATE_DIR="${state_root}"
        ensure_state_dirs || return 1
        [[ -f "${STATE_DIR}/state.meta" && -f "${STATE_DIR}/state.meta.sha256" &&
           -f "${STATE_DIR}/state-format.sha256" ]] || return 1
        write_current_run run-1 || return 1
        [[ "$(cat "${STATE_DIR}/current_run")" == run-1 &&
           -f "${STATE_DIR}/current_run.sha256" ]] || return 1
        printf 'tamper\n' >> "${STATE_DIR}/current_run"
        ensure_secure_state
    )
    assert_failure 'state pointer sidecars detect content drift before recovery' \
        unit_state_sidecars_and_drift
    unit_state_child_permissions() (
        STATE_DIR="${parse_tmp}-unsafe"
        ensure_state_dirs || return 1
        chmod 0750 "${STATE_DIR}/runs" || return 1
        ensure_secure_state
    )
    assert_failure 'state readers reject a group-readable child tree' unit_state_child_permissions

    state_extra_dir="${parse_tmp}-state-extra"
    unit_state_unknown_top_level_fails_closed() (
        local state="${state_extra_dir}"
        STATE_DIR="${state}"
        ensure_state_dirs || return 1
        : > "${STATE_DIR}/unregistered-material" || return 1
        chmod 0600 "${STATE_DIR}/unregistered-material" || return 1
        ensure_secure_state
    )
    assert_failure 'state readers reject an unregistered visible top-level material' \
        unit_state_unknown_top_level_fails_closed

    baseline_state_dir="${parse_tmp}-baseline-state"
    unit_baseline_identity_roundtrip() (
        local initial
        STATE_DIR="${baseline_state_dir}"
        ensure_state_dirs || return 1
        initial="${STATE_DIR}/baseline/initial"
        mkdir -m 0700 "${initial}" || return 1
        printf 'net.core.rmem_max\t100\n' > "${initial}/runtime.tsv"
        : > "${initial}/qdisc.tsv"
        printf 'peer\n' > "${initial}/routes.tsv"
        printf '# Managed by vps-proxy-tune. Do not edit; use rollback/uninstall.\n' > "${initial}/metadata"
        printf 'now\n' > "${initial}/created_at"
        chmod 0600 "${initial}"/* || return 1
        create_hash_manifest "${initial}" "${initial}/manifest.sha256" || return 1
        baseline_identity_write "${initial}" || return 1
        baseline_identity_is_current "${initial}"
    )
    assert_success 'baseline identity records content, inode and exact permissions' \
        unit_baseline_identity_roundtrip
    unit_existing_baseline_state_is_valid() (
        STATE_DIR="${baseline_state_dir}"
        ensure_secure_state
    )
    assert_success 'state validation resolves an existing baseline identity from its own directory' \
        unit_existing_baseline_state_is_valid
    unit_baseline_identity_inode_drift() (
        local initial replacement
        STATE_DIR="${baseline_state_dir}"
        initial="${STATE_DIR}/baseline/initial"
        replacement="${initial}/runtime.tsv.replacement"
        install -m 0600 "${initial}/runtime.tsv" "${replacement}" || return 1
        mv -f "${replacement}" "${initial}/runtime.tsv" || return 1
        baseline_identity_is_current "${initial}"
    )
    assert_failure 'baseline identity rejects same-content inode replacement' \
        unit_baseline_identity_inode_drift
    unit_baseline_identity_extra_file() (
        local initial="${baseline_state_dir}/baseline/initial"
        printf 'unexpected\n' > "${initial}/extra.tsv" || return 1
        chmod 0600 "${initial}/extra.tsv" || return 1
        baseline_identity_is_current "${initial}"
    )
    assert_failure 'baseline identity rejects unlisted files' unit_baseline_identity_extra_file

    baseline_restore_state="${parse_tmp}-baseline-restore"
    unit_baseline_restore_executes() (
        local initial observed_runtime_value=300 writes=0
        STATE_DIR="${baseline_restore_state}"
        initial="${STATE_DIR}/baseline/initial"
        mkdir -p "${initial}" || return 1
        chmod 0700 "${STATE_DIR}" "${STATE_DIR}/baseline" "${initial}" || return 1
        printf 'net.core.rmem_max\t100\n' > "${initial}/runtime.tsv"
        : > "${initial}/qdisc.tsv"
        chmod 0600 "${initial}/runtime.tsv" "${initial}/qdisc.tsv" || return 1
        verify_hash_manifest() { :; }
        sysctl_read() { printf '%s\n' "${observed_runtime_value}"; }
        sysctl() {
            [[ "$3" == net.core.rmem_max=* ]] || return 1
            observed_runtime_value="${3#*=}"
            writes=$((writes + 1))
        }
        baseline_runtime_value_is_owned() { [[ "$2" == 300 ]]; }
        restore_initial_baseline || return 1
        [[ "${observed_runtime_value}" == 100 && "${writes}" == 1 ]]
    )
    assert_success 'baseline recovery restores authenticated runtime data' unit_baseline_restore_executes
    unit_baseline_restore_drift_stops() (
        local initial observed_runtime_value=300 writes=0
        STATE_DIR="${baseline_restore_state}-drift"
        initial="${STATE_DIR}/baseline/initial"
        mkdir -p "${initial}" || return 1
        chmod 0700 "${STATE_DIR}" "${STATE_DIR}/baseline" "${initial}" || return 1
        printf 'net.core.rmem_max\t100\n' > "${initial}/runtime.tsv"
        : > "${initial}/qdisc.tsv"
        chmod 0600 "${initial}/runtime.tsv" "${initial}/qdisc.tsv" || return 1
        verify_hash_manifest() { :; }
        sysctl_read() { printf '%s\n' "${observed_runtime_value}"; }
        sysctl() { writes=$((writes + 1)); }
        baseline_runtime_value_is_owned() { return 1; }
        if restore_initial_baseline; then return 1; fi
        [[ "${observed_runtime_value}" == 300 && "${writes}" == 0 ]]
    )
    assert_success 'baseline recovery refuses to overwrite unowned administrator drift' \
        unit_baseline_restore_drift_stops

    ownership_history_state="${parse_tmp}-ownership-history"
    unit_baseline_ignores_rolled_back_history_after_current_proof() (
        local transaction="${ownership_history_state}/transactions/historical-run" snapshot_hash
        STATE_DIR="${ownership_history_state}"
        mkdir -p "${STATE_DIR}/transactions" || return 1
        chmod 0700 "${STATE_DIR}" "${STATE_DIR}/transactions" || return 1
        mkdir -m 0700 "${transaction}" || return 1
        printf 'rolled-back\n' > "${transaction}/status" || return 1
        printf 'net.core.rmem_max\t300\t100\thistorical\truntime_change\n' > \
            "${transaction}/desired.tsv" || return 1
        printf 'authenticated snapshot\n' > "${transaction}/snapshot.sha256" || return 1
        snapshot_hash=$(sha256sum "${transaction}/snapshot.sha256" | awk '{print $1}') || return 1
        transaction_snapshot_is_valid() { :; }
        BASELINE_OWNERSHIP_PROOF=("historical-run${TAB}committed${TAB}${snapshot_hash}")
        baseline_runtime_value_is_owned net.core.rmem_max 300
    )
    assert_failure 'baseline ownership refuses an administrator value recreated from rolled-back history' \
        unit_baseline_ignores_rolled_back_history_after_current_proof

    baseline_race_state="${parse_tmp}-baseline-race"
    unit_baseline_appearing_during_apply_is_not_adopted() (
        local state="${baseline_race_state}" initial run_dir
        STATE_DIR="${state}"
        ensure_state_dirs || return 1
        initial="${STATE_DIR}/baseline/initial"
        run_dir="${STATE_DIR}/runs/run-race"
        mkdir -m 0700 "${initial}" "${run_dir}" || return 1
        APPLY_BASELINE_CREATED=1
        APPLY_BASELINE_EXPECT_NEW=1
        if create_initial_baseline "${run_dir}"; then return 1; fi
        [[ -d "${initial}" && ! -L "${initial}" &&
           "${APPLY_BASELINE_CREATED}" == 0 ]]
    )
    assert_success 'apply refuses to adopt a baseline that appears after preflight' \
        unit_baseline_appearing_during_apply_is_not_adopted

    unit_apt_temp_cleanup_scope() (
        local temp
        temp=$(mktemp -d /tmp/vps-proxy-tune-apt.XXXXXXXX) || return 1
        chmod 0700 "${temp}" || return 1
        apt_temp_cleanup "${temp}" || return 1
        [[ ! -e "${temp}" && ! -L "${temp}" ]] || return 1
        ! apt_temp_cleanup /tmp/vps-proxy-tune-apt-unsafe
    )
    assert_success 'APT cleanup only removes an exact private temporary directory' \
        unit_apt_temp_cleanup_scope

    unit_apt_temp_cleanup_rejects_wrong_type() (
        local temp
        temp=$(mktemp -d /tmp/vps-proxy-tune-apt.XXXXXXXX) || return 1
        command rm -rf -- "${temp}" || return 1
        : > "${temp}" || return 1
        if apt_temp_cleanup "${temp}"; then
            command rm -f -- "${temp}"
            return 1
        fi
        [[ -f "${temp}" && ! -L "${temp}" ]] || return 1
        command rm -f -- "${temp}"
    )
    assert_success 'APT cleanup rejects an exact-name non-directory instead of reporting success' \
        unit_apt_temp_cleanup_rejects_wrong_type

    unit_apt_temp_cleanup_failure_is_detectable() (
        local temp
        temp=$(mktemp -d /tmp/vps-proxy-tune-apt.XXXXXXXX) || return 1
        chmod 0700 "${temp}" || return 1
        rm() {
            if [[ "${3:-}" == "${temp}" ]]; then return 1; fi
            command rm "$@"
        }
        APT_TEMP_DIR="${temp}"
        if apt_temp_finish; then return 1; fi
        [[ -d "${temp}" && ! -L "${temp}" ]] || return 1
        command rm -rf -- "${temp}"
    )
    assert_success 'APT cleanup failure retains the exact temporary directory as evidence' \
        unit_apt_temp_cleanup_failure_is_detectable

    hash_failure_state="${parse_tmp}-hash-write-failure"
    unit_hash_write_failure_is_detectable() (
        local state="${hash_failure_state}" temp
        STATE_DIR="${state}"
        ensure_state_dirs || return 1
        atomic_install() { return 1; }
        rm() {
            if [[ "${3:-}" == "${STATE_DIR}"/.hash.* ]]; then return 1; fi
            command rm "$@"
        }
        if write_private_hash_record "${STATE_DIR}/state-format" \
            "${STATE_DIR}/state-format-failure.sha256"; then
            return 1
        fi
        temp=$(find "${STATE_DIR}" -maxdepth 1 -type f -name '.hash.*' -print -quit) || return 1
        [[ -n "${temp}" ]] || return 1
        ! ensure_secure_state
    )
    assert_success 'hash write failure leaves a detectable state temporary' \
        unit_hash_write_failure_is_detectable

    hash_publish_cleanup_failure_state="${parse_tmp}-hash-publish-cleanup-failure"
    unit_hash_publish_cleanup_failure_is_detectable() (
        local state="${hash_publish_cleanup_failure_state}" temp
        STATE_DIR="${state}"
        ensure_state_dirs || return 1
        atomic_install() {
            install -m "$3" "$1" "$2"
        }
        rm() {
            if [[ "${3:-}" == "${STATE_DIR}"/.hash.* ]]; then return 1; fi
            command rm "$@"
        }
        if write_private_hash_record "${STATE_DIR}/state-format" \
            "${STATE_DIR}/state-format-published.sha256"; then
            return 1
        fi
        [[ -f "${STATE_DIR}/state-format-published.sha256" &&
           ! -L "${STATE_DIR}/state-format-published.sha256" ]] || return 1
        temp=$(find "${STATE_DIR}" -maxdepth 1 -type f -name '.hash.*' -print -quit) || return 1
        [[ -n "${temp}" ]] || return 1
        ! ensure_secure_state
    )
    assert_success 'hash publish cleanup failure leaves a detectable state temporary' \
        unit_hash_publish_cleanup_failure_is_detectable

    transaction_cleanup_failure_state="${parse_tmp}-transaction-cleanup-failure"
    unit_transaction_staging_cleanup_failure_is_detectable() (
        local state="${transaction_cleanup_failure_state}" staging
        STATE_DIR="${state}"
        ensure_state_dirs || return 1
        staging="${STATE_DIR}/transactions/.run-1.ABCDEFGH"
        mkdir -m 0700 "${staging}" || return 1
        rm() {
            if [[ "${3:-}" == "${staging}" ]]; then return 1; fi
            command rm "$@"
        }
        if discard_transaction_staging "${staging}"; then return 1; fi
        [[ -d "${staging}" && ! -L "${staging}" ]] || return 1
        ! ensure_secure_state
    )
    assert_success 'transaction staging cleanup failure remains fail-closed and detectable' \
        unit_transaction_staging_cleanup_failure_is_detectable

    transaction_staging_type_state="${parse_tmp}-transaction-staging-type"
    unit_transaction_staging_wrong_type_is_detected() (
        local state="${transaction_staging_type_state}" staging
        STATE_DIR="${state}"
        ensure_state_dirs || return 1
        staging="${STATE_DIR}/transactions/.run-1.ABCDEFGH"
        : > "${staging}" || return 1
        if discard_transaction_staging "${staging}"; then return 1; fi
        [[ -f "${staging}" && ! -L "${staging}" ]] || return 1
        ! ensure_secure_state
    )
    assert_success 'transaction staging cleanup rejects an exact-name non-directory' \
        unit_transaction_staging_wrong_type_is_detected

    recovery_cleanup_failure_state="${parse_tmp}-recovery-cleanup-failure"
    unit_recovery_backup_cleanup_failure_is_detectable() (
        local state="${recovery_cleanup_failure_state}" backup
        STATE_DIR="${state}"
        ensure_state_dirs || return 1
        backup="${STATE_DIR}/.recovery-unit-rollback.ABCDEFGH"
        mkdir -m 0700 "${backup}" || return 1
        rm() {
            if [[ "${3:-}" == "${backup}" ]]; then return 1; fi
            command rm "$@"
        }
        if discard_recovery_rollback_backup "${backup}" 'injected recovery cleanup failure'; then
            return 1
        fi
        recovery_failure_marker_is_safe "${backup}" || return 1
        ! ensure_secure_state
    )
    assert_success 'recovery unit cleanup failure writes a detectable failure marker' \
        unit_recovery_backup_cleanup_failure_is_detectable

    recovery_staging_cleanup_state="${parse_tmp}-recovery-staging-cleanup"
    unit_recovery_staging_cleanup_failure_is_detectable() (
        local state="${recovery_staging_cleanup_state}" script_temp unit_temp
        STATE_DIR="${state}"
        ensure_state_dirs || return 1
        script_temp="${STATE_DIR}/.recovery-script.ABCDEFGH"
        unit_temp="${STATE_DIR}/.recovery-unit.ABCDEFGH"
        : > "${script_temp}" || return 1
        : > "${unit_temp}" || return 1
        chmod 0600 "${script_temp}" "${unit_temp}" || return 1
        rm() {
            if [[ "${3:-}" == "${script_temp}" || "${3:-}" == "${unit_temp}" ]]; then return 1; fi
            command rm "$@"
        }
        if recovery_script_staging_cleanup "${script_temp}"; then return 1; fi
        if recovery_unit_staging_cleanup "${unit_temp}"; then return 1; fi
        [[ -f "${script_temp}" && -f "${unit_temp}" && ! -L "${script_temp}" && ! -L "${unit_temp}" ]] || return 1
        ! ensure_secure_state
    )
    assert_success 'recovery unit/script staging cleanup failure remains fail-closed and detectable' \
        unit_recovery_staging_cleanup_failure_is_detectable

    baseline_staging_state="${parse_tmp}-baseline-staging"
    unit_baseline_staging_is_detected() (
        STATE_DIR="${baseline_staging_state}"
        mkdir -p "${STATE_DIR}/runs" "${STATE_DIR}/transactions" "${STATE_DIR}/baseline" || return 1
        chmod 0700 "${STATE_DIR}" "${STATE_DIR}/runs" "${STATE_DIR}/transactions" "${STATE_DIR}/baseline" || return 1
        mkdir -m 0700 "${STATE_DIR}/baseline/.initial.ABCDEFGH" || return 1
        ensure_secure_state
    )
    assert_failure 'unpublished baseline staging material is detected fail-closed' \
        unit_baseline_staging_is_detected

    baseline_staging_recovery_state="${parse_tmp}-baseline-staging-recovery"
    unit_baseline_staging_cleanup_can_be_retried() (
        local state="${baseline_staging_recovery_state}" staging
        STATE_DIR="${state}"
        ensure_state_dirs || return 1
        staging="${STATE_DIR}/baseline/.initial.ABCDEFGH"
        mkdir -m 0700 "${staging}" || return 1
        APPLY_BASELINE_CREATED=1
        remove_new_initial_baseline 1 || return 1
        [[ ! -e "${staging}" && ! -L "${staging}" && "${APPLY_BASELINE_CREATED}" == 0 ]]
    )
    assert_success 'authenticated baseline cleanup can retry safe staging removal' \
        unit_baseline_staging_cleanup_can_be_retried

    transaction_staging_state="${parse_tmp}-transaction-staging"
    unit_transaction_staging_is_detected_by_secure_state() (
        STATE_DIR="${transaction_staging_state}"
        mkdir -p "${STATE_DIR}/runs" "${STATE_DIR}/transactions" "${STATE_DIR}/baseline" || return 1
        chmod 0700 "${STATE_DIR}" "${STATE_DIR}/runs" "${STATE_DIR}/transactions" "${STATE_DIR}/baseline" || return 1
        mkdir -m 0700 "${STATE_DIR}/transactions/.run-1.ABCDEFGH" || return 1
        ensure_secure_state
    )
    assert_failure 'unpublished transaction staging material is detected fail-closed by state readers' \
        unit_transaction_staging_is_detected_by_secure_state

    transaction_artifact_state="${parse_tmp}-transaction-artifacts"
    unit_transaction_unknown_artifact_is_detected() (
        local transaction="${transaction_artifact_state}/transactions/run-1"
        STATE_DIR="${transaction_artifact_state}"
        mkdir -p "${transaction}/files" || return 1
        chmod 0700 "${transaction_artifact_state}" "${transaction_artifact_state}/transactions" "${transaction}" "${transaction}/files" || return 1
        : > "${transaction}/.apply-report.ABCDEFGH" || return 1
        chmod 0600 "${transaction}/.apply-report.ABCDEFGH" || return 1
        transaction_artifacts_are_known "${transaction}"
    )
    assert_failure 'published transaction readers reject leftover hidden report staging' \
        unit_transaction_unknown_artifact_is_detected

    recovery_marker_state="${parse_tmp}-recovery-marker"
    unit_recovery_failure_marker_is_explicit() (
        local backup="${recovery_marker_state}/.recovery-unit-rollback.ABCDEFGH"
        STATE_DIR="${recovery_marker_state}"
        mkdir -p "${STATE_DIR}/runs" "${STATE_DIR}/transactions" "${STATE_DIR}/baseline" "${backup}" || return 1
        chmod 0700 "${STATE_DIR}" "${STATE_DIR}/runs" "${STATE_DIR}/transactions" "${STATE_DIR}/baseline" "${backup}" || return 1
        printf '%s\n' 'automatic compensation incomplete' > "${backup}/recovery-failed" || return 1
        chmod 0600 "${backup}/recovery-failed" || return 1
        recovery_failure_marker_is_safe "${backup}" || return 1
        ensure_secure_state
    )
assert_failure 'incomplete recovery compensation leaves an explicit detectable marker' \
        unit_recovery_failure_marker_is_explicit

baseline_cleanup_marker_state="$parse_tmp/baseline-cleanup-marker"
unit_baseline_cleanup_marker_is_detectable() (
    local state="$baseline_cleanup_marker_state" marker
    STATE_DIR="$state"
    mkdir -p "$state/runs" "$state/transactions" "$state/baseline" || return 1
    chmod 0700 "$state" "$state/runs" "$state/transactions" "$state/baseline" || return 1
    marker="$state/.baseline-rollback.run-1"
    printf 'run-1\tbaseline-cleanup-pending\n' > "$marker" || return 1
    chmod 0600 "$marker" || return 1
    baseline_cleanup_marker_is_safe "$marker" || return 1
    ensure_secure_state
)
assert_failure 'baseline cleanup failure leaves an explicit detectable marker' \
    unit_baseline_cleanup_marker_is_detectable

    unit_transaction_staging_is_ignored() (
        STATE_DIR="${state_format_parent}/staging-state"
        mkdir -p "${STATE_DIR}/runs" "${STATE_DIR}/transactions" "${STATE_DIR}/baseline" || return 1
        chmod 0700 "${STATE_DIR}" "${STATE_DIR}/runs" "${STATE_DIR}/transactions" "${STATE_DIR}/baseline" || return 1
        mkdir -m 0700 "${STATE_DIR}/transactions/.run-1.ABCDEFGH" || return 1
        validate_transaction_chain
    )
    assert_success 'low-level chain validation ignores unpublished transaction staging' \
        unit_transaction_staging_is_ignored
    unit_unknown_transaction_directory_fails_closed() (
        STATE_DIR="${state_format_parent}/unknown-state"
        mkdir -p "${STATE_DIR}/runs" "${STATE_DIR}/transactions" "${STATE_DIR}/baseline" || return 1
        chmod 0700 "${STATE_DIR}" "${STATE_DIR}/runs" "${STATE_DIR}/transactions" "${STATE_DIR}/baseline" || return 1
        mkdir -m 0700 "${STATE_DIR}/transactions/.not-a-staging-dir" || return 1
        validate_transaction_chain
    )
    assert_failure 'unknown transaction directories still fail closed' \
        unit_unknown_transaction_directory_fails_closed

    printf '%s\n' \
        'Inter-|   Receive                                                |  Transmit' \
        ' face |bytes packets errs drop fifo frame compressed multicast|bytes packets errs drop fifo colls carrier compressed' \
        'test0: 100 1 0 0 0 0 0 0 200 1 0 0 0 0 0 0' \
        > "${safety_dir}/proc/net/dev"
    printf '1500\n' > "${safety_dir}/sys/class/net/test0/mtu"

    unit_interface_counter() (
        PROC_ROOT="${safety_dir}/proc"
        interface_bytes test0
    )
    unit_missing_interface_counter() (
        PROC_ROOT="${safety_dir}/proc"
        interface_bytes missing0
    )
    unit_unreadable_interface_counter() (
        PROC_ROOT="${safety_dir}/missing-proc"
        interface_bytes test0
    )
    assert_output '300' 'interface byte counter sums RX and TX' unit_interface_counter
    assert_failure 'interface byte counter fails when the interface is absent' \
        unit_missing_interface_counter
    assert_failure 'interface byte counter fails when proc data is unavailable' \
        unit_unreadable_interface_counter
    printf 'test0: malformed 1 0 0 0 0 0 0 0 200 1 0 0 0 0 0 0\n' \
        > "${safety_dir}/proc/net/dev"
    assert_failure 'interface byte counter rejects malformed proc fields' \
        unit_interface_counter
    printf 'test0: 9999999999999999999 1 0 0 0 0 0 0 9999999999999999999 1 0 0 0 0 0 0\n' \
        > "${safety_dir}/proc/net/dev"
    assert_failure 'interface byte counter rejects integer overflow' \
        unit_interface_counter

    printf '000000000000000a 000000000000000b 000000000000000c 0\n' \
        > "${safety_dir}/proc/net/softnet_stat"
    unit_softnet_counter() (
        PROC_ROOT="${safety_dir}/proc"
        softnet_totals
    )
    assert_output '10 11 12' 'softnet hex counters are converted safely' unit_softnet_counter
    printf 'ffffffffffffffff 0000000000000000 0000000000000000 0\n' \
        > "${safety_dir}/proc/net/softnet_stat"
    assert_output 'NA NA NA' 'softnet counter overflow fails closed as unavailable' unit_softnet_counter

    printf 'cpu 1 2 3 4 5 6 7 8 9 10\n' > "${safety_dir}/proc/stat"
    unit_cpu_snapshot() (
        PROC_ROOT="${safety_dir}/proc"
        cpu_snapshot
    )
    assert_output '36 9 8' 'cpu snapshot parses validated aggregate counters' unit_cpu_snapshot
    printf 'cpu bad 2 3 4 5 6 7 8 9 10\n' > "${safety_dir}/proc/stat"
    assert_failure 'cpu snapshot rejects malformed counters' unit_cpu_snapshot

    unit_route_direct() (
        ip() {
            [[ "$2" != -o ]] || set -- "$1" "${@:3}"
            if [[ "$4" == fibmatch ]]; then
                [[ "$5" == 203.0.113.1 ]] || return 1
            else
                [[ "$4" == 203.0.113.1 ]] || return 1
            fi
            printf '203.0.113.1 via 192.0.2.1 dev test0 src 192.0.2.2\n'
        }
        route_is_unambiguous 4 203.0.113.1 192.0.2.2
    )
    unit_route_ecmp() (
        ip() {
            printf '%s\n' \
                '203.0.113.1 proto static metric 10' \
                '    nexthop via 192.0.2.1 dev test0 weight 1' \
                '    nexthop via 192.0.2.5 dev test1 weight 1'
        }
        route_is_unambiguous 4 203.0.113.1 192.0.2.2
    )
    assert_success 'route check accepts one direct nexthop' unit_route_direct
    assert_failure 'route check rejects an ECMP nexthop set' unit_route_ecmp

    unit_route_cache_metadata() (
        ip() {
            if [[ "$2" == -o ]]; then
                printf '203.0.113.1 via 192.0.2.1 dev test0 src 192.0.2.2 \\ cache\n'
            else
                printf '203.0.113.1 via 192.0.2.1 dev test0 src 192.0.2.2\n    cache\n'
            fi
        }
        route_is_unambiguous 4 203.0.113.1 192.0.2.2
    )
    unit_route_source_fingerprint() (
        ip() {
            if [[ "${5:-}" == from ]]; then
                printf '203.0.113.1 from 192.0.2.2 via 192.0.2.1 dev test0 uid 0\n    cache\n'
            else
                printf '203.0.113.1 via 192.0.2.1 dev test0 src 192.0.2.2 uid 0\n    cache\n'
            fi
        }
        local initial_details initial_hash bound_hash
        initial_details=$(route_details 4 203.0.113.1) || return 1
        initial_hash=$(printf '%s' "$initial_details" | sha256_text) || return 1
        bound_hash=$(route_fingerprint 4 203.0.113.1 192.0.2.2) || return 1
        [[ "$initial_hash" == "$bound_hash" ]]
    )
    assert_success 'route check accepts cache metadata within a single record' unit_route_cache_metadata
    assert_success 'explicit source lookup preserves the frozen route fingerprint' unit_route_source_fingerprint
    assert_failure 'one-line ECMP output remains ambiguous' route_output_has_unique_nexthop \
        '203.0.113.0/24 nexthop via 192.0.2.1 dev test0 weight 1\ nexthop via 192.0.2.5 dev test1 weight 1'
    assert_failure 'multiple independent route records remain ambiguous' route_output_has_unique_nexthop \
        $'203.0.113.1 dev test0\n203.0.113.1 dev test1'

    unit_qdisc_default() (
        SYS_ROOT="${safety_dir}/sys"
        interface_queue_counts() { printf '1/1\n'; }
        interface_qdisc_kind() { printf 'fq_codel\n'; }
        tc() {
            case "$1" in
                qdisc) printf 'qdisc fq_codel 0: root refcnt 2 limit 10240p flows 1024 quantum 1514 target 5ms interval 100ms memory_limit 32Mb ecn drop_batch 64\n' ;;
                class|filter) : ;;
                *) return 1 ;;
            esac
        }
        qdisc_fresh_candidate test0
    )
    unit_qdisc_custom() (
        SYS_ROOT="${safety_dir}/sys"
        interface_queue_counts() { printf '1/1\n'; }
        interface_qdisc_kind() { printf 'fq_codel\n'; }
        tc() {
            case "$1" in
                qdisc) printf 'qdisc fq_codel 0: root limit 2048p flows 1024 quantum 1514 target 5ms interval 100ms memory_limit 32Mb ecn drop_batch 64\n' ;;
                class|filter) : ;;
                *) return 1 ;;
            esac
        }
        qdisc_fresh_candidate test0
    )
    unit_qdisc_default_pfifo_fast() (
        interface_queue_counts() { printf '1/1\n'; }
        interface_qdisc_kind() { printf 'pfifo_fast\n'; }
        tc() {
            case "$1" in
                qdisc) printf 'qdisc pfifo_fast 0: root refcnt 2 bands 3 priomap 1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1\n' ;;
                class|filter) : ;;
                *) return 1 ;;
            esac
        }
        qdisc_fresh_candidate test0
    )
    unit_qdisc_custom_pfifo_fast() (
        interface_queue_counts() { printf '1/1\n'; }
        interface_qdisc_kind() { printf 'pfifo_fast\n'; }
        tc() {
            case "$1" in
                qdisc) printf 'qdisc pfifo_fast 0: root bands 3 priomap 0 0 0 0 0 0 0 0 1 1 1 1 1 1 1 1\n' ;;
                class|filter) : ;;
                *) return 1 ;;
            esac
        }
        qdisc_fresh_candidate test0
    )
    unit_qdisc_complex() (
        interface_queue_counts() { printf '1/1\n'; }
        interface_qdisc_kind() { printf 'htb\n'; }
        qdisc_fresh_candidate test0
    )
    unit_qdisc_multiqueue() (
        interface_queue_counts() { printf '1/4\n'; }
        qdisc_fresh_candidate test0
    )
    unit_qdisc_rx_multiqueue() (
        interface_queue_counts() { printf '4/1\n'; }
        qdisc_fresh_candidate test0
    )
    unit_qdisc_already_fq() (
        interface_queue_counts() { printf '1/1\n'; }
        interface_qdisc_kind() { printf 'fq\n'; }
        tc() {
            case "$1" in
                qdisc) printf 'qdisc fq 0: root\n' ;;
                class|filter) : ;;
                *) return 1 ;;
            esac
        }
        qdisc_fresh_candidate test0
        [[ $? == 2 ]]
    )
    unit_qdisc_fq_with_filter() (
        interface_queue_counts() { printf '1/1\n'; }
        interface_qdisc_kind() { printf 'fq\n'; }
        tc() {
            case "$1" in
                qdisc) printf 'qdisc fq 0: root\n' ;;
                class) : ;;
                filter) printf 'filter parent 1: protocol ip pref 1 fw\n' ;;
                *) return 1 ;;
            esac
        }
        qdisc_fresh_candidate test0
    )
    assert_success 'fresh qdisc accepts only exact default fq_codel' unit_qdisc_default
    assert_failure 'fresh qdisc rejects customized fq_codel parameters' unit_qdisc_custom
    assert_success 'fresh qdisc accepts exact default pfifo_fast priomap' unit_qdisc_default_pfifo_fast
    assert_failure 'fresh qdisc rejects customized pfifo_fast priomap' unit_qdisc_custom_pfifo_fast
    assert_failure 'fresh qdisc rejects a classful topology' unit_qdisc_complex
    assert_failure 'fresh qdisc rejects a multi-queue interface' unit_qdisc_multiqueue
    assert_failure 'fresh qdisc rejects an RX-multi/TX-single interface' unit_qdisc_rx_multiqueue
    assert_success 'fresh qdisc treats an existing fq as a no-op' unit_qdisc_already_fq
    assert_failure 'fresh qdisc rejects an fq interface with filters' unit_qdisc_fq_with_filter

    unit_qdisc_restore_spec() (
        tc() {
            case "$1" in
                qdisc) printf 'qdisc fq_codel 0: root refcnt 2 limit 10240p flows 1024 quantum 1514 target 5ms interval 100ms memory_limit 32Mb ecn drop_batch 64\n' ;;
                *) return 1 ;;
            esac
        }
        spec=$(qdisc_root_restore_spec test0) || return 1
        [[ "$spec" == 'fq_codel limit 10240p flows 1024 quantum 1514 target 5ms interval 100ms memory_limit 32Mb ecn drop_batch 64' ]] || return 1
        qdisc_spec_is_safe "$spec" || return 1
        ! qdisc_spec_is_safe 'fq_codel limit 10240p; rm -rf /'
    )
    assert_success 'qdisc rollback captures and validates an allowlisted replay spec' \
        unit_qdisc_restore_spec

    unit_pfifo_fast_replay_uses_kernel_defaults() (
        local observed_tc_args="" IFS=' '
        tc() { observed_tc_args="$*"; [[ "$*" == 'qdisc replace dev test0 root pfifo_fast' ]]; }
        qdisc_replace_from_spec test0 'pfifo_fast bands 3 priomap 1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1' || return 1
        [[ "$observed_tc_args" == 'qdisc replace dev test0 root pfifo_fast' ]] || return 1
        observed_tc_args=""
        if qdisc_replace_from_spec test0 'pfifo_fast bands 3 priomap 0 0 0'; then return 1; fi
        [[ -z "$observed_tc_args" ]]
    )
    assert_success 'pfifo_fast replay omits display-only options and still rejects unsafe specs' \
        unit_pfifo_fast_replay_uses_kernel_defaults

    unit_qdisc_retry() (
        local observed_attempts=0
        restore_transaction() {
            observed_attempts=$((observed_attempts + 1))
            (( observed_attempts >= 3 ))
        }
        sleep() { :; }
        recover_qdisc_phase transaction 1 || return 1
        [[ "$observed_attempts" == 3 ]]
    )
    assert_success 'boot qdisc recovery retries bounded network-late failures' unit_qdisc_retry

    printf 'net.core.rmem_max\t8388608\t212992\ttest recommendation\n' \
        > "${safety_dir}/plan.tsv"
    printf 'net.core.rmem_max = 4194304\n' \
        > "${safety_dir}/etc/sysctl.d/50-admin.conf"
    unit_local_conflict() (
        ETC_ROOT="${safety_dir}/etc"
        RUN_ROOT="${safety_dir}/run"
        SYSCTL_FILE="${safety_dir}/etc/sysctl.d/90-vps-proxy-tune.conf"
        result=$(find_plan_conflicts "${safety_dir}/plan.tsv") || return 1
        [[ "$result" == *$'net.core.rmem_max\t'"${safety_dir}/etc/sysctl.d/50-admin.conf"* ]]
    )
    assert_success 'local sysctl definitions are reported as conflicts' unit_local_conflict
    assert_failure 'plan generation contains no automatic tcp_mtu_probing proposal' \
        grep -E '^[[:space:]]*append_plan_value(_forced)?[^#]*tcp_mtu_probing' "${PROGRAM}"

    unit_plan_change_types() (
        local output="${safety_dir}/change-types.tsv"
        : > "${output}" || return 1
        append_plan_value_forced "${output}" net.core.default_qdisc fq fq 'already active' || return 1
        append_plan_value_forced "${output}" net.core.default_qdisc fq_codel fq 'runtime change' || return 1
        [[ "$(awk -F '\t' 'NR==1{print $5}' "${output}")" == persist_only &&
           "$(awk -F '\t' 'NR==2{print $5}' "${output}")" == runtime_change ]]
    )
    assert_success 'plan entries distinguish runtime changes from persistence-only changes' \
        unit_plan_change_types

    unit_plan_record_fields_reject_controls() (
        local output="${safety_dir}/control-fields.tsv"
        : > "${output}" || return 1
        if append_plan_value "${output}" net.core.rmem_max $'1\r2' 0 'invalid'; then
            return 1
        fi
        printf 'net.core.rmem_max\t1\t0\treason\rwith-cr\truntime_change\n' > "${output}" || return 1
        ! validate_plan_file "${output}"
    )
    assert_success 'plan and sysctl record fields reject carriage-return injection' \
        unit_plan_record_fields_reject_controls

    printf '# Managed by vps-proxy-tune v1.2.3. Do not edit; use rollback/uninstall.\n' \
        > "${safety_dir}/legacy-owned.conf"
    assert_success 'legacy versioned ownership markers remain recognizable during upgrade' \
        managed_file_has_marker "${safety_dir}/legacy-owned.conf"
    printf '# Managed by vps-proxy-tune v9.0.0. Do not edit; use rollback/uninstall.\n' \
        > "${safety_dir}/unknown-owned.conf"
    assert_failure 'unknown ownership marker versions are not trusted' \
        managed_file_has_marker "${safety_dir}/unknown-owned.conf"
    managed_marker > "${safety_dir}/stable-owned.conf"
    assert_success 'stable ownership marker is recognized' \
        managed_file_has_marker "${safety_dir}/stable-owned.conf"
    { managed_marker; managed_metadata run-1; } > "${safety_dir}/current-owned.conf"
    assert_success 'current ownership metadata is accepted for controlled writes' \
        managed_file_is_known_owned "${safety_dir}/current-owned.conf"
    {
        managed_marker
        printf '# Format-Version: 99\n# Writer-Version: 99.0.0\n'
    } > "${safety_dir}/unknown-format-owned.conf"
    assert_failure 'unknown owned file metadata cannot authorize migration' \
        managed_file_is_known_owned "${safety_dir}/unknown-format-owned.conf"
    {
        managed_marker
        managed_metadata run-1
        printf '# Format-Version: 99\n'
    } > "${safety_dir}/hidden-unknown-format-owned.conf"
    assert_failure 'unknown metadata hidden after the header cannot authorize migration' \
        managed_file_is_known_owned "${safety_dir}/hidden-unknown-format-owned.conf"

    printf 'payload\n' > "${safety_dir}/atomic.source"
    printf 'administrator value\n' > "${safety_dir}/atomic.target"
    unit_atomic_write_failure() (
        install() { return 1; }
        if atomic_install "${safety_dir}/atomic.source" "${safety_dir}/atomic.target" 0644; then
            return 1
        fi
        grep -Fqx 'administrator value' "${safety_dir}/atomic.target"
    )
    assert_success 'atomic install failure preserves the previous target' unit_atomic_write_failure

    hash_state="${safety_dir}/hash-state"
    mkdir "${hash_state}"
    chmod 0700 "${hash_state}"
    printf 'hash-bound payload\n' > "${hash_state}/artifact"
    unit_private_hash_record_roundtrip() (
        STATE_DIR="${hash_state}"
        write_private_hash_record "${hash_state}/artifact" "${hash_state}/artifact.sha256" || return 1
        verify_private_hash_record "${hash_state}/artifact" "${hash_state}/artifact.sha256"
    )
    assert_success 'private hash records bind content, inode and mode' \
        unit_private_hash_record_roundtrip
    printf 'hash-bound payload changed\n' >> "${hash_state}/artifact"
    assert_failure 'private hash records reject content drift' \
        verify_private_hash_record "${hash_state}/artifact" "${hash_state}/artifact.sha256"
    printf 'hash-bound payload\n' > "${hash_state}/artifact"
    chmod 0644 "${hash_state}/artifact"
    assert_failure 'private hash records reject mode drift' \
        verify_private_hash_record "${hash_state}/artifact" "${hash_state}/artifact.sha256"
    chmod 0600 "${hash_state}/artifact"
    artifact_hash="$(sha256sum "${hash_state}/artifact" | awk '{print $1}')"
    printf '%s\n' "${artifact_hash}" > "${hash_state}/artifact.sha256"
    chmod 0600 "${hash_state}/artifact.sha256"
    assert_success 'legacy one-field hash records remain readable for migration' \
        verify_private_hash_record "${hash_state}/artifact" "${hash_state}/artifact.sha256"

    unit_missing_module() (
        SYS_ROOT="${safety_dir}/missing-sys"
        command_exists() { return 1; }
        module_available_no_load tcp_bbr
    )
    assert_failure 'missing BBR module is not reported as available' unit_missing_module

    unit_missing_service() (
        command_exists() { [[ "$1" == systemctl ]]; }
        systemctl() {
            if [[ "$1" == show && "$*" == *LoadState* ]]; then
                printf 'not-found\n'
                return 0
            fi
            return 1
        }
        prepare_service_change missing-proxy.service
    )
    assert_failure 'a nonexistent systemd service is rejected' unit_missing_service
    unit_service_preview() (
        command_exists() { [[ "$1" == systemctl ]]; }
        systemctl() {
            if [[ "$*" == *LoadState* ]]; then
                printf 'loaded\n'
            elif [[ "$*" == *LimitNOFILESoft* ]]; then
                printf '1024\n'
            elif [[ "$*" == *LimitNOFILE* ]]; then
                printf '1048576\n'
            else
                return 1
            fi
        }
        sysctl_read() { [[ "$1" == fs.nr_open ]] && printf '1048576\n'; }
        STATE_DIR="${safety_dir}/service-state"
        ETC_ROOT="${safety_dir}/etc"
        prepare_service_change xray.service || return 1
        [[ "$SERVICE_DROPIN_NEEDED" == 1 && "$SERVICE_CURRENT_LIMIT" == 1024:1048576 &&
           "$SERVICE_LIMIT" == 262144 &&
           "$SERVICE_DROPIN_PATH" == "${safety_dir}/etc/systemd/system/xray.service.d/90-vps-proxy-tune.conf" ]] || return 1
        print_service_change_preview xray.service | grep -Fq 'LimitNOFILE soft/hard=1024:1048576 -> 262144:1048576'
    )
    assert_success 'service dry-run data freezes current and target LimitNOFILE values' \
        unit_service_preview
    if command_exists jq; then
        printf '{"changes":[],"rollback_status":"not-applied"}\n' > "${safety_dir}/plan.json"
        unit_service_preview_json() (
            SERVICE_DROPIN_NEEDED=1
            SERVICE_DROPIN_PATH="${safety_dir}/etc/systemd/system/xray.service.d/90-vps-proxy-tune.conf"
            SERVICE_CURRENT_LIMIT=1024:1048576
            SERVICE_CURRENT_LIMIT_SOFT=1024
            SERVICE_CURRENT_LIMIT_HARD=1048576
            SERVICE_LIMIT=262144
            SERVICE_LIMIT_HARD=1048576
            write_apply_preview_json "${safety_dir}/plan.json" xray.service safe |
                jq -e '.rollback_status=="dry-run" and .service_change.change_required==true and
                    .service_change.current_limit_nofile=="1024:1048576" and
                    .service_change.target_limit_nofile==262144 and
                    .service_change.target_hard=="1048576" and
                    .service_change.service_restart==false and (.proposed_changes|length)==1' >/dev/null
        )
    assert_success 'JSON dry-run exposes the exact service drop-in proposal' \
        unit_service_preview_json
    fi
    unit_service_limit_empty_soft() (
        command_exists() { [[ "$1" == systemctl ]]; }
        systemctl() {
            if [[ "$*" == *LoadState* ]]; then printf 'loaded\n'
            elif [[ "$*" == *LimitNOFILESoft* ]]; then printf '\n'
            elif [[ "$*" == *LimitNOFILE* ]]; then printf '1048576\n'
            else return 1; fi
        }
        sysctl_read() { printf '1048576\n'; }
        prepare_service_change xray.service
    )
    unit_service_limit_unknown_hard() (
        command_exists() { [[ "$1" == systemctl ]]; }
        systemctl() {
            if [[ "$*" == *LoadState* ]]; then printf 'loaded\n'
            elif [[ "$*" == *LimitNOFILESoft* ]]; then printf '1024\n'
            elif [[ "$*" == *LimitNOFILE* ]]; then printf 'unknown\n'
            else return 1; fi
        }
        sysctl_read() { printf '1048576\n'; }
        prepare_service_change xray.service
    )
    unit_service_limit_soft_infinity_finite_hard() (
        command_exists() { [[ "$1" == systemctl ]]; }
        systemctl() {
            if [[ "$*" == *LoadState* ]]; then printf 'loaded\n'
            elif [[ "$*" == *LimitNOFILESoft* ]]; then printf 'infinity\n'
            elif [[ "$*" == *LimitNOFILE* ]]; then printf '1048576\n'
            else return 1; fi
        }
        sysctl_read() { printf '1048576\n'; }
        prepare_service_change xray.service
    )
    unit_service_limit_both_infinity_is_satisfied() (
        command_exists() { [[ "$1" == systemctl ]]; }
        systemctl() {
            if [[ "$*" == *LoadState* ]]; then printf 'loaded\n'
            elif [[ "$*" == *LimitNOFILESoft* ]]; then printf 'infinity\n'
            elif [[ "$*" == *LimitNOFILE* ]]; then printf 'infinity\n'
            else return 1; fi
        }
        sysctl_read() { printf '1048576\n'; }
        prepare_service_change xray.service || return 1
        [[ "$SERVICE_DROPIN_NEEDED" == 0 && "$SERVICE_LIMIT_HARD" == infinity ]]
    )
    unit_service_limit_soft_above_hard() (
        command_exists() { [[ "$1" == systemctl ]]; }
        systemctl() {
            if [[ "$*" == *LoadState* ]]; then printf 'loaded\n'
            elif [[ "$*" == *LimitNOFILESoft* ]]; then printf '2048\n'
            elif [[ "$*" == *LimitNOFILE* ]]; then printf '1024\n'
            else return 1; fi
        }
        sysctl_read() { printf '1048576\n'; }
        prepare_service_change xray.service
    )
    unit_service_limit_caps_soft_without_raising_hard() (
        command_exists() { [[ "$1" == systemctl ]]; }
        systemctl() {
            if [[ "$*" == *LoadState* ]]; then printf 'loaded\n'
            elif [[ "$*" == *LimitNOFILESoft* ]]; then printf '1024\n'
            elif [[ "$*" == *LimitNOFILE* ]]; then printf '65536\n'
            else return 1; fi
        }
        sysctl_read() { printf '1048576\n'; }
        prepare_service_change xray.service || return 1
        [[ "$SERVICE_LIMIT" == 65536 && "$SERVICE_LIMIT_HARD" == 65536 ]]
    )
    assert_failure 'empty LimitNOFILE soft value fails closed' unit_service_limit_empty_soft
    assert_failure 'unknown LimitNOFILE hard value fails closed' unit_service_limit_unknown_hard
    assert_failure 'infinity soft with finite hard fails closed' unit_service_limit_soft_infinity_finite_hard
    assert_success 'infinity soft and hard values are accepted without a drop-in' \
        unit_service_limit_both_infinity_is_satisfied
    assert_failure 'LimitNOFILE soft above hard fails closed' unit_service_limit_soft_above_hard
    assert_success 'service limit never raises the existing hard limit' \
        unit_service_limit_caps_soft_without_raising_hard
    unit_service_effective_limit_unknown_pid() (
        SERVICE_LIMIT=262144
        SERVICE_LIMIT_HARD=1048576
        SERVICE_CURRENT_LIMIT=1024:1048576
        systemctl() {
            if [[ "$*" == *'LimitNOFILESoft'* ]]; then printf '262144\n'
            elif [[ "$*" == *'LimitNOFILE'* ]]; then printf '1048576\n'
            elif [[ "$*" == *'MainPID'* ]]; then printf 'unknown\n'
            else return 1; fi
        }
        verify_service_limit_after_reload xray.service
    )
    assert_failure 'post-reload service verification rejects unknown MainPID' \
        unit_service_effective_limit_unknown_pid

    unit_apply_dry_run_is_stateless() (
        local dry_state="${safety_dir}/dry-apply-state" dry_run_dir="${safety_dir}/dry-apply-run"
        mkdir -p "${dry_run_dir}" || return 1
        : > "${dry_run_dir}/plan.sha256"
        : > "${dry_run_dir}/metrics.tsv"
        : > "${dry_run_dir}/plan.tsv"
        require_root() { :; }
        require_real_apply_roots() { :; }
        supported_os() { :; }
        supported_arch() { :; }
        is_container() { return 1; }
        require_preview_commands() { :; }
        ensure_secure_state() { :; }
        validate_transaction_chain() { :; }
        run_directory() { printf '%s\n' "${dry_run_dir}"; }
        verify_hash_manifest() { :; }
        metric_get() {
            case "$2" in CONFIDENCE) printf 'high\n' ;; RETRANS_KNOWN) printf '1\n' ;; *) return 1 ;; esac
        }
        plan_contains_key() { return 1; }
        validate_plan_file() { :; }
        run_measurement_context_is_current() { :; }
        plan_current_is_safe() { :; }
        prepare_service_change() {
            SERVICE_DROPIN_NEEDED=0; SERVICE_DROPIN_PATH=""; SERVICE_CURRENT_LIMIT=""
            SERVICE_CURRENT_LIMIT_SOFT=""; SERVICE_CURRENT_LIMIT_HARD=""; SERVICE_LIMIT=0; SERVICE_LIMIT_HARD=""
        }
        build_persisted_sysctl() { : > "$3"; }
        persisted_file_as_plan() { : > "$2"; }
        verify_retained_runtime() { :; }
        find_plan_conflicts() { :; }
        write_apply_preview_json() { printf '{"outcome":"ok","reason_code":"apply_preview"}\n'; }
        write_current_run() { : > "${safety_dir}/dry-run-state-write"; return 1; }
        acquire_lock() { : > "${safety_dir}/dry-run-lock-write"; return 1; }
        cmd_apply --run run-dry --dry-run --json > "${safety_dir}/dry-apply.json" || return 1
        [[ ! -e "${dry_state}/current_run" && ! -e "${dry_state}/transactions" &&
           ! -e "${safety_dir}/dry-run-state-write" && ! -e "${safety_dir}/dry-run-lock-write" ]]
    )
    assert_success 'apply dry-run leaves no current_run, transaction or lock state' \
        unit_apply_dry_run_is_stateless
    unit_apply_dependency_gate() (
        local installed=0
        INSTALL_DEPS=1
        command_exists() {
            (( installed == 1 )) || [[ "$1" != jq && "$1" != systemd-run && "$1" != modprobe ]]
        }
        install_dependencies() { installed=1; }
        require_apply_commands
    )
    assert_success 'apply dependency installation can repair recovery command gaps' \
        unit_apply_dependency_gate
    assert_failure 'implementation contains no automatic service restart command' \
        grep -E 'systemctl[[:space:]]+(restart|try-restart)' "${PROGRAM}"

    mkdir "${safety_dir}/transaction"
    : > "${safety_dir}/transaction/status.lock"
    printf 'applying\n' > "${safety_dir}/transaction/status"
    unit_status_compare_and_swap() (
        flock() { return 0; }
        compare_set_transaction_status "${safety_dir}/transaction" applying committed || return 1
        if compare_set_transaction_status "${safety_dir}/transaction" applying guard-restoring; then
            return 1
        fi
        [[ $(<"${safety_dir}/transaction/status") == committed ]]
    )
    assert_success 'commit and rollback guard use a compare-and-swap handshake' \
        unit_status_compare_and_swap

    transaction_dir="${safety_dir}/state/transactions/run-1"
    mkdir -p "${transaction_dir}/files"
    chmod 0700 "${safety_dir}/state" "${safety_dir}/state/transactions" "${transaction_dir}" "${transaction_dir}/files"
    printf 'committed\n' > "${transaction_dir}/status"
    : > "${transaction_dir}/status.lock"
    chmod 0600 "${transaction_dir}/status" "${transaction_dir}/status.lock"
    printf '%s\n' \
        $'RUN_ID\trun-1' \
        $'PREVIOUS_RUN\t' \
        $'MODE\tsafe' \
        $'SERVICE\t' \
        $'APPLY_PID\t123' \
        $'APPLY_STARTTIME\t456' \
        $'QDISC_CHANGED\t0' \
        $'GUARD_UNIT\t' \
        $'SYSCTL_HASH\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
        > "${transaction_dir}/meta.tsv"
    chmod 0600 "${transaction_dir}/meta.tsv"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${transaction_dir}/guard-script.sh"
    : > "${transaction_dir}/runtime.before.tsv"
    : > "${transaction_dir}/desired.tsv"
    : > "${transaction_dir}/files.tsv"
    printf '{}\n' > "${transaction_dir}/apply.json"
    : > "${transaction_dir}/snapshot.sha256"
    chmod 0600 "${transaction_dir}/runtime.before.tsv" "${transaction_dir}/desired.tsv" \
        "${transaction_dir}/files.tsv" "${transaction_dir}/apply.json" "${transaction_dir}/snapshot.sha256"
    chmod 0600 "${transaction_dir}/guard-script.sh"
    for snapshot_name in guard-script.sh runtime.before.tsv desired.tsv files.tsv; do
        snapshot_hash=$(sha256sum "${transaction_dir}/${snapshot_name}" | awk '{print $1}')
        printf '%s  %s\n' "${snapshot_hash}" "${snapshot_name}" >> "${transaction_dir}/snapshot.sha256"
    done
    printf 'run-1\n' > "${safety_dir}/state/current_run"
    unit_transaction_chain() (
        STATE_DIR="${safety_dir}/state"
        validate_transaction_chain
    )
    legacy_transaction_dir="${safety_dir}/run-legacy"
    cp -a "${transaction_dir}" "${legacy_transaction_dir}"
    sed -i -e 's/run-1/run-legacy/g' -e '/^APPLY_PID/d' -e '/^APPLY_STARTTIME/d' \
        "${legacy_transaction_dir}/meta.tsv"
    unit_legacy_terminal_transaction() (
        STATE_DIR="${safety_dir}/state"
        transaction_snapshot_is_valid "${legacy_transaction_dir}"
    )
    assert_success 'v1 terminal transactions without apply-owner metadata remain readable' \
        unit_legacy_terminal_transaction
    # Keep the v2 fixture in its own private state tree so its companion hash
    # records exercise the same path allow-list without becoming an unrelated
    # orphan in the primary transaction chain.
    v2_state_dir="${safety_dir}/v2-state"
    mkdir -p "${v2_state_dir}/transactions" || exit 1
    chmod 0700 "${v2_state_dir}" "${v2_state_dir}/transactions" || exit 1
    v2_transaction_dir="${v2_state_dir}/transactions/run-v2"
    cp -a "${transaction_dir}" "${v2_transaction_dir}"
    sed -i 's/run-1/run-v2/g' "${v2_transaction_dir}/meta.tsv"
    printf '%s\n' $'MANAGED_BY\tvps-proxy-tune' $'FORMAT_VERSION\t2' $'WRITER_VERSION\t2.1.0' >> "${v2_transaction_dir}/meta.tsv"
    unit_v2_transaction_dynamic_hashes() (
        STATE_DIR="${v2_state_dir}"
        write_private_hash_record "${v2_transaction_dir}/meta.tsv" "${v2_transaction_dir}/meta.sha256" || return 1
        write_private_hash_record "${v2_transaction_dir}/status" "${v2_transaction_dir}/status.sha256" || return 1
        : > "${v2_transaction_dir}/changes.tsv" || return 1
        : > "${v2_transaction_dir}/apply.warnings" || return 1
        chmod 0600 "${v2_transaction_dir}/changes.tsv" "${v2_transaction_dir}/apply.warnings" || return 1
        write_private_hash_record "${v2_transaction_dir}/changes.tsv" "${v2_transaction_dir}/changes.tsv.sha256" || return 1
        write_private_hash_record "${v2_transaction_dir}/apply.warnings" "${v2_transaction_dir}/apply.warnings.sha256" || return 1
        write_private_hash_record "${v2_transaction_dir}/apply.json" "${v2_transaction_dir}/apply.json.sha256" || return 1
        transaction_snapshot_is_valid "${v2_transaction_dir}"
    )
    assert_success 'v2 transactions authenticate mutable metadata and status files' \
        unit_v2_transaction_dynamic_hashes
    mutable_transaction_dir="${v2_state_dir}/transactions/run-v2-mutable"
    cp -a "${v2_transaction_dir}" "${mutable_transaction_dir}"
    sed -i 's/run-v2/run-v2-mutable/g' "${mutable_transaction_dir}/meta.tsv"
    unit_v2_mutable_artifact_hashes() (
        STATE_DIR="${v2_state_dir}"
        write_private_hash_record "${mutable_transaction_dir}/meta.tsv" "${mutable_transaction_dir}/meta.sha256" || return 1
        transaction_append_mutable_line "${mutable_transaction_dir}" apply.warnings 'new warning' || return 1
        transaction_append_mutable_line "${mutable_transaction_dir}" changes.tsv $'sysctl\tnet.core.rmem_max\t1\t2\truntime_change' || return 1
        transaction_snapshot_is_valid "${mutable_transaction_dir}" || return 1
        printf 'tampered\n' >> "${mutable_transaction_dir}/changes.tsv"
        transaction_snapshot_is_valid "${mutable_transaction_dir}"
    )
    assert_failure 'v2 transaction changes and warnings sidecars detect drift' \
        unit_v2_mutable_artifact_hashes
    v2_missing_owner_dir="${v2_state_dir}/transactions/run-v2-noowner"
    cp -a "${v2_transaction_dir}" "${v2_missing_owner_dir}"
    sed -i -e 's/run-v2/run-v2-noowner/g' -e '/^MANAGED_BY/d' "${v2_missing_owner_dir}/meta.tsv"
    unit_v2_missing_owner() (
        STATE_DIR="${v2_state_dir}"
        write_private_hash_record "${v2_missing_owner_dir}/meta.tsv" "${v2_missing_owner_dir}/meta.sha256" || return 1
        write_private_hash_record "${v2_missing_owner_dir}/status" "${v2_missing_owner_dir}/status.sha256" || return 1
        transaction_snapshot_is_valid "${v2_missing_owner_dir}"
    )
    assert_failure 'v2 transactions require an explicit Managed-By owner field' \
        unit_v2_missing_owner
    printf 'tampered\n' >> "${v2_transaction_dir}/meta.tsv"
    assert_failure 'v2 transaction metadata drift is detected before recovery' \
        transaction_snapshot_is_valid "${v2_transaction_dir}"
    sed -i '$d' "${v2_transaction_dir}/meta.tsv"
    unit_v2_status_hash_drift() (
        STATE_DIR="${v2_state_dir}"
        write_private_hash_record "${v2_transaction_dir}/meta.tsv" "${v2_transaction_dir}/meta.sha256" || return 1
        printf 'tampered\n' >> "${v2_transaction_dir}/status"
        transaction_snapshot_is_valid "${v2_transaction_dir}"
    )
    assert_failure 'v2 transaction status drift is detected before recovery' \
        unit_v2_status_hash_drift
    duplicate_transaction_dir="${safety_dir}/duplicate-transaction"
    cp -a "${transaction_dir}" "${duplicate_transaction_dir}"
    sed -i 's/run-1/duplicate/g' "${duplicate_transaction_dir}/meta.tsv"
    printf 'MODE\tsafe\n' >> "${duplicate_transaction_dir}/meta.tsv"
    unit_duplicate_immutable_metadata() (
        STATE_DIR="${safety_dir}/state"
        transaction_snapshot_is_valid "${duplicate_transaction_dir}"
    )
    assert_failure 'transaction metadata rejects duplicate immutable chain fields' \
        unit_duplicate_immutable_metadata
    unit_transaction_snapshot_tamper() (
        {
            printf '%064d  guard-script.sh\n' 0
            sed -n '2,$p' "${transaction_dir}/snapshot.sha256"
        } > "${transaction_dir}/snapshot.sha256.broken" || return 1
        mv "${transaction_dir}/snapshot.sha256.broken" "${transaction_dir}/snapshot.sha256" || return 1
        STATE_DIR="${safety_dir}/state"
        transaction_snapshot_is_valid "${transaction_dir}"
    )
    assert_success 'a complete committed transaction chain validates' unit_transaction_chain
    assert_failure 'transaction snapshot manifest tampering is detected' unit_transaction_snapshot_tamper
    assert_output '' 'transaction metadata preserves an explicit empty value' \
        transaction_get "${transaction_dir}" PREVIOUS_RUN

    unit_owned_snapshot_identity_drift() (
        local root="${safety_dir}/owned-snapshot" transaction target replacement
        transaction="${root}/transaction"
        target="${root}/etc/sysctl.d/90-vps-proxy-tune.conf"
        replacement="${root}/replacement.conf"
        mkdir -p "${root}/etc/sysctl.d" "${transaction}/files" || return 1
        chmod 0700 "${root}" "${root}/etc" "${root}/etc/sysctl.d" "${transaction}" "${transaction}/files" || return 1
        printf 'old\n' > "${target}" || return 1
        chmod 0644 "${target}" || return 1
        : > "${transaction}/files.tsv"
        : > "${transaction}/files.identity.tsv"
        chmod 0600 "${transaction}/files.tsv" "${transaction}/files.identity.tsv" || return 1
        SYSCTL_FILE="${target}"
        snapshot_owned_file sysctl "${target}" "${transaction}/files" \
            "${transaction}/files.tsv" "${transaction}/files.identity.tsv" || return 1
        install -m 0644 "${target}" "${replacement}" || return 1
        mv -f "${replacement}" "${target}" || return 1
        owned_target_matches_snapshot "${transaction}" sysctl
    )
    assert_failure 'owned file snapshot rejects same-content inode replacement' \
        unit_owned_snapshot_identity_drift

    unit_recovery_pair_identity_drift() (
        local root="${parse_tmp}-recovery-pair" target record backup replacement
        local expected_new_hash new_inode new_mode old_inode old_mode
        STATE_DIR="${root}/state"
        ETC_ROOT="${root}/etc"
        target="${STATE_DIR}/recovery-target"
        record="${STATE_DIR}/recovery-target.sha256"
        backup="${STATE_DIR}/backup.before"
        replacement="${STATE_DIR}/replacement"
        mkdir -p "${STATE_DIR}" "${ETC_ROOT}" || return 1
        chmod 0700 "${root}" "${STATE_DIR}" "${ETC_ROOT}" || return 1
        printf 'old\n' > "${target}" || return 1
        chmod 0600 "${target}" || return 1
        install -m 0600 "${target}" "${backup}" || return 1
        old_inode=$(stat -c %i "${target}") || return 1
        old_mode=$(stat -c %a "${target}") || return 1
        printf 'new\n' > "${replacement}" || return 1
        chmod 0600 "${replacement}" || return 1
        mv -f "${replacement}" "${target}" || return 1
        expected_new_hash=$(sha256sum "${target}" | awk '{print $1}') || return 1
        new_inode=$(stat -c %i "${target}") || return 1
        new_mode=$(stat -c %a "${target}") || return 1
        printf 'new\n' > "${replacement}" || return 1
        chmod 0600 "${replacement}" || return 1
        mv -f "${replacement}" "${target}" || return 1
        recovery_restore_pair "${target}" "${record}" "${backup}" 1 0 0600 \
            "${expected_new_hash}" "${new_inode}" "${new_mode}" "${old_inode}" "${old_mode}"
    )
    assert_failure 'recovery rollback rejects same-content replacement after the new write' \
        unit_recovery_pair_identity_drift

    guard_failure_dir="${safety_dir}/guard-failure"
    mkdir "${guard_failure_dir}"
    printf 'GUARD_UNIT\tvps-proxy-tune-guard-test\n' > "${guard_failure_dir}/meta.tsv"
    unit_guard_stop_failure() (
        systemctl() {
            case "$1" in
                show) printf 'loaded\n' ;;
                stop|reset-failed) return 1 ;;
                *) return 1 ;;
            esac
        }
        cancel_rollback_guard "${guard_failure_dir}"
    )
    unit_guard_not_found_is_success() (
        systemctl() {
            [[ "$1" == show ]] && printf 'not-found\n'
        }
        cancel_rollback_guard "${guard_failure_dir}"
    )
    assert_failure 'rollback guard stop/reset failures propagate to the caller' \
        unit_guard_stop_failure
    assert_success 'already absent rollback guard units are treated as successful' \
        unit_guard_not_found_is_success

    unit_process_identity_cleanup() (
        local killed="${safety_dir}/wrong-process-killed"
        process_start_time() { printf '123\n'; }
        terminate_process_tree_signal() { : > "${killed}"; }
        terminate_owned_process 4242 456 TERM
        [[ ! -e "${killed}" ]]
    )
    assert_success 'probe cleanup refuses to signal a reused PID with a different start time' \
        unit_process_identity_cleanup

    mkdir "${safety_dir}/restore"
    printf 'net.core.rmem_max\t100\n' > "${safety_dir}/restore/runtime.before.tsv"
    printf 'net.core.rmem_max\t200\t100\ttest\n' > "${safety_dir}/restore/desired.tsv"
    : > "${safety_dir}/restore/apply.warnings"
    unit_restore_owned_value() (
        sysctl_read() { printf '200\n'; }
        sysctl() { printf '%s\n' "$@" > "${safety_dir}/restore/sysctl.called"; }
        restore_transaction_runtime "${safety_dir}/restore" || return 1
        grep -Fqx -- 'net.core.rmem_max=100' "${safety_dir}/restore/sysctl.called"
    )
    unit_restore_admin_drift() (
        sysctl_read() { printf '300\n'; }
        sysctl() { : > "${safety_dir}/restore/sysctl.unexpected"; }
        if restore_transaction_runtime "${safety_dir}/restore"; then
            return 1
        fi
        [[ ! -e "${safety_dir}/restore/sysctl.unexpected" ]]
    )
    assert_success 'rollback restores a value still owned by the transaction' unit_restore_owned_value
    assert_success 'rollback refuses to overwrite an administrator drift value' unit_restore_admin_drift

    mkdir "${safety_dir}/interrupted-run"
    assert_success 'measurement interruption records an aborted run' \
        measure_interrupt "${safety_dir}/interrupted-run"
    assert_output 'aborted' 'aborted measurement status is durable' \
        head -n 1 "${safety_dir}/interrupted-run/status"

    unit_guard_unavailable() (
        command_exists() { return 1; }
        start_rollback_guard "${safety_dir}/transaction"
    )
    assert_failure 'live qdisc guard fails closed when systemd is unavailable' \
        unit_guard_unavailable

    unit_auto_dry_run_dispatch() (
        collect_audit() { :; }
        cmd_measure() { printf '{"run_id":"run-1"}\n'; }
        cmd_plan() { printf '{"confidence":"high","metrics":{"retransmits_known":true}}\n'; }
        jq() {
            if [[ "$1" == -er && "$2" == .run_id ]]; then printf 'run-1\n'
            elif [[ "$1" == -r && "$2" == .confidence ]]; then printf 'high\n'
            elif [[ "$1" == -r && "$2" == '.metrics.retransmits_known // false' ]]; then printf 'true\n'
            else return 1
            fi
        }
        cmd_apply() { printf '%s\n' "$@" > "${safety_dir}/auto-apply.args"; }
        cmd_auto --peer peer.example --service xray.service --dry-run --json || return 1
        diff -u <(printf '%s\n' --run run-1 --mode safe --service xray.service --dry-run --json) \
            "${safety_dir}/auto-apply.args"
    )
    assert_success 'auto dry-run delegates to the full apply preview including service data' \
        unit_auto_dry_run_dispatch

    printf '%s\n' \
        $'1\t0\t1\t2\t1\t100\t0\t1\t5\t0\t0' \
        $'1\t1\t1\t0\t2\t200\t4\t0\t0\t3\t1' \
        $'0\t1\t0\t0\t0\t300\t5\t2\t0\t0\t0' > "${safety_dir}/pressure.tsv"
    assert_output '2' 'pressure observation preserves raw listen overflow deltas' \
        pressure_delta_sum "${safety_dir}/pressure.tsv" 4
    assert_output '9' 'pressure observation preserves raw softnet drop deltas' \
        pressure_delta_sum "${safety_dir}/pressure.tsv" 7
    assert_output '2' 'pressure observation counts consecutive softnet-drop windows' \
        pressure_consecutive_count "${safety_dir}/pressure.tsv" 2
    assert_output '2' 'pressure observation counts SYN queue event windows' \
        pressure_window_count "${safety_dir}/pressure.tsv" 3
fi

assert_output '5' 'low-RTT peer uses the five-second minimum measurement' \
    measurement_duration_seconds 512 119.999
assert_output '5' 'medium low-RTT peer uses the same bounded minimum' \
    measurement_duration_seconds 128 119.999
assert_output '5' 'moderate-RTT peer uses a five-second measurement' \
    measurement_duration_seconds 512 120
assert_output '5' 'small peer budget still uses the bounded minimum' \
    measurement_duration_seconds 127 50
assert_output '30' 'very high RTT is capped at thirty seconds' \
    measurement_duration_seconds 512 2000
assert_failure 'adaptive duration rejects a zero peer budget' \
    measurement_duration_seconds 0 50
assert_failure 'adaptive duration rejects a malformed RTT' \
    measurement_duration_seconds 512 unknown

unit_verify_profile_five_seconds() {
    local result bytes mib duration capacity target
    result=$(verification_budget_profile "${TEST_GIB}" "$((500 * TEST_MIB))" 250) || return 1
    IFS=$'\t' read -r bytes mib duration capacity target <<< "${result}"
    [[ "$bytes" == 483183820 && "$mib" == 460 && "$duration" == 5 &&
       "$capacity" == 289 && "$target" == 263 ]]
}
assert_success 'verification profile keeps the RTT-derived five-second duration' \
    unit_verify_profile_five_seconds
assert_failure 'verification profile rejects a baseline that cannot fit the bounded duration' \
    verification_budget_profile "${TEST_GIB}" "$((500 * TEST_MIB))" 1000
assert_failure 'verification profile rejects a baseline it cannot measure without pacing bias' \
    verification_budget_profile "${TEST_GIB}" "$((800 * TEST_MIB))" 800
assert_failure 'verification profile rejects wire usage beyond the total budget' \
    verification_budget_profile "${TEST_GIB}" "$((TEST_GIB + 1))" 100

# The rate is aggregate across STREAM_FACTOR test-seconds and reserves 25% of
# the stated transfer budget. Returned rates are integer decimal Mbps.
assert_output '50' 'budget rate reserves 25 percent across four test groups' \
    budget_rate_mbps 256 8 4
assert_output '201' 'budget rate accounts for a single test group' \
    budget_rate_mbps 256 8 1
assert_output '62' 'budget rate uses MiB input and decimal Mbps output' \
    budget_rate_mbps 100 10 1
assert_output '161' 'default 1 GiB budget is divided across four test groups' \
    budget_rate_mbps 1024 10 4
assert_output '4096' 'netdev backlog zero starts at the bounded recovery tier' \
    next_netdev_backlog_tier 0
assert_output '10000' 'netdev backlog tier caps a large queue increase' \
    next_netdev_backlog_tier 6000
assert_output '20000' 'netdev backlog preserves an administrator value above the cap' \
    next_netdev_backlog_tier 20000

printf '%s\n' \
    '# Managed by vps-proxy-tune. Do not edit; use rollback/uninstall.' \
    'net.core.default_qdisc = fq_codel' > "${safety_dir}/owned-sysctl.conf"
printf 'net.core.default_qdisc\tfq\tfq_codel\tpacing\n' > "${safety_dir}/qdisc-plan.tsv"
unit_disabled_pacing_preserves_owned() (
    local output="${safety_dir}/qdisc-output.conf"
    SYSCTL_FILE="${safety_dir}/owned-sysctl.conf"
    PACING_PLAN_ENABLED=0
    build_persisted_sysctl run-1 "${safety_dir}/qdisc-plan.tsv" "${output}" || return 1
    grep -Fqx 'net.core.default_qdisc = fq_codel' "${output}"
)
assert_success 'disabled pacing proposal preserves an existing owned qdisc value' \
    unit_disabled_pacing_preserves_owned

printf '%s\n' \
    '# Managed by vps-proxy-tune. Do not edit; use rollback/uninstall.' \
    '# Source run: legacy-run' \
    'net.ipv4.ip_forward = 0' \
    'net.core.rmem_max 4096' \
    'net.core.default_qdisc = fq_codel' > "${safety_dir}/owned-sysctl-with-extra.conf"
unit_owned_sysctl_extra_is_retained() (
    local output="${safety_dir}/owned-sysctl-with-extra.out"
    local all_plan="${safety_dir}/owned-sysctl-with-extra.plan"
    SYSCTL_FILE="${safety_dir}/owned-sysctl-with-extra.conf"
    PACING_PLAN_ENABLED=0
    build_persisted_sysctl run-2 "${safety_dir}/qdisc-plan.tsv" "${output}" || return 1
    persisted_file_as_plan "${output}" "${all_plan}" || return 1
    grep -Fqx 'net.ipv4.ip_forward = 0' "${output}" &&
        grep -Fqx 'net.core.rmem_max = 4096' "${output}" &&
        grep -Fqx 'net.core.default_qdisc = fq_codel' "${output}" &&
        grep -Fq $'net.core.rmem_max\t4096\t' "${all_plan}" &&
        ! grep -Fq $'net.ipv4.ip_forward\t' "${all_plan}"
)
assert_success 'v2 rewrites retain non-target keys from an older owned sysctl file' \
    unit_owned_sysctl_extra_is_retained
printf '%s\n' \
    '# Managed by vps-proxy-tune. Do not edit; use rollback/uninstall.' \
    'bad;key = 1' > "${safety_dir}/owned-sysctl-invalid-extra.conf"
unit_owned_sysctl_extra_invalid() (
    SYSCTL_FILE="${safety_dir}/owned-sysctl-invalid-extra.conf"
    PACING_PLAN_ENABLED=0
    build_persisted_sysctl run-3 "${safety_dir}/qdisc-plan.tsv" "${safety_dir}/invalid-extra.out"
)
assert_failure 'malformed legacy non-target sysctl entries fail closed' \
    unit_owned_sysctl_extra_invalid
printf '%s\n' \
    '# Managed by vps-proxy-tune. Do not edit; use rollback/uninstall.' \
    'net.core.rmem_max' > "${safety_dir}/owned-sysctl-missing-value.conf"
unit_owned_sysctl_missing_value_invalid() (
    SYSCTL_FILE="${safety_dir}/owned-sysctl-missing-value.conf"
    PACING_PLAN_ENABLED=0
    build_persisted_sysctl run-4 "${safety_dir}/qdisc-plan.tsv" "${safety_dir}/missing-value.out"
)
assert_failure 'owned sysctl parser rejects a target definition with no value' \
    unit_owned_sysctl_missing_value_invalid

unit_qdisc_recovery_install_target() (
    local qdisc_line
    qdisc_line=$(awk '
        /Description=vps-proxy-tune boot qdisc recovery/ { inside=1 }
        inside && /WantedBy=/ { print; exit }
    ' "${PROGRAM}") || return 1
    [[ "${qdisc_line}" == *'WantedBy=multi-user.target'* ]] || return 1
    ! printf '%s\n' "${qdisc_line}" | grep -Fq 'WantedBy=network-online.target'
)
assert_success 'qdisc recovery is enabled by multi-user.target only' \
    unit_qdisc_recovery_install_target

unit_orphan_qdisc_wants_link_is_authenticatable() (
    local root="${safety_dir}/orphan-qdisc" unit link
    mkdir -p "${root}/etc/systemd/system/network-online.target.wants" || return 1
    chmod 0700 "${root}" "${root}/etc" "${root}/etc/systemd" \
        "${root}/etc/systemd/system" "${root}/etc/systemd/system/network-online.target.wants" || return 1
    ETC_ROOT="${root}/etc"
    RECOVERY_QDISC_UNIT_PATH="${root}/etc/systemd/system/vps-proxy-tune-recover-qdisc.service"
    unit="$RECOVERY_QDISC_UNIT_PATH"
    link="$(recovery_qdisc_online_wants_path)"
    ln -s -- "$unit" "$link" || return 1
    [[ "$(systemd_recovery_wants_link_state "$link" "$unit")" == $'present\t'"$unit" ]] || return 1
    remove_managed_recovery_wants_link "$link" "$unit" || return 1
    [[ ! -e "$link" && ! -L "$link" ]]
)
assert_success 'orphan qdisc wants links remain removable when the old unit file is missing' \
    unit_orphan_qdisc_wants_link_is_authenticatable

if command_exists jq; then
    unit_iperf_bitrate_suffix() (
        local expected="$1" transport="$2" tmp seen="" previous="" status
        tmp=$(mktemp -d /tmp/vps-proxy-tune-iperf-unit.XXXXXXXX) || return 1
        timeout() {
            while [[ "$1" == --* ]]; do shift; done
            shift
            "$@"
        }
        iperf3() {
            local arg
            for arg in "$@"; do
                [[ "$previous" == -b ]] && seen="$arg"
                previous="$arg"
            done
            printf '%s\n' '{"end":{"sum_sent":{"bits_per_second":7000000,"bytes":875000,"sender":true,"retransmits":1},"sum_received":{"bits_per_second":7000000,"bytes":875000}},"intervals":[{"sum":{"seconds":0.25,"bits_per_second":7000000}},{"sum":{"seconds":0.25,"bits_per_second":7000000}}]}'
        }
        run_iperf_test unit 192.0.2.1 5201 4 192.0.2.2 2 7 4 0 "$tmp/out.json" 0 "$transport" >/dev/null
        status=$?
        rm -f -- "$tmp/out.json" "$tmp/out.json.stderr"
        rmdir -- "$tmp" 2>/dev/null || true
        (( status == 0 )) || return "$status"
        [[ "$seen" == "$expected" ]] || return 1
        printf '%s\n' "$seen"
    )
    assert_output '1750K' 'iperf3 TCP pacing converts aggregate Mbps to per-stream Kbit/s' \
        unit_iperf_bitrate_suffix 1750K tcp
    assert_output '1750K' 'iperf3 UDP pacing converts aggregate Mbps to per-stream Kbit/s' \
        unit_iperf_bitrate_suffix 1750K udp

    unit_iperf_retrans_fixture() (
        local fixture="$1" reverse="$2" expected_known="$3" expected_retrans="$4" expect_reverse="$5"
        local tmp line result_file name _bps bytes retrans known cv rate saw_reverse=0 status
        tmp=$(mktemp -d /tmp/vps-proxy-tune-iperf-fixture.XXXXXXXX) || return 1
        result_file="$tmp/result.tsv"
        timeout() {
            while [[ "$1" == --* ]]; do shift; done
            shift
            "$@"
        }
        iperf3() {
            local arg
            for arg in "$@"; do
                [[ "$arg" == -R ]] && saw_reverse=1
            done
            printf '%s\n' "$fixture"
        }
        run_iperf_test fixture 192.0.2.1 5201 4 192.0.2.2 2 7 1 "$reverse" \
            "$tmp/out.json" 0 tcp > "$result_file"
        status=$?
        line=$(<"$result_file")
        rm -f -- "$tmp/out.json" "$tmp/out.json.stderr"
        rm -f -- "$result_file"
        rmdir -- "$tmp" 2>/dev/null || true
        (( status == 0 )) || return "$status"
        IFS=$'\t' read -r name _bps bytes retrans known cv rate <<< "$line"
        [[ "$known" == "$expected_known" && "$retrans" == "$expected_retrans" ]] || return 1
        [[ "$saw_reverse" == "$expect_reverse" ]]
    )

    iperf_fixture_normal='{"end":{"sum_sent":{"bits_per_second":7000000,"bytes":875000,"sender":true,"retransmits":1},"sum_received":{"bits_per_second":7000000,"bytes":875000}},"intervals":[{"sum":{"seconds":0.25,"bits_per_second":7000000}},{"sum":{"seconds":0.25,"bits_per_second":7000000}}]}'
    iperf_fixture_reverse='{"end":{"sum_sent":{"bits_per_second":7000000,"bytes":875000,"sender":false,"retransmits":3},"sum_received":{"bits_per_second":7000000,"bytes":875000}},"intervals":[{"sum":{"seconds":0.25,"bits_per_second":7000000}},{"sum":{"seconds":0.25,"bits_per_second":7000000}}]}'
    iperf_fixture_missing='{"end":{"sum_sent":{"bits_per_second":7000000,"bytes":875000,"sender":true},"sum_received":{"bits_per_second":7000000,"bytes":875000}},"intervals":[{"sum":{"seconds":0.25,"bits_per_second":7000000}},{"sum":{"seconds":0.25,"bits_per_second":7000000}}]}'
    iperf_fixture_nonnumeric='{"end":{"sum_sent":{"bits_per_second":7000000,"bytes":875000,"sender":true,"retransmits":"unknown"},"sum_received":{"bits_per_second":7000000,"bytes":875000}},"intervals":[{"sum":{"seconds":0.25,"bits_per_second":7000000}},{"sum":{"seconds":0.25,"bits_per_second":7000000}}]}'
    iperf_fixture_negative='{"end":{"sum_sent":{"bits_per_second":7000000,"bytes":875000,"sender":true,"retransmits":-1},"sum_received":{"bits_per_second":7000000,"bytes":875000}},"intervals":[{"sum":{"seconds":0.25,"bits_per_second":7000000}},{"sum":{"seconds":0.25,"bits_per_second":7000000}}]}'
    iperf_fixture_wrong_direction='{"end":{"sum_sent":{"bits_per_second":7000000,"bytes":875000,"sender":false,"retransmits":9},"sum_received":{"bits_per_second":7000000,"bytes":875000}},"intervals":[{"sum":{"seconds":0.25,"bits_per_second":7000000}},{"sum":{"seconds":0.25,"bits_per_second":7000000}}]}'

    assert_success 'iperf normal sender retransmission is known' \
        unit_iperf_retrans_fixture "$iperf_fixture_normal" 0 1 1 0
    assert_success 'iperf reverse mode uses the receiver-side client JSON sender=false summary' \
        unit_iperf_retrans_fixture "$iperf_fixture_reverse" 1 1 3 1
    assert_success 'missing iperf retransmits stay unknown instead of becoming zero' \
        unit_iperf_retrans_fixture "$iperf_fixture_missing" 0 0 NA 0
    assert_success 'non-numeric iperf retransmits stay unknown' \
        unit_iperf_retrans_fixture "$iperf_fixture_nonnumeric" 0 0 NA 0
    assert_success 'negative iperf retransmits stay unknown' \
        unit_iperf_retrans_fixture "$iperf_fixture_negative" 0 0 NA 0
    assert_success 'iperf sender-direction mismatch stays unknown' \
        unit_iperf_retrans_fixture "$iperf_fixture_wrong_direction" 0 0 NA 0

    unit_measure_report_unknown_retrans() (
        local root="${parse_tmp}/retrans-report" metrics peers
        mkdir -m 0700 "${root}" || return 1
        metrics="${root}/metrics.tsv"
        peers="${root}/peers.json"
        printf '%b\n' \
            'RUN_ID\tfixture-run' \
            'CREATED_AT\t2026-01-01T00:00:00Z' \
            'OS\tfixture-os' \
            'KERNEL\tfixture-kernel' \
            'ARCH\tx86_64' \
            'PROFILE\ttcp' \
            'CONFIDENCE\tlow' \
            'QUALITY\tunknown' \
            'EFFECTIVE_MBPS\t1' \
            'RTT_P95_MS\t10' \
            'LOSS_PCT\t0' \
            'LOSS_KNOWN\t1' \
            'JITTER_MS\t0' \
            'JITTER_KNOWN\t1' \
            'LOADED_DELTA_MS\t0' \
            'RETRANS_PCT\tNA' \
            'RETRANS_KNOWN\t0' \
            'ACTUAL_BYTES\t1000' \
            'WIRE_BYTES\t1000' \
            'BUDGET_BYTES\t2000' \
            'MAX_CV_PCT\t0' \
            'BACKGROUND_PCT\t0' \
            'CPU_BUSY_PCT\t0' \
            'CPU_STEAL_PCT\t0' \
            'VERIFY_RESERVED_BYTES\t0' \
            'VERIFY_DURATION_SECONDS\t0' \
            'VERIFY_CAPACITY_MBPS\t0' \
            'VERIFY_TARGET_MBPS\t0' \
            'LISTEN_OVERFLOW_DELTA\t0' \
            'LISTEN_DROP_DELTA\t0' \
            'SOFTNET_PROCESSED_DELTA\t0' \
            'SOFTNET_DROPPED_DELTA\t0' \
            'SOFTNET_SQUEEZE_DELTA\t0' \
            'LISTEN_PRESSURE_WINDOWS\t0' \
            'SYN_QUEUE_WINDOWS\t0' \
            'SYN_QUEUE_COOKIES_DELTA\t0' \
            'SYN_QUEUE_DROP_DELTA\t0' \
            'SYNCOOKIES_DELTA\t0' \
            'UDP_LOSS_PCT\t0' \
            'UDP_LOSS_KNOWN\t0' \
            'UDP_JITTER_MS\t0' \
            'UDP_JITTER_KNOWN\t0' \
            'UDP_METRICS_COMPLETE\t1' \
            'UDP_TESTS_OK\t0' \
            'UDP_TESTS_TOTAL\t0' \
            'SOFTNET_DROP_WINDOWS\t0' > "${metrics}" || return 1
        printf '[]\n' > "${peers}" || return 1
        chmod 0600 "${metrics}" "${peers}" || return 1
        write_measure_report_json "${root}" "${metrics}" "${peers}" || return 1
        jq -e '.metrics.retransmits_known == false and .metrics.retrans_pct == null' \
            "${root}/report.json" >/dev/null
    )
    assert_success 'measure JSON preserves unknown retransmission as null instead of zero' \
        unit_measure_report_unknown_retrans
else
    pass 'iperf JSON retransmission fixtures skipped because jq is unavailable'
fi

assert_budget_reserved() {
    local budget_mib=$1 duration=$2 stream_factor=$3 description=$4
    local rate status used_bits reserved_bits
    rate="$(budget_rate_mbps "${budget_mib}" "${duration}" "${stream_factor}" 2>/dev/null)"
    status=$?
    if (( status != 0 )) || [[ ! "${rate}" =~ ^[0-9]+$ ]]; then
        fail "${description}" 'budget_rate_mbps did not return an integer rate'
        return
    fi
    used_bits=$((rate * 1000000 * duration * stream_factor))
    reserved_bits=$((budget_mib * 1048576 * 8 * 75 / 100))
    if (( used_bits <= reserved_bits )); then
        pass "${description}"
    else
        fail "${description}" "${used_bits} bits exceeds reserved ${reserved_bits} bits"
    fi
}

assert_budget_reserved 64 7 4 'calculated transfer stays within 75 percent of a small budget'
assert_budget_reserved 1024 10 4 'calculated transfer stays within 75 percent of the default budget'
assert_budget_reserved 4096 30 8 'calculated transfer stays within 75 percent of a large budget'
assert_failure 'budget rate fails when even 1 Mbps would exceed its allowance' \
    budget_rate_mbps 1 10 4
assert_failure 'budget rate rejects a zero budget' budget_rate_mbps 0 10 4
assert_failure 'budget rate rejects zero duration' budget_rate_mbps 100 0 4
assert_failure 'budget rate rejects zero stream factor' budget_rate_mbps 100 10 0
assert_failure 'budget rate rejects a non-canonical leading zero' budget_rate_mbps 01024 10 4
assert_failure 'budget rate rejects malformed input' budget_rate_mbps 100 ten 4

printf '\n%d tests, %d failures\n' "${tests_run}" "${tests_failed}"
if (( tests_failed != 0 )); then
    exit 1
fi
exit 0
