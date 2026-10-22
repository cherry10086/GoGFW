#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Two-phase destructive coverage for a disposable Debian/Ubuntu VM with a real
# systemd PID 1.  The prepare phase deliberately reboots the guest, so the
# caller must reconnect and run the verify phase after the VM is back.

set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_root="$(cd -- "$script_dir/.." && pwd -P)"
source_program="$project_root/vps-proxy-tune.sh"
test_dir=/var/lib/vps-proxy-tune-reboot-test
state_dir=/var/lib/vps-proxy-tune
lock_file=/run/lock/vps-proxy-tune/lock
sysctl_file=/etc/sysctl.d/90-vps-proxy-tune.conf
modules_file=/etc/modules-load.d/90-vps-proxy-tune.conf
recovery_unit=/etc/systemd/system/vps-proxy-tune-recover.service
recovery_qdisc_unit=/etc/systemd/system/vps-proxy-tune-recover-qdisc.service
recovery_qdisc_online_wants=/etc/systemd/system/network-online.target.wants/vps-proxy-tune-recover-qdisc.service
recovery_qdisc_multi_wants=/etc/systemd/system/multi-user.target.wants/vps-proxy-tune-recover-qdisc.service
recovery_script="$state_dir/recovery-script.sh"
iperf_port=55202

phase="${1:-}"
program=""
server_pid=""
owned_run_id=""
state_started=0
reboot_started=0

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    return 1
}

remove_test_dir_if_safe() {
    [[ -d "$test_dir" && ! -L "$test_dir" ]] || return 0
    [[ "$(basename -- "$test_dir")" == vps-proxy-tune-reboot-test ]] || return 1
    rm -rf -- "$test_dir"
}

stop_server() {
    if [[ -n "$server_pid" ]]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
        server_pid=""
    fi
}

cleanup() {
    local exit_status=$1 current="" current_status=""
    trap - EXIT INT TERM HUP
    stop_server

    # Keep the tuner state as evidence when cleanup cannot prove ownership.
    # The test directory is removed only after the managed installation has
    # been successfully uninstalled.
    if (( state_started == 1 )) && [[ -r "$state_dir/current_run" ]]; then
        current="$(cat "$state_dir/current_run" 2>/dev/null || true)"
        current_status="$(cat "$state_dir/transactions/$current/status" 2>/dev/null || true)"
        # Keep a live current_run chain available for uninstall's LIFO
        # ownership proof.  pending-confirm is directly recoverable by
        # uninstall; only states that its chain validator cannot accept are
        # recovered before the first attempt.
        if [[ "$current" == "$owned_run_id" &&
              ( "$current_status" == prepared || "$current_status" == applying ||
                "$current_status" == guard-restoring || "$current_status" == rollback-failed ) ]]; then
            bash "$program" recover --run "$current" --json \
                >"$test_dir/cleanup-recover.json" 2>"$test_dir/cleanup-recover.err" || true
        fi
    fi
    if (( state_started == 1 )) && [[ "$reboot_started" == 0 ]]; then
        if bash "$program" uninstall --yes --json \
            >"$test_dir/cleanup-uninstall.json" 2>"$test_dir/cleanup-uninstall.err"; then
            state_started=0
        elif [[ -r "$state_dir/current_run" ]]; then
            # Complete one recoverable current run and retry once.  If the
            # retry still cannot prove ownership, retain the state directory
            # for forensic recovery instead of deleting it from the harness.
            current="$(cat "$state_dir/current_run" 2>/dev/null || true)"
            current_status="$(cat "$state_dir/transactions/$current/status" 2>/dev/null || true)"
            if [[ "$current" == "$owned_run_id" ]] &&
               [[ "$current_status" == prepared || "$current_status" == applying ||
                  "$current_status" == pending-confirm || "$current_status" == guard-restoring ||
                  "$current_status" == rollback-failed ]]; then
                bash "$program" recover --run "$current" --json \
                    >"$test_dir/cleanup-retry-recover.json" 2>"$test_dir/cleanup-retry-recover.err" || true
                if bash "$program" uninstall --yes --json \
                    >"$test_dir/cleanup-retry-uninstall.json" 2>"$test_dir/cleanup-retry-uninstall.err"; then
                    state_started=0
                fi
            fi
        fi
    fi
    if (( state_started == 0 )); then
        remove_test_dir_if_safe || true
    else
        printf 'WARN: leaving %s and managed state for forensic recovery\n' "$test_dir" >&2
    fi
    exit "$exit_status"
}
trap 'cleanup $?' EXIT
trap 'exit 130' INT TERM HUP

