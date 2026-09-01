#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# This test deliberately confines traffic shaping and test traffic to two
# randomly named network namespaces. It does not install software or contact
# the Internet. When the runner cannot create a network namespace, the test is
# reported as skipped instead of failed.

set -euo pipefail
IFS=$'\n\t'
export LC_ALL=C

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly TEST_DIR
REPO_DIR="$(cd -- "${TEST_DIR}/.." && pwd -P)"
readonly REPO_DIR
readonly TUNER="${REPO_DIR}/vps-proxy-tune.sh"

tmp_dir=""
client_ns=""
server_ns=""
client_dev=""
server_dev=""
iperf_pid=""
iperf_pid_v6=""
client_ns_created=0
server_ns_created=0
veth_created=0

skip() {
    if [[ "${VPS_TUNE_REQUIRE_NETNS:-0}" == 1 ]]; then
        printf 'FAIL: required network namespace test cannot run: %s\n' "$*" >&2
        exit 1
    fi
    printf 'SKIP: %s\n' "$*"
    exit 0
}

cleanup() {
    local exit_status="${1:-1}"

    trap - EXIT INT TERM HUP
    if [[ -n "${iperf_pid}" ]]; then
        kill "${iperf_pid}" 2>/dev/null || true
        wait "${iperf_pid}" 2>/dev/null || true
    fi
    if [[ -n "${iperf_pid_v6}" ]]; then
        kill "${iperf_pid_v6}" 2>/dev/null || true
        wait "${iperf_pid_v6}" 2>/dev/null || true
    fi
    if ((client_ns_created == 1)) && [[ -n "${client_ns}" ]]; then
        ip netns delete "${client_ns}" 2>/dev/null || true
    fi
    if ((server_ns_created == 1)) && [[ -n "${server_ns}" ]]; then
        ip netns delete "${server_ns}" 2>/dev/null || true
    fi
    if ((veth_created == 1)); then
        ip link delete "${client_dev}" 2>/dev/null ||
            ip link delete "${server_dev}" 2>/dev/null || true
    fi
    if [[ -n "${tmp_dir}" && -d "${tmp_dir}" ]]; then
        case "$(basename -- "${tmp_dir}")" in
            vps-proxy-tune-netns.????????) rm -rf -- "${tmp_dir}" ;;
            *) printf 'WARN: refusing to remove unexpected temp path: %s\n' "${tmp_dir}" >&2 ;;
        esac
    fi
    exit "${exit_status}"
}
trap 'cleanup $?' EXIT
trap 'exit 130' INT TERM HUP

for command_name in \
    bash basename chmod cmp diff env find ip iperf3 jq mkdir mktemp od ping rm \
    sed sha256sum sleep sort sysctl tc tr; do
    command -v "${command_name}" >/dev/null 2>&1 || skip "missing test dependency: ${command_name}"
done
[[ -r "${TUNER}" ]] || {
    printf 'FAIL: main script not found: %s\n' "${TUNER}" >&2
    exit 1
}

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/vps-proxy-tune-netns.XXXXXXXX")"
chmod 0700 "${tmp_dir}"

# Linux interface names are limited to 15 bytes. Eight random hexadecimal
# characters keep every generated netns/veth name short and collision-safe.
random_hex="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
[[ "${random_hex}" =~ ^[0-9a-f]{8}$ ]] || {
    printf 'FAIL: unable to generate a safe namespace prefix\n' >&2
    exit 1
}
readonly random_hex
client_ns="vpt${random_hex}c"
server_ns="vpt${random_hex}s"
client_dev="vc${random_hex}"
server_dev="vs${random_hex}"

# The create attempt is also the capability probe. In particular, root inside
# an unprivileged container commonly lacks CAP_NET_ADMIN/CAP_SYS_ADMIN.
if ! ip netns add "${client_ns}" 2>"${tmp_dir}/netns-probe.err"; then
    skip "CAP_NET_ADMIN/network namespace support is unavailable"
fi
client_ns_created=1
if ! ip netns add "${server_ns}" 2>"${tmp_dir}/netns-server.err"; then
    skip "CAP_NET_ADMIN/network namespace support is unavailable"
fi
server_ns_created=1

