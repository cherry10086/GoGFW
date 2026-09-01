#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Destructive, opt-in integration coverage for a disposable Debian/Ubuntu VM
# with a real systemd PID 1. GitHub-hosted containers and Windows cannot prove
# this part of the contract.

set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_root="$(cd -- "$script_dir/.." && pwd -P)"
source_program="$project_root/vps-proxy-tune.sh"
program=""
state_dir=/var/lib/vps-proxy-tune
lock_file=/run/lock/vps-proxy-tune/lock
sysctl_file=/etc/sysctl.d/90-vps-proxy-tune.conf
modules_file=/etc/modules-load.d/90-vps-proxy-tune.conf
recovery_unit=/etc/systemd/system/vps-proxy-tune-recover.service
recovery_qdisc_unit=/etc/systemd/system/vps-proxy-tune-recover-qdisc.service
recovery_qdisc_online_wants=/etc/systemd/system/network-online.target.wants/vps-proxy-tune-recover-qdisc.service
recovery_qdisc_multi_wants=/etc/systemd/system/multi-user.target.wants/vps-proxy-tune-recover-qdisc.service
recovery_script="$state_dir/recovery-script.sh"
iperf_port=55201

work_dir=""
server_pid=""
run_one=""
run_two=""
guard_unit=""
state_started=0

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    return 1
}

cleanup() {
    local exit_status=$1 current="" current_status=""
    trap - EXIT INT TERM HUP

    # The tool remains the authority for rollback. Never recursively delete
    # /var/lib/vps-proxy-tune here; ownership failures must remain inspectable.
    if (( state_started == 1 )) && [[ -r "$state_dir/current_run" ]]; then
        current="$(cat "$state_dir/current_run" 2>/dev/null || true)"
        if [[ "$current" == "$run_one" || "$current" == "$run_two" ]]; then
            current_status="$(cat "$state_dir/transactions/$current/status" 2>/dev/null || true)"
            # uninstall needs the live current_run chain as its ownership
            # proof.  pending-confirm is a valid LIFO head and must be left
            # for uninstall; only states that uninstall cannot validate are
            # recovered before the first attempt.
            if [[ "$current_status" == prepared || "$current_status" == applying ||
                  "$current_status" == guard-restoring || "$current_status" == rollback-failed ]]; then
                bash "$program" recover --run "$current" --json \
                    >/tmp/vps-proxy-tune-systemd-vm.cleanup.json \
                    2>/tmp/vps-proxy-tune-systemd-vm.cleanup.err || true
            fi
        fi
    fi
    if (( state_started == 1 )); then
        if bash "$program" uninstall --yes --json \
            >/tmp/vps-proxy-tune-systemd-vm.uninstall.json \
            2>/tmp/vps-proxy-tune-systemd-vm.uninstall.err; then
            state_started=0
        elif [[ -r "$state_dir/current_run" ]]; then
            # If the first attempt failed after a recoverable ownership or
            # guard error, finish that exact current run and retry uninstall
            # once.  Leave the tree intact if proof is still unavailable.
            current="$(cat "$state_dir/current_run" 2>/dev/null || true)"
            current_status="$(cat "$state_dir/transactions/$current/status" 2>/dev/null || true)"
            if [[ "$current" == "$run_one" || "$current" == "$run_two" ]] &&
               [[ "$current_status" == prepared || "$current_status" == applying ||
                  "$current_status" == pending-confirm || "$current_status" == guard-restoring ||
                  "$current_status" == rollback-failed ]]; then
                bash "$program" recover --run "$current" --json \
                    >/tmp/vps-proxy-tune-systemd-vm.cleanup-retry.json \
                    2>/tmp/vps-proxy-tune-systemd-vm.cleanup-retry.err || true
                if bash "$program" uninstall --yes --json \
                    >/tmp/vps-proxy-tune-systemd-vm.uninstall-retry.json \
                    2>/tmp/vps-proxy-tune-systemd-vm.uninstall-retry.err; then
                    state_started=0
                fi
            fi
        fi
    fi
    if [[ -n "$guard_unit" ]]; then
        systemctl stop "$guard_unit.timer" "$guard_unit.service" >/dev/null 2>&1 || true
        systemctl reset-failed "$guard_unit.timer" "$guard_unit.service" >/dev/null 2>&1 || true
    fi
    if [[ -n "$server_pid" ]]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    if [[ -n "$work_dir" && -d "$work_dir" ]]; then
        case "$(basename -- "$work_dir")" in
            vps-proxy-tune-systemd-vm.????????) rm -rf -- "$work_dir" ;;
            *) printf 'WARN: refusing to remove unexpected temporary path: %s\n' "$work_dir" >&2 ;;
        esac
    fi
    exit "$exit_status"
}
trap 'cleanup $?' EXIT
trap 'exit 130' INT TERM HUP