[[ "${VPS_TUNE_THROWAWAY_VM:-0}" == 1 ]] || {
    printf 'SKIP: set VPS_TUNE_THROWAWAY_VM=1 on a disposable VM to run this suite\n'
    exit 0
}
[[ "$phase" == prepare || "$phase" == verify ]] || {
    fail 'usage: integration_systemd_reboot.sh prepare|verify'
    exit 1
}
(( EUID == 0 )) || { fail 'this suite must run as root'; exit 1; }
[[ -d /run/systemd/system ]] || { fail 'systemd is not running'; exit 1; }
[[ "$(ps -p 1 -o comm= | tr -d ' ')" == systemd ]] ||
    { fail 'PID 1 is not systemd'; exit 1; }
[[ ! -e /.dockerenv && ! -e /run/.containerenv ]] ||
    { fail 'container detected; use a disposable VM'; exit 1; }

for command_name in \
    awk basename bash cat chmod cmp date dirname find flock getconf getent grep \
    install ip iperf3 jq kill mkdir mktemp modprobe mv od ping ps readlink rm \
    rmdir sed seq sha256sum sleep stat sysctl systemctl systemd-analyze systemd-run \
    tc timeout tr uname; do
    command -v "$command_name" >/dev/null 2>&1 ||
        { fail "missing integration dependency: $command_name"; exit 1; }
done

run_json() {
    local expected_rc=$1 label=$2 output rc
    shift 2
    output="$test_dir/$label.json"
    set +e
    bash "$program" "$@" --json >"$output" 2>"$output.err"
    rc=$?
    set -e
    if (( rc != expected_rc )); then
        printf 'FAIL: %s returned %s, expected %s\n' "$label" "$rc" "$expected_rc" >&2
        sed -n '1,120p' "$output.err" >&2 || true
        return 1
    fi
    jq -e 'type == "object" and (.schema_version | type == "string") and
        (.outcome | type == "string") and (.reason_code | type == "string")' \
        "$output" >/dev/null || {
        printf 'FAIL: %s did not produce stable JSON\n' "$label" >&2
        sed -n '1,120p' "$output" >&2 || true
        return 1
    }
}

check_recovery_graph() {
    systemd-analyze verify "$recovery_unit" "$recovery_qdisc_unit" >/dev/null
    grep -Fqx 'Wants=network-online.target' "$recovery_qdisc_unit"
    grep -Fqx 'WantedBy=multi-user.target' "$recovery_qdisc_unit"
    if grep -Fqx 'WantedBy=network-online.target' "$recovery_qdisc_unit"; then
        printf 'qdisc recovery must not be wanted by network-online.target\n' >&2
        return 1
    fi
    [[ ! -e "$recovery_qdisc_online_wants" && ! -L "$recovery_qdisc_online_wants" ]]
    [[ -L "$recovery_qdisc_multi_wants" &&
       "$(readlink -f "$recovery_qdisc_multi_wants")" == "$recovery_qdisc_unit" ]]
    systemctl is-enabled --quiet vps-proxy-tune-recover-qdisc.service
}