if ! ip link add "${client_dev}" type veth peer name "${server_dev}" \
    2>"${tmp_dir}/veth-probe.err"; then
    skip "CAP_NET_ADMIN/veth support is unavailable"
fi
veth_created=1
ip link set "${client_dev}" netns "${client_ns}"
ip link set "${server_dev}" netns "${server_ns}"

readonly client_ip='198.18.77.1'
readonly server_ip='198.18.77.2'
readonly client_ip6='2001:db8:77::1'
readonly server_ip6='2001:db8:77::2'
ip -n "${client_ns}" link set lo up
ip -n "${server_ns}" link set lo up
ip -n "${client_ns}" address add "${client_ip}/30" dev "${client_dev}"
ip -n "${server_ns}" address add "${server_ip}/30" dev "${server_dev}"
ip -n "${client_ns}" -6 address add "${client_ip6}/64" dev "${client_dev}"
ip -n "${server_ns}" -6 address add "${server_ip6}/64" dev "${server_dev}"
ip -n "${client_ns}" link set "${client_dev}" up
ip -n "${server_ns}" link set "${server_dev}" up

# Exercise the allowlisted qdisc snapshot/replay path on a real Linux network
# namespace before adding the deliberately non-fresh netem topology. This is
# intentionally helper-level coverage; privileged systemd apply/recovery is
# covered only by the systemd VM job described in the CI workflow.
ip netns exec "${client_ns}" tc qdisc replace dev "${client_dev}" root pfifo_fast
ip netns exec "${client_ns}" env VPS_TUNE_LIB_ONLY=1 TUNER="${TUNER}" DEV="${client_dev}" \
    bash -c '
        set -euo pipefail
        source "${TUNER}"
        spec=$(qdisc_root_restore_spec "${DEV}")
        qdisc_spec_is_safe "${spec}"
        qdisc_replace_from_spec "${DEV}" "${spec}"
        [[ "$(qdisc_root_restore_spec "${DEV}")" == "${spec}" ]]
    '

# Applying half of the target delay on each endpoint yields an approximately
# 90 ms RTT path; a small endpoint loss exercises the quality classifier.
ip netns exec "${client_ns}" tc qdisc add dev "${client_dev}" root \
    netem delay 45ms 5ms distribution normal loss 0.2% rate 50mbit
ip netns exec "${server_ns}" tc qdisc add dev "${server_dev}" root \
    netem delay 45ms 5ms distribution normal loss 0.2% rate 50mbit

if ! ip netns exec "${client_ns}" ping -q -c 2 -W 2 "${server_ip}" >/dev/null 2>&1; then
    printf 'FAIL: isolated netem path is not reachable\n' >&2
    exit 1
fi
if ! ip netns exec "${client_ns}" ping -6 -q -c 2 -W 2 "${server_ip6}" >/dev/null 2>&1; then
    printf 'FAIL: isolated IPv6 netem path is not reachable\n' >&2
    exit 1
fi

readonly iperf_port="$((20000 + (16#${random_hex:0:4} % 20000)))"
readonly iperf_port_v6="$((iperf_port + 1))"
ip netns exec "${server_ns}" iperf3 -s -4 -B "${server_ip}" -p "${iperf_port}" \
    >"${tmp_dir}/iperf-server.log" 2>&1 &
iperf_pid=$!
ip netns exec "${server_ns}" iperf3 -s -6 -B "${server_ip6}" -p "${iperf_port_v6}" \
    >"${tmp_dir}/iperf-server-v6.log" 2>&1 &
iperf_pid_v6=$!

server_ready=0
server_ready_v6=0
for _ in 1 2 3 4 5; do
    if ip netns exec "${client_ns}" \
        iperf3 -c "${server_ip}" -p "${iperf_port}" -n 64K -J \
        >"${tmp_dir}/iperf-probe.json" 2>/dev/null; then
        server_ready=1
    fi
    if ip netns exec "${client_ns}" \
        iperf3 -6 -c "${server_ip6}" -p "${iperf_port_v6}" -n 64K -J \
        >"${tmp_dir}/iperf-probe-v6.json" 2>/dev/null; then
        server_ready_v6=1
    fi
    ((server_ready == 0 || server_ready_v6 == 0)) || break
    sleep 1