[[ "${VPS_TUNE_THROWAWAY_VM:-0}" == 1 ]] ||
    { printf 'SKIP: set VPS_TUNE_THROWAWAY_VM=1 on a disposable VM to run this suite\n'; exit 0; }
(( EUID == 0 )) || { fail 'this suite must run as root'; exit 1; }
[[ -d /run/systemd/system ]] || { fail 'systemd is not running'; exit 1; }
[[ "$(ps -p 1 -o comm= | tr -d ' ')" == systemd ]] ||
    { fail 'PID 1 is not systemd'; exit 1; }
[[ ! -e /.dockerenv && ! -e /run/.containerenv ]] ||
    { fail 'container detected; use a disposable VM'; exit 1; }
[[ -r "$source_program" ]] || { fail "main script not found: $source_program"; exit 1; }

for command_name in \
    awk basename bash cat chmod cmp date dirname find flock getconf getent grep \
    install ip iperf3 jq kill mkdir mktemp modprobe mv od ping ps readlink rm \
    rmdir sed seq sha256sum sleep stat sysctl systemctl systemd-analyze systemd-run tc \
    timeout tr uname; do
    command -v "$command_name" >/dev/null 2>&1 ||
        { fail "missing integration dependency: $command_name"; exit 1; }
done

# Refuse to touch an existing installation. A disposable VM snapshot is the
# recovery boundary for this destructive suite.
for path in "$state_dir" "$lock_file" "$sysctl_file" "$modules_file" \
    "$recovery_unit" "$recovery_qdisc_unit" "$recovery_qdisc_online_wants" \
    "$recovery_qdisc_multi_wants" "$recovery_script"; do
    [[ ! -e "$path" && ! -L "$path" ]] ||
        { fail "pre-existing managed path: $path"; exit 1; }
done

work_dir="$(mktemp -d /tmp/vps-proxy-tune-systemd-vm.XXXXXXXX)"
chmod 0700 "$work_dir"
program="$work_dir/vps-proxy-tune"
install -o 0 -g 0 -m 0755 "$source_program" "$program" ||
    { fail 'could not install a root-owned test copy of the tuner'; exit 1; }
state_started=1

iperf3 -s -4 -p "$iperf_port" >"$work_dir/iperf3.log" 2>&1 &
server_pid=$!
for _ in $(seq 1 15); do
    if timeout 3 iperf3 -c 127.0.0.1 -4 -p "$iperf_port" -n 64K -J \
        >"$work_dir/iperf3-probe.json" 2>/dev/null; then
        break
    fi
    sleep 1
done
[[ -s "$work_dir/iperf3-probe.json" ]] ||
    { fail 'local iperf3 server did not become ready'; exit 1; }

run_json() {
    local expected_rc=$1 label=$2 output rc
    shift 2
    output="$work_dir/$label.json"
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

measure_and_plan() {
    local suffix=$1 measure_output run_id plan_label
    run_json 0 "measure-$suffix" measure \
        --peer "127.0.0.1:$iperf_port" --family 4 --profile tcp --budget-mib 64
    measure_output="$work_dir/measure-$suffix.json"
    jq -e '.outcome == "ok" and (.run_id | type == "string" and
        test("^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$")) and
        .environment.profile == "tcp" and .metrics.effective_mbps > 0' \
        "$measure_output" >/dev/null
    run_id="$(jq -er '.run_id' "$measure_output")"
    if [[ "$suffix" == one ]]; then
        run_one=$run_id
        plan_label=plan-one
    else
        run_two=$run_id
        plan_label=plan-two
    fi
    run_json 0 "$plan_label" plan --run "$run_id"
    jq -e '.outcome == "ok" and .recommendations and
        ([.changes[]?.change_type] | all(. == "runtime_change" or . == "persist_only"))' \
        "$work_dir/$plan_label.json" >/dev/null
}

measure_and_plan one
run_json 20 apply-one apply --run "$run_one" --mode safe --yes
jq -e '.outcome == "pending_confirm" and .rollback_status == "pending-confirm"' \
    "$work_dir/apply-one.json" >/dev/null
[[ -r "$state_dir/current_run" && "$(cat "$state_dir/current_run")" == "$run_one" ]] ||
    { fail 'apply did not publish current_run'; exit 1; }
[[ "$(cat "$state_dir/transactions/$run_one/status")" == pending-confirm ]] ||
    { fail 'apply did not enter pending-confirm'; exit 1; }