start_local_iperf() {
    iperf3 -s -4 -p "$iperf_port" >"$test_dir/iperf3.log" 2>&1 &
    server_pid=$!
    for _ in $(seq 1 15); do
        if timeout 3 iperf3 -c 127.0.0.1 -4 -p "$iperf_port" -n 64K -J \
            >"$test_dir/iperf3-probe.json" 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

prepare() {
    local run_id qdisc_changed qdisc_iface qdisc_before_hash
    [[ -r "$source_program" ]] || { fail "main script not found: $source_program"; return 1; }
    for path in "$test_dir" "$state_dir" "$lock_file" "$sysctl_file" "$modules_file" \
        "$recovery_unit" "$recovery_qdisc_unit" "$recovery_qdisc_online_wants" \
        "$recovery_qdisc_multi_wants" "$recovery_script"; do
        [[ ! -e "$path" && ! -L "$path" ]] ||
            { fail "pre-existing managed/test path: $path"; return 1; }
    done
    install -d -m 0700 "$test_dir"
    program="$test_dir/vps-proxy-tune"
    install -o 0 -g 0 -m 0755 "$source_program" "$program"
    state_started=1
    start_local_iperf || { fail 'local iperf3 server did not become ready'; return 1; }

    run_json 0 measure measure --peer "127.0.0.1:$iperf_port" --family 4 \
        --profile tcp --budget-mib 64
    run_id="$(jq -er '.run_id' "$test_dir/measure.json")"
    owned_run_id="$run_id"
    run_json 0 plan plan --run "$run_id"
    run_json 20 apply apply --run "$run_id" --mode safe --yes
    jq -e '.outcome == "pending_confirm" and .rollback_status == "pending-confirm"' \
        "$test_dir/apply.json" >/dev/null

    qdisc_changed="$(awk -F '\t' '$1 == "QDISC_CHANGED" {print $2; exit}' \
        "$state_dir/transactions/$run_id/meta.tsv")"
    qdisc_iface="$(awk -F '\t' '$1 == "QDISC_IFACE" {print $2; exit}' \
        "$state_dir/transactions/$run_id/meta.tsv")"
    qdisc_before_hash="$(awk -F '\t' '$1 == "QDISC_BEFORE_HASH" {print $2; exit}' \
        "$state_dir/transactions/$run_id/meta.tsv")"
    [[ "$qdisc_changed" == 0 || "$qdisc_changed" == 1 ]] || return 1
    [[ -z "$qdisc_iface" || "$qdisc_iface" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] || return 1
    [[ -z "$qdisc_before_hash" || "$qdisc_before_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
    check_recovery_graph
    printf 'run_id=%s\nqdisc_changed=%s\nqdisc_iface=%s\nqdisc_before_hash=%s\n' \
        "$run_id" "$qdisc_changed" "$qdisc_iface" "$qdisc_before_hash" > "$test_dir/reboot.tsv"
    chmod 0600 "$test_dir/reboot.tsv"
    stop_server
    sync
    reboot_started=1
    if ! systemctl reboot --no-block; then
        reboot_started=0
        return 1
    fi
    trap - EXIT INT TERM HUP
    printf 'PREPARED: VM reboot requested for run=%s; reconnect and run integration_systemd_reboot.sh verify\n' "$run_id"
}

verify() {
    local run_id qdisc_changed qdisc_iface qdisc_before_hash status actual_hash
    [[ -d "$test_dir" && ! -L "$test_dir" ]] || { fail "missing reboot test state: $test_dir"; return 1; }
    program="$test_dir/vps-proxy-tune"
    [[ -f "$program" && ! -L "$program" ]] || { fail 'reboot test copy is missing'; return 1; }
    state_started=1
    run_id="$(awk -F '=' '$1 == "run_id" {print $2; exit}' "$test_dir/reboot.tsv")"
    owned_run_id="$run_id"
    qdisc_changed="$(awk -F '=' '$1 == "qdisc_changed" {print $2; exit}' "$test_dir/reboot.tsv")"
    qdisc_iface="$(awk -F '=' '$1 == "qdisc_iface" {print $2; exit}' "$test_dir/reboot.tsv")"
    qdisc_before_hash="$(awk -F '=' '$1 == "qdisc_before_hash" {print $2; exit}' "$test_dir/reboot.tsv")"
    [[ "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$ ]] || return 1
    [[ "$qdisc_changed" == 0 || "$qdisc_changed" == 1 ]] || return 1
    [[ -z "$qdisc_iface" || "$qdisc_iface" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] || return 1
    [[ -z "$qdisc_before_hash" || "$qdisc_before_hash" =~ ^[0-9a-f]{64}$ ]] || return 1

    for _ in $(seq 1 90); do
        status="$(cat "$state_dir/transactions/$run_id/status" 2>/dev/null || true)"
        if [[ "$status" == rolled-back ]] &&
           systemctl is-active --quiet vps-proxy-tune-recover-qdisc.service; then
            break
        fi
        sleep 1
    done
    [[ "$(cat "$state_dir/transactions/$run_id/status" 2>/dev/null || true)" == rolled-back ]] ||
        { fail 'pending-confirm transaction was not rolled back during boot'; return 1; }
    [[ ! -e "$state_dir/current_run" && ! -L "$state_dir/current_run" ]] ||
        { fail 'rolled-back first transaction left current_run published'; return 1; }
    jq -e '.outcome == "rolled_back" and .rollback_status == "rolled-back"' \
        "$state_dir/transactions/$run_id/apply.json" >/dev/null
    check_recovery_graph

    if [[ "$qdisc_changed" == 1 ]]; then
        export VPS_TUNE_LIB_ONLY=1
        # shellcheck source=vps-proxy-tune.sh
        source "$program"
        unset VPS_TUNE_LIB_ONLY
        actual_hash="$(qdisc_root_fingerprint "$qdisc_iface")"
        [[ "$actual_hash" == "$qdisc_before_hash" ]] || {
            fail 'qdisc fingerprint after boot does not match the authenticated before snapshot'
            return 1
        }
    fi
    run_json 0 recover-after-reboot recover --run "$run_id"
    jq -e '.outcome == "rolled_back"' "$test_dir/recover-after-reboot.json" >/dev/null

    # A clean uninstall after a first-transaction boot rollback intentionally
    # requires a new authenticated current chain.  Exercise that path with a
    # second committed run instead of deleting state outside the tuner.
    start_local_iperf || { fail 'local iperf3 server did not become ready after reboot'; return 1; }
    run_json 0 measure-after-reboot measure --peer "127.0.0.1:$iperf_port" \
        --family 4 --profile tcp --budget-mib 64
    run_id="$(jq -er '.run_id' "$test_dir/measure-after-reboot.json")"
    owned_run_id="$run_id"
    run_json 0 plan-after-reboot plan --run "$run_id"
    run_json 20 apply-after-reboot apply --run "$run_id" --mode safe --yes
    run_json 0 confirm-after-reboot confirm --run "$run_id"
    run_json 0 verify-after-reboot verify --scope all
    run_json 0 uninstall-after-reboot uninstall --yes
    jq -e '.outcome == "ok" and .reason_code == "uninstalled"' \
        "$test_dir/uninstall-after-reboot.json" >/dev/null
    state_started=0
    # The tuner deliberately retains the state tree and terminal transaction
    # history after uninstall.  Only managed live files must be absent here.
    [[ -d "$state_dir" && ! -L "$state_dir" ]] || {
        fail 'uninstall removed the retained audit state tree'; return 1;
    }
    for path in "$sysctl_file" "$modules_file" "$recovery_unit" \
        "$recovery_qdisc_unit" "$recovery_qdisc_online_wants" "$recovery_qdisc_multi_wants" \
        "$recovery_script"; do
        [[ ! -e "$path" && ! -L "$path" ]] ||
            { fail "uninstall left managed path: $path"; return 1; }
    done
    printf 'PASS: real reboot pending-confirm rollback, network-online qdisc recovery, authenticated follow-up, and uninstall completed\n'
}

if [[ "$phase" == prepare ]]; then
    prepare
else
    verify
fi