done
if ((server_ready == 0 || server_ready_v6 == 0)); then
    printf 'FAIL: isolated IPv4/IPv6 iperf3 server did not become ready\n' >&2
    exit 1
fi

snapshot_protected_state() {
    local output_file=$1
    local key path scope

    {
        for scope in host client; do
            for key in \
                net.core.default_qdisc \
                net.core.netdev_max_backlog \
                net.core.rmem_max \
                net.core.somaxconn \
                net.core.wmem_max \
                net.ipv4.tcp_congestion_control \
                net.ipv4.tcp_max_syn_backlog \
                net.ipv4.tcp_moderate_rcvbuf \
                net.ipv4.tcp_mtu_probing \
                net.ipv4.tcp_rmem \
                net.ipv4.tcp_wmem; do
                printf 'sysctl %s %s=' "${scope}" "${key}"
                if [[ "${scope}" == host ]]; then
                    sysctl -n "${key}" 2>/dev/null || printf '<unavailable>'
                else
                    ip netns exec "${client_ns}" \
                        sysctl -n "${key}" 2>/dev/null || printf '<unavailable>'
                fi
                printf '\n'
            done
        done

        printf 'client-qdisc '
        ip netns exec "${client_ns}" tc qdisc show dev "${client_dev}" |
            sed -E 's/ seed [0-9]+//g; s/[[:space:]]+$//'

        for path in \
            /etc/sysctl.conf \
            /etc/sysctl.d \
            /etc/modules-load.d/90-vps-proxy-tune.conf \
            /var/lib/vps-proxy-tune; do
            if [[ -f "${path}" ]]; then
                printf 'file '
                sha256sum -- "${path}"
            elif [[ -d "${path}" ]]; then
                while IFS= read -r -d '' child; do
                    printf 'file '
                    sha256sum -- "${child}"
                done < <(find "${path}" -xdev -type f -print0 | sort -z)
            else
                printf 'missing %s\n' "${path}"
            fi
        done
    } >"${output_file}"
}

readonly isolated_state="${tmp_dir}/state"
readonly isolated_run="${tmp_dir}/run"
mkdir -p "${isolated_state}" "${isolated_run}"
chmod 0700 "${isolated_state}" "${isolated_run}"

printf 'atomic source\n' >"${tmp_dir}/atomic-source"
env VPS_TUNE_LIB_ONLY=1 TUNER="${TUNER}" STATE_ROOT="${isolated_state}" \
    SOURCE_FILE="${tmp_dir}/atomic-source" TARGET_FILE="${isolated_state}/atomic-target" \
    bash -c '
        set -euo pipefail
        source "${TUNER}"
        STATE_DIR="${STATE_ROOT}"
        atomic_install "${SOURCE_FILE}" "${TARGET_FILE}" 0600
        cmp -s "${SOURCE_FILE}" "${TARGET_FILE}"
    '

snapshot_protected_state "${tmp_dir}/before.snapshot"

readonly -a tuner_env=(
    "VPS_TUNE_STATE_DIR=${isolated_state}"
    "VPS_TUNE_RUN_ROOT=${isolated_run}"
)

# audit is executed in the shaped client namespace, so it sees the test route
# and qdisc but cannot accidentally rely on the runner's Internet connection.
ip netns exec "${client_ns}" env "${tuner_env[@]}" \
    bash "${TUNER}" audit --json >"${tmp_dir}/audit.json"
jq -e '.schema_version and has("run_id") and .environment' \
    "${tmp_dir}/audit.json" >/dev/null

# Generate a real run for plan using only the local, user-supplied test peer.
# A deliberately small budget keeps CI quick while still exercising all four
# TCP directions/parallelism modes plus the two UDP directions in mixed mode.
ip netns exec "${client_ns}" env "${tuner_env[@]}" \
    bash "${TUNER}" measure \
        --peer "${server_ip}:${iperf_port}" \
        --family 4 \
        --profile mixed \
        --budget-mib 32 \
        --json >"${tmp_dir}/measure.json"

run_id="$(jq -er '.run_id | select(type == "string" and length > 0)' \
    "${tmp_dir}/measure.json")"