guard_unit="$(awk -F '\t' '$1 == "GUARD_UNIT" {print $2; exit}' \
    "$state_dir/transactions/$run_one/meta.tsv")"
[[ "$guard_unit" =~ ^vps-proxy-tune-guard-[A-Za-z0-9-]{1,120}$ ]] ||
    { fail 'apply did not persist a safe guard unit name'; exit 1; }
systemctl is-active --quiet "$guard_unit.timer" ||
    { fail 'rollback timer was not armed'; exit 1; }

# Start the exact timer service immediately to exercise the timeout/guard path
# without making CI wait for the configured 180-second timeout.
systemctl start "$guard_unit.service"
for _ in $(seq 1 30); do
    [[ "$(cat "$state_dir/transactions/$run_one/status" 2>/dev/null || true)" == rolled-back ]] &&
        break
    sleep 1
done
[[ "$(cat "$state_dir/transactions/$run_one/status" 2>/dev/null || true)" == rolled-back ]] ||
    { fail 'guard did not complete rollback'; exit 1; }
jq -e '.outcome == "rolled_back" and .rollback_status == "rolled-back"' \
    "$state_dir/transactions/$run_one/apply.json" >/dev/null
run_json 0 recover-after-guard recover --run "$run_one"
jq -e '.outcome == "rolled_back" or .outcome == "ok"' \
    "$work_dir/recover-after-guard.json" >/dev/null
systemctl stop "$guard_unit.timer" "$guard_unit.service" >/dev/null 2>&1 || true
systemctl reset-failed "$guard_unit.timer" "$guard_unit.service" >/dev/null 2>&1 || true
guard_unit=""

measure_and_plan two
run_json 20 apply-two apply --run "$run_two" --mode safe --yes
jq -e '.outcome == "pending_confirm"' "$work_dir/apply-two.json" >/dev/null
run_json 0 confirm-two confirm --run "$run_two"
jq -e '.outcome == "ok" and .reason_code == "confirmed" and
    .rollback_status == "committed"' "$work_dir/confirm-two.json" >/dev/null
[[ "$(cat "$state_dir/transactions/$run_two/status")" == committed ]] ||
    { fail 'confirm did not commit the second transaction'; exit 1; }

run_json 0 verify-all verify --scope all
jq -e '.outcome == "ok" and .reason_code == "verification_passed"' \
    "$work_dir/verify-all.json" >/dev/null
systemd-analyze verify "$recovery_unit" "$recovery_qdisc_unit" >/dev/null
grep -Fqx 'Wants=network-online.target' "$recovery_qdisc_unit" ||
    { fail 'qdisc recovery unit is missing its network-online consumer dependency'; exit 1; }
grep -Fqx 'WantedBy=multi-user.target' "$recovery_qdisc_unit" ||
    { fail 'qdisc recovery unit is not enabled by multi-user.target'; exit 1; }
if grep -Fqx 'WantedBy=network-online.target' "$recovery_qdisc_unit"; then
    fail 'qdisc recovery unit still declares network-online.target as an install target'
    exit 1
fi
[[ ! -e "$recovery_qdisc_online_wants" && ! -L "$recovery_qdisc_online_wants" ]] ||
    { fail 'legacy network-online.target.wants qdisc link remains after apply'; exit 1; }
[[ -L "$recovery_qdisc_multi_wants" &&
   "$(readlink -f "$recovery_qdisc_multi_wants")" == "$recovery_qdisc_unit" ]] ||
    { fail 'multi-user.target does not point to the qdisc recovery unit'; exit 1; }
systemctl is-enabled --quiet vps-proxy-tune-recover-qdisc.service ||
    { fail 'qdisc recovery unit is not enabled'; exit 1; }
run_json 0 history-list history list --limit 20
run_json 0 history-prune history prune --keep 1 --yes
jq -e '.outcome == "ok"' "$work_dir/history-prune.json" >/dev/null

run_json 0 uninstall uninstall --yes
jq -e '.outcome == "ok" and .reason_code == "uninstalled"' \
    "$work_dir/uninstall.json" >/dev/null
state_started=0
for path in "$sysctl_file" "$modules_file" "$recovery_unit" \
    "$recovery_qdisc_unit" "$recovery_qdisc_online_wants" \
    "$recovery_qdisc_multi_wants" "$recovery_script"; do
    [[ ! -e "$path" && ! -L "$path" ]] ||
        { fail "uninstall left managed path: $path"; exit 1; }
done

printf 'PASS: systemd VM pending-confirm, guard rollback, recover, confirm, verify, recovery graph, history prune, and uninstall completed\n'