[[ "${run_id}" =~ ^[A-Za-z0-9._-]+$ ]] || {
    printf 'FAIL: measure returned an unsafe run_id\n' >&2
    exit 1
}
# The dollar-prefixed names below are jq variables supplied with --arg.
# shellcheck disable=SC2016
jq -e --arg address "${server_ip}" --arg source "${client_ip}" '
    . as $doc |
    $doc.environment.profile == "mixed" and
    ($doc.path.peers | length) == 1 and
    $doc.path.peers[0].address == $address and
    $doc.path.peers[0].source_address == $source and
    $doc.path.peers[0].family == 4 and
    $doc.path.peers[0].route_unambiguous == true and
    ($doc.path.peers[0].route_fingerprint | test("^[0-9a-f]{64}$")) and
    $doc.metrics.rtt_p95_ms >= 50 and
    $doc.metrics.effective_mbps > 0 and
    $doc.metrics.udp_tests_total == 2 and
    $doc.metrics.udp_tests_ok == 2 and
    $doc.metrics.udp_metrics_complete == true and
    ($doc.metrics.verification_budget | type) == "object" and
    ($doc.metrics.actual_bytes * 100 <= $doc.metrics.budget_bytes * 102) and
    ($doc.metrics.wire_bytes * 100 <= $doc.metrics.budget_bytes * 102)
' "${tmp_dir}/measure.json" >/dev/null

ip netns exec "${client_ns}" env "${tuner_env[@]}" \
    bash "${TUNER}" plan --run "${run_id}" --json \
    >"${tmp_dir}/plan.json"
jq -e '.schema_version and .run_id and .recommendations' \
    "${tmp_dir}/plan.json" >/dev/null
jq -e '([.changes[]? | select(.key == "net.ipv4.tcp_mtu_probing")] | length == 0) and
    ([.changes[]?.change_type] | all(. == "runtime_change" or . == "persist_only"))' \
    "${tmp_dir}/plan.json" >/dev/null

# Repeat the full read-only measurement/plan path over IPv6. This uses the same
# private server and shaped veth, and therefore never reaches the Internet.
ip netns exec "${client_ns}" env "${tuner_env[@]}" \
    bash "${TUNER}" measure \
        --peer "[${server_ip6}]:${iperf_port_v6}" \
        --family 6 \
        --budget-mib 32 \
        --json >"${tmp_dir}/measure-v6.json"

run_id_v6="$(jq -er '.run_id | select(type == "string" and length > 0)' \
    "${tmp_dir}/measure-v6.json")"
[[ "${run_id_v6}" =~ ^[A-Za-z0-9._-]+$ ]] || {
    printf 'FAIL: IPv6 measure returned an unsafe run_id\n' >&2
    exit 1
}
# shellcheck disable=SC2016
jq -e --arg address "${server_ip6}" --arg source "${client_ip6}" '
    . as $doc |
    ($doc.path.peers | length) == 1 and
    $doc.path.peers[0].address == $address and
    $doc.path.peers[0].source_address == $source and
    $doc.path.peers[0].family == 6 and
    $doc.path.peers[0].route_unambiguous == true and
    ($doc.path.peers[0].route_fingerprint | test("^[0-9a-f]{64}$")) and
    $doc.metrics.effective_mbps > 0 and
    ($doc.metrics.verification_budget | type) == "object" and
    ($doc.metrics.wire_bytes * 100 <= $doc.metrics.budget_bytes * 102)
' "${tmp_dir}/measure-v6.json" >/dev/null

ip netns exec "${client_ns}" env "${tuner_env[@]}" \
    bash "${TUNER}" plan --run "${run_id_v6}" --json \
    >"${tmp_dir}/plan-v6.json"
jq -e '.schema_version and .run_id and .recommendations' \
    "${tmp_dir}/plan-v6.json" >/dev/null

snapshot_protected_state "${tmp_dir}/after.snapshot"
if ! cmp -s "${tmp_dir}/before.snapshot" "${tmp_dir}/after.snapshot"; then
    printf 'FAIL: audit, measure, or plan changed protected system state\n' >&2
    diff -u "${tmp_dir}/before.snapshot" "${tmp_dir}/after.snapshot" >&2 || true
    exit 1
fi

printf 'PASS: netns/netem measurement completed; audit, measure, and plan were read-only\n'
