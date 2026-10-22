#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# vps-proxy-tune: conservative, evidence-driven Linux proxy VPS tuning.

set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077

readonly SCRIPT_NAME="vps-proxy-tune"
readonly SCRIPT_VERSION="2.1.2"
readonly SCHEMA_VERSION="2"
readonly OWNER_ID="vps-proxy-tune"
readonly MIB=1048576
readonly TAB=$'\t'
readonly MAX_BUDGET_MIB=4096
readonly RUN_TTL_SECONDS=3600
readonly CONFIRM_TIMEOUT_SECONDS=180
readonly STATE_FORMAT_VERSION="2"
SELF_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
readonly SELF_PATH

ETC_ROOT="${VPS_TUNE_ETC_ROOT:-/etc}"
PROC_ROOT="${VPS_TUNE_PROC_ROOT:-/proc}"
SYS_ROOT="${VPS_TUNE_SYS_ROOT:-/sys}"
STATE_DIR="${VPS_TUNE_STATE_DIR:-/var/lib/vps-proxy-tune}"
RUN_ROOT="${VPS_TUNE_RUN_ROOT:-/run}"
SYSCTL_FILE="${ETC_ROOT}/sysctl.d/90-vps-proxy-tune.conf"
MODULES_FILE="${ETC_ROOT}/modules-load.d/90-vps-proxy-tune.conf"
LOCK_FILE="${RUN_ROOT}/lock/vps-proxy-tune/lock"
LOCK_HELD_PATH=""
RECOVERY_UNIT_PATH="${ETC_ROOT}/systemd/system/vps-proxy-tune-recover.service"
RECOVERY_QDISC_UNIT_PATH="${ETC_ROOT}/systemd/system/vps-proxy-tune-recover-qdisc.service"
RECOVERY_UNIT_HASH_FILE="${STATE_DIR}/recovery-unit.sha256"
RECOVERY_QDISC_UNIT_HASH_FILE="${STATE_DIR}/recovery-qdisc-unit.sha256"
RECOVERY_SCRIPT_PATH="${STATE_DIR}/recovery-script.sh"
RECOVERY_SCRIPT_HASH_FILE="${STATE_DIR}/recovery-script.sha256"

JSON_OUTPUT=0
DRY_RUN=0
INSTALL_DEPS=0
PROFILE="tcp"
OUTCOME=""
REASON_CODE=""
JSON_ERROR_EMITTED=0
PACING_PLAN_ENABLED=1
PARSED_HOST=""
PARSED_PORT=""
APT_TEMP_DIR=""
APPLY_BASELINE_CREATED=0
APPLY_BASELINE_EXPECT_NEW=0
APPLY_PRESERVE_PREPARED=0
RECOVERY_UNIT_HOLD_BACKUP=0
RECOVERY_UNIT_PENDING_BACKUP=""
declare -a BASELINE_OWNERSHIP_PROOF=()
declare -a BASELINE_AUTHORIZED_TRANSACTIONS=()

log() { printf '[INFO] %s\n' "$*" >&2; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
err() { printf '[ERROR] %s\n' "$*" >&2; }
reason_code_for_message() {
    local message="$*"
    case "$message" in
        *缺少*命令*|*缺少*依赖*|*缺失命令*|*依赖安装*|*依赖*|*'需要 systemctl'*|*'需要 systemd'*|*apt-get*|*dpkg*|*找不到*systemctl*|*找不到*systemd*) printf 'dependency_missing\n' ;;
        *恢复*|*守卫*|*rollback-failed*) printf 'recovery_pending\n' ;;
        *qdisc*|*队列*|*白名单拓扑*) printf 'qdisc_unsafe\n' ;;
        *LimitNOFILE*|*服务*drop-in*|*服务不存在*) printf 'service_limit_unknown\n' ;;
        *事务快照*|*快照*|*元数据*|*所有权*|*哈希*|*漂移*|*owned*|*符号链接*|*不安全*) printf 'ownership_drift\n' ;;
        *过期*|*环境已变化*|*测量*环境*|*measurement*stale*) printf 'measurement_stale\n' ;;
        *冲突*|*sysctl*配置*|*配置层级*) printf 'plan_conflict\n' ;;
        *) printf 'operation_failed\n' ;;
    esac
}

json_operation_result() {
    local outcome="${1:-failed}" reason="${2:-operation_failed}" run_id="${3:-}" rollback="${4:-failed}"
    local run_json
    if [[ -n "$run_id" ]]; then run_json=$(json_string "$run_id"); else run_json=null; fi
    printf '{"schema_version":%s,"run_id":%s,"outcome":%s,"reason_code":%s,"environment":{},"path":{},"metrics":{},"quality":"not-measured","confidence":"not-measured","recommendations":{},"changes":[],"warnings":[],"rollback_status":%s}\n' \
        "$(json_string "$SCHEMA_VERSION")" "$run_json" "$(json_string "$outcome")" "$(json_string "$reason")" "$(json_string "$rollback")"
}

emit_json_result() {
    local outcome="${1:-failed}" reason="${2:-${REASON_CODE:-operation_failed}}" run_id="${3:-}" rollback="${4:-failed}"
    (( JSON_OUTPUT )) || return 0
    (( JSON_ERROR_EMITTED == 0 )) || return 0
    JSON_ERROR_EMITTED=1
    json_operation_result "$outcome" "$reason" "$run_id" "$rollback"
}

emit_json_error() {
    local reason="${1:-${REASON_CODE:-operation_failed}}" run_id="${2:-}" rollback="${3:-failed}"
    emit_json_result failed "$reason" "$run_id" "$rollback"
}

die() {
    local message="$*" reason="${REASON_CODE:-}"
    err "$message"
    [[ -n "$reason" ]] || reason=$(reason_code_for_message "$message")
    set_outcome failed "$reason"
    emit_json_error "$reason"
    return 1
}

command_exists() { command -v "$1" >/dev/null 2>&1; }
is_uint() { [[ "${1:-}" == 0 || "${1:-}" =~ ^[1-9][0-9]{0,17}$ ]]; }
is_positive_uint() { is_uint "${1:-}" && [[ "${1:-}" != 0 ]]; }
is_nonnegative_number() { [[ "${1:-}" =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)$ ]]; }
is_bool01() { [[ "${1:-}" == 0 || "${1:-}" == 1 ]]; }

trusted_tmp_dir() {
    local uid mode permissions
    [[ -d /tmp && ! -L /tmp ]] || return 1
    uid=$(stat -c %u /tmp 2>/dev/null || true)
    mode=$(stat -c %a /tmp 2>/dev/null || true)
    [[ "$uid" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    permissions=$((8#$mode))
    if (( (permissions & 8#022) != 0 && (permissions & 8#1000) == 0 )); then return 1; fi
}

json_escape() {
    local value="${1-}" code octal character escaped
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    value=${value//$'\b'/\\b}
    value=${value//$'\f'/\\f}
    for code in {1..8} 11 12 {14..31}; do
        printf -v octal '%03o' "$code"
        printf -v character '%b' "\\$octal"
        printf -v escaped '\\u%04x' "$code"
        value=${value//"$character"/$escaped}
    done
    printf '%s' "$value"
}

json_string() { printf '"%s"' "$(json_escape "${1-}")"; }
is_json_nonnegative_number() {
    [[ "${1:-}" =~ ^(0|[1-9][0-9]*)([.][0-9]+)?$ ]]
}
json_number_or_null() {
    if is_json_nonnegative_number "${1:-}"; then printf '%s' "$1"; else printf 'null'; fi
}

set_outcome() {
    OUTCOME="${1:-}"
    REASON_CODE="${2:-}"
}

managed_marker() {
    printf '# Managed by %s. Do not edit; use rollback/uninstall.\n' "$OWNER_ID"
}

managed_metadata() {
    local run_id="${1:-}"
    if [[ -n "$run_id" ]] && ! validate_run_id "$run_id"; then return 1; fi
    printf '# Format-Version: %s\n' "$STATE_FORMAT_VERSION"
    printf '# Writer-Version: %s\n' "$SCRIPT_VERSION"
    [[ -z "$run_id" ]] || printf '# Source run: %s\n' "$run_id"
}

trim() {
    local value="${1-}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

record_field_is_safe() {
    local value="${1-}"
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *$'\t'* ]]
}

validate_run_id() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$ ]]; }

transaction_staging_name() {
    [[ "${1:-}" =~ ^\.[A-Za-z0-9][A-Za-z0-9._-]{0,95}\.[A-Za-z0-9]{8}$ ]]
}

validate_unit() {
    local unit="${1:-}"
    [[ "$unit" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]{0,127}\.service$ ]]
}

parse_peer() {
    local input="${1:-}" host="" port="5201" colons=""
    PARSED_HOST=""
    PARSED_PORT=""
    [[ -n "$input" && ${#input} -le 320 && "$input" != -* ]] || return 1

    if [[ "$input" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    elif [[ "$input" =~ ^\[([^]]+)\]$ ]]; then
        host="${BASH_REMATCH[1]}"
    else
        colons=${input//[^:]/}
        if (( ${#colons} == 1 )); then
            host=${input%:*}
            port=${input##*:}
        else
            host=$input
        fi
    fi

    [[ -n "$host" && "$host" != -* ]] || return 1
    if ! is_uint "$port" || (( 10#$port < 1 || 10#$port > 65535 )); then return 1; fi
    if [[ "$host" == *:* ]]; then
        [[ "$host" =~ ^[0-9A-Fa-f:.%_-]+$ ]] || return 1
    else
        [[ "$host" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
        [[ "$host" != .* && "$host" != *..* && "$host" != *. ]] || return 1
    fi

    PARSED_HOST=$host
    PARSED_PORT=$((10#$port))
    printf '%s\n%s\n' "$PARSED_HOST" "$PARSED_PORT"
}

validate_peer() { parse_peer "$1" >/dev/null; }

round_pow2() {
    local value="${1:-}" result=1
    is_positive_uint "$value" || return 1
    while (( result < value )); do
        (( result <= 2305843009213693952 )) || return 1
        result=$((result * 2))
    done
    printf '%s\n' "$result"
}

ram_cap_bytes() {
    local ram_bytes="${1:-}"
    is_positive_uint "$ram_bytes" || return 1
    if (( ram_bytes < 1 * 1024 * MIB )); then printf '%s\n' $((4 * MIB))
    elif (( ram_bytes < 2 * 1024 * MIB )); then printf '%s\n' $((8 * MIB))
    elif (( ram_bytes < 4 * 1024 * MIB )); then printf '%s\n' $((16 * MIB))
    elif (( ram_bytes < 8 * 1024 * MIB )); then printf '%s\n' $((32 * MIB))
    else printf '%s\n' $((64 * MIB))
    fi
}

compute_buffer_target() {
    local mbps="${1:-}" rtt_ms="${2:-}" ram_bytes="${3:-}" current="${4:-0}"
    local desired cap
    if ! is_nonnegative_number "$mbps" || ! is_nonnegative_number "$rtt_ms" ||
       ! float_cmp "$mbps" gt 0 || ! float_cmp "$rtt_ms" gt 0 || ! is_positive_uint "$ram_bytes"; then return 1; fi
    is_uint "$current" || return 1
    float_cmp "$mbps" le 1000000 || return 1
    float_cmp "$rtt_ms" le 60000 || return 1
    desired=$(awk -v m="$mbps" -v r="$rtt_ms" 'BEGIN{v=m*r*250;i=int(v);if(v>i)i++;printf "%.0f\n",i}') || return 1
    is_positive_uint "$desired" || return 1
    (( desired < 4 * MIB )) && desired=$((4 * MIB))
    desired=$(round_pow2 "$desired") || return 1
    cap=$(ram_cap_bytes "$ram_bytes") || return 1
    (( desired > cap )) && desired=$cap
    if float_cmp "$current" gt "$desired"; then desired=$current; fi
    printf '%s\n' "$desired"
}

float_cmp() {
    local left="${1:-0}" op="${2:-le}" right="${3:-0}"
    if ! is_nonnegative_number "$left" || ! is_nonnegative_number "$right"; then return 2; fi
    awk -v a="$left" -v b="$right" -v op="$op" 'BEGIN {
        if (op == "lt") exit !(a < b); if (op == "le") exit !(a <= b);
        if (op == "gt") exit !(a > b); if (op == "ge") exit !(a >= b);
        if (op == "eq") exit !(a == b); exit 2
    }'
}

classify_quality() {
    local loss="${1:-100}" loaded_delta="${2:-9999}" retrans="${3:-100}"
    is_nonnegative_number "$loss" || return 1
    is_nonnegative_number "$loaded_delta" || return 1
    is_nonnegative_number "$retrans" || return 1
    if float_cmp "$loss" gt 2 || float_cmp "$loaded_delta" gt 80 || float_cmp "$retrans" gt 2; then
        printf 'poor\n'
    elif float_cmp "$loss" ge 0.5 || float_cmp "$loaded_delta" gt 20 || float_cmp "$retrans" ge 0.5; then
        printf 'fair\n'
    else
        printf 'good\n'
    fi
}

confidence_from_metrics() {
    local four_ok="${1:-0}" route_stable="${2:-0}" cv="${3:-999}" bg="${4:-999}" steal="${5:-999}" has_rtt="${6:-0}"
    if ! is_bool01 "$four_ok" || ! is_bool01 "$route_stable" || ! is_bool01 "$has_rtt"; then return 1; fi
    if ! is_nonnegative_number "$cv" || ! is_nonnegative_number "$bg" || ! is_nonnegative_number "$steal"; then return 1; fi
    if [[ "$four_ok" == 1 && "$route_stable" == 1 && "$has_rtt" == 1 ]] &&
       float_cmp "$cv" le 15 && float_cmp "$bg" le 10 && float_cmp "$steal" lt 10; then
        printf 'high\n'
    else
        printf 'low\n'
    fi
}

budget_rate_mbps() {
    local budget_mib="${1:-}" duration="${2:-}" stream_factor="${3:-}"
    if ! is_positive_uint "$budget_mib" || ! is_positive_uint "$duration" || ! is_positive_uint "$stream_factor"; then return 1; fi
    awk -v m="$budget_mib" -v d="$duration" -v f="$stream_factor" \
        'BEGIN { r=int((m*1048576*8*0.75)/(d*f*1000000)); if (r<1) exit 1; print r }'
}

measurement_duration_seconds() {
    local peer_budget_mib="${1:-}" rtt_ms="${2:-0}"
    local duration
    is_positive_uint "$peer_budget_mib" || return 1
    is_nonnegative_number "$rtt_ms" || return 1
    # The steady phase must cover several dozen RTTs.  Keep a bounded upper
    # limit so a high-RTT path cannot consume an unbounded budget; callers must
    # lower confidence when the budget cannot sustain this duration.
    duration=$(awk -v r="$rtt_ms" 'BEGIN{v=int((r*30+999.999)/1000);if(v<5)v=5;if(v>30)v=30;print v}') || return 1
    is_positive_uint "$duration" || return 1
    printf '%s\n' "$duration"
}

# Return a single, shared post-apply verification profile so measure-time
# eligibility and the later live verification cannot disagree. Fields are:
# reserved_bytes, reserved_mib, duration_seconds, capacity_mbps, target_mbps.
verification_budget_profile() {
    local budget_bytes="${1:-}" measurement_wire="${2:-}" baseline_mbps="${3:-}" rtt_ms="${4:-0}" test_count="${5:-2}"
    local remaining verify_bytes verify_mib duration=5 capacity target
    is_positive_uint "$budget_bytes" || return 1
    is_uint "$measurement_wire" || return 1
    is_nonnegative_number "$baseline_mbps" || return 1
    is_nonnegative_number "$rtt_ms" || return 1
    is_positive_uint "$test_count" || return 1
    (( measurement_wire <= budget_bytes )) || return 1
    remaining=$((budget_bytes - measurement_wire))
    verify_bytes=$((budget_bytes * 45 / 100))
    (( verify_bytes > remaining )) && verify_bytes=$remaining
    verify_mib=$((verify_bytes / MIB))
    is_positive_uint "$verify_mib" || return 1
    duration=$(measurement_duration_seconds "$verify_mib" "$rtt_ms" 2>/dev/null) || return 1
    target=$(awk -v value="$baseline_mbps" \
        'BEGIN{v=int(value*1.05+0.999999);if(v<1)v=1;print v}') || return 1
    is_positive_uint "$target" || return 1
    capacity=$(budget_rate_mbps "$verify_mib" "$duration" "$test_count" 2>/dev/null || printf '0')
    is_positive_uint "$capacity" || return 1
    (( capacity >= target )) || return 1
    printf '%s\t%s\t%s\t%s\t%s\n' "$verify_bytes" "$verify_mib" "$duration" "$capacity" "$target"
}

percentile() {
    local percentile_value="${1:-95}"
    awk -v p="$percentile_value" '
        /^[0-9]+([.][0-9]+)?$/ { a[++n]=$1 }
        END {
            if (!n) exit 1
            for (i=1;i<=n;i++) for (j=i+1;j<=n;j++) if (a[i]>a[j]) { t=a[i];a[i]=a[j];a[j]=t }
            idx=int((p*n+99)/100); if (idx<1) idx=1; if (idx>n) idx=n
            printf "%.3f\n", a[idx]
        }'
}

coefficient_variation() {
    awk '
        /^[0-9]+([.][0-9]+)?$/ { a[++n]=$1; sum+=$1 }
        END {
            if (!n || sum==0) { print "999"; exit }
            mean=sum/n; for(i=1;i<=n;i++) sq+=(a[i]-mean)^2
            printf "%.3f\n", (sqrt(sq/n)/mean)*100
        }'
}

require_root() { (( EUID == 0 )) || die '此操作需要 root；请使用 sudo。'; }

supported_os() {
    local id="" version=""
    [[ -r "${ETC_ROOT}/os-release" ]] || return 1
    id=$(awk -F= '$1=="ID"{gsub(/"/,"",$2);print $2}' "${ETC_ROOT}/os-release")
    version=$(awk -F= '$1=="VERSION_ID"{gsub(/"/,"",$2);print $2}' "${ETC_ROOT}/os-release")
    case "$id:$version" in
        debian:12|debian:13|ubuntu:22.04|ubuntu:24.04|ubuntu:26.04) return 0 ;;
        *) return 1 ;;
    esac
}

supported_arch() {
    case "$(uname -m 2>/dev/null || true)" in
        x86_64|aarch64) return 0 ;;
        *) return 1 ;;
    esac
}

os_pretty_name() {
    if [[ -r "${ETC_ROOT}/os-release" ]]; then
        awk -F= '$1=="PRETTY_NAME"{sub(/^"/,"",$2);sub(/"$/,"",$2);print $2}' "${ETC_ROOT}/os-release"
    else
        printf 'unknown\n'
    fi
}

os_release_value() {
    local wanted="$1"
    [[ "$wanted" =~ ^[A-Z0-9_]+$ && -r "${ETC_ROOT}/os-release" ]] || return 1
    awk -F= -v wanted="$wanted" '$1==wanted{gsub(/"/,"",$2);print $2;found=1;exit} END{if(!found)exit 1}' "${ETC_ROOT}/os-release"
}

boot_id() {
    local value
    value=$(cat "${PROC_ROOT}/sys/kernel/random/boot_id" 2>/dev/null || true)
    [[ "$value" =~ ^[0-9A-Fa-f-]{36}$ ]] || return 1
    printf '%s\n' "$value"
}

netns_inode() {
    local path="${PROC_ROOT}/self/ns/net" value
    [[ -e "$path" && ! -L "$path" ]] || path="${PROC_ROOT}/1/ns/net"
    value=$(stat -Lc %i "$path" 2>/dev/null || true)
    is_positive_uint "$value" || return 1
    printf '%s\n' "$value"
}

run_measurement_context_is_current() {
    local run_dir="$1" metrics stored current age
    metrics="$run_dir/metrics.tsv"
    [[ -r "$metrics" ]] || return 1
    stored=$(metric_get "$metrics" BOOT_ID 2>/dev/null || true)
    current=$(boot_id 2>/dev/null || true)
    [[ -n "$stored" && "$stored" == "$current" ]] || return 1
    stored=$(metric_get "$metrics" NETNS_INODE 2>/dev/null || true)
    current=$(netns_inode 2>/dev/null || true)
    [[ -n "$stored" && "$stored" == "$current" ]] || return 1
    stored=$(metric_get "$metrics" KERNEL 2>/dev/null || true)
    [[ "$stored" == "$(uname -r 2>/dev/null || true)" ]] || return 1
    stored=$(metric_get "$metrics" OS_ID 2>/dev/null || true)
    [[ "$stored" == "$(os_release_value ID 2>/dev/null || true)" ]] || return 1
    stored=$(metric_get "$metrics" OS_VERSION 2>/dev/null || true)
    [[ "$stored" == "$(os_release_value VERSION_ID 2>/dev/null || true)" ]] || return 1
    stored=$(metric_get "$metrics" MONOTONIC_SECONDS 2>/dev/null || true)
    current=$(monotonic_seconds 2>/dev/null || true)
    is_nonnegative_number "$stored" || return 1
    is_nonnegative_number "$current" || return 1
    age=$(awk -v n="$current" -v o="$stored" 'BEGIN{print n-o}')
    float_cmp "$age" ge 0 || return 1
    float_cmp "$age" le "$RUN_TTL_SECONDS"
}

memory_total_bytes() {
    [[ -r "${PROC_ROOT}/meminfo" ]] || { printf '0\n'; return; }
    awk '/^MemTotal:/ { printf "%.0f\n",$2*1024; found=1; exit } END{if(!found)print 0}' "${PROC_ROOT}/meminfo"
}

memory_available_bytes() {
    [[ -r "${PROC_ROOT}/meminfo" ]] || { printf '0\n'; return; }
    awk '/^MemAvailable:/ { printf "%.0f\n",$2*1024; found=1; exit } END{if(!found)print 0}' "${PROC_ROOT}/meminfo"
}

sysctl_key_path() { printf '%s/sys/%s\n' "$PROC_ROOT" "${1//./\/}"; }

sysctl_read() {
    local key="$1" path
    path=$(sysctl_key_path "$key")
    [[ -r "$path" ]] || return 1
    tr '\t' ' ' < "$path" | awk '{$1=$1;print}'
}

target_sysctl_keys() {
    printf '%s\n' \
        net.core.default_qdisc \
        net.ipv4.tcp_congestion_control \
        net.core.rmem_max \
        net.core.wmem_max \
        net.ipv4.tcp_rmem \
        net.ipv4.tcp_wmem \
        net.ipv4.tcp_moderate_rcvbuf \
        net.ipv4.tcp_mtu_probing \
        net.core.somaxconn \
        net.ipv4.tcp_max_syn_backlog \
        net.core.netdev_max_backlog
}

sha256_text() {
    if command_exists sha256sum; then sha256sum | awk '{print $1}'
    elif command_exists shasum; then shasum -a 256 | awk '{print $1}'
    else return 1
    fi
}

new_run_id() {
    local suffix
    if [[ -r /dev/urandom ]]; then suffix=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
    else suffix=$$
    fi
    printf '%s-%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$suffix"
}

ensure_state_dirs() {
    local directory uid mode
    require_root || return 1
    if [[ "$STATE_DIR" != /var/lib/vps-proxy-tune && ! "$STATE_DIR" =~ ^/tmp/vps-proxy-tune-[A-Za-z0-9._-]+(/state)?$ ]]; then
        die 'VPS_TUNE_STATE_DIR 只允许默认路径，或测试专用 /tmp/vps-proxy-tune-*/state。'; return 1
    fi
    [[ "$STATE_DIR" != *'/../'* && "$STATE_DIR" != *'/./'* && "$STATE_DIR" != *'//' ]] || return 1
    secure_existing_ancestor "$(dirname -- "$STATE_DIR")" || { die '状态目录的已有祖先链不安全。'; return 1; }
    for directory in "$STATE_DIR" "$STATE_DIR/runs" "$STATE_DIR/transactions" "$STATE_DIR/baseline"; do
        if [[ -e "$directory" || -L "$directory" ]]; then
            [[ -d "$directory" && ! -L "$directory" ]] || { die "状态路径不安全: $directory"; return 1; }
            uid=$(stat -c %u "$directory" 2>/dev/null || printf unknown)
            mode=$(stat -c %a "$directory" 2>/dev/null || printf unknown)
            [[ "$uid" == 0 && "$mode" == 700 ]] || { die "状态路径必须 root:0700: $directory ($uid:$mode)"; return 1; }
        else
            install -d -m 0700 "$directory" || return 1
        fi
    done
    ensure_state_format || return 1
    ensure_state_integrity_records || return 1
}

state_format_file() { printf '%s/state-format\n' "$STATE_DIR"; }

state_hash_file() {
    local name="${1:-}"
    case "$name" in
        current_run|owned-services.tsv|state-format|uninstalled_at|state.meta)
            printf '%s/%s.sha256\n' "$STATE_DIR" "$name"
            ;;
        *) return 1 ;;
    esac
}

state_metadata_file() { printf '%s/state.meta\n' "$STATE_DIR"; }

state_hash_pair_is_valid() {
    local path="$1" record="$2"
    if [[ -e "$path" || -L "$path" ]]; then
        [[ -f "$path" && ! -L "$path" ]] || return 1
        if [[ -e "$record" || -L "$record" ]]; then
            verify_private_hash_record "$path" "$record"
        else
            # Legacy v1 state had no sidecar.  It remains readable until a
            # mutating command performs the controlled sidecar migration.
            secure_private_path "$path"
        fi
    else
        [[ ! -e "$record" && ! -L "$record" ]]
    fi
}

ensure_state_metadata() {
    local file record temp run_id=""
    file=$(state_metadata_file)
    record=$(state_hash_file state.meta) || return 1
    if [[ -e "$file" || -L "$file" ]]; then
        [[ -f "$file" && ! -L "$file" ]] || { die "状态 metadata 类型不安全: $file"; return 1; }
        secure_private_path "$file" || { die "状态 metadata 权限不安全: $file"; return 1; }
        managed_file_has_current_metadata "$file" || { die "状态 metadata 版本或所有权不受支持: $file"; return 1; }
        state_hash_pair_is_valid "$file" "$record" || { die "状态 metadata 已发生漂移: $file"; return 1; }
    else
        if [[ -r "$STATE_DIR/current_run" ]]; then
            state_hash_pair_is_valid "$STATE_DIR/current_run" "$(state_hash_file current_run)" || {
                die 'current_run 在状态 metadata 迁移前已经发生漂移。'; return 1;
            }
            run_id=$(cat "$STATE_DIR/current_run" 2>/dev/null || true)
            validate_run_id "$run_id" || run_id=""
        fi
        temp=$(mktemp "$STATE_DIR/.state-meta.XXXXXXXX") || return 1
        if ! { managed_marker; managed_metadata "$run_id"; } > "$temp" ||
           ! chmod 0600 "$temp" || ! atomic_install "$temp" "$file" 0600; then
            rm -f -- "$temp"
            return 1
        fi
        rm -f -- "$temp" || return 1
        [[ ! -e "$temp" && ! -L "$temp" ]] || return 1
    fi
    write_private_hash_record "$file" "$record"
}

ensure_state_integrity_records() {
    local name path record
    ensure_state_metadata || return 1
    for name in current_run owned-services.tsv state-format uninstalled_at; do
        path="$STATE_DIR/$name"
        record=$(state_hash_file "$name") || return 1
        if [[ -e "$path" || -L "$path" || -e "$record" || -L "$record" ]]; then
            state_hash_pair_is_valid "$path" "$record" || return 1
            if [[ -e "$path" && ! -e "$record" ]]; then
                write_private_hash_record "$path" "$record" || return 1
            fi
        fi
    done
}

ensure_state_format() {
    local file value temp
    file=$(state_format_file)
    if [[ -e "$file" || -L "$file" ]]; then
        [[ -f "$file" && ! -L "$file" ]] || { die "状态格式文件类型不安全: $file"; return 1; }
        secure_private_path "$file" || { die "状态格式文件必须由 root 私有: $file"; return 1; }
        value=$(cat "$file" 2>/dev/null || true)
        [[ "$value" == "$STATE_FORMAT_VERSION" ]] || {
            die "不支持的状态格式版本: ${value:-empty}（期望 $STATE_FORMAT_VERSION）"; return 1;
        }
        return 0
    fi
    # A state tree without this marker is the v1 layout.  Migration is
    # deliberately metadata-only: retain all runs/transactions and let the
    # existing manifest/ownership checks decide whether an old transaction is
    # safe to recover.  Never rewrite legacy data implicitly.
    temp=$(mktemp "$STATE_DIR/.state-format.XXXXXXXX") || return 1
    if printf '%s\n' "$STATE_FORMAT_VERSION" > "$temp" && chmod 0600 "$temp" && atomic_install "$temp" "$file" 0600; then
        if rm -f -- "$temp" && [[ ! -e "$temp" && ! -L "$temp" ]]; then
            return 0
        fi
        return 1
    fi
    rm -f -- "$temp"
    return 1
}

secure_directory_chain() {
    local directory="${1:-}" current uid mode permissions
    [[ -n "$directory" && "$directory" == /* && "$directory" != *'//'* && "$directory" != *'/../'* && "$directory" != *'/./'* ]] || return 1
    current="$directory"
    while :; do
        if [[ -e "$current" || -L "$current" ]]; then
            [[ -d "$current" && ! -L "$current" ]] || return 1
            uid=$(stat -c %u "$current" 2>/dev/null || true)
            mode=$(stat -c %a "$current" 2>/dev/null || true)
            [[ "$uid" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
            permissions=$((8#$mode))
            # /tmp is accepted only in its standard root-owned sticky form for test
            # roots and transient files; every other ancestor must be private to root.
            if (( (permissions & 8#022) != 0 )); then
                [[ "$current" == /tmp ]] || return 1
                (( (permissions & 8#1000) != 0 )) || return 1
            fi
        else
            return 1
        fi
        [[ "$current" == / ]] && break
        current=$(dirname -- "$current")
    done
}

secure_private_path() {
    local path="$1" uid mode permissions
    [[ -e "$path" && ! -L "$path" ]] || return 1
    uid=$(stat -c %u "$path" 2>/dev/null || true)
    mode=$(stat -c %a "$path" 2>/dev/null || true)
    [[ "$uid" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    permissions=$((8#$mode))
    (( (permissions & 8#077) == 0 ))
}

secure_existing_ancestor() {
    local path="$1" current
    [[ "$path" == /* && "$path" != *'//'* && "$path" != *'/../'* && "$path" != *'/./'* ]] || return 1
    current="$path"
    while [[ ! -e "$current" && ! -L "$current" ]]; do
        [[ "$current" != / ]] || return 1
        current=$(dirname -- "$current")
    done
    secure_directory_chain "$current"
}

secure_target_parent() {
    local path="${1:-}" parent
    [[ -n "$path" ]] || return 1
    parent=$(dirname -- "$path") || return 1
    secure_existing_ancestor "$parent"
}

acquire_lock() {
    local wait_seconds="${1:-0}" lock_dir uid gid mode permissions
    is_uint "$wait_seconds" || return 1
    # Some recovery subroutines need to take the lock before they can safely
    # inspect or compensate persistent markers, while the main recovery path
    # may take it again after claiming a transaction.  Keep one descriptor
    # authoritative and make the second acquisition explicitly re-entrant;
    # otherwise a marker cleanup could race the later transaction recovery or
    # the same process could accidentally reject its own lock.
    [[ "$LOCK_HELD_PATH" == "$LOCK_FILE" ]] && return 0
    if ! command_exists flock; then die '缺少 flock（util-linux）。'; return 1; fi
    if [[ "$RUN_ROOT" != /run && ! "$RUN_ROOT" =~ ^/tmp/vps-proxy-tune-[A-Za-z0-9._-]+/run$ ]]; then
        die 'VPS_TUNE_RUN_ROOT 只允许默认路径，或测试专用 /tmp/vps-proxy-tune-*/run。'; return 1
    fi
    lock_dir=$(dirname "$LOCK_FILE")
    secure_existing_ancestor "$lock_dir" || { die '锁目录的已有祖先链不安全。'; return 1; }
    if [[ -e "$lock_dir" || -L "$lock_dir" ]]; then
        [[ -d "$lock_dir" && ! -L "$lock_dir" ]] || { die "锁目录不安全: $lock_dir"; return 1; }
    else
        install -d -m 0700 "$lock_dir" || return 1
    fi
    uid=$(stat -c %u "$lock_dir" 2>/dev/null || printf unknown)
    gid=$(stat -c %g "$lock_dir" 2>/dev/null || printf unknown)
    mode=$(stat -c %a "$lock_dir" 2>/dev/null || printf unknown)
    [[ "$uid" == 0 && "$gid" == 0 && "$mode" == 700 ]] || { die '锁目录必须是 root:root 0700。'; return 1; }
    secure_directory_chain "$lock_dir" || { die '锁目录祖先链不安全。'; return 1; }
    if [[ -e "$LOCK_FILE" || -L "$LOCK_FILE" ]]; then
        [[ -f "$LOCK_FILE" && ! -L "$LOCK_FILE" && $(stat -c %u "$LOCK_FILE" 2>/dev/null || true) == 0 ]] || {
            die '全局锁文件类型或所有权不安全。'; return 1;
        }
    fi
    exec 9>"$LOCK_FILE"
    [[ -f "$LOCK_FILE" && ! -L "$LOCK_FILE" && $(stat -c %u "$LOCK_FILE" 2>/dev/null || true) == 0 ]] || return 1
    chmod 0600 "$LOCK_FILE" || return 1
    if (( wait_seconds > 0 )); then
        if ! flock -w "$wait_seconds" 9; then die '等待 vps-proxy-tune 全局锁超时。'; return 1; fi
    elif ! flock -n 9; then
        die '另一个 vps-proxy-tune 操作正在运行。'; return 1
    fi
    LOCK_HELD_PATH="$LOCK_FILE"
}

atomic_install() {
    local source="$1" target="$2" mode="${3:-0644}" temp parent basename_target uid target_mode target_permissions
    local target_exists=0 target_inode="" target_hash="" parent_inode="" current_inode current_hash
    [[ -f "$source" && ! -L "$source" ]] || return 1
    parent=$(dirname "$target")
    if [[ -e "$parent" || -L "$parent" ]]; then
        [[ -d "$parent" && ! -L "$parent" ]] || return 1
    else
        secure_existing_ancestor "$parent" || return 1
        install -d -m 0755 "$parent" || return 1
    fi
    secure_directory_chain "$parent" || return 1
    parent_inode=$(stat -c %i "$parent" 2>/dev/null || true)
    is_positive_uint "$parent_inode" || return 1
    if [[ -e "$target" || -L "$target" ]]; then
        [[ -f "$target" && ! -L "$target" ]] || return 1
        uid=$(stat -c %u "$target" 2>/dev/null || true)
        target_mode=$(stat -c %a "$target" 2>/dev/null || true)
        [[ "$uid" == 0 && "$target_mode" =~ ^[0-7]{3,4}$ ]] || return 1
        target_permissions=$((8#$target_mode))
        (( (target_permissions & 8#022) == 0 )) || return 1
        target_exists=1
        target_inode=$(stat -c %i "$target" 2>/dev/null || true)
        target_hash=$(sha256sum "$target" 2>/dev/null | awk '{print $1}') || return 1
        is_positive_uint "$target_inode" || return 1
        [[ "$target_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
    fi
    basename_target=$(basename "$target")
    temp=$(mktemp "$parent/.${basename_target}.tmp.XXXXXX") || return 1
    if ! install -m "$mode" "$source" "$temp"; then
        rm -f -- "$temp"
        return 1
    fi
    [[ "$(stat -c %i "$parent" 2>/dev/null || true)" == "$parent_inode" ]] || {
        rm -f -- "$temp"; return 1;
    }
    if (( target_exists )); then
        current_inode=$(stat -c %i "$target" 2>/dev/null || true)
        current_hash=$(sha256sum "$target" 2>/dev/null | awk '{print $1}' || true)
        [[ "$current_inode" == "$target_inode" && "$current_hash" == "$target_hash" ]] || {
            rm -f -- "$temp"; return 1;
        }
    else
        [[ ! -e "$target" && ! -L "$target" ]] || { rm -f -- "$temp"; return 1; }
    fi
    if ! mv -fT -- "$temp" "$target"; then
        rm -f -- "$temp"
        return 1
    fi
    secure_directory_chain "$parent" || return 1
    [[ -f "$target" && ! -L "$target" && $(stat -c %u "$target" 2>/dev/null || true) == 0 ]] || return 1
}

declare -a SYSCTL_SCAN_FILES=()

collect_sysctl_files() {
    local dir file name real
    local -a matches=() names=()
    declare -A effective=()
    SYSCTL_SCAN_FILES=()
    if [[ -e "${ETC_ROOT}/sysctl.conf" || -L "${ETC_ROOT}/sysctl.conf" ]]; then
        [[ -f "${ETC_ROOT}/sysctl.conf" && -r "${ETC_ROOT}/sysctl.conf" ]] || return 1
        SYSCTL_SCAN_FILES+=("${ETC_ROOT}/sysctl.conf")
    fi
    # systemd loads the highest-priority file for each basename, then sorts the
    # effective set lexically.  /lib and /usr/lib are both inspected because
    # supported releases may be merged-/usr or may still expose both paths.
    for dir in "${ETC_ROOT}/../lib/sysctl.d" "${ETC_ROOT}/../usr/lib/sysctl.d" \
        "${ETC_ROOT}/../usr/local/lib/sysctl.d" "${RUN_ROOT}/sysctl.d" \
        "${ETC_ROOT}/sysctl.d"; do
        if [[ ! -e "$dir" && ! -L "$dir" ]]; then continue; fi
        [[ -d "$dir" && -r "$dir" ]] || return 1
        shopt -s nullglob
        matches=("$dir"/*.conf)
        shopt -u nullglob
        for file in "${matches[@]}"; do
            name=$(basename -- "$file")
            [[ "$name" =~ ^[A-Za-z0-9_.-]+[.]conf$ ]] || return 1
            if [[ -L "$file" ]]; then
                real=$(readlink -f -- "$file" 2>/dev/null || true)
                if [[ "$real" == /dev/null ]]; then
                    effective[$name]=__MASKED__
                    continue
                fi
                # Distribution files may link to a readable configuration (for
                # example 99-sysctl.conf -> ../sysctl.conf). This scan is read-only;
                # owned state and write targets retain their stricter link rules.
                [[ -n "$real" && -f "$real" && -r "$real" ]] || return 1
            fi
            [[ -f "$file" && -r "$file" ]] || return 1
            # Later directories have higher sysctl.d priority in this ordered
            # walk, so a higher-priority path replaces a lower-priority one.
            # This also handles merged-/usr aliases without preserving a stale
            # lower-priority path.
            real=$(readlink -f -- "$file" 2>/dev/null || true)
            [[ -n "$real" && -f "$real" && -r "$real" ]] || return 1
            effective[$name]="$file"
        done
    done
    # Bash's empty associative-array expansion produces one empty line in a
    # process substitution.  Keep an actually empty effective set empty so
    # callers can safely scan minimal images with no sysctl.d files.
    if (( ${#effective[@]} == 0 )); then
        return 0
    fi
    mapfile -t names < <(printf '%s\n' "${!effective[@]}" | LC_ALL=C sort)
    for name in "${names[@]}"; do
        [[ "${effective[$name]}" == __MASKED__ ]] && continue
        SYSCTL_SCAN_FILES+=("${effective[$name]}")
    done
}

is_target_sysctl_key() {
    local wanted="$1" key
    while IFS= read -r key; do [[ "$wanted" == "$key" ]] && return 0; done < <(target_sysctl_keys)
    return 1
}

scan_sysctl_definitions() {
    local file line key value normalized scope target exclusion
    local key_pattern='^-?([A-Za-z0-9_./*?-]|\[!?[A-Za-z0-9_:-]+\])+$'
    collect_sysctl_files || return 1
    for file in "${SYSCTL_SCAN_FILES[@]}"; do
        [[ "$file" == "$SYSCTL_FILE" ]] && continue
        if [[ "$file" == "${ETC_ROOT}/sysctl.conf" || "$file" == "${ETC_ROOT}/sysctl.d/"* ]]; then scope=local
        elif [[ "$file" == "${RUN_ROOT}/sysctl.d/"* ]]; then scope=runtime
        else scope=vendor
        fi
        if ! while IFS= read -r line || [[ -n "$line" ]]; do
            line=${line%%#*}; line=$(trim "$line")
            [[ -n "$line" ]] || continue
            [[ "$line" != ';'* ]] || continue
            # sysctl.d has no shell-style semicolon comment syntax.  Treating
            # it as a comment would hide a second assignment (or arbitrary
            # malformed text) and could make the conflict check incomplete.
            [[ "$line" != *';'* ]] || return 1
            exclusion=0
            if [[ "$line" == *=* ]]; then
                key=$(trim "${line%%=*}")
                value=$(trim "${line#*=}")
            else
                key=${line%%[[:space:]]*}
                value=$(trim "${line#"$key"}")
                if [[ -z "$value" && "$key" == -* ]]; then
                    # A bare -key excludes it from glob assignments; it does
                    # not itself assign a value (systemd sysctl.d syntax).
                    exclusion=1
                else
                    [[ -n "$value" ]] || return 1
                fi
            fi
            # Validate every effective definition before filtering to the
            # managed allow-list.  Otherwise a malformed non-target line could
            # be silently ignored while the same file is used as a conflict
            # authority for a later apply.
            [[ -n "$key" && "$key" != --* && "$key" =~ $key_pattern &&
               "$value" != *'='* && "$value" != *$'\t'* && "$value" != *$'\r'* ]] || return 1
            (( exclusion == 0 )) || continue
            [[ -n "$value" ]] || return 1
            key=${key#-}; normalized=${key//\//.}; normalized=${normalized#.}
            # Conservatively report every managed key matched by a glob. This
            # keeps wildcard definitions visible to the apply conflict gate.
            while IFS= read -r target; do
                # shellcheck disable=SC2053 # Match the validated sysctl glob intentionally.
                [[ "$target" == $normalized ]] || continue
                printf '%s\t%s\t%s\t%s\n' "$scope" "$target" "$file" "$value"
            done < <(target_sysctl_keys)
        done < "$file"; then
            return 1
        fi
    done
}

default_interface() {
    command_exists ip || return 1
    ip -o route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}'
}

interface_qdisc_kind() {
    local iface="$1"
    command_exists tc || return 1
    tc qdisc show dev "$iface" 2>/dev/null | awk '$1=="qdisc" && ($3=="root" || $4=="root") {print $2; exit}'
}

interface_queue_counts() {
    local iface="$1" rx=0 tx=0 path
    for path in "${SYS_ROOT}/class/net/${iface}/queues"/rx-*; do
        [[ -d "$path" && ! -L "$path" ]] || continue
        rx=$((rx + 1))
    done
    for path in "${SYS_ROOT}/class/net/${iface}/queues"/tx-*; do
        [[ -d "$path" && ! -L "$path" ]] || continue
        tx=$((tx + 1))
    done
    printf '%s/%s\n' "$rx" "$tx"
}

softnet_totals() {
    local processed=0 dropped=0 squeeze=0 a b c rest rows=0 bad=0 value first
    [[ -r "${PROC_ROOT}/net/softnet_stat" ]] || { printf 'NA NA NA\n'; return; }
    while IFS=' ' read -r a b c rest; do
        [[ "$a" =~ ^[0-9A-Fa-f]+$ && "$b" =~ ^[0-9A-Fa-f]+$ && "$c" =~ ^[0-9A-Fa-f]+$ ]] || { bad=1; continue; }
        for value in "$a" "$b" "$c"; do
            [[ ${#value} -le 16 ]] || { bad=1; continue 2; }
            if (( ${#value} == 16 )); then
                first=${value:0:1}
                [[ "$first" =~ ^[0-7]$ ]] || { bad=1; continue 2; }
            fi
        done
        if (( 16#$a > 9223372036854775807 - processed )); then bad=1; continue; fi
        processed=$((processed + 16#$a))
        if (( 16#$b > 9223372036854775807 - dropped )); then bad=1; continue; fi
        dropped=$((dropped + 16#$b))
        if (( 16#$c > 9223372036854775807 - squeeze )); then bad=1; continue; fi
        squeeze=$((squeeze + 16#$c))
        rows=$((rows + 1))
    done < "${PROC_ROOT}/net/softnet_stat"
    (( rows > 0 && bad == 0 )) || { printf 'NA NA NA\n'; return; }
    printf '%s %s %s\n' "$processed" "$dropped" "$squeeze"
}

nstat_value() {
    local key="$1"
    if command_exists nstat; then
        nstat -az 2>/dev/null | awk -v k="$key" '$1==k && $2 ~ /^[0-9]+$/{print $2;found=1} END{if(!found)print "NA"}'
    else
        printf 'NA\n'
    fi
}

listen_queue_pressure() {
    if ! command_exists ss; then printf 'NA\n'; return; fi
    ss -H -lnt 2>/dev/null | awk '
        $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $3>0 && ($2/$3)>=0.8 { hit=1 }
        END { if (NR==0) print "NA"; else print hit+0 }'
}

is_container() {
    if command_exists systemd-detect-virt && systemd-detect-virt --quiet --container 2>/dev/null; then return 0; fi
    [[ -f /.dockerenv || -f "${RUN_ROOT}/systemd/container" ]]
}

declare -A AUDIT=()

collect_audit() {
    local iface="" qdisc="" virt="none" conflicts="" softnet="0 0 0"
    local softnet_processed softnet_dropped softnet_squeeze
    AUDIT=()
    AUDIT[time]=$(date -u +%FT%TZ)
    AUDIT[hostname]=$(hostname 2>/dev/null || printf unknown)
    AUDIT[os]=$(os_pretty_name)
    AUDIT[os_supported]=0; supported_os && AUDIT[os_supported]=1
    AUDIT[kernel]=$(uname -r 2>/dev/null || printf unknown)
    AUDIT[arch]=$(uname -m 2>/dev/null || printf unknown)
    AUDIT[arch_supported]=0; supported_arch && AUDIT[arch_supported]=1
    AUDIT[cpu_count]=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 1)
    AUDIT[ram_bytes]=$(memory_total_bytes)
    AUDIT[mem_available_bytes]=$(memory_available_bytes)
    if command_exists systemd-detect-virt; then
        virt=$(systemd-detect-virt 2>/dev/null) || virt=none
    fi
    AUDIT[virtualization]=$virt
    AUDIT[container]=0; is_container && AUDIT[container]=1
    iface=$(default_interface 2>/dev/null || true)
    AUDIT[default_interface]=${iface:-unknown}
    AUDIT[default_route]=$(ip -o route show default 2>/dev/null | awk 'NR==1{$1=$1;print;exit}' || true)
    AUDIT[default_route_v4]=$(ip -4 -o route show default 2>/dev/null | awk 'NR==1{$1=$1;print;exit}' || true)
    AUDIT[default_route_v6]=$(ip -6 -o route show default 2>/dev/null | awk 'NR==1{$1=$1;print;exit}' || true)
    [[ -n "${AUDIT[default_route_v4]}" ]] || AUDIT[default_route_v4]=unavailable
    [[ -n "${AUDIT[default_route_v6]}" ]] || AUDIT[default_route_v6]=unavailable
    if [[ -n "$iface" ]]; then
        qdisc=$(interface_qdisc_kind "$iface" 2>/dev/null || true)
        AUDIT[qdisc]=${qdisc:-unknown}
        AUDIT[queues]=$(interface_queue_counts "$iface")
        AUDIT[mtu]=$(cat "${SYS_ROOT}/class/net/${iface}/mtu" 2>/dev/null || printf unknown)
        AUDIT[qdisc_details]=$(tc qdisc show dev "$iface" 2>/dev/null || printf unavailable)
    else
        AUDIT[qdisc]=unknown; AUDIT[queues]=0/0; AUDIT[mtu]=unknown; AUDIT[qdisc_details]=unavailable
    fi
    AUDIT[tcp_cc]=$(sysctl_read net.ipv4.tcp_congestion_control 2>/dev/null || printf unavailable)
    AUDIT[tcp_cc_available]=$(sysctl_read net.ipv4.tcp_available_congestion_control 2>/dev/null || printf unavailable)
    AUDIT[default_qdisc]=$(sysctl_read net.core.default_qdisc 2>/dev/null || printf unavailable)
    AUDIT[rmem_max]=$(sysctl_read net.core.rmem_max 2>/dev/null || printf unavailable)
    AUDIT[wmem_max]=$(sysctl_read net.core.wmem_max 2>/dev/null || printf unavailable)
    AUDIT[tcp_rmem]=$(sysctl_read net.ipv4.tcp_rmem 2>/dev/null || printf unavailable)
    AUDIT[tcp_wmem]=$(sysctl_read net.ipv4.tcp_wmem 2>/dev/null || printf unavailable)
    AUDIT[tcp_moderate_rcvbuf]=$(sysctl_read net.ipv4.tcp_moderate_rcvbuf 2>/dev/null || printf unavailable)
    AUDIT[tcp_mtu_probing]=$(sysctl_read net.ipv4.tcp_mtu_probing 2>/dev/null || printf unavailable)
    AUDIT[somaxconn]=$(sysctl_read net.core.somaxconn 2>/dev/null || printf unavailable)
    AUDIT[syn_backlog]=$(sysctl_read net.ipv4.tcp_max_syn_backlog 2>/dev/null || printf unavailable)
    AUDIT[netdev_backlog]=$(sysctl_read net.core.netdev_max_backlog 2>/dev/null || printf unavailable)
    softnet=$(softnet_totals)
    IFS=' ' read -r softnet_processed softnet_dropped softnet_squeeze <<< "$softnet"
    AUDIT[softnet_processed]=$softnet_processed
    AUDIT[softnet_dropped]=$softnet_dropped
    AUDIT[softnet_squeeze]=$softnet_squeeze
    AUDIT[listen_overflows]=$(nstat_value TcpExtListenOverflows)
    AUDIT[listen_drops]=$(nstat_value TcpExtListenDrops)
    AUDIT[tcp_retrans]=$(nstat_value TcpRetransSegs)
    AUDIT[listen_pressure]=$(listen_queue_pressure)
    AUDIT[conntrack_count]=$(sysctl_read net.netfilter.nf_conntrack_count 2>/dev/null || printf unavailable)
    AUDIT[conntrack_max]=$(sysctl_read net.netfilter.nf_conntrack_max 2>/dev/null || printf unavailable)
    AUDIT[conntrack_utilization_pct]=unavailable
    if is_uint "${AUDIT[conntrack_count]}" && is_uint "${AUDIT[conntrack_max]}" && (( AUDIT[conntrack_max] > 0 )); then
        AUDIT[conntrack_utilization_pct]=$(awk -v c="${AUDIT[conntrack_count]}" -v m="${AUDIT[conntrack_max]}" 'BEGIN{printf "%.3f",(c/m)*100}')
    fi
    if conflicts=$(scan_sysctl_definitions 2>/dev/null); then
        AUDIT[sysctl_definitions]="$conflicts"
    else
        AUDIT[sysctl_definitions]='[scan-failed: one or more sysctl files were unreadable]'
    fi
}

print_audit_human() {
    local ram_bytes="${AUDIT[ram_bytes]}" available_bytes="${AUDIT[mem_available_bytes]}"
    is_uint "$ram_bytes" || ram_bytes=0
    is_uint "$available_bytes" || available_bytes=0
    printf '%s v%s — 只读审计\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
    printf '系统: %s | kernel=%s | arch=%s | virt=%s | container=%s\n' \
        "${AUDIT[os]}" "${AUDIT[kernel]}" "${AUDIT[arch]}" "${AUDIT[virtualization]}" "${AUDIT[container]}"
    printf '资源: cpu=%s | ram=%s MiB | available=%s MiB\n' \
        "${AUDIT[cpu_count]}" "$((ram_bytes / MIB))" "$((available_bytes / MIB))"
    printf '出口: iface=%s | mtu=%s | queues=%s | active_qdisc=%s | default_qdisc=%s\n' \
        "${AUDIT[default_interface]}" "${AUDIT[mtu]}" "${AUDIT[queues]}" "${AUDIT[qdisc]}" "${AUDIT[default_qdisc]}"
    printf '默认路由: any=%s | v4=%s | v6=%s\n' \
        "${AUDIT[default_route]}" "${AUDIT[default_route_v4]}" "${AUDIT[default_route_v6]}"
    printf 'TCP: cc=%s | available=%s | rmem=%s | wmem=%s\n' \
        "${AUDIT[tcp_cc]}" "${AUDIT[tcp_cc_available]}" "${AUDIT[tcp_rmem]}" "${AUDIT[tcp_wmem]}"
    printf '缓冲/探测: rmem_max=%s | wmem_max=%s | moderate_rcvbuf=%s | mtu_probing=%s\n' \
        "${AUDIT[rmem_max]}" "${AUDIT[wmem_max]}" "${AUDIT[tcp_moderate_rcvbuf]}" "${AUDIT[tcp_mtu_probing]}"
    printf '队列证据: listen_overflow=%s | listen_drop=%s | softnet_drop=%s | time_squeeze=%s\n' \
        "${AUDIT[listen_overflows]}" "${AUDIT[listen_drops]}" "${AUDIT[softnet_dropped]}" "${AUDIT[softnet_squeeze]}"
    printf 'conntrack（仅审计，不调优）: count=%s | max=%s | utilization=%s%%\n' \
        "${AUDIT[conntrack_count]}" "${AUDIT[conntrack_max]}" "${AUDIT[conntrack_utilization_pct]}"
    if [[ -n "${AUDIT[sysctl_definitions]}" ]]; then
        printf '现有目标参数定义（应用前将严格检查本地冲突）:\n%s\n' "${AUDIT[sysctl_definitions]}"
    fi
    [[ "${AUDIT[os_supported]}" == 1 ]] || warn '当前发行版不在已验证矩阵内；apply 将拒绝执行。'
    [[ "${AUDIT[arch_supported]}" == 1 ]] || warn '当前架构不在 amd64/arm64 验证矩阵内；apply 将拒绝执行。'
    [[ "${AUDIT[container]}" == 0 ]] || warn '检测到共享内核容器；apply 将拒绝修改宿主级网络参数。'
}

print_audit_json() {
    local first=1
    printf '{'
    printf '"schema_version":%s,' "$(json_string "$SCHEMA_VERSION")"
    printf '"run_id":null,'
    printf '"outcome":"ok","reason_code":"audit",'
    printf '"environment":{'
    printf '"time":%s,' "$(json_string "${AUDIT[time]}")"
    printf '"hostname":%s,' "$(json_string "${AUDIT[hostname]}")"
    printf '"os":%s,' "$(json_string "${AUDIT[os]}")"
    printf '"kernel":%s,' "$(json_string "${AUDIT[kernel]}")"
    printf '"arch":%s,' "$(json_string "${AUDIT[arch]}")"
    printf '"os_supported":%s,' "${AUDIT[os_supported]}"
    printf '"arch_supported":%s,' "${AUDIT[arch_supported]}"
    printf '"virtualization":%s,' "$(json_string "${AUDIT[virtualization]}")"
    printf '"container":%s,' "${AUDIT[container]}"
    printf '"cpu_count":%s,"ram_bytes":%s,"mem_available_bytes":%s' \
        "$(json_number_or_null "${AUDIT[cpu_count]}")" "$(json_number_or_null "${AUDIT[ram_bytes]}")" "$(json_number_or_null "${AUDIT[mem_available_bytes]}")"
    printf '},'
    printf '"path":{"interface":%s,"default_route":%s,"default_route_v4":%s,"default_route_v6":%s,"mtu":%s,"queues":%s,"qdisc":%s,"qdisc_details":%s,"default_qdisc":%s},' \
        "$(json_string "${AUDIT[default_interface]}")" "$(json_string "${AUDIT[default_route]}")" \
        "$(json_string "${AUDIT[default_route_v4]}")" "$(json_string "${AUDIT[default_route_v6]}")" \
        "$(json_string "${AUDIT[mtu]}")" \
        "$(json_string "${AUDIT[queues]}")" "$(json_string "${AUDIT[qdisc]}")" \
        "$(json_string "${AUDIT[qdisc_details]}")" "$(json_string "${AUDIT[default_qdisc]}")"
    printf '"metrics":{'
    printf '"tcp_cc":%s,"available_cc":%s,"rmem_max":%s,"wmem_max":%s,"tcp_rmem":%s,"tcp_wmem":%s,' \
        "$(json_string "${AUDIT[tcp_cc]}")" "$(json_string "${AUDIT[tcp_cc_available]}")" \
        "$(json_number_or_null "${AUDIT[rmem_max]}")" "$(json_number_or_null "${AUDIT[wmem_max]}")" \
        "$(json_string "${AUDIT[tcp_rmem]}")" "$(json_string "${AUDIT[tcp_wmem]}")"
    printf '"tcp_moderate_rcvbuf":%s,"tcp_mtu_probing":%s,"somaxconn":%s,"tcp_max_syn_backlog":%s,"netdev_max_backlog":%s,' \
        "$(json_number_or_null "${AUDIT[tcp_moderate_rcvbuf]}")" "$(json_number_or_null "${AUDIT[tcp_mtu_probing]}")" \
        "$(json_number_or_null "${AUDIT[somaxconn]}")" "$(json_number_or_null "${AUDIT[syn_backlog]}")" "$(json_number_or_null "${AUDIT[netdev_backlog]}")"
    printf '"softnet_processed":%s,"softnet_dropped":%s,"softnet_time_squeeze":%s,"listen_overflows":%s,"listen_drops":%s,"listen_pressure":%s,"tcp_retrans_segments":%s,"conntrack_count":%s,"conntrack_max":%s,"conntrack_utilization_pct":%s},' \
        "$(json_number_or_null "${AUDIT[softnet_processed]}")" "$(json_number_or_null "${AUDIT[softnet_dropped]}")" \
        "$(json_number_or_null "${AUDIT[softnet_squeeze]}")" "$(json_number_or_null "${AUDIT[listen_overflows]}")" \
        "$(json_number_or_null "${AUDIT[listen_drops]}")" "$(json_number_or_null "${AUDIT[listen_pressure]}")" \
        "$(json_number_or_null "${AUDIT[tcp_retrans]}")" "$(json_number_or_null "${AUDIT[conntrack_count]}")" "$(json_number_or_null "${AUDIT[conntrack_max]}")" "$(json_number_or_null "${AUDIT[conntrack_utilization_pct]}")"
    printf '"sysctl_definitions":%s,' "$(json_string "${AUDIT[sysctl_definitions]}")"
    printf '"confidence":"not-measured","quality":"not-measured","recommendations":{},"changes":[],"warnings":['
    if [[ "${AUDIT[os_supported]}" != 1 ]]; then
        (( first == 1 )) || printf ','; json_string 'unsupported operating system'; first=0
    fi
    if [[ "${AUDIT[arch_supported]}" != 1 ]]; then
        (( first == 1 )) || printf ','; json_string 'unsupported architecture'; first=0
    fi
    if [[ "${AUDIT[container]}" == 1 ]]; then
        (( first == 1 )) || printf ','; json_string 'shared-kernel container; apply is disabled'
    fi
    printf '],"rollback_status":"not-applicable"'
    printf '}\n'
}

cmd_audit() {
    local arg
    JSON_OUTPUT=0; DRY_RUN=0; INSTALL_DEPS=0; JSON_ERROR_EMITTED=0
    for arg in "$@"; do
        case "$arg" in --json) JSON_OUTPUT=1 ;; --dry-run) DRY_RUN=1 ;; --install-deps) INSTALL_DEPS=1 ;; *) die "audit 不支持参数: $arg"; return 1 ;; esac
    done
    (( DRY_RUN == 0 || INSTALL_DEPS == 0 )) || { die '--dry-run 与 --install-deps 不能同时使用。'; return 1; }
    if (( INSTALL_DEPS )); then require_file_commands || return 1; fi
    collect_audit
    if (( JSON_OUTPUT )); then print_audit_json; else print_audit_human; fi
}

apt_temp_cleanup() {
    local path="${1:-}"
    [[ -z "$path" ]] && return 0
    [[ "$path" =~ ^/tmp/vps-proxy-tune-apt\.[A-Za-z0-9]{8}$ ]] || return 1
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        return 0
    fi
    [[ -d "$path" && ! -L "$path" ]] || return 1
    if rm -rf -- "$path"; then
        [[ ! -e "$path" && ! -L "$path" ]]
    else
        return 1
    fi
}

apt_temp_exit_cleanup() {
    local status=$? path="${APT_TEMP_DIR:-}"
    if [[ -n "$path" ]] && ! apt_temp_cleanup "$path"; then
        warn "APT 临时目录清理失败，保留证据: $path"
    fi
    APT_TEMP_DIR=""
    trap - EXIT INT TERM HUP
    return "$status"
}

apt_temp_abort() {
    local message="$1" path="${APT_TEMP_DIR:-}" cleanup_rc=0
    apt_temp_cleanup "$path" || cleanup_rc=1
    APT_TEMP_DIR=""
    trap - EXIT INT TERM HUP
    if (( cleanup_rc )); then
        die "$message；APT 临时目录清理失败，保留路径: $path"
    else
        die "$message"
    fi
    return 1
}

apt_temp_finish() {
    local path="${APT_TEMP_DIR:-}" cleanup_rc=0
    apt_temp_cleanup "$path" || cleanup_rc=1
    APT_TEMP_DIR=""
    trap - EXIT INT TERM HUP
    if (( cleanup_rc )); then
        die "APT 临时目录清理失败，保留路径: $path"
        return 1
    fi
    return 0
}

install_dependencies() {
    local id codename arch mirror temp sources keyring uid mode permissions phase command package package_status
    local -a apt_scope packages missing_commands
    local -A package_seen=()
    phase="${1:-all}"
    [[ "$phase" == all || "$phase" == common || "$phase" == audit || "$phase" == measure || "$phase" == apply || "$phase" == recovery ]] || {
        die "未知依赖阶段: $phase"; return 1;
    }
    require_root || return 1
    if ! supported_os; then die '只允许在受支持的 Debian/Ubuntu 上安装依赖。'; return 1; fi
    if ! command_exists apt-get || ! command_exists dpkg || ! command_exists dpkg-query; then die '找不到 apt-get/dpkg/dpkg-query。'; return 1; fi
    if [[ ! -r "${ETC_ROOT}/ssl/certs/ca-certificates.crt" ]]; then die '缺少 ca-certificates 信任库；为避免降级 HTTP，拒绝自动安装。请先通过可信控制台安装 ca-certificates。'; return 1; fi
    id=$(awk -F= '$1=="ID"{gsub(/"/,"",$2);print $2}' "${ETC_ROOT}/os-release")
    codename=$(awk -F= '$1=="VERSION_CODENAME"{gsub(/"/,"",$2);print $2}' "${ETC_ROOT}/os-release")
    if [[ ! "$codename" =~ ^[a-z0-9-]+$ ]]; then die '无法安全确定发行版代号。'; return 1; fi
    arch=$(dpkg --print-architecture)
    if [[ "$arch" != amd64 && "$arch" != arm64 ]]; then die "不支持的架构: $arch"; return 1; fi
    trusted_tmp_dir || {
        die '/tmp 不是可信的 root-owned 目录。'; return 1;
    }
    if ! temp=$(mktemp -d "/tmp/vps-proxy-tune-apt.XXXXXXXX"); then
        die '无法创建 APT 隔离临时目录。'; return 1
    fi
    APT_TEMP_DIR="$temp"
    trap apt_temp_exit_cleanup EXIT
    trap 'exit 130' INT TERM HUP
    chmod 0700 "$temp" || { apt_temp_abort '无法设置 APT 临时目录权限'; return 1; }
    install -d -m 0755 "$temp/lists/partial" "$temp/cache/archives/partial" || {
        apt_temp_abort '无法创建 APT 隔离目录'; return 1;
    }
    sources="$temp/official.list"
    {
        if [[ "$id" == debian ]]; then
            keyring=/usr/share/keyrings/debian-archive-keyring.gpg
            printf 'deb [signed-by=%s] https://deb.debian.org/debian %s main\n' "$keyring" "$codename"
            printf 'deb [signed-by=%s] https://deb.debian.org/debian %s-updates main\n' "$keyring" "$codename"
            printf 'deb [signed-by=%s] https://security.debian.org/debian-security %s-security main\n' "$keyring" "$codename"
        else
            keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg
            mirror=https://archive.ubuntu.com/ubuntu
            [[ "$arch" == amd64 ]] || mirror=https://ports.ubuntu.com/ubuntu-ports
            printf 'deb [signed-by=%s] %s %s main universe\n' "$keyring" "$mirror" "$codename"
            printf 'deb [signed-by=%s] %s %s-updates main universe\n' "$keyring" "$mirror" "$codename"
            printf 'deb [signed-by=%s] %s %s-security main universe\n' "$keyring" "$mirror" "$codename"
        fi
    } > "$sources" || { apt_temp_abort '无法写入 APT 官方源配置'; return 1; }
    chmod 0600 "$sources" || { apt_temp_abort '无法设置 APT 官方源配置权限'; return 1; }
    uid=$(stat -c %u "$keyring" 2>/dev/null || printf unknown)
    mode=$(stat -c %a "$keyring" 2>/dev/null || printf unknown)
    if [[ ! -f "$keyring" || -L "$keyring" || ! -r "$keyring" || "$uid" != 0 || ! "$mode" =~ ^[0-7]{3,4}$ ]]; then
        apt_temp_abort "缺少可信的发行版 archive keyring: $keyring"; return 1
    fi
    permissions=$((8#$mode))
    if (( (permissions & 8#022) != 0 )); then
        apt_temp_abort "发行版 archive keyring 可被 group/other 写入: $keyring"; return 1
    fi
    apt_scope=(
        -o "Dir::Etc::sourcelist=$sources"
        -o 'Dir::Etc::sourceparts=-'
        -o "Dir::State::lists=$temp/lists"
        -o "Dir::Cache::archives=$temp/cache/archives"
        -o 'Acquire::AllowInsecureRepositories=false'
        -o 'Acquire::AllowDowngradeToInsecureRepositories=false'
    )
    mapfile -t missing_commands < <(dependency_missing_commands "$phase") || {
        apt_temp_abort '无法枚举缺失依赖命令'; return 1;
    }
    for command in "${missing_commands[@]}"; do
        package=$(dependency_package_for_command "$command") || {
            apt_temp_abort "无法为缺失命令建立安全的发行版包映射: $command"; return 1;
        }
        # Only pass packages that are not already installed.  This keeps the
        # explicit dependency installer from turning a missing command into
        # an opportunistic package upgrade.
        package_status=$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)
        if [[ "$package_status" == 'install ok installed' ]]; then
            continue
        fi
        if [[ -z "${package_seen[$package]+x}" ]]; then
            package_seen[$package]=1
            packages+=("$package")
        fi
    done
    if (( ${#packages[@]} == 0 )); then
        apt_temp_finish || return 1
        log "依赖阶段 $phase 已满足，无需安装软件包。"
        return 0
    fi
    log '使用临时隔离配置，仅从 Debian/Ubuntu 官方 HTTPS 仓库安装依赖；先模拟，再安装缺失软件包。'
    if ! DEBIAN_FRONTEND=noninteractive apt-get "${apt_scope[@]}" update ||
       ! DEBIAN_FRONTEND=noninteractive apt-get "${apt_scope[@]}" --simulate install -y --no-install-recommends --no-upgrade "${packages[@]}" ||
       ! DEBIAN_FRONTEND=noninteractive apt-get "${apt_scope[@]}" install -y --no-install-recommends --no-upgrade "${packages[@]}"; then
        apt_temp_abort '官方仓库依赖安装失败。'; return 1
    fi
    apt_temp_finish || return 1
}

dependency_commands_for_phase() {
    local phase="${1:-all}"
    case "$phase" in
        common|audit)
            printf '%s\n' awk basename cat chmod cmp date dirname find flock grep head install mkdir mktemp mv readlink rm rmdir sed sha256sum sort stat tr jq
            ;;
        measure)
            dependency_commands_for_phase common
            printf '%s\n' ip ping iperf3 timeout getent od hostname getconf sleep
            ;;
        apply)
            dependency_commands_for_phase common
            dependency_commands_for_phase recovery
            printf '%s\n' systemd-run modprobe
            ;;
        recovery)
            dependency_commands_for_phase common
            printf '%s\n' sysctl uname systemctl tc
            ;;
        all)
            dependency_commands_for_phase apply
            dependency_commands_for_phase measure
            ;;
        *) return 1 ;;
    esac
}

dependency_package_for_command() {
    case "${1:-}" in
        bash) printf 'bash\n' ;;
        awk) printf 'mawk\n' ;;
        basename|cat|chmod|date|dirname|head|install|mkdir|mktemp|mv|od|readlink|rm|rmdir|sha256sum|sleep|sort|stat|tr|timeout) printf 'coreutils\n' ;;
        cmp) printf 'diffutils\n' ;;
        find) printf 'findutils\n' ;;
        flock) printf 'util-linux\n' ;;
        grep) printf 'grep\n' ;;
        sed) printf 'sed\n' ;;
        gawk) printf 'gawk\n' ;;
        ip|tc) printf 'iproute2\n' ;;
        ping) printf 'iputils-ping\n' ;;
        iperf3) printf 'iperf3\n' ;;
        jq) printf 'jq\n' ;;
        sysctl) printf 'procps\n' ;;
        systemctl|systemd-run) printf 'systemd\n' ;;
        modprobe) printf 'kmod\n' ;;
        getent|getconf) printf 'libc-bin\n' ;;
        hostname) printf 'hostname\n' ;;
        uname) printf 'coreutils\n' ;;
        *) return 1 ;;
    esac
}

dependency_missing_commands() {
    local phase="${1:-all}" cmd
    while IFS= read -r cmd; do
        [[ -n "$cmd" ]] || continue
        command_exists "$cmd" || printf '%s\n' "$cmd"
    done < <(dependency_commands_for_phase "$phase" | LC_ALL=C sort -u)
}

json_lines_array() {
    local input="${1:-}" line first=1
    printf '['
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        (( first == 1 )) || printf ','
        json_string "$line"
        first=0
    done <<< "$input"
    printf ']'
}

dependency_check_json() {
    local phase="$1" missing ok
    missing=$(dependency_missing_commands "$phase") || return 1
    [[ -z "$missing" ]] && ok=true || ok=false
    printf '{"schema_version":%s,"phase":%s,"ok":%s,"missing_commands":' \
        "$(json_string "$SCHEMA_VERSION")" "$(json_string "$phase")" "$ok"
    json_lines_array "$missing"
    printf ',"outcome":"%s","reason_code":"%s","rollback_status":"not-applicable"}\n' \
        "$([[ -z "$missing" ]] && printf ok || printf blocked)" \
        "$([[ -z "$missing" ]] && printf dependencies_satisfied || printf dependency_missing)"
}

cmd_deps() {
    local action=check phase=all arg assume_yes=0 dry=0 missing
    JSON_OUTPUT=0; DRY_RUN=0; INSTALL_DEPS=0; JSON_ERROR_EMITTED=0
    if (($#)) && [[ "$1" != --* ]]; then action=$1; shift; fi
    case "$action" in check|install) ;; *) die 'deps 只支持 check 或 install。'; return 1 ;; esac
    while (($#)); do
        arg=$1; shift
        case "$arg" in
            --phase) (($#)) || { die '--phase 缺少值'; return 1; }; phase=$1; shift ;;
            --phase=*) phase=${arg#*=} ;;
            --json) JSON_OUTPUT=1 ;;
            --dry-run) dry=1 ;;
            --yes) assume_yes=1 ;;
            *) die "deps 不支持参数: $arg"; return 1 ;;
        esac
    done
    [[ "$phase" == all || "$phase" == common || "$phase" == audit || "$phase" == measure || "$phase" == apply || "$phase" == recovery ]] || {
        die '--phase 只能是 all、common、audit、measure、apply 或 recovery。'; return 1;
    }
    missing=$(dependency_missing_commands "$phase") || return 1
    if [[ "$action" == check ]]; then
        if (( JSON_OUTPUT )); then
            dependency_check_json "$phase"
            JSON_ERROR_EMITTED=1
        else
            if [[ -n "$missing" ]]; then
                printf '依赖阶段 %s 缺少:\n%s\n' "$phase" "$missing"
            else
                printf '依赖阶段 %s 已满足。\n' "$phase"
            fi
        fi
        [[ -z "$missing" ]]
        return $?
    fi
    if (( dry )); then
        if (( JSON_OUTPUT )); then
            printf '{"schema_version":%s,"phase":%s,"outcome":"ok","reason_code":"dependency_install_preview","missing_commands":' \
                "$(json_string "$SCHEMA_VERSION")" "$(json_string "$phase")"
            json_lines_array "$missing"
            printf ',"rollback_status":"dry-run"}\n'
        else
            printf 'dry-run：依赖阶段 %s 将只安装以下缺失命令对应的软件包:\n%s\n' "$phase" "${missing:-（无）}"
        fi
        return 0
    fi
    [[ -n "$missing" ]] || {
        if (( JSON_OUTPUT )); then dependency_check_json "$phase"; else printf '无需安装：依赖阶段 %s 已满足。\n' "$phase"; fi
        return 0
    }
    if (( assume_yes == 0 )); then
        [[ -t 0 ]] || { die '非交互安装必须显式提供 --yes。'; return 1; }
        printf '将使用官方 HTTPS APT 源，仅安装缺失依赖（阶段 %s）。输入 "INSTALL %s" 确认: ' "$phase" "$phase" >&2
        IFS= read -r arg
        [[ "$arg" == "INSTALL $phase" ]] || { die '用户取消。'; return 1; }
    fi
    INSTALL_DEPS=1
    install_dependencies "$phase" || return 1
    missing=$(dependency_missing_commands "$phase") || return 1
    if (( JSON_OUTPUT )); then
        printf '{"schema_version":%s,"phase":%s,"outcome":%s,"reason_code":%s,"missing_commands":' \
            "$(json_string "$SCHEMA_VERSION")" "$(json_string "$phase")" \
            "$(if [[ -z "$missing" ]]; then json_string ok; else json_string blocked; fi)" \
            "$(if [[ -z "$missing" ]]; then json_string dependencies_installed; else json_string dependency_missing; fi)"
        json_lines_array "$missing"
        printf ',"rollback_status":"not-applicable"}\n'
        JSON_ERROR_EMITTED=1
    else
        if [[ -z "$missing" ]]; then
            printf '依赖阶段 %s 已满足。\n' "$phase" || return 1
        else
            printf '安装后仍缺少依赖:\n%s\n' "$missing"; return 1;
        fi
    fi
    [[ -z "$missing" ]]
}

require_file_commands() {
    local missing=() cmd
    # The measure/plan/recovery paths all write private manifests and state
    # files.  Check this small coreutils closure before any state mutation so a
    # stripped image cannot fail halfway through an otherwise valid operation.
    for cmd in awk basename cat chmod cmp date dirname find flock grep head install mkdir mktemp mv readlink rm rmdir sed sha256sum sort stat tr; do
        command_exists "$cmd" || missing+=("$cmd")
    done
    if (( ${#missing[@]} )); then
        if (( INSTALL_DEPS )); then
            install_dependencies common || return 1
            for cmd in "${missing[@]}"; do
                command_exists "$cmd" || { die "依赖安装后仍找不到命令: $cmd"; return 1; }
            done
        else
            die "缺少状态/文件命令: ${missing[*]}。使用 --install-deps 可从发行版仓库安装。"
            return 1
        fi
    fi
}

require_preview_commands() {
    local missing=() cmd
    # apply --dry-run reads an existing run and renders the proposed files. It
    # must not require network probes or iperf3, and it must not install
    # anything.  qdisc/service-specific checks still fail closed later when
    # their own command is needed.
    require_file_commands || return 1
    command_exists jq || missing+=(jq)
    if (( ${#missing[@]} )); then
        die "缺少 dry-run 预览命令: ${missing[*]}。请先安装发行版提供的 jq。"
        return 1
    fi
}

require_measure_commands() {
    local missing=() cmd
    # mtr, ss and tc are useful diagnostics but are not required to complete a
    # measurement.  modprobe is only needed when apply actually needs a
    # kernel module.  Keep the hard gate limited to commands used on every
    # measurement path so a minimal VPS can still collect usable evidence.
    require_file_commands || return 1
    for cmd in ip ping iperf3 jq timeout sed sort sha256sum getent flock od hostname getconf cat tr sleep head; do
        command_exists "$cmd" || missing+=("$cmd")
    done
    if (( ${#missing[@]} )); then
        if (( INSTALL_DEPS )); then
            install_dependencies measure || return 1
            for cmd in "${missing[@]}"; do
                command_exists "$cmd" || { die "依赖安装后仍找不到命令: $cmd"; return 1; }
            done
        else
            die "缺少测量命令: ${missing[*]}。使用 --install-deps 可从发行版仓库安装。"
            return 1
        fi
    fi
}

require_apply_commands() {
    local missing=() cmd
    # These commands are part of the apply/recovery closure.  Keep the list
    # explicit so a stripped VPS fails before any transaction is published.
    require_recovery_commands || return 1
    for cmd in systemd-run modprobe; do
        command_exists "$cmd" || missing+=("$cmd")
    done
    if (( ${#missing[@]} )); then
        if (( INSTALL_DEPS )); then
            install_dependencies apply || return 1
            for cmd in "${missing[@]}"; do
                command_exists "$cmd" || { die "依赖安装后仍找不到命令: $cmd"; return 1; }
            done
        else
            die "缺少应用/恢复命令: ${missing[*]}。请先安装发行版提供的基础工具。"
            return 1
        fi
    fi
}

require_recovery_commands() {
    local missing=() cmd
    # Rollback, confirmation and boot recovery run independently of measure.
    # Check their complete closure up front instead of discovering a missing
    # core utility after a partial restore has already started.
    require_file_commands || return 1
    for cmd in sysctl cmp rmdir cat head tr uname systemctl tc sha256sum sed jq flock; do
        command_exists "$cmd" || missing+=("$cmd")
    done
    if (( ${#missing[@]} )); then
        if (( INSTALL_DEPS )); then
            install_dependencies recovery || return 1
            missing=()
            for cmd in sysctl cmp rmdir cat head tr uname systemctl tc sha256sum sed jq flock; do
                command_exists "$cmd" || missing+=("$cmd")
            done
            if (( ${#missing[@]} )); then
                die "依赖安装后仍找不到恢复/事务命令: ${missing[*]}。"
                return 1
            fi
        else
            die "缺少恢复/事务命令: ${missing[*]}。请先安装发行版提供的基础工具。"
            return 1
        fi
    fi
}

require_verify_commands() {
    local scope="${1:-all}" missing=() cmd
    require_file_commands || return 1
    command_exists jq || missing+=(jq)
    case "$scope" in
        config) command_exists sysctl || missing+=(sysctl) ;;
        path) command_exists ip || missing+=(ip); command_exists tc || missing+=(tc) ;;
        all) command_exists sysctl || missing+=(sysctl); command_exists ip || missing+=(ip); command_exists tc || missing+=(tc) ;;
        *) return 1 ;;
    esac
    if (( ${#missing[@]} )); then
        die "缺少 verify ${scope} 范围命令: ${missing[*]}。"
        return 1
    fi
}

family_of_ip() { if [[ "$1" == *:* ]]; then printf '6\n'; else printf '4\n'; fi; }

resolve_peer_host() {
    local host="$1" requested_family="$2" ip=""
    if [[ "$host" == *:* ]]; then
        [[ "$requested_family" != 4 ]] || return 1
        printf '%s\n' "$host"; return
    elif [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        [[ "$requested_family" != 6 ]] || return 1
        printf '%s\n' "$host"; return
    fi
    command_exists getent || return 1
    if [[ "$requested_family" == 4 || "$requested_family" == auto ]]; then
        ip=$(getent ahostsv4 "$host" 2>/dev/null | awk '$2=="STREAM"{print $1;exit}')
        [[ -z "$ip" ]] || { printf '%s\n' "$ip"; return; }
    fi
    if [[ "$requested_family" == 6 || "$requested_family" == auto ]]; then
        ip=$(getent ahostsv6 "$host" 2>/dev/null | awk '$2=="STREAM"{print $1;exit}')
        [[ -z "$ip" ]] || { printf '%s\n' "$ip"; return; }
    fi
    return 1
}

normalize_route() {
    # A lookup with `from` may omit the redundant `src` field. Preserve the
    # explicitly requested source so its fingerprint matches the initial lookup.
    awk -v requested_source="${1:-}" '{
        dst=$1; via=""; dev=""; src=requested_source; table="main"
        for(i=1;i<=NF;i++) {
            if($i=="via") via=$(i+1)
            else if($i=="dev") dev=$(i+1)
            else if($i=="src") src=$(i+1)
            else if($i=="table") table=$(i+1)
        }
        printf "dst=%s via=%s dev=%s src=%s table=%s\n",dst,via,dev,src,table
    }'
}

route_details() {
    local family="$1" ip_addr="$2" source="${3:-}" output
    local -a args=(ip "-$family" route get "$ip_addr")
    [[ -z "$source" ]] || args+=(from "$source")
    output=$("${args[@]}" 2>/dev/null) || return 1
    printf '%s\n' "$output" | head -n1 | normalize_route "$source"
}

route_output_has_unique_nexthop() {
    local output="$1" nhid nhjson nonempty_lines
    nonempty_lines=$(awk 'NF{n++} END{print n+0}' <<< "$output")
    [[ "$nonempty_lines" == 1 ]] || return 1
    [[ "$output" != *nexthop* && "$output" != *weight* ]] || return 1
    nhid=$(awk '{for(i=1;i<=NF;i++)if($i=="nhid"){print $(i+1);exit}}' <<< "$output")
    [[ -n "$nhid" ]] || return 0
    is_positive_uint "$nhid" || return 1
    command_exists jq || return 1
    nhjson=$(ip -j nexthop show id "$nhid" 2>/dev/null) || return 1
    jq -e 'type=="array" and length==1 and
        ((.[0] | has("group") | not) or
         ((.[0].group | type)=="array" and (.[0].group | length)<=1))' \
        <<< "$nhjson" >/dev/null 2>&1
}

route_is_unambiguous() {
    local family="$1" ip_addr="$2" source="${3:-}" selected fibmatch
    # Cache metadata can occupy a second line in normal iproute2 output. One
    # record per line keeps that formatting distinct from multiple route records;
    # explicit nexthop/weight and nexthop-group checks remain fail-closed below.
    local -a args=(ip "-$family" -o route get "$ip_addr")
    local -a fib_args=(ip "-$family" -o route get fibmatch "$ip_addr")
    [[ -z "$source" ]] || args+=(from "$source")
    [[ -z "$source" ]] || fib_args+=(from "$source")
    selected=$("${args[@]}" 2>/dev/null) || return 1
    route_output_has_unique_nexthop "$selected" || return 1
    fibmatch=$("${fib_args[@]}" 2>/dev/null) || return 1
    [[ -n "$fibmatch" ]] || return 1
    route_output_has_unique_nexthop "$fibmatch"
}

route_field() {
    local details="$1" field="$2" word
    local -a words=()
    IFS=' ' read -r -a words <<< "$details"
    for word in "${words[@]}"; do [[ "$word" == "$field="* ]] && { printf '%s\n' "${word#*=}"; return; }; done
    return 1
}

freeze_peer() {
    local spec="$1" requested_family="$2" host port ip_addr family details source iface fingerprint route_unambiguous=1
    if ! parse_peer "$spec" >/dev/null; then die "peer 格式无效: $spec"; return 1; fi
    host=$PARSED_HOST; port=$PARSED_PORT
    ip_addr=$(resolve_peer_host "$host" "$requested_family") || { die "无法按 family=$requested_family 解析 peer: $host"; return 1; }
    family=$(family_of_ip "$ip_addr")
    details=$(route_details "$family" "$ip_addr") || { die "peer 路由不存在: $ip_addr"; return 1; }
    source=$(route_field "$details" src || true)
    iface=$(route_field "$details" dev || true)
    if [[ -z "$source" || -z "$iface" ]]; then die "无法冻结 peer 的来源地址/接口: $details"; return 1; fi
    fingerprint=$(printf '%s' "$details" | sha256_text) || { die '缺少 SHA-256 工具。'; return 1; }
    route_is_unambiguous "$family" "$ip_addr" "$source" || route_unambiguous=0
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$host" "$port" "$family" "$ip_addr" "$source" "$iface" "$fingerprint" "$route_unambiguous"
}

route_fingerprint() {
    local family="$1" ip_addr="$2" source="$3" details
    details=$(route_details "$family" "$ip_addr" "$source") || return 1
    printf '%s' "$details" | sha256_text
}

ping_collect() {
    local family="$1" ip_addr="$2" source="$3" count="$4" output_file="$5" interval="${6:-0.20}"
    local rc=0
    local -a args=(ping "-$family" -n -c "$count" -W 2 -i "$interval")
    [[ -z "$source" ]] || args+=(-I "$source")
    args+=("$ip_addr")
    : > "$output_file" || return 1
    timeout --signal=TERM --kill-after=5s "$((count / 2 + 10))" "${args[@]}" >> "$output_file" 2>&1 || rc=$?
    [[ -f "$output_file" && -r "$output_file" ]] || return 1
    (( rc != 125 && rc != 126 && rc != 127 ))
}

ping_jitter_from_file() {
    ping_samples_from_file "$1" | awk '
        /^[0-9]+([.][0-9]+)?$/ {
            if(n>0){d=$1-prev;if(d<0)d=-d;sum+=d} prev=$1;n++
        }
        END{if(n<2)exit 1;printf "%.3f\n",sum/(n-1)}'
}

ping_samples_from_file() {
    awk '/time[=<][0-9.]+/ {
        line=$0; sub(/^.*time[=<]/,"",line); sub(/[^0-9.].*$/,"",line)
        if(line ~ /^[0-9]+([.][0-9]+)?$/) print line
    }' "$1"
}

ping_loss_from_file() {
    awk -F',' '/packet loss/ {
        for(i=1;i<=NF;i++) if($i ~ /packet loss/) { gsub(/[^0-9.]/,"",$i); print $i; found=1; exit }
    } END{if(!found)print 100}' "$1"
}

cpu_snapshot() {
    local _cpu user nice system idle iowait irq softirq steal _guest _guest_nice total idle_all value
    [[ -r "${PROC_ROOT}/stat" ]] || return 1
    IFS=' ' read -r _cpu user nice system idle iowait irq softirq steal _guest _guest_nice < "${PROC_ROOT}/stat" || return 1
    [[ "$_cpu" == cpu ]] || return 1
    for value in "$user" "$nice" "$system" "$idle" "$iowait" "$irq" "$softirq" "$steal"; do
        is_uint "$value" || return 1
    done
    total=$((user+nice+system+idle+iowait+irq+softirq+steal))
    idle_all=$((idle+iowait))
    printf '%s %s %s\n' "$total" "$idle_all" "$steal"
}

cpu_steal_delta_pct() {
    local before_total="$1" before_steal="$2" after_total="$3" after_steal="$4"
    awk -v bt="$before_total" -v bs="$before_steal" -v at="$after_total" -v as="$after_steal" \
        'BEGIN { d=at-bt; if(d<=0){print 0}else{printf "%.3f\n",((as-bs)/d)*100} }'
}

cpu_busy_delta_pct() {
    local before_total="$1" before_idle="$2" after_total="$3" after_idle="$4"
    awk -v bt="$before_total" -v bi="$before_idle" -v at="$after_total" -v ai="$after_idle" \
        'BEGIN { d=at-bt; idle=ai-bi; if(d<=0){print 0}else{v=((d-idle)/d)*100;if(v<0)v=0;printf "%.3f\n",v} }'
}

interface_bytes() {
    local iface="$1" value rx tx
    [[ "$iface" =~ ^[A-Za-z0-9_.:-]{1,15}$ && -r "${PROC_ROOT}/net/dev" ]] || return 1
    value=$(awk -v i="$iface:" '
        $1==i {
            if ($2 !~ /^[0-9]+$/ || $10 !~ /^[0-9]+$/) { bad=1; exit }
            printf "%s\t%s\n",$2,$10; found=1; exit
        }
        END { if (bad) exit 2; if (!found) exit 1 }
    ' "${PROC_ROOT}/net/dev") || return 1
    IFS=$'\t' read -r rx tx <<< "$value"
    is_uint "$rx" && is_uint "$tx" || return 1
    value=$((rx + tx))
    is_uint "$value" || return 1
    printf '%s\n' "$value"
}

monotonic_seconds() {
    awk 'NR==1 && $1 ~ /^[0-9]+([.][0-9]+)?$/ {print $1;found=1;exit} END{if(!found)exit 1}' "${PROC_ROOT}/uptime"
}

declare TEST_BPS=0 TEST_BYTES=0 TEST_RETRANS="" TEST_RETRANS_KNOWN=0 TEST_CV=999 TEST_BUSY=0
declare TEST_LOSS_PCT=0 TEST_LOSS_KNOWN=0 TEST_JITTER_MS=0 TEST_JITTER_KNOWN=0

run_iperf_test() {
    local name="$1" ip_addr="$2" port="$3" family="$4" source="$5" duration="$6" rate="$7" parallel="$8" reverse="$9" output_file="${10}" byte_limit="${11:-0}" transport="${12:-tcp}"
    local per_stream error_text="" rc=0 interval_values retrans_state retrans_output
    local -a args=(iperf3 "-$family" -c "$ip_addr" -p "$port" -B "$source" -J -i 0.25 -O 1)
    [[ "$transport" == tcp || "$transport" == udp ]] || return 1
    [[ "$family" == 4 || "$family" == 6 ]] || return 1
    is_uint "$port" && (( 10#$port >= 1 && 10#$port <= 65535 )) || return 1
    is_positive_uint "$duration" && (( duration <= 300 )) || return 1
    is_positive_uint "$rate" || return 1
    float_cmp "$rate" le 9000000000000 || return 1
    is_positive_uint "$parallel" && (( parallel <= 128 )) || return 1
    is_bool01 "$reverse" || return 1
    is_uint "$byte_limit" || return 1
    TEST_BPS=0; TEST_BYTES=0; TEST_RETRANS=""; TEST_RETRANS_KNOWN=0; TEST_CV=999; TEST_BUSY=0
    TEST_LOSS_PCT=0; TEST_LOSS_KNOWN=0; TEST_JITTER_MS=0; TEST_JITTER_KNOWN=0
    (( parallel > 1 )) && args+=(-P "$parallel")
    # Planner rates are aggregate Mbit/s.  Convert to Kbit/s before splitting
    # across parallel streams; keeping the K suffix preserves fractional
    # Mbit/s allocations (e.g. 7 Mbit/s / 4 = 1750 Kbit/s).
    per_stream=$((rate * 1000 / parallel)); (( per_stream < 1 )) && per_stream=1
    if [[ "$transport" == udp ]]; then
        args+=(-u -b "${per_stream}K" --udp-counters-64bit)
    else
        args+=(-b "${per_stream}K")
    fi
    args+=(-t "$duration")
    (( reverse == 0 )) || args+=(-R)
    timeout --signal=TERM --kill-after=5s "$((duration + 15))" "${args[@]}" > "$output_file" 2>"${output_file}.stderr" || rc=$?
    if ! jq -e . "$output_file" >/dev/null 2>&1; then
        (( rc == 0 )) && rc=1
        return "$rc"
    fi
    error_text=$(jq -er '(.error // "") | strings' "$output_file") || return 1
    if [[ -n "$error_text" ]]; then
        [[ "${error_text,,}" == *busy* ]] && TEST_BUSY=1
        return 1
    fi
    (( rc == 0 )) || return "$rc"
    TEST_BYTES=$(jq -er '(.end.sum_received.bytes // .end.sum_sent.bytes // .end.sum.bytes // 0) | numbers | floor' "$output_file") || return 1
    TEST_BPS=$(jq -er '(.end.sum_received.bits_per_second // .end.sum_sent.bits_per_second // .end.sum.bits_per_second // 0) | numbers | floor' "$output_file") || return 1
    if [[ "$transport" == tcp ]]; then
        # iperf3's client JSON reports the aggregate sender statistics in
        # end.sum_sent.  In reverse mode the client is a receiver, so the
        # sender boolean must be false; in normal mode it must be true.  A
        # numeric retransmit field without that direction proof is not safe
        # to use as a zero or as a real counter.
        retrans_state=$(jq -er --argjson expected_reverse "$reverse" '
            .end.sum_sent as $sum |
            if ($sum | type) != "object" then
                "unknown"
            elif ($sum.sender | type) != "boolean" then
                "unknown"
            elif $sum.sender != ($expected_reverse == 0) then
                "unknown"
            elif (($sum | has("retransmits")) | not) then
                "unknown"
            elif ($sum.retransmits | type) != "number" then
                "unknown"
            elif ($sum.retransmits < 0) or
                 (($sum.retransmits | floor) != $sum.retransmits) then
                "unknown"
            else
                ($sum.retransmits | floor | tostring)
            end' "$output_file") || return 1
        case "$retrans_state" in
            unknown) TEST_RETRANS="" ;;
            [0-9]*) TEST_RETRANS="$retrans_state"; TEST_RETRANS_KNOWN=1 ;;
            *) return 1 ;;
        esac
    else
        # Retransmissions are a TCP sender counter and have no meaning for a
        # UDP test.  Keep the per-test field explicitly unavailable instead of
        # manufacturing a zero that could be mistaken for a TCP result.
        TEST_RETRANS=""
        TEST_RETRANS_KNOWN=0
    fi
    if [[ "$transport" == udp ]]; then
        if TEST_LOSS_PCT=$(jq -er '(.end.sum.lost_percent // .end.sum_received.lost_percent // empty) | numbers' "$output_file" 2>/dev/null); then
            TEST_LOSS_KNOWN=1
        fi
        if TEST_JITTER_MS=$(jq -er '(.end.sum.jitter_ms // .end.sum_received.jitter_ms // empty) | numbers' "$output_file" 2>/dev/null); then
            TEST_JITTER_KNOWN=1
        fi
        if (( TEST_LOSS_KNOWN )) && {
            ! is_nonnegative_number "$TEST_LOSS_PCT" || ! float_cmp "$TEST_LOSS_PCT" le 100
        }; then
            return 1
        fi
        if (( TEST_JITTER_KNOWN )) && {
            ! is_nonnegative_number "$TEST_JITTER_MS" || ! float_cmp "$TEST_JITTER_MS" le 1000000000
        }; then
            return 1
        fi
    fi
    interval_values=$(jq -er '[.intervals[]? | select((.sum.seconds // .sum_received.seconds // 0) >= 0.20) | (.sum.bits_per_second // .sum_received.bits_per_second // empty) | numbers] | if length>=2 then .[] else error("insufficient steady intervals") end' "$output_file") || return 1
    TEST_CV=$(printf '%s\n' "$interval_values" | coefficient_variation) || return 1
    if ! is_positive_uint "$TEST_BYTES" || ! is_positive_uint "$TEST_BPS" ||
       ! is_nonnegative_number "$TEST_CV" ||
       ! float_cmp "$TEST_BYTES" le 9000000000000000 ||
       ! float_cmp "$TEST_BPS" le 9000000000000000; then return 1; fi
    if [[ "$transport" == tcp && "$TEST_RETRANS_KNOWN" == 1 ]]; then
        is_uint "$TEST_RETRANS" || return 1
        float_cmp "$TEST_RETRANS" le 9000000000000000 || return 1
    fi
    # Keep the byte-limit comparison in awk: iperf3 counters are untrusted
    # kernel/peer data and multiplying a large counter in Bash can overflow a
    # signed shell integer before the budget check gets a chance to reject it.
    if is_positive_uint "$byte_limit" && ! awk -v bytes="$TEST_BYTES" -v limit="$byte_limit" \
        'BEGIN{exit !(bytes*100 <= limit*102)}'; then return 1; fi
    retrans_output=NA
    (( TEST_RETRANS_KNOWN == 1 )) && retrans_output=$TEST_RETRANS
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$TEST_BPS" "$TEST_BYTES" "$retrans_output" "$TEST_RETRANS_KNOWN" "$TEST_CV" "$rate"
}

counter_snapshot() {
    local soft soft_processed soft_dropped soft_squeeze listen_overflows listen_drops syn_cookies syn_drops syncookies queue
    soft=$(softnet_totals)
    IFS=' ' read -r soft_processed soft_dropped soft_squeeze <<< "$soft"
    listen_overflows=$(nstat_value TcpExtListenOverflows)
    listen_drops=$(nstat_value TcpExtListenDrops)
    syn_cookies=$(nstat_value TcpExtTCPReqQFullDoCookies)
    syn_drops=$(nstat_value TcpExtTCPReqQFullDrop)
    syncookies=$(nstat_value TcpExtSyncookiesSent)
    queue=$(listen_queue_pressure)
    printf '%s %s %s %s %s %s %s %s %s\n' \
        "$listen_overflows" "$listen_drops" "$syn_cookies" "$syn_drops" "$syncookies" \
        "$soft_processed" "$soft_dropped" "$soft_squeeze" "$queue"
}

observe_pressure_windows() {
    local output_file="$1" i before after
    : > "$output_file" || return 1
    i=0
    while (( i < 3 )); do
        i=$((i + 1))
        before=$(counter_snapshot); sleep 1; after=$(counter_snapshot)
        awk -v b="$before" -v a="$after" 'BEGIN {
            split(b,x," ");split(a,y," ");
            for(i=1;i<=9;i++) if(x[i]=="NA" || y[i]=="NA") {print "NA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA"; exit}
            lo=y[1]-x[1]; ld=y[2]-x[2]; rc=y[3]-x[3]; rd=y[4]-x[4]; sc=y[5]-x[5]
            sp=y[6]-x[6]; sd=y[7]-x[7]; sq=y[8]-x[8]
            if(lo<0)lo=0;if(ld<0)ld=0;if(sp<0)sp=0;if(sd<0)sd=0;if(sq<0)sq=0
            if(rc<0)rc=0;if(rd<0)rd=0;if(sc<0)sc=0
            listen=(lo>0 || ld>0) && y[9]==1 ? 1 : 0
            soft=sd>0 ? 1 : 0
            syn=(rc>0 || rd>0 || sc>0) ? 1 : 0
            printf "%d\t%d\t%d\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\n",listen,soft,syn,lo,ld,sp,sd,sq,rc,rd,sc
        }' >> "$output_file" || return 1
    done
}

pressure_window_count() {
    awk -v col="$2" -F'\t' '{if($col=="NA")bad=1; else if($col==1)n++} END{if(bad)print "NA";else print n+0}' "$1"
}
pressure_delta_sum() {
    awk -v col="$2" -F'\t' '{if($col=="NA")bad=1; else n+=$col} END{if(bad)print "NA";else printf "%.0f\n",n+0}' "$1"
}
pressure_consecutive_count() {
    awk -v col="$2" -F'\t' '{if($col=="NA")bad=1; else if($col==1){run++;if(run>max)max=run}else run=0} END{if(bad)print "NA";else print max+0}' "$1"
}

metric_put() { printf '%s\t%s\n' "$2" "$3" >> "$1"; }

write_measure_report_json() {
    local run_dir metrics peers_json output
    run_dir=$1; metrics=$2; peers_json=$3; output="$run_dir/report.json"
    declare -A m=()
    local key value
    while IFS=$'\t' read -r key value; do [[ "$key" =~ ^[A-Z0-9_]+$ ]] && m[$key]=$value; done < "$metrics"
    jq -n \
        --arg schema "$SCHEMA_VERSION" --arg run "${m[RUN_ID]}" --arg created "${m[CREATED_AT]}" \
        --arg os "${m[OS]}" --arg kernel "${m[KERNEL]}" --arg arch "${m[ARCH]}" --arg profile "${m[PROFILE]}" \
        --arg confidence "${m[CONFIDENCE]}" --arg quality "${m[QUALITY]}" \
        --argjson peers "$(<"$peers_json")" \
        --argjson effective_mbps "${m[EFFECTIVE_MBPS]}" --argjson rtt "${m[RTT_P95_MS]}" \
        --argjson loss "${m[LOSS_PCT]}" --argjson loss_known "${m[LOSS_KNOWN]}" \
        --argjson jitter "${m[JITTER_MS]}" --argjson jitter_known "${m[JITTER_KNOWN]}" --argjson loaded "${m[LOADED_DELTA_MS]}" \
        --argjson retrans "$(json_number_or_null "${m[RETRANS_PCT]:-}")" --argjson retrans_known "${m[RETRANS_KNOWN]:-0}" \
        --argjson bytes "${m[ACTUAL_BYTES]}" --argjson wire "${m[WIRE_BYTES]}" \
        --argjson budget "${m[BUDGET_BYTES]}" --argjson cv "${m[MAX_CV_PCT]}" \
        --argjson bg "${m[BACKGROUND_PCT]}" --argjson busy "${m[CPU_BUSY_PCT]}" --argjson steal "${m[CPU_STEAL_PCT]}" \
        --argjson verify_bytes "${m[VERIFY_RESERVED_BYTES]}" --argjson verify_duration "${m[VERIFY_DURATION_SECONDS]}" \
        --argjson verify_capacity "${m[VERIFY_CAPACITY_MBPS]}" --argjson verify_target "${m[VERIFY_TARGET_MBPS]}" \
        --argjson listen_overflow_delta "$(json_number_or_null "${m[LISTEN_OVERFLOW_DELTA]}")" --argjson listen_drop_delta "$(json_number_or_null "${m[LISTEN_DROP_DELTA]}")" \
        --argjson softnet_processed_delta "$(json_number_or_null "${m[SOFTNET_PROCESSED_DELTA]}")" --argjson softnet_dropped_delta "$(json_number_or_null "${m[SOFTNET_DROPPED_DELTA]}")" \
        --argjson softnet_squeeze_delta "$(json_number_or_null "${m[SOFTNET_SQUEEZE_DELTA]}")" --argjson listen_windows "$(json_number_or_null "${m[LISTEN_PRESSURE_WINDOWS]}")" \
        --argjson syn_windows "$(json_number_or_null "${m[SYN_QUEUE_WINDOWS]}")" --argjson syn_cookies_delta "$(json_number_or_null "${m[SYN_QUEUE_COOKIES_DELTA]}")" \
        --argjson syn_drop_delta "$(json_number_or_null "${m[SYN_QUEUE_DROP_DELTA]}")" --argjson syncookies_delta "$(json_number_or_null "${m[SYNCOOKIES_DELTA]}")" \
        --argjson udp_loss "$(json_number_or_null "${m[UDP_LOSS_PCT]}")" --argjson udp_loss_known "$(json_number_or_null "${m[UDP_LOSS_KNOWN]}")" \
        --argjson udp_jitter "$(json_number_or_null "${m[UDP_JITTER_MS]}")" --argjson udp_jitter_known "$(json_number_or_null "${m[UDP_JITTER_KNOWN]}")" \
        --argjson udp_metrics_complete "$(json_number_or_null "${m[UDP_METRICS_COMPLETE]}")" \
        --argjson udp_tests_ok "$(json_number_or_null "${m[UDP_TESTS_OK]}")" --argjson udp_tests_total "$(json_number_or_null "${m[UDP_TESTS_TOTAL]}")" \
        --argjson softnet_windows "$(json_number_or_null "${m[SOFTNET_DROP_WINDOWS]}")" \
        '{schema_version:$schema,run_id:$run,outcome:"ok",reason_code:"measurement_complete",environment:{created_at:$created,os:$os,kernel:$kernel,arch:$arch,profile:$profile},path:{peers:$peers},metrics:{effective_mbps:$effective_mbps,rtt_p95_ms:$rtt,loss_pct:(if $loss_known==1 then $loss else null end),jitter_ms:(if $jitter_known==1 then $jitter else null end),udp_loss_pct:(if $udp_loss_known==1 then $udp_loss else null end),udp_jitter_ms:(if $udp_jitter_known==1 then $udp_jitter else null end),udp_metrics_complete:($udp_metrics_complete==1),udp_tests_ok:$udp_tests_ok,udp_tests_total:$udp_tests_total,loaded_delta_ms:$loaded,retransmits_known:($retrans_known==1),retrans_pct:(if $retrans_known==1 then $retrans else null end),actual_bytes:$bytes,wire_bytes:$wire,budget_bytes:$budget,cv_pct:$cv,background_pct:$bg,cpu_busy_pct:$busy,cpu_steal_pct:$steal,verification_budget:{eligible:($verify_duration>0),reserved_bytes:$verify_bytes,duration_seconds:$verify_duration,capacity_mbps:$verify_capacity,target_mbps:$verify_target},listen_overflow_delta:$listen_overflow_delta,listen_drop_delta:$listen_drop_delta,softnet_processed_delta:$softnet_processed_delta,softnet_dropped_delta:$softnet_dropped_delta,softnet_time_squeeze_delta:$softnet_squeeze_delta,listen_pressure_windows:$listen_windows,syn_queue_windows:$syn_windows,syn_queue_cookies_delta:$syn_cookies_delta,syn_queue_drop_delta:$syn_drop_delta,syncookies_delta:$syncookies_delta,softnet_drop_consecutive_windows:$softnet_windows},confidence:$confidence,quality:$quality,recommendations:{},changes:[],warnings:[],rollback_status:"not-applied"}' > "$output" || return 1
    chmod 0600 "$output" || return 1
}

metric_get() {
    local file="$1" key="$2"
    [[ "$key" =~ ^[A-Z0-9_]+$ && -r "$file" ]] || return 1
    awk -F'\t' -v wanted="$key" '$1==wanted{print substr($0,index($0,$2));found=1;exit} END{if(!found)exit 1}' "$file"
}

float_max() {
    local left="$1" right="$2"
    if ! is_nonnegative_number "$left" || ! is_nonnegative_number "$right"; then return 1; fi
    awk -v a="$left" -v b="$right" 'BEGIN{if(a>b)print a;else print b}'
}

create_hash_manifest() {
    local directory="$1" output="$2" file relative hash list_file temp failed=0
    [[ -d "$directory" && ! -L "$directory" && "$output" == "$directory/"* ]] || return 1
    trusted_tmp_dir || return 1
    list_file=$(mktemp "/tmp/vps-proxy-tune-files.XXXXXXXX") || return 1
    if ! find "$directory" -type f -print | LC_ALL=C sort > "$list_file"; then
        rm -f -- "$list_file"; return 1
    fi
    temp=$(mktemp "${output}.tmp.XXXXXXXX") || { rm -f -- "$list_file"; return 1; }
    while IFS= read -r file; do
        [[ "$file" == "$output" ]] && continue
        relative=${file#"$directory"/}
        # These are apply-time derived views, not immutable user plans.  They
        # may be regenerated when safe/fresh filters an unverified pacing action.
        [[ "$relative" == sysctl.conf.apply || "$relative" == all-owned-plan.tsv || "$relative" == identity.tsv ]] && continue
        if [[ ! "$relative" =~ ^[A-Za-z0-9._/-]+$ ]] || ! hash=$(sha256sum "$file" | awk '{print $1}') ||
           [[ ! "$hash" =~ ^[0-9a-f]{64}$ ]] || ! printf '%s  %s\n' "$hash" "$relative" >> "$temp"; then
            failed=1
            break
        fi
    done < "$list_file"
    if ! rm -f -- "$list_file"; then
        rm -f -- "$temp"; return 1
    fi
    if (( failed != 0 )); then
        rm -f -- "$temp"; return 1
    fi
    if ! chmod 0600 "$temp" || ! atomic_install "$temp" "$output" 0600; then
        rm -f -- "$list_file" "$temp"; return 1
    fi
    rm -f -- "$temp"
}

create_transaction_snapshot_manifest() {
    local transaction="$1" file relative hash list_file failed=0
    local output="$transaction/snapshot.sha256"
    : > "$output" || return 1
    for file in "$transaction/guard-script.sh" "$transaction/runtime.before.tsv" \
        "$transaction/desired.tsv" "$transaction/files.tsv"; do
        [[ -f "$file" && ! -L "$file" ]] || return 1
        relative=${file#"$transaction"/}
        hash=$(sha256sum "$file" | awk '{print $1}') || return 1
        [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
        printf '%s  %s\n' "$hash" "$relative" >> "$output" || return 1
    done
    if [[ -e "$transaction/files.identity.tsv" || -L "$transaction/files.identity.tsv" ]]; then
        file="$transaction/files.identity.tsv"
        [[ -f "$file" && ! -L "$file" ]] || return 1
        hash=$(sha256sum "$file" | awk '{print $1}') || return 1
        [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
        printf '%s  files.identity.tsv\n' "$hash" >> "$output" || return 1
    fi
    trusted_tmp_dir || return 1
    list_file=$(mktemp "/tmp/vps-proxy-tune-snapshots.XXXXXXXX") || return 1
    if ! find "$transaction/files" -maxdepth 1 -type f -name '*.before' -print | LC_ALL=C sort > "$list_file"; then
        rm -f -- "$list_file"; return 1
    fi
    while IFS= read -r file; do
        relative=${file#"$transaction"/}
        if [[ ! "$relative" =~ ^[A-Za-z0-9._/-]+$ ]] || ! hash=$(sha256sum "$file" | awk '{print $1}') ||
           [[ ! "$hash" =~ ^[0-9a-f]{64}$ ]] || ! printf '%s  %s\n' "$hash" "$relative" >> "$output"; then
            failed=1
            break
        fi
    done < "$list_file"
    rm -f -- "$list_file" || return 1
    (( failed == 0 )) || return 1
    chmod 0600 "$output" || return 1
}

verify_hash_manifest() {
    local directory="$1" manifest="$2" line hash relative path actual component current count=0
    local -a components=()
    local -A seen=()
    [[ -d "$directory" && ! -L "$directory" && -f "$manifest" && ! -L "$manifest" && -r "$manifest" ]] || return 1
    [[ "$manifest" == "$directory/"* ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        hash=${line%%  *}; relative=${line#*  }
        [[ "$line" == "$hash  $relative" && "$hash" =~ ^[0-9a-f]{64}$ &&
           "$relative" =~ ^[A-Za-z0-9._/-]+$ && "$relative" != /* &&
           "$relative" != . && "$relative" != .. && "$relative" != ./* &&
           "$relative" != ../* && "$relative" != */./* && "$relative" != */../* &&
           "$relative" != */. && "$relative" != */.. && "$relative" != *//* ]] || return 1
        [[ -z "${seen[$relative]+x}" ]] || return 1
        seen[$relative]=1
        path="$directory/$relative"; current=$directory
        IFS=/ read -r -a components <<< "$relative"
        for component in "${components[@]}"; do
            current="$current/$component"
            if [[ "$current" == "$path" ]]; then
                [[ -f "$current" && ! -L "$current" ]] || return 1
            else
                [[ -d "$current" && ! -L "$current" ]] || return 1
            fi
        done
        actual=$(sha256sum "$path" | awk '{print $1}') || return 1
        [[ "$actual" == "$hash" ]] || return 1
        count=$((count + 1))
    done < "$manifest"
    (( count > 0 ))
}

measure_interrupt() {
    local run_dir="${1:-}" temp
    [[ -n "$run_dir" && -d "$run_dir" ]] || return 0
    [[ "$run_dir" == "$STATE_DIR/runs/"* || "$run_dir" == /tmp/vps-proxy-tune-*/* ]] || return 1
    temp=$(mktemp "$run_dir/.aborted.XXXXXXXX") || return 1
    if printf 'aborted\n' > "$temp" && chmod 0600 "$temp" && atomic_install "$temp" "$run_dir/status" 0600; then
        rm -f -- "$temp"
        return 0
    fi
    rm -f -- "$temp"
    return 1
}

MEASURE_RUN_DIR=""
MEASURE_LOADED_PID=0
MEASURE_PRESSURE_PID=0
MEASURE_LOADED_STARTTIME=""
MEASURE_PRESSURE_STARTTIME=""

measure_cleanup() {
    local pid expected
    if is_positive_uint "$MEASURE_LOADED_PID"; then
        pid=$MEASURE_LOADED_PID; expected=$MEASURE_LOADED_STARTTIME
        terminate_owned_process "$pid" "$expected" TERM 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    if is_positive_uint "$MEASURE_PRESSURE_PID"; then
        pid=$MEASURE_PRESSURE_PID; expected=$MEASURE_PRESSURE_STARTTIME
        terminate_owned_process "$pid" "$expected" TERM 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    MEASURE_LOADED_PID=0
    MEASURE_PRESSURE_PID=0
    MEASURE_LOADED_STARTTIME=""
    MEASURE_PRESSURE_STARTTIME=""
}

measure_exit_cleanup() {
    local saved_status=$?
    measure_cleanup
    if (( saved_status != 0 )) && [[ -n "$MEASURE_RUN_DIR" ]]; then
        measure_interrupt "$MEASURE_RUN_DIR" || true
    fi
    MEASURE_RUN_DIR=""
    # cmd_auto --dry-run runs measure in a command-substitution subshell.  If
    # that subshell is interrupted, also remove the parent's private preview
    # tree instead of relying only on the parent EXIT trap.
    if [[ -n "${AUTO_PREVIEW_DIR:-}" ]]; then
        auto_preview_cleanup "$AUTO_PREVIEW_DIR" "${AUTO_PREVIEW_SAVED_STATE:-}" \
            "${AUTO_PREVIEW_SAVED_RUN:-}" "${AUTO_PREVIEW_SAVED_LOCK:-}" || true
        AUTO_PREVIEW_DIR=""
    fi
    return "$saved_status"
}

measure_signal_exit() { exit 130; }

cmd_measure() {
    local -a peer_specs=()
    local family=auto profile=tcp budget_mib=1024 duration=5 arg spec frozen
    local run_id run_dir metrics peers_tsv peers_json frozen_inputs pressure_file peer_count peer_budget rate per_test_cap test_count min_peer_budget
    local idx=0 host port fam ip_addr source iface frozen_fp route_unambiguous peer_dir
    local idle_p50 idle_p95 idle_loss idle_samples idle_jitter loaded_p95 loaded_delta has_rtt tcp_rtt=0 tcp_loaded_max
    local loss_known jitter_known loss_json jitter_json
    local cpu_before_total cpu_before_idle cpu_before_steal cpu_after_total cpu_after_idle cpu_after_steal cpu_snapshot_before cpu_snapshot_after steal cpu_busy
    local iface_before iface_after iface_delta peer_wire_before peer_wire_after peer_wire_delta background_pct actual_bytes
    local idle_iface_before idle_iface_after idle_wire idle_time_before idle_time_after idle_duration idle_background_bps
    local active_unexplained_pct idle_background_pct test_average_bps
    local four_ok udp_ok udp_metrics_complete route_stable resolution_stable busy budget_ok wire_counter_ok rate_limited success_count udp_success_count udp_test_count retrans_pct resolved_after
    local tcp_retrans_known retrans_json
    local single_up_bps single_down_bps single_bps effective_mbps max_cv peer_conf peer_quality quality_loss
    local overall_conf=high overall_loss=0 overall_loss_known=1 overall_loaded=0 overall_retrans=0 overall_retrans_known=1 overall_cv=0
    local overall_bg=0 overall_busy=0 overall_steal=0 selected_mbps=0 selected_rtt=1 selected_score=0
    local selected_index=0 selected_loaded=0 selected_retrans=0 selected_retrans_known=0 selected_jitter=0 selected_jitter_known=0
    local overall_udp_loss=0 overall_udp_loss_known=0 overall_udp_jitter=0 overall_udp_jitter_known=0 overall_udp_metrics_complete=1
    local total_actual=0 total_wire=0 total_budget_bytes route_now loaded_pid=0 pressure_pid=0 test_index name parallel reverse tcp_actual_bytes tcp_retrans_segments
    local total_udp_success=0 total_udp_tests=0
    local verification_profile verification_bytes=0 verification_mib=0 verification_duration=0 verification_capacity=0 verification_target=0 verification_tests=2
    local local_score overall_quality peer_loss peer_loss_known peer_jitter peer_jitter_known udp_loss_json udp_jitter_json transport retrans_output
    local -a names=(upload_1 upload_4 download_1 download_4)
    local -a transports=(tcp tcp tcp tcp)
    local -a parallels=(1 4 1 4)
    local -a reverses=(0 0 1 1)

    JSON_OUTPUT=0; DRY_RUN=0; INSTALL_DEPS=0; JSON_ERROR_EMITTED=0
    while (($#)); do
        arg=$1; shift
        case "$arg" in
            --profile) (($#)) || { die '--profile 缺少值'; return 1; }; profile=$1; shift ;;
            --profile=*) profile=${arg#*=} ;;
            --peer) (($#)) || { die '--peer 缺少值'; return 1; }; peer_specs+=("$1"); shift ;;
            --peer=*) peer_specs+=("${arg#*=}") ;;
            --family) (($#)) || { die '--family 缺少值'; return 1; }; family=$1; shift ;;
            --family=*) family=${arg#*=} ;;
            --budget-mib) (($#)) || { die '--budget-mib 缺少值'; return 1; }; budget_mib=$1; shift ;;
            --budget-mib=*) budget_mib=${arg#*=} ;;
            --json) JSON_OUTPUT=1 ;;
            --dry-run) DRY_RUN=1 ;;
            --install-deps) INSTALL_DEPS=1 ;;
            *) die "measure 不支持参数: $arg"; return 1 ;;
        esac
    done
    (( DRY_RUN == 0 || INSTALL_DEPS == 0 )) || { die '--dry-run 与 --install-deps 不能同时使用。'; return 1; }
    (( ${#peer_specs[@]} > 0 && ${#peer_specs[@]} <= 8 )) || { die '必须提供 1 至 8 个 --peer。'; return 1; }
    [[ "$profile" == tcp || "$profile" == mixed ]] || { die '--profile 只能是 tcp 或 mixed。'; return 1; }
    [[ "$family" == auto || "$family" == 4 || "$family" == 6 ]] || { die '--family 只能是 auto、4 或 6。'; return 1; }
    if ! is_positive_uint "$budget_mib" || (( budget_mib > MAX_BUDGET_MIB )); then die "--budget-mib 必须是 1..${MAX_BUDGET_MIB} 的整数。"; return 1; fi
    for spec in "${peer_specs[@]}"; do validate_peer "$spec" || { die "peer 格式无效: $spec"; return 1; }; done

    if [[ "$profile" == mixed ]]; then
        # UDP is measured in both directions in addition to the four TCP
        # tests.  Keep the per-test reservation proportional to the number of
        # tests so the aggregate wire-byte budget remains bounded.
        names+=(udp_upload udp_download)
        transports+=(udp udp)
        parallels+=(1 1)
        reverses+=(0 1)
        verification_tests=4
    fi
    test_count=${#names[@]}
    min_peer_budget=4
    [[ "$profile" == mixed ]] && min_peer_budget=6
    (( budget_mib >= ${#peer_specs[@]} * min_peer_budget )) || {
        die "当前 profile 至少需要每个 peer ${min_peer_budget} MiB 预算；请提高 --budget-mib。"; return 1;
    }

    require_root || return 1
    require_measure_commands || return 1
    if (( DRY_RUN )); then
        if (( JSON_OUTPUT )); then
            jq -n --arg schema "$SCHEMA_VERSION" --arg profile "$profile" --arg family "$family" \
                --argjson peers "${#peer_specs[@]}" --argjson budget "$budget_mib" \
                '{schema_version:$schema,operation:"measure",outcome:"ok",reason_code:"measurement_preview",dry_run:true,profile:$profile,family:$family,peer_count:$peers,budget_mib:$budget,network_requests:false,state_write:false}'
        else
            printf 'dry-run：将测量 %s 个 peer，profile=%s，family=%s，总预算=%s MiB；未发送网络请求且未写入状态。\n' \
                "${#peer_specs[@]}" "$profile" "$family" "$budget_mib"
        fi
        return 0
    fi
    ensure_state_dirs || return 1
    acquire_lock || return 1
    umask 077
    run_id=$(new_run_id)
    run_dir="$STATE_DIR/runs/$run_id"
    mkdir -m 0700 "$run_dir" || return 1
    MEASURE_RUN_DIR="$run_dir"
    MEASURE_LOADED_PID=0
    MEASURE_PRESSURE_PID=0
    MEASURE_LOADED_STARTTIME=""
    MEASURE_PRESSURE_STARTTIME=""
    trap measure_exit_cleanup EXIT
    trap measure_signal_exit INT TERM HUP
    metrics="$run_dir/metrics.tsv"; peers_tsv="$run_dir/peers.tsv"; peers_json="$run_dir/peers.json"
    frozen_inputs="$run_dir/frozen-inputs.tsv"
    pressure_file="$run_dir/pressure.tsv"
    : > "$metrics" || return 1
    : > "$peers_tsv" || return 1
    : > "$frozen_inputs" || return 1
    printf '[]\n' > "$peers_json" || return 1
    peer_count=${#peer_specs[@]}
    peer_budget=$((budget_mib / peer_count))
    total_budget_bytes=$((budget_mib * MIB))
    # Cheap preflight for the minimum-duration profile. The actual duration and
    # rate are recomputed per peer after idle RTT is known.
    per_test_cap=$((peer_budget * MIB * 70 / (100 * test_count)))
    rate=$(awk -v cap="$per_test_cap" -v seconds="$duration" \
        'BEGIN{r=int((cap*8*0.95)/(seconds*1000000));if(r<1)exit 1;print r}') || {
        die "预算太小，无法在不超出预算的情况下完成 ${test_count} 类定时测试。"; return 1;
    }

    log "run_id=$run_id；冻结 $peer_count 条路径，总预算 ${budget_mib} MiB；每项时长和限速将在空载 RTT 后自适应计算。"
    for spec in "${peer_specs[@]}"; do
        frozen=$(freeze_peer "$spec" "$family") || return 1
        printf '%s\n' "$frozen" >> "$peers_tsv" || return 1
        printf '%s\t%s\n' "$spec" "$frozen" >> "$frozen_inputs" || return 1
    done
    log '所有 peer 的地址族、目标/源地址、出口接口和路由指纹均已在主动测量前冻结。'
    idx=0
    while IFS=$'\t' read -r spec host port fam ip_addr source iface frozen_fp route_unambiguous; do
        idx=$((idx + 1))
        peer_dir="$run_dir/peer-$idx"; mkdir -m 0700 "$peer_dir" || return 1
        # Count every byte observed while this peer is being assessed, including
        # route probes, mtr and idle/loaded ping traffic. The iperf pacing keeps
        # reserve for these probes; a busy interface fails the wire-budget check.
        peer_wire_before=$(interface_bytes "$iface") || { die "无法读取接口字节计数: $iface"; return 1; }
        route_details "$fam" "$ip_addr" "$source" > "$peer_dir/route.before" || true
        if command_exists mtr; then
            timeout --signal=TERM --kill-after=5s 20 mtr "-$fam" -n -r -c 5 -a "$source" "$ip_addr" > "$peer_dir/mtr.txt" 2>&1 || true
        fi

        idle_iface_before=$(interface_bytes "$iface") || { die "无法读取空载前接口字节计数: $iface"; return 1; }
        idle_time_before=$(monotonic_seconds) || return 1
        ping_collect "$fam" "$ip_addr" "$source" 20 "$peer_dir/ping.idle" 0.20 || {
            die "无法执行 peer RTT 探测: $ip_addr"; return 1;
        }
        idle_time_after=$(monotonic_seconds) || return 1
        idle_iface_after=$(interface_bytes "$iface") || { die "无法读取空载后接口字节计数: $iface"; return 1; }
        idle_wire=$((idle_iface_after >= idle_iface_before ? idle_iface_after - idle_iface_before : 0))
        idle_duration=$(awk -v before="$idle_time_before" -v after="$idle_time_after" 'BEGIN{d=after-before;if(d<=0)exit 1;printf "%.6f\n",d}') || return 1
        idle_background_bps=$(awk -v bytes="$idle_wire" -v seconds="$idle_duration" 'BEGIN{printf "%.3f\n",bytes*8/seconds}')
        idle_samples=$(ping_samples_from_file "$peer_dir/ping.idle" | awk 'END{print NR+0}')
        loss_known=0; jitter_known=0; idle_loss=0; idle_jitter=0
        if is_positive_uint "$idle_samples"; then
            loss_known=1
            idle_loss=$(ping_loss_from_file "$peer_dir/ping.idle")
            if idle_jitter=$(ping_jitter_from_file "$peer_dir/ping.idle" 2>/dev/null); then jitter_known=1; else idle_jitter=0; fi
        fi
        idle_p50=$(ping_samples_from_file "$peer_dir/ping.idle" | percentile 50 2>/dev/null || printf '0')
        idle_p95=$(ping_samples_from_file "$peer_dir/ping.idle" | percentile 95 2>/dev/null || printf '0')
        has_rtt=0; float_cmp "$idle_p95" gt 0 2>/dev/null && has_rtt=1
        duration=$(measurement_duration_seconds "$peer_budget" "$idle_p95") || return 1
        per_test_cap=$((peer_budget * MIB * 70 / (100 * test_count)))
        rate=$(awk -v cap="$per_test_cap" -v seconds="$duration" \
            'BEGIN{r=int((cap*8*0.95)/(seconds*1000000));if(r<1)exit 1;print r}') || return 1
        log "peer[$idx]=$ip_addr：RTT p95=${idle_p95} ms，测试时长=${duration}s，每项限速=${rate} Mbit/s。"

        cpu_snapshot_before=$(cpu_snapshot) || { die '无法读取测速前 CPU 计数器。'; return 1; }
        IFS=' ' read -r cpu_before_total cpu_before_idle cpu_before_steal <<< "$cpu_snapshot_before"
        iface_before=$(interface_bytes "$iface") || { die "无法读取测速前接口字节计数: $iface"; return 1; }
        # Keep the loaded-RTT window alive for every test in the selected
        # profile.  mixed adds two UDP tests; probing for only the four TCP
        # durations would leave the latter half of the run unobserved.
        ping_collect "$fam" "$ip_addr" "$source" "$((duration * test_count * 5))" "$peer_dir/ping.loaded" 0.20 &
        loaded_pid=$!
        MEASURE_LOADED_PID=$loaded_pid
        MEASURE_LOADED_STARTTIME=$(process_start_time "$loaded_pid" 2>/dev/null || true)
        is_positive_uint "$MEASURE_LOADED_STARTTIME" || {
            terminate_owned_process "$loaded_pid" "$MEASURE_LOADED_STARTTIME" TERM 2>/dev/null || true
            wait "$loaded_pid" 2>/dev/null || true
            MEASURE_LOADED_PID=0; MEASURE_LOADED_STARTTIME=""
            die '无法验证 RTT 探测子进程身份。'; return 1;
        }
        if (( pressure_pid == 0 )); then
            observe_pressure_windows "$pressure_file" & pressure_pid=$!
            MEASURE_PRESSURE_PID=$pressure_pid
            MEASURE_PRESSURE_STARTTIME=$(process_start_time "$pressure_pid" 2>/dev/null || true)
            is_positive_uint "$MEASURE_PRESSURE_STARTTIME" || {
                terminate_owned_process "$pressure_pid" "$MEASURE_PRESSURE_STARTTIME" TERM 2>/dev/null || true
                wait "$pressure_pid" 2>/dev/null || true
                MEASURE_PRESSURE_PID=0; MEASURE_PRESSURE_STARTTIME=""
                die '无法验证压力观测子进程身份。'; return 1;
            }
        fi
        success_count=0; udp_success_count=0; udp_test_count=0; udp_metrics_complete=1; route_stable=$route_unambiguous; busy=0; budget_ok=1; rate_limited=0; actual_bytes=0; tcp_actual_bytes=0; tcp_retrans_segments=0; tcp_retrans_known=1
        peer_loss=0; peer_loss_known=0; peer_jitter=0; peer_jitter_known=0
        single_up_bps=0; single_down_bps=0; max_cv=0; tcp_loaded_max=0
        if ! printf 'name\ttransport\tok\tbps\tbytes\tretrans\tretrans_known\tcv_pct\trequested_mbps\tduration_seconds\tloss_pct\tjitter_ms\n' > "$peer_dir/tests.tsv" ||
           ! printf '[]\n' > "$peer_dir/tests.json"; then
            terminate_owned_process "$loaded_pid" "$MEASURE_LOADED_STARTTIME" TERM 2>/dev/null || true; wait "$loaded_pid" 2>/dev/null || true; MEASURE_LOADED_PID=0; MEASURE_LOADED_STARTTIME=""
            die '无法初始化测速结果文件。'; return 1
        fi
        for (( test_index=0; test_index<test_count; test_index++ )); do
            name=${names[$test_index]}; transport=${transports[$test_index]}; parallel=${parallels[$test_index]}; reverse=${reverses[$test_index]}
            [[ "$transport" == udp ]] && udp_test_count=$((udp_test_count + 1))
            if run_iperf_test "$name" "$ip_addr" "$port" "$fam" "$source" "$duration" "$rate" "$parallel" "$reverse" "$peer_dir/$name.json" "$per_test_cap" "$transport" > /dev/null; then
                [[ "$transport" == udp ]] && udp_success_count=$((udp_success_count + 1)) || success_count=$((success_count + 1))
                actual_bytes=$((actual_bytes + TEST_BYTES))
                if [[ "$transport" == tcp ]]; then
                    tcp_actual_bytes=$((tcp_actual_bytes + TEST_BYTES))
                    if (( TEST_RETRANS_KNOWN )); then
                        tcp_retrans_segments=$((tcp_retrans_segments + TEST_RETRANS))
                    else
                        tcp_retrans_known=0
                    fi
                fi
                # UDP loss/jitter are meaningful only when the iperf3 server
                # returned the corresponding counters.  Aggregate the worst
                # observed values without converting unavailable data to zero.
                if [[ "$transport" == udp ]]; then
                    # A successful UDP transfer without receiver-side loss
                    # counters is not sufficient evidence for a mixed-profile
                    # high-confidence decision.  Keep the unavailable state
                    # explicit rather than treating it as zero loss.
                    (( TEST_LOSS_KNOWN )) || udp_metrics_complete=0
                    if (( TEST_LOSS_KNOWN )); then
                        peer_loss_known=1
                        if float_cmp "$TEST_LOSS_PCT" gt "$peer_loss"; then peer_loss=$TEST_LOSS_PCT; fi
                    fi
                    if (( TEST_JITTER_KNOWN )); then
                        peer_jitter_known=1
                        if float_cmp "$TEST_JITTER_MS" gt "$peer_jitter"; then peer_jitter=$TEST_JITTER_MS; fi
                    fi
                fi
                # UDP is intentionally sent at a requested datagram rate, so
                # reaching that rate is expected rather than evidence of a
                # TCP pacing ceiling.  Apply the ceiling check only to TCP.
                if [[ "$transport" == tcp ]]; then
                    (( TEST_BPS < rate * 950000 )) || rate_limited=1
                fi
                max_cv=$(float_max "$max_cv" "$TEST_CV")
                [[ "$name" == upload_1 ]] && single_up_bps=$TEST_BPS
                [[ "$name" == download_1 ]] && single_down_bps=$TEST_BPS
                tcp_rtt=$(jq -er '[.end.streams[]?.sender.mean_rtt // empty] | if length>0 then (add/length/1000) else 0 end' "$peer_dir/$name.json" 2>/dev/null || printf '0')
                if is_nonnegative_number "$tcp_rtt" && float_cmp "$tcp_rtt" gt "$tcp_loaded_max"; then tcp_loaded_max=$tcp_rtt; fi
                if (( has_rtt == 0 )) && is_nonnegative_number "$tcp_rtt" && float_cmp "$tcp_rtt" gt 0; then
                    idle_p95=$tcp_rtt; idle_p50=$tcp_rtt; has_rtt=1
                fi
                retrans_output=NA
                (( TEST_RETRANS_KNOWN == 1 )) && retrans_output=$TEST_RETRANS
                retrans_json=null
                (( TEST_RETRANS_KNOWN == 1 )) && retrans_json=$TEST_RETRANS
                if ! printf '%s\t%s\t1\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$transport" "$TEST_BPS" "$TEST_BYTES" "$retrans_output" "$TEST_RETRANS_KNOWN" "$TEST_CV" "$rate" "$duration" "$TEST_LOSS_PCT" "$TEST_JITTER_MS" >> "$peer_dir/tests.tsv" ||
                    ! jq --arg name "$name" --argjson bps "$TEST_BPS" --argjson bytes "$TEST_BYTES" \
                     --argjson retrans "$retrans_json" --argjson retrans_known "$TEST_RETRANS_KNOWN" --argjson cv "$TEST_CV" --argjson streams "$parallel" \
                    --arg transport "$transport" --argjson loss "$TEST_LOSS_PCT" --argjson loss_known "$TEST_LOSS_KNOWN" \
                    --argjson jitter "$TEST_JITTER_MS" --argjson jitter_known "$TEST_JITTER_KNOWN" \
                    --argjson reverse "$reverse" --argjson duration "$duration" '. + [{name:$name,transport:$transport,ok:true,bps:$bps,bytes:$bytes,retransmits:(if $retrans_known==1 then $retrans else null end),retransmits_known:($retrans_known==1),cv_pct:$cv,streams:$streams,reverse:($reverse==1),duration_seconds:$duration,loss_pct:(if $loss_known==1 then $loss else null end),jitter_ms:(if $jitter_known==1 then $jitter else null end)}]' \
                    "$peer_dir/tests.json" > "$peer_dir/tests.json.tmp" ||
                   ! mv -T -- "$peer_dir/tests.json.tmp" "$peer_dir/tests.json"; then
                    terminate_owned_process "$loaded_pid" "$MEASURE_LOADED_STARTTIME" TERM 2>/dev/null || true; wait "$loaded_pid" 2>/dev/null || true; MEASURE_LOADED_PID=0; MEASURE_LOADED_STARTTIME=""
                    die '无法记录成功的测速结果。'; return 1
                fi
            else
                (( TEST_BUSY == 0 )) || busy=1
                # A failed UDP transfer cannot provide receiver-side loss or
                # jitter evidence.  Keep the aggregate completeness flag
                # false instead of presenting a failed test as complete.
                if [[ "$transport" == udp ]]; then
                    udp_metrics_complete=0
                else
                    # A failed TCP test is also an unavailable sender
                    # measurement.  Do not let the counters from the other
                    # three tests make the peer look retransmission-complete.
                    tcp_retrans_known=0
                fi
                if ! printf '%s\t%s\t0\t0\t0\tNA\t0\t999\t%s\t%s\tNA\tNA\n' "$name" "$transport" "$rate" "$duration" >> "$peer_dir/tests.tsv" ||
                    ! jq --arg name "$name" --arg transport "$transport" --argjson streams "$parallel" --argjson reverse "$reverse" --argjson duration "$duration" \
                    '. + [{name:$name,transport:$transport,ok:false,bps:0,bytes:0,retransmits:null,retransmits_known:false,cv_pct:999,streams:$streams,reverse:($reverse==1),duration_seconds:$duration,loss_pct:null,jitter_ms:null}]' \
                    "$peer_dir/tests.json" > "$peer_dir/tests.json.tmp" ||
                   ! mv -T -- "$peer_dir/tests.json.tmp" "$peer_dir/tests.json"; then
                    terminate_owned_process "$loaded_pid" "$MEASURE_LOADED_STARTTIME" TERM 2>/dev/null || true; wait "$loaded_pid" 2>/dev/null || true; MEASURE_LOADED_PID=0; MEASURE_LOADED_STARTTIME=""
                    die '无法记录失败的测速结果。'; return 1
                fi
            fi
            route_now=$(route_fingerprint "$fam" "$ip_addr" "$source" 2>/dev/null || printf unavailable)
            [[ "$route_now" == "$frozen_fp" ]] || route_stable=0
            route_is_unambiguous "$fam" "$ip_addr" "$source" || route_stable=0
        done
        wait "$loaded_pid" 2>/dev/null || true; loaded_pid=0; MEASURE_LOADED_PID=0; MEASURE_LOADED_STARTTIME=""
        cpu_snapshot_after=$(cpu_snapshot) || { die '无法读取测速后 CPU 计数器。'; return 1; }
        IFS=' ' read -r cpu_after_total cpu_after_idle cpu_after_steal <<< "$cpu_snapshot_after"
        iface_after=$(interface_bytes "$iface") || { die "无法读取测速后接口字节计数: $iface"; return 1; }
        peer_wire_after=$iface_after
        steal=$(cpu_steal_delta_pct "$cpu_before_total" "$cpu_before_steal" "$cpu_after_total" "$cpu_after_steal")
        cpu_busy=$(cpu_busy_delta_pct "$cpu_before_total" "$cpu_before_idle" "$cpu_after_total" "$cpu_after_idle")
        iface_delta=$((iface_after >= iface_before ? iface_after - iface_before : 0))
        wire_counter_ok=1
        (( iface_after >= iface_before && peer_wire_after >= peer_wire_before )) || wire_counter_ok=0
        peer_wire_delta=$((peer_wire_after >= peer_wire_before ? peer_wire_after - peer_wire_before : 0))
        # Keep the aggregate counter bounded by the measured budget.  Once a
        # peer alone exceeds it, retain the sentinel budget+1 instead of
        # allowing an untrusted interface counter to overflow shell arithmetic.
        if (( peer_wire_delta > total_budget_bytes || total_wire > total_budget_bytes - peer_wire_delta )); then
            total_wire=$((total_budget_bytes + 1))
        else
            total_wire=$((total_wire + peer_wire_delta))
        fi
        active_unexplained_pct=$(awk -v wire="$iface_delta" -v test="$actual_bytes" \
            'BEGIN {if(test<=0){print 999;exit} v=(wire/test)*100-110;if(v<0)v=0;printf "%.3f\n",v}')
        test_average_bps=$(awk -v bytes="$actual_bytes" -v seconds="$((duration * test_count))" \
            'BEGIN{if(bytes<=0){print 0;exit}printf "%.3f\n",bytes*8/seconds}')
        idle_background_pct=$(awk -v background="$idle_background_bps" -v test="$test_average_bps" \
            'BEGIN{if(test<=0){print 999;exit}printf "%.3f\n",(background/test)*100}')
        background_pct=$(float_max "$active_unexplained_pct" "$idle_background_pct")
        loaded_p95=$(ping_samples_from_file "$peer_dir/ping.loaded" | percentile 95 2>/dev/null || printf '0')
        if ! float_cmp "$loaded_p95" gt 0 2>/dev/null && float_cmp "$tcp_loaded_max" gt 0 2>/dev/null; then loaded_p95=$tcp_loaded_max; fi
        loaded_delta=$(awk -v loaded="$loaded_p95" -v idle="$idle_p95" 'BEGIN{d=loaded-idle;if(d<0)d=0;printf "%.3f\n",d}')
        four_ok=0; (( success_count == 4 )) && four_ok=1
        if (( four_ok == 0 || tcp_retrans_known == 0 )); then
            overall_retrans_known=0
            overall_conf=low
        fi
        udp_ok=1
        if [[ "$profile" == mixed ]]; then
            udp_ok=0
            (( udp_test_count > 0 && udp_success_count == udp_test_count && udp_metrics_complete == 1 )) && udp_ok=1
        fi
        resolution_stable=1
        resolved_after=$(resolve_peer_host "$host" "$fam" 2>/dev/null || printf unavailable)
        [[ "$resolved_after" == "$ip_addr" ]] || { resolution_stable=0; route_stable=0; }
        budget_ok=$wire_counter_ok
        if ! awk -v used="$peer_wire_delta" -v budget="$peer_budget" -v mib="$MIB" \
            'BEGIN{exit !(used*100 <= budget*mib*102)}'; then budget_ok=0; fi
        if (( single_up_bps > 0 && single_down_bps > 0 )); then
            single_bps=$((single_up_bps < single_down_bps ? single_up_bps : single_down_bps))
        else
            single_bps=$((single_up_bps > single_down_bps ? single_up_bps : single_down_bps))
        fi
        effective_mbps=$(awk -v bps="$single_bps" 'BEGIN{printf "%.3f\n",bps/1000000}')
        retrans_pct=""
        if (( tcp_retrans_known )); then
            retrans_pct=$(awk -v r="$tcp_retrans_segments" -v bytes="$tcp_actual_bytes" 'BEGIN{segments=bytes/1448;if(segments<1)segments=1;printf "%.6f\n",(r/segments)*100}')
        fi
        peer_conf=$(confidence_from_metrics "$four_ok" "$route_stable" "$max_cv" "$background_pct" "$steal" "$has_rtt")
        (( busy == 0 && budget_ok == 1 && rate_limited == 0 )) || peer_conf=low
        if (( tcp_retrans_known == 0 )); then
            peer_quality=unknown
            peer_conf=low
        elif (( peer_loss_known == 1 )); then
            peer_quality=$(classify_quality "$peer_loss" "$loaded_delta" "$retrans_pct")
        elif (( loss_known == 1 )); then
            peer_quality=$(classify_quality "$idle_loss" "$loaded_delta" "$retrans_pct")
        else
            peer_quality=unknown
        fi
        [[ "$peer_conf" == high && "$udp_ok" == 1 ]] || peer_conf=low
        [[ "$peer_conf" == high ]] || overall_conf=low
        if [[ "$profile" == mixed && "$udp_metrics_complete" != 1 ]]; then
            overall_udp_metrics_complete=0
        fi
        overall_loss=$(float_max "$overall_loss" "$idle_loss")
        (( loss_known == 1 )) || overall_loss_known=0
        if (( peer_loss_known == 1 )); then
            overall_udp_loss_known=1
            overall_udp_loss=$(float_max "$overall_udp_loss" "$peer_loss")
        fi
        if (( peer_jitter_known == 1 )); then
            overall_udp_jitter_known=1
            overall_udp_jitter=$(float_max "$overall_udp_jitter" "$peer_jitter")
        fi
        total_udp_success=$((total_udp_success + udp_success_count))
        total_udp_tests=$((total_udp_tests + udp_test_count))
        overall_loaded=$(float_max "$overall_loaded" "$loaded_delta")
        if (( tcp_retrans_known )); then
            overall_retrans=$(float_max "$overall_retrans" "$retrans_pct")
        fi
        overall_cv=$(float_max "$overall_cv" "$max_cv")
        overall_bg=$(float_max "$overall_bg" "$background_pct")
        overall_busy=$(float_max "$overall_busy" "$cpu_busy")
        overall_steal=$(float_max "$overall_steal" "$steal")
        total_actual=$((total_actual + actual_bytes))
        if is_nonnegative_number "$effective_mbps" && is_nonnegative_number "$idle_p95"; then
            local_score=$(awk -v m="$effective_mbps" -v r="$idle_p95" 'BEGIN{printf "%.3f\n",m*r}')
            if float_cmp "$local_score" gt "$selected_score"; then
                selected_score=$local_score; selected_mbps=$effective_mbps; selected_rtt=$idle_p95
                selected_index=$idx; selected_loaded=$loaded_delta; selected_retrans=$retrans_pct; selected_retrans_known=$tcp_retrans_known
                selected_jitter=$idle_jitter; selected_jitter_known=$jitter_known
            fi
        fi
        route_details "$fam" "$ip_addr" "$source" > "$peer_dir/route.after" 2>/dev/null || true
        loss_json=$idle_loss; (( loss_known == 1 )) || loss_json=null
        jitter_json=$idle_jitter; (( jitter_known == 1 )) || jitter_json=null
        udp_loss_json=$peer_loss; (( peer_loss_known == 1 )) || udp_loss_json=null
        udp_jitter_json=$peer_jitter; (( peer_jitter_known == 1 )) || udp_jitter_json=null
        retrans_json=$retrans_pct; (( tcp_retrans_known == 1 )) || retrans_json=null
        if ! jq -n --arg requested "$spec" --arg host "$host" --argjson port "$port" --argjson family "$fam" \
            --arg address "$ip_addr" --arg source "$source" --arg interface "$iface" --arg route_fingerprint "$frozen_fp" \
            --arg confidence "$peer_conf" --arg quality "$peer_quality" --argjson route_stable "$route_stable" --argjson route_unambiguous "$route_unambiguous" --argjson resolution_stable "$resolution_stable" \
            --argjson busy "$busy" --argjson budget_ok "$budget_ok" --argjson rate_limited "$rate_limited" --argjson rtt_p50 "$idle_p50" \
            --argjson rtt_p95 "$idle_p95" --argjson loss "$loss_json" --argjson jitter "$jitter_json" --argjson loaded_p95 "$loaded_p95" \
            --argjson loaded_delta "$loaded_delta" --argjson mbps "$effective_mbps" --argjson retrans "$retrans_json" \
            --argjson retrans_known "$tcp_retrans_known" \
            --argjson cv "$max_cv" --argjson bg "$background_pct" --argjson idle_bg "$idle_background_pct" --argjson active_bg "$active_unexplained_pct" --argjson cpu_busy "$cpu_busy" --argjson steal "$steal" \
            --arg profile "$profile" --argjson udp_loss "$udp_loss_json" --argjson udp_jitter "$udp_jitter_json" \
            --argjson udp_loss_known "$peer_loss_known" --argjson udp_jitter_known "$peer_jitter_known" \
            --argjson udp_metrics_complete "$udp_metrics_complete" \
            --argjson udp_tests_ok "$udp_success_count" --argjson udp_tests_total "$udp_test_count" \
            --argjson duration "$duration" --argjson requested_rate "$rate" \
            --slurpfile tests "$peer_dir/tests.json" \
            '{requested:$requested,profile:$profile,host:$host,port:$port,family:$family,address:$address,source_address:$source,interface:$interface,route_fingerprint:$route_fingerprint,route_unambiguous:($route_unambiguous==1),route_stable:($route_stable==1),resolution_stable:($resolution_stable==1),endpoint_busy:($busy==1),budget_ok:($budget_ok==1),rate_limited:($rate_limited==1),metrics:{rtt_p50_ms:$rtt_p50,rtt_p95_ms:$rtt_p95,loss_pct:$loss,jitter_ms:$jitter,udp_loss_pct:(if $udp_loss_known==1 then $udp_loss else null end),udp_jitter_ms:(if $udp_jitter_known==1 then $udp_jitter else null end),udp_metrics_complete:($udp_metrics_complete==1),udp_tests_ok:$udp_tests_ok,udp_tests_total:$udp_tests_total,loaded_rtt_p95_ms:$loaded_p95,loaded_delta_ms:$loaded_delta,effective_single_mbps:$mbps,retransmits_known:($retrans_known==1),retrans_pct:$retrans,cv_pct:$cv,background_pct:$bg,idle_background_pct:$idle_bg,active_unexplained_pct:$active_bg,cpu_busy_pct:$cpu_busy,cpu_steal_pct:$steal,test_duration_seconds:$duration,requested_rate_mbps:$requested_rate},quality:$quality,confidence:$confidence,tests:$tests[0]}' \
            > "$peer_dir/peer.json" ||
           ! jq --slurpfile peer "$peer_dir/peer.json" '. + [$peer[0]]' "$peers_json" > "$peers_json.tmp" ||
           ! mv -T -- "$peers_json.tmp" "$peers_json"; then
            die '无法生成 peer JSON 报告。'; return 1
        fi
    done < "$frozen_inputs"

    if (( pressure_pid > 0 )); then wait "$pressure_pid" || return 1; MEASURE_PRESSURE_PID=0; MEASURE_PRESSURE_STARTTIME=""; fi
    if ! awk -v used="$total_wire" -v budget="$total_budget_bytes" \
        'BEGIN{exit !(used*100 <= budget*102)}'; then overall_conf=low; fi
    float_cmp "$selected_mbps" gt 0 || overall_conf=low
    if verification_profile=$(verification_budget_profile "$total_budget_bytes" "$total_wire" "$selected_mbps" "$selected_rtt" "$verification_tests" 2>/dev/null); then
        IFS=$'\t' read -r verification_bytes verification_mib verification_duration verification_capacity verification_target <<< "$verification_profile"
    else
        overall_conf=low
    fi
    quality_loss=$overall_loss
    if [[ "$profile" == mixed && "$overall_udp_loss_known" == 1 ]]; then
        quality_loss=$(float_max "$quality_loss" "$overall_udp_loss")
    fi
    if (( overall_retrans_known == 1 &&
          (overall_loss_known == 1 ||
           (overall_udp_loss_known == 1 && overall_udp_metrics_complete == 1))
       )); then
        overall_quality=$(classify_quality "$quality_loss" "$overall_loaded" "$overall_retrans")
    else
        overall_quality=unknown
    fi
    : > "$metrics" || return 1
    metric_put "$metrics" RUN_ID "$run_id" || return 1
    metric_put "$metrics" CREATED_AT "$(date -u +%FT%TZ)" || return 1
    metric_put "$metrics" OS "$(os_pretty_name)" || return 1
    metric_put "$metrics" KERNEL "$(uname -r)" || return 1
    metric_put "$metrics" ARCH "$(uname -m)" || return 1
    metric_put "$metrics" PROFILE "$profile" || return 1
    metric_put "$metrics" BOOT_ID "$(boot_id 2>/dev/null || printf unknown)" || return 1
    metric_put "$metrics" NETNS_INODE "$(netns_inode 2>/dev/null || printf unknown)" || return 1
    metric_put "$metrics" OS_ID "$(os_release_value ID 2>/dev/null || printf unknown)" || return 1
    metric_put "$metrics" OS_VERSION "$(os_release_value VERSION_ID 2>/dev/null || printf unknown)" || return 1
    metric_put "$metrics" MONOTONIC_SECONDS "$(monotonic_seconds 2>/dev/null || printf 0)" || return 1
    metric_put "$metrics" FAMILY "$family" || return 1
    metric_put "$metrics" PEER_COUNT "$peer_count" || return 1
    metric_put "$metrics" BUDGET_MIB "$budget_mib" || return 1
    metric_put "$metrics" BUDGET_BYTES "$total_budget_bytes" || return 1
    metric_put "$metrics" ACTUAL_BYTES "$total_actual" || return 1
    metric_put "$metrics" WIRE_BYTES "$total_wire" || return 1
    metric_put "$metrics" EFFECTIVE_MBPS "$selected_mbps" || return 1
    metric_put "$metrics" RTT_P95_MS "$selected_rtt" || return 1
    metric_put "$metrics" SELECTED_PEER_INDEX "$selected_index" || return 1
    metric_put "$metrics" VERIFY_BASELINE_MBPS "$selected_mbps" || return 1
    metric_put "$metrics" VERIFY_BASELINE_LOADED_DELTA_MS "$selected_loaded" || return 1
    if (( selected_retrans_known == 1 )); then
        metric_put "$metrics" VERIFY_BASELINE_RETRANS_PCT "$selected_retrans" || return 1
    else
        metric_put "$metrics" VERIFY_BASELINE_RETRANS_PCT NA || return 1
    fi
    metric_put "$metrics" VERIFY_CAPACITY_MBPS "$verification_capacity" || return 1
    metric_put "$metrics" VERIFY_DURATION_SECONDS "$verification_duration" || return 1
    metric_put "$metrics" VERIFY_RESERVED_BYTES "$verification_bytes" || return 1
    metric_put "$metrics" VERIFY_RESERVED_MIB "$verification_mib" || return 1
    metric_put "$metrics" VERIFY_TARGET_MBPS "$verification_target" || return 1
    metric_put "$metrics" JITTER_MS "$selected_jitter" || return 1
    metric_put "$metrics" JITTER_KNOWN "$selected_jitter_known" || return 1
    metric_put "$metrics" LOSS_KNOWN "$overall_loss_known" || return 1
    metric_put "$metrics" LOSS_PCT "$overall_loss" || return 1
    metric_put "$metrics" LOADED_DELTA_MS "$overall_loaded" || return 1
    if (( overall_retrans_known == 1 )); then
        metric_put "$metrics" RETRANS_PCT "$overall_retrans" || return 1
    else
        metric_put "$metrics" RETRANS_PCT NA || return 1
    fi
    metric_put "$metrics" RETRANS_KNOWN "$overall_retrans_known" || return 1
    metric_put "$metrics" MAX_CV_PCT "$overall_cv" || return 1
    metric_put "$metrics" BACKGROUND_PCT "$overall_bg" || return 1
    metric_put "$metrics" CPU_BUSY_PCT "$overall_busy" || return 1
    metric_put "$metrics" CPU_STEAL_PCT "$overall_steal" || return 1
    metric_put "$metrics" UDP_LOSS_PCT "$overall_udp_loss" || return 1
    metric_put "$metrics" UDP_LOSS_KNOWN "$overall_udp_loss_known" || return 1
    metric_put "$metrics" UDP_JITTER_MS "$overall_udp_jitter" || return 1
    metric_put "$metrics" UDP_JITTER_KNOWN "$overall_udp_jitter_known" || return 1
    metric_put "$metrics" UDP_METRICS_COMPLETE "$overall_udp_metrics_complete" || return 1
    metric_put "$metrics" UDP_TESTS_OK "$total_udp_success" || return 1
    metric_put "$metrics" UDP_TESTS_TOTAL "$total_udp_tests" || return 1
    metric_put "$metrics" CONFIDENCE "$overall_conf" || return 1
    metric_put "$metrics" QUALITY "$overall_quality" || return 1
    metric_put "$metrics" LISTEN_PRESSURE_WINDOWS "$(pressure_window_count "$pressure_file" 1)" || return 1
    metric_put "$metrics" SOFTNET_DROP_WINDOWS "$(pressure_consecutive_count "$pressure_file" 2)" || return 1
    metric_put "$metrics" SYN_QUEUE_WINDOWS "$(pressure_window_count "$pressure_file" 3)" || return 1
    metric_put "$metrics" LISTEN_OVERFLOW_DELTA "$(pressure_delta_sum "$pressure_file" 4)" || return 1
    metric_put "$metrics" LISTEN_DROP_DELTA "$(pressure_delta_sum "$pressure_file" 5)" || return 1
    metric_put "$metrics" SOFTNET_PROCESSED_DELTA "$(pressure_delta_sum "$pressure_file" 6)" || return 1
    metric_put "$metrics" SOFTNET_DROPPED_DELTA "$(pressure_delta_sum "$pressure_file" 7)" || return 1
    metric_put "$metrics" SOFTNET_SQUEEZE_DELTA "$(pressure_delta_sum "$pressure_file" 8)" || return 1
    metric_put "$metrics" SYN_QUEUE_COOKIES_DELTA "$(pressure_delta_sum "$pressure_file" 9)" || return 1
    metric_put "$metrics" SYN_QUEUE_DROP_DELTA "$(pressure_delta_sum "$pressure_file" 10)" || return 1
    metric_put "$metrics" SYNCOOKIES_DELTA "$(pressure_delta_sum "$pressure_file" 11)" || return 1
    metric_put "$metrics" RAM_BYTES "$(memory_total_bytes)" || return 1
    metric_put "$metrics" MEM_AVAILABLE_BYTES "$(memory_available_bytes)" || return 1
    write_measure_report_json "$run_dir" "$metrics" "$peers_json" || return 1
    printf 'measured\n' > "$run_dir/status" || return 1
    chmod 0600 "$run_dir/status" || return 1
    create_hash_manifest "$run_dir" "$run_dir/measurement.sha256" || return 1
    chmod -R go-rwx "$run_dir" || return 1
    measure_cleanup
    MEASURE_RUN_DIR=""
    trap - EXIT INT TERM HUP
    if (( JSON_OUTPUT )); then
        cat "$run_dir/report.json"
    else
        printf '测量完成: run_id=%s\n' "$run_id"
        printf '质量=%s，置信度=%s，单流有效吞吐=%s Mbps，RTT p95=%s ms\n' \
            "$overall_quality" "$overall_conf" "$selected_mbps" "$selected_rtt"
        printf '实际 iperf3 数据=%s MiB / 预算=%s MiB；报告=%s\n' \
            "$((total_actual / MIB))" "$budget_mib" "$run_dir/report.json"
        if (( overall_retrans_known )); then
            printf 'TCP 重传估算=%s%%（sender 方向已证明）\n' "$overall_retrans"
        else
            printf 'TCP 重传估算=unknown（sender 方向或计数器无法证明）\n'
        fi
        [[ "$overall_conf" == high ]] || warn '置信度不足：计划仍可生成，但 apply/auto 不会修改系统。'
    fi
}

run_directory() {
    local run_id="$1" directory
    validate_run_id "$run_id" || return 1
    directory="$STATE_DIR/runs/$run_id"
    [[ -d "$directory" && ! -L "$directory" ]] || return 1
    secure_private_path "$directory" || return 1
    printf '%s\n' "$directory"
}

module_available_no_load() {
    local module="$1"
    [[ "$module" =~ ^[a-z0-9_]+$ ]] || return 1
    [[ -d "${SYS_ROOT}/module/$module" ]] && return 0
    command_exists modprobe && modprobe -n -q "$module" >/dev/null 2>&1
}

bbr_is_available() {
    local available
    available=$(sysctl_read net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    [[ " $available " == *' bbr '* ]] || module_available_no_load tcp_bbr
}

fq_is_available() {
    local available
    available=$(sysctl_read net.core.default_qdisc 2>/dev/null || true)
    [[ "$available" == fq ]] || module_available_no_load sch_fq
}

next_queue_tier() {
    local current="$1"
    is_uint "$current" || return 1
    if float_cmp "$current" lt 4096; then printf '4096\n'
    elif float_cmp "$current" lt 8192; then printf '8192\n'
    elif float_cmp "$current" lt 16384; then printf '16384\n'
    else printf '%s\n' "$current"
    fi
}

next_netdev_backlog_tier() {
    local current="$1" next
    is_uint "$current" || return 1
    if [[ "$current" == 0 ]]; then
        next=4096
    elif float_cmp "$current" ge 5000; then
        next=10000
    else
        next=$((current * 2))
    fi
    # Never lower an administrator value, even if it is already above the
    # bounded tuning ceiling.
    if float_cmp "$next" lt "$current"; then next=$current; fi
    printf '%s\n' "$next"
}

append_plan_value() {
    local file="$1" key="$2" value="$3" before="$4" reason="$5"
    is_target_sysctl_key "$key" || return 1
    record_field_is_safe "$value" && [[ "$value" =~ ^[A-Za-z0-9_.[:space:]-]+$ ]] || return 1
    record_field_is_safe "$before" && record_field_is_safe "$reason" || return 1
    [[ "$value" == "$before" ]] && return 0
    printf '%s\t%s\t%s\t%s\truntime_change\n' "$key" "$value" "$before" "$reason" >> "$file"
}

append_plan_value_forced() {
    local file="$1" key="$2" value="$3" before="$4" reason="$5"
    is_target_sysctl_key "$key" || return 1
    record_field_is_safe "$value" && [[ "$value" =~ ^[A-Za-z0-9_.[:space:]-]+$ ]] || return 1
    record_field_is_safe "$before" && record_field_is_safe "$reason" || return 1
    if [[ "$value" == "$before" ]]; then
        printf '%s\t%s\t%s\t%s\tpersist_only\n' "$key" "$value" "$before" "$reason" >> "$file"
    else
        printf '%s\t%s\t%s\t%s\truntime_change\n' "$key" "$value" "$before" "$reason" >> "$file"
    fi
}

# A recommendation can be useful even when the live value already matches the
# target: the value may only come from a vendor/runtime file and disappear on
# reboot. Keep that persistence repair visible instead of silently dropping it
# from the plan. The apply path treats persist_only entries as a no-op for
# runtime sysctl and still journals/restores the dedicated file.
append_plan_persisted_value() {
    append_plan_value_forced "$@"
}

plan_change_type() {
    case "${1:-}" in
        runtime_change|persist_only) printf '%s\n' "$1" ;;
        "") printf 'runtime_change\n' ;;
        *) return 1 ;;
    esac
}

plan_contains_key() { awk -F'\t' -v key="$2" '$1==key{found=1} END{exit !found}' "$1"; }

plan_entry_enabled() {
    local key="${1:-}"
    if (( PACING_PLAN_ENABLED == 0 )) && [[ "$key" == net.core.default_qdisc ]]; then
        return 1
    fi
    return 0
}

PLAN_PREVIEW_DIR=""

plan_preview_exit_cleanup() {
    local saved_status=$?
    trap - EXIT INT TERM HUP
    if [[ -n "$PLAN_PREVIEW_DIR" ]]; then
        case "$PLAN_PREVIEW_DIR" in
            /tmp/vps-proxy-tune-plan.*) rm -rf -- "$PLAN_PREVIEW_DIR" ;;
        esac
    fi
    PLAN_PREVIEW_DIR=""
    return "$saved_status"
}

find_plan_conflicts() {
    local plan_file="$1" scope key file value basename owned_basename definitions
    owned_basename=$(basename "$SYSCTL_FILE")
    definitions=$(LC_ALL=C scan_sysctl_definitions) || return 1
    [[ -n "$definitions" ]] || return 0
    while IFS=$'\t' read -r scope key file value; do
        plan_contains_key "$plan_file" "$key" || continue
        basename=$(basename "$file")
        if [[ "$scope" == local || "$scope" == runtime || "$basename" > "$owned_basename" ]]; then
            printf '%s\t%s\t%s\n' "$key" "$file" "$value"
        fi
    done <<< "$definitions"
}

managed_file_has_marker() {
    local file="$1" marker versioned
    [[ -f "$file" && ! -L "$file" ]] || return 1
    marker=$(head -n 1 "$file" 2>/dev/null || true)
    [[ "$marker" == "# Managed by $OWNER_ID. Do not edit; use rollback/uninstall." ]] && return 0
    # The unversioned marker is the known v1 format.  A versioned marker is
    # accepted only for the known v1 writer family; future/unknown majors must
    # not become an implicit ownership or migration grant.
    versioned="^# Managed by ${OWNER_ID} v1[.][0-9]+[.][0-9]+[.] Do not edit; use rollback/uninstall[.]$"
    [[ "$marker" =~ $versioned ]]
}

managed_file_has_current_metadata() {
    local file="$1" format writer writer_version source_line source_run line format_count=0 writer_count=0
    managed_file_has_marker "$file" || return 1
    [[ "$(head -n 1 "$file" 2>/dev/null || true)" == "# Managed by $OWNER_ID. Do not edit; use rollback/uninstall." ]] || return 1
    format=$(sed -n '2p' "$file" 2>/dev/null || true)
    writer=$(sed -n '3p' "$file" 2>/dev/null || true)
    [[ "$format" == "# Format-Version: $STATE_FORMAT_VERSION" ]] || return 1
    [[ "$writer" =~ ^#\ Writer-Version:\ ([0-9]+[.][0-9]+[.][0-9]+)$ ]] || return 1
    writer_version=${BASH_REMATCH[1]}
    # Format v2 is intentionally forward-readable only within the v2 writer
    # family.  A future major writer may change ownership semantics and must
    # go through an explicit migration instead of silently taking over files.
    [[ "$writer_version" =~ ^2[.][0-9]+[.][0-9]+$ ]] || return 1
    source_line=$(sed -n '4p' "$file" 2>/dev/null || true)
    case "$source_line" in
        '') ;;
        '# Source run: '*)
            source_run=${source_line#'# Source run: '}
            validate_run_id "$source_run" || return 1
            ;;
        *) return 1 ;;
    esac
    # Version headers are part of the ownership boundary.  Reject duplicate or
    # hidden headers anywhere in the file instead of treating a payload with an
    # unknown later header as a valid v2 file.
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            '# Format-Version:'*) format_count=$((format_count + 1)) ;;
            '# Writer-Version:'*) writer_count=$((writer_count + 1)) ;;
        esac
    done < "$file"
    [[ "$format_count" == 1 && "$writer_count" == 1 ]]
}

managed_file_is_known_owned() {
    local file="$1" line metadata=0
    managed_file_has_marker "$file" || return 1
    # A legacy v1 file has only the stable ownership marker.  If any versioned
    # metadata is present anywhere in the file, require the complete current
    # metadata block; this prevents an unknown format or writer version from
    # being treated as an implicit migration permission.
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            '# Format-Version:'*|'# Writer-Version:'*) metadata=1; break ;;
        esac
    done < "$file"
    if (( metadata )); then
        managed_file_has_current_metadata "$file"
    else
        return 0
    fi
}

write_private_hash_record() {
    local path="$1" output="$2" hash inode mode temp
    [[ -f "$path" && ! -L "$path" ]] || return 1
    hash=$(sha256sum "$path" 2>/dev/null | awk '{print $1}') || return 1
    inode=$(stat -c %i "$path" 2>/dev/null || true)
    mode=$(stat -c %a "$path" 2>/dev/null || true)
    [[ "$hash" =~ ^[0-9a-f]{64}$ && "$inode" =~ ^[0-9]+$ && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    [[ "$output" == "$STATE_DIR/"* ]] || return 1
    temp=$(mktemp "$STATE_DIR/.hash.XXXXXXXX") || return 1
    if printf '%s\t%s\t%s\n' "$hash" "$inode" "$mode" > "$temp" && chmod 0600 "$temp" &&
       atomic_install "$temp" "$output" 0600; then
        if rm -f -- "$temp" && [[ ! -e "$temp" && ! -L "$temp" ]]; then
            return 0
        fi
        return 1
    fi
    rm -f -- "$temp"
    return 1
}

verify_private_hash_record() {
    local path="$1" record="$2" expected expected_inode expected_mode extra actual inode mode
    [[ -f "$path" && ! -L "$path" && -f "$record" && ! -L "$record" ]] || return 1
    secure_owned_file "$path" || return 1
    secure_private_path "$record" || return 1
    IFS=$'\t' read -r expected expected_inode expected_mode extra < "$record" || return 1
    [[ -z "${extra:-}" && "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
    actual=$(sha256sum "$path" 2>/dev/null | awk '{print $1}') || return 1
    [[ "$actual" == "$expected" ]] || return 1
    # A one-field record is a legacy v1/v2 hash marker.  It remains readable
    # for controlled migration, while every record written by this version
    # also binds inode and mode so a replacement/chmod drift is visible.
    if [[ -n "$expected_inode" || -n "$expected_mode" ]]; then
        [[ "$expected_inode" =~ ^[0-9]+$ && "$expected_mode" =~ ^[0-7]{3,4}$ ]] || return 1
        inode=$(stat -c %i "$path" 2>/dev/null || true)
        mode=$(stat -c %a "$path" 2>/dev/null || true)
        [[ "$inode" == "$expected_inode" && "$mode" == "$expected_mode" ]]
    fi
}

owned_path_identity() {
    local path="$1" hash
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        printf 'absent\n'; return 0
    fi
    [[ -f "$path" && ! -L "$path" ]] || return 1
    hash=$(sha256sum "$path" | awk '{print $1}') || return 1
    [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf 'file:%s\n' "$hash"
}

owned_sysctl_values() {
    local file="$1" line key value normalized_key
    local -A seen=()
    managed_file_has_marker "$file" || return 0
    if ! while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%%#*}; line=$(trim "$line")
        [[ -n "$line" ]] || continue
        [[ "$line" != *';'* ]] || return 1
        if [[ "$line" == *=* ]]; then
            key=$(trim "${line%%=*}")
            value=$(trim "${line#*=}")
        else
            key=${line%%[[:space:]]*}
            value=$(trim "${line#"$key"}")
            [[ -n "$value" ]] || return 1
        fi
        [[ -n "$key" && -n "$value" && "$key" =~ ^-?[A-Za-z0-9_./]+$ &&
           "$value" != *$'\t'* && "$value" != *$'\r'* ]] || return 1
        normalized_key=${key#-}; normalized_key=${normalized_key//\//.}; normalized_key=${normalized_key#.}
        is_target_sysctl_key "$normalized_key" || continue
        [[ "$value" =~ ^[A-Za-z0-9_.[:space:]-]+$ ]] || return 1
        [[ -z "${seen[$normalized_key]+x}" ]] || return 1
        seen[$normalized_key]=1
        printf '%s\t%s\n' "$normalized_key" "$value" || return 1
    done < "$file"; then
        return 1
    fi
}

owned_sysctl_extra_lines() {
    local file="$1" line normalized key value normalized_key
    local -A seen=()
    managed_file_has_marker "$file" || return 0
    # Older releases may have placed additional sysctl keys in the same
    # tool-owned file.  Keep those settings instead of silently deleting them
    # during a v2 rewrite.  They are never used for a new recommendation; the
    # parser only proves that each retained assignment is unambiguous and
    # cannot inject a second line break or tab into the generated file.
    if ! while IFS= read -r line || [[ -n "$line" ]]; do
        normalized=${line%%#*}; normalized=$(trim "$normalized")
        [[ -n "$normalized" ]] || continue
        [[ "$normalized" != *';'* ]] || return 1
        if [[ "$normalized" == *=* ]]; then
            key=$(trim "${normalized%%=*}")
            value=$(trim "${normalized#*=}")
        else
            key=${normalized%%[[:space:]]*}
            value=$(trim "${normalized#"$key"}")
        fi
        [[ -n "$key" && -n "$value" && "$key" =~ ^-?[A-Za-z0-9_./]+$ ]] || return 1
        [[ "$value" != *'='* && "$value" != *$'\t'* && "$value" != *$'\r'* ]] || return 1
        [[ "$value" =~ ^[A-Za-z0-9_.[:space:]-]+$ ]] || return 1
        normalized_key=${key#-}; normalized_key=${normalized_key//\//.}; normalized_key=${normalized_key#.}
        is_target_sysctl_key "$normalized_key" && continue
        [[ -z "${seen[$normalized_key]+x}" ]] || return 1
        seen[$normalized_key]=1
        printf '%s = %s\n' "$key" "$value" || return 1
    done < "$file"; then
        return 1
    fi
}

build_persisted_sysctl() {
    local run_id="$1" plan_file="$2" output="$3" key value before reason change_type retained extra temp
    local -A changed=()
    while IFS=$'\t' read -r key value before reason change_type; do
        is_target_sysctl_key "$key" || return 1
        plan_entry_enabled "$key" || continue
        changed[$key]=1
    done < "$plan_file"
    retained=$(mktemp "${output}.retained.XXXXXXXX") || return 1
    extra=$(mktemp "${output}.extra.XXXXXXXX") || { rm -f -- "$retained"; return 1; }
    temp=$(mktemp "${output}.tmp.XXXXXXXX") || { rm -f -- "$retained" "$extra"; return 1; }
    if [[ -f "$SYSCTL_FILE" ]]; then
        if ! managed_file_is_known_owned "$SYSCTL_FILE" ||
           ! owned_sysctl_values "$SYSCTL_FILE" > "$retained" ||
           ! owned_sysctl_extra_lines "$SYSCTL_FILE" > "$extra"; then
            rm -f -- "$retained" "$extra" "$temp"; return 1
        fi
    else
        : > "$retained" || { rm -f -- "$retained" "$extra" "$temp"; return 1; }
        : > "$extra" || { rm -f -- "$retained" "$extra" "$temp"; return 1; }
    fi
    if ! {
        managed_marker
        managed_metadata "$run_id"
        cat "$extra"
        while IFS=$'\t' read -r key value; do
            # Retain every value already owned by this tool.  In particular,
            # safe-mode pacing may disable a proposed default_qdisc entry; a
            # disabled proposal must not delete an older owned value from the
            # persisted file.
            [[ -n "${changed[$key]+x}" ]] || printf '%s = %s\n' "$key" "$value"
        done < "$retained"
        while IFS=$'\t' read -r key value before reason change_type; do
            plan_entry_enabled "$key" || continue
            printf '%s = %s\n' "$key" "$value"
        done < "$plan_file"
    } > "$temp"; then
        rm -f -- "$retained" "$extra" "$temp"; return 1
    fi
    if ! chmod 0600 "$temp" || ! atomic_install "$temp" "$output" 0600 ||
       ! rm -f -- "$retained" "$extra"; then
        rm -f -- "$retained" "$extra" "$temp"; return 1
    fi
    rm -f -- "$temp"
}

write_plan_json() {
    local run_dir plan_file warnings_file recommendations changes warnings metrics peers output
    run_dir=$1; plan_file=$2; warnings_file=$3; output="${4:-$run_dir/plan.json}"
    metrics="$run_dir/metrics.tsv"; peers="$run_dir/peers.json"
    local run confidence quality created os kernel arch
    run=$(metric_get "$metrics" RUN_ID) || return 1
    confidence=$(metric_get "$metrics" CONFIDENCE) || return 1
    quality=$(metric_get "$metrics" QUALITY) || return 1
    created=$(metric_get "$metrics" CREATED_AT) || return 1
    os=$(metric_get "$metrics" OS) || return 1
    kernel=$(metric_get "$metrics" KERNEL) || return 1
    arch=$(metric_get "$metrics" ARCH) || return 1
    recommendations=$(jq -Rn '[inputs | split("\t") | select(length>=2) | {(.[0]):.[1]}] | add // {}' < "$plan_file") || return 1
    changes=$(jq -Rn '[inputs | split("\t") | select(length>=4) |
        {key:.[0],target:.[1],before:.[2],reason:.[3],
         change_type:(if length>=5 and .[4]!="" then .[4] else "runtime_change" end)}]' < "$plan_file") || return 1
    warnings=$(jq -Rsc 'split("\n") | map(select(length>0))' < "$warnings_file") || return 1
    jq -n --arg schema "$SCHEMA_VERSION" --arg run "$run" --arg created "$created" --arg os "$os" \
        --arg kernel "$kernel" --arg arch "$arch" --arg profile "$(metric_get "$metrics" PROFILE 2>/dev/null || printf tcp)" --arg confidence "$confidence" --arg quality "$quality" \
        --argjson peers "$(<"$peers")" --argjson recommendations "$recommendations" --argjson changes "$changes" --argjson warnings "$warnings" \
        --argjson effective "$(json_number_or_null "$(metric_get "$metrics" EFFECTIVE_MBPS 2>/dev/null || true)")" --argjson rtt "$(json_number_or_null "$(metric_get "$metrics" RTT_P95_MS 2>/dev/null || true)")" \
        --argjson loss "$(json_number_or_null "$(metric_get "$metrics" LOSS_PCT 2>/dev/null || true)")" --argjson loss_known "$(json_number_or_null "$(metric_get "$metrics" LOSS_KNOWN 2>/dev/null || true)")" \
        --argjson jitter "$(json_number_or_null "$(metric_get "$metrics" JITTER_MS 2>/dev/null || true)")" --argjson jitter_known "$(json_number_or_null "$(metric_get "$metrics" JITTER_KNOWN 2>/dev/null || true)")" --argjson loaded "$(json_number_or_null "$(metric_get "$metrics" LOADED_DELTA_MS 2>/dev/null || true)")" \
        --argjson retrans "$(json_number_or_null "$(metric_get "$metrics" RETRANS_PCT 2>/dev/null || true)")" \
        --argjson retrans_known "$(json_number_or_null "$(metric_get "$metrics" RETRANS_KNOWN 2>/dev/null || true)")" \
        --argjson actual "$(json_number_or_null "$(metric_get "$metrics" ACTUAL_BYTES 2>/dev/null || true)")" \
        --argjson wire "$(json_number_or_null "$(metric_get "$metrics" WIRE_BYTES 2>/dev/null || true)")" --argjson budget "$(json_number_or_null "$(metric_get "$metrics" BUDGET_BYTES 2>/dev/null || true)")" \
        --argjson verify_bytes "$(json_number_or_null "$(metric_get "$metrics" VERIFY_RESERVED_BYTES 2>/dev/null || true)")" \
        --argjson verify_duration "$(json_number_or_null "$(metric_get "$metrics" VERIFY_DURATION_SECONDS 2>/dev/null || true)")" \
        --argjson verify_capacity "$(json_number_or_null "$(metric_get "$metrics" VERIFY_CAPACITY_MBPS 2>/dev/null || true)")" \
        --argjson verify_target "$(json_number_or_null "$(metric_get "$metrics" VERIFY_TARGET_MBPS 2>/dev/null || true)")" \
        --argjson listen_overflow_delta "$(json_number_or_null "$(metric_get "$metrics" LISTEN_OVERFLOW_DELTA 2>/dev/null || true)")" \
        --argjson listen_drop_delta "$(json_number_or_null "$(metric_get "$metrics" LISTEN_DROP_DELTA 2>/dev/null || true)")" \
        --argjson softnet_processed_delta "$(json_number_or_null "$(metric_get "$metrics" SOFTNET_PROCESSED_DELTA 2>/dev/null || true)")" \
        --argjson softnet_dropped_delta "$(json_number_or_null "$(metric_get "$metrics" SOFTNET_DROPPED_DELTA 2>/dev/null || true)")" \
        --argjson softnet_squeeze_delta "$(json_number_or_null "$(metric_get "$metrics" SOFTNET_SQUEEZE_DELTA 2>/dev/null || true)")" \
        --argjson listen_windows "$(json_number_or_null "$(metric_get "$metrics" LISTEN_PRESSURE_WINDOWS 2>/dev/null || true)")" \
        --argjson syn_windows "$(json_number_or_null "$(metric_get "$metrics" SYN_QUEUE_WINDOWS 2>/dev/null || true)")" \
        --argjson syn_cookies_delta "$(json_number_or_null "$(metric_get "$metrics" SYN_QUEUE_COOKIES_DELTA 2>/dev/null || true)")" \
        --argjson syn_drop_delta "$(json_number_or_null "$(metric_get "$metrics" SYN_QUEUE_DROP_DELTA 2>/dev/null || true)")" \
        --argjson syncookies_delta "$(json_number_or_null "$(metric_get "$metrics" SYNCOOKIES_DELTA 2>/dev/null || true)")" \
        --argjson udp_loss "$(json_number_or_null "$(metric_get "$metrics" UDP_LOSS_PCT 2>/dev/null || true)")" \
        --argjson udp_loss_known "$(json_number_or_null "$(metric_get "$metrics" UDP_LOSS_KNOWN 2>/dev/null || true)")" \
        --argjson udp_jitter "$(json_number_or_null "$(metric_get "$metrics" UDP_JITTER_MS 2>/dev/null || true)")" \
        --argjson udp_jitter_known "$(json_number_or_null "$(metric_get "$metrics" UDP_JITTER_KNOWN 2>/dev/null || true)")" \
        --argjson udp_metrics_complete "$(json_number_or_null "$(metric_get "$metrics" UDP_METRICS_COMPLETE 2>/dev/null || true)")" \
        --argjson udp_tests_ok "$(json_number_or_null "$(metric_get "$metrics" UDP_TESTS_OK 2>/dev/null || true)")" \
        --argjson udp_tests_total "$(json_number_or_null "$(metric_get "$metrics" UDP_TESTS_TOTAL 2>/dev/null || true)")" \
        --argjson softnet_windows "$(json_number_or_null "$(metric_get "$metrics" SOFTNET_DROP_WINDOWS 2>/dev/null || true)")" \
        '{schema_version:$schema,run_id:$run,outcome:"ok",reason_code:"plan_generated",environment:{created_at:$created,os:$os,kernel:$kernel,arch:$arch,profile:$profile},path:{peers:$peers},metrics:{effective_mbps:$effective,rtt_p95_ms:$rtt,loss_pct:(if $loss_known==1 then $loss else null end),jitter_ms:(if $jitter_known==1 then $jitter else null end),udp_loss_pct:(if $udp_loss_known==1 then $udp_loss else null end),udp_jitter_ms:(if $udp_jitter_known==1 then $udp_jitter else null end),udp_metrics_complete:($udp_metrics_complete==1),udp_tests_ok:$udp_tests_ok,udp_tests_total:$udp_tests_total,loaded_delta_ms:$loaded,retransmits_known:($retrans_known==1),retrans_pct:(if $retrans_known==1 then $retrans else null end),actual_bytes:$actual,wire_bytes:$wire,budget_bytes:$budget,verification_budget:{eligible:($verify_duration>0),reserved_bytes:$verify_bytes,duration_seconds:$verify_duration,capacity_mbps:$verify_capacity,target_mbps:$verify_target},listen_overflow_delta:$listen_overflow_delta,listen_drop_delta:$listen_drop_delta,softnet_processed_delta:$softnet_processed_delta,softnet_dropped_delta:$softnet_dropped_delta,softnet_time_squeeze_delta:$softnet_squeeze_delta,listen_pressure_windows:$listen_windows,syn_queue_windows:$syn_windows,syn_queue_cookies_delta:$syn_cookies_delta,syn_queue_drop_delta:$syn_drop_delta,syncookies_delta:$syncookies_delta,softnet_drop_consecutive_windows:$softnet_windows},quality:$quality,confidence:$confidence,recommendations:$recommendations,recommended_values:$recommendations,changes:$changes,warnings:$warnings,rollback_status:"not-applied"}' > "$output" || return 1
    chmod 0600 "$output" || return 1
}

cmd_plan() {
    local run_id="" arg run_dir metrics plan_file proposed warnings_file conflicts_file preview_dir="" plan_output
    local confidence mbps rtt ram base_target cap mem_available memory_headroom_ok=1 current value first second third target
    local desired key extra
    local listen_windows syn_windows syn_cookies_delta syn_drop_delta syncookies_delta syn_evidence=0
    local softnet_windows available total current_somax current_syn current_backlog next
    local bbr=0 fq=0
    JSON_OUTPUT=0; DRY_RUN=0; INSTALL_DEPS=0; JSON_ERROR_EMITTED=0; PACING_PLAN_ENABLED=1
    while (($#)); do
        arg=$1; shift
        case "$arg" in
            --run) (($#)) || { die '--run 缺少值'; return 1; }; run_id=$1; shift ;;
            --run=*) run_id=${arg#*=} ;;
            --json) JSON_OUTPUT=1 ;;
            --dry-run) DRY_RUN=1 ;;
            --install-deps) INSTALL_DEPS=1 ;;
            *) die "plan 不支持参数: $arg"; return 1 ;;
        esac
    done
    (( DRY_RUN == 0 || INSTALL_DEPS == 0 )) || { die '--dry-run 与 --install-deps 不能同时使用。'; return 1; }
    [[ -n "$run_id" ]] || { die 'plan 需要 --run RUN_ID。'; return 1; }
    require_root || return 1
    if ! command_exists jq || ! command_exists sha256sum; then
        if (( INSTALL_DEPS )); then
            install_dependencies common || return 1
        else
            die 'plan 需要 jq 和 sha256sum；可显式使用 --install-deps 从发行版官方仓库安装。'; return 1
        fi
    fi
    command_exists jq || { die '依赖安装后仍缺少 jq。'; return 1; }
    command_exists sha256sum || { die '依赖安装后仍缺少 sha256sum。'; return 1; }
    require_file_commands || return 1
    # A dry-run must not create the state tree or lock file.  Require an
    # already-initialized, private state directory and read it without taking
    # a writer lock; all preview artifacts live under a private /tmp dir.
    if (( DRY_RUN )); then
        ensure_secure_state || return 1
    else
        ensure_state_dirs || return 1; ensure_secure_state || return 1; acquire_lock || return 1
    fi
    run_dir=$(run_directory "$run_id") || { die '找不到安全的测量 run。'; return 1; }
    verify_hash_manifest "$run_dir" "$run_dir/measurement.sha256" || { die '测量 manifest 校验失败；拒绝规划。'; return 1; }
    if [[ -e "$STATE_DIR/transactions/$run_id" || -L "$STATE_DIR/transactions/$run_id" ]]; then
        die '该 run 已存在事务快照或不安全占位路径；为保持审计链不可变，拒绝重新生成 plan。'; return 1
    fi
    metrics="$run_dir/metrics.tsv"
    if (( DRY_RUN )); then
        trusted_tmp_dir || { die '/tmp 不是可信的 root-owned 目录。'; return 1; }
        preview_dir=$(mktemp -d /tmp/vps-proxy-tune-plan.XXXXXXXX) || return 1
        PLAN_PREVIEW_DIR="$preview_dir"
        trap plan_preview_exit_cleanup EXIT
        trap 'exit 130' INT TERM HUP
        chmod 0700 "$preview_dir" || return 1
        plan_file="$preview_dir/plan.tsv"; proposed="$preview_dir/sysctl.conf.proposed"
        warnings_file="$preview_dir/plan.warnings"; conflicts_file="$preview_dir/conflicts.tsv"; plan_output="$preview_dir/plan.json"
    else
        plan_file="$run_dir/plan.tsv"; proposed="$run_dir/sysctl.conf.proposed"
        warnings_file="$run_dir/plan.warnings"; conflicts_file="$run_dir/conflicts.tsv"; plan_output="$run_dir/plan.json"
    fi
    : > "$plan_file" || return 1
    : > "$warnings_file" || return 1
    : > "$conflicts_file" || return 1
    if ! run_measurement_context_is_current "$run_dir"; then
        printf '测量运行环境已变化或超过 %ss；plan 仍可供审阅，但 apply 将拒绝使用它。\n' "$RUN_TTL_SECONDS" >> "$warnings_file"
    fi
    confidence=$(metric_get "$metrics" CONFIDENCE)
    mbps=$(metric_get "$metrics" EFFECTIVE_MBPS); rtt=$(metric_get "$metrics" RTT_P95_MS)
    ram=$(metric_get "$metrics" RAM_BYTES)
    is_nonnegative_number "$mbps" || { die '测量吞吐值损坏。'; return 1; }
    float_cmp "$mbps" gt 0 || { die '测量吞吐值损坏。'; return 1; }
    is_nonnegative_number "$rtt" || { die '测量 RTT 值损坏。'; return 1; }
    float_cmp "$rtt" gt 0 || { die '测量 RTT 值损坏。'; return 1; }
    is_positive_uint "$ram" || { die '测量内存值损坏。'; return 1; }
    base_target=$(compute_buffer_target "$mbps" "$rtt" "$ram" 0) || return 1
    cap=$(ram_cap_bytes "$ram") || return 1
    mem_available=$(metric_get "$metrics" MEM_AVAILABLE_BYTES 2>/dev/null || printf 0)
    if ! is_uint "$mem_available" || float_cmp "$mem_available" lt "$((256 * MIB))" ||
       ! awk -v available="$mem_available" -v total="$ram" 'BEGIN{exit !(available*100 >= total*20)}'; then
        memory_headroom_ok=0
        printf 'MemAvailable 低于 256 MiB 或总内存的 20%%；跳过自动扩大 socket 缓冲。\n' >> "$warnings_file"
    fi

    current=$(sysctl_read net.ipv4.tcp_rmem 2>/dev/null || true)
    if IFS=' ' read -r first second third extra <<< "$current" && is_uint "$first" && is_uint "$second" && is_uint "$third" && [[ -z "${extra:-}" ]]; then
        if float_cmp "$third" gt "$cap"; then
            printf '现有 tcp_rmem 最大值超过 RAM cap（%s > %s）；保留现值且不据此抬高 core 上限。\n' "$third" "$cap" >> "$warnings_file"
        elif (( memory_headroom_ok == 1 )); then
            if float_cmp "$third" gt "$base_target"; then target=$third; else target=$base_target; fi
            append_plan_persisted_value "$plan_file" net.ipv4.tcp_rmem "$first $second $target" "$current" '2x BDP，受 RAM cap 限制且绝不下调管理员值；运行时已满足时仍补齐持久化'
        fi
    else
        printf 'net.ipv4.tcp_rmem 不可用或不是三元组，已跳过。\n' >> "$warnings_file"
    fi
    current=$(sysctl_read net.ipv4.tcp_wmem 2>/dev/null || true)
    if IFS=' ' read -r first second third extra <<< "$current" && is_uint "$first" && is_uint "$second" && is_uint "$third" && [[ -z "${extra:-}" ]]; then
        if float_cmp "$third" gt "$cap"; then
            printf '现有 tcp_wmem 最大值超过 RAM cap（%s > %s）；保留现值且不据此抬高 core 上限。\n' "$third" "$cap" >> "$warnings_file"
        elif (( memory_headroom_ok == 1 )); then
            if float_cmp "$third" gt "$base_target"; then target=$third; else target=$base_target; fi
            append_plan_persisted_value "$plan_file" net.ipv4.tcp_wmem "$first $second $target" "$current" '2x BDP，受 RAM cap 限制且绝不下调管理员值；运行时已满足时仍补齐持久化'
        fi
    else
        printf 'net.ipv4.tcp_wmem 不可用或不是三元组，已跳过。\n' >> "$warnings_file"
    fi
    for key in net.core.rmem_max net.core.wmem_max; do
        current=$(sysctl_read "$key" 2>/dev/null || true)
        if is_uint "$current"; then
            desired=$base_target; [[ "$key" == net.core.wmem_max ]] && desired=$base_target
            if (( memory_headroom_ok == 1 )); then
                if float_cmp "$current" gt "$desired"; then target=$current; else target=$desired; fi
                append_plan_persisted_value "$plan_file" "$key" "$target" "$current" '不低于 2x BDP，受 RAM cap/可用内存限制且绝不下调管理员值；运行时已满足时仍补齐持久化'
            fi
        else
            printf '%s 不可用，已跳过。\n' "$key" >> "$warnings_file"
        fi
    done
    current=$(sysctl_read net.ipv4.tcp_moderate_rcvbuf 2>/dev/null || true)
    if is_uint "$current"; then
        # Treat any non-zero administrator value as enabled; never lower an
        # unknown/stronger setting merely to normalize it to 1.
        [[ "$current" != 0 ]] || append_plan_persisted_value "$plan_file" net.ipv4.tcp_moderate_rcvbuf 1 "$current" '启用 TCP 接收缓冲自动调节；运行时已满足时仍补齐持久化'
    else
        printf 'net.ipv4.tcp_moderate_rcvbuf 不可用，已跳过。\n' >> "$warnings_file"
    fi
    current=$(sysctl_read net.ipv4.tcp_mtu_probing 2>/dev/null || true)
    if is_uint "$current"; then
        # There is no end-to-end black-hole signal in the current measurement
        # data.  Do not turn this on merely because the key exists: value 1
        # changes TCP's recovery behavior and requires explicit evidence.
        printf 'tcp_mtu_probing 当前为 %s；本轮没有黑洞证据，保持原值且不自动启用。\n' \
            "$current" >> "$warnings_file"
    else
        printf 'net.ipv4.tcp_mtu_probing 不可用，已跳过。\n' >> "$warnings_file"
    fi

    bbr_is_available && bbr=1
    fq_is_available && fq=1
    if (( bbr == 1 && fq == 1 )); then
        current=$(sysctl_read net.core.default_qdisc 2>/dev/null || true)
        if [[ -n "$current" ]]; then append_plan_value_forced "$plan_file" net.core.default_qdisc fq "$current" '标准内核 BBR 首选 fq；只有 live 验证成功或当前已是 fq 才持久化'; fi
        current=$(sysctl_read net.ipv4.tcp_congestion_control 2>/dev/null || true)
        if [[ -n "$current" ]]; then append_plan_value_forced "$plan_file" net.ipv4.tcp_congestion_control bbr "$current" '使用发行版内核已有的标准 BBR；仅对新 socket 生效'; fi
    else
        printf '标准 BBR 或 fq 在当前内核不可证明可用；保留现有拥塞控制和 qdisc。\n' >> "$warnings_file"
    fi

    listen_windows=$(metric_get "$metrics" LISTEN_PRESSURE_WINDOWS 2>/dev/null || printf 0)
    syn_windows=$(metric_get "$metrics" SYN_QUEUE_WINDOWS 2>/dev/null || printf 0)
    if is_uint "$listen_windows" && (( listen_windows >= 2 )); then
        current_somax=$(sysctl_read net.core.somaxconn 2>/dev/null || true)
        if is_uint "$current_somax"; then
            next=$(next_queue_tier "$current_somax")
            append_plan_persisted_value "$plan_file" net.core.somaxconn "$next" "$current_somax" '至少 2/3 窗口出现 ListenOverflow/Drop 且队列达到 80%；运行时已满足时仍补齐持久化'
        fi
    fi
    syn_cookies_delta=$(metric_get "$metrics" SYN_QUEUE_COOKIES_DELTA 2>/dev/null || printf NA)
    syn_drop_delta=$(metric_get "$metrics" SYN_QUEUE_DROP_DELTA 2>/dev/null || printf NA)
    syncookies_delta=$(metric_get "$metrics" SYNCOOKIES_DELTA 2>/dev/null || printf NA)
    for current in "$syn_cookies_delta" "$syn_drop_delta" "$syncookies_delta"; do
        if is_uint "$current" && float_cmp "$current" gt 0; then syn_evidence=1; fi
    done
    if is_uint "$syn_windows" && (( syn_windows >= 2 && syn_evidence == 1 )); then
        current_syn=$(sysctl_read net.ipv4.tcp_max_syn_backlog 2>/dev/null || true)
        if is_uint "$current_syn"; then
            next=$(next_queue_tier "$current_syn")
            append_plan_persisted_value "$plan_file" net.ipv4.tcp_max_syn_backlog "$next" "$current_syn" '至少 2/3 窗口出现 SYN 队列 cookie/drop 事件；运行时已满足时仍补齐持久化'
        fi
    elif is_uint "$syn_windows" && (( syn_windows >= 2 )); then
        printf 'SYN 队列窗口计数存在，但 cookie/drop 计数没有明确正向证据；不修改 tcp_max_syn_backlog。\n' >> "$warnings_file"
    fi
    softnet_windows=$(metric_get "$metrics" SOFTNET_DROP_WINDOWS 2>/dev/null || printf 0)
    available=$(metric_get "$metrics" MEM_AVAILABLE_BYTES 2>/dev/null || printf 0); total=$(metric_get "$metrics" RAM_BYTES 2>/dev/null || printf 0)
    if is_uint "$softnet_windows" && is_uint "$available" && is_uint "$total" &&
       float_cmp "$softnet_windows" ge 2 &&
       awk -v available="$available" -v total="$total" 'BEGIN{exit !(available*100 > total*20)}'; then
        current_backlog=$(sysctl_read net.core.netdev_max_backlog 2>/dev/null || true)
        if is_uint "$current_backlog"; then
            next=$(next_netdev_backlog_tier "$current_backlog") || return 1
            append_plan_persisted_value "$plan_file" net.core.netdev_max_backlog "$next" "$current_backlog" 'softnet dropped 连续增长且可用内存超过 20%；运行时已满足时仍补齐持久化'
        fi
    fi

    if ! find_plan_conflicts "$plan_file" > "$conflicts_file"; then
        die '无法完整扫描 sysctl 配置层级；拒绝生成可应用计划。'; return 1
    fi
    if [[ -s "$conflicts_file" ]]; then
        printf '检测到其他本地/运行时或后加载配置定义拟修改 key；apply 将 fail-closed。\n' >> "$warnings_file"
        while IFS=$'\t' read -r key file value; do printf '冲突: %s 来自 %s（%s）\n' "$key" "$file" "$value" >> "$warnings_file"; done < "$conflicts_file"
    fi
    [[ "$confidence" == high ]] || printf '测量置信度不是 high；apply/auto 将拒绝任何变更。\n' >> "$warnings_file"
    if [[ -e "$SYSCTL_FILE" ]] && ! managed_file_is_known_owned "$SYSCTL_FILE"; then
        printf '工具路径上的 sysctl 文件缺少所有权标记或包含未知格式；apply 将拒绝接管。\n' >> "$warnings_file"
    fi
    build_persisted_sysctl "$run_id" "$plan_file" "$proposed" || return 1
    write_plan_json "$run_dir" "$plan_file" "$warnings_file" "$plan_output" || return 1
    if (( DRY_RUN == 0 )); then
        create_hash_manifest "$run_dir" "$run_dir/plan.sha256" || return 1
        chmod -R go-rwx "$run_dir" || return 1
    fi
    if (( JSON_OUTPUT )); then
        cat "$plan_output"
    else
        if (( DRY_RUN )); then printf 'dry-run 计划（未写入 run 目录）：\n'; else printf '计划已生成: %s\n' "$run_dir/plan.json"; fi
        if [[ -s "$plan_file" ]]; then
            printf '推荐值:\n'
            while IFS=$'\t' read -r key value before reason change_type; do printf '  %s: %s -> %s（%s；%s）\n' "$key" "$before" "$value" "$reason" "${change_type:-runtime_change}"; done < "$plan_file"
        else
            printf '没有需要改变的 sysctl。\n'
        fi
        [[ ! -s "$warnings_file" ]] || { printf '警告:\n'; sed 's/^/  - /' "$warnings_file"; }
    fi
    if [[ -n "$preview_dir" ]]; then
        rm -rf -- "$preview_dir"
        PLAN_PREVIEW_DIR=""
        trap - EXIT INT TERM HUP
    fi
}

require_real_apply_roots() {
    if [[ "$ETC_ROOT" == /etc && "$PROC_ROOT" == /proc && "$SYS_ROOT" == /sys && "$RUN_ROOT" == /run &&
          "$STATE_DIR" == /var/lib/vps-proxy-tune ]]; then
        return 0
    fi
    # auto --dry-run uses a private, disposable state/run pair so the full
    # measure -> plan -> apply-preview path can be exercised without touching
    # /var/lib or /run.  Never permit redirected roots for a real mutation.
    if (( DRY_RUN )) && [[ "$ETC_ROOT" == /etc && "$PROC_ROOT" == /proc && "$SYS_ROOT" == /sys &&
        "$STATE_DIR" =~ ^/tmp/vps-proxy-tune-[A-Za-z0-9._-]+/state$ &&
        "$RUN_ROOT" =~ ^/tmp/vps-proxy-tune-[A-Za-z0-9._-]+/run$ ]]; then
        return 0
    fi
    die 'apply/rollback/uninstall 拒绝在重定向的系统根目录上运行。'
}

secure_script_source() {
    local path uid mode permissions resolved
    [[ -f "$SELF_PATH" && ! -L "$SELF_PATH" ]] || { die 'apply 要求主脚本是普通文件且不是符号链接。'; return 1; }
    resolved=$(readlink -f "$SELF_PATH" 2>/dev/null || true)
    [[ "$resolved" == "$SELF_PATH" ]] || { die '无法证明主脚本路径稳定。'; return 1; }
    path=$SELF_PATH
    while :; do
        uid=$(stat -c %u "$path" 2>/dev/null || printf unknown)
        mode=$(stat -c %a "$path" 2>/dev/null || printf unknown)
        [[ "$uid" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || { die "守卫源路径必须由 root 拥有: $path"; return 1; }
        permissions=$((8#$mode))
        (( (permissions & 8#022) == 0 )) || { die "守卫源路径不能由 group/other 写入: $path"; return 1; }
        [[ "$path" == / ]] && break
        path=$(dirname "$path")
    done
}

write_current_run() {
    local run_id="$1" temp record
    validate_run_id "$run_id" || return 1
    record=$(state_hash_file current_run) || return 1
    state_hash_pair_is_valid "$STATE_DIR/current_run" "$record" || {
        die 'current_run 已发生漂移，拒绝覆盖。'; return 1;
    }
    temp=$(mktemp "$STATE_DIR/.current.XXXXXXXX") || return 1
    if ! printf '%s\n' "$run_id" > "$temp" || ! chmod 0600 "$temp" || ! atomic_install "$temp" "$STATE_DIR/current_run" 0600; then
        rm -f -- "$temp"; return 1
    fi
    rm -f -- "$temp"
    write_private_hash_record "$STATE_DIR/current_run" "$record"
}

write_uninstalled_at() {
    local file="$STATE_DIR/uninstalled_at" record temp
    record=$(state_hash_file uninstalled_at) || return 1
    state_hash_pair_is_valid "$file" "$record" || {
        die 'uninstalled_at 已发生漂移，拒绝覆盖。'; return 1;
    }
    temp=$(mktemp "$STATE_DIR/.uninstalled-at.XXXXXXXX") || return 1
    if ! printf '%s\n' "$(date -u +%FT%TZ)" > "$temp" ||
       ! chmod 0600 "$temp" || ! atomic_install "$temp" "$file" 0600; then
        rm -f -- "$temp"
        return 1
    fi
    rm -f -- "$temp"
    write_private_hash_record "$file" "$record"
}

discard_transaction_staging() {
    local path="${1:-}" name
    [[ -n "$path" ]] || return 1
    name=$(basename -- "$path") || return 1
    transaction_staging_name "$name" || return 1
    [[ "$path" == "$STATE_DIR/transactions/$name" ]] || return 1
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        return 0
    fi
    [[ -d "$path" && ! -L "$path" ]] || return 1
    if rm -rf -- "$path"; then
        [[ ! -e "$path" && ! -L "$path" ]]
    else
        return 1
    fi
}

discard_unstarted_transaction() {
    local transaction="${1:-}" name status current previous
    [[ "$transaction" == "$STATE_DIR/transactions/"* ]] || return 1
    name=$(basename -- "$transaction") || return 1
    validate_run_id "$name" || return 1
    [[ "$transaction" == "$STATE_DIR/transactions/$name" ]] || return 1
    [[ -d "$transaction" && ! -L "$transaction" ]] || return 1
    transaction_snapshot_is_valid "$transaction" || return 1
    status=$(cat "$transaction/status" 2>/dev/null || true)
    [[ "$status" == prepared ]] || return 1
    current=$(cat "$STATE_DIR/current_run" 2>/dev/null || true)
    [[ "$current" != "$name" ]] || return 1
    previous=$(transaction_get "$transaction" PREVIOUS_RUN 2>/dev/null || true)
    if [[ -n "$current" ]]; then
        [[ "$previous" == "$current" ]] || return 1
    else
        [[ -z "$previous" ]] || return 1
    fi
    rm -rf -- "$transaction" || return 1
    [[ ! -e "$transaction" && ! -L "$transaction" ]]
}

remove_new_initial_baseline() {
    local initial="$STATE_DIR/baseline/initial" record staging name
    local allow_staging="${1:-0}" staging_rc=0
    local -a staged=()
    (( APPLY_BASELINE_CREATED == 1 )) || return 0
    [[ "$allow_staging" == 0 || "$allow_staging" == 1 ]] || return 1
    # A failed first-use publish may leave its private directory behind when
    # the final cleanup itself is interrupted.  Do not silently discard the
    # prepared transaction while that material remains during the live apply.
    # An authenticated baseline cleanup marker may pass allow_staging=1 so a
    # later recover can retry deletion of the exact safe staging name.
    shopt -s nullglob
    staged=("$STATE_DIR"/baseline/.initial.*)
    shopt -u nullglob
    for staging in "${staged[@]}"; do
        name=$(basename -- "$staging") || return 1
        [[ "$name" =~ ^\.initial\.[A-Za-z0-9]{8}$ && -d "$staging" && ! -L "$staging" ]] || return 1
        if (( allow_staging )); then
            if ! rm -rf -- "$staging" || [[ -e "$staging" || -L "$staging" ]]; then
                staging_rc=1
            fi
        else
            return 1
        fi
    done
    (( staging_rc == 0 )) || return 1
    record=$(baseline_identity_hash_file) || return 1
    if [[ ! -e "$initial" && ! -L "$initial" && ! -e "$record" && ! -L "$record" ]]; then
        APPLY_BASELINE_CREATED=0
        return 0
    fi
    baseline_identity_is_current "$initial" "$record" || return 1
    rm -rf -- "$initial" || return 1
    if [[ -e "$record" || -L "$record" ]]; then
        rm -f -- "$record" || return 1
    fi
    [[ ! -e "$initial" && ! -L "$initial" && ! -e "$record" && ! -L "$record" ]] || return 1
    APPLY_BASELINE_CREATED=0
}

baseline_cleanup_marker_path() {
    local run_id="$1"
    validate_run_id "$run_id" || return 1
    printf '%s/.baseline-rollback.%s\n' "$STATE_DIR" "$run_id"
}

baseline_cleanup_marker_is_safe() {
    local marker="$1" name run_id expected state_uid state_mode marker_uid marker_mode
    [[ -d "$STATE_DIR" && ! -L "$STATE_DIR" ]] || return 1
    state_uid=$(stat -c %u "$STATE_DIR" 2>/dev/null || true)
    state_mode=$(stat -c %a "$STATE_DIR" 2>/dev/null || true)
    [[ "$state_uid" == 0 && "$state_mode" == 700 ]] || return 1
    secure_directory_chain "$STATE_DIR" || return 1
    [[ "$marker" == "$STATE_DIR"/.baseline-rollback.* ]] || return 1
    name=$(basename -- "$marker") || return 1
    [[ "$name" =~ ^\.baseline-rollback\.([A-Za-z0-9][A-Za-z0-9._-]{0,95})$ ]] || return 1
    run_id="${BASH_REMATCH[1]}"
    expected=$(baseline_cleanup_marker_path "$run_id") || return 1
    [[ "$marker" == "$expected" ]] || return 1
    [[ -f "$marker" && ! -L "$marker" ]] || return 1
    marker_uid=$(stat -c %u "$marker" 2>/dev/null || true)
    marker_mode=$(stat -c %a "$marker" 2>/dev/null || true)
    [[ "$marker_uid" == 0 && "$marker_mode" == 600 ]] || return 1
    awk -F '\t' -v run_id="$run_id" \
        'NR == 1 && NF == 2 && $1 == run_id && $2 == "baseline-cleanup-pending" { valid=1 }
         END { exit !(valid == 1 && NR == 1) }' "$marker"
}

write_baseline_cleanup_marker() {
    local transaction="$1" run_id marker temp
    (( APPLY_BASELINE_CREATED == 1 )) || return 0
    [[ "$transaction" == "$STATE_DIR/transactions/"* ]] || return 1
    run_id=$(basename -- "$transaction") || return 1
    validate_run_id "$run_id" || return 1
    [[ "$transaction" == "$STATE_DIR/transactions/$run_id" ]] || return 1
    [[ -d "$transaction" && ! -L "$transaction" ]] || return 1
    transaction_snapshot_is_valid "$transaction" || return 1
    marker=$(baseline_cleanup_marker_path "$run_id") || return 1
    if [[ -e "$marker" || -L "$marker" ]]; then
        baseline_cleanup_marker_is_safe "$marker"
        return $?
    fi
    temp=$(mktemp "$STATE_DIR/.baseline-rollback.$run_id.XXXXXXXX") || return 1
    if printf '%s\tbaseline-cleanup-pending\n' "$run_id" > "$temp" &&
       chmod 0600 "$temp" && atomic_install "$temp" "$marker" 0600; then
        rm -f -- "$temp" || return 1
        return 0
    fi
    rm -f -- "$temp"
    return 1
}

remove_baseline_cleanup_marker() {
    local marker="$1"
    baseline_cleanup_marker_is_safe "$marker" || return 1
    rm -f -- "$marker" || return 1
    [[ ! -e "$marker" && ! -L "$marker" ]]
}

recover_baseline_cleanup_marker() {
    local marker="$1" name run_id transaction status current
    local baseline="$STATE_DIR/baseline/initial" record
    baseline_cleanup_marker_is_safe "$marker" || return 1
    name=$(basename -- "$marker") || return 1
    run_id=${name#'.baseline-rollback.'}
    validate_run_id "$run_id" || return 1
    transaction="$STATE_DIR/transactions/$run_id"
    record=$(baseline_identity_hash_file) || return 1
    if [[ ! -e "$transaction" && ! -L "$transaction" ]]; then
        [[ ! -e "$baseline" && ! -L "$baseline" && ! -e "$record" && ! -L "$record" ]] || return 1
        remove_baseline_cleanup_marker "$marker"
        return $?
    fi
    [[ -d "$transaction" && ! -L "$transaction" ]] || return 1
    transaction_snapshot_is_valid "$transaction" || return 1
    # The marker is a compensation record, not an independent ownership
    # grant.  Re-authenticate its transaction against the current chain
    # before removing a baseline or advancing current_run.  The optional
    # target is needed because this transaction is intentionally incomplete
    # while recovery is in progress.
    validate_transaction_chain "$run_id" || return 1
    status=$(cat "$transaction/status" 2>/dev/null || true)
    case "$status" in
        prepared)
            current=$(cat "$STATE_DIR/current_run" 2>/dev/null || true)
            [[ "$current" != "$run_id" ]] || return 1
            APPLY_BASELINE_CREATED=1
            remove_new_initial_baseline 1 || return 1
            discard_unstarted_transaction "$transaction" || return 1
            ;;
        rolled-back)
            current=$(cat "$STATE_DIR/current_run" 2>/dev/null || true)
            if [[ "$current" == "$run_id" ]]; then
                advance_rolled_back_head "$transaction" || return 1
            fi
            cancel_rollback_guard "$transaction" || return 1
            APPLY_BASELINE_CREATED=1
            remove_new_initial_baseline 1 || return 1
            ;;
        *)
            return 1
            ;;
    esac
    remove_baseline_cleanup_marker "$marker"
}

recover_baseline_cleanup_markers() {
    local marker directory uid mode
    local -a markers=()
    [[ -d "$STATE_DIR" && ! -L "$STATE_DIR" ]] || return 1
    secure_directory_chain "$STATE_DIR" || return 1
    for directory in "$STATE_DIR/runs" "$STATE_DIR/transactions" "$STATE_DIR/baseline"; do
        [[ -d "$directory" && ! -L "$directory" ]] || return 1
        uid=$(stat -c %u "$directory" 2>/dev/null || true)
        mode=$(stat -c %a "$directory" 2>/dev/null || true)
        [[ "$uid" == 0 && "$mode" == 700 ]] || return 1
    done
    shopt -s nullglob
    markers=("$STATE_DIR"/.baseline-rollback.*)
    shopt -u nullglob
    # Multiple markers cannot be ordered safely: each one may describe a
    # different incomplete apply and recovery mutates shared baseline state.
    # Refuse before changing any marker so an operator can inspect the full
    # set and resolve it explicitly.
    ((${#markers[@]} <= 1)) || return 1
    # Marker recovery mutates both the baseline and its transaction.  Take
    # the global lock only when there is a marker to process; the main
    # recovery path still needs its existing CAS-before-lock ordering for a
    # live apply transaction.  If a marker appears after this scan, the
    # caller's ensure_secure_state pass will fail closed and leave it for the
    # next recover invocation.
    if ((${#markers[@]} > 0)); then
        acquire_lock 30 || return 1
    fi
    for marker in "${markers[@]}"; do
        recover_baseline_cleanup_marker "$marker" || return 1
    done
}

cleanup_unpublished_transaction() {
    local transaction="$1" cleanup_rc=0 baseline_rc=0 transaction_rc=0
    if ! remove_new_initial_baseline; then
        baseline_rc=1
    fi
    if (( baseline_rc != 0 )); then
        write_baseline_cleanup_marker "$transaction" ||
            warn '无法写入 baseline cleanup marker；保留 prepared 事务和现有材料供人工检查。'
    fi
    # Keep the prepared transaction as an authenticated recovery marker when
    # baseline compensation fails.  Removing the only transaction record would
    # make the leftover baseline impossible to attribute or recover.
    if (( baseline_rc == 0 )); then
        discard_unstarted_transaction "$transaction" || transaction_rc=1
    else
        transaction_rc=1
    fi
    (( baseline_rc == 0 && transaction_rc == 0 )) || cleanup_rc=1
    if (( cleanup_rc )); then
        # The EXIT trap must not turn a deliberately retained prepared
        # transaction into a rolled-back historical record: that transaction
        # is the authenticated marker tying any partial baseline/recovery
        # material to this failed publish.
        APPLY_PRESERVE_PREPARED=1
        warn '未发布事务或新建 baseline 无法完整清理；保留事务/材料供 recover/status 检测。'
        set_outcome 'rollback_failed' 'recovery_pending'
        emit_json_result rollback_failed recovery_pending "$(basename -- "$transaction")" rollback-failed
        return 1
    fi
    APPLY_BASELINE_EXPECT_NEW=0
    RECOVERY_UNIT_HOLD_BACKUP=0
    disarm_apply_cleanup
    return 0
}

ACTIVE_TRANSACTION=""
POST_VERIFY_LOADED_PID=0
POST_VERIFY_LOADED_STARTTIME=""

post_verify_cleanup() {
    local pid="$POST_VERIFY_LOADED_PID" expected="$POST_VERIFY_LOADED_STARTTIME"
    if is_positive_uint "$pid"; then
        terminate_owned_process "$pid" "$expected" TERM 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    POST_VERIFY_LOADED_PID=0
    POST_VERIFY_LOADED_STARTTIME=""
}

apply_exit_cleanup() {
    local saved_status="$1" status=""
    trap - EXIT INT TERM HUP
    post_verify_cleanup
    if [[ -n "$RECOVERY_UNIT_PENDING_BACKUP" ]]; then
        restore_held_recovery_unit || warn '退出清理无法恢复 apply 前的启动恢复材料；保留恢复备份供 status/recover 检测。'
    fi
    if (( APPLY_PRESERVE_PREPARED )); then
        warn '未发布事务被保留为恢复 marker；跳过 EXIT trap 的自动回滚，等待 recover/status 检查。'
        return "$saved_status"
    fi
    if [[ -n "$ACTIVE_TRANSACTION" && -d "$ACTIVE_TRANSACTION" ]]; then
        status=$(cat "$ACTIVE_TRANSACTION/status" 2>/dev/null || printf unknown)
        if [[ "$status" == guard-restoring ]]; then
            return "$saved_status"
        elif [[ "$status" != committed && "$status" != pending-confirm && "$status" != rolled-back ]]; then
            if restore_transaction "$ACTIVE_TRANSACTION"; then
                cancel_rollback_guard "$ACTIVE_TRANSACTION" || warn '退出清理回滚成功，但守卫停止/重置失败；请人工检查。'
                if ! remove_new_initial_baseline; then
                    warn '退出清理已恢复事务，但新建 baseline 无法安全移除；保留 baseline 作为可检测恢复证据。'
                    write_baseline_cleanup_marker "$ACTIVE_TRANSACTION" ||
                        warn '退出清理无法写入 baseline cleanup marker；请保留并检查当前 baseline 与事务状态。'
                fi
            else
                warn '退出清理无法完成回滚；保留守卫和 rollback-failed 状态以便重试。'
            fi
        fi
    fi
    return "$saved_status"
}

apply_signal_exit() { exit 130; }

arm_apply_cleanup() {
    ACTIVE_TRANSACTION=$1
    trap 'apply_exit_cleanup "$?"' EXIT
    trap apply_signal_exit INT TERM HUP
}

disarm_apply_cleanup() {
    ACTIVE_TRANSACTION=""
    trap - EXIT INT TERM HUP
}

ensure_secure_state() {
    local uid mode format_file format directory file name record backup staging transaction
    local -a hidden_state_entries=() state_entries=()
    [[ -d "$STATE_DIR" && ! -L "$STATE_DIR" ]] || { die '状态目录不存在或是符号链接。'; return 1; }
    uid=$(stat -c %u "$STATE_DIR" 2>/dev/null || printf unknown)
    mode=$(stat -c %a "$STATE_DIR" 2>/dev/null || printf unknown)
    [[ "$uid" == 0 && "$mode" == 700 ]] || { die "状态目录必须由 root 拥有且权限为 0700（当前 $uid:$mode）。"; return 1; }
    # The child trees contain executable recovery material and network
    # metadata.  Validate them on every read path as well as at creation time;
    # otherwise a later chmod/chown could turn history or recovery into an
    # ambiently writable control surface.
    for directory in "$STATE_DIR/runs" "$STATE_DIR/transactions" "$STATE_DIR/baseline"; do
        [[ -d "$directory" && ! -L "$directory" ]] || { die "状态子目录不存在或是不安全类型: $directory"; return 1; }
        uid=$(stat -c %u "$directory" 2>/dev/null || printf unknown)
        mode=$(stat -c %a "$directory" 2>/dev/null || printf unknown)
        [[ "$uid" == 0 && "$mode" == 700 ]] || { die "状态子目录必须是 root:root 0700: $directory ($uid:$mode)"; return 1; }
    done
    # The state directory is a dedicated control boundary.  Reject an
    # unexplained visible top-level entry as well as hidden staging material;
    # otherwise a failed write could leave a file that every normal read path
    # silently ignores.
    shopt -s nullglob
    state_entries=("$STATE_DIR"/*)
    shopt -u nullglob
    for file in "${state_entries[@]}"; do
        name=$(basename -- "$file") || return 1
        case "$name" in
            baseline|runs|transactions)
                [[ -d "$file" && ! -L "$file" ]] || { die "状态子目录类型不安全: $file"; return 1; }
                ;;
            current_run|current_run.sha256|owned-services.tsv|owned-services.tsv.sha256|\
            state-format|state-format.sha256|state.meta|state.meta.sha256|uninstalled_at|uninstalled_at.sha256|\
            recovery-script.sh|recovery-script.sha256|recovery-unit.sha256|recovery-qdisc-unit.sha256)
                ;;
            *)
                die "检测到未登记的状态材料；停止并保留证据: $file"
                return 1
                ;;
        esac
    done
    for file in "$STATE_DIR/current_run" "$STATE_DIR/owned-services.tsv" "$STATE_DIR/state-format" \
        "$STATE_DIR/state.meta" "$STATE_DIR/current_run.sha256" "$STATE_DIR/owned-services.tsv.sha256" \
        "$STATE_DIR/state-format.sha256" "$STATE_DIR/uninstalled_at" "$STATE_DIR/uninstalled_at.sha256" \
        "$STATE_DIR/state.meta.sha256" \
        "$RECOVERY_SCRIPT_PATH" "$RECOVERY_SCRIPT_HASH_FILE" "$RECOVERY_UNIT_HASH_FILE" "$RECOVERY_QDISC_UNIT_HASH_FILE"; do
        if [[ -e "$file" || -L "$file" ]]; then
            [[ -f "$file" && ! -L "$file" ]] || { die "状态元数据文件权限或类型不安全: $file"; return 1; }
            secure_private_path "$file" || { die "状态元数据文件权限或类型不安全: $file"; return 1; }
        fi
    done
    format_file=$(state_format_file)
    if [[ -e "$format_file" || -L "$format_file" ]]; then
        [[ -f "$format_file" && ! -L "$format_file" ]] || { die '状态格式文件类型不安全。'; return 1; }
        secure_private_path "$format_file" || { die '状态格式文件权限不安全。'; return 1; }
        format=$(cat "$format_file" 2>/dev/null || true)
        [[ "$format" == "$STATE_FORMAT_VERSION" ]] || { die "不支持的状态格式版本: ${format:-empty}"; return 1; }
    fi
    if [[ -e "$STATE_DIR/state.meta" || -L "$STATE_DIR/state.meta" ||
          -e "$STATE_DIR/state.meta.sha256" || -L "$STATE_DIR/state.meta.sha256" ]]; then
        [[ -f "$STATE_DIR/state.meta" && ! -L "$STATE_DIR/state.meta" ]] || { die '状态 metadata 类型不安全。'; return 1; }
        managed_file_has_current_metadata "$STATE_DIR/state.meta" || { die '状态 metadata 版本或所有权不受支持。'; return 1; }
        record=$(state_hash_file state.meta) || return 1
        state_hash_pair_is_valid "$STATE_DIR/state.meta" "$record" || { die '状态 metadata 哈希或 inode 不一致。'; return 1; }
    fi
    for name in current_run owned-services.tsv state-format uninstalled_at; do
        file="$STATE_DIR/$name"
        record=$(state_hash_file "$name") || return 1
        if [[ -e "$file" || -L "$file" || -e "$record" || -L "$record" ]]; then
            state_hash_pair_is_valid "$file" "$record" || { die "状态文件哈希或 inode 不一致: $file"; return 1; }
        fi
    done
    local artifact="$RECOVERY_SCRIPT_PATH"
    record="$RECOVERY_SCRIPT_HASH_FILE"
        if [[ -e "$artifact" || -L "$artifact" || -e "$record" || -L "$record" ]]; then
            if [[ -e "$artifact" || -L "$artifact" ]] && [[ -e "$record" || -L "$record" ]]; then
                verify_private_hash_record "$artifact" "$record" || {
                    die "恢复脚本或哈希记录不一致: $artifact"; return 1;
                }
            elif [[ -f "$artifact" && ! -L "$artifact" && ! -e "$record" && ! -L "$record" ]]; then
                secure_owned_file "$artifact" || { die "旧版恢复脚本权限不安全: $artifact"; return 1; }
            else
                die "恢复脚本或哈希记录不完整: $artifact"; return 1
            fi
        fi
    for file in "$RECOVERY_UNIT_PATH:$RECOVERY_UNIT_HASH_FILE" "$RECOVERY_QDISC_UNIT_PATH:$RECOVERY_QDISC_UNIT_HASH_FILE"; do
        local artifact=${file%%:*} record=${file#*:}
        if [[ -e "$artifact" || -L "$artifact" || -e "$record" || -L "$record" ]]; then
            if [[ -e "$artifact" || -L "$artifact" ]] && [[ -e "$record" || -L "$record" ]]; then
                verify_private_hash_record "$artifact" "$record" || {
                    die "恢复单元或哈希记录不一致: $artifact"; return 1;
                }
            elif [[ -f "$artifact" && ! -L "$artifact" && ! -e "$record" && ! -L "$record" ]]; then
                secure_owned_file "$artifact" || { die "旧版恢复单元权限不安全: $artifact"; return 1; }
            else
                die "恢复单元或哈希记录不完整: $artifact"; return 1
            fi
        fi
    done
    file="$(baseline_identity_path):$(baseline_identity_hash_file)"
    local artifact=${file%%:*} record=${file#*:}
    if [[ -e "$artifact" || -L "$artifact" || -e "$record" || -L "$record" ]]; then
        if [[ -e "$artifact" || -L "$artifact" ]] && [[ -e "$record" || -L "$record" ]]; then
            verify_private_hash_record "$artifact" "$record" || {
                die "baseline identity 或哈希记录不一致: $artifact"; return 1;
            }
        else
            die 'baseline identity 或哈希记录不完整。'; return 1
        fi
    fi
    # A legacy v1 baseline may omit identity.tsv, but a v2 identity artifact
    # must always be complete.  Also reject the temporary identity sidecar
    # name used before the baseline directory is published; otherwise a
    # failed first-use publish could remain invisible to later state checks.
    if [[ -e "$STATE_DIR/baseline/initial" || -L "$STATE_DIR/baseline/initial" ]]; then
        local initial_dir="$STATE_DIR/baseline/initial"
        local initial_identity="$initial_dir/identity.tsv" legacy_identity="$initial_dir/identity.sha256"
        [[ -d "$initial_dir" && ! -L "$initial_dir" ]] || { die '首次 baseline 类型不安全。'; return 1; }
        uid=$(stat -c %u "$initial_dir" 2>/dev/null || printf unknown)
        mode=$(stat -c %a "$initial_dir" 2>/dev/null || printf unknown)
        [[ "$uid" == 0 && "$mode" == 700 ]] || { die '首次 baseline 目录权限不安全。'; return 1; }
        [[ ! -e "$legacy_identity" && ! -L "$legacy_identity" ]] || {
            die '检测到未完成的 baseline identity 暂存材料；停止并保留证据。'; return 1;
        }
        if [[ -e "$initial_identity" || -L "$initial_identity" || -e "$record" || -L "$record" ]]; then
            baseline_identity_is_current "$initial_dir" "$record" || {
                die 'baseline identity 不完整或已漂移；停止并保留证据。'; return 1;
            }
        else
            verify_hash_manifest "$initial_dir" "$initial_dir/manifest.sha256" || {
                die 'legacy baseline manifest 不可信；停止并保留证据。'; return 1;
            }
        fi
    fi
    shopt -s nullglob
    for staging in "$STATE_DIR"/baseline/.initial.*; do
        [[ -d "$staging" && ! -L "$staging" ]] || {
            shopt -u nullglob
            die "baseline 暂存材料类型不安全；停止并保留证据: $staging"
            return 1
        }
        name=$(basename -- "$staging") || {
            shopt -u nullglob
            return 1
        }
        [[ "$name" =~ ^\.initial\.[A-Za-z0-9]{8}$ ]] || {
            shopt -u nullglob
            die "baseline 暂存材料名称不安全；停止并保留证据: $staging"
            return 1
        }
        die "检测到未发布的 baseline 暂存材料；停止并保留证据: $staging"
        shopt -u nullglob
        return 1
    done
    for transaction in "$STATE_DIR"/transactions/.[!.]* "$STATE_DIR"/transactions/..?*; do
        name=$(basename -- "$transaction") || {
            shopt -u nullglob
            return 1
        }
        if transaction_staging_name "$name"; then
            [[ -d "$transaction" && ! -L "$transaction" ]] || {
                shopt -u nullglob
                die "事务暂存材料类型不安全；停止并保留证据: $transaction"
                return 1
            }
            shopt -u nullglob
            die "检测到未发布的事务暂存材料；停止并保留证据: $transaction"
            return 1
        fi
    done
    for backup in "$STATE_DIR"/.recovery-unit-rollback.*; do
        if recovery_unit_backup_is_safe "$backup"; then
            :
        elif recovery_failure_marker_is_safe "$backup"; then
            shopt -u nullglob
            die "启动恢复补偿失败 marker 已存在；拒绝自动接管并保留证据: $backup"
            return 1
        else
            shopt -u nullglob
            die "启动恢复补偿备份不可信；拒绝继续并保留证据: $backup"
            return 1
        fi
    done
    for backup in "$STATE_DIR"/.recovery-script-rollback.*; do
        if recovery_failure_marker_is_safe "$backup"; then
            shopt -u nullglob
            die "恢复脚本补偿失败 marker 已存在；拒绝自动接管并保留证据: $backup"
            return 1
        fi
        shopt -u nullglob
        die "恢复脚本补偿材料不可信；拒绝继续并保留证据: $backup"
        return 1
    done
    for staging in "$STATE_DIR"/.recovery-script.* "$STATE_DIR"/.recovery-unit.* "$STATE_DIR"/.recovery-qdisc-unit.*; do
        shopt -u nullglob
        die "检测到未发布的恢复单元暂存材料；停止并保留证据: $staging"
        return 1
    done
    shopt -u nullglob
    # Every top-level dot entry is a private operation temporary or a
    # compensating recovery directory.  Do not let a failed hash/status/state
    # write remain invisible merely because its basename is not part of the
    # normal state schema.  A complete unit rollback backup is the only
    # intentionally persistent exception and has already been authenticated
    # above.
    shopt -s nullglob
    hidden_state_entries=("$STATE_DIR"/.[!.]* "$STATE_DIR"/..?*)
    shopt -u nullglob
    for staging in "${hidden_state_entries[@]}"; do
        name=$(basename -- "$staging") || return 1
        case "$name" in
            .baseline-rollback.*)
                baseline_cleanup_marker_is_safe "$staging" || {
                    die "baseline cleanup marker 不可信；停止并保留证据: $staging"
                    return 1
                }
                die "检测到 baseline cleanup marker；请先执行 recover 并确认本轮新建 baseline 可安全清理: $staging"
                return 1
                ;;
            .recovery-unit-rollback.????????)
                recovery_unit_backup_is_safe "$staging" || {
                    die "启动恢复补偿备份不可信；拒绝继续并保留证据: $staging"
                    return 1
                }
                ;;
            *)
                die "检测到未发布的状态暂存材料；停止并保留证据: $staging"
                return 1
                ;;
        esac
    done
}

validate_plan_file() {
    local file="$1" key value before reason change_type extra count=0
    declare -A seen=()
    [[ -f "$file" && ! -L "$file" ]] || return 1
    while IFS=$'\t' read -r key value before reason change_type extra || [[ -n "${key:-}" ]]; do
        [[ -n "$key" && -z "${extra:-}" ]] || return 1
        is_target_sysctl_key "$key" || return 1
        [[ -z "${seen[$key]+x}" ]] || return 1
        seen[$key]=1
        record_field_is_safe "$key" && record_field_is_safe "$value" &&
            record_field_is_safe "$before" && record_field_is_safe "$reason" &&
            record_field_is_safe "$change_type" || return 1
        [[ "$value" =~ ^[A-Za-z0-9_.[:space:]-]+$ ]] || return 1
        [[ -n "$before" && -n "$reason" ]] || return 1
        plan_change_type "$change_type" >/dev/null || return 1
        count=$((count + 1)); (( count <= 32 )) || return 1
    done < "$file"
}

plan_current_is_safe() {
    local file="$1" key value before reason change_type current
    while IFS=$'\t' read -r key value before reason change_type; do
        plan_entry_enabled "$key" || continue
        current=$(sysctl_read "$key" 2>/dev/null || true)
        if [[ "$current" != "$before" && "$current" != "$value" ]]; then
            err "$key 在 plan 后发生变化（plan 前=$before，当前=$current）；请重新 measure/plan。"
            return 1
        fi
    done < "$file"
}

verify_plan_runtime() {
    local file="$1" key value before reason change_type current failed=0
    while IFS=$'\t' read -r key value before reason change_type; do
        plan_entry_enabled "$key" || continue
        current=$(sysctl_read "$key" 2>/dev/null || true)
        if [[ "$current" != "$value" ]]; then
            err "运行时验证失败: $key 期望 '$value'，得到 '$current'。"
            failed=1
        fi
    done < "$file"
    (( failed == 0 ))
}

verify_retained_runtime() {
    local all_file="$1" changed_file="$2" key value before reason change_type current failed=0
    while IFS=$'\t' read -r key value before reason change_type; do
        plan_entry_enabled "$key" || continue
        plan_contains_key "$changed_file" "$key" && continue
        current=$(sysctl_read "$key" 2>/dev/null || true)
        if [[ "$current" != "$value" ]]; then
            err "已有 owned 值漂移: $key 期望 '$value'，得到 '$current'。"
            failed=1
        fi
    done < "$all_file"
    (( failed == 0 ))
}

capture_runtime() {
    local output="$1" key value
    : > "$output" || return 1
    while IFS= read -r key; do
        value=$(sysctl_read "$key" 2>/dev/null || true)
        if [[ -n "$value" ]]; then
            printf '%s\t%s\n' "$key" "$value" >> "$output" || return 1
        fi
    done < <(target_sysctl_keys)
    chmod 0600 "$output" || return 1
}

restore_runtime_file() {
    local input="$1" key value rc=0
    [[ -r "$input" ]] || return 1
    while IFS=$'\t' read -r key value; do
        is_target_sysctl_key "$key" || { rc=1; continue; }
        if ! record_field_is_safe "$key" || ! record_field_is_safe "$value"; then rc=1; continue; fi
        [[ "$value" =~ ^[A-Za-z0-9_.[:space:]-]+$ ]] || { rc=1; continue; }
        sysctl -q -w "$key=$value" >/dev/null 2>&1 || rc=1
    done < "$input"
    return "$rc"
}

restore_transaction_runtime() {
    local transaction="$1" key before desired current rc=0
    [[ -r "$transaction/runtime.before.tsv" && -r "$transaction/desired.tsv" ]] || return 1
    while IFS=$'\t' read -r key before; do
        is_target_sysctl_key "$key" || { rc=1; continue; }
        desired=$(awk -F'\t' -v key="$key" '$1==key{print $2;found=1;exit} END{if(!found)exit 1}' "$transaction/desired.tsv" 2>/dev/null || true)
        [[ -n "$desired" ]] || continue
        # Retained values and already-satisfied recommendations were not changed by this transaction.
        [[ "$desired" != "$before" ]] || continue
        current=$(sysctl_read "$key" 2>/dev/null || true)
        if [[ "$current" == "$before" ]]; then
            continue
        elif [[ "$current" == "$desired" ]]; then
            sysctl -q -w "$key=$before" >/dev/null 2>&1 || rc=1
        else
            warn "$key 已在 apply 后变化；为避免覆盖管理员值，回滚跳过该 sysctl。"
            transaction_append_mutable_line "$transaction" apply.warnings \
                "sysctl $key ownership value changed; rollback skipped runtime key" 2>/dev/null || true
            rc=1
        fi
    done < "$transaction/runtime.before.tsv"
    return "$rc"
}

owned_path_allowed() {
    local path="$1" relative unit
    [[ "$path" == "$SYSCTL_FILE" || "$path" == "$MODULES_FILE" || "$path" == "$RECOVERY_UNIT_PATH" ||
       "$path" == "$RECOVERY_QDISC_UNIT_PATH" ]] && return 0
    [[ "$path" == "${ETC_ROOT}/systemd/system/"*'.service.d/90-vps-proxy-tune.conf' ]] || return 1
    relative=${path#"${ETC_ROOT}/systemd/system/"}; unit=${relative%%.d/*}
    validate_unit "$unit"
}

secure_owned_file() {
    local path="$1" uid mode permissions
    [[ -f "$path" && ! -L "$path" ]] || return 1
    uid=$(stat -c %u "$path" 2>/dev/null || true)
    mode=$(stat -c %a "$path" 2>/dev/null || true)
    [[ "$uid" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    permissions=$((8#$mode))
    (( (permissions & 8#022) == 0 ))
}

snapshot_owned_file() {
    local label="$1" path="$2" snapshot_dir="$3" records="$4" identity="${5:-}" uid mode permissions hash inode
    if [[ ! "$label" =~ ^[a-z0-9_-]+$ ]] || ! owned_path_allowed "$path"; then return 1; fi
    if [[ -n "$identity" && "$identity" != "$(dirname -- "$snapshot_dir")/files.identity.tsv" ]]; then return 1; fi
    secure_target_parent "$path" || return 1
    if [[ -L "$path" ]]; then die "拒绝跟随 owned path 符号链接: $path"; return 1; fi
    if [[ -e "$path" ]]; then
        [[ -f "$path" ]] || { die "owned path 不是普通文件: $path"; return 1; }
        uid=$(stat -c %u "$path") || return 1
        mode=$(stat -c %a "$path") || return 1
        [[ "$uid" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || {
            die "owned path 必须由 root 拥有: $path"; return 1;
        }
        permissions=$((8#$mode))
        (( (permissions & 8#022) == 0 )) || {
            die "owned path 不得由 group/other 写入: $path"; return 1;
        }
        hash=$(sha256sum "$path" | awk '{print $1}') || return 1
        [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
        inode=$(stat -c %i "$path") || return 1
        [[ "$inode" =~ ^[0-9]+$ ]] || return 1
        install -m 0600 "$path" "$snapshot_dir/$label.before" || return 1
        printf '%s\t%s\t1\t%s\t%s\n' "$label" "$path" "$mode" "$hash" >> "$records" || return 1
        if [[ -n "$identity" ]]; then
            printf '%s\t%s\t1\t%s\t%s\t%s\n' "$label" "$path" "$inode" "$mode" "$hash" >> "$identity" || return 1
        fi
    else
        printf '%s\t%s\t0\t-\t-\n' "$label" "$path" >> "$records" || return 1
        if [[ -n "$identity" ]]; then
            printf '%s\t%s\t0\t-\t-\t-\n' "$label" "$path" >> "$identity" || return 1
        fi
    fi
}

owned_target_matches_snapshot() {
    local transaction="$1" label="$2" record path existed mode hash extra current_hash identity_record identity_existed identity_inode identity_mode identity_hash identity_extra
    [[ "$label" =~ ^[a-z0-9_-]+$ ]] || return 1
    record=$(awk -F'\t' -v label="$label" '$1==label{print;found=1;exit} END{if(!found)exit 1}' "$transaction/files.tsv") || return 1
    IFS=$'\t' read -r _ path existed mode hash extra <<< "$record"
    [[ -z "${extra:-}" ]] || return 1
    owned_path_allowed "$path" || return 1
    secure_target_parent "$path" || return 1
    if [[ "$existed" == 1 ]]; then
        secure_owned_file "$path" || return 1
        current_hash=$(sha256sum "$path" | awk '{print $1}') || return 1
        [[ "$current_hash" == "$hash" ]] || return 1
        if [[ -f "$transaction/files.identity.tsv" && ! -L "$transaction/files.identity.tsv" ]]; then
            identity_record=$(awk -F'\t' -v label="$label" '$1==label{print;found=1;exit} END{if(!found)exit 1}' "$transaction/files.identity.tsv") || return 1
            IFS=$'\t' read -r _ _ identity_existed identity_inode identity_mode identity_hash identity_extra <<< "$identity_record"
            [[ "$identity_existed" == 1 && "$identity_inode" =~ ^[0-9]+$ && "$identity_mode" =~ ^[0-7]{3,4}$ &&
               "$identity_hash" == "$hash" && -z "${identity_extra:-}" ]] || return 1
            [[ "$(stat -c %i "$path" 2>/dev/null || true)" == "$identity_inode" &&
               "$(stat -c %a "$path" 2>/dev/null || true)" == "$identity_mode" ]]
        fi
    elif [[ "$existed" == 0 ]]; then
        [[ ! -e "$path" && ! -L "$path" ]] || return 1
        if [[ -f "$transaction/files.identity.tsv" && ! -L "$transaction/files.identity.tsv" ]]; then
            identity_record=$(awk -F'\t' -v label="$label" '$1==label{print;found=1;exit} END{if(!found)exit 1}' "$transaction/files.identity.tsv") || return 1
            IFS=$'\t' read -r _ _ identity_existed identity_inode identity_mode identity_hash identity_extra <<< "$identity_record"
            [[ "$identity_existed" == 0 && "$identity_inode" == - && "$identity_mode" == - && "$identity_hash" == - && -z "${identity_extra:-}" ]]
        fi
    else
        return 1
    fi
}

owned_after_hash() {
    local transaction="$1" label="$2" key
    case "$label" in
        sysctl) key=SYSCTL_HASH ;;
        modules) key=MODULES_HASH ;;
        service) key=SERVICE_HASH ;;
        *) return 1 ;;
    esac
    transaction_get "$transaction" "$key"
}

owned_after_inode() {
    local transaction="$1" label key
    case "$label" in
        sysctl) key=SYSCTL_INODE ;;
        modules) key=MODULES_INODE ;;
        service) key=SERVICE_INODE ;;
        *) return 1 ;;
    esac
    transaction_get "$transaction" "$key"
}

owned_after_mode() {
    local transaction="$1" label key
    case "$label" in
        sysctl) key=SYSCTL_MODE ;;
        modules) key=MODULES_MODE ;;
        service) key=SERVICE_MODE ;;
        *) return 1 ;;
    esac
    transaction_get "$transaction" "$key"
}

record_owned_after_identity() {
    local transaction="$1" label="$2" path inode mode inode_key mode_key
    case "$label" in
        sysctl) path="$SYSCTL_FILE"; inode_key=SYSCTL_INODE; mode_key=SYSCTL_MODE ;;
        modules) path="$MODULES_FILE"; inode_key=MODULES_INODE; mode_key=MODULES_MODE ;;
        service) path=$(transaction_get "$transaction" SERVICE_PATH 2>/dev/null || true); inode_key=SERVICE_INODE; mode_key=SERVICE_MODE ;;
        *) return 1 ;;
    esac
    [[ -f "$path" && ! -L "$path" ]] || return 1
    owned_path_allowed "$path" || return 1
    inode=$(stat -c %i "$path" 2>/dev/null || true)
    mode=$(stat -c %a "$path" 2>/dev/null || true)
    [[ "$inode" =~ ^[1-9][0-9]*$ && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    transaction_put "$transaction" "$inode_key" "$inode" || return 1
    transaction_put "$transaction" "$mode_key" "$mode"
}

owned_after_identity_is_current() {
    local transaction="$1" label="$2" path="$3" after_inode after_mode current_inode current_mode
    after_inode=$(owned_after_inode "$transaction" "$label" 2>/dev/null || true)
    after_mode=$(owned_after_mode "$transaction" "$label" 2>/dev/null || true)
    if [[ -z "$after_inode" && -z "$after_mode" ]]; then return 0; fi
    [[ "$after_inode" =~ ^[1-9][0-9]*$ && "$after_mode" =~ ^[0-7]{3,4}$ ]] || return 1
    [[ -f "$path" && ! -L "$path" ]] || return 1
    current_inode=$(stat -c %i "$path" 2>/dev/null || true)
    current_mode=$(stat -c %a "$path" 2>/dev/null || true)
    [[ "$current_inode" == "$after_inode" && "$current_mode" == "$after_mode" ]]
}

restore_owned_files() {
    local transaction label path existed mode hash source rc=0 records after_hash after_inode after_mode current_hash current_inode current_mode
    transaction=$1; records="$transaction/files.tsv"
    [[ -r "$records" ]] || return 1
    while IFS=$'\t' read -r label path existed mode hash; do
        if [[ ! "$label" =~ ^[a-z0-9_-]+$ ]] || ! owned_path_allowed "$path"; then rc=1; continue; fi
        secure_target_parent "$path" || { rc=1; continue; }
        after_hash=$(owned_after_hash "$transaction" "$label" 2>/dev/null || true)
        after_inode=$(owned_after_inode "$transaction" "$label" 2>/dev/null || true)
        after_mode=$(owned_after_mode "$transaction" "$label" 2>/dev/null || true)
        if [[ "$existed" == 1 ]]; then
            source="$transaction/files/$label.before"
            [[ -f "$source" && $(sha256sum "$source" | awk '{print $1}') == "$hash" ]] || { rc=1; continue; }
            if [[ ! -e "$path" || -L "$path" || ! -f "$path" ]]; then
                warn "$path 已被删除或替换为不安全类型；回滚跳过。"; rc=1; continue
            fi
            if ! secure_owned_file "$path"; then
                warn "$path 的所有权或写权限已变化；回滚跳过。"; rc=1; continue
            fi
            current_hash=$(sha256sum "$path" | awk '{print $1}' 2>/dev/null || true)
            if [[ "$current_hash" == "$hash" ]]; then
                continue
            elif [[ -n "$after_hash" && "$current_hash" == "$after_hash" ]] && managed_file_has_marker "$path"; then
                if [[ -n "$after_inode" || -n "$after_mode" ]]; then
                    current_inode=$(stat -c %i "$path" 2>/dev/null || true)
                    current_mode=$(stat -c %a "$path" 2>/dev/null || true)
                    if [[ ! "$after_inode" =~ ^[1-9][0-9]*$ || ! "$after_mode" =~ ^[0-7]{3,4}$ ||
                          "$current_inode" != "$after_inode" || "$current_mode" != "$after_mode" ]]; then
                        warn "$path 的事务后 inode/权限已发生漂移；回滚跳过。"
                        rc=1
                        continue
                    fi
                fi
                if atomic_install "$source" "$path" "0$mode"; then
                    :
                else
                    rc=1
                fi
            else
                warn "$path 的内容已在 apply 后变化；回滚跳过该文件。"
                transaction_append_mutable_line "$transaction" apply.warnings \
                    "file $path ownership hash changed; rollback skipped owned file" 2>/dev/null || true
                rc=1
            fi
        elif [[ "$existed" == 0 ]]; then
            [[ ! -e "$path" && ! -L "$path" ]] && continue
            if [[ -L "$path" || ! -f "$path" ]]; then
                warn "$path 已变为不安全类型；回滚跳过。"; rc=1; continue
            fi
            if ! secure_owned_file "$path"; then
                warn "$path 的所有权或写权限已变化；回滚跳过。"; rc=1; continue
            fi
            current_hash=$(sha256sum "$path" | awk '{print $1}' 2>/dev/null || true)
            if [[ -n "$after_hash" && "$current_hash" == "$after_hash" ]] && managed_file_has_marker "$path"; then
                if [[ -n "$after_inode" || -n "$after_mode" ]]; then
                    current_inode=$(stat -c %i "$path" 2>/dev/null || true)
                    current_mode=$(stat -c %a "$path" 2>/dev/null || true)
                    if [[ ! "$after_inode" =~ ^[1-9][0-9]*$ || ! "$after_mode" =~ ^[0-7]{3,4}$ ||
                          "$current_inode" != "$after_inode" || "$current_mode" != "$after_mode" ]]; then
                        warn "$path 的事务后 inode/权限已发生漂移；回滚跳过删除。"
                        rc=1
                        continue
                    fi
                fi
                if rm -f -- "$path"; then
                    if [[ "$path" == "${ETC_ROOT}/systemd/system/"* ]]; then
                        rmdir --ignore-fail-on-non-empty "$(dirname "$path")" 2>/dev/null || true
                    fi
                else
                    rc=1
                fi
            else
                warn "$path 不是本事务最后写入的已验证内容；回滚跳过删除。"
                transaction_append_mutable_line "$transaction" apply.warnings \
                    "file $path ownership hash changed; rollback skipped removal" 2>/dev/null || true
                rc=1
            fi
        else
            rc=1
        fi
    done < "$records"
    return "$rc"
}

capture_qdisc_state() {
    local peers_tsv="$1" output="$2" _host _port _family _address _source iface _fingerprint _route_unambiguous kind qdisc_hash restore_spec
    [[ -r "$peers_tsv" ]] || return 1
    : > "$output" || return 1
    while IFS=$'\t' read -r _host _port _family _address _source iface _fingerprint _route_unambiguous; do
        awk -F'\t' -v iface="$iface" '$1==iface{found=1} END{exit !found}' "$output" && continue
        kind=$(interface_qdisc_kind "$iface" 2>/dev/null || true)
        qdisc_hash=$(qdisc_root_fingerprint "$iface" 2>/dev/null || true)
        restore_spec=$(qdisc_root_restore_spec "$iface" 2>/dev/null || true)
        [[ "$kind" =~ ^[A-Za-z0-9_-]+$ && "$qdisc_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
        # Safe mode may encounter a qdisc outside the fresh-mode whitelist;
        # it is never changed by this tool.  Keep its authenticated kind and
        # fingerprint, and mark the optional replay field unavailable rather
        # than refusing an otherwise unrelated sysctl apply.
        [[ -n "$restore_spec" ]] || restore_spec=-
        [[ "$restore_spec" == - ]] || qdisc_spec_is_safe "$restore_spec" || return 1
        # Keep both the restore target and its authenticated pre-change
        # fingerprint and a replayable, allowlisted root specification.  A
        # kind alone is not enough to restore parameters after a live swap.
        printf '%s\t%s\t%s\t%s\n' "$iface" "$kind" "$qdisc_hash" "$restore_spec" >> "$output" || return 1
    done < "$peers_tsv"
    chmod 0600 "$output" || return 1
}

baseline_identity_path() {
    local initial="$STATE_DIR/baseline/initial"
    printf '%s/identity.tsv\n' "$initial"
}

baseline_identity_hash_file() {
    printf '%s/baseline/initial.identity.tsv.sha256\n' "$STATE_DIR"
}

baseline_expected_files() {
    printf '%s\n' runtime.tsv qdisc.tsv routes.tsv metadata created_at manifest.sha256
}

baseline_identity_write() {
    local initial="$1" identity record="${2:-}" relative file hash inode mode
    local temp
    [[ -d "$initial" && ! -L "$initial" && "$initial" == "$STATE_DIR/baseline/"* ]] || return 1
    identity="$initial/identity.tsv"
    [[ -n "$record" ]] || record="$(dirname -- "$initial")/initial.identity.tsv.sha256"
    [[ "$record" == "$STATE_DIR/baseline/"* ]] || return 1
    trusted_tmp_dir || return 1
    temp=$(mktemp "$identity.tmp.XXXXXXXX") || return 1
    while IFS= read -r relative; do
        file="$initial/$relative"
        [[ -f "$file" && ! -L "$file" ]] || { rm -f -- "$temp"; return 1; }
        hash=$(sha256sum "$file" | awk '{print $1}') || { rm -f -- "$temp"; return 1; }
        inode=$(stat -c %i "$file" 2>/dev/null || true)
        mode=$(stat -c %a "$file" 2>/dev/null || true)
        [[ "$hash" =~ ^[0-9a-f]{64}$ && "$inode" =~ ^[0-9]+$ && "$mode" == 600 ]] || {
            rm -f -- "$temp"; return 1;
        }
        printf '%s\t%s\t%s\t%s\n' "$relative" "$inode" "$mode" "$hash" >> "$temp" || {
            rm -f -- "$temp"; return 1;
        }
    done < <(baseline_expected_files)
    chmod 0600 "$temp" || { rm -f -- "$temp"; return 1; }
    atomic_install "$temp" "$identity" 0600 || { rm -f -- "$temp"; return 1; }
    rm -f -- "$temp"
    write_private_hash_record "$identity" "$record"
}

baseline_identity_is_current() {
    local initial="$1" identity record="${2:-}" record_relative="" relative inode mode hash extra file current_hash current_inode current_mode
    local -A seen=()
    [[ -d "$initial" && ! -L "$initial" && "$initial" == "$STATE_DIR/baseline/"* ]] || return 1
    identity="$initial/identity.tsv"
    [[ -n "$record" ]] || record="$(dirname -- "$initial")/initial.identity.tsv.sha256"
    [[ "$record" == "$STATE_DIR/baseline/"* ]] || return 1
    if [[ "$record" == "$initial/"* ]]; then
        record_relative=${record#"$initial/"}
        [[ "$record_relative" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    fi
    [[ -f "$identity" && ! -L "$identity" && -f "$record" && ! -L "$record" ]] || return 1
    [[ "$(stat -c %a "$identity" 2>/dev/null || true)" == 600 ]] || return 1
    [[ "$(stat -c %a "$record" 2>/dev/null || true)" == 600 ]] || return 1
    verify_private_hash_record "$identity" "$record" || return 1
    while IFS=$'\t' read -r relative inode mode hash extra || [[ -n "${relative:-}" ]]; do
        [[ -n "$relative" && -z "${extra:-}" && -z "${seen[$relative]+x}" ]] || return 1
        case "$relative" in
            runtime.tsv|qdisc.tsv|routes.tsv|metadata|created_at|manifest.sha256) ;;
            *) return 1 ;;
        esac
        seen[$relative]=1
        file="$initial/$relative"
        [[ -f "$file" && ! -L "$file" ]] || return 1
        [[ "$inode" =~ ^[0-9]+$ && "$mode" == 600 && "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
        current_inode=$(stat -c %i "$file" 2>/dev/null || true)
        current_mode=$(stat -c %a "$file" 2>/dev/null || true)
        current_hash=$(sha256sum "$file" | awk '{print $1}' 2>/dev/null || true)
        [[ "$current_inode" == "$inode" && "$current_mode" == "$mode" && "$current_hash" == "$hash" ]] || return 1
    done < "$identity"
    while IFS= read -r relative; do
        [[ -n "${seen[$relative]+x}" ]] || return 1
    done < <(baseline_expected_files)
    [[ -z "$(find "$initial" -mindepth 1 -type d -print -quit 2>/dev/null)" ]] || return 1
    [[ -z "$(find "$initial" -mindepth 1 -type l -print -quit 2>/dev/null)" ]] || return 1
    while IFS= read -r -d '' file; do
        relative=${file#"$initial"/}
        case "$relative" in
            identity.tsv|runtime.tsv|qdisc.tsv|routes.tsv|metadata|created_at|manifest.sha256) ;;
            "$record_relative") ;;
            *) return 1 ;;
        esac
    done < <(find "$initial" -mindepth 1 -type f -print0 2>/dev/null)
}

discard_initial_baseline_staging() {
    local staging name rc=0
    local -a staged=()
    shopt -s nullglob
    staged=("$STATE_DIR/baseline"/.initial.????????)
    shopt -u nullglob
    for staging in "${staged[@]}"; do
        name=$(basename -- "$staging") || return 1
        [[ "$name" =~ ^\.initial\.[A-Za-z0-9]{8}$ ]] || return 1
        [[ -d "$staging" && ! -L "$staging" ]] || return 1
        if rm -rf -- "$staging" && [[ ! -e "$staging" && ! -L "$staging" ]]; then
            :
        else
            rc=1
        fi
    done
    return "$rc"
}

discard_new_initial_baseline_material() {
    local initial="$STATE_DIR/baseline/initial" identity_record staging_rc=0
    identity_record=$(baseline_identity_hash_file) || return 1
    [[ "$initial" == "$STATE_DIR/baseline/initial" && "$identity_record" == "$STATE_DIR/baseline/"* ]] || return 1
    discard_initial_baseline_staging || staging_rc=1
    if [[ -e "$initial" || -L "$initial" ]]; then
        [[ -d "$initial" && ! -L "$initial" ]] || return 1
        rm -rf -- "$initial" || return 1
    fi
    if [[ -e "$identity_record" || -L "$identity_record" ]]; then
        [[ -f "$identity_record" && ! -L "$identity_record" ]] || return 1
        rm -f -- "$identity_record" || return 1
    fi
    [[ ! -e "$initial" && ! -L "$initial" && ! -e "$identity_record" && ! -L "$identity_record" ]] || return 1
    (( staging_rc == 0 ))
}

create_initial_baseline() {
    local run_dir="$1" run_id initial="$STATE_DIR/baseline/initial" temp uid mode path identity_record published=0
    run_id=$(basename -- "$run_dir")
    validate_run_id "$run_id" || { die '首次 baseline 的 run ID 无效。'; return 1; }
    if [[ -e "$initial" || -L "$initial" ]]; then
        if (( APPLY_BASELINE_EXPECT_NEW )); then
            # The caller observed no baseline immediately before publishing the
            # prepared transaction.  If one appears before this point, it may
            # belong to an administrator or another interrupted operation; do
            # not validate it as ours and never let compensation remove it.
            APPLY_BASELINE_CREATED=0
            die '首次 baseline 在 apply 期间出现；无法证明其来源，拒绝接管。'
            return 1
        fi
        [[ -d "$initial" && ! -L "$initial" ]] || { die '首次 baseline 类型不安全。'; return 1; }
        uid=$(stat -c %u "$initial" 2>/dev/null || true)
        mode=$(stat -c %a "$initial" 2>/dev/null || true)
        [[ "$uid" == 0 && "$mode" == 700 ]] || { die '首次 baseline 必须由 root 拥有且权限为 0700。'; return 1; }
        if [[ -e "$initial/metadata" || -L "$initial/metadata" ]]; then
            [[ -f "$initial/metadata" && ! -L "$initial/metadata" ]] || { die '首次 baseline metadata 类型不安全。'; return 1; }
            secure_private_path "$initial/metadata" || { die '首次 baseline metadata 权限不安全。'; return 1; }
            if managed_file_has_current_metadata "$initial/metadata"; then
                baseline_identity_is_current "$initial" || { die '首次 baseline identity 校验失败。'; return 1; }
            else
                managed_file_has_marker "$initial/metadata" || { die '首次 baseline metadata 版本或所有权不受支持。'; return 1; }
            fi
        fi
        verify_hash_manifest "$initial" "$initial/manifest.sha256" || { die '首次 baseline manifest 校验失败。'; return 1; }
        return 0
    fi
    identity_record=$(baseline_identity_hash_file) || return 1
    [[ ! -e "$identity_record" && ! -L "$identity_record" ]] || {
        die '首次 baseline 缺失但 identity 哈希 sidecar 仍存在；拒绝接管并保留证据。'; return 1;
    }
    # A v1 installation may already own these paths.  A stable ownership
    # marker is enough to prove that this first v2 transaction can snapshot and
    # replace them; an unmarked file (or any symlink) remains a hard refusal.
    for path in "$SYSCTL_FILE" "$MODULES_FILE"; do
        if [[ -e "$path" || -L "$path" ]]; then
            if [[ ! -f "$path" || -L "$path" ]] || ! managed_file_is_known_owned "$path"; then
                die "首次应用前发现无所有权标记的工具路径；无法证明所有权，拒绝接管: $path"; return 1;
            fi
        fi
    done
    temp=$(mktemp -d "$STATE_DIR/baseline/.initial.XXXXXXXX") || return 1
    if ! chmod 0700 "$temp" ||
       ! capture_runtime "$temp/runtime.tsv" ||
       ! capture_qdisc_state "$run_dir/peers.tsv" "$temp/qdisc.tsv" ||
       ! install -m 0600 "$run_dir/peers.tsv" "$temp/routes.tsv" ||
       ! { managed_marker; managed_metadata "$run_id"; } > "$temp/metadata" ||
       ! chmod 0600 "$temp/metadata" ||
       ! printf '%s\n' "$(date -u +%FT%TZ)" > "$temp/created_at" ||
       ! chmod 0600 "$temp/created_at" ||
       ! create_hash_manifest "$temp" "$temp/manifest.sha256" ||
       ! verify_hash_manifest "$temp" "$temp/manifest.sha256" ||
       ! baseline_identity_write "$temp" "$temp/identity.sha256" ||
       ! baseline_identity_is_current "$temp" "$temp/identity.sha256"; then
        discard_initial_baseline_staging || warn "无法清理失败的 baseline 暂存目录；保留证据: $temp"
        die '无法原子创建并验证首次 baseline。'
        return 1
    fi
    if ! mv -T -- "$temp" "$initial"; then
        discard_initial_baseline_staging || warn "无法清理未发布的 baseline 暂存目录；保留证据: $temp"
        die '无法发布首次 baseline 目录。'
        return 1
    fi
    published=1
    if ! mv -T -- "$initial/identity.sha256" "$identity_record"; then
        if (( published )) && ! discard_new_initial_baseline_material; then
            warn '首次 baseline identity 发布失败且无法清理新建材料；保留不完整 baseline 作为恢复证据。'
        fi
        die '无法发布首次 baseline identity 哈希。'
        return 1
    fi
}

transaction_mutable_hash_record() {
    local transaction="$1" name="$2"
    [[ "$transaction" == "$STATE_DIR/transactions/"* ]] || return 1
    case "$name" in
        changes.tsv|apply.warnings|apply.json)
            printf '%s/%s.sha256\n' "$transaction" "$name"
            ;;
        *) return 1 ;;
    esac
}

transaction_mutable_file_is_current() {
    local transaction="$1" name="$2" path record format
    path="$transaction/$name"
    record=$(transaction_mutable_hash_record "$transaction" "$name") || return 1
    format=$(transaction_get "$transaction" FORMAT_VERSION 2>/dev/null || true)
    case "$format" in
        "$STATE_FORMAT_VERSION")
            if [[ -e "$path" || -L "$path" ]]; then
                [[ -f "$path" && ! -L "$path" && -f "$record" && ! -L "$record" ]] || return 1
                verify_private_hash_record "$path" "$record"
            else
                [[ ! -e "$record" && ! -L "$record" ]]
            fi
            ;;
        '')
            # Terminal v1 transactions are readable, but their mutable views
            # have no sidecar and are never upgraded in place by recovery.
            [[ ! -e "$record" && ! -L "$record" ]] || return 1
            if [[ -e "$path" || -L "$path" ]]; then
                [[ -f "$path" && ! -L "$path" ]] || return 1
                secure_owned_file "$path"
            fi
            ;;
        *) return 1 ;;
    esac
}

transaction_append_mutable_line() {
    local transaction="$1" name="$2" line="$3" path record format
    [[ "$line" != *$'\n'* && "$line" != *$'\r'* ]] || return 1
    path="$transaction/$name"
    record=$(transaction_mutable_hash_record "$transaction" "$name") || return 1
    transaction_mutable_file_is_current "$transaction" "$name" || return 1
    [[ -f "$path" && ! -L "$path" ]] || return 1
    printf '%s\n' "$line" >> "$path" || return 1
    format=$(transaction_get "$transaction" FORMAT_VERSION 2>/dev/null || true)
    if [[ "$format" == "$STATE_FORMAT_VERSION" ]]; then
        write_private_hash_record "$path" "$record" || return 1
    fi
}

transaction_replace_mutable_file() {
    local transaction="$1" name="$2" source="$3" mode="${4:-0600}" path record format
    path="$transaction/$name"
    record=$(transaction_mutable_hash_record "$transaction" "$name") || return 1
    [[ -f "$source" && ! -L "$source" ]] || return 1
    transaction_mutable_file_is_current "$transaction" "$name" || return 1
    atomic_install "$source" "$path" "$mode" || return 1
    format=$(transaction_get "$transaction" FORMAT_VERSION 2>/dev/null || true)
    if [[ "$format" == "$STATE_FORMAT_VERSION" ]]; then
        write_private_hash_record "$path" "$record" || return 1
    fi
}

transaction_artifacts_are_known() {
    local transaction="$1" entry kind relative path list_file failed=0
    [[ -d "$transaction" && ! -L "$transaction" ]] || return 1
    trusted_tmp_dir || return 1
    list_file=$(mktemp "/tmp/vps-proxy-tune-transaction-tree.XXXXXXXX") || return 1
    if ! find "$transaction" -mindepth 1 -printf '%y\t%P\0' > "$list_file"; then
        rm -f -- "$list_file"
        return 1
    fi
    while IFS= read -r -d '' entry; do
        kind=${entry%%$'\t'*}
        relative=${entry#*$'\t'}
        path="$transaction/$relative"
        case "$kind:$relative" in
            d:files|d:postverify)
                [[ -d "$path" && ! -L "$path" ]] || { failed=1; break; }
                ;;
            f:status|f:status.lock|f:status.sha256|f:meta.tsv|f:meta.sha256|f:snapshot.sha256|\
            f:runtime.before.tsv|f:desired.tsv|f:files.tsv|f:files.identity.tsv|\
            f:guard-script.sh|f:changes.tsv|f:changes.tsv.sha256|\
            f:apply.warnings|f:apply.warnings.sha256|f:apply.json|f:apply.json.sha256|\
            f:modules.conf|f:service.conf|\
            f:files/sysctl.before|f:files/modules.before|f:files/service.before|\
            f:postverify/ping.idle|f:postverify/ping.loaded|\
            f:postverify/upload.json|f:postverify/upload.json.stderr|\
            f:postverify/download.json|f:postverify/download.json.stderr|\
            f:postverify/udp-upload.json|f:postverify/udp-upload.json.stderr|\
            f:postverify/udp-download.json|f:postverify/udp-download.json.stderr)
                [[ -f "$path" && ! -L "$path" ]] || { failed=1; break; }
                ;;
            *)
                failed=1
                break
                ;;
        esac
        secure_private_path "$path" || { failed=1; break; }
    done < "$list_file"
    if ! rm -f -- "$list_file"; then
        return 1
    fi
    (( failed == 0 ))
}

transaction_snapshot_is_valid() {
    local transaction="$1" expected mutable_name run previous status run_count previous_count key _value extra count=0
    local mode service apply_pid apply_start qdisc_changed qdisc_iface qdisc_before qdisc_before_spec qdisc_before_hash qdisc_after_hash guard_unit format_version writer_version
    local label path existed hash source identity_record identity_label identity_path identity_existed identity_inode identity_mode identity_hash identity_extra
    local file_record file_label file_path file_existed file_mode file_hash file_extra identity_count=0
    local -A immutable_meta=() seen_file_labels=() seen_file_existed=() seen_file_paths=() seen_identity_labels=()
    [[ -d "$transaction" && ! -L "$transaction" ]] || return 1
    secure_private_path "$transaction" || return 1
    transaction_artifacts_are_known "$transaction" || return 1
    [[ -d "$transaction/files" && ! -L "$transaction/files" ]] || return 1
    secure_private_path "$transaction/files" || return 1
    for expected in status status.lock meta.tsv snapshot.sha256 runtime.before.tsv desired.tsv files.tsv guard-script.sh; do
        [[ -f "$transaction/$expected" && ! -L "$transaction/$expected" ]] || return 1
        secure_private_path "$transaction/$expected" || return 1
    done
    verify_hash_manifest "$transaction" "$transaction/snapshot.sha256" || return 1
    while IFS=$'\t' read -r key _value extra || [[ -n "${key:-}" ]]; do
        [[ "$key" =~ ^[A-Z0-9_]+$ && -z "${extra:-}" ]] || return 1
        # meta.tsv is an append-only WAL: values whose runtime identity is
        # learned during apply (for example SYSCTL_HASH) may be written more
        # than once, while chain identity and ownership anchors must never be
        # ambiguous.  Reject duplicate immutable fields but retain the WAL
        # update semantics for mutable fields.
        case "$key" in
            RUN_ID|PREVIOUS_RUN|MODE|SERVICE|APPLY_PID|APPLY_STARTTIME|QDISC_IFACE|QDISC_BEFORE|QDISC_BEFORE_SPEC|QDISC_BEFORE_HASH|SERVICE_PREVIOUS_HASH|MANAGED_BY|FORMAT_VERSION|WRITER_VERSION)
                [[ -z "${immutable_meta[$key]+x}" ]] || return 1
                immutable_meta[$key]=1
                ;;
        esac
        count=$((count + 1)); (( count <= 128 )) || return 1
    done < "$transaction/meta.tsv"
    # Validate the file/runtime payloads before any recovery path consumes
    # them.  The manifest authenticates bytes, but it does not by itself prove
    # that a record names one of the tool-owned targets or that two records do
    # not alias the same target.
    while IFS=$'\t' read -r label path existed mode hash extra || [[ -n "${label:-}" ]]; do
        [[ "$label" =~ ^(sysctl|modules|service)$ && -z "${extra:-}" ]] || return 1
        [[ -z "${seen_file_labels[$label]+x}" && -z "${seen_file_paths[$path]+x}" ]] || return 1
        owned_path_allowed "$path" || return 1
        case "$existed" in
            1)
                [[ "$mode" =~ ^[0-7]{3,4}$ && "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
                source="$transaction/files/$label.before"
                [[ -f "$source" && ! -L "$source" ]] || return 1
                ;;
            0) [[ "$mode" == - && "$hash" == - ]] || return 1 ;;
            *) return 1 ;;
        esac
        seen_file_labels[$label]=1
        seen_file_existed[$label]=$existed
        seen_file_paths[$path]=1
    done < "$transaction/files.tsv"
    if [[ -e "$transaction/files.identity.tsv" || -L "$transaction/files.identity.tsv" ]]; then
        [[ -f "$transaction/files.identity.tsv" && ! -L "$transaction/files.identity.tsv" ]] || return 1
        [[ "$(stat -c %a "$transaction/files.identity.tsv" 2>/dev/null || true)" == 600 ]] || return 1
        secure_private_path "$transaction/files.identity.tsv" || return 1
        awk '$2=="files.identity.tsv"{found=1} END{exit !found}' "$transaction/snapshot.sha256" || return 1
        while IFS=$'\t' read -r identity_label identity_path identity_existed identity_inode identity_mode identity_hash identity_extra || [[ -n "${identity_label:-}" ]]; do
            [[ "$identity_label" =~ ^(sysctl|modules|service)$ && -z "${identity_extra:-}" ]] || return 1
            [[ -z "${seen_identity_labels[$identity_label]+x}" ]] || return 1
            file_record=$(awk -F'\t' -v label="$identity_label" '$1==label{print;found=1;exit} END{if(!found)exit 1}' "$transaction/files.tsv") || return 1
            IFS=$'\t' read -r file_label file_path file_existed file_mode file_hash file_extra <<< "$file_record"
            [[ "$file_label" == "$identity_label" && "$file_path" == "$identity_path" &&
               "$file_existed" == "$identity_existed" && "$file_mode" == "$identity_mode" &&
               "$file_hash" == "$identity_hash" && -z "${file_extra:-}" ]] || return 1
            owned_path_allowed "$identity_path" || return 1
            case "$identity_existed" in
                1) [[ "$identity_inode" =~ ^[1-9][0-9]*$ && "$identity_mode" =~ ^[0-7]{3,4}$ && "$identity_hash" =~ ^[0-9a-f]{64}$ ]] || return 1 ;;
                0) [[ "$identity_inode" == - && "$identity_mode" == - && "$identity_hash" == - ]] || return 1 ;;
                *) return 1 ;;
            esac
            seen_identity_labels[$identity_label]=1
            identity_count=$((identity_count + 1)); (( identity_count <= 3 )) || return 1
        done < "$transaction/files.identity.tsv"
        for identity_label in "${!seen_file_labels[@]}"; do
            [[ -n "${seen_identity_labels[$identity_label]+x}" ]] || return 1
        done
        for identity_label in "${!seen_identity_labels[@]}"; do
            [[ -n "${seen_file_labels[$identity_label]+x}" ]] || return 1
        done
    fi
    while IFS=$'\t' read -r key _value extra || [[ -n "${key:-}" ]]; do
        [[ -n "$key" && -n "${_value:-}" && -z "${extra:-}" ]] || return 1
        record_field_is_safe "$key" && record_field_is_safe "$_value" || return 1
        is_target_sysctl_key "$key" || return 1
        [[ "$_value" =~ ^[A-Za-z0-9_.[:space:]-]+$ ]] || return 1
    done < "$transaction/runtime.before.tsv"
    while IFS=$'\t' read -r key _value _before _reason change_type extra || [[ -n "${key:-}" ]]; do
        [[ -n "$key" && -n "${_value:-}" && -n "${_before:-}" && -n "${_reason:-}" && -z "${extra:-}" ]] || return 1
        record_field_is_safe "$key" && record_field_is_safe "$_value" &&
            record_field_is_safe "$_before" && record_field_is_safe "$_reason" &&
            record_field_is_safe "$change_type" || return 1
        is_target_sysctl_key "$key" || return 1
        [[ "$_value" =~ ^[A-Za-z0-9_.[:space:]-]+$ ]] || return 1
        plan_change_type "$change_type" >/dev/null || return 1
    done < "$transaction/desired.tsv"
    shopt -s nullglob
    local -a snapshot_files=("$transaction/files"/*.before)
    shopt -u nullglob
    for expected in "${snapshot_files[@]}"; do
        secure_private_path "$expected" || return 1
        file_label=$(basename -- "$expected")
        file_label=${file_label%.before}
        [[ "${seen_file_existed[$file_label]:-0}" == 1 ]] || return 1
    done
    expected=$(basename "$transaction")
    validate_run_id "$expected" || return 1
    status=$(cat "$transaction/status" 2>/dev/null || true)
    [[ "$status" =~ ^(prepared|applying|pending-confirm|guard-restoring|committed|rollback-failed|rolled-back)$ ]] || return 1
    format_version=$(transaction_get "$transaction" FORMAT_VERSION 2>/dev/null || true)
    writer_version=$(transaction_get "$transaction" WRITER_VERSION 2>/dev/null || true)
    if [[ -z "$format_version" && -z "$writer_version" ]]; then
        # Terminal v1 transactions did not carry explicit writer metadata and
        # remain readable for audit/rollback.  Live legacy transactions are
        # not safe to recover without an authenticated writer version.
        [[ "$status" == committed || "$status" == rolled-back ]] || return 1
    else
        [[ "$format_version" == "$STATE_FORMAT_VERSION" ]] || return 1
        [[ "$writer_version" =~ ^2[.][0-9]+[.][0-9]+$ ]] || return 1
        [[ "$(transaction_get "$transaction" MANAGED_BY 2>/dev/null || true)" == "$OWNER_ID" ]] || return 1
        [[ -f "$transaction/meta.sha256" && ! -L "$transaction/meta.sha256" &&
           -f "$transaction/status.sha256" && ! -L "$transaction/status.sha256" ]] || return 1
        verify_private_hash_record "$transaction/meta.tsv" "$transaction/meta.sha256" || return 1
        verify_private_hash_record "$transaction/status" "$transaction/status.sha256" || return 1
        for mutable_name in changes.tsv apply.warnings; do
            [[ -f "$transaction/$mutable_name" && ! -L "$transaction/$mutable_name" ]] || return 1
            secure_private_path "$transaction/$mutable_name" || return 1
            [[ -f "$transaction/$mutable_name.sha256" && ! -L "$transaction/$mutable_name.sha256" ]] || return 1
            verify_private_hash_record "$transaction/$mutable_name" "$transaction/$mutable_name.sha256" || return 1
        done
        if [[ -e "$transaction/apply.json" || -L "$transaction/apply.json" ||
              -e "$transaction/apply.json.sha256" || -L "$transaction/apply.json.sha256" ]]; then
            transaction_mutable_file_is_current "$transaction" apply.json || return 1
        fi
    fi
    run=$(transaction_get "$transaction" RUN_ID 2>/dev/null || true)
    [[ "$run" == "$expected" ]] || return 1
    run_count=$(awk -F'\t' '$1=="RUN_ID"{n++} END{print n+0}' "$transaction/meta.tsv") || return 1
    previous_count=$(awk -F'\t' '$1=="PREVIOUS_RUN"{n++} END{print n+0}' "$transaction/meta.tsv") || return 1
    [[ "$run_count" == 1 && "$previous_count" == 1 ]] || return 1
    previous=$(transaction_get "$transaction" PREVIOUS_RUN 2>/dev/null || true)
    [[ -z "$previous" ]] || validate_run_id "$previous" || return 1
    mode=$(transaction_get "$transaction" MODE 2>/dev/null || true)
    [[ "$mode" == safe || "$mode" == fresh ]] || return 1
    service=$(transaction_get "$transaction" SERVICE 2>/dev/null || true)
    [[ -z "$service" ]] || validate_unit "$service" || return 1
    local identity_key identity_value
    for identity_key in SYSCTL_INODE MODULES_INODE SERVICE_INODE; do
        identity_value=$(transaction_get "$transaction" "$identity_key" 2>/dev/null || true)
        [[ -z "$identity_value" || "$identity_value" =~ ^[1-9][0-9]*$ ]] || return 1
    done
    for identity_key in SYSCTL_MODE MODULES_MODE SERVICE_MODE; do
        identity_value=$(transaction_get "$transaction" "$identity_key" 2>/dev/null || true)
        [[ -z "$identity_value" || "$identity_value" =~ ^[0-7]{3,4}$ ]] || return 1
    done
    apply_pid=$(transaction_get "$transaction" APPLY_PID 2>/dev/null || true)
    apply_start=$(transaction_get "$transaction" APPLY_STARTTIME 2>/dev/null || true)
    # v1 transactions predate the apply-owner fields.  Terminal snapshots do
    # not need those fields to be recoverable, so accept the legacy omission;
    # every live/incomplete state still requires a positive PID plus start time
    # to prevent killing a reused process during recovery.
    if [[ -z "$apply_pid" && -z "$apply_start" && ( "$status" == committed || "$status" == rolled-back ) ]]; then
        :
    else
        is_positive_uint "$apply_pid" || return 1
        is_positive_uint "$apply_start" || return 1
    fi
    qdisc_changed=$(transaction_get "$transaction" QDISC_CHANGED 2>/dev/null || true)
    is_bool01 "$qdisc_changed" || return 1
    if [[ "$qdisc_changed" == 1 ]]; then
        qdisc_iface=$(transaction_get "$transaction" QDISC_IFACE 2>/dev/null || true)
        qdisc_before=$(transaction_get "$transaction" QDISC_BEFORE 2>/dev/null || true)
        qdisc_before_spec=$(transaction_get "$transaction" QDISC_BEFORE_SPEC 2>/dev/null || true)
        qdisc_before_hash=$(transaction_get "$transaction" QDISC_BEFORE_HASH 2>/dev/null || true)
        qdisc_after_hash=$(transaction_get "$transaction" QDISC_AFTER_HASH 2>/dev/null || true)
        [[ "$qdisc_iface" =~ ^[A-Za-z0-9_.:-]{1,15}$ && "$qdisc_before" =~ ^(fq_codel|pfifo_fast)$ &&
           "$qdisc_before_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
        # v2 qdisc transactions carry a replayable allowlisted specification.
        # A terminal v1 transaction may omit it and remains readable for
        # controlled migration, but new/live records must never fall back to
        # restoring only the qdisc kind.
        if [[ -n "$qdisc_before_spec" ]]; then
            qdisc_spec_is_safe "$qdisc_before_spec" || return 1
        elif [[ -n "$format_version" ]]; then
            return 1
        fi
        [[ -z "$qdisc_after_hash" || "$qdisc_after_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
    fi
    guard_unit=$(transaction_get "$transaction" GUARD_UNIT 2>/dev/null || true)
    [[ -z "$guard_unit" || "$guard_unit" =~ ^vps-proxy-tune-guard-[A-Za-z0-9-]{1,120}$ ]] || return 1
    if [[ "$status" == committed || "$status" == pending-confirm ]]; then
        [[ $(transaction_get "$transaction" SYSCTL_HASH 2>/dev/null || true) =~ ^[0-9a-f]{64}$ ]] || return 1
        [[ -f "$transaction/apply.json" && ! -L "$transaction/apply.json" ]] || return 1
        secure_private_path "$transaction/apply.json" || return 1
        if [[ "$format_version" == "$STATE_FORMAT_VERSION" ]]; then
            transaction_mutable_file_is_current "$transaction" apply.json || return 1
        fi
        [[ "$qdisc_changed" == 0 || "$qdisc_after_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
    fi
}

validate_transaction_chain() {
    # With an optional argument, validate the chain while allowing exactly one
    # recovery target (an incomplete transaction, or a rolled-back head whose
    # pointer still needs repair).  This matters for a crash after
    # publishing a prepared directory but before linking it from current_run:
    # recovery may adopt that one predecessor-linked orphan, but must still
    # reject unrelated orphan commits or a second incomplete transaction.
    local allowed_incomplete="${1:-}" current="" transaction status previous name head="" head_status=""
    local -A reachable=()
    local -a transactions=()
    [[ -z "$allowed_incomplete" ]] || validate_run_id "$allowed_incomplete" || return 1
    if [[ -e "$STATE_DIR/current_run" || -L "$STATE_DIR/current_run" ]]; then
        [[ -f "$STATE_DIR/current_run" && ! -L "$STATE_DIR/current_run" ]] || return 1
        secure_private_path "$STATE_DIR/current_run" || return 1
        current=$(cat "$STATE_DIR/current_run") || return 1
        validate_run_id "$current" || return 1
        head="$current"
    fi
    while [[ -n "$current" ]]; do
        [[ -z "${reachable[$current]+x}" ]] || return 1
        reachable[$current]=1
        transaction="$STATE_DIR/transactions/$current"
        transaction_snapshot_is_valid "$transaction" || return 1
        status=$(cat "$transaction/status" 2>/dev/null || true)
        if [[ "$current" == "$head" && "$status" == pending-confirm ]]; then
            :
        elif [[ -n "$allowed_incomplete" && "$current" == "$allowed_incomplete" &&
                ( "$status" =~ ^(prepared|applying|pending-confirm|guard-restoring|rollback-failed)$ ||
                  ( "$status" == rolled-back && "$current" == "$head" ) ) ]]; then
            :
        else
            [[ "$status" == committed ]] || return 1
        fi
        previous=$(transaction_get "$transaction" PREVIOUS_RUN 2>/dev/null || true)
        [[ -z "$previous" ]] || validate_run_id "$previous" || return 1
        current=$previous
    done
    shopt -s nullglob
    # Include dot-prefixed transaction entries as well.  Staging directories
    # are explicitly ignored below, while an unknown hidden entry must fail
    # closed instead of disappearing behind a normal `*` glob.
    transactions=("$STATE_DIR"/transactions/* "$STATE_DIR"/transactions/.[!.]* "$STATE_DIR"/transactions/..?*)
    shopt -u nullglob
    for transaction in "${transactions[@]}"; do
        name=$(basename "$transaction")
        # A crash can leave the private mktemp staging directory behind before
        # the final atomic rename.  It is not a published transaction and must
        # not make recovery of the real chain impossible; unknown directory
        # names remain fail-closed below.
        if transaction_staging_name "$name"; then
            [[ -d "$transaction" && ! -L "$transaction" ]] || return 1
            continue
        fi
        validate_run_id "$name" || return 1
        transaction_snapshot_is_valid "$transaction" || return 1
        status=$(cat "$transaction/status" 2>/dev/null || true)
        case "$status" in
            rolled-back) ;;
            committed) [[ -n "${reachable[$name]+x}" ]] || return 1 ;;
            pending-confirm)
                if [[ "$name" == "$head" ]]; then
                    :
                elif [[ "$name" == "$allowed_incomplete" ]]; then
                    previous=$(transaction_get "$transaction" PREVIOUS_RUN 2>/dev/null || true)
                    if [[ -n "$head" ]]; then
                        head_status=$(cat "$STATE_DIR/transactions/$head/status" 2>/dev/null || true)
                        [[ "$head_status" == committed && "$previous" == "$head" ]] || return 1
                    else
                        [[ -z "$previous" ]] || return 1
                    fi
                else
                    return 1
                fi
                ;;
            prepared|applying|guard-restoring|rollback-failed)
                [[ "$name" == "$allowed_incomplete" ]] || return 1
                if [[ -n "${reachable[$name]+x}" ]]; then
                    :
                else
                    previous=$(transaction_get "$transaction" PREVIOUS_RUN 2>/dev/null || true)
                    if [[ -n "$head" ]]; then
                        head_status=$(cat "$STATE_DIR/transactions/$head/status" 2>/dev/null || true)
                        [[ "$head_status" == committed && "$previous" == "$head" ]] || return 1
                    else
                        [[ -z "$previous" ]] || return 1
                    fi
                fi
                ;;
            *) return 1 ;;
        esac
    done
}

registry_contains_service() {
    local unit="$1" registry="$STATE_DIR/owned-services.tsv"
    [[ -r "$registry" ]] && awk -F'\t' -v unit="$unit" '$1==unit{found=1} END{exit !found}' "$registry"
}

registry_service_record() {
    local unit="$1" registry="$STATE_DIR/owned-services.tsv"
    [[ -r "$registry" ]] || return 1
    awk -F'\t' -v unit="$unit" '$1==unit{print;found=1;exit} END{if(!found)exit 1}' "$registry"
}

validate_service_registry() {
    local registry="$STATE_DIR/owned-services.tsv" unit path hash extra
    local -A seen_units=() seen_paths=()
    [[ ! -e "$registry" && ! -L "$registry" ]] && return 0
    [[ -f "$registry" && ! -L "$registry" && -r "$registry" ]] || return 1
    while IFS=$'\t' read -r unit path hash extra; do
        validate_unit "$unit" || return 1
        owned_path_allowed "$path" || return 1
        [[ "$hash" =~ ^[0-9a-f]{64}$ && -z "${extra:-}" ]] || return 1
        [[ -z "${seen_units[$unit]+x}" && -z "${seen_paths[$path]+x}" ]] || return 1
        seen_units[$unit]=1; seen_paths[$path]=1
    done < "$registry"
}

set_service_registry() {
    local unit="$1" path="$2" hash="$3" registry="$STATE_DIR/owned-services.tsv" record temp
    validate_unit "$unit" || return 1
    owned_path_allowed "$path" || return 1
    [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
    record=$(state_hash_file owned-services.tsv) || return 1
    state_hash_pair_is_valid "$registry" "$record" || {
        die '服务所有权 registry 已发生漂移，拒绝覆盖。'; return 1;
    }
    validate_service_registry || return 1
    temp=$(mktemp "$STATE_DIR/.services.XXXXXXXX") || return 1
    if { [[ ! -r "$registry" ]] || awk -F'\t' -v unit="$unit" '$1!=unit' "$registry" > "$temp"; } &&
       printf '%s\t%s\t%s\n' "$unit" "$path" "$hash" >> "$temp" &&
       chmod 0600 "$temp" && atomic_install "$temp" "$registry" 0600; then
        rm -f -- "$temp" || return 1
        [[ ! -e "$temp" && ! -L "$temp" ]] || return 1
        write_private_hash_record "$registry" "$record"
        return $?
    fi
    rm -f -- "$temp"
    return 1
}

unregister_service() {
    local unit="$1" registry="$STATE_DIR/owned-services.tsv" record temp
    record=$(state_hash_file owned-services.tsv) || return 1
    state_hash_pair_is_valid "$registry" "$record" || {
        die '服务所有权 registry 已发生漂移，拒绝覆盖。'; return 1;
    }
    validate_service_registry || return 1
    [[ -r "$registry" ]] || return 0
    temp=$(mktemp "$STATE_DIR/.services.XXXXXXXX") || return 1
    if awk -F'\t' -v unit="$unit" '$1!=unit' "$registry" > "$temp" &&
       chmod 0600 "$temp" && atomic_install "$temp" "$registry" 0600; then
        rm -f -- "$temp" || return 1
        [[ ! -e "$temp" && ! -L "$temp" ]] || return 1
        write_private_hash_record "$registry" "$record"
        return $?
    fi
    rm -f -- "$temp"
    return 1
}

SERVICE_DROPIN_NEEDED=0
SERVICE_DROPIN_PATH=""
SERVICE_LIMIT=0
SERVICE_LIMIT_HARD=""
SERVICE_CURRENT_LIMIT=""
SERVICE_CURRENT_LIMIT_SOFT=""
SERVICE_CURRENT_LIMIT_HARD=""
SERVICE_EFFECTIVE_AFTER=""

prepare_service_change() {
    local unit="$1" load current current_soft current_hard nr_open record registered_path registered_hash extra current_hash
    SERVICE_DROPIN_NEEDED=0; SERVICE_DROPIN_PATH=""; SERVICE_LIMIT=0; SERVICE_LIMIT_HARD=""
    SERVICE_CURRENT_LIMIT=""; SERVICE_CURRENT_LIMIT_SOFT=""; SERVICE_CURRENT_LIMIT_HARD=""; SERVICE_EFFECTIVE_AFTER=""
    [[ -n "$unit" ]] || return 0
    validate_unit "$unit" || { die "systemd unit 名无效: $unit"; return 1; }
    command_exists systemctl || { die '找不到 systemctl，不能配置服务 drop-in。'; return 1; }
    load=$(systemctl show "$unit" -p LoadState --value 2>/dev/null || true)
    [[ "$load" == loaded ]] || { die "服务不存在或未加载: $unit"; return 1; }
    nr_open=$(sysctl_read fs.nr_open 2>/dev/null || true)
    is_positive_uint "$nr_open" || { die '无法读取 fs.nr_open。'; return 1; }
    SERVICE_LIMIT=262144; (( nr_open < SERVICE_LIMIT )) && SERVICE_LIMIT=$nr_open
    current_hard=$(systemctl show "$unit" -p LimitNOFILE --value 2>/dev/null || true)
    current_soft=$(systemctl show "$unit" -p LimitNOFILESoft --value 2>/dev/null || true)
    SERVICE_CURRENT_LIMIT_HARD=$current_hard
    SERVICE_CURRENT_LIMIT_SOFT=$current_soft
    SERVICE_CURRENT_LIMIT="$current_soft:$current_hard"
    # Both values are required.  Treat an empty/unknown systemd response as an
    # inability to prove the administrator's limit, rather than as an already
    # satisfied limit or permission to invent a hard ceiling.
    if [[ -z "$current_hard" || -z "$current_soft" ]]; then
        die "无法读取服务 LimitNOFILE soft/hard: ${current_soft:-<empty>}:${current_hard:-<empty>}"; return 1
    fi
    if [[ "$current_hard" != infinity ]] && ! is_uint "$current_hard"; then
        die "无法解释服务 LimitNOFILE hard: $current_hard"; return 1
    fi
    if [[ "$current_soft" != infinity ]] && ! is_uint "$current_soft"; then
        die "无法解释服务 LimitNOFILE soft: $current_soft"; return 1
    fi
    if [[ "$current_soft" == infinity && "$current_hard" != infinity ]]; then
        die '服务 LimitNOFILE soft=infinity 但 hard 不是 infinity；拒绝降低或猜测管理员限制。'; return 1
    fi
    if [[ "$current_soft" != infinity && "$current_hard" != infinity ]] &&
       (( current_soft > current_hard )); then
        die "服务 LimitNOFILE soft 大于 hard: $current_soft:$current_hard"; return 1
    fi
    SERVICE_LIMIT_HARD=$current_hard
    if is_uint "$current_soft" && (( current_soft > SERVICE_LIMIT )); then SERVICE_LIMIT=$current_soft; fi
    # Never raise the hard limit automatically.  If it is finite, cap the
    # requested soft limit at the administrator's existing hard limit.
    if [[ "$SERVICE_LIMIT_HARD" != infinity ]] && (( SERVICE_LIMIT > SERVICE_LIMIT_HARD )); then
        SERVICE_LIMIT=$SERVICE_LIMIT_HARD
    fi
    if { [[ "$current_soft" == infinity ]] || { is_uint "$current_soft" && (( current_soft >= SERVICE_LIMIT )); }; } &&
       { [[ "$current_hard" == infinity ]] || { is_uint "$current_hard" && (( current_hard >= SERVICE_LIMIT )); }; }; then return 0; fi
    SERVICE_DROPIN_PATH="${ETC_ROOT}/systemd/system/${unit}.d/90-vps-proxy-tune.conf"
    validate_service_registry || { die '服务所有权 registry 损坏；拒绝继续。'; return 1; }
    record=$(registry_service_record "$unit" 2>/dev/null || true)
    if [[ -e "$SERVICE_DROPIN_PATH" || -L "$SERVICE_DROPIN_PATH" ]]; then
        [[ -f "$SERVICE_DROPIN_PATH" && ! -L "$SERVICE_DROPIN_PATH" ]] || {
            die "服务 drop-in 不是安全的普通文件: $SERVICE_DROPIN_PATH"; return 1;
        }
        [[ -n "$record" ]] || { die "服务 drop-in 已存在但不属于本工具: $SERVICE_DROPIN_PATH"; return 1; }
        IFS=$'\t' read -r _ registered_path registered_hash extra <<< "$record"
        current_hash=$(sha256sum "$SERVICE_DROPIN_PATH" | awk '{print $1}') || return 1
        if [[ "$registered_path" != "$SERVICE_DROPIN_PATH" || ! "$registered_hash" =~ ^[0-9a-f]{64}$ ||
              -n "${extra:-}" || "$current_hash" != "$registered_hash" ]] || ! managed_file_has_marker "$SERVICE_DROPIN_PATH"; then
            die '服务 drop-in 与已登记所有权哈希不一致；拒绝覆盖。'; return 1
        fi
    elif [[ -n "$record" ]]; then
        die '服务所有权 registry 存在，但 drop-in 已缺失；请先 verify/rollback。'; return 1
    fi
    SERVICE_DROPIN_NEEDED=1
}

print_service_change_preview() {
    local unit="${1:-}"
    [[ -n "$unit" ]] || return 0
    if (( SERVICE_DROPIN_NEEDED )); then
        printf '服务预览: %s LimitNOFILE soft/hard=%s -> %s:%s；写入 %s；仅 daemon-reload，不重启服务。\n' \
            "$unit" "${SERVICE_CURRENT_LIMIT:-unknown}" "$SERVICE_LIMIT" "$SERVICE_LIMIT_HARD" "$SERVICE_DROPIN_PATH"
    else
        printf '服务预览: %s 当前 LimitNOFILE soft/hard=%s 已满足目标 %s:%s；无需写入且不会重启。\n' \
            "$unit" "${SERVICE_CURRENT_LIMIT:-unknown}" "$SERVICE_LIMIT" "$SERVICE_LIMIT_HARD"
    fi
}

verify_service_limit_after_reload() {
    local unit="$1" manager_soft manager_hard main_pid actual_soft actual_hard expected_actual
    manager_hard=$(systemctl show "$unit" -p LimitNOFILE --value 2>/dev/null || true)
    manager_soft=$(systemctl show "$unit" -p LimitNOFILESoft --value 2>/dev/null || true)
    [[ "$manager_hard" == "$SERVICE_LIMIT_HARD" && "$manager_soft" == "$SERVICE_LIMIT" ]] || return 1
    SERVICE_EFFECTIVE_AFTER=unknown
    main_pid=$(systemctl show "$unit" -p MainPID --value 2>/dev/null || true)
    if [[ "$main_pid" == 0 ]]; then
        # An inactive unit has no process whose rlimit can be inspected.  Keep
        # the no-restart contract explicit; an empty/unknown MainPID is not
        # equivalent and must fail closed below.
        SERVICE_EFFECTIVE_AFTER=not-running
        return 0
    fi
    if is_positive_uint "$main_pid"; then
        [[ -r "$PROC_ROOT/$main_pid/limits" ]] || return 1
        actual_soft=$(awk '$1=="Max" && $2=="open" && $3=="files"{print $4;exit}' "$PROC_ROOT/$main_pid/limits" 2>/dev/null || true)
        actual_hard=$(awk '$1=="Max" && $2=="open" && $3=="files"{print $5;exit}' "$PROC_ROOT/$main_pid/limits" 2>/dev/null || true)
        [[ "$actual_soft" == unlimited ]] && actual_soft=infinity
        [[ "$actual_hard" == unlimited ]] && actual_hard=infinity
        [[ -n "$actual_soft" && -n "$actual_hard" ]] || return 1
        if [[ "$actual_hard" != infinity ]] && ! is_uint "$actual_hard"; then return 1; fi
        if [[ "$actual_soft" != infinity ]] && ! is_uint "$actual_soft"; then return 1; fi
        if [[ "$actual_soft" == infinity && "$actual_hard" != infinity ]]; then return 1; fi
        if [[ "$actual_soft" != infinity && "$actual_hard" != infinity ]] &&
           (( actual_soft > actual_hard )); then return 1; fi
        SERVICE_EFFECTIVE_AFTER="$actual_soft:$actual_hard"
        # daemon-reload changes the manager defaults but does not restart the
        # proxy.  Verify the live process explicitly and keep the documented
        # no-restart behavior: it must still equal the pre-apply limit, not an
        # invented value and not the new drop-in value before a restart.
        expected_actual=$SERVICE_CURRENT_LIMIT
        [[ "$SERVICE_EFFECTIVE_AFTER" == "$expected_actual" ]] || return 1
    else
        # systemd did not provide a trustworthy process identity.  Do not
        # claim that the live service limit was verified.
        return 1
    fi
}

write_apply_preview_json() {
    local plan_json="$1" unit="${2:-}" mode="$3" warning="${4:-}"
    jq --arg unit "$unit" --arg mode "$mode" --arg path "$SERVICE_DROPIN_PATH" \
        --arg before "$SERVICE_CURRENT_LIMIT" --arg soft_before "$SERVICE_CURRENT_LIMIT_SOFT" --arg hard_before "$SERVICE_CURRENT_LIMIT_HARD" \
        --arg warning "$warning" --argjson target "${SERVICE_LIMIT:-0}" --arg hard_target "${SERVICE_LIMIT_HARD:-}" \
        --argjson needed "${SERVICE_DROPIN_NEEDED:-0}" '
        .outcome="ok"
        | .reason_code="apply_preview"
        | .rollback_status="dry-run"
        | .apply_mode=$mode
        | .service_change=(if $unit=="" then null else {
            unit:$unit,path:(if $needed==1 then $path else null end),
            current_limit_nofile:$before,current_soft:$soft_before,current_hard:$hard_before,
            target_limit_nofile:$target,target_hard:$hard_target,
            change_required:($needed==1),service_restart:false
          } end)
        | .warnings += (if $warning=="" then [] else [$warning] end)
        | .proposed_changes=(if $needed==1 then [{
            type:"service-dropin",target:$path,before:$before,
            after:("LimitNOFILE="+($target|tostring)+" (effective after administrator restarts service)")
          }] else [] end)' "$plan_json"
}

APPLY_PREVIEW_DIR=""

apply_preview_exit_cleanup() {
    local saved_status=$?
    trap - EXIT INT TERM HUP
    if [[ -n "$APPLY_PREVIEW_DIR" ]]; then
        case "$APPLY_PREVIEW_DIR" in
            /tmp/vps-proxy-tune-apply.*) rm -rf -- "$APPLY_PREVIEW_DIR" ;;
        esac
    fi
    APPLY_PREVIEW_DIR=""
    return "$saved_status"
}

transaction_put() {
    local transaction="$1" key="$2" value="$3"
    [[ "$key" =~ ^[A-Z0-9_]+$ ]] || return 1
    record_field_is_safe "$value" || return 1
    # Once a v2 WAL record exists, verify the current bytes/inode/mode before
    # appending.  This turns a replacement or chmod race into a fail-closed
    # transaction error instead of authenticating an already-drifted file.
    if [[ -e "$transaction/meta.sha256" || -L "$transaction/meta.sha256" ]]; then
        verify_private_hash_record "$transaction/meta.tsv" "$transaction/meta.sha256" || return 1
    else
        secure_owned_file "$transaction/meta.tsv" || return 1
    fi
    printf '%s\t%s\n' "$key" "$value" >> "$transaction/meta.tsv" || return 1
    # v2 transactions authenticate the append-only WAL separately from the
    # immutable payload manifest. The record is refreshed after every append;
    # legacy terminal transactions without it remain read-only compatible.
    if [[ -e "$transaction/meta.sha256" || -L "$transaction/meta.sha256" ]]; then
        [[ -f "$transaction/meta.sha256" && ! -L "$transaction/meta.sha256" ]] || return 1
        write_private_hash_record "$transaction/meta.tsv" "$transaction/meta.sha256" || return 1
    fi
}

transaction_get() {
    local transaction="$1" key="$2"
    [[ "$key" =~ ^[A-Z0-9_]+$ ]] || return 1
    awk -F'\t' -v key="$key" '$1==key{value=substr($0,length($1)+2);found=1} END{if(found)print value;else exit 1}' "$transaction/meta.tsv"
}

process_start_time() {
    local pid="$1"
    is_positive_uint "$pid" || return 1
    sed -E 's/^[0-9]+ \(.*\) //' "$PROC_ROOT/$pid/stat" 2>/dev/null | awk '{print $20}'
}

process_parent_id() {
    local pid="$1"
    is_positive_uint "$pid" || return 1
    sed -E 's/^[0-9]+ \(.*\) //' "$PROC_ROOT/$pid/stat" 2>/dev/null | awk '{print $2}'
}

process_children() {
    local parent="$1" entry pid child_parent
    is_positive_uint "$parent" || return 1
    shopt -s nullglob
    for entry in "$PROC_ROOT"/[0-9]*; do
        pid=${entry##*/}
        is_positive_uint "$pid" || continue
        child_parent=$(process_parent_id "$pid" 2>/dev/null || true)
        [[ "$child_parent" == "$parent" ]] && printf '%s\n' "$pid"
    done
    shopt -u nullglob
}

terminate_process_tree_signal() {
    local pid="$1" signal="$2" child child_start current
    is_positive_uint "$pid" || return 0
    while IFS= read -r child; do
        child_start=$(process_start_time "$child" 2>/dev/null || true)
        [[ -n "$child_start" ]] || continue
        terminate_process_tree_signal "$child" "$signal" || true
        current=$(process_start_time "$child" 2>/dev/null || true)
        [[ "$current" == "$child_start" ]] || continue
        kill -"$signal" "$child" 2>/dev/null || true
    done < <(process_children "$pid")
    kill -"$signal" "$pid" 2>/dev/null || true
}

terminate_owned_process() {
    local pid="$1" expected_start="${2:-}" signal="${3:-TERM}" current
    is_positive_uint "$pid" || return 0
    is_positive_uint "$expected_start" || return 0
    current=$(process_start_time "$pid" 2>/dev/null || true)
    [[ "$current" == "$expected_start" ]] || return 0
    terminate_process_tree_signal "$pid" "$signal"
}

terminate_apply_owner() {
    local transaction="$1" pid expected current i
    pid=$(transaction_get "$transaction" APPLY_PID 2>/dev/null || true)
    expected=$(transaction_get "$transaction" APPLY_STARTTIME 2>/dev/null || true)
    is_positive_uint "$pid" || return 0
    is_positive_uint "$expected" || return 0
    (( pid > 1 )) || return 0
    current=$(process_start_time "$pid" 2>/dev/null || true)
    [[ "$current" == "$expected" ]] || return 0
    # The recorded Bash PID owns probe children such as iperf3/ping.  Kill the
    # validated process tree, not just the parent, so a disconnected apply
    # cannot leave network probes running after recovery takes ownership.
    terminate_process_tree_signal "$pid" TERM
    i=0
    while (( i < 20 )); do
        current=$(process_start_time "$pid" 2>/dev/null || true)
        [[ "$current" == "$expected" ]] || return 0
        sleep 0.1
        i=$((i + 1))
    done
    terminate_process_tree_signal "$pid" KILL
    i=0
    while (( i < 20 )); do
        current=$(process_start_time "$pid" 2>/dev/null || true)
        [[ "$current" == "$expected" ]] || return 0
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

write_transaction_status_unlocked() {
    local transaction="$1" status="$2" temp
    [[ "$status" =~ ^(prepared|applying|pending-confirm|guard-restoring|committed|rollback-failed|rolled-back)$ ]] || return 1
    if [[ -e "$transaction/status.sha256" || -L "$transaction/status.sha256" ]]; then
        verify_private_hash_record "$transaction/status" "$transaction/status.sha256" || return 1
    else
        secure_owned_file "$transaction/status" || return 1
    fi
    temp=$(mktemp "$transaction/.status.XXXXXXXX") || return 1
    if printf '%s\n' "$status" > "$temp" && chmod 0600 "$temp" && atomic_install "$temp" "$transaction/status" 0600; then
        if ! rm -f -- "$temp" || [[ -e "$temp" || -L "$temp" ]]; then
            return 1
        fi
        if [[ -e "$transaction/status.sha256" || -L "$transaction/status.sha256" ]]; then
            [[ -f "$transaction/status.sha256" && ! -L "$transaction/status.sha256" ]] || return 1
            write_private_hash_record "$transaction/status" "$transaction/status.sha256" || return 1
        fi
        return 0
    fi
    rm -f -- "$temp"
    return 1
}

set_transaction_status() {
    local transaction="$1" status="$2" status_fd rc=0
    [[ -f "$transaction/status.lock" && ! -L "$transaction/status.lock" ]] || return 1
    exec {status_fd}<>"$transaction/status.lock" || return 1
    flock -x "$status_fd" || { exec {status_fd}>&-; return 1; }
    write_transaction_status_unlocked "$transaction" "$status" || rc=1
    flock -u "$status_fd" || rc=1
    exec {status_fd}>&-
    return "$rc"
}

compare_set_transaction_status() {
    local transaction="$1" expected="$2" status="$3" status_fd current rc=0
    [[ "$expected" =~ ^(prepared|applying|pending-confirm|guard-restoring|committed|rollback-failed|rolled-back)$ ]] || return 1
    [[ -f "$transaction/status.lock" && ! -L "$transaction/status.lock" ]] || return 1
    exec {status_fd}<>"$transaction/status.lock" || return 1
    flock -x "$status_fd" || { exec {status_fd}>&-; return 1; }
    current=$(cat "$transaction/status" 2>/dev/null || true)
    if [[ "$current" != "$expected" ]]; then
        rc=2
    else
        write_transaction_status_unlocked "$transaction" "$status" || rc=1
    fi
    flock -u "$status_fd" || rc=1
    exec {status_fd}>&-
    return "$rc"
}

transaction_is_applying() {
    local transaction="$1" run_id status current
    run_id=$(basename "$transaction")
    status=$(cat "$transaction/status" 2>/dev/null || true)
    current=$(cat "$STATE_DIR/current_run" 2>/dev/null || true)
    [[ "$status" == applying && "$current" == "$run_id" ]]
}

advance_rolled_back_head() {
    local transaction="$1" run_id previous current current_record
    run_id=$(basename "$transaction")
    current_record=$(state_hash_file current_run) || return 1
    if [[ -e "$STATE_DIR/current_run" || -L "$STATE_DIR/current_run" ||
          -e "$current_record" || -L "$current_record" ]]; then
        state_hash_pair_is_valid "$STATE_DIR/current_run" "$current_record" || {
            die 'current_run 已发生漂移，拒绝推进回滚头指针。'; return 1;
        }
        current=$(cat "$STATE_DIR/current_run" 2>/dev/null || true)
        validate_run_id "$current" || { die 'current_run 内容无效。'; return 1; }
    else
        current=""
    fi
    if [[ -n "$current" && "$current" != "$run_id" ]]; then
        return 0
    fi
    previous=$(transaction_get "$transaction" PREVIOUS_RUN 2>/dev/null || true)
    if [[ -n "$previous" ]]; then
        validate_run_id "$previous" || return 1
        transaction_snapshot_is_valid "$STATE_DIR/transactions/$previous" || return 1
        [[ $(cat "$STATE_DIR/transactions/$previous/status" 2>/dev/null || true) == committed ]] || return 1
        write_current_run "$previous"
    else
        rm -f -- "$STATE_DIR/current_run" "$current_record"
    fi
}

single_peer_interface() {
    local peers="$1" _host _port _family _address _source iface _fingerprint _route_unambiguous
    local found="" count=0
    while IFS=$'\t' read -r _host _port _family _address _source iface _fingerprint _route_unambiguous; do
        [[ "$iface" == "$found" ]] && continue
        found=$iface; count=$((count + 1))
    done < "$peers"
    (( count == 1 )) || return 1
    printf '%s\n' "$found"
}

qdisc_fresh_candidate() {
    local iface="$1" queues _rx tx kind line roots classes filters mtu quantum expected_quantum
    [[ "$iface" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] || return 1
    queues=$(interface_queue_counts "$iface"); IFS=/ read -r _rx tx <<< "$queues"
    # A single transmit queue alone is not enough: an RX-multiqueue device
    # can still have a different traffic topology than the one validated by
    # the fresh-mode qdisc policy.
    if ! is_uint "$_rx" || ! is_uint "$tx" || (( _rx != 1 || tx != 1 )); then return 1; fi
    kind=$(interface_qdisc_kind "$iface" 2>/dev/null || true)
    [[ "$kind" == fq || "$kind" == fq_codel || "$kind" == pfifo_fast ]] || return 1
    roots=$(tc qdisc show dev "$iface" 2>/dev/null | awk '/ root([[:space:]]|$)/{n++} END{print n+0}')
    (( roots == 1 )) || return 1
    classes=$(tc class show dev "$iface" 2>/dev/null) || return 1
    filters=$(tc filter show dev "$iface" 2>/dev/null) || return 1
    [[ -z "$classes" && -z "$filters" ]] || return 1
    # An existing fq is a safe no-op only after the same topology checks as a
    # fresh replacement.  Filters or classful children must never be hidden by
    # the no-op return path.
    [[ "$kind" == fq ]] && return 2
    line=$(tc qdisc show dev "$iface" 2>/dev/null | awk '/ root /{$1=$1;print;exit}')
    if [[ "$kind" == pfifo_fast ]]; then
        [[ "$line" =~ ^qdisc\ pfifo_fast\ [0-9A-Fa-f]+:\ root(\ refcnt\ [0-9]+)?\ bands\ 3\ priomap\ 1\ 2\ 2\ 2\ 1\ 2\ 0\ 0\ 1\ 1\ 1\ 1\ 1\ 1\ 1\ 1$ ]] || return 1
        return 0
    fi
    mtu=$(cat "$SYS_ROOT/class/net/$iface/mtu" 2>/dev/null || true)
    is_positive_uint "$mtu" || return 1
    if [[ "$line" =~ ^qdisc\ fq_codel\ [0-9A-Fa-f]+:\ root(\ refcnt\ [0-9]+)?\ limit\ 10240p\ flows\ 1024\ quantum\ ([0-9]+)\ target\ 5ms\ interval\ 100ms\ memory_limit\ 32Mb\ ecn\ drop_batch\ 64$ ]]; then
        quantum=${BASH_REMATCH[2]}
    else
        return 1
    fi
    expected_quantum=$((mtu + 14))
    (( quantum == mtu || quantum == expected_quantum )) || return 1
    return 0
}

qdisc_root_restore_spec() {
    local iface="$1" line quantum
    [[ "$iface" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] || return 1
    line=$(tc qdisc show dev "$iface" 2>/dev/null | awk '/ root /{$1=$1;print;exit}') || return 1
    if [[ "$line" =~ ^qdisc[[:space:]]fq_codel[[:space:]][0-9A-Fa-f]+:[[:space:]]root([[:space:]]refcnt[[:space:]][0-9]+)?[[:space:]]limit[[:space:]]10240p[[:space:]]flows[[:space:]]1024[[:space:]]quantum[[:space:]]([0-9]+)[[:space:]]target[[:space:]]5ms[[:space:]]interval[[:space:]]100ms[[:space:]]memory_limit[[:space:]]32Mb[[:space:]]ecn[[:space:]]drop_batch[[:space:]]64$ ]]; then
        quantum=${BASH_REMATCH[2]}
        is_positive_uint "$quantum" || return 1
        printf 'fq_codel limit 10240p flows 1024 quantum %s target 5ms interval 100ms memory_limit 32Mb ecn drop_batch 64\n' "$quantum"
        return 0
    fi
    if [[ "$line" =~ ^qdisc[[:space:]]pfifo_fast[[:space:]][0-9A-Fa-f]+:[[:space:]]root([[:space:]]refcnt[[:space:]][0-9]+)?[[:space:]]bands[[:space:]]3[[:space:]]priomap[[:space:]]1[[:space:]]2[[:space:]]2[[:space:]]2[[:space:]]1[[:space:]]2[[:space:]]0[[:space:]]0[[:space:]]1[[:space:]]1[[:space:]]1[[:space:]]1[[:space:]]1[[:space:]]1[[:space:]]1[[:space:]]1$ ]]; then
        printf 'pfifo_fast bands 3 priomap 1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1\n'
        return 0
    fi
    return 1
}

qdisc_spec_is_safe() {
    local spec="${1:-}" token joined
    local -a args=()
    [[ -n "$spec" && "$spec" != *$'\n'* && "$spec" != *$'\t'* ]] || return 1
    IFS=' ' read -r -a args <<< "$spec"
    ((${#args[@]} > 0)) || return 1
    for token in "${args[@]}"; do
        [[ "$token" =~ ^[A-Za-z0-9_.:-]+$ ]] || return 1
    done
    case "${args[0]}" in
        fq_codel)
            ((${#args[@]} == 16)) || return 1
            [[ "${args[1]}" == limit && "${args[2]}" == 10240p &&
               "${args[3]}" == flows && "${args[4]}" == 1024 &&
               "${args[5]}" == quantum && "${args[6]}" =~ ^[1-9][0-9]*$ &&
               "${args[7]}" == target && "${args[8]}" == 5ms &&
               "${args[9]}" == interval && "${args[10]}" == 100ms &&
               "${args[11]}" == memory_limit && "${args[12]}" == 32Mb &&
               "${args[13]}" == ecn && "${args[14]}" == drop_batch &&
               "${args[15]}" == 64 ]]
            ;;
        pfifo_fast)
            IFS=' ' joined="${args[*]}"
            [[ "$joined" == 'pfifo_fast bands 3 priomap 1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1' ]]
            ;;
        *) return 1 ;;
    esac
}

qdisc_replace_from_spec() {
    local iface="$1" spec="$2"
    local -a args=()
    [[ "$iface" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] || return 1
    qdisc_spec_is_safe "$spec" || return 1
    IFS=' ' read -r -a args <<< "$spec"
    # pfifo_fast reports bands/priomap, but tc has no option parser for them.
    # The exact default map was validated above; instantiate its kernel defaults.
    if [[ "${args[0]}" == pfifo_fast ]]; then args=(pfifo_fast); fi
    tc qdisc replace dev "$iface" root "${args[@]}"
}

qdisc_root_fingerprint() {
    local iface="$1" line hash
    [[ "$iface" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] || return 1
    line=$(tc qdisc show dev "$iface" 2>/dev/null | awk '/ root / {
        root=0; out=$1 " " $2
        for(i=3;i<=NF;i++) {
            if($i=="root") {root=i; out=out " root"; continue}
            if(root && i>root) {
                if($i=="refcnt") {i++; continue}
                out=out " " $i
            }
        }
        if(root) print out
        exit
    }') || return 1
    [[ -n "$line" ]] || return 1
    hash=$(printf '%s\n' "$line" | sha256sum | awk '{print $1}') || return 1
    [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$hash"
}

start_rollback_guard() {
    local transaction="$1" run_id unit safe_id cleanup_rc=0 name
    if ! command_exists systemd-run || ! command_exists systemctl || [[ ! -d /run/systemd/system ]]; then return 1; fi
    run_id=$(basename "$transaction"); safe_id=${run_id//[^A-Za-z0-9]/-}
    unit="vps-proxy-tune-guard-${safe_id}"
    # The source file supports VPS_TUNE_LIB_ONLY for unit-test sourcing.  Do
    # not let an inherited test environment turn a production guard into a
    # no-op when systemd later executes the copied recovery script.
    systemd-run --quiet --collect \
        --setenv=VPS_TUNE_LIB_ONLY=0 --setenv=VPS_TUNE_ETC_ROOT=/etc \
        --setenv=VPS_TUNE_PROC_ROOT=/proc --setenv=VPS_TUNE_SYS_ROOT=/sys \
        --setenv=VPS_TUNE_STATE_DIR=/var/lib/vps-proxy-tune --setenv=VPS_TUNE_RUN_ROOT=/run \
        --unit="$unit" --on-active="${CONFIRM_TIMEOUT_SECONDS}s" \
        --timer-property=AccuracySec=1s --property=Type=oneshot \
        /bin/bash "$transaction/guard-script.sh" _guard-rollback --transaction "$run_id" >/dev/null 2>&1 || return 1
    if ! transaction_put "$transaction" GUARD_UNIT "$unit"; then
        for name in "$unit.timer" "$unit.service"; do
            stop_reset_unit_checked "$name" || cleanup_rc=1
        done
        (( cleanup_rc == 0 )) || warn "回滚守卫元数据写入失败，且清理守卫 unit 未完全成功: $unit"
        return 1
    fi
}

stop_reset_unit_checked() {
    local name="$1" load show_status
    load=$(systemctl show "$name" -p LoadState --value 2>/dev/null); show_status=$?
    (( show_status == 0 )) || return 1
    [[ "$load" == not-found ]] && return 0
    systemctl stop "$name" >/dev/null 2>&1 || return 1
    systemctl reset-failed "$name" >/dev/null 2>&1 || return 1
}

cancel_rollback_guard() {
    local transaction="$1" unit
    unit=$(transaction_get "$transaction" GUARD_UNIT 2>/dev/null || true)
    [[ -n "$unit" ]] || return 0
    [[ "$unit" =~ ^vps-proxy-tune-guard-[A-Za-z0-9-]{1,120}$ ]] || return 1
    stop_reset_unit_checked "$unit.timer" || return 1
    stop_reset_unit_checked "$unit.service" || return 1
}

update_apply_report_rollback_status() {
    local transaction="$1" rollback_status="$2" report temp reason outcome
    [[ "$rollback_status" == rolled-back || "$rollback_status" == rollback-failed ]] || return 1
    reason=rollback_completed
    outcome=rolled_back
    if [[ "$rollback_status" == rollback-failed ]]; then
        reason=rollback_failed
        outcome=rollback_failed
    fi
    report="$transaction/apply.json"
    transaction_mutable_file_is_current "$transaction" apply.json || return 1
    [[ -e "$report" || -L "$report" ]] || return 0
    [[ -f "$report" && ! -L "$report" ]] || return 1
    command_exists jq || return 1
    temp=$(mktemp "$transaction/.apply-report.XXXXXXXX") || return 1
    if jq --arg rollback "$rollback_status" --arg outcome "$outcome" --arg reason "$reason" \
        '.rollback_status=$rollback | .outcome=$outcome | .reason_code=$reason' "$report" > "$temp" &&
       chmod 0600 "$temp" && atomic_install "$temp" "$report" 0600; then
        rm -f -- "$temp" || return 1
        [[ ! -e "$temp" && ! -L "$temp" ]] || return 1
        if [[ "$(transaction_get "$transaction" FORMAT_VERSION 2>/dev/null || true)" == "$STATE_FORMAT_VERSION" ]]; then
            write_private_hash_record "$report" "$transaction/apply.json.sha256" || return 1
        fi
        return 0
    fi
    rm -f -- "$temp"
    return 1
}

restore_transaction() {
    local transaction="$1" phase="${2:-all}" status iface before before_spec changed service service_existed rc=0
    local expected_qdisc_hash current_qdisc_hash current_qdisc_kind before_qdisc_hash this_run
    local service_path service_before_hash current_hash
    [[ "$phase" == all || "$phase" == config || "$phase" == qdisc ]] || return 1
    if [[ "$phase" == all ]]; then
        # Keep every caller on the same ordering as the two boot units: the
        # authenticated configuration/sysctl state is restored before any
        # network-dependent qdisc operation.  The qdisc phase has its own
        # ownership check and finalizes the transaction state.
        restore_transaction "$transaction" config || return 1
        restore_transaction "$transaction" qdisc
        return $?
    fi
    if ! transaction_snapshot_is_valid "$transaction"; then
        warn "事务 $(basename "$transaction") 的快照、身份或元数据校验失败；拒绝执行不可信回滚。"
        return 1
    fi
    status=$(cat "$transaction/status" 2>/dev/null || printf unknown)
    if [[ "$phase" == qdisc && "$status" != committed && "$status" != rolled-back ]]; then
        [[ "$(transaction_get "$transaction" CONFIG_RECOVERED 2>/dev/null || true)" == 1 ]] || {
            die 'qdisc 阶段要求配置/sysctl 阶段已成功恢复；请先执行 recover --phase config 或 recover --phase all。'
            return 40
        }
    fi
    if [[ "$status" == rolled-back ]]; then
        advance_rolled_back_head "$transaction"
        return $?
    fi
    if [[ "$phase" != config ]]; then
            iface=$(transaction_get "$transaction" QDISC_IFACE 2>/dev/null || true)
            before=$(transaction_get "$transaction" QDISC_BEFORE 2>/dev/null || true)
            before_spec=$(transaction_get "$transaction" QDISC_BEFORE_SPEC 2>/dev/null || true)
            changed=$(transaction_get "$transaction" QDISC_CHANGED 2>/dev/null || printf 0)
        if [[ "$changed" == 1 && -n "$iface" && -n "$before" && "$before" != unknown ]]; then
            before_qdisc_hash=$(transaction_get "$transaction" QDISC_BEFORE_HASH 2>/dev/null || true)
            expected_qdisc_hash=$(transaction_get "$transaction" QDISC_AFTER_HASH 2>/dev/null || true)
            current_qdisc_hash=$(qdisc_root_fingerprint "$iface" 2>/dev/null || true)
            current_qdisc_kind=$(interface_qdisc_kind "$iface" 2>/dev/null || true)
            if [[ -n "$before_qdisc_hash" && "$current_qdisc_hash" == "$before_qdisc_hash" ]]; then
                :
            elif [[ -n "$expected_qdisc_hash" && "$current_qdisc_hash" == "$expected_qdisc_hash" ]]; then
                if [[ -n "$before_spec" ]]; then
                    if ! qdisc_spec_is_safe "$before_spec" ||
                       ! qdisc_replace_from_spec "$iface" "$before_spec" >/dev/null 2>&1; then
                        rc=1
                    fi
                else
                    # A legacy snapshot that stores only the qdisc kind is
                    # readable for audit, but is not sufficient to restore
                    # parameters safely.  Never replace a live qdisc from a
                    # kind-only v1 record; require an explicit migration or
                    # an operator using the out-of-band console.
                    warn "事务 $(basename "$transaction") 缺少 qdisc before_spec；拒绝使用 v1 kind-only 快照覆盖当前 qdisc。"
                    rc=1
                fi
                if (( rc == 0 )) &&
                   [[ $(qdisc_root_fingerprint "$iface" 2>/dev/null || true) != "$before_qdisc_hash" ]]; then
                    rc=1
                fi
            elif [[ -z "$expected_qdisc_hash" && "$current_qdisc_kind" == fq && "$status" != committed ]]; then
                warn "qdisc $iface 的 apply 后指纹未落盘；无法证明当前 fq 仍归本事务所有，回滚拒绝覆盖。"
                transaction_append_mutable_line "$transaction" apply.warnings \
                    "qdisc $iface post-change fingerprint missing; rollback skipped unowned live qdisc" 2>/dev/null || true
                rc=1
            else
                warn "qdisc $iface 已在 apply 后变化；为避免覆盖管理员配置，回滚跳过该 qdisc。"
                transaction_append_mutable_line "$transaction" apply.warnings \
                    "qdisc $iface ownership fingerprint changed; rollback skipped live qdisc" 2>/dev/null || true
                rc=1
            fi
        fi
    fi
    if [[ "$phase" != qdisc ]]; then
        restore_transaction_runtime "$transaction" || rc=1
        restore_owned_files "$transaction" || rc=1
        service=$(transaction_get "$transaction" SERVICE 2>/dev/null || true)
        service_existed=$(awk -F'\t' '$1=="service"{print $3;found=1;exit} END{if(!found)exit 1}' "$transaction/files.tsv" 2>/dev/null || true)
        if [[ -n "$service" && -n "$service_existed" ]]; then
            service_path=$(awk -F'\t' '$1=="service"{print $2;exit}' "$transaction/files.tsv") || rc=1
            service_before_hash=$(awk -F'\t' '$1=="service"{print $5;exit}' "$transaction/files.tsv") || rc=1
            if [[ "$service_existed" == 0 ]]; then
                if [[ ! -e "$service_path" && ! -L "$service_path" ]]; then
                    unregister_service "$service" || rc=1
                else
                    rc=1
                fi
            elif [[ "$service_existed" == 1 ]]; then
                current_hash=$(sha256sum "$service_path" 2>/dev/null | awk '{print $1}' || true)
                if [[ "$current_hash" == "$service_before_hash" ]]; then
                    set_service_registry "$service" "$service_path" "$service_before_hash" || rc=1
                else
                    rc=1
                fi
            else
                rc=1
            fi
            if ! command_exists systemctl || ! systemctl daemon-reload >/dev/null 2>&1; then rc=1; fi
        fi
    fi
    # The config recovery unit intentionally leaves the transaction in
    # guard-restoring until the network-specific qdisc phase has completed.
    if [[ "$phase" == config ]]; then
        if (( rc == 0 )); then
            transaction_put "$transaction" CONFIG_RECOVERED 1 || rc=1
        fi
        if (( rc != 0 )); then
            set_transaction_status "$transaction" rollback-failed || true
            update_apply_report_rollback_status "$transaction" rollback-failed || true
        fi
        return "$rc"
    fi
    if (( rc == 0 )); then
        set_transaction_status "$transaction" rolled-back || rc=1
    fi
    if (( rc == 0 )); then
        update_apply_report_rollback_status "$transaction" rolled-back ||
            warn '事务已恢复，但无法更新历史 apply.json 的 rollback_status；事务 status 文件仍是权威状态。'
        if ! advance_rolled_back_head "$transaction"; then
            warn '事务已恢复并标记 rolled-back，但 current_run 推进失败；可再次执行 rollback 修复指针。'
            return 1
        fi
    else
        set_transaction_status "$transaction" rollback-failed || true
        update_apply_report_rollback_status "$transaction" rollback-failed || true
        this_run=$(basename "$transaction")
        write_current_run "$this_run" || true
        warn "事务 $(basename "$transaction") 恢复不完整；状态保留为 rollback-failed 以允许重试。"
    fi
    return "$rc"
}

POST_VERIFY_REASON=""
POST_VERIFY_MBPS=0
POST_VERIFY_LOADED_DELTA=0
POST_VERIFY_RETRANS_PCT=0
POST_VERIFY_RETRANS_KNOWN=0
POST_VERIFY_UDP_LOSS=0
POST_VERIFY_UDP_LOSS_KNOWN=0

post_apply_verify() {
    local run_dir transaction plan_file metrics
    local host port family address source iface fingerprint route_unambiguous current_fp resolved
    local budget actual measurement_wire verify_profile verify_bytes verify_mib verify_test_cap rate max_rate desired_rate duration profile verification_tests
    local baseline_mbps baseline_loaded baseline_retrans baseline_rtt selected_index selected_line idle_p95 loaded_p95 loaded_pid tcp_loaded
    local up_bps down_bps up_bytes down_bytes up_retrans down_retrans up_retrans_known down_retrans_known udp_up_loss threshold iface_before iface_after verify_wire udp_loss_complete=1
    run_dir=$1; transaction=$2; plan_file="$run_dir/plan.tsv"; metrics="$run_dir/metrics.tsv"
    POST_VERIFY_REASON=""; POST_VERIFY_MBPS=0; POST_VERIFY_LOADED_DELTA=0; POST_VERIFY_RETRANS_PCT=0; POST_VERIFY_RETRANS_KNOWN=0; POST_VERIFY_UDP_LOSS=0; POST_VERIFY_UDP_LOSS_KNOWN=0
    POST_VERIFY_LOADED_PID=0
    POST_VERIFY_LOADED_STARTTIME=""
    verify_plan_runtime "$plan_file" || { POST_VERIFY_REASON='sysctl value mismatch'; return 1; }
    while IFS=$'\t' read -r host port family address source iface fingerprint route_unambiguous; do
        [[ "$route_unambiguous" == 1 ]] || { POST_VERIFY_REASON="ambiguous route for $address"; return 1; }
        route_is_unambiguous "$family" "$address" "$source" || { POST_VERIFY_REASON="route became ambiguous for $address"; return 1; }
        resolved=$(resolve_peer_host "$host" "$family" 2>/dev/null || printf unavailable)
        [[ "$resolved" == "$address" ]] || { POST_VERIFY_REASON="address family or DNS drift for $host"; return 1; }
        current_fp=$(route_fingerprint "$family" "$address" "$source" 2>/dev/null || printf unavailable)
        [[ "$current_fp" == "$fingerprint" ]] || { POST_VERIFY_REASON="route drift for $address"; return 1; }
    done < "$run_dir/peers.tsv"
    selected_index=$(metric_get "$metrics" SELECTED_PEER_INDEX)
    is_positive_uint "$selected_index" || { POST_VERIFY_REASON='invalid selected peer index'; return 1; }
    selected_line=$(sed -n "${selected_index}p" "$run_dir/peers.tsv")
    [[ -n "$selected_line" ]] || { POST_VERIFY_REASON='selected peer missing'; return 1; }
    IFS=$'\t' read -r host port family address source iface fingerprint route_unambiguous <<< "$selected_line"
    budget=$(metric_get "$metrics" BUDGET_BYTES); actual=$(metric_get "$metrics" ACTUAL_BYTES)
    measurement_wire=$(metric_get "$metrics" WIRE_BYTES)
    is_positive_uint "$budget" || { POST_VERIFY_REASON='invalid budget metrics'; return 1; }
    is_uint "$actual" || { POST_VERIFY_REASON='invalid budget metrics'; return 1; }
    is_uint "$measurement_wire" || { POST_VERIFY_REASON='invalid budget metrics'; return 1; }
    baseline_mbps=$(metric_get "$metrics" VERIFY_BASELINE_MBPS)
    profile=$(metric_get "$metrics" PROFILE 2>/dev/null || printf tcp)
    verification_tests=2
    [[ "$profile" == mixed ]] && verification_tests=4
    verify_profile=$(verification_budget_profile "$budget" "$measurement_wire" "$baseline_mbps" "$(metric_get "$metrics" RTT_P95_MS)" "$verification_tests" 2>/dev/null) || {
        POST_VERIFY_REASON='remaining budget cannot verify baseline throughput without pacing bias'; return 1;
    }
    IFS=$'\t' read -r verify_bytes verify_mib duration max_rate desired_rate <<< "$verify_profile"
    is_positive_uint "$verify_mib" || { POST_VERIFY_REASON='invalid verification budget profile'; return 1; }
    is_positive_uint "$max_rate" || { POST_VERIFY_REASON='invalid verification budget profile'; return 1; }
    rate=$desired_rate
    verify_test_cap=$((verify_bytes * 80 / (100 * verification_tests)))
    install -d -m 0700 "$transaction/postverify" || { POST_VERIFY_REASON='cannot create verification state'; return 1; }
    iface_before=$(interface_bytes "$iface") || { POST_VERIFY_REASON='cannot read interface byte counter before verification'; return 1; }
    ping_collect "$family" "$address" "$source" 15 "$transaction/postverify/ping.idle" 0.20 || { POST_VERIFY_REASON='idle RTT probe failed'; return 1; }
    idle_p95=$(ping_samples_from_file "$transaction/postverify/ping.idle" | percentile 95 2>/dev/null || printf '0')
    # Match the loaded-RTT probe to the complete verification profile.  A
    # mixed verification has four tests (two TCP plus two UDP), not two.
    ping_collect "$family" "$address" "$source" "$((duration * verification_tests * 5))" "$transaction/postverify/ping.loaded" 0.20 & loaded_pid=$!
    POST_VERIFY_LOADED_PID=$loaded_pid
    POST_VERIFY_LOADED_STARTTIME=$(process_start_time "$loaded_pid" 2>/dev/null || true)
    if ! is_positive_uint "$POST_VERIFY_LOADED_STARTTIME"; then
        post_verify_cleanup
        POST_VERIFY_REASON='cannot verify loaded RTT probe process identity'
        return 1
    fi
    if ! run_iperf_test verify_upload "$address" "$port" "$family" "$source" "$duration" "$rate" 1 0 "$transaction/postverify/upload.json" "$verify_test_cap" tcp >/dev/null; then
        wait "$loaded_pid" 2>/dev/null || true; POST_VERIFY_LOADED_PID=0; POST_VERIFY_LOADED_STARTTIME=""; POST_VERIFY_REASON='new upload connection failed'; return 1
    fi
    up_bps=$TEST_BPS; up_bytes=$TEST_BYTES; up_retrans=$TEST_RETRANS; up_retrans_known=$TEST_RETRANS_KNOWN
    if ! run_iperf_test verify_download "$address" "$port" "$family" "$source" "$duration" "$rate" 1 1 "$transaction/postverify/download.json" "$verify_test_cap" tcp >/dev/null; then
        wait "$loaded_pid" 2>/dev/null || true; POST_VERIFY_LOADED_PID=0; POST_VERIFY_LOADED_STARTTIME=""; POST_VERIFY_REASON='new reverse connection failed'; return 1
    fi
    down_bps=$TEST_BPS; down_bytes=$TEST_BYTES; down_retrans=$TEST_RETRANS; down_retrans_known=$TEST_RETRANS_KNOWN
    if (( up_retrans_known == 0 || down_retrans_known == 0 )); then
        wait "$loaded_pid" 2>/dev/null || true; POST_VERIFY_LOADED_PID=0; POST_VERIFY_LOADED_STARTTIME=""
        POST_VERIFY_REASON='TCP retransmission counter unavailable during verification'; return 1
    fi
    if [[ "$profile" == mixed ]]; then
        if ! run_iperf_test verify_udp_upload "$address" "$port" "$family" "$source" "$duration" "$rate" 1 0 "$transaction/postverify/udp-upload.json" "$verify_test_cap" udp >/dev/null; then
            wait "$loaded_pid" 2>/dev/null || true; POST_VERIFY_LOADED_PID=0; POST_VERIFY_LOADED_STARTTIME=""; POST_VERIFY_REASON='new UDP upload connection failed'; return 1
        fi
        if (( TEST_LOSS_KNOWN )); then
            udp_up_loss=$TEST_LOSS_PCT; POST_VERIFY_UDP_LOSS_KNOWN=1; POST_VERIFY_UDP_LOSS=$udp_up_loss
        else
            udp_loss_complete=0
        fi
        if ! run_iperf_test verify_udp_download "$address" "$port" "$family" "$source" "$duration" "$rate" 1 1 "$transaction/postverify/udp-download.json" "$verify_test_cap" udp >/dev/null; then
            wait "$loaded_pid" 2>/dev/null || true; POST_VERIFY_LOADED_PID=0; POST_VERIFY_LOADED_STARTTIME=""; POST_VERIFY_REASON='new UDP reverse connection failed'; return 1
        fi
        if (( TEST_LOSS_KNOWN )); then
            if (( POST_VERIFY_UDP_LOSS_KNOWN == 0 )) || float_cmp "$TEST_LOSS_PCT" gt "$POST_VERIFY_UDP_LOSS"; then POST_VERIFY_UDP_LOSS=$TEST_LOSS_PCT; fi
            POST_VERIFY_UDP_LOSS_KNOWN=1
        else
            udp_loss_complete=0
        fi
        if (( udp_loss_complete == 0 )); then
            wait "$loaded_pid" 2>/dev/null || true; POST_VERIFY_LOADED_PID=0; POST_VERIFY_LOADED_STARTTIME=""
            POST_VERIFY_REASON='UDP receiver loss counters unavailable during verification'; return 1
        fi
    fi
    wait "$loaded_pid" 2>/dev/null || true; POST_VERIFY_LOADED_PID=0; POST_VERIFY_LOADED_STARTTIME=""
    iface_after=$(interface_bytes "$iface") || { POST_VERIFY_REASON='cannot read interface byte counter after verification'; return 1; }
    if (( iface_after < iface_before )); then
        POST_VERIFY_REASON='interface byte counter regressed during verification'; return 1
    fi
    verify_wire=$((iface_after >= iface_before ? iface_after - iface_before : 0))
    if ! awk -v measured="$measurement_wire" -v verified="$verify_wire" -v budget="$budget" \
        'BEGIN{exit !((measured+verified)*100 <= budget*102)}'; then
        POST_VERIFY_REASON='wire-byte budget exceeded during verification'; return 1
    fi
    current_fp=$(route_fingerprint "$family" "$address" "$source" 2>/dev/null || printf unavailable)
    [[ "$current_fp" == "$fingerprint" ]] || { POST_VERIFY_REASON='route drift during verification'; return 1; }
    route_is_unambiguous "$family" "$address" "$source" || { POST_VERIFY_REASON='route became ambiguous during verification'; return 1; }
    POST_VERIFY_MBPS=$(awk -v u="$up_bps" -v d="$down_bps" 'BEGIN{b=(u<d?u:d);printf "%.3f\n",b/1000000}')
    loaded_p95=$(ping_samples_from_file "$transaction/postverify/ping.loaded" | percentile 95 2>/dev/null || printf '0')
    baseline_rtt=$(metric_get "$metrics" RTT_P95_MS)
    if ! float_cmp "$idle_p95" gt 0 2>/dev/null; then idle_p95=$baseline_rtt; fi
    if ! float_cmp "$loaded_p95" gt 0 2>/dev/null; then
        tcp_loaded=$(jq -s -r '[.[] | .end.streams[]?.sender.mean_rtt // empty] | if length>0 then (max/1000) else 0 end' \
            "$transaction/postverify/upload.json" "$transaction/postverify/download.json" 2>/dev/null || printf '0')
        loaded_p95=$tcp_loaded
    fi
    if ! float_cmp "$idle_p95" gt 0 2>/dev/null || ! float_cmp "$loaded_p95" gt 0 2>/dev/null; then
        POST_VERIFY_REASON='no usable TCP/ICMP RTT during verification'; return 1
    fi
    POST_VERIFY_LOADED_DELTA=$(awk -v loaded="$loaded_p95" -v idle="$idle_p95" 'BEGIN{d=loaded-idle;if(d<0)d=0;printf "%.3f\n",d}')
    POST_VERIFY_RETRANS_PCT=$(awk -v r="$((up_retrans + down_retrans))" -v b="$((up_bytes + down_bytes))" 'BEGIN{s=b/1448;if(s<1)s=1;printf "%.6f\n",(r/s)*100}')
    POST_VERIFY_RETRANS_KNOWN=1
    baseline_loaded=$(metric_get "$metrics" VERIFY_BASELINE_LOADED_DELTA_MS)
    baseline_retrans=$(metric_get "$metrics" VERIFY_BASELINE_RETRANS_PCT)
    threshold=$(awk -v value="$baseline_mbps" 'BEGIN{printf "%.6f\n",value*0.85}')
    if float_cmp "$POST_VERIFY_MBPS" lt "$threshold"; then POST_VERIFY_REASON='throughput regressed by more than 15%'; return 1; fi
    threshold=$(awk -v value="$baseline_loaded" 'BEGIN{printf "%.6f\n",value+30}')
    if float_cmp "$POST_VERIFY_LOADED_DELTA" gt "$threshold"; then POST_VERIFY_REASON='loaded RTT increased by more than 30 ms'; return 1; fi
    threshold=$(awk -v value="$baseline_retrans" 'BEGIN{printf "%.6f\n",value*2}')
    if float_cmp "$POST_VERIFY_RETRANS_PCT" gt "$threshold"; then POST_VERIFY_REASON='retransmission estimate more than doubled'; return 1; fi
    if [[ "$profile" == mixed ]] && (( POST_VERIFY_UDP_LOSS_KNOWN )); then
        local baseline_udp_loss baseline_udp_known udp_threshold
        baseline_udp_loss=$(metric_get "$metrics" UDP_LOSS_PCT 2>/dev/null || printf '0')
        baseline_udp_known=$(metric_get "$metrics" UDP_LOSS_KNOWN 2>/dev/null || printf '0')
        if (( baseline_udp_known == 1 )); then
            udp_threshold=$(awk -v value="$baseline_udp_loss" 'BEGIN{v=value*2;if(v<0.5)v=0.5;printf "%.6f",v}')
            if float_cmp "$POST_VERIFY_UDP_LOSS" gt "$udp_threshold"; then POST_VERIFY_REASON='UDP loss more than doubled'; return 1; fi
        fi
    fi
    return 0
}

persisted_file_as_plan() {
    local file="$1" output="$2" line key value normalized_key current change_type
    local -A seen=()
    : > "$output" || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%%#*}; line=$(trim "$line")
        [[ -n "$line" ]] || continue
        [[ "$line" != *';'* ]] || return 1
        if [[ "$line" == *=* ]]; then
            key=$(trim "${line%%=*}")
            value=$(trim "${line#*=}")
        else
            key=${line%%[[:space:]]*}
            value=$(trim "${line#"$key"}")
            [[ -n "$value" ]] || return 1
        fi
        [[ -n "$key" && -n "$value" && "$key" =~ ^-?[A-Za-z0-9_./]+$ &&
           "$value" != *'='* && "$value" != *$'\t'* && "$value" != *$'\r'* ]] || return 1
        normalized_key=${key#-}; normalized_key=${normalized_key//\//.}; normalized_key=${normalized_key#.}
        is_target_sysctl_key "$normalized_key" || continue
        [[ -z "${seen[$normalized_key]+x}" ]] || return 1
        seen[$normalized_key]=1
        key=$normalized_key
        [[ "$value" =~ ^[A-Za-z0-9_.[:space:]-]+$ ]] || return 1
        current=$(sysctl_read "$key" 2>/dev/null || printf unavailable)
        change_type=runtime_change
        [[ "$value" == "$current" ]] && change_type=persist_only
        printf '%s\t%s\t%s\tretained owned value\t%s\n' "$key" "$value" "$current" "$change_type" >> "$output" || return 1
    done < "$file"
    chmod 0600 "$output" || return 1
}

write_apply_json() {
    local run_dir transaction rollback_status warnings_file report_temp
    local changes verification outcome reason
    run_dir=$1; transaction=$2; rollback_status=$3; warnings_file="$transaction/apply.warnings"
    outcome=${OUTCOME:-$rollback_status}; reason=${REASON_CODE:-$rollback_status}
    transaction_mutable_file_is_current "$transaction" changes.tsv || return 1
    transaction_mutable_file_is_current "$transaction" apply.warnings || return 1
    changes=$(jq -Rn '[inputs | split("\t") | select(length>=4) |
        {type:.[0],target:.[1],before:.[2],after:.[3],
         change_type:(if length>=5 and .[4]!="" then .[4] else "runtime_change" end)}]' < "$transaction/changes.tsv") || return 1
    verification=$(jq -n --arg mbps "$POST_VERIFY_MBPS" --arg loaded "$POST_VERIFY_LOADED_DELTA" \
        --arg retrans "$POST_VERIFY_RETRANS_PCT" --arg udp_loss "$POST_VERIFY_UDP_LOSS" \
        --argjson retrans_known "$POST_VERIFY_RETRANS_KNOWN" --argjson udp_loss_known "$POST_VERIFY_UDP_LOSS_KNOWN" --arg reason "$POST_VERIFY_REASON" \
        '{throughput_mbps:($mbps|tonumber),loaded_delta_ms:($loaded|tonumber),retransmits_known:($retrans_known==1),retrans_pct:(if $retrans_known==1 then ($retrans|tonumber) else null end),udp_loss_pct:(if $udp_loss_known==1 then ($udp_loss|tonumber) else null end),failure_reason:$reason}') || return 1
    report_temp=$(mktemp "$transaction/.apply-json.XXXXXXXX") || return 1
    if ! jq --argjson changes "$changes" --argjson verification "$verification" --arg rollback "$rollback_status" \
        --arg outcome "$outcome" --arg reason "$reason" \
        --slurpfile extra <(jq -Rsc 'split("\n")|map(select(length>0))' "$warnings_file") \
        '.changes=$changes | .verification=$verification | .outcome=$outcome | .reason_code=$reason | .rollback_status=$rollback | .warnings += $extra[0]' \
        "$run_dir/plan.json" > "$report_temp"; then
        rm -f -- "$report_temp"
        return 1
    fi
    if ! chmod 0600 "$report_temp" || ! transaction_replace_mutable_file "$transaction" apply.json "$report_temp" 0600; then
        rm -f -- "$report_temp"
        return 1
    fi
    rm -f -- "$report_temp"
}

apply_failure() {
    local transaction="$1" message="$2" status
    POST_VERIFY_REASON=$message
    set_outcome 'failed' 'apply_failed'
    warn "应用失败，正在恢复事务基线: $message"
    status=$(cat "$transaction/status" 2>/dev/null || printf unknown)
    if [[ "$status" == guard-restoring ]]; then
        warn '回滚守卫已接管事务；当前 apply 将退出并把恢复工作留给守卫。'
        set_outcome 'blocked' 'recovery_pending'
        emit_json_result blocked recovery_pending "$(basename "$transaction")" guard-restoring
        disarm_apply_cleanup
        return 1
    fi
    if restore_transaction "$transaction"; then
        if [[ -n "$RECOVERY_UNIT_PENDING_BACKUP" ]] && ! restore_held_recovery_unit; then
            warn '事务已恢复，但 apply 前的启动恢复材料无法恢复；保留补偿备份供 status/recover 检测。'
            write_baseline_cleanup_marker "$transaction" ||
                warn '无法写入 baseline cleanup marker；请保留并检查当前 baseline 与事务状态。'
            set_outcome 'rollback_failed' 'recovery_pending'
            emit_json_result rollback_failed recovery_pending "$(basename "$transaction")" rollback-failed
            disarm_apply_cleanup
            return 1
        fi
        if ! remove_new_initial_baseline; then
            warn '事务已恢复，但本轮新建 baseline 无法安全移除；保留 baseline 作为可检测恢复证据。'
            write_baseline_cleanup_marker "$transaction" ||
                warn '无法写入 baseline cleanup marker；请保留并检查当前 baseline 与事务状态。'
            cancel_rollback_guard "$transaction" || true
            set_outcome 'rollback_failed' 'recovery_pending'
            emit_json_result rollback_failed recovery_pending "$(basename "$transaction")" rollback-failed
            disarm_apply_cleanup
            return 1
        fi
        if cancel_rollback_guard "$transaction"; then
            set_outcome 'rolled_back' 'apply_failed'
            emit_json_result rolled_back apply_failed "$(basename "$transaction")" rolled-back
        else
            warn '事务已恢复，但回滚守卫停止/重置失败；错误已保留供人工处理。'
            set_outcome 'rollback_failed' 'recovery_pending'
            emit_json_result rollback_failed recovery_pending "$(basename "$transaction")" rollback-failed
        fi
        disarm_apply_cleanup
    else
        warn '自动恢复遇到错误；保留回滚守卫和 rollback-failed 状态，请随后执行 rollback/recover 并检查控制台。'
        set_outcome 'rollback_failed' 'apply_failed'
        emit_json_result rollback_failed apply_failed "$(basename "$transaction")" rollback-failed
    fi
    return 1
}

cmd_apply() {
    local run_id="" mode=safe service="" assume_yes=0 arg run_dir metrics confidence retrans_known transaction status
    local plan_file all_plan conflict current key value before reason previous="" answer verification dry_preview_dir="" persisted_preview
    local baseline_existed=0
    local modules_needed=0 bbr_module_needed=0 fq_module_needed=0 iface="" qdisc_before="" qdisc_before_spec="" qdisc_rc=1 qdisc_changed=0
    local service_temp="" modules_temp="" transaction_tmp="" source_hash source_hash_after guard_hash qdisc_before_hash qdisc_after_hash stage_file apply_starttime
    local modules_line
    local -A module_seen=()
    local pre_sysctl_identity pre_modules_identity host port family address source fingerprint _route_iface route_unambiguous current_fp resolved current_head
    local pre_service_needed pre_service_path pre_service_limit pre_service_current pacing_skip_reason=""
    local qdisc_preflight_iface qdisc_preflight_rc qdisc_default_current cc_available_current
    JSON_OUTPUT=0; DRY_RUN=0; INSTALL_DEPS=0; JSON_ERROR_EMITTED=0
    APPLY_BASELINE_CREATED=0
    APPLY_PRESERVE_PREPARED=0
    set_outcome '' ''
    while (($#)); do
        arg=$1; shift
        case "$arg" in
            --run) (($#)) || { die '--run 缺少值'; return 1; }; run_id=$1; shift ;;
            --run=*) run_id=${arg#*=} ;;
            --mode) (($#)) || { die '--mode 缺少值'; return 1; }; mode=$1; shift ;;
            --mode=*) mode=${arg#*=} ;;
            --service) (($#)) || { die '--service 缺少值'; return 1; }; service=$1; shift ;;
            --service=*) service=${arg#*=} ;;
            --yes) assume_yes=1 ;;
            --json) JSON_OUTPUT=1 ;;
            --dry-run) DRY_RUN=1 ;;
            --install-deps) INSTALL_DEPS=1 ;;
            *) die "apply 不支持参数: $arg"; return 1 ;;
        esac
    done
    (( DRY_RUN == 0 || INSTALL_DEPS == 0 )) || { die '--dry-run 与 --install-deps 不能同时使用。'; return 1; }
    if [[ -z "$run_id" ]] || ! validate_run_id "$run_id"; then die 'apply 需要有效的 --run RUN_ID。'; return 1; fi
    [[ "$mode" == safe || "$mode" == fresh ]] || { die '--mode 只能是 safe 或 fresh。'; return 1; }
    if [[ -n "$service" ]] && ! validate_unit "$service"; then die '无效的 --service unit 名。'; return 1; fi
    require_root || return 1
    require_real_apply_roots || return 1
    supported_os || { die '当前系统不在 Debian/Ubuntu 验证矩阵内。'; return 1; }
    supported_arch || { die '当前架构不在 amd64/arm64 验证矩阵内。'; return 1; }
    if is_container; then die '检测到共享内核容器（LXC/OpenVZ/Docker 等），拒绝宿主级 apply。'; return 1; fi
    if (( DRY_RUN )); then
        require_preview_commands || return 1
    else
        require_measure_commands || return 1
        require_apply_commands || return 1
    fi
    if (( DRY_RUN )); then
        ensure_secure_state || return 1
    else
        ensure_state_dirs || return 1; ensure_secure_state || return 1; acquire_lock || return 1
    fi
    validate_transaction_chain || {
        die '事务链含未完成、链外或损坏事务；拒绝新 apply，请先按 current_run 执行 rollback/status。'; return 1;
    }
    if [[ -r "$STATE_DIR/current_run" ]]; then
        current_head=$(cat "$STATE_DIR/current_run") || return 1
        if ! verification=$(verify_current_state "$STATE_DIR/transactions/$current_head" 0 2>&1); then
            [[ -z "$verification" ]] || printf '%s\n' "$verification" >&2
            die '当前事务拥有的配置已漂移；拒绝在不完整的所有权链上创建新事务。'; return 1
        fi
    fi
    run_dir=$(run_directory "$run_id") || { die '找不到安全的 run。'; return 1; }
    [[ -r "$run_dir/plan.sha256" ]] || { die '该 run 尚未执行 plan。'; return 1; }
    verify_hash_manifest "$run_dir" "$run_dir/plan.sha256" || { die 'plan manifest 校验失败。'; return 1; }
    metrics="$run_dir/metrics.tsv"; plan_file="$run_dir/plan.tsv"
    validate_plan_file "$plan_file" || { die 'plan.tsv 格式或 key 白名单校验失败。'; return 1; }
    PACING_PLAN_ENABLED=1
    if plan_contains_key "$plan_file" net.core.default_qdisc; then
        qdisc_default_current=$(sysctl_read net.core.default_qdisc 2>/dev/null || true)
        if [[ "$mode" == safe && "$qdisc_default_current" != fq ]]; then
            PACING_PLAN_ENABLED=0
            pacing_skip_reason='safe 模式不允许把未实测的 default_qdisc=fq 延迟到重启后生效；仅报告 fq，仍可独立验证 BBR。'
        elif [[ "$mode" == fresh ]]; then
            qdisc_preflight_iface=$(single_peer_interface "$run_dir/peers.tsv" 2>/dev/null || true)
            qdisc_preflight_rc=1
            if [[ -n "$qdisc_preflight_iface" ]]; then
                qdisc_preflight_rc=0
                qdisc_fresh_candidate "$qdisc_preflight_iface" || qdisc_preflight_rc=$?
            fi
            if (( qdisc_preflight_rc != 0 && qdisc_preflight_rc != 2 )); then
                PACING_PLAN_ENABLED=0
                pacing_skip_reason='fresh 模式的出口 qdisc 不是可证明可替换的白名单拓扑；不持久化未实测 fq。'
            elif ! command_exists systemd-run || ! command_exists systemctl || [[ ! -d /run/systemd/system ]]; then
                PACING_PLAN_ENABLED=0
                pacing_skip_reason='无法建立 systemd 回滚守卫；不执行或持久化未实测 fq。'
            fi
        fi
    fi
    confidence=$(metric_get "$metrics" CONFIDENCE)
    retrans_known=$(metric_get "$metrics" RETRANS_KNOWN 2>/dev/null || printf '0')
    [[ "$confidence" == high && "$retrans_known" == 1 ]] || {
        if [[ "$retrans_known" != 1 ]]; then
            die 'TCP 重传计数不可证明：根据安全策略保持零变更。'
        else
            die '置信度不是 high：根据安全策略保持零变更。'
        fi
        return 1
    }
    if [[ -e "$STATE_DIR/transactions/$run_id" || -L "$STATE_DIR/transactions/$run_id" ]]; then
        [[ -d "$STATE_DIR/transactions/$run_id" && ! -L "$STATE_DIR/transactions/$run_id" ]] || {
            die '该 run 的事务路径不是安全的普通目录。'; return 1;
        }
        transaction="$STATE_DIR/transactions/$run_id"; status=$(cat "$transaction/status" 2>/dev/null || printf unknown)
        if [[ "$status" == committed ]]; then
            if verification=$(verify_current_state "$transaction" 2>&1); then
                if (( JSON_OUTPUT )) && [[ -r "$transaction/apply.json" ]]; then cat "$transaction/apply.json"
                else printf 'run %s 已提交且完整状态一致；重复 apply 为幂等操作。\n' "$run_id"; fi
                return 0
            fi
            [[ -z "$verification" ]] || printf '%s\n' "$verification" >&2
                die '该 run 已提交但完整状态发生漂移；拒绝把重复 apply 当作成功。'; return 1
        fi
        if [[ "$status" == pending-confirm ]]; then
            if (( JSON_OUTPUT )) && [[ -r "$transaction/apply.json" ]]; then cat "$transaction/apply.json"; else
                printf 'run %s 已等待确认；请执行 confirm --run %s。\n' "$run_id" "$run_id"
            fi
            return 20
        fi
        die "该 run 已有不可重用事务（status=$status）。"; return 1
    fi
    run_measurement_context_is_current "$run_dir" || { die "测量环境已变化或超过 ${RUN_TTL_SECONDS}s；请重新 measure/plan。"; return 1; }
    [[ ! -e "$SYSCTL_FILE" ]] || managed_file_is_known_owned "$SYSCTL_FILE" || { die "拒绝接管无所有权标记或未知格式的 $SYSCTL_FILE"; return 1; }
    [[ ! -L "$MODULES_FILE" ]] || { die "拒绝跟随符号链接: $MODULES_FILE"; return 1; }
    [[ ! -e "$MODULES_FILE" ]] || managed_file_is_known_owned "$MODULES_FILE" || { die "拒绝接管无所有权标记或未知格式的 $MODULES_FILE"; return 1; }
    pre_sysctl_identity=$(owned_path_identity "$SYSCTL_FILE") || { die '无法冻结 owned sysctl 文件身份。'; return 1; }
    pre_modules_identity=$(owned_path_identity "$MODULES_FILE") || { die '无法冻结 owned modules-load 文件身份。'; return 1; }
    plan_current_is_safe "$plan_file" || return 1
    prepare_service_change "$service" || return 1
    pre_service_needed=$SERVICE_DROPIN_NEEDED
    pre_service_path=$SERVICE_DROPIN_PATH
    pre_service_limit=$SERVICE_LIMIT
    pre_service_current=$SERVICE_CURRENT_LIMIT
    if (( DRY_RUN )); then
        trusted_tmp_dir || { die '/tmp 不是可信的 root-owned 目录。'; return 1; }
        dry_preview_dir=$(mktemp -d /tmp/vps-proxy-tune-apply.XXXXXXXX) || return 1
        APPLY_PREVIEW_DIR="$dry_preview_dir"
        trap apply_preview_exit_cleanup EXIT
        trap 'exit 130' INT TERM HUP
        chmod 0700 "$dry_preview_dir" || return 1
        persisted_preview="$dry_preview_dir/sysctl.conf.apply"
        all_plan="$dry_preview_dir/all-owned-plan.tsv"
    else
        persisted_preview="$run_dir/sysctl.conf.apply"
        all_plan="$run_dir/all-owned-plan.tsv"
    fi
    build_persisted_sysctl "$run_id" "$plan_file" "$persisted_preview" || return 1
    persisted_file_as_plan "$persisted_preview" "$all_plan" || return 1
    verify_retained_runtime "$all_plan" "$plan_file" || { die '已有 owned sysctl 的运行时值发生漂移；请先 verify/rollback。'; return 1; }
    if ! conflict=$(find_plan_conflicts "$all_plan"); then
        die '无法完整复查 sysctl 配置层级；保持零变更。'; return 1
    fi
    [[ -z "$conflict" ]] || { printf '%s\n' "$conflict" >&2; die '存在配置冲突或更晚加载的 sysctl.d 定义；保持零变更。'; return 1; }
    if (( DRY_RUN )); then
        if (( JSON_OUTPUT )); then
            write_apply_preview_json "$run_dir/plan.json" "$service" "$mode" "$pacing_skip_reason"
        else
            printf 'dry-run：所有检查通过，未修改系统。\n'
            [[ -z "$pacing_skip_reason" ]] || printf '[WARN] %s\n' "$pacing_skip_reason" >&2
            cat "$persisted_preview"
            print_service_change_preview "$service"
        fi
        if [[ -n "$dry_preview_dir" ]]; then
            rm -rf -- "$dry_preview_dir"
            APPLY_PREVIEW_DIR=""
            trap - EXIT INT TERM HUP
        fi
        return 0
    fi
    if (( assume_yes == 0 )); then
        [[ -t 0 ]] || { die '非交互环境必须显式提供 --yes。'; return 1; }
        print_service_change_preview "$service" >&2
        printf '即将应用 run=%s mode=%s；输入 "APPLY %s" 确认: ' "$run_id" "$mode" "$run_id" >&2
        IFS= read -r answer
        [[ "$answer" == "APPLY $run_id" ]] || { die '用户取消。'; return 1; }
    fi

    verify_hash_manifest "$run_dir" "$run_dir/plan.sha256" || { die '确认期间 plan 内容发生变化。'; return 1; }
    [[ $(owned_path_identity "$SYSCTL_FILE" 2>/dev/null || true) == "$pre_sysctl_identity" ]] || {
        die '确认期间 owned sysctl 文件发生变化；保持零变更。'; return 1;
    }
    [[ $(owned_path_identity "$MODULES_FILE" 2>/dev/null || true) == "$pre_modules_identity" ]] || {
        die '确认期间 owned modules-load 文件发生变化；保持零变更。'; return 1;
    }
    plan_current_is_safe "$plan_file" || return 1
    prepare_service_change "$service" || return 1
    if [[ "$SERVICE_DROPIN_NEEDED" != "$pre_service_needed" || "$SERVICE_DROPIN_PATH" != "$pre_service_path" ||
          "$SERVICE_LIMIT" != "$pre_service_limit" || "$SERVICE_CURRENT_LIMIT" != "$pre_service_current" ]]; then
        die '确认期间服务 LimitNOFILE 或 drop-in 状态发生变化；保持零变更。'; return 1
    fi
    build_persisted_sysctl "$run_id" "$plan_file" "$run_dir/sysctl.conf.apply" || return 1
    persisted_file_as_plan "$run_dir/sysctl.conf.apply" "$all_plan" || return 1
    verify_retained_runtime "$all_plan" "$plan_file" || { die '确认期间已有 owned sysctl 的运行时值发生漂移。'; return 1; }
    if ! conflict=$(find_plan_conflicts "$all_plan"); then
        die '确认后无法完整复查 sysctl 配置层级。'; return 1
    fi
    [[ -z "$conflict" ]] || { printf '%s\n' "$conflict" >&2; die '确认期间出现新的 sysctl 冲突。'; return 1; }
    while IFS=$'\t' read -r host port family address source _route_iface fingerprint route_unambiguous; do
        [[ "$route_unambiguous" == 1 ]] || { die "冻结路由包含无法证明唯一的下一跳: $address"; return 1; }
        route_is_unambiguous "$family" "$address" "$source" || { die "确认期间 peer 路由变为 ECMP 或无法证明唯一: $address"; return 1; }
        resolved=$(resolve_peer_host "$host" "$family" 2>/dev/null || printf unavailable)
        [[ "$resolved" == "$address" ]] || { die "确认期间 peer 地址族或 DNS 结果发生变化: $host"; return 1; }
        current_fp=$(route_fingerprint "$family" "$address" "$source" 2>/dev/null || printf unavailable)
        [[ "$current_fp" == "$fingerprint" ]] || { die "确认期间冻结路由发生变化: $address"; return 1; }
    done < "$run_dir/peers.tsv"

    secure_script_source || return 1
    transaction="$STATE_DIR/transactions/$run_id"
    transaction_tmp=$(mktemp -d "$STATE_DIR/transactions/.$run_id.XXXXXXXX") || return 1
    if ! chmod 0700 "$transaction_tmp" || ! install -d -m 0700 "$transaction_tmp/files"; then
        discard_transaction_staging "$transaction_tmp" || true
        die '无法建立事务暂存目录。'; return 1
    fi
    source_hash=$(sha256sum "$SELF_PATH" | awk '{print $1}') || {
        discard_transaction_staging "$transaction_tmp" || true; return 1;
    }
    if ! install -m 0700 "$SELF_PATH" "$transaction_tmp/guard-script.sh"; then
        discard_transaction_staging "$transaction_tmp" || true
        die '无法复制本地回滚守卫。'; return 1
    fi
    guard_hash=$(sha256sum "$transaction_tmp/guard-script.sh" | awk '{print $1}') || {
        discard_transaction_staging "$transaction_tmp" || true; return 1;
    }
    source_hash_after=$(sha256sum "$SELF_PATH" | awk '{print $1}') || {
        discard_transaction_staging "$transaction_tmp" || true; return 1;
    }
    if [[ ! "$source_hash" =~ ^[0-9a-f]{64}$ || "$source_hash" != "$guard_hash" || "$source_hash" != "$source_hash_after" ]]; then
        discard_transaction_staging "$transaction_tmp" || true
        die '主脚本在守卫复制期间变化或哈希不一致。'; return 1
    fi
    for stage_file in status.lock meta.tsv files.tsv files.identity.tsv changes.tsv apply.warnings; do
        : > "$transaction_tmp/$stage_file" || {
            discard_transaction_staging "$transaction_tmp" || true; return 1;
        }
        chmod 0600 "$transaction_tmp/$stage_file" || {
            discard_transaction_staging "$transaction_tmp" || true; return 1;
        }
    done
    if ! capture_runtime "$transaction_tmp/runtime.before.tsv" ||
       ! install -m 0600 "$all_plan" "$transaction_tmp/desired.tsv"; then
        discard_transaction_staging "$transaction_tmp" || true
        die '无法写入事务运行时快照。'; return 1
    fi
    if [[ -e "$STATE_DIR/current_run" || -L "$STATE_DIR/current_run" ]]; then
        if [[ ! -f "$STATE_DIR/current_run" || -L "$STATE_DIR/current_run" ]]; then
            discard_transaction_staging "$transaction_tmp" || true
            die 'current_run 指针不是安全的普通文件。'; return 1
        fi
        previous=$(cat "$STATE_DIR/current_run") || {
            discard_transaction_staging "$transaction_tmp" || true; return 1;
        }
        if ! validate_run_id "$previous" || [[ ! -d "$STATE_DIR/transactions/$previous" || -L "$STATE_DIR/transactions/$previous" ]] ||
           [[ $(cat "$STATE_DIR/transactions/$previous/status" 2>/dev/null || true) != committed ]]; then
            discard_transaction_staging "$transaction_tmp" || true
            die '当前事务链指针无效或前一事务未提交。'; return 1
        fi
    fi
    apply_starttime=$(process_start_time "$BASHPID" 2>/dev/null || true)
    if ! is_positive_uint "$apply_starttime" ||
       ! transaction_put "$transaction_tmp" RUN_ID "$run_id" ||
       ! transaction_put "$transaction_tmp" MANAGED_BY "$OWNER_ID" ||
       ! transaction_put "$transaction_tmp" FORMAT_VERSION "$STATE_FORMAT_VERSION" ||
       ! transaction_put "$transaction_tmp" WRITER_VERSION "$SCRIPT_VERSION" ||
       ! transaction_put "$transaction_tmp" MODE "$mode" ||
       ! transaction_put "$transaction_tmp" PREVIOUS_RUN "$previous" ||
       ! transaction_put "$transaction_tmp" SERVICE "$service" ||
       ! transaction_put "$transaction_tmp" APPLY_PID "$BASHPID" ||
       ! transaction_put "$transaction_tmp" APPLY_STARTTIME "$apply_starttime" ||
       ! transaction_put "$transaction_tmp" QDISC_CHANGED 0 ||
       ! snapshot_owned_file sysctl "$SYSCTL_FILE" "$transaction_tmp/files" "$transaction_tmp/files.tsv" "$transaction_tmp/files.identity.tsv" ||
       ! snapshot_owned_file modules "$MODULES_FILE" "$transaction_tmp/files" "$transaction_tmp/files.tsv" "$transaction_tmp/files.identity.tsv"; then
        discard_transaction_staging "$transaction_tmp" || true
        die '无法完成事务元数据或 owned 文件快照。'; return 1
    fi
    if (( SERVICE_DROPIN_NEEDED )) &&
       ! snapshot_owned_file service "$SERVICE_DROPIN_PATH" "$transaction_tmp/files" "$transaction_tmp/files.tsv" "$transaction_tmp/files.identity.tsv"; then
        discard_transaction_staging "$transaction_tmp" || true
        die '无法快照服务 drop-in。'; return 1
    fi
    if (( SERVICE_DROPIN_NEEDED )); then
        current=$(awk -F'\t' '$1=="service"{print $3;exit}' "$transaction_tmp/files.tsv") || {
            discard_transaction_staging "$transaction_tmp" || true; return 1;
        }
        if [[ "$current" == 1 ]]; then
            guard_hash=$(awk -F'\t' '$1=="service"{print $5;exit}' "$transaction_tmp/files.tsv") || {
                discard_transaction_staging "$transaction_tmp" || true; return 1;
            }
            if ! transaction_put "$transaction_tmp" SERVICE_PREVIOUS_HASH "$guard_hash"; then
                discard_transaction_staging "$transaction_tmp" || true; return 1
            fi
        fi
    fi
    # meta.tsv, status, changes.tsv and apply.warnings are mutable transaction
    # WAL/state views.  Bind them to private hash records before publishing the
    # transaction; every later append/status transition refreshes the record.
    if ! write_private_hash_record "$transaction_tmp/meta.tsv" "$transaction_tmp/meta.sha256" ||
       ! write_private_hash_record "$transaction_tmp/status" "$transaction_tmp/status.sha256" ||
       ! write_private_hash_record "$transaction_tmp/changes.tsv" "$transaction_tmp/changes.tsv.sha256" ||
       ! write_private_hash_record "$transaction_tmp/apply.warnings" "$transaction_tmp/apply.warnings.sha256" ||
       ! create_transaction_snapshot_manifest "$transaction_tmp" ||
       ! verify_hash_manifest "$transaction_tmp" "$transaction_tmp/snapshot.sha256" ||
       ! set_transaction_status "$transaction_tmp" prepared ||
       ! mv -T -- "$transaction_tmp" "$transaction"; then
        discard_transaction_staging "$transaction_tmp" || true
        die '无法原子发布事务快照。'; return 1
    fi
    transaction_tmp=""
    arm_apply_cleanup "$transaction"
    if [[ -e "$STATE_DIR/baseline/initial" || -L "$STATE_DIR/baseline/initial" ]]; then
        baseline_existed=1
    fi
    # Publish the complete transaction snapshot before creating persistent
    # recovery material.  Until current_run is updated, every failure must
    # either remove this prepared transaction and a newly-created baseline or
    # leave the authenticated artifacts for explicit recovery/status handling.
    if (( baseline_existed == 0 )); then
        # Mark the compensating cleanup before entering the baseline creator so
        # a failure halfway through its publish cannot lose track of a partial
        # initial directory.
        APPLY_BASELINE_CREATED=1
        APPLY_BASELINE_EXPECT_NEW=1
    fi
    if ! create_initial_baseline "$run_dir"; then
        cleanup_unpublished_transaction "$transaction" || true
        return 1
    fi
    APPLY_BASELINE_EXPECT_NEW=0
    RECOVERY_UNIT_HOLD_BACKUP=1
    if ! ensure_recovery_unit "$run_id"; then
        cleanup_unpublished_transaction "$transaction" || true
        return 1
    fi
    if [[ -n "$pacing_skip_reason" ]]; then
        transaction_append_mutable_line "$transaction" apply.warnings "$pacing_skip_reason" || {
            apply_failure "$transaction" '无法记录 qdisc 安全策略警告'; return 1;
        }
    fi
    if ! write_current_run "$run_id"; then
        restore_held_recovery_unit || warn 'current_run 发布失败且旧恢复材料无法恢复；保留恢复备份供 status/recover 检测。'
        RECOVERY_UNIT_HOLD_BACKUP=0
        apply_failure "$transaction" '无法在变更前发布可恢复的 current_run 指针'; return 1
    fi
    if ! commit_held_recovery_unit; then
        restore_held_recovery_unit || warn '恢复单元补偿备份提交失败且旧材料无法恢复；保留恢复备份供 status/recover 检测。'
        RECOVERY_UNIT_HOLD_BACKUP=0
        apply_failure "$transaction" '无法提交启动恢复单元补偿备份'; return 1
    fi
    RECOVERY_UNIT_HOLD_BACKUP=0
    if plan_entry_enabled net.ipv4.tcp_congestion_control && plan_contains_key "$plan_file" net.ipv4.tcp_congestion_control; then
        value=$(awk -F'\t' '$1=="net.ipv4.tcp_congestion_control"{print $2}' "$plan_file")
        cc_available_current=$(sysctl_read net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
        if [[ "$value" == bbr && ! -d "$SYS_ROOT/module/tcp_bbr" && " $cc_available_current " != *' bbr '* ]]; then
            modules_needed=1; bbr_module_needed=1
        fi
    fi
    if plan_entry_enabled net.core.default_qdisc && plan_contains_key "$plan_file" net.core.default_qdisc; then
        value=$(awk -F'\t' '$1=="net.core.default_qdisc"{print $2}' "$plan_file")
        qdisc_default_current=$(sysctl_read net.core.default_qdisc 2>/dev/null || true)
        if [[ "$value" == fq && ! -d "$SYS_ROOT/module/sch_fq" && "$qdisc_default_current" != fq ]]; then
            modules_needed=1; fq_module_needed=1
        fi
    fi
    if ! set_transaction_status "$transaction" applying; then
        apply_failure "$transaction" '无法记录事务 applying 状态'; return 1
    fi
    if ! start_rollback_guard "$transaction"; then
        apply_failure "$transaction" '无法建立通用 systemd 回滚守卫；拒绝开始系统变更'; return 1
    fi
    if (( modules_needed )); then
        (( bbr_module_needed == 0 )) || { command_exists modprobe && modprobe tcp_bbr >/dev/null 2>&1; } || {
            apply_failure "$transaction" '无法加载发行版内核 tcp_bbr 模块'; return 1;
        }
        (( fq_module_needed == 0 )) || { command_exists modprobe && modprobe sch_fq >/dev/null 2>&1; } || {
            apply_failure "$transaction" '无法加载发行版内核 sch_fq 模块'; return 1;
        }
    fi
    while IFS=$'\t' read -r key value before reason change_type; do
        plan_entry_enabled "$key" || continue
        transaction_is_applying "$transaction" || { apply_failure "$transaction" '事务已被回滚守卫接管'; return 1; }
        current=$(sysctl_read "$key" 2>/dev/null || true); [[ "$current" == "$value" ]] && continue
        if [[ "$current" != "$before" ]]; then
            apply_failure "$transaction" "sysctl 在写入前发生竞态变化: $key"; return 1
        fi
        if ! sysctl -q -w "$key=$value" >/dev/null; then apply_failure "$transaction" "sysctl 写入失败: $key"; return 1; fi
        if ! transaction_append_mutable_line "$transaction" changes.tsv \
            "sysctl${TAB}$key${TAB}$current${TAB}$value${TAB}${change_type:-runtime_change}"; then
            apply_failure "$transaction" '无法记录 sysctl 实际变更'; return 1
        fi
    done < "$plan_file"
    verify_plan_runtime "$plan_file" || { apply_failure "$transaction" 'sysctl 逐项验证失败'; return 1; }

    if [[ "$mode" == fresh ]] && (( PACING_PLAN_ENABLED == 1 )) &&
       [[ $(sysctl_read net.ipv4.tcp_congestion_control 2>/dev/null || true) == bbr ]] &&
       [[ $(sysctl_read net.core.default_qdisc 2>/dev/null || true) == fq ]]; then
        iface=$(single_peer_interface "$run_dir/peers.tsv" 2>/dev/null || true)
        if [[ -n "$iface" ]]; then
            qdisc_rc=0; qdisc_fresh_candidate "$iface" || qdisc_rc=$?
            if (( qdisc_rc == 0 )); then
                qdisc_before=$(interface_qdisc_kind "$iface")
                qdisc_before_hash=$(qdisc_root_fingerprint "$iface" 2>/dev/null || true)
                qdisc_before_spec=$(qdisc_root_restore_spec "$iface" 2>/dev/null || true)
                if ! transaction_put "$transaction" QDISC_IFACE "$iface" ||
                   ! transaction_put "$transaction" QDISC_BEFORE "$qdisc_before" ||
                   [[ ! "$qdisc_before_hash" =~ ^[0-9a-f]{64}$ ]] ||
                   ! qdisc_spec_is_safe "$qdisc_before_spec" ||
                   ! transaction_put "$transaction" QDISC_BEFORE_SPEC "$qdisc_before_spec" ||
                   ! transaction_put "$transaction" QDISC_BEFORE_HASH "$qdisc_before_hash"; then
                    apply_failure "$transaction" '无法记录 qdisc 变更前状态'; return 1
                fi
                if ! transaction_put "$transaction" QDISC_CHANGED 1; then
                    apply_failure "$transaction" '无法记录 qdisc 变更意图'; return 1
                fi
                qdisc_rc=0; qdisc_fresh_candidate "$iface" || qdisc_rc=$?
                if (( qdisc_rc != 0 )); then
                    apply_failure "$transaction" 'qdisc 在 live 替换紧前不再满足完整 fresh 白名单'; return 1
                fi
                if [[ $(qdisc_root_fingerprint "$iface" 2>/dev/null || true) != "$qdisc_before_hash" ]]; then
                    apply_failure "$transaction" 'qdisc 在 live 替换前发生竞态变化'; return 1
                fi
                if tc qdisc replace dev "$iface" root fq; then
                    qdisc_changed=1
                    if [[ $(interface_qdisc_kind "$iface" 2>/dev/null || true) != fq ]]; then
                        apply_failure "$transaction" 'live qdisc 替换后类型不是 fq'; return 1
                    fi
                    qdisc_after_hash=$(qdisc_root_fingerprint "$iface" 2>/dev/null || true)
                    if [[ ! "$qdisc_after_hash" =~ ^[0-9a-f]{64}$ ]] ||
                       ! transaction_put "$transaction" QDISC_AFTER_HASH "$qdisc_after_hash" ||
                       ! transaction_append_mutable_line "$transaction" changes.tsv \
                           "qdisc${TAB}$iface${TAB}$qdisc_before${TAB}fq${TAB}runtime_change"; then
                        apply_failure "$transaction" '无法验证或记录 live qdisc 指纹'; return 1
                    fi
                else
                    apply_failure "$transaction" 'live qdisc 替换失败'; return 1
                fi
            elif (( qdisc_rc == 2 )); then
                transaction_append_mutable_line "$transaction" apply.warnings \
                    'root qdisc 已是 fq，无需 live 替换。' || {
                    apply_failure "$transaction" '无法记录 qdisc no-op 警告'; return 1;
                }
            else
                # The plan currently includes default_qdisc=fq.  If the
                # topology changed after preflight, continuing would persist
                # an unverified pacing default even though the live qdisc was
                # not replaced.  Abort and roll back the whole transaction so
                # the fail-closed path cannot leave that half-verified state.
                apply_failure "$transaction" 'qdisc 在 live 替换前发生竞态或不再满足 fresh 白名单'; return 1
            fi
        else
            apply_failure "$transaction" '无法在 live qdisc 验证时唯一确定出口接口'; return 1
        fi
    fi
    if ! post_apply_verify "$run_dir" "$transaction"; then
        apply_failure "$transaction" "$POST_VERIFY_REASON"; return 1
    fi
    transaction_is_applying "$transaction" || { apply_failure "$transaction" '复测期间事务被回滚守卫接管'; return 1; }

    source_hash=$(sha256sum "$run_dir/sysctl.conf.apply" | awk '{print $1}') || {
        apply_failure "$transaction" '无法计算预期 sysctl 持久化哈希'; return 1;
    }
    if [[ ! "$source_hash" =~ ^[0-9a-f]{64}$ ]] || ! transaction_put "$transaction" SYSCTL_HASH "$source_hash"; then
        apply_failure "$transaction" '无法预写 sysctl 持久化 WAL'; return 1
    fi
    if ! transaction_is_applying "$transaction" || ! owned_target_matches_snapshot "$transaction" sysctl; then
        apply_failure "$transaction" 'sysctl owned 文件在写入前发生竞态变化'; return 1
    fi
    if ! conflict=$(find_plan_conflicts "$all_plan"); then
        apply_failure "$transaction" '持久化前无法完整复查 sysctl 配置层级'; return 1
    fi
    [[ -z "$conflict" ]] || { apply_failure "$transaction" '持久化前出现新的 sysctl 配置冲突'; return 1; }
    if ! atomic_install "$run_dir/sysctl.conf.apply" "$SYSCTL_FILE" 0644; then
        apply_failure "$transaction" 'sysctl 持久化原子写入失败'; return 1
    fi
    record_owned_after_identity "$transaction" sysctl || {
        apply_failure "$transaction" '无法记录 sysctl 持久化文件 inode/权限'; return 1;
    }
    if ! conflict=$(find_plan_conflicts "$all_plan"); then
        apply_failure "$transaction" '持久化后无法完整复查 sysctl 配置层级'; return 1
    fi
    [[ -z "$conflict" ]] || { apply_failure "$transaction" '持久化期间出现新的 sysctl 配置冲突'; return 1; }
    guard_hash=$(sha256sum "$SYSCTL_FILE" | awk '{print $1}') || {
        apply_failure "$transaction" '无法验证 sysctl 持久化哈希'; return 1;
    }
    if [[ "$guard_hash" != "$source_hash" ]] ||
       ! transaction_append_mutable_line "$transaction" changes.tsv \
           "file${TAB}$SYSCTL_FILE${TAB}$(awk -F'\t' '$1==\"sysctl\"{print $5;exit}' "$transaction/files.tsv")${TAB}$source_hash${TAB}runtime_change"; then
        apply_failure "$transaction" '无法记录 sysctl 持久化变更'; return 1
    fi
    if (( modules_needed )); then
        modules_temp="$transaction/modules.conf"
        module_seen=()
        if (( bbr_module_needed )); then module_seen[tcp_bbr]=1; fi
        if (( fq_module_needed )); then module_seen[sch_fq]=1; fi
        if ! {
            managed_marker
            managed_metadata "$run_id"
            if (( bbr_module_needed )); then printf 'tcp_bbr\n'; fi
            if (( fq_module_needed )); then printf 'sch_fq\n'; fi
            # Preserve other modules previously owned by this tool.  A
            # transaction that needs one new module must not silently remove a
            # different previously-owned module.
            if [[ -f "$MODULES_FILE" ]] && managed_file_is_known_owned "$MODULES_FILE"; then
                while IFS= read -r modules_line || [[ -n "$modules_line" ]]; do
                    modules_line=${modules_line%%#*}; modules_line=$(trim "$modules_line")
                    [[ -z "$modules_line" ]] && continue
                    [[ "$modules_line" =~ ^[A-Za-z0-9_]+$ ]] || {
                        apply_failure "$transaction" '已有 owned modules-load 文件包含无法解释的模块名'; return 1;
                    }
                    [[ -n "${module_seen[$modules_line]+x}" ]] && continue
                    module_seen[$modules_line]=1
                    printf '%s\n' "$modules_line"
                done < "$MODULES_FILE"
            fi
        } > "$modules_temp"; then
            apply_failure "$transaction" '无法生成 modules-load 内容'; return 1
        fi
        guard_hash=$(sha256sum "$modules_temp" | awk '{print $1}') || {
            apply_failure "$transaction" '无法计算预期 modules-load 哈希'; return 1;
        }
        if [[ ! "$guard_hash" =~ ^[0-9a-f]{64}$ ]] || ! transaction_put "$transaction" MODULES_HASH "$guard_hash"; then
            apply_failure "$transaction" '无法预写 modules-load WAL'; return 1
        fi
        if ! transaction_is_applying "$transaction" || ! owned_target_matches_snapshot "$transaction" modules; then
            apply_failure "$transaction" 'modules-load 文件在写入前发生竞态变化'; return 1
        fi
        if ! atomic_install "$modules_temp" "$MODULES_FILE" 0644; then apply_failure "$transaction" 'modules-load 持久化失败'; return 1; fi
        record_owned_after_identity "$transaction" modules || {
            apply_failure "$transaction" '无法记录 modules-load 文件 inode/权限'; return 1;
        }
        source_hash=$(sha256sum "$MODULES_FILE" | awk '{print $1}') || {
            apply_failure "$transaction" '无法计算 modules-load 哈希'; return 1;
        }
        if [[ "$source_hash" != "$guard_hash" ]] ||
           ! transaction_append_mutable_line "$transaction" changes.tsv \
               "file${TAB}$MODULES_FILE${TAB}$(awk -F'\t' '$1==\"modules\"{print $5;exit}' "$transaction/files.tsv")${TAB}$guard_hash${TAB}runtime_change"; then
            apply_failure "$transaction" '无法记录 modules-load 变更'; return 1
        fi
    fi
    if (( SERVICE_DROPIN_NEEDED )); then
        service_temp="$transaction/service.conf"
        if ! { managed_marker; managed_metadata "$run_id"; printf '[Service]\nLimitNOFILE=%s:%s\n' "$SERVICE_LIMIT" "$SERVICE_LIMIT_HARD"; } > "$service_temp"; then
            apply_failure "$transaction" '无法生成服务 drop-in 内容'; return 1
        fi
        guard_hash=$(sha256sum "$service_temp" | awk '{print $1}') || {
            apply_failure "$transaction" '无法计算预期服务 drop-in 哈希'; return 1;
        }
        if [[ ! "$guard_hash" =~ ^[0-9a-f]{64}$ ]] ||
           ! transaction_put "$transaction" SERVICE_PATH "$SERVICE_DROPIN_PATH" ||
           ! transaction_put "$transaction" SERVICE_HASH "$guard_hash"; then
            apply_failure "$transaction" '无法预写服务 drop-in WAL'; return 1
        fi
        if ! transaction_is_applying "$transaction" || ! owned_target_matches_snapshot "$transaction" service; then
            apply_failure "$transaction" '服务 drop-in 在写入前发生竞态变化'; return 1
        fi
        if ! atomic_install "$service_temp" "$SERVICE_DROPIN_PATH" 0644; then
            apply_failure "$transaction" '服务 drop-in 持久化失败'; return 1
        fi
        record_owned_after_identity "$transaction" service || {
            apply_failure "$transaction" '无法记录服务 drop-in inode/权限'; return 1;
        }
        source_hash=$(sha256sum "$SERVICE_DROPIN_PATH" | awk '{print $1}') || {
            apply_failure "$transaction" '无法计算服务 drop-in 哈希'; return 1;
        }
        if [[ "$source_hash" != "$guard_hash" ]]; then
            apply_failure "$transaction" '无法记录服务 drop-in 所有权哈希'; return 1
        fi
        systemctl daemon-reload >/dev/null 2>&1 || { apply_failure "$transaction" 'systemd daemon-reload 失败'; return 1; }
        verify_service_limit_after_reload "$service" || {
            apply_failure "$transaction" 'daemon-reload 后 systemd 服务 LimitNOFILE 未达到预期'; return 1;
        }
        if ! transaction_append_mutable_line "$transaction" changes.tsv \
                "file${TAB}$SERVICE_DROPIN_PATH${TAB}$(awk -F'\t' '$1==\"service\"{print $5;exit}' "$transaction/files.tsv")${TAB}$guard_hash${TAB}persist_only" ||
           ! transaction_append_mutable_line "$transaction" changes.tsv \
                "service${TAB}$service${TAB}LimitNOFILE=${SERVICE_CURRENT_LIMIT:-unknown}${TAB}LimitNOFILE=$SERVICE_LIMIT:$SERVICE_LIMIT_HARD (restart required; observed=${SERVICE_EFFECTIVE_AFTER:-unknown})" ||
           ! transaction_append_mutable_line "$transaction" apply.warnings \
                '服务未重启；LimitNOFILE 将在管理员下次重启该服务时生效。'; then
            apply_failure "$transaction" '无法记录服务 drop-in 变更'; return 1
        fi
    fi
    cmp -s "$run_dir/sysctl.conf.apply" "$SYSCTL_FILE" || { apply_failure "$transaction" '持久化文件内容不一致'; return 1; }
    verify_plan_runtime "$all_plan" || { apply_failure "$transaction" '持久化后运行时值不一致'; return 1; }
    if (( SERVICE_DROPIN_NEEDED )); then
        guard_hash=$(transaction_get "$transaction" SERVICE_HASH 2>/dev/null || true)
        if ! set_service_registry "$service" "$SERVICE_DROPIN_PATH" "$guard_hash"; then
            apply_failure "$transaction" '服务所有权登记失败'; return 1
        fi
    fi
    source_hash=$(sha256sum "$SYSCTL_FILE" | awk '{print $1}') || {
        apply_failure "$transaction" '无法写入最终 sysctl 哈希'; return 1;
    }
    if [[ ! "$source_hash" =~ ^[0-9a-f]{64}$ ]] || ! transaction_put "$transaction" SYSCTL_HASH "$source_hash"; then
        apply_failure "$transaction" '最终 sysctl 哈希无效'; return 1
    fi
    if [[ -f "$MODULES_FILE" ]]; then
        guard_hash=$(sha256sum "$MODULES_FILE" | awk '{print $1}') || {
            apply_failure "$transaction" '无法写入最终 modules-load 哈希'; return 1;
        }
        if [[ ! "$guard_hash" =~ ^[0-9a-f]{64}$ ]] || ! transaction_put "$transaction" MODULES_HASH "$guard_hash"; then
            apply_failure "$transaction" '最终 modules-load 哈希无效'; return 1
        fi
    fi
    if (( SERVICE_DROPIN_NEEDED )); then
        guard_hash=$(sha256sum "$SERVICE_DROPIN_PATH" | awk '{print $1}') || {
            apply_failure "$transaction" '无法写入最终服务 drop-in 哈希'; return 1;
        }
        if [[ ! "$guard_hash" =~ ^[0-9a-f]{64}$ ]] ||
           ! transaction_put "$transaction" SERVICE_PATH "$SERVICE_DROPIN_PATH" ||
           ! transaction_put "$transaction" SERVICE_HASH "$guard_hash"; then
            apply_failure "$transaction" '最终服务 drop-in 元数据无效'; return 1
        fi
    fi
    POST_VERIFY_REASON=""
    set_outcome 'pending_confirm' 'awaiting_confirmation'
    if ! write_apply_json "$run_dir" "$transaction" pending-confirm; then
        apply_failure "$transaction" '无法生成 apply JSON 报告'; return 1
    fi
    status=$(cat "$transaction/status" 2>/dev/null || printf unknown)
    current=$(cat "$STATE_DIR/current_run" 2>/dev/null || printf unknown)
    if [[ "$status" != applying || "$current" != "$run_id" ]]; then
        apply_failure "$transaction" '回滚守卫与 apply 状态握手失败'; return 1
    fi
    if ! verification=$(verify_current_state "$transaction" 2>&1); then
        [[ -z "$verification" ]] || printf '%s\n' "$verification" >&2
        apply_failure "$transaction" '提交前完整状态复核失败'; return 1
    fi
    transaction_is_applying "$transaction" || { apply_failure "$transaction" '提交前回滚守卫已接管事务'; return 1; }
    if ! compare_set_transaction_status "$transaction" applying pending-confirm; then
        apply_failure "$transaction" '无法进入 pending-confirm 状态；回滚守卫可能已接管'; return 1
    fi
    disarm_apply_cleanup
    if (( JSON_OUTPUT )); then cat "$transaction/apply.json"
    else
        printf '应用已完成复测但尚未提交: run=%s mode=%s。请在管理会话执行 confirm --run %s（守卫将在确认超时后自动回滚）。\n' "$run_id" "$mode" "$run_id"
        if (( POST_VERIFY_RETRANS_KNOWN )); then
            printf '复测: %s Mbps，loaded RTT 增量=%s ms，重传估算=%s%%\n' "$POST_VERIFY_MBPS" "$POST_VERIFY_LOADED_DELTA" "$POST_VERIFY_RETRANS_PCT"
        else
            printf '复测: %s Mbps，loaded RTT 增量=%s ms，重传估算=unknown\n' "$POST_VERIFY_MBPS" "$POST_VERIFY_LOADED_DELTA"
        fi
        (( qdisc_changed == 0 )) || printf 'live qdisc 已在回滚守卫保护下切换为 fq，等待确认。\n'
        [[ ! -s "$transaction/apply.warnings" ]] || sed 's/^/[WARN] /' "$transaction/apply.warnings" >&2
    fi
    return 20
}

cmd_guard_rollback() {
    local run_id="" transaction status
    DRY_RUN=0; JSON_ERROR_EMITTED=0
    while (($#)); do
        case "$1" in
            --transaction) shift; (($#)) || return 2; run_id=$1; shift ;;
            *) return 2 ;;
        esac
    done
    (( EUID == 0 )) || return 1
    require_real_apply_roots || return 1
    require_recovery_commands || return 1
    validate_run_id "$run_id" || return 1
    ensure_secure_state || return 1
    transaction="$STATE_DIR/transactions/$run_id"
    [[ -d "$transaction" && ! -L "$transaction" ]] || return 1
    transaction_snapshot_is_valid "$transaction" || return 1
    status=$(cat "$transaction/status" 2>/dev/null || printf unknown)
    [[ "$status" != committed && "$status" != rolled-back ]] || return 0
    # A guard is an automatic recovery writer.  Before it changes the
    # transaction state, reject unrelated orphan/corrupt records so it cannot
    # silently advance a partially compromised chain.
    validate_transaction_chain "$run_id" || return 1
    if ! compare_set_transaction_status "$transaction" "$status" guard-restoring; then
        status=$(cat "$transaction/status" 2>/dev/null || printf unknown)
        [[ "$status" == committed || "$status" == rolled-back ]] && return 0
        return 1
    fi
    # Do not wait for the apply process while it still owns the global lock:
    # the guard must first claim the transaction, terminate that owner, and
    # only then acquire the lock needed for restoration.
    terminate_apply_owner "$transaction" || return 1
    acquire_lock 30 || return 1
    status=$(cat "$transaction/status" 2>/dev/null || printf unknown)
    [[ "$status" != committed && "$status" != rolled-back ]] || return 0
    [[ "$status" == guard-restoring ]] || return 1
    [[ $(cat "$STATE_DIR/current_run" 2>/dev/null || true) == "$run_id" ]] || return 1
    restore_transaction "$transaction"
}

recovery_record_refers_to_hash() {
    local target="$1" record="$2" expected_hash="$3" recorded_hash recorded_inode recorded_mode extra
    # The target may already have been restored when the companion hash record
    # is removed.  The record itself is the authenticated object here; tying
    # it to the target's current bytes would make a safe pair rollback look
    # like drift after the target has been put back.
    [[ "$target" == "$STATE_DIR/"* && "$record" == "$STATE_DIR/"* &&
       -f "$record" && ! -L "$record" ]] || return 1
    secure_private_path "$record" || return 1
    IFS=$'\t' read -r recorded_hash recorded_inode recorded_mode extra < "$record" || return 1
    [[ "$recorded_hash" == "$expected_hash" && -z "${extra:-}" ]] || return 1
    [[ -z "${recorded_inode:-}" || "$recorded_inode" =~ ^[0-9]+$ ]] || return 1
    [[ -z "${recorded_mode:-}" || "$recorded_mode" =~ ^[0-7]{3,4}$ ]] || return 1
}

recovery_remove_new_hash_record() {
    local target="$1" record="$2" expected_hash="$3"
    if [[ ! -e "$record" && ! -L "$record" ]]; then return 0; fi
    recovery_record_refers_to_hash "$target" "$record" "$expected_hash" || return 1
    rm -f -- "$record"
}

recovery_script_staging_cleanup() {
    local path="${1:-}"
    (($# == 1)) || return 1
    [[ "$path" == "$STATE_DIR"/.recovery-script.???????? ]] || return 1
    if [[ -e "$path" || -L "$path" ]]; then
        [[ -f "$path" && ! -L "$path" ]] || return 1
        rm -f -- "$path" || return 1
    fi
    [[ ! -e "$path" && ! -L "$path" ]]
}

recovery_script_failure_cleanup() {
    local temp="$1" backup="$2" message="$3" cleanup_rc=0
    recovery_script_staging_cleanup "$temp" || cleanup_rc=1
    if (( cleanup_rc == 0 )); then
        discard_recovery_rollback_backup "$backup" "$message" || cleanup_rc=1
    fi
    if (( cleanup_rc )); then
        # Keep the authenticated rollback directory when either the temporary
        # file or the backup cannot be removed.  The marker makes the partial
        # compensation explicit to ensure_secure_state/status instead of
        # turning it into an unexplained hidden file.
        if [[ -d "$backup" && ! -L "$backup" ]]; then
            write_recovery_failure_marker "$backup" "$message" || true
        fi
        warn "恢复脚本失败清理不完整；保留恢复证据: $backup"
        return 1
    fi
    return 0
}

recovery_restore_pair() {
    local target="$1" record="$2" backup="$3" had_target="$4" had_record="$5" target_mode="$6" expected_new_hash="$7"
    local expected_new_inode="${8:-}" expected_new_mode="${9:-}" expected_old_inode="${10:-}" expected_old_mode="${11:-}"
    local old_hash current_hash current_inode current_mode rc=0
    [[ "$target" == "$STATE_DIR/"* || "$target" == "$ETC_ROOT/"* ]] || return 1
    [[ "$record" == "$STATE_DIR/"* && "$backup" == "$STATE_DIR/"* ]] || return 1
    if [[ -n "$expected_new_inode" || -n "$expected_new_mode" ]]; then
        [[ "$expected_new_inode" =~ ^[1-9][0-9]*$ && "$expected_new_mode" =~ ^[0-7]{3,4}$ ]] || return 1
    fi
    if [[ -n "$expected_old_inode" || -n "$expected_old_mode" ]]; then
        [[ "$expected_old_inode" =~ ^[1-9][0-9]*$ && "$expected_old_mode" =~ ^[0-7]{3,4}$ ]] || return 1
    fi
    if (( had_target )); then
        [[ -f "$backup" && ! -L "$backup" ]] || return 1
        old_hash=$(sha256sum "$backup" 2>/dev/null | awk '{print $1}') || return 1
        current_hash=$(sha256sum "$target" 2>/dev/null | awk '{print $1}' || true)
        if [[ "$current_hash" == "$old_hash" ]]; then
            # Even byte-identical content is not enough here: a replacement
            # inode or chmod drift must not be silently adopted as our old
            # recovery artifact.  Callers pass the pre-change identity.
            [[ "$expected_old_inode" =~ ^[1-9][0-9]*$ && "$expected_old_mode" =~ ^[0-7]{3,4}$ ]] || rc=1
            if (( rc == 0 )); then
                current_inode=$(stat -c %i "$target" 2>/dev/null || true)
                current_mode=$(stat -c %a "$target" 2>/dev/null || true)
                [[ "$current_inode" == "$expected_old_inode" && "$current_mode" == "$expected_old_mode" ]] || rc=1
            fi
        elif [[ "$current_hash" == "$expected_new_hash" ]]; then
            # A same-content replacement after the new install is equally
            # untrusted.  Restore only when the post-install identity is the
            # one observed by this operation.
            if [[ "$expected_new_inode" =~ ^[1-9][0-9]*$ && "$expected_new_mode" =~ ^[0-7]{3,4}$ ]]; then
                current_inode=$(stat -c %i "$target" 2>/dev/null || true)
                current_mode=$(stat -c %a "$target" 2>/dev/null || true)
                if [[ "$current_inode" == "$expected_new_inode" && "$current_mode" == "$expected_new_mode" ]]; then
                    atomic_install "$backup" "$target" "$target_mode" || rc=1
                else
                    rc=1
                fi
            else
                rc=1
            fi
        else
            rc=1
        fi
        if (( rc == 0 )); then
            if (( had_record )); then
                write_private_hash_record "$target" "$record" || rc=1
            elif [[ -e "$record" || -L "$record" ]]; then
                recovery_remove_new_hash_record "$target" "$record" "$expected_new_hash" || rc=1
            fi
        fi
    else
        if [[ -e "$target" || -L "$target" ]]; then
            current_hash=$(sha256sum "$target" 2>/dev/null | awk '{print $1}' || true)
            if [[ "$current_hash" == "$expected_new_hash" ]] && secure_owned_file "$target" &&
               [[ "$expected_new_inode" =~ ^[1-9][0-9]*$ && "$expected_new_mode" =~ ^[0-7]{3,4}$ ]]; then
                current_inode=$(stat -c %i "$target" 2>/dev/null || true)
                current_mode=$(stat -c %a "$target" 2>/dev/null || true)
                if [[ "$current_inode" == "$expected_new_inode" && "$current_mode" == "$expected_new_mode" ]]; then
                    rm -f -- "$target" || rc=1
                else
                    rc=1
                fi
            else
                rc=1
            fi
        fi
        if [[ -e "$record" || -L "$record" ]]; then
            recovery_remove_new_hash_record "$target" "$record" "$expected_new_hash" || rc=1
        fi
    fi
    return "$rc"
}

ensure_recovery_script_snapshot() {
    local temp source_hash source_hash_after snapshot_hash current_hash mode backup="" had_script=0 had_record=0 restore_rc=0 cleanup_rc=0
    local old_inode="" old_mode="" new_inode="" new_mode="" snapshot_failed=0
    secure_script_source || return 1
    [[ "$RECOVERY_SCRIPT_PATH" =~ ^/[A-Za-z0-9._/+:-]+$ ]] || return 1
    if [[ -e "$RECOVERY_SCRIPT_PATH" || -L "$RECOVERY_SCRIPT_PATH" ]]; then
        [[ -f "$RECOVERY_SCRIPT_PATH" && ! -L "$RECOVERY_SCRIPT_PATH" ]] || return 1
        if [[ -e "$RECOVERY_SCRIPT_HASH_FILE" || -L "$RECOVERY_SCRIPT_HASH_FILE" ]]; then
            verify_private_hash_record "$RECOVERY_SCRIPT_PATH" "$RECOVERY_SCRIPT_HASH_FILE" || {
                die '持久恢复脚本快照哈希不一致；拒绝覆盖。'; return 1;
            }
        else
            secure_owned_file "$RECOVERY_SCRIPT_PATH" || return 1
        fi
        had_script=1
        old_inode=$(stat -c %i "$RECOVERY_SCRIPT_PATH" 2>/dev/null || true)
        old_mode=$(stat -c %a "$RECOVERY_SCRIPT_PATH" 2>/dev/null || true)
        [[ "$old_inode" =~ ^[1-9][0-9]*$ && "$old_mode" =~ ^[0-7]{3,4}$ ]] || return 1
        [[ -e "$RECOVERY_SCRIPT_HASH_FILE" || -L "$RECOVERY_SCRIPT_HASH_FILE" ]] && had_record=1
    elif [[ -e "$RECOVERY_SCRIPT_HASH_FILE" || -L "$RECOVERY_SCRIPT_HASH_FILE" ]]; then
        die '恢复脚本哈希记录存在但脚本快照缺失；拒绝接管。'
        return 1
    fi
    source_hash=$(sha256sum "$SELF_PATH" 2>/dev/null | awk '{print $1}') || return 1
    source_hash_after=$(sha256sum "$SELF_PATH" 2>/dev/null | awk '{print $1}') || return 1
    [[ "$source_hash" =~ ^[0-9a-f]{64}$ && "$source_hash" == "$source_hash_after" ]] || return 1
    if (( had_script )); then
        current_hash=$(sha256sum "$RECOVERY_SCRIPT_PATH" 2>/dev/null | awk '{print $1}' || true)
        mode=$(stat -c %a "$RECOVERY_SCRIPT_PATH" 2>/dev/null || true)
        if [[ "$current_hash" == "$source_hash" && "$mode" == 700 ]]; then
            # Refresh a legacy one-field record in place without replacing an
            # otherwise identical executable snapshot.
            write_private_hash_record "$RECOVERY_SCRIPT_PATH" "$RECOVERY_SCRIPT_HASH_FILE" || return 1
            return 0
        fi
    fi
    backup=$(mktemp -d "$STATE_DIR/.recovery-script-rollback.XXXXXXXX") || return 1
    chmod 0700 "$backup" || {
        discard_recovery_rollback_backup "$backup" 'recovery script backup initialization cleanup failed' || true
        return 1
    }
    if (( had_script )) && ! install -m 0700 "$RECOVERY_SCRIPT_PATH" "$backup/script.before"; then
        discard_recovery_rollback_backup "$backup" 'recovery script backup snapshot cleanup failed' || true
        return 1
    fi
    temp=$(mktemp "$STATE_DIR/.recovery-script.XXXXXXXX") || {
        discard_recovery_rollback_backup "$backup" 'recovery script temporary-file setup cleanup failed' || true
        return 1
    }
    if ! install -m 0700 "$SELF_PATH" "$temp"; then
        recovery_script_failure_cleanup "$temp" "$backup" 'recovery script temporary snapshot cleanup failed' || true
        return 1
    fi
    snapshot_hash=$(sha256sum "$temp" 2>/dev/null | awk '{print $1}') || {
        recovery_script_failure_cleanup "$temp" "$backup" 'recovery script hash failure cleanup failed' || true
        return 1;
    }
    source_hash_after=$(sha256sum "$SELF_PATH" 2>/dev/null | awk '{print $1}') || {
        recovery_script_failure_cleanup "$temp" "$backup" 'recovery script source hash cleanup failed' || true
        return 1;
    }
    if [[ ! "$snapshot_hash" =~ ^[0-9a-f]{64}$ || "$snapshot_hash" != "$source_hash" ||
          "$snapshot_hash" != "$source_hash_after" ]] ||
       ! chmod 0700 "$temp" || ! atomic_install "$temp" "$RECOVERY_SCRIPT_PATH" 0700; then
        snapshot_failed=1
    else
        new_inode=$(stat -c %i "$RECOVERY_SCRIPT_PATH" 2>/dev/null || true)
        new_mode=$(stat -c %a "$RECOVERY_SCRIPT_PATH" 2>/dev/null || true)
        [[ "$new_inode" =~ ^[1-9][0-9]*$ && "$new_mode" =~ ^[0-7]{3,4}$ ]] || snapshot_failed=1
        (( snapshot_failed == 1 )) || write_private_hash_record "$RECOVERY_SCRIPT_PATH" "$RECOVERY_SCRIPT_HASH_FILE" || snapshot_failed=1
    fi
    if (( snapshot_failed )); then
        if (( had_script )); then
            recovery_restore_pair "$RECOVERY_SCRIPT_PATH" "$RECOVERY_SCRIPT_HASH_FILE" "$backup/script.before" 1 "$had_record" 0700 "$snapshot_hash" "$new_inode" "$new_mode" "$old_inode" "$old_mode" || restore_rc=1
        else
            recovery_restore_pair "$RECOVERY_SCRIPT_PATH" "$RECOVERY_SCRIPT_HASH_FILE" "$backup/script.before" 0 0 0700 "$snapshot_hash" "$new_inode" "$new_mode" || restore_rc=1
        fi
        cleanup_rc=0
        recovery_script_staging_cleanup "$temp" || cleanup_rc=1
        if (( restore_rc == 0 && cleanup_rc == 0 )); then
            if ! discard_recovery_rollback_backup "$backup" 'recovery script restore completed but rollback backup cleanup failed'; then
                restore_rc=1
                write_recovery_failure_marker "$backup" 'recovery script restore completed but rollback backup cleanup failed' || true
            fi
        else
            write_recovery_failure_marker "$backup" 'recovery script snapshot compensation was incomplete' || true
            (( restore_rc == 0 )) || warn "恢复脚本快照更新失败且无法完整恢复旧快照；保留回滚证据: $backup"
            (( cleanup_rc == 0 )) || warn "恢复脚本失败分支的暂存清理失败；保留回滚证据: $backup"
        fi
        (( restore_rc == 0 && cleanup_rc == 0 )) || warn "恢复脚本快照失败补偿未完全成功；保留恢复证据: $backup"
        return 1
    fi
    if ! recovery_script_staging_cleanup "$temp"; then
        # The new executable has already been published.  A failed cleanup is
        # still an operation failure: restore the authenticated old snapshot
        # before returning, and retain a recovery marker if that compensation
        # cannot be completed.
        restore_rc=0
        if (( had_script )); then
            recovery_restore_pair "$RECOVERY_SCRIPT_PATH" "$RECOVERY_SCRIPT_HASH_FILE" "$backup/script.before" 1 "$had_record" 0700 "$snapshot_hash" "$new_inode" "$new_mode" "$old_inode" "$old_mode" || restore_rc=1
        else
            recovery_restore_pair "$RECOVERY_SCRIPT_PATH" "$RECOVERY_SCRIPT_HASH_FILE" "$backup/script.before" 0 0 0700 "$snapshot_hash" "$new_inode" "$new_mode" || restore_rc=1
        fi
        if (( restore_rc == 0 )); then
            if ! discard_recovery_rollback_backup "$backup" 'recovery script temporary-file cleanup failed'; then
                restore_rc=1
            fi
        fi
        if (( restore_rc != 0 )); then
            write_recovery_failure_marker "$backup" 'recovery script temporary-file cleanup failed and automatic compensation was incomplete' || true
        fi
        (( restore_rc == 0 )) || warn "恢复脚本暂存清理失败且无法完整恢复旧快照；保留回滚证据: $backup"
        return 1
    fi
    discard_recovery_rollback_backup "$backup" 'recovery script snapshot cleanup failed' || return 1
}

recovery_qdisc_online_wants_path() {
    printf '%s/systemd/system/network-online.target.wants/vps-proxy-tune-recover-qdisc.service\n' "$ETC_ROOT"
}

recovery_qdisc_multi_wants_path() {
    printf '%s/systemd/system/multi-user.target.wants/vps-proxy-tune-recover-qdisc.service\n' "$ETC_ROOT"
}

recovery_config_sysctl_wants_path() {
    printf '%s/systemd/system/systemd-sysctl.service.wants/vps-proxy-tune-recover.service\n' "$ETC_ROOT"
}

recovery_config_multi_wants_path() {
    printf '%s/systemd/system/multi-user.target.wants/vps-proxy-tune-recover.service\n' "$ETC_ROOT"
}

systemd_recovery_wants_link_state() {
    local path="$1" expected="$2" parent raw actual expected_real uid mode permissions
    case "$path" in
        "$(recovery_config_sysctl_wants_path)"|"$(recovery_config_multi_wants_path)"|\
        "$(recovery_qdisc_online_wants_path)"|"$(recovery_qdisc_multi_wants_path)") ;;
        *) return 1 ;;
    esac
    parent=$(dirname -- "$path")
    if [[ -e "$parent" || -L "$parent" ]]; then
        [[ -d "$parent" && ! -L "$parent" ]] || return 1
        uid=$(stat -c %u "$parent" 2>/dev/null || true)
        mode=$(stat -c %a "$parent" 2>/dev/null || true)
        [[ "$uid" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
        permissions=$((8#$mode))
        (( (permissions & 8#022) == 0 )) || return 1
    else
        [[ ! -L "$parent" ]] || return 1
    fi
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        printf 'absent\n'
        return 0
    fi
    [[ -L "$path" ]] || return 1
    raw=$(readlink -- "$path" 2>/dev/null || true)
    [[ -n "$raw" && "$raw" != *$'\n'* && "$raw" != *$'\r'* && "$raw" != *$'\t'* ]] || return 1
    actual=$(readlink -f -- "$path" 2>/dev/null || true)
    expected_real=$(readlink -f -- "$expected" 2>/dev/null || true)
    # A release upgrade or an interrupted uninstall can leave our wants link
    # behind after the unit file itself has disappeared.  -f intentionally
    # returns empty for a missing target; -m canonicalizes the fixed path
    # lexically without following the missing target, so the orphan can still
    # be authenticated and removed.  The link and its parent remain subject
    # to the type/ownership checks above.
    [[ -n "$actual" ]] || actual=$(readlink -m -- "$path" 2>/dev/null || true)
    [[ -n "$expected_real" ]] || expected_real=$(readlink -m -- "$expected" 2>/dev/null || true)
    [[ -n "$actual" && -n "$expected_real" && "$actual" == "$expected_real" ]] || return 1
    printf 'present\t%s\n' "$raw"
}

remove_managed_recovery_wants_link() {
    local path="$1" expected="$2" state
    state=$(systemd_recovery_wants_link_state "$path" "$expected") || return 1
    case "$state" in
        absent) return 0 ;;
        present$'\t'*) rm -f -- "$path" ;;
        *) return 1 ;;
    esac
    [[ ! -e "$path" && ! -L "$path" ]]
}

restore_recovery_wants_link() {
    local path="$1" expected="$2" desired_state="$3" current_state raw current_raw parent
    current_state=$(systemd_recovery_wants_link_state "$path" "$expected") || return 1
    case "$desired_state" in
        absent)
            remove_managed_recovery_wants_link "$path" "$expected"
            ;;
        present$'\t'*)
            raw=${desired_state#*$'\t'}
            [[ -n "$raw" && "$raw" != *$'\n'* && "$raw" != *$'\r'* && "$raw" != *$'\t'* ]] || return 1
            case "$current_state" in
                present$'\t'*)
                    current_raw=${current_state#*$'\t'}
                    [[ "$current_raw" == "$raw" ]] || {
                        rm -f -- "$path" || return 1
                        ln -s -- "$raw" "$path" || return 1
                    }
                    ;;
                absent)
                    parent=$(dirname -- "$path")
                    [[ -d "$parent" && ! -L "$parent" ]] || return 1
                    ln -s -- "$raw" "$path" || return 1
                    ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
    current_state=$(systemd_recovery_wants_link_state "$path" "$expected") || return 1
    [[ "$current_state" == "$desired_state" ]]
}

recovery_backup_tree_is_known() {
    local backup="$1" kind="$2" allow_marker="${3:-0}" path name uid mode
    local -a entries=()
    [[ "$kind" == unit || "$kind" == script ]] || return 1
    if [[ "$kind" == unit ]]; then
        name=$(basename -- "$backup") || return 1
        [[ "$backup" == "$STATE_DIR/".recovery-unit-rollback.* &&
           "$name" =~ ^\.recovery-unit-rollback\.[A-Za-z0-9]{8}$ ]] || return 1
    else
        name=$(basename -- "$backup") || return 1
        [[ "$backup" == "$STATE_DIR/".recovery-script-rollback.* &&
           "$name" =~ ^\.recovery-script-rollback\.[A-Za-z0-9]{8}$ ]] || return 1
    fi
    [[ -d "$backup" && ! -L "$backup" ]] || return 1
    uid=$(stat -c %u "$backup" 2>/dev/null || true)
    mode=$(stat -c %a "$backup" 2>/dev/null || true)
    [[ "$uid" == 0 && "$mode" == 700 ]] || return 1
    shopt -s nullglob
    entries=("$backup"/* "$backup"/.[!.]* "$backup"/..?*)
    shopt -u nullglob
    for path in "${entries[@]}"; do
        name=$(basename -- "$path") || return 1
        [[ -f "$path" && ! -L "$path" ]] || return 1
        uid=$(stat -c %u "$path" 2>/dev/null || true)
        mode=$(stat -c %a "$path" 2>/dev/null || true)
        [[ "$uid" == 0 ]] || return 1
        case "$name" in
            restore-files.tsv|restore-links.tsv)
                [[ "$kind" == unit && "$mode" == 600 ]] || return 1
                ;;
            config.before|qdisc.before)
                [[ "$kind" == unit && ( "$mode" == 600 || "$mode" == 644 ) ]] || return 1
                ;;
            script.before)
                [[ "$mode" == 700 ]] || return 1
                ;;
            recovery-failed)
                [[ "$allow_marker" == 1 && "$mode" == 600 ]] || return 1
                ;;
            *) return 1 ;;
        esac
    done
}

recovery_unit_backup_is_safe() {
    local backup="$1" kind target record before had_target had_record target_mode new_hash new_inode new_mode old_inode expected_mode extra
    local link_name link_target link_expected link_state link_raw link_extra count=0 link_count=0
    local -A seen=() seen_links=()
    recovery_backup_tree_is_known "$backup" unit 0 || return 1
    [[ -f "$backup/restore-files.tsv" && ! -L "$backup/restore-files.tsv" &&
       -f "$backup/restore-links.tsv" && ! -L "$backup/restore-links.tsv" ]] || return 1
    while IFS=$'\t' read -r kind target record before had_target had_record target_mode new_hash new_inode new_mode old_inode expected_mode extra || [[ -n "${kind:-}" ]]; do
        [[ -z "${extra:-}" && "$kind" =~ ^(config|qdisc|script)$ &&
           -z "${seen[$kind]+x}" && "$had_target" =~ ^[01]$ && "$had_record" =~ ^[01]$ &&
           "$target_mode" =~ ^[0-7]{3,4}$ && "$new_hash" =~ ^[0-9a-f]{64}$ &&
           "$new_inode" =~ ^[1-9][0-9]*$ && "$new_mode" =~ ^[0-7]{3,4}$ &&
           "$expected_mode" =~ ^[0-7]{3,4}$ ]] || return 1
        case "$kind" in
            config)
                [[ "$target" == "$RECOVERY_UNIT_PATH" && "$record" == "$RECOVERY_UNIT_HASH_FILE" &&
                   "$before" == "$backup/config.before" && "$expected_mode" == 0644 ]] || return 1
                ;;
            qdisc)
                [[ "$target" == "$RECOVERY_QDISC_UNIT_PATH" && "$record" == "$RECOVERY_QDISC_UNIT_HASH_FILE" &&
                   "$before" == "$backup/qdisc.before" && "$expected_mode" == 0644 ]] || return 1
                ;;
            script)
                [[ "$target" == "$RECOVERY_SCRIPT_PATH" && "$record" == "$RECOVERY_SCRIPT_HASH_FILE" &&
                   "$before" == "$backup/script.before" && "$expected_mode" == 0700 ]] || return 1
                ;;
        esac
        if [[ "$had_target" == 1 ]]; then
            [[ -f "$before" && ! -L "$before" && "$old_inode" =~ ^[1-9][0-9]*$ ]] || return 1
        else
            [[ ! -e "$before" && ! -L "$before" && ( -z "$old_inode" || "$old_inode" == - ) ]] || return 1
        fi
        seen[$kind]=1
        count=$((count + 1)); (( count <= 3 )) || return 1
    done < "$backup/restore-files.tsv"
    (( count == 3 && ${#seen[@]} == 3 )) || return 1
    for kind in config qdisc script; do [[ -n "${seen[$kind]+x}" ]] || return 1; done

    while IFS=$'\t' read -r link_name link_target link_expected link_state link_raw link_extra || [[ -n "${link_name:-}" ]]; do
        [[ -z "${link_extra:-}" && -z "${seen_links[$link_name]+x}" &&
           "$link_state" =~ ^(absent|present)$ ]] || return 1
        case "$link_name" in
            config-sysctl|config-multi)
                [[ "$link_target" == "$RECOVERY_UNIT_PATH" && "$link_expected" == "$RECOVERY_UNIT_PATH" ]] || return 1
                ;;
            online|multi)
                [[ "$link_target" == "$RECOVERY_QDISC_UNIT_PATH" && "$link_expected" == "$RECOVERY_QDISC_UNIT_PATH" ]] || return 1
                ;;
            *) return 1 ;;
        esac
        if [[ "$link_state" == absent ]]; then
            [[ "$link_raw" == - ]] || return 1
        else
            [[ -n "$link_raw" && "$link_raw" != - && "$link_raw" != *$'\n'* &&
               "$link_raw" != *$'\r'* && "$link_raw" != *$'\t'* ]] || return 1
        fi
        seen_links[$link_name]=1
        link_count=$((link_count + 1)); (( link_count <= 4 )) || return 1
    done < "$backup/restore-links.tsv"
    (( link_count == 4 && ${#seen_links[@]} == 4 )) || return 1
    for link_name in config-sysctl config-multi online multi; do [[ -n "${seen_links[$link_name]+x}" ]] || return 1; done
}

recovery_failure_marker_is_safe() {
    local marker="$1/recovery-failed" name kind line
    [[ "$1" == "$STATE_DIR/".recovery-unit-rollback.* ||
       "$1" == "$STATE_DIR/".recovery-script-rollback.* ]] || return 1
    name=$(basename -- "$1") || return 1
    if [[ "$name" =~ ^\.recovery-unit-rollback\.[A-Za-z0-9]{8}$ ]]; then
        kind=unit
    elif [[ "$name" =~ ^\.recovery-script-rollback\.[A-Za-z0-9]{8}$ ]]; then
        kind=script
    else
        return 1
    fi
    recovery_backup_tree_is_known "$1" "$kind" 1 || return 1
    [[ -f "$marker" && ! -L "$marker" ]] || return 1
    IFS= read -r line < "$marker" || return 1
    [[ -n "$line" && "$line" != *$'\n'* && "$line" != *$'\r'* ]] || return 1
    awk 'NR == 1 { first=1; next } { extra=1 } END { exit !(first == 1 && extra != 1) }' "$marker"
}

write_recovery_failure_marker() {
    local backup="$1" message="$2" marker temp name
    [[ "$backup" == "$STATE_DIR/".recovery-unit-rollback.* ||
       "$backup" == "$STATE_DIR/".recovery-script-rollback.* ]] || return 1
    name=$(basename -- "$backup") || return 1
    [[ "$name" =~ ^\.recovery-(unit|script)-rollback\.[A-Za-z0-9]{8}$ ]] || return 1
    [[ -d "$backup" && ! -L "$backup" ]] || return 1
    [[ "$message" != *$'\n'* && "$message" != *$'\r'* && "$message" != *$'\t'* && -n "$message" ]] || return 1
    marker="$backup/recovery-failed"
    temp=$(mktemp "$backup/.recovery-failed.XXXXXXXX") || return 1
    if printf '%s\n' "$message" > "$temp" && chmod 0600 "$temp" && atomic_install "$temp" "$marker" 0600; then
        if rm -f -- "$temp" && [[ ! -e "$temp" && ! -L "$temp" ]]; then
            return 0
        fi
        return 1
    fi
    rm -f -- "$temp"
    return 1
}

recovery_rollback_backup_path_is_safe() {
    local backup="$1" name
    [[ "$backup" == "$STATE_DIR/".recovery-unit-rollback.* ||
       "$backup" == "$STATE_DIR/".recovery-script-rollback.* ]] || return 1
    name=$(basename -- "$backup") || return 1
    [[ "$name" =~ ^\.recovery-(unit|script)-rollback\.[A-Za-z0-9]{8}$ ]] || return 1
    [[ -d "$backup" && ! -L "$backup" ]] || return 1
}

discard_recovery_rollback_backup() {
    local backup="${1:-}" message="${2:-recovery rollback backup cleanup failed}"
    [[ -z "$backup" ]] && return 0
    if [[ ! -e "$backup" && ! -L "$backup" ]]; then
        return 0
    fi
    recovery_rollback_backup_path_is_safe "$backup" || return 1
    if rm -rf -- "$backup" && [[ ! -e "$backup" && ! -L "$backup" ]]; then
        return 0
    fi
    # If deletion was interrupted, leave a bounded, root-only marker that
    # ensure_secure_state can distinguish from an untrusted arbitrary tree.
    write_recovery_failure_marker "$backup" "$message" || true
    return 1
}

write_recovery_unit_backup_manifest() {
    local backup="$1" config_had="$2" config_record_had="$3" config_before_mode="$4" config_hash="$5" config_new_inode="$6" config_new_mode="$7" config_before_inode="$8" qdisc_had="$9" qdisc_record_had="${10}" qdisc_before_mode="${11}" qdisc_hash="${12}" qdisc_new_inode="${13}" qdisc_new_mode="${14}" qdisc_before_inode="${15}" script_had="${16}" script_record_had="${17}" script_before_mode="${18}" script_new_hash="${19}" script_new_inode="${20}" script_new_mode="${21}" script_before_inode="${22}" config_sysctl_state="${23}" config_multi_state="${24}" online_state="${25}" multi_state="${26}"
    local config_sysctl_raw="" config_multi_raw="" online_raw="" multi_raw=""
    : > "$backup/restore-files.tsv" || return 1
    : > "$backup/restore-links.tsv" || return 1
    recovery_backup_tree_is_known "$backup" unit 0 || return 1
    [[ "$config_hash" =~ ^[0-9a-f]{64}$ && "$qdisc_hash" =~ ^[0-9a-f]{64}$ && "$script_new_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf 'config\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$RECOVERY_UNIT_PATH" "$RECOVERY_UNIT_HASH_FILE" "$backup/config.before" "$config_had" "$config_record_had" \
        "${config_before_mode:-0644}" "$config_hash" "$config_new_inode" "$config_new_mode" "$config_before_inode" "0644" >> "$backup/restore-files.tsv" || return 1
    printf 'qdisc\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$RECOVERY_QDISC_UNIT_PATH" "$RECOVERY_QDISC_UNIT_HASH_FILE" "$backup/qdisc.before" "$qdisc_had" "$qdisc_record_had" \
        "${qdisc_before_mode:-0644}" "$qdisc_hash" "$qdisc_new_inode" "$qdisc_new_mode" "$qdisc_before_inode" "0644" >> "$backup/restore-files.tsv" || return 1
    printf 'script\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$RECOVERY_SCRIPT_PATH" "$RECOVERY_SCRIPT_HASH_FILE" "$backup/script.before" "$script_had" "$script_record_had" \
        "${script_before_mode:-0700}" "$script_new_hash" "$script_new_inode" "$script_new_mode" "$script_before_inode" "0700" >> "$backup/restore-files.tsv" || return 1
    case "$config_sysctl_state" in
        absent) printf 'config-sysctl\t%s\t%s\tabsent\t-\n' "$RECOVERY_UNIT_PATH" "$RECOVERY_UNIT_PATH" >> "$backup/restore-links.tsv" ;;
        present$'\t'*) config_sysctl_raw=${config_sysctl_state#*$'\t'}; printf 'config-sysctl\t%s\t%s\tpresent\t%s\n' "$RECOVERY_UNIT_PATH" "$RECOVERY_UNIT_PATH" "$config_sysctl_raw" >> "$backup/restore-links.tsv" ;;
        *) return 1 ;;
    esac
    case "$config_multi_state" in
        absent) printf 'config-multi\t%s\t%s\tabsent\t-\n' "$RECOVERY_UNIT_PATH" "$RECOVERY_UNIT_PATH" >> "$backup/restore-links.tsv" ;;
        present$'\t'*) config_multi_raw=${config_multi_state#*$'\t'}; printf 'config-multi\t%s\t%s\tpresent\t%s\n' "$RECOVERY_UNIT_PATH" "$RECOVERY_UNIT_PATH" "$config_multi_raw" >> "$backup/restore-links.tsv" ;;
        *) return 1 ;;
    esac
    case "$online_state" in
        absent) printf 'online\t%s\t%s\tabsent\t-\n' "$RECOVERY_QDISC_UNIT_PATH" "$RECOVERY_QDISC_UNIT_PATH" >> "$backup/restore-links.tsv" ;;
        present$'\t'*) online_raw=${online_state#*$'\t'}; printf 'online\t%s\t%s\tpresent\t%s\n' "$RECOVERY_QDISC_UNIT_PATH" "$RECOVERY_QDISC_UNIT_PATH" "$online_raw" >> "$backup/restore-links.tsv" ;;
        *) return 1 ;;
    esac
    case "$multi_state" in
        absent) printf 'multi\t%s\t%s\tabsent\t-\n' "$RECOVERY_QDISC_UNIT_PATH" "$RECOVERY_QDISC_UNIT_PATH" >> "$backup/restore-links.tsv" ;;
        present$'\t'*) multi_raw=${multi_state#*$'\t'}; printf 'multi\t%s\t%s\tpresent\t%s\n' "$RECOVERY_QDISC_UNIT_PATH" "$RECOVERY_QDISC_UNIT_PATH" "$multi_raw" >> "$backup/restore-links.tsv" ;;
        *) return 1 ;;
    esac
    chmod 0600 "$backup/restore-files.tsv" "$backup/restore-links.tsv" || return 1
    recovery_unit_backup_is_safe "$backup"
}

restore_held_recovery_unit() {
    local backup="$RECOVERY_UNIT_PENDING_BACKUP" kind target record before had_target had_record target_mode new_hash new_inode new_mode old_inode expected_mode extra
    local link_name link_expected link_target link_state link_raw link_desired link_path link_unit rc=0
    [[ -n "$backup" ]] || return 0
    recovery_unit_backup_is_safe "$backup" || return 1
    while IFS=$'\t' read -r kind target record before had_target had_record target_mode new_hash new_inode new_mode old_inode expected_mode extra || [[ -n "${kind:-}" ]]; do
        [[ -z "${extra:-}" && "$kind" =~ ^(config|qdisc|script)$ && "$had_target" =~ ^[01]$ && "$had_record" =~ ^[01]$ &&
           "$new_hash" =~ ^[0-9a-f]{64}$ && "$target_mode" =~ ^[0-7]{3,4}$ && "$expected_mode" =~ ^[0-7]{3,4}$ ]] || { rc=1; continue; }
        case "$kind" in
            config) [[ "$target" == "$RECOVERY_UNIT_PATH" && "$record" == "$RECOVERY_UNIT_HASH_FILE" && "$before" == "$backup/config.before" ]] || { rc=1; continue; } ;;
            qdisc) [[ "$target" == "$RECOVERY_QDISC_UNIT_PATH" && "$record" == "$RECOVERY_QDISC_UNIT_HASH_FILE" && "$before" == "$backup/qdisc.before" ]] || { rc=1; continue; } ;;
            script) [[ "$target" == "$RECOVERY_SCRIPT_PATH" && "$record" == "$RECOVERY_SCRIPT_HASH_FILE" && "$before" == "$backup/script.before" ]] || { rc=1; continue; } ;;
        esac
        recovery_restore_pair "$target" "$record" "$before" "$had_target" "$had_record" "$target_mode" "$new_hash" "$new_inode" "$new_mode" "$old_inode" "$expected_mode" || rc=1
    done < "$backup/restore-files.tsv"
    while IFS=$'\t' read -r link_name link_target link_expected link_state link_raw extra || [[ -n "${link_name:-}" ]]; do
        [[ -z "${extra:-}" && "$link_state" =~ ^(absent|present)$ ]] || { rc=1; continue; }
        case "$link_name" in
            config-sysctl) link_path=$(recovery_config_sysctl_wants_path); link_unit="$RECOVERY_UNIT_PATH" ;;
            config-multi) link_path=$(recovery_config_multi_wants_path); link_unit="$RECOVERY_UNIT_PATH" ;;
            online) link_path=$(recovery_qdisc_online_wants_path); link_unit="$RECOVERY_QDISC_UNIT_PATH" ;;
            multi) link_path=$(recovery_qdisc_multi_wants_path); link_unit="$RECOVERY_QDISC_UNIT_PATH" ;;
            *) rc=1; continue ;;
        esac
        [[ "$link_target" == "$link_unit" && "$link_expected" == "$link_unit" ]] || { rc=1; continue; }
        if [[ "$link_state" == absent ]]; then link_desired=absent; else link_desired="present${TAB}${link_raw}"; fi
        restore_recovery_wants_link "$link_path" "$link_unit" "$link_desired" || rc=1
    done < "$backup/restore-links.tsv"
    systemctl daemon-reload >/dev/null 2>&1 || rc=1
    if (( rc == 0 )); then
        if ! rm -rf -- "$backup" || [[ -e "$backup" || -L "$backup" ]]; then
            rc=1
        fi
    fi
    if (( rc == 0 )); then
        RECOVERY_UNIT_PENDING_BACKUP=""
        RECOVERY_UNIT_HOLD_BACKUP=0
        return 0
    fi
    if [[ -d "$backup" && ! -L "$backup" ]]; then
        write_recovery_failure_marker "$backup" 'recovery unit compensation cleanup failed' || true
    fi
    return 1
}

commit_held_recovery_unit() {
    local backup="$RECOVERY_UNIT_PENDING_BACKUP"
    [[ -n "$backup" ]] || return 0
    recovery_unit_backup_is_safe "$backup" || return 1
    rm -rf -- "$backup" || return 1
    [[ ! -e "$backup" && ! -L "$backup" ]] || return 1
    RECOVERY_UNIT_PENDING_BACKUP=""
    RECOVERY_UNIT_HOLD_BACKUP=0
}

load_pending_recovery_unit_backup() {
    local backup count=0
    local -a backups=()
    shopt -s nullglob
    backups=("$STATE_DIR"/.recovery-unit-rollback.*)
    shopt -u nullglob
    for backup in "${backups[@]}"; do
        recovery_unit_backup_is_safe "$backup" || return 1
        count=$((count + 1))
        RECOVERY_UNIT_PENDING_BACKUP="$backup"
    done
    (( count <= 1 )) || return 1
    (( count == 1 )) || RECOVERY_UNIT_PENDING_BACKUP=""
}

recovery_unit_staging_cleanup() {
    local path
    (($# > 0)) || return 1
    for path in "$@"; do
        case "$path" in
            "$STATE_DIR"/.recovery-unit.????????|"$STATE_DIR"/.recovery-qdisc-unit.????????) ;;
            *) return 1 ;;
        esac
        if [[ -e "$path" || -L "$path" ]]; then
            [[ -f "$path" && ! -L "$path" ]] || return 1
            rm -f -- "$path" || return 1
        fi
        [[ ! -e "$path" && ! -L "$path" ]] || return 1
    done
}

ensure_recovery_unit() {
    local run_id="${1:-}" config_temp qdisc_temp config_hash qdisc_hash unit backup backup_target
    local config_had=0 qdisc_had=0 config_record_had=0 qdisc_record_had=0
    local script_had=0 script_record_had=0 script_before_hash="" script_new_hash="" script_changed=0 restore_rc=0
    local config_before_inode="" config_before_mode="" qdisc_before_inode="" qdisc_before_mode=""
    local script_before_inode="" script_before_mode="" config_new_inode="" config_new_mode="" qdisc_new_inode="" qdisc_new_mode=""
    local script_new_inode="" script_new_mode="" unit_write_failed=0 rollback_backup=""
    local config_sysctl_wants config_multi_wants config_sysctl_state config_multi_state config_sysctl_after config_multi_after
    local qdisc_online_wants qdisc_multi_wants qdisc_online_state qdisc_multi_state qdisc_online_after qdisc_multi_after
    require_root || return 1
    validate_run_id "$run_id" || { die '恢复单元必须绑定有效的 source run。'; return 1; }
    command_exists systemctl || { die 'apply 需要 systemctl 以安装启动恢复单元。'; return 1; }
    [[ -d /run/systemd/system ]] || { die 'apply 需要 systemd 作为 PID 1。'; return 1; }
    if (( RECOVERY_UNIT_HOLD_BACKUP )) && [[ -n "$RECOVERY_UNIT_PENDING_BACKUP" ]]; then
        die '存在未提交的恢复单元补偿备份；拒绝覆盖。'; return 1
    fi
    config_sysctl_wants=$(recovery_config_sysctl_wants_path)
    config_multi_wants=$(recovery_config_multi_wants_path)
    config_sysctl_state=$(systemd_recovery_wants_link_state "$config_sysctl_wants" "$RECOVERY_UNIT_PATH") || {
        die 'systemd-sysctl.service.wants 中存在无法认证的配置恢复链接；拒绝接管。'; return 1;
    }
    config_multi_state=$(systemd_recovery_wants_link_state "$config_multi_wants" "$RECOVERY_UNIT_PATH") || {
        die 'multi-user.target.wants 中存在无法认证的配置恢复链接；拒绝接管。'; return 1;
    }
    qdisc_online_wants=$(recovery_qdisc_online_wants_path)
    qdisc_multi_wants=$(recovery_qdisc_multi_wants_path)
    qdisc_online_state=$(systemd_recovery_wants_link_state "$qdisc_online_wants" "$RECOVERY_QDISC_UNIT_PATH") || {
        die 'network-online.target.wants 中存在无法认证的 qdisc 恢复链接；拒绝接管。'; return 1;
    }
    qdisc_multi_state=$(systemd_recovery_wants_link_state "$qdisc_multi_wants" "$RECOVERY_QDISC_UNIT_PATH") || {
        die 'multi-user.target.wants 中存在无法认证的 qdisc 恢复链接；拒绝接管。'; return 1;
    }
    for unit in "$RECOVERY_UNIT_PATH:$RECOVERY_UNIT_HASH_FILE" "$RECOVERY_QDISC_UNIT_PATH:$RECOVERY_QDISC_UNIT_HASH_FILE"; do
        local unit_path=${unit%%:*} hash_path=${unit#*:}
        if [[ ! -e "$unit_path" && ! -L "$unit_path" && ( -e "$hash_path" || -L "$hash_path" ) ]]; then
            die "恢复单元缺失但哈希记录仍存在；拒绝接管: $unit_path"
            return 1
        fi
        if [[ -e "$unit_path" || -L "$unit_path" ]]; then
            [[ -f "$unit_path" && ! -L "$unit_path" ]] || { die "恢复单元路径类型不安全: $unit_path"; return 1; }
            managed_file_is_known_owned "$unit_path" || { die "拒绝接管无所有权标记或未知格式的 $unit_path"; return 1; }
            if [[ -e "$hash_path" || -L "$hash_path" ]]; then
                verify_private_hash_record "$unit_path" "$hash_path" || {
                    die "恢复单元哈希不一致；拒绝覆盖: $unit_path"; return 1;
                }
            else
                secure_owned_file "$unit_path" || return 1
            fi
        fi
    done
    backup=$(mktemp -d "$STATE_DIR/.recovery-unit-rollback.XXXXXXXX") || return 1
    rollback_backup="$backup"
    if ! chmod 0700 "$backup"; then
        discard_recovery_rollback_backup "$backup" 'recovery unit backup initialization cleanup failed' || true
        return 1
    fi
    if [[ -e "$RECOVERY_UNIT_PATH" || -L "$RECOVERY_UNIT_PATH" ]]; then
        config_had=1
        config_before_inode=$(stat -c %i "$RECOVERY_UNIT_PATH" 2>/dev/null || true)
        config_before_mode=$(stat -c %a "$RECOVERY_UNIT_PATH" 2>/dev/null || true)
        [[ "$config_before_inode" =~ ^[1-9][0-9]*$ && "$config_before_mode" =~ ^[0-7]{3,4}$ ]] || {
            discard_recovery_rollback_backup "$backup" 'recovery unit backup identity cleanup failed' || true
            return 1;
        }
        backup_target="$backup/config.before"
        install -m 0644 "$RECOVERY_UNIT_PATH" "$backup_target" || {
            discard_recovery_rollback_backup "$backup" 'recovery unit snapshot cleanup failed' || true
            return 1;
        }
        [[ -e "$RECOVERY_UNIT_HASH_FILE" || -L "$RECOVERY_UNIT_HASH_FILE" ]] && config_record_had=1
    fi
    if [[ -e "$RECOVERY_QDISC_UNIT_PATH" || -L "$RECOVERY_QDISC_UNIT_PATH" ]]; then
        qdisc_had=1
        qdisc_before_inode=$(stat -c %i "$RECOVERY_QDISC_UNIT_PATH" 2>/dev/null || true)
        qdisc_before_mode=$(stat -c %a "$RECOVERY_QDISC_UNIT_PATH" 2>/dev/null || true)
        [[ "$qdisc_before_inode" =~ ^[1-9][0-9]*$ && "$qdisc_before_mode" =~ ^[0-7]{3,4}$ ]] || {
            discard_recovery_rollback_backup "$backup" 'qdisc recovery unit backup identity cleanup failed' || true
            return 1;
        }
        backup_target="$backup/qdisc.before"
        install -m 0644 "$RECOVERY_QDISC_UNIT_PATH" "$backup_target" || {
            discard_recovery_rollback_backup "$backup" 'qdisc recovery unit snapshot cleanup failed' || true
            return 1;
        }
        [[ -e "$RECOVERY_QDISC_UNIT_HASH_FILE" || -L "$RECOVERY_QDISC_UNIT_HASH_FILE" ]] && qdisc_record_had=1
    fi
    if [[ -e "$RECOVERY_SCRIPT_PATH" || -L "$RECOVERY_SCRIPT_PATH" ]]; then
        [[ -f "$RECOVERY_SCRIPT_PATH" && ! -L "$RECOVERY_SCRIPT_PATH" ]] || {
            discard_recovery_rollback_backup "$backup" 'recovery script path validation cleanup failed' || true
            die '恢复脚本快照路径类型不安全。'; return 1;
        }
        if [[ -e "$RECOVERY_SCRIPT_HASH_FILE" || -L "$RECOVERY_SCRIPT_HASH_FILE" ]]; then
            verify_private_hash_record "$RECOVERY_SCRIPT_PATH" "$RECOVERY_SCRIPT_HASH_FILE" || {
                discard_recovery_rollback_backup "$backup" 'recovery script hash validation cleanup failed' || true
                die '持久恢复脚本快照哈希不一致；拒绝覆盖。'; return 1;
            }
            script_record_had=1
        else
            secure_owned_file "$RECOVERY_SCRIPT_PATH" || {
                discard_recovery_rollback_backup "$backup" 'legacy recovery script validation cleanup failed' || true
                return 1;
            }
        fi
        script_had=1
        script_before_inode=$(stat -c %i "$RECOVERY_SCRIPT_PATH" 2>/dev/null || true)
        script_before_mode=$(stat -c %a "$RECOVERY_SCRIPT_PATH" 2>/dev/null || true)
        [[ "$script_before_inode" =~ ^[1-9][0-9]*$ && "$script_before_mode" =~ ^[0-7]{3,4}$ ]] || {
            discard_recovery_rollback_backup "$backup" 'recovery script backup identity cleanup failed' || true
            return 1;
        }
        script_before_hash=$(sha256sum "$RECOVERY_SCRIPT_PATH" 2>/dev/null | awk '{print $1}') || {
            discard_recovery_rollback_backup "$backup" 'recovery script backup hash cleanup failed' || true
            return 1;
        }
        install -m 0700 "$RECOVERY_SCRIPT_PATH" "$backup/script.before" || {
            discard_recovery_rollback_backup "$backup" 'recovery script snapshot cleanup failed' || true
            return 1;
        }
    elif [[ -e "$RECOVERY_SCRIPT_HASH_FILE" || -L "$RECOVERY_SCRIPT_HASH_FILE" ]]; then
        discard_recovery_rollback_backup "$backup" 'orphan recovery script hash cleanup failed' || true
        die '恢复脚本哈希记录存在但脚本快照缺失；拒绝接管。'
        return 1
    fi
    if ! ensure_recovery_script_snapshot; then
        discard_recovery_rollback_backup "$backup" 'recovery script snapshot failure cleanup failed' || true
        die '无法创建或验证不可变持久恢复脚本快照。'
        return 1
    fi
    script_new_hash=$(sha256sum "$RECOVERY_SCRIPT_PATH" 2>/dev/null | awk '{print $1}') || {
        discard_recovery_rollback_backup "$backup" 'new recovery script hash cleanup failed' || true
        return 1;
    }
    script_new_inode=$(stat -c %i "$RECOVERY_SCRIPT_PATH" 2>/dev/null || true)
    script_new_mode=$(stat -c %a "$RECOVERY_SCRIPT_PATH" 2>/dev/null || true)
    [[ "$script_new_inode" =~ ^[1-9][0-9]*$ && "$script_new_mode" =~ ^[0-7]{3,4}$ ]] || {
        discard_recovery_rollback_backup "$backup" 'new recovery script identity cleanup failed' || true
        return 1;
    }
    if (( script_had == 0 )) || [[ "$script_new_hash" != "$script_before_hash" ]] ||
       { (( script_record_had == 0 )) && [[ -e "$RECOVERY_SCRIPT_HASH_FILE" || -L "$RECOVERY_SCRIPT_HASH_FILE" ]]; }; then
        script_changed=1
    fi
    [[ "$RECOVERY_SCRIPT_PATH" =~ ^/[A-Za-z0-9._/+:-]+$ ]] || {
        discard_recovery_rollback_backup "$backup" 'recovery script path policy cleanup failed' || true
        die '恢复单元要求脚本快照路径只含安全的绝对路径字符。'
        return 1
    }
    config_temp=$(mktemp "$STATE_DIR/.recovery-unit.XXXXXXXX") || {
        discard_recovery_rollback_backup "$backup" 'configuration recovery unit temporary-file cleanup failed' || true
        return 1
    }
    qdisc_temp=$(mktemp "$STATE_DIR/.recovery-qdisc-unit.XXXXXXXX") || {
        recovery_unit_staging_cleanup "$config_temp" || true
        discard_recovery_rollback_backup "$backup" 'qdisc recovery unit temporary-file cleanup failed' || true
        return 1
    }
    if ! {
        managed_marker
        managed_metadata "$run_id"
        printf '[Unit]\nDescription=vps-proxy-tune boot configuration recovery\nDefaultDependencies=no\nRequiresMountsFor=%s\nAfter=local-fs.target\nBefore=systemd-sysctl.service network-pre.target\nConditionPathExists=%s\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\nUMask=0077\nEnvironment=VPS_TUNE_LIB_ONLY=0\nEnvironment=VPS_TUNE_ETC_ROOT=/etc\nEnvironment=VPS_TUNE_PROC_ROOT=/proc\nEnvironment=VPS_TUNE_SYS_ROOT=/sys\nEnvironment=VPS_TUNE_STATE_DIR=/var/lib/vps-proxy-tune\nEnvironment=VPS_TUNE_RUN_ROOT=/run\nExecStart=/bin/bash %s _boot-recover --phase config\n\n[Install]\nWantedBy=systemd-sysctl.service multi-user.target\n' "$STATE_DIR" "$STATE_DIR" "$RECOVERY_SCRIPT_PATH"
    } > "$config_temp" || ! {
        managed_marker
        managed_metadata "$run_id"
        printf '[Unit]\nDescription=vps-proxy-tune boot qdisc recovery\nDefaultDependencies=no\nRequiresMountsFor=%s\nWants=network-online.target\nAfter=network-online.target vps-proxy-tune-recover.service\nRequires=vps-proxy-tune-recover.service\nConditionPathExists=%s\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\nUMask=0077\nEnvironment=VPS_TUNE_LIB_ONLY=0\nEnvironment=VPS_TUNE_ETC_ROOT=/etc\nEnvironment=VPS_TUNE_PROC_ROOT=/proc\nEnvironment=VPS_TUNE_SYS_ROOT=/sys\nEnvironment=VPS_TUNE_STATE_DIR=/var/lib/vps-proxy-tune\nEnvironment=VPS_TUNE_RUN_ROOT=/run\nExecStart=/bin/bash %s _boot-recover --phase qdisc\n\n[Install]\nWantedBy=multi-user.target\n' "$STATE_DIR" "$STATE_DIR" "$RECOVERY_SCRIPT_PATH"
    } > "$qdisc_temp" || ! chmod 0600 "$config_temp" "$qdisc_temp"; then
        recovery_unit_staging_cleanup "$config_temp" "$qdisc_temp" || true
        discard_recovery_rollback_backup "$backup" 'recovery unit text staging cleanup failed' || true
        return 1
    fi
    config_hash=$(sha256sum "$config_temp" 2>/dev/null | awk '{print $1}') || {
        recovery_unit_staging_cleanup "$config_temp" "$qdisc_temp" || true
        discard_recovery_rollback_backup "$backup" 'configuration recovery unit hash cleanup failed' || true
        return 1;
    }
    qdisc_hash=$(sha256sum "$qdisc_temp" 2>/dev/null | awk '{print $1}') || {
        recovery_unit_staging_cleanup "$config_temp" "$qdisc_temp" || true
        discard_recovery_rollback_backup "$backup" 'qdisc recovery unit hash cleanup failed' || true
        return 1;
    }
    if [[ ! "$config_hash" =~ ^[0-9a-f]{64}$ || ! "$qdisc_hash" =~ ^[0-9a-f]{64}$ ]]; then
        unit_write_failed=1
    elif ! atomic_install "$config_temp" "$RECOVERY_UNIT_PATH" 0644; then
        unit_write_failed=1
    else
        config_new_inode=$(stat -c %i "$RECOVERY_UNIT_PATH" 2>/dev/null || true)
        config_new_mode=$(stat -c %a "$RECOVERY_UNIT_PATH" 2>/dev/null || true)
        [[ "$config_new_inode" =~ ^[1-9][0-9]*$ && "$config_new_mode" =~ ^[0-7]{3,4}$ ]] || unit_write_failed=1
    fi
    if (( unit_write_failed == 0 )) && ! atomic_install "$qdisc_temp" "$RECOVERY_QDISC_UNIT_PATH" 0644; then
        unit_write_failed=1
    fi
    if (( unit_write_failed == 0 )); then
        qdisc_new_inode=$(stat -c %i "$RECOVERY_QDISC_UNIT_PATH" 2>/dev/null || true)
        qdisc_new_mode=$(stat -c %a "$RECOVERY_QDISC_UNIT_PATH" 2>/dev/null || true)
        [[ "$qdisc_new_inode" =~ ^[1-9][0-9]*$ && "$qdisc_new_mode" =~ ^[0-7]{3,4}$ ]] || unit_write_failed=1
    fi
    if (( unit_write_failed == 0 )) && ! write_private_hash_record "$RECOVERY_UNIT_PATH" "$RECOVERY_UNIT_HASH_FILE"; then
        unit_write_failed=1
    fi
    if (( unit_write_failed == 0 )) && ! write_private_hash_record "$RECOVERY_QDISC_UNIT_PATH" "$RECOVERY_QDISC_UNIT_HASH_FILE"; then
        unit_write_failed=1
    fi
    if (( unit_write_failed == 0 )) && ! managed_file_has_current_metadata "$RECOVERY_UNIT_PATH"; then
        unit_write_failed=1
    fi
    if (( unit_write_failed == 0 )) && ! managed_file_has_current_metadata "$RECOVERY_QDISC_UNIT_PATH"; then
        unit_write_failed=1
    fi
    if (( unit_write_failed == 0 )) && ! systemctl daemon-reload >/dev/null 2>&1; then
        unit_write_failed=1
    fi
    if (( unit_write_failed == 0 )) && ! systemctl enable vps-proxy-tune-recover.service vps-proxy-tune-recover-qdisc.service >/dev/null 2>&1; then
        unit_write_failed=1
    fi
    if (( unit_write_failed == 0 )) && ! remove_managed_recovery_wants_link "$qdisc_online_wants" "$RECOVERY_QDISC_UNIT_PATH"; then
        unit_write_failed=1
    fi
    if (( unit_write_failed == 0 )); then
        config_sysctl_after=$(systemd_recovery_wants_link_state "$config_sysctl_wants" "$RECOVERY_UNIT_PATH" 2>/dev/null || printf invalid)
        config_multi_after=$(systemd_recovery_wants_link_state "$config_multi_wants" "$RECOVERY_UNIT_PATH" 2>/dev/null || printf invalid)
        qdisc_online_after=$(systemd_recovery_wants_link_state "$qdisc_online_wants" "$RECOVERY_QDISC_UNIT_PATH" 2>/dev/null || printf invalid)
        qdisc_multi_after=$(systemd_recovery_wants_link_state "$qdisc_multi_wants" "$RECOVERY_QDISC_UNIT_PATH" 2>/dev/null || printf invalid)
        [[ "$config_sysctl_after" == present$'\t'* && "$config_multi_after" == present$'\t'* &&
           "$qdisc_online_after" == absent && "$qdisc_multi_after" == present$'\t'* ]] || unit_write_failed=1
    fi
    if (( unit_write_failed == 0 )); then
        # Keep a complete, authenticated compensation record even when the
        # caller does not ask to hold the backup.  This makes a later staging
        # cleanup failure recoverable instead of leaving only unstructured
        # before-files behind.
        if ! write_recovery_unit_backup_manifest "$backup" "$config_had" "$config_record_had" "${config_before_mode:-0644}" "$config_hash" "$config_new_inode" "$config_new_mode" "$config_before_inode" \
            "$qdisc_had" "$qdisc_record_had" "${qdisc_before_mode:-0644}" "$qdisc_hash" "$qdisc_new_inode" "$qdisc_new_mode" "$qdisc_before_inode" \
            "$script_had" "$script_record_had" "${script_before_mode:-0700}" "$script_new_hash" "$script_new_inode" "$script_new_mode" "$script_before_inode" \
            "$config_sysctl_state" "$config_multi_state" "$qdisc_online_state" "$qdisc_multi_state"; then
            unit_write_failed=1
        elif (( RECOVERY_UNIT_HOLD_BACKUP )); then
            RECOVERY_UNIT_PENDING_BACKUP="$backup"
            backup=""
        fi
    fi
    if (( unit_write_failed )); then
        if ! recovery_unit_staging_cleanup "$config_temp" "$qdisc_temp"; then
            restore_rc=1
            warn "恢复单元失败分支的暂存清理失败；保留恢复证据。"
        fi
        recovery_restore_pair "$RECOVERY_QDISC_UNIT_PATH" "$RECOVERY_QDISC_UNIT_HASH_FILE" "$rollback_backup/qdisc.before" "$qdisc_had" "$qdisc_record_had" "${qdisc_before_mode:-0644}" "$qdisc_hash" "$qdisc_new_inode" "$qdisc_new_mode" "$qdisc_before_inode" "$qdisc_before_mode" || restore_rc=1
        recovery_restore_pair "$RECOVERY_UNIT_PATH" "$RECOVERY_UNIT_HASH_FILE" "$rollback_backup/config.before" "$config_had" "$config_record_had" "${config_before_mode:-0644}" "$config_hash" "$config_new_inode" "$config_new_mode" "$config_before_inode" "$config_before_mode" || restore_rc=1
        if (( script_changed )); then
            recovery_restore_pair "$RECOVERY_SCRIPT_PATH" "$RECOVERY_SCRIPT_HASH_FILE" "$rollback_backup/script.before" "$script_had" "$script_record_had" 0700 "$script_new_hash" "$script_new_inode" "$script_new_mode" "$script_before_inode" "$script_before_mode" || restore_rc=1
        fi
        restore_recovery_wants_link "$config_sysctl_wants" "$RECOVERY_UNIT_PATH" "$config_sysctl_state" || restore_rc=1
        restore_recovery_wants_link "$config_multi_wants" "$RECOVERY_UNIT_PATH" "$config_multi_state" || restore_rc=1
        restore_recovery_wants_link "$qdisc_online_wants" "$RECOVERY_QDISC_UNIT_PATH" "$qdisc_online_state" || restore_rc=1
        restore_recovery_wants_link "$qdisc_multi_wants" "$RECOVERY_QDISC_UNIT_PATH" "$qdisc_multi_state" || restore_rc=1
        systemctl daemon-reload >/dev/null 2>&1 || restore_rc=1
        if (( restore_rc == 0 )); then
            if [[ -n "$rollback_backup" ]] && ! discard_recovery_rollback_backup "$rollback_backup" 'recovery unit restore completed but rollback backup cleanup failed'; then
                restore_rc=1
            elif [[ "$RECOVERY_UNIT_PENDING_BACKUP" == "$rollback_backup" ]]; then
                RECOVERY_UNIT_PENDING_BACKUP=""
            fi
        else
            write_recovery_failure_marker "$rollback_backup" 'recovery unit install failed and automatic compensation was incomplete' || true
            warn "恢复单元安装失败且无法完整恢复旧的恢复材料；保留回滚证据: $rollback_backup"
        fi
        die '无法安装、验证或启用两阶段启动恢复单元。'
        return 1
    fi
    if ! recovery_unit_staging_cleanup "$config_temp" "$qdisc_temp"; then
        # Persistent recovery files and links have been published at this
        # point.  Treat a failed temp-file cleanup as a failed transaction and
        # restore the exact pre-install state from the authenticated backup.
        # The backup is moved into the normal pending slot so apply's EXIT
        # compensation or a later `recover` can retry if this restore fails.
        if [[ -z "$RECOVERY_UNIT_PENDING_BACKUP" && -n "$backup" ]]; then
            RECOVERY_UNIT_PENDING_BACKUP="$backup"
            backup=""
        fi
        if [[ -n "$RECOVERY_UNIT_PENDING_BACKUP" ]] && ! restore_held_recovery_unit; then
            write_recovery_failure_marker "$RECOVERY_UNIT_PENDING_BACKUP" \
                'recovery unit temporary-file cleanup failed and automatic compensation was incomplete' || true
            warn "恢复单元暂存清理失败且无法完整恢复旧材料；保留回滚证据: $RECOVERY_UNIT_PENDING_BACKUP"
        fi
        die '恢复单元暂存清理失败；拒绝报告为成功。'
        return 1
    fi
    [[ -z "$backup" ]] || discard_recovery_rollback_backup "$backup" 'recovery unit snapshot cleanup failed' || return 1
}

recovery_artifacts_are_valid() {
    local artifact record
    for artifact in "$RECOVERY_UNIT_PATH" "$RECOVERY_QDISC_UNIT_PATH"; do
        case "$artifact" in
            "$RECOVERY_UNIT_PATH") record=$RECOVERY_UNIT_HASH_FILE ;;
            *) record=$RECOVERY_QDISC_UNIT_HASH_FILE ;;
        esac
        if [[ -e "$artifact" || -L "$artifact" || -e "$record" || -L "$record" ]]; then
            if [[ ! -e "$artifact" && ! -L "$artifact" ]]; then return 1; fi
            [[ -f "$artifact" && ! -L "$artifact" ]] || return 1
            secure_owned_file "$artifact" || return 1
            managed_file_is_known_owned "$artifact" || return 1
            if [[ -e "$record" || -L "$record" ]]; then
                verify_private_hash_record "$artifact" "$record" || return 1
                managed_file_has_current_metadata "$artifact" || return 1
            fi
        fi
    done
    if [[ -e "$RECOVERY_SCRIPT_PATH" || -L "$RECOVERY_SCRIPT_PATH" ||
          -e "$RECOVERY_SCRIPT_HASH_FILE" || -L "$RECOVERY_SCRIPT_HASH_FILE" ]]; then
        if [[ -e "$RECOVERY_SCRIPT_PATH" || -L "$RECOVERY_SCRIPT_PATH" ]] &&
           [[ -e "$RECOVERY_SCRIPT_HASH_FILE" || -L "$RECOVERY_SCRIPT_HASH_FILE" ]]; then
            verify_private_hash_record "$RECOVERY_SCRIPT_PATH" "$RECOVERY_SCRIPT_HASH_FILE" || return 1
        else
            [[ -f "$RECOVERY_SCRIPT_PATH" && ! -L "$RECOVERY_SCRIPT_PATH" &&
               ! -e "$RECOVERY_SCRIPT_HASH_FILE" && ! -L "$RECOVERY_SCRIPT_HASH_FILE" ]] || return 1
            secure_owned_file "$RECOVERY_SCRIPT_PATH" || return 1
        fi
    fi
}

recovery_unit_source_run() {
    local unit="$1" source count
    case "$unit" in
        "$RECOVERY_UNIT_PATH"|"$RECOVERY_QDISC_UNIT_PATH") ;;
        *) return 1 ;;
    esac
    [[ -f "$unit" && ! -L "$unit" ]] || return 1
    count=$(awk '/^# Source run: /{n++} END{print n+0}' "$unit") || return 1
    [[ "$count" == 1 ]] || return 1
    source=$(awk '/^# Source run: /{print substr($0,15);exit}' "$unit") || return 1
    validate_run_id "$source" || return 1
    printf '%s\n' "$source"
}

recovery_binding_state() {
    local config_source qdisc_source current
    if [[ ! -e "$RECOVERY_UNIT_PATH" && ! -L "$RECOVERY_UNIT_PATH" &&
          ! -e "$RECOVERY_QDISC_UNIT_PATH" && ! -L "$RECOVERY_QDISC_UNIT_PATH" ]]; then
        printf 'none\n'
        return 0
    fi
    config_source=$(recovery_unit_source_run "$RECOVERY_UNIT_PATH" 2>/dev/null || true)
    qdisc_source=$(recovery_unit_source_run "$RECOVERY_QDISC_UNIT_PATH" 2>/dev/null || true)
    [[ -n "$config_source" && "$config_source" == "$qdisc_source" ]] || {
        printf 'invalid\n'; return 0;
    }
    current=$(cat "$STATE_DIR/current_run" 2>/dev/null || true)
    if [[ -n "$current" && "$current" == "$config_source" ]]; then
        printf 'current\n'
    else
        printf 'stale\n'
    fi
}

recover_qdisc_phase() {
    local transaction="$1" boot_mode="${2:-0}" attempts=1 delay=0 attempt=1
    if (( boot_mode )); then
        # Network devices and their root qdisc can appear after the early
        # configuration recovery unit.  Retry only this phase, and keep the
        # bound small so a broken qdisc cannot stall boot indefinitely.
        attempts=5
        delay=2
    fi
    while :; do
        if restore_transaction "$transaction" qdisc; then
            return 0
        fi
        (( attempt >= attempts )) && return 1
        sleep "$delay" || return 1
        attempt=$((attempt + 1))
    done
}

# RECOVERY_INSERT_POINT
find_incomplete_transactions() {
    local transaction status name invalid=0
    shopt -s nullglob
    for transaction in "$STATE_DIR"/transactions/* "$STATE_DIR"/transactions/.[!.]* "$STATE_DIR"/transactions/..?*; do
        name=$(basename "$transaction")
        # A private mktemp staging directory is not a published transaction and
        # may be left behind by a crash.  Every other entry must be a complete,
        # authenticated transaction; silently skipping an unexpected file or a
        # corrupt snapshot would make recover report a false "nothing to do".
        if transaction_staging_name "$name"; then
            [[ -d "$transaction" && ! -L "$transaction" ]] || invalid=1
            continue
        fi
        if [[ ! -d "$transaction" || -L "$transaction" ]] || ! validate_run_id "$name"; then
            invalid=1
            continue
        fi
        transaction_snapshot_is_valid "$transaction" || { invalid=1; continue; }
        status=$(cat "$transaction/status" 2>/dev/null || true)
        case "$status" in
            prepared|applying|pending-confirm|guard-restoring|rollback-failed) printf '%s\t%s\n' "$name" "$status" ;;
            committed|rolled-back) ;;
            *) invalid=1 ;;
        esac
    done
    shopt -u nullglob
    (( invalid == 0 ))
}

recover_failure_result() {
    local run_id="$1" message="$2"
    set_outcome rollback_failed recovery_pending
    warn "$message"
    emit_json_result rollback_failed recovery_pending "$run_id" rollback-failed
    return 40
}

cmd_recover() {
    local arg run_id="" transaction status current="" count=0 candidate boot_mode=0 incomplete="" phase=all outcome=ok
    local current_head="" current_status="" candidate_previous="" orphan_mode=0 orphan_previous=""
    JSON_OUTPUT=0; DRY_RUN=0; JSON_ERROR_EMITTED=0
    set_outcome '' ''
    while (($#)); do
        arg=$1; shift
        case "$arg" in
            --run) (($#)) || { die '--run 缺少值'; return 1; }; run_id=$1; shift ;;
            --run=*) run_id=${arg#*=} ;;
            --json) JSON_OUTPUT=1 ;;
            --boot) boot_mode=1 ;;
            --phase) (($#)) || { die '--phase 缺少值'; return 1; }; phase=$1; shift ;;
            --phase=*) phase=${arg#*=} ;;
            *) die "recover 不支持参数: $arg"; return 1 ;;
        esac
    done
    [[ "$phase" == all || "$phase" == config || "$phase" == qdisc ]] || { die '--phase 只能是 all、config 或 qdisc。'; return 1; }
    require_root || return 1; require_real_apply_roots || return 1
    (( boot_mode == 0 )) || secure_script_source || return 1
    require_recovery_commands || return 1
    recover_baseline_cleanup_markers || {
        die 'baseline cleanup marker 无法安全重试；停止恢复并保留证据。'; return 40;
    }
    ensure_secure_state || return 1
    load_pending_recovery_unit_backup || {
        die '存在多个或损坏的启动恢复补偿备份；停止自动恢复并保留证据。'; return 40;
    }
    if [[ -n "$RECOVERY_UNIT_PENDING_BACKUP" ]]; then
        restore_held_recovery_unit || {
            die '无法恢复 apply 前的启动恢复材料；停止自动恢复并保留补偿备份。'; return 40;
        }
    fi
    [[ -r "$STATE_DIR/current_run" ]] && current_head=$(cat "$STATE_DIR/current_run")
    if ! incomplete=$(find_incomplete_transactions); then
        die '事务目录包含未认证或损坏条目；停止自动恢复并保留证据。'
        return 40
    fi
    if [[ -z "$incomplete" ]] && ! validate_transaction_chain; then
        die '没有未完成事务，但事务链包含孤立或损坏的提交记录；停止自动恢复并保留证据。'
        return 40
    fi
    if [[ -z "$run_id" ]]; then
        # Prefer the published head while it is itself incomplete.  If a crash
        # happened after publishing a prepared transaction but before updating
        # current_run, recover the one linked orphan instead of incorrectly
        # reporting the previous committed head as already healthy.
        if [[ -n "$current_head" ]]; then
            validate_run_id "$current_head" || { die 'current_run 指针无效；停止自动恢复。'; return 40; }
            current_status=$(cat "$STATE_DIR/transactions/$current_head/status" 2>/dev/null || true)
            case "$current_status" in
                prepared|applying|pending-confirm|guard-restoring|rollback-failed|rolled-back)
                    run_id=$current_head
                    ;;
                committed)
                    count=0; candidate=""
                    if [[ -n "$incomplete" ]]; then
                        while IFS=$'\t' read -r candidate _; do
                            count=$((count + 1))
                            candidate_previous=$(transaction_get "$STATE_DIR/transactions/$candidate" PREVIOUS_RUN 2>/dev/null || true)
                            [[ "$candidate_previous" == "$current_head" ]] || candidate_previous='__unlinked__'
                        done <<< "$incomplete"
                    fi
                    if (( count == 0 )); then
                        run_id=$current_head
                    elif (( count == 1 )) && [[ "$candidate_previous" == "$current_head" ]]; then
                        run_id=$candidate
                        orphan_mode=1
                        orphan_previous=$current_head
                    else
                        die 'current_run 已提交但存在多个或链外未完成事务；请显式指定 recover --run RUN_ID。'
                        return 40
                    fi
                    ;;
                *)
                    die "current_run 指向未知事务状态: ${current_status:-missing}"
                    return 40
                    ;;
            esac
        else
            if [[ -n "$incomplete" ]]; then
                while IFS=$'\t' read -r candidate _; do
                    run_id=$candidate; count=$((count + 1))
                done <<< "$incomplete"
            fi
            if (( count > 1 )); then
                die '存在多个未完成事务且没有 current_run；请显式指定 recover --run RUN_ID。'
                return 40
            fi
        fi
    fi
    if [[ -z "$run_id" ]]; then
        set_outcome 'ok' 'nothing_to_recover'
        if (( JSON_OUTPUT )); then jq -n --arg schema "$SCHEMA_VERSION" --arg outcome "$OUTCOME" --arg reason "$REASON_CODE" '{schema_version:$schema,outcome:$outcome,reason_code:$reason,warnings:[],rollback_status:"not-applicable"}'
        else printf '没有发现需要恢复的事务。\n'; fi
        return 0
    fi
    validate_run_id "$run_id" || { die 'recover 的 RUN_ID 无效。'; return 1; }
    transaction="$STATE_DIR/transactions/$run_id"
    [[ -d "$transaction" && ! -L "$transaction" ]] || { die '找不到待恢复事务。'; return 1; }
    transaction_snapshot_is_valid "$transaction" || { die '事务快照不可信；停止恢复并保留证据。'; return 40; }
    status=$(cat "$transaction/status" 2>/dev/null || printf unknown)
    # An operator may explicitly name the same published-but-not-linked
    # orphan that automatic selection would choose.  Treat it as an orphan
    # only when the current head is a committed predecessor and the snapshot
    # points exactly to that head; never overwrite an unrelated newer chain.
    if (( orphan_mode == 0 )) && [[ -n "$current_head" && "$current_head" != "$run_id" ]]; then
        validate_run_id "$current_head" || { die 'current_run 指针无效；停止自动恢复。'; return 40; }
        current_status=$(cat "$STATE_DIR/transactions/$current_head/status" 2>/dev/null || true)
    fi
    if (( orphan_mode == 0 )) && [[ -n "$current_head" && "$current_head" != "$run_id" ]] &&
       [[ "$current_status" == committed ]]; then
        candidate_previous=$(transaction_get "$transaction" PREVIOUS_RUN 2>/dev/null || true)
        case "$status" in
            prepared|applying|pending-confirm|guard-restoring|rollback-failed)
                if [[ "$candidate_previous" == "$current_head" ]]; then
                    orphan_mode=1
                    orphan_previous=$current_head
                fi
                ;;
        esac
    fi
    if [[ "$status" =~ ^(prepared|applying|pending-confirm|guard-restoring|rollback-failed)$ || "$status" == rolled-back ]]; then
        validate_transaction_chain "$run_id" || {
            die '待恢复事务之外还存在孤立、链外或损坏记录；停止恢复并保留证据。'; return 40;
        }
    else
        validate_transaction_chain || {
            die '事务链含孤立、链外或损坏记录；停止恢复并保留证据。'; return 40;
        }
    fi
    set_outcome 'blocked' 'recovery_pending'
    case "$status" in
        prepared|applying|pending-confirm|guard-restoring|rollback-failed)
            if [[ "$status" != guard-restoring ]] && ! compare_set_transaction_status "$transaction" "$status" guard-restoring 2>/dev/null; then
                status=$(cat "$transaction/status" 2>/dev/null || true)
                [[ "$status" == guard-restoring ]] || { die '无法接管待恢复事务。'; return 40; }
            fi
            # If an apply process is still alive it may hold the global lock;
            # terminate it after the transaction CAS and before taking that
            # lock, otherwise a manual recovery could deadlock or time out.
            terminate_apply_owner "$transaction" || { die '无法终止原 apply 进程；事务保留为 guard-restoring。'; return 40; }
            acquire_lock 30 || { die '无法取得恢复锁；事务保留为 guard-restoring。'; return 40; }
            current=$(cat "$STATE_DIR/current_run" 2>/dev/null || true)
            if (( orphan_mode )); then
                [[ "$current" == "$orphan_previous" ]] || {
                    die '孤儿事务接管期间 current_run 已变化；拒绝覆盖较新的事务链。'; return 40;
                }
                write_current_run "$run_id" || { die '无法接入孤儿事务以进行安全恢复。'; return 40; }
                current=$run_id
            else
                if [[ -n "$current" && "$current" != "$run_id" ]]; then
                    die 'current_run 已指向另一事务；拒绝覆盖较新的事务链。'; return 40
                fi
                [[ "$current" == "$run_id" ]] || write_current_run "$run_id" || return 40
            fi
            if [[ "$phase" == all ]]; then
                # Persistent recovery is deliberately two phase: sysctl/files
                # first, qdisc only after network-online (with bounded retry
                # when this is the boot unit).
                restore_transaction "$transaction" config || {
                    recover_failure_result "$run_id" '配置/sysctl 恢复未完全成功；事务保留为 rollback-failed。'; return 40;
                }
                recover_qdisc_phase "$transaction" "$boot_mode" || {
                    recover_failure_result "$run_id" 'qdisc 恢复未完全成功；事务保留为 rollback-failed。'; return 40;
                }
            elif [[ "$phase" == qdisc ]]; then
                recover_qdisc_phase "$transaction" "$boot_mode" || {
                    recover_failure_result "$run_id" 'qdisc 恢复未完全成功；事务保留为 rollback-failed。'; return 40;
                }
            else
                restore_transaction "$transaction" config || {
                    recover_failure_result "$run_id" '配置/sysctl 恢复未完全成功；事务保留为 rollback-failed。'; return 40;
                }
            fi
            if [[ "$phase" != config ]] && ! cancel_rollback_guard "$transaction"; then
                set_outcome 'rollback_failed' 'recovery_pending'
                emit_json_result rollback_failed recovery_pending "$run_id" rollback-failed
                die '恢复已完成但回滚守卫停止/重置失败；事务状态保留并需要人工处理。'
                return 40
            fi
            ;;
        committed) : ;;
        rolled-back)
            # A crash can occur after the transaction status is atomically
            # marked rolled-back but before current_run is advanced.  Repair
            # that pointer under the global lock; do not rewrite any values.
            current=$(cat "$STATE_DIR/current_run" 2>/dev/null || true)
            if [[ "$current" == "$run_id" ]]; then
                acquire_lock 30 || { die '无法取得指针修复锁；事务保持为 rolled-back。'; return 40; }
                current=$(cat "$STATE_DIR/current_run" 2>/dev/null || true)
                if [[ "$current" == "$run_id" ]]; then
                    advance_rolled_back_head "$transaction" || { die 'rolled-back 事务的 current_run 指针修复失败。'; return 40; }
                elif [[ -n "$current" ]]; then
                    die 'current_run 已指向另一事务；拒绝覆盖较新的事务链。'; return 40
                fi
            fi
            ;;
        *) die "未知事务状态: $status"; return 40 ;;
    esac
    status=$(cat "$transaction/status" 2>/dev/null || printf unknown)
    if [[ "$status" == committed ]]; then
        set_outcome 'ok' 'already_committed'
        outcome=ok
    elif [[ "$status" == rolled-back ]]; then
        set_outcome 'rolled_back' 'recovered'
        outcome=rolled_back
    elif [[ "$status" == guard-restoring && "$phase" == config ]]; then
        set_outcome 'blocked' 'recovery_pending'
        outcome=blocked
    else
        outcome=blocked
    fi
    if (( JSON_OUTPUT )); then
        jq -n --arg schema "$SCHEMA_VERSION" --arg run "$run_id" --arg status "$status" --arg outcome "$outcome" --arg reason "$REASON_CODE" --arg phase "$phase" \
            '{schema_version:$schema,run_id:$run,outcome:$outcome,reason_code:$reason,phase:$phase,rollback_status:$status,warnings:[]}'
    else
        printf '恢复完成: run=%s status=%s%s\n' "$run_id" "$status" "$(if [[ $boot_mode == 1 ]]; then printf ' (boot)'; fi)"
    fi
}

cmd_confirm() {
    local run_id="" arg current="" transaction status verification temp
    JSON_OUTPUT=0; DRY_RUN=0; JSON_ERROR_EMITTED=0
    set_outcome '' ''
    while (($#)); do
        arg=$1; shift
        case "$arg" in
            --run) (($#)) || { die '--run 缺少值'; return 1; }; run_id=$1; shift ;;
            --run=*) run_id=${arg#*=} ;;
            --json) JSON_OUTPUT=1 ;;
            *) die "confirm 不支持参数: $arg"; return 1 ;;
        esac
    done
    require_root || return 1; require_real_apply_roots || return 1
    require_recovery_commands || return 1
    ensure_secure_state || return 1; acquire_lock 30 || return 1
    [[ -r "$STATE_DIR/current_run" ]] || { die '当前没有等待确认的 run。'; return 1; }
    current=$(cat "$STATE_DIR/current_run") || return 1
    [[ -n "$run_id" ]] || run_id=$current
    validate_run_id "$run_id" || { die 'confirm 需要有效的 --run RUN_ID。'; return 1; }
    [[ "$run_id" == "$current" ]] || { die '只能确认当前事务。'; return 1; }
    transaction="$STATE_DIR/transactions/$run_id"
    [[ -d "$transaction" && ! -L "$transaction" ]] || { die '找不到事务。'; return 1; }
    status=$(cat "$transaction/status" 2>/dev/null || printf unknown)
    [[ "$status" == pending-confirm ]] || { die "事务当前不是 pending-confirm: $status"; return 1; }
    transaction_snapshot_is_valid "$transaction" || { die '事务快照或所有权校验失败；保留守卫等待恢复。'; return 40; }
    validate_transaction_chain || {
        die '确认前事务链含孤立、链外或损坏记录；保留守卫并停止提交。'; return 40;
    }
    if ! verification=$(verify_current_state "$transaction" 2>&1); then
        [[ -z "$verification" ]] || printf '%s\n' "$verification" >&2
        die '确认前完整状态复核失败；保留回滚守卫。'; return 40
    fi
    if ! compare_set_transaction_status "$transaction" pending-confirm committed; then
        die '无法提交事务状态；守卫仍会按状态安全处理。'; return 40
    fi
    if [[ -f "$transaction/apply.json" && ! -L "$transaction/apply.json" ]] && command_exists jq; then
        temp=$(mktemp "$transaction/.apply-confirm.XXXXXXXX") || return 40
        if ! jq '.outcome="committed" | .reason_code="confirmed" | .rollback_status="committed"' "$transaction/apply.json" > "$temp" ||
           ! chmod 0600 "$temp" || ! atomic_install "$temp" "$transaction/apply.json" 0600; then
            rm -f -- "$temp"
            warn '事务已提交，但无法更新 apply.json；status 文件仍是权威状态。'
        elif [[ "$(transaction_get "$transaction" FORMAT_VERSION 2>/dev/null || true)" == "$STATE_FORMAT_VERSION" ]] &&
             ! write_private_hash_record "$transaction/apply.json" "$transaction/apply.json.sha256"; then
            warn '事务已提交，但无法更新 apply.json 哈希；status 文件仍是权威状态。'
        fi
    fi
    if ! cancel_rollback_guard "$transaction"; then
        # A committed transaction is still safe for the guard to observe, but
        # failure to stop/reset the timer must not be hidden from callers.
        warn '事务已提交，但无法取消守卫；守卫稍后会因 committed 状态安全退出。'
        set_outcome 'rollback_failed' 'recovery_pending'
        emit_json_result rollback_failed recovery_pending "$run_id" rollback-failed
        return 40
    fi
    if (( JSON_OUTPUT )); then
        jq -n --arg schema "$SCHEMA_VERSION" --arg run "$run_id" \
            '{schema_version:$schema,run_id:$run,outcome:"ok",reason_code:"confirmed",rollback_status:"committed",warnings:[]}'
    else
        printf '已确认并提交 run=%s；未重启任何代理服务。\n' "$run_id"
    fi
}

cmd_rollback() {
    local run_id="" current="" arg transaction status previous explicit_run=0 orphan_previous="" orphan_mode=0
    JSON_OUTPUT=0; DRY_RUN=0; JSON_ERROR_EMITTED=0
    set_outcome '' ''
    while (($#)); do
        arg=$1; shift
        case "$arg" in
            --run) (($#)) || { die '--run 缺少值'; return 1; }; run_id=$1; explicit_run=1; shift ;;
            --run=*) run_id=${arg#*=}; explicit_run=1 ;;
            --json) JSON_OUTPUT=1 ;;
            --dry-run) DRY_RUN=1 ;;
            *) die "rollback 不支持参数: $arg"; return 1 ;;
        esac
    done
    require_root || return 1; require_real_apply_roots || return 1
    require_recovery_commands || return 1
    ensure_secure_state || return 1
    [[ ! -r "$STATE_DIR/current_run" ]] || current=$(cat "$STATE_DIR/current_run")
    [[ -n "$run_id" ]] || run_id=$current
    validate_run_id "$run_id" || { die '没有可回滚的当前 run。'; return 1; }
    transaction="$STATE_DIR/transactions/$run_id"
    [[ -d "$transaction" && ! -L "$transaction" ]] || { die '找不到事务。'; return 1; }
    status=$(cat "$transaction/status" 2>/dev/null || printf unknown)
    if [[ "$run_id" != "$current" ]]; then
        previous=$(transaction_get "$transaction" PREVIOUS_RUN 2>/dev/null || true)
        if (( explicit_run == 1 )) && [[ "$status" == prepared && "$previous" == "$current" ]] &&
           transaction_snapshot_is_valid "$transaction"; then
            # Do not publish an orphan into current_run until after the
            # takeover handshake and global lock are held.  Otherwise a
            # concurrent apply could advance the chain between this check and
            # the pointer write, allowing an older orphan to overwrite it.
            orphan_mode=1
            orphan_previous="$current"
            current=$run_id
        else
            die '为保持事务顺序，只允许回滚当前 run；链外 prepared 事务须显式指定且通过 manifest 校验。'; return 1
        fi
    fi
    [[ "$status" == committed || "$status" == applying || "$status" == pending-confirm || "$status" == prepared || "$status" == guard-restoring || "$status" == rollback-failed || "$status" == rolled-back ]] || { die "事务状态不可回滚: $status"; return 1; }
    if [[ "$status" == committed ]]; then
        validate_transaction_chain || {
            die '回滚前事务链含孤立、链外或损坏记录；停止回滚并保留证据。'; return 40;
        }
    else
        validate_transaction_chain "$run_id" || {
            die '回滚前事务链含其他未完成、链外或损坏记录；停止回滚并保留证据。'; return 40;
        }
    fi
    if (( DRY_RUN )); then
        if (( JSON_OUTPUT )); then json_operation_result ok rollback_preview "$run_id" dry-run
        else printf 'dry-run：将恢复事务 %s 的 runtime、owned 文件和 qdisc 快照。\n' "$run_id"; fi
        return 0
    fi
    if [[ "$status" != committed && "$status" != rolled-back ]]; then
        # Take ownership before waiting for the global lock.  An active apply
        # can hold that lock, so waiting first would make an explicit manual
        # rollback unable to interrupt a hung or disconnected apply.
        if [[ "$status" != guard-restoring ]]; then
            if ! compare_set_transaction_status "$transaction" "$status" guard-restoring 2>/dev/null; then
                status=$(cat "$transaction/status" 2>/dev/null || true)
                [[ "$status" == committed || "$status" == rolled-back || "$status" == guard-restoring ]] || {
                    die '无法接管待回滚事务；守卫或其他操作仍在处理。'; return 40;
                }
            else
                status=guard-restoring
            fi
        fi
        if [[ "$status" == guard-restoring ]]; then
            terminate_apply_owner "$transaction" || { die '无法终止原 apply 进程；事务保留为 guard-restoring。'; return 40; }
        fi
    fi
    acquire_lock 30 || return 1
    current=$(cat "$STATE_DIR/current_run" 2>/dev/null || true)
    if (( orphan_mode )); then
        [[ "$current" == "$orphan_previous" ]] || { die 'prepared 孤儿事务接管期间 current_run 已前进；拒绝覆盖较新的事务链。'; return 40; }
        write_current_run "$run_id" || { die '无法接入 prepared 孤儿事务以进行安全恢复。'; return 40; }
        current=$run_id
    else
        [[ "$current" == "$run_id" ]] || { die 'current_run 已指向另一事务；拒绝越过较新的事务回滚。'; return 40; }
    fi
    status=$(cat "$transaction/status" 2>/dev/null || printf unknown)
    [[ "$status" == committed || "$status" == applying || "$status" == pending-confirm || "$status" == prepared || "$status" == guard-restoring || "$status" == rollback-failed || "$status" == rolled-back ]] || {
        die "事务状态在回滚前发生变化: $status"; return 40;
    }
    restore_transaction "$transaction" || {
        set_outcome 'rollback_failed' 'apply_failed'
        emit_json_result rollback_failed apply_failed "$run_id" rollback-failed
        die '回滚未完全成功，请检查审计状态。'; return 1;
    }
    if ! cancel_rollback_guard "$transaction"; then
        set_outcome 'rollback_failed' 'recovery_pending'
        emit_json_result rollback_failed recovery_pending "$run_id" rolled-back
        die '回滚已完成但守卫停止/重置失败；请人工检查。'; return 40
    fi
    set_outcome 'rolled_back' 'manual_rollback'
    if (( JSON_OUTPUT )); then
        jq -n --arg schema "$SCHEMA_VERSION" --arg run "$run_id" '{schema_version:$schema,run_id:$run,outcome:"rolled_back",reason_code:"manual_rollback",environment:{},path:{},metrics:{},quality:"not-measured",confidence:"not-measured",recommendations:{},changes:[],warnings:[],rollback_status:"rolled-back"}'
    else
        printf '已回滚 run=%s；未重启任何代理服务。\n' "$run_id"
    fi
}

verify_current_state() {
    local transaction="$1" verify_routes="${2:-1}" scope="${3:-all}" check_config=1 check_path=1
    local run_dir desired key value before reason current
    local iface changed fp_now host _port family address source _route_iface fingerprint route_unambiguous resolved failures=0
    local expected_hash actual_hash service_path service_hash service_unit service_record modules_hash modules_existed modules_before_hash qdisc_hash format_version
    local previous chain_status inherited_path inherited_hash inherited_unit inherited_record inherited_changed inherited_iface inherited_qdisc_hash
    local registry_unit registry_path registry_hash registry_extra
    local qdisc_checked=0
    local -A seen_transactions=() seen_services=()
    is_bool01 "$verify_routes" || return 1
    case "$scope" in
        config) check_path=0 ;;
        path) check_config=0 ;;
        all) ;;
        *) return 1 ;;
    esac
    transaction=${transaction%/}; run_dir="$STATE_DIR/runs/$(basename "$transaction")"
    desired="$transaction/desired.tsv"
    transaction_snapshot_is_valid "$transaction" || return 1
    format_version=$(transaction_get "$transaction" FORMAT_VERSION 2>/dev/null || true)
    verify_hash_manifest "$run_dir" "$run_dir/plan.sha256" || return 1
    if (( check_config )); then
        validate_service_registry || { printf 'owned service registry is invalid\n'; failures=$((failures + 1)); }
        if ! recovery_artifacts_are_valid; then
            printf 'persistent recovery artifact ownership or hash mismatch\n'
            failures=$((failures + 1))
        fi
        while IFS=$'\t' read -r key value before reason change_type; do
            current=$(sysctl_read "$key" 2>/dev/null || true)
            [[ "$current" == "$value" ]] || { printf 'sysctl %s: expected=%s actual=%s\n' "$key" "$value" "$current"; failures=$((failures + 1)); }
        done < "$desired"
        expected_hash=$(transaction_get "$transaction" SYSCTL_HASH 2>/dev/null || true)
        if secure_owned_file "$SYSCTL_FILE" && [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] &&
           managed_file_has_marker "$SYSCTL_FILE" &&
           { [[ "$format_version" != "$STATE_FORMAT_VERSION" ]] || managed_file_has_current_metadata "$SYSCTL_FILE"; }; then
            actual_hash=$(sha256sum "$SYSCTL_FILE" | awk '{print $1}')
            if [[ "$actual_hash" == "$expected_hash" ]]; then
                owned_after_identity_is_current "$transaction" sysctl "$SYSCTL_FILE" || {
                    printf 'owned sysctl inode or mode drift\n'; failures=$((failures + 1));
                }
            else
                printf 'owned sysctl hash mismatch\n'; failures=$((failures + 1))
            fi
        else
            printf 'missing or unsafe owned file: %s\n' "$SYSCTL_FILE"; failures=$((failures + 1))
        fi
    fi
    if (( check_config )); then
        modules_hash=$(transaction_get "$transaction" MODULES_HASH 2>/dev/null || true)
        modules_existed=$(awk -F'\t' '$1=="modules"{print $3;exit}' "$transaction/files.tsv" 2>/dev/null || true)
        modules_before_hash=$(awk -F'\t' '$1=="modules"{print $5;exit}' "$transaction/files.tsv" 2>/dev/null || true)
        if [[ -z "$modules_hash" && "$modules_existed" == 1 ]]; then modules_hash=$modules_before_hash; fi
        if [[ "$modules_hash" =~ ^[0-9a-f]{64}$ ]]; then
            if secure_owned_file "$MODULES_FILE" && managed_file_has_marker "$MODULES_FILE" &&
               { [[ "$format_version" != "$STATE_FORMAT_VERSION" ]] || managed_file_has_current_metadata "$MODULES_FILE"; }; then
                actual_hash=$(sha256sum "$MODULES_FILE" 2>/dev/null | awk '{print $1}')
                if [[ "$actual_hash" == "$modules_hash" ]]; then
                    owned_after_identity_is_current "$transaction" modules "$MODULES_FILE" || {
                        printf 'owned modules-load inode or mode drift\n'; failures=$((failures + 1));
                    }
                else
                    printf 'owned modules-load hash mismatch\n'; failures=$((failures + 1))
                fi
            else
                printf 'missing or unsafe owned modules-load file\n'; failures=$((failures + 1))
            fi
        elif [[ "$modules_existed" == 0 && ( -e "$MODULES_FILE" || -L "$MODULES_FILE" ) ]]; then
            printf 'unexpected owned modules-load file\n'; failures=$((failures + 1))
        elif [[ "$modules_existed" != 0 ]]; then
            printf 'invalid modules-load snapshot metadata\n'; failures=$((failures + 1))
        fi
        service_path=$(transaction_get "$transaction" SERVICE_PATH 2>/dev/null || true)
        service_hash=$(transaction_get "$transaction" SERVICE_HASH 2>/dev/null || true)
        if [[ -n "$service_path" && "$service_hash" =~ ^[0-9a-f]{64}$ ]]; then
            seen_services[$service_path]=$service_hash
            service_unit=$(transaction_get "$transaction" SERVICE 2>/dev/null || true)
            service_record=$(registry_service_record "$service_unit" 2>/dev/null || true)
            if ! owned_path_allowed "$service_path" || ! secure_owned_file "$service_path" ||
               ! managed_file_has_marker "$service_path" ||
               { [[ "$format_version" != "$STATE_FORMAT_VERSION" ]] || ! managed_file_has_current_metadata "$service_path"; } ||
               [[ "$service_record" != "$service_unit"$'\t'"$service_path"$'\t'"$service_hash" ]]; then
                printf 'owned service drop-in metadata mismatch\n'; failures=$((failures + 1))
            else
                actual_hash=$(sha256sum "$service_path" 2>/dev/null | awk '{print $1}')
                if [[ "$actual_hash" == "$service_hash" ]]; then
                    owned_after_identity_is_current "$transaction" service "$service_path" || {
                        printf 'owned service drop-in inode or mode drift\n'; failures=$((failures + 1));
                    }
                else
                    printf 'owned service drop-in hash mismatch\n'; failures=$((failures + 1))
                fi
            fi
        elif [[ -n "$service_path" || -n "$service_hash" ]]; then
            printf 'invalid owned service drop-in metadata\n'; failures=$((failures + 1))
        fi
    fi
    if (( check_path )); then
        changed=$(transaction_get "$transaction" QDISC_CHANGED 2>/dev/null || printf 0)
    else
        changed=0
    fi
    if [[ "$changed" == 1 ]]; then
        qdisc_checked=1
        iface=$(transaction_get "$transaction" QDISC_IFACE)
        qdisc_hash=$(transaction_get "$transaction" QDISC_AFTER_HASH 2>/dev/null || true)
        actual_hash=$(qdisc_root_fingerprint "$iface" 2>/dev/null || true)
        [[ -n "$qdisc_hash" && "$actual_hash" == "$qdisc_hash" ]] || {
            printf 'qdisc %s ownership fingerprint mismatch\n' "$iface"; failures=$((failures + 1));
        }
    fi
    previous=$(transaction_get "$transaction" PREVIOUS_RUN 2>/dev/null || true)
    while [[ -n "$previous" ]]; do
        validate_run_id "$previous" || { failures=$((failures + 1)); break; }
        [[ -z "${seen_transactions[$previous]+x}" ]] || { failures=$((failures + 1)); break; }
        seen_transactions[$previous]=1
        current="$STATE_DIR/transactions/$previous"
        [[ -d "$current" && ! -L "$current" ]] || { failures=$((failures + 1)); break; }
        chain_status=$(cat "$current/status" 2>/dev/null || true)
        [[ "$chain_status" == committed ]] || { failures=$((failures + 1)); break; }
        verify_hash_manifest "$current" "$current/snapshot.sha256" || { failures=$((failures + 1)); break; }
        if (( check_config )); then
            inherited_path=$(transaction_get "$current" SERVICE_PATH 2>/dev/null || true)
            inherited_hash=$(transaction_get "$current" SERVICE_HASH 2>/dev/null || true)
            if [[ -n "$inherited_path" && -z "${seen_services[$inherited_path]+x}" ]]; then
                seen_services[$inherited_path]=$inherited_hash
                inherited_unit=$(transaction_get "$current" SERVICE 2>/dev/null || true)
                inherited_record=$(registry_service_record "$inherited_unit" 2>/dev/null || true)
                if [[ -z "$inherited_hash" ]] || ! owned_path_allowed "$inherited_path" ||
                   ! secure_owned_file "$inherited_path" || ! managed_file_has_marker "$inherited_path" ||
                   { [[ "$(transaction_get "$current" FORMAT_VERSION 2>/dev/null || true)" != "$STATE_FORMAT_VERSION" ]] || ! managed_file_has_current_metadata "$inherited_path"; } ||
                   [[ "$inherited_record" != "$inherited_unit"$'\t'"$inherited_path"$'\t'"$inherited_hash" ]]; then
                    printf 'inherited service drop-in metadata mismatch: %s\n' "$inherited_path"; failures=$((failures + 1))
                else
                    actual_hash=$(sha256sum "$inherited_path" 2>/dev/null | awk '{print $1}')
                    if [[ "$actual_hash" == "$inherited_hash" ]]; then
                        owned_after_identity_is_current "$current" service "$inherited_path" || {
                            printf 'inherited service drop-in inode or mode drift: %s\n' "$inherited_path"; failures=$((failures + 1));
                        }
                    else
                        printf 'inherited service drop-in hash mismatch: %s\n' "$inherited_path"; failures=$((failures + 1))
                    fi
                fi
            fi
        fi
        inherited_changed=$(transaction_get "$current" QDISC_CHANGED 2>/dev/null || printf 0)
        if (( check_path && qdisc_checked == 0 )) && [[ "$inherited_changed" == 1 ]]; then
            qdisc_checked=1
            inherited_iface=$(transaction_get "$current" QDISC_IFACE 2>/dev/null || true)
            inherited_qdisc_hash=$(transaction_get "$current" QDISC_AFTER_HASH 2>/dev/null || true)
            actual_hash=$(qdisc_root_fingerprint "$inherited_iface" 2>/dev/null || true)
            [[ -n "$inherited_qdisc_hash" && "$actual_hash" == "$inherited_qdisc_hash" ]] || {
                printf 'inherited qdisc ownership fingerprint mismatch: %s\n' "$inherited_iface"; failures=$((failures + 1));
            }
        fi
        previous=$(transaction_get "$current" PREVIOUS_RUN 2>/dev/null || true)
    done
    if (( check_config )) && [[ -r "$STATE_DIR/owned-services.tsv" ]]; then
        while IFS=$'\t' read -r registry_unit registry_path registry_hash registry_extra; do
            if [[ -z "$registry_unit" || -z "$registry_path" || ! "$registry_hash" =~ ^[0-9a-f]{64}$ || -n "${registry_extra:-}" ]]; then
                printf 'owned service registry contains a malformed record\n'
                failures=$((failures + 1))
            elif [[ -z "${seen_services[$registry_path]+x}" ]]; then
                printf 'owned service registry contains an unreferenced record: %s\n' "$registry_unit"
                failures=$((failures + 1))
            elif [[ "${seen_services[$registry_path]}" != "$registry_hash" ]]; then
                printf 'owned service registry hash disagrees with transaction: %s\n' "$registry_unit"
                failures=$((failures + 1))
            fi
        done < "$STATE_DIR/owned-services.tsv"
    fi
    if (( check_path == 0 || verify_routes == 0 )); then
        :
    elif [[ -r "$run_dir/peers.tsv" ]]; then
        while IFS=$'\t' read -r host _port family address source _route_iface fingerprint route_unambiguous; do
            [[ "$route_unambiguous" == 1 ]] || { printf 'ambiguous frozen route: %s\n' "$address"; failures=$((failures + 1)); }
            route_is_unambiguous "$family" "$address" "$source" || { printf 'route is now ambiguous: %s\n' "$address"; failures=$((failures + 1)); }
            resolved=$(resolve_peer_host "$host" "$family" 2>/dev/null || printf unavailable)
            [[ "$resolved" == "$address" ]] || { printf 'address family or DNS drift: %s\n' "$host"; failures=$((failures + 1)); }
            fp_now=$(route_fingerprint "$family" "$address" "$source" 2>/dev/null || printf unavailable)
            [[ "$fp_now" == "$fingerprint" ]] || { printf 'route drift: %s\n' "$address"; failures=$((failures + 1)); }
        done < "$run_dir/peers.tsv"
    else
        printf 'missing frozen peer data\n'; failures=$((failures + 1))
    fi
    (( failures == 0 ))
}

cmd_verify() {
    local arg run_id transaction deviations status result=ok scope=all
    JSON_OUTPUT=0; DRY_RUN=0; JSON_ERROR_EMITTED=0
    set_outcome '' ''
    # Parse the output-format flag before validating the remaining arguments so
    # an unsupported option such as `--dry-run --json` still obeys the global
    # JSON error contract regardless of option order.  This does not assign any
    # execution meaning to --dry-run; the option remains rejected below.
    for arg in "$@"; do
        [[ "$arg" == --json ]] && JSON_OUTPUT=1
    done
    while (($#)); do
        arg=$1; shift
        case "$arg" in
            --json) JSON_OUTPUT=1 ;;
            --scope) (($#)) || { die '--scope 缺少值'; return 1; }; scope=$1; shift ;;
            --scope=*) scope=${arg#*=} ;;
            *) die "verify 不支持参数: $arg"; return 1 ;;
        esac
    done
    [[ "$scope" == config || "$scope" == path || "$scope" == all ]] || { die '--scope 只能是 config、path 或 all。'; return 1; }
    require_root || return 1; require_real_apply_roots || return 1; require_verify_commands "$scope" || return 1; ensure_secure_state || return 1
    [[ -r "$STATE_DIR/current_run" ]] || { die '当前没有已应用的 run。'; return 1; }
    run_id=$(cat "$STATE_DIR/current_run"); validate_run_id "$run_id" || return 1
    transaction="$STATE_DIR/transactions/$run_id"; status=$(cat "$transaction/status" 2>/dev/null || printf unknown)
    [[ "$status" == committed || "$status" == pending-confirm ]] || { die "当前事务状态异常: $status"; return 1; }
    deviations=$(verify_current_state "$transaction" 1 "$scope" 2>&1) || result=failed
    if [[ "$result" == ok ]]; then
        if [[ "$status" == pending-confirm ]]; then set_outcome 'pending_confirm' 'verification_passed'; else set_outcome 'ok' 'verification_passed'; fi
    else
        set_outcome 'failed' 'verification_failed'
    fi
    if (( JSON_OUTPUT )); then
        jq -n --arg schema "$SCHEMA_VERSION" --arg run "$run_id" --arg result "$result" --arg scope "$scope" --arg deviations "$deviations" --arg outcome "$OUTCOME" --arg reason "$REASON_CODE" --arg rollback "$status" \
            '{schema_version:$schema,run_id:$run,outcome:$outcome,reason_code:$reason,scope:$scope,environment:{},path:{},metrics:{verification:$result},quality:"not-measured",confidence:"not-measured",recommendations:{},warnings:($deviations|split("\n")|map(select(length>0))),rollback_status:$rollback}'
        JSON_ERROR_EMITTED=1
    else
        if [[ "$result" == ok ]]; then printf 'verify 通过：运行时 sysctl、owned 文件、qdisc 和冻结路由一致。\n'
        else printf 'verify 失败:\n%s\n' "$deviations"; fi
    fi
    if [[ "$result" != ok ]]; then return 1; fi
    [[ "$status" == committed ]] || return 20
}

history_run_is_safe() {
    local run_dir="$1" manifest manifest_name file relative line rel
    local -A listed=()
    [[ -d "$run_dir" && ! -L "$run_dir" ]] || return 1
    validate_run_id "$(basename "$run_dir")" || return 1
    secure_private_path "$run_dir" || return 1
    [[ -f "$run_dir/metrics.tsv" && ! -L "$run_dir/metrics.tsv" &&
       -f "$run_dir/status" && ! -L "$run_dir/status" ]] || return 1
    [[ "$(cat "$run_dir/status" 2>/dev/null || true)" == measured ]] || return 1
    if [[ -f "$run_dir/plan.sha256" && ! -L "$run_dir/plan.sha256" ]]; then
        manifest="$run_dir/plan.sha256"
    elif [[ -f "$run_dir/measurement.sha256" && ! -L "$run_dir/measurement.sha256" ]]; then
        manifest="$run_dir/measurement.sha256"
    else
        return 1
    fi
    verify_hash_manifest "$run_dir" "$manifest" || return 1
    manifest_name=$(basename "$manifest")
    while IFS= read -r line || [[ -n "$line" ]]; do
        rel=${line#*  }
        [[ -n "$rel" ]] || return 1
        listed[$rel]=1
    done < "$manifest"
    [[ -z "$(find "$run_dir" -type l -print -quit 2>/dev/null)" ]] || return 1
    while IFS= read -r -d '' file; do
        secure_private_path "$file" || return 1
        relative=${file#"$run_dir"/}
        case "$relative" in
            "$manifest_name"|sysctl.conf.apply|all-owned-plan.tsv) ;;
            *) [[ -n "${listed[$relative]+x}" ]] || return 1 ;;
        esac
    done < <(find "$run_dir" -mindepth 1 \( -type f -o -type d \) -print0)
}

cmd_history_prune() {
    local arg keep="" assume_yes=0 dry=0 current="" entry name entry_status run_dir manifest_count=0 removed_count=0
    local entry_temp removed="" current_after
    local -a run_names=()
    local -A protected=()
    JSON_OUTPUT=0; JSON_ERROR_EMITTED=0
    while (($#)); do
        arg=$1; shift
        case "$arg" in
            --keep) (($#)) || { die '--keep 缺少值'; return 1; }; keep=$1; shift ;;
            --keep=*) keep=${arg#*=} ;;
            --yes) assume_yes=1 ;;
            --dry-run) dry=1 ;;
            --json) JSON_OUTPUT=1 ;;
            *) die "history prune 不支持参数: $arg"; return 1 ;;
        esac
    done
    if ! is_positive_uint "$keep" || (( keep > 1000 )); then die '--keep 必须是 1..1000 的整数。'; return 1; fi
    require_root || return 1
    [[ "$assume_yes" == 1 || "$dry" == 1 ]] || {
        REASON_CODE=history_confirmation_required
        die 'history prune 必须显式提供 --yes；可先使用 --dry-run 预览。'
        return 1
    }
    [[ -d "$STATE_DIR" && ! -L "$STATE_DIR" ]] || {
        if (( JSON_OUTPUT )); then json_operation_result ok history_empty "" not-applicable; else printf '暂无历史记录。\n'; fi
        return 0
    }
    require_file_commands || return 1
    ensure_secure_state || return 1
    validate_transaction_chain || {
        REASON_CODE=ownership_drift
        die '事务链包含未认证、漂移或孤立记录；历史清理停止。'
        return 40
    }
    if (( dry == 0 )); then
        acquire_lock 30 || return 1
        validate_transaction_chain || {
            REASON_CODE=ownership_drift
            die '取得清理锁后事务链发生变化；历史清理停止。'
            return 40
        }
    fi
    [[ -r "$STATE_DIR/current_run" ]] && current=$(cat "$STATE_DIR/current_run" 2>/dev/null || true)
    if [[ -n "$current" ]]; then
        validate_run_id "$current" || { REASON_CODE=ownership_drift; die 'current_run 指针无效；历史清理停止。'; return 40; }
        protected[$current]=1
    fi
    shopt -s nullglob
    local -a transaction_entries=("$STATE_DIR"/transactions/* "$STATE_DIR"/transactions/.[!.]* "$STATE_DIR"/transactions/..?*)
    shopt -u nullglob
    for entry in "${transaction_entries[@]}"; do
        name=$(basename "$entry")
        transaction_staging_name "$name" && continue
        validate_run_id "$name" || { REASON_CODE=ownership_drift; die '事务目录存在未认证名称；历史清理停止。'; return 40; }
        [[ -d "$entry" && ! -L "$entry" ]] || { REASON_CODE=ownership_drift; die '事务条目类型不安全；历史清理停止。'; return 40; }
        entry_status=$(cat "$entry/status" 2>/dev/null || true)
        case "$entry_status" in
            prepared|applying|pending-confirm|guard-restoring|rollback-failed)
                # Never remove a measurement run that still backs an
                # incomplete transaction; recovery/audit may need its plan.
                protected[$name]=1
                ;;
            committed|rolled-back) ;;
            *) REASON_CODE=ownership_drift; die '事务状态未知；历史清理停止。'; return 40 ;;
        esac
    done
    entry_temp=$(mktemp /tmp/vps-proxy-tune-history-prune.XXXXXXXX) || return 1
    : > "$entry_temp" || { rm -f -- "$entry_temp"; return 1; }
    shopt -s nullglob
    local -a run_entries=("$STATE_DIR"/runs/* "$STATE_DIR"/runs/.[!.]* "$STATE_DIR"/runs/..?*)
    shopt -u nullglob
    for entry in "${run_entries[@]}"; do
        name=$(basename "$entry")
        if validate_run_id "$name"; then
            printf '%s\n' "$name" >> "$entry_temp" || { rm -f -- "$entry_temp"; return 1; }
        fi
    done
    mapfile -t run_names < <(LC_ALL=C sort -r "$entry_temp")
    rm -f -- "$entry_temp"
    for name in "${run_names[@]}"; do
        run_dir="$STATE_DIR/runs/$name"
        if ! history_run_is_safe "$run_dir"; then
            # A drifted or unknown run is evidence, not a cleanup target.  It
            # remains counted as retained so pruning cannot consume older
            # history merely because a newer entry is unsafe to inspect.
            manifest_count=$((manifest_count + 1))
            continue
        fi
        manifest_count=$((manifest_count + 1))
        [[ -n "${protected[$name]+x}" ]] && continue
        (( manifest_count <= keep )) && continue
        if (( dry )); then
            removed+="$name"$'\n'
            removed_count=$((removed_count + 1))
            continue
        fi
        [[ -r "$STATE_DIR/current_run" ]] && current_after=$(cat "$STATE_DIR/current_run" 2>/dev/null || true) || current_after=""
        [[ "$current_after" != "$name" && -z "${protected[$name]+x}" ]] || continue
        history_run_is_safe "$run_dir" || continue
        if ! rm -rf -- "$run_dir"; then
            REASON_CODE=operation_failed
            die "无法删除已验证的历史 run: $name"
            return 1
        fi
        removed+="$name"$'\n'
        removed_count=$((removed_count + 1))
    done
    if (( JSON_OUTPUT )); then
        printf '{"schema_version":%s,"outcome":"ok","reason_code":%s,"keep":%s,"removed_runs":' \
            "$(json_string "$SCHEMA_VERSION")" "$(json_string "$([[ $dry == 1 ]] && printf history_prune_preview || printf history_pruned)")" "$keep"
        json_lines_array "$removed"
        printf ',"rollback_status":"not-applicable"}\n'
        JSON_ERROR_EMITTED=1
    else
        if (( dry )); then
            printf 'dry-run：保留最新 %s 个安全历史 run，将删除 %s 个：\n' "$keep" "$removed_count"
        else
            printf '历史清理完成：保留最新 %s 个安全历史 run，删除 %s 个。\n' "$keep" "$removed_count"
        fi
        [[ -z "$removed" ]] || printf '%b' "$removed"
    fi
}

cmd_history() {
    local action=list
    JSON_OUTPUT=0; JSON_ERROR_EMITTED=0
    if (($#)) && [[ "$1" != --* ]]; then action=$1; shift; fi
    case "$action" in
        list) ;;
        prune) cmd_history_prune "$@"; return $? ;;
        *) die 'history 只支持 list 或 prune。'; return 1 ;;
    esac
    local arg limit=100 run run_dir metrics run_status profile confidence quality created mbps rtt txn_status ri
    local temp rows=0
    while (($#)); do
        arg=$1; shift
        case "$arg" in
            --json) JSON_OUTPUT=1 ;;
            --limit) (($#)) || { die '--limit 缺少值'; return 1; }; limit=$1; shift ;;
            --limit=*) limit=${arg#*=} ;;
            *) die "history 不支持参数: $arg"; return 1 ;;
        esac
    done
    if ! is_positive_uint "$limit" || (( limit > 1000 )); then die '--limit 必须是 1..1000 的整数。'; return 1; fi
    require_root || return 1
    if [[ ! -d "$STATE_DIR" || -L "$STATE_DIR" ]]; then
        if (( JSON_OUTPUT )); then
            printf '{"schema_version":%s,"outcome":"ok","reason_code":"history_empty","limit":%s,"runs":[],"rollback_status":"not-applicable"}\n' \
                "$(json_string "$SCHEMA_VERSION")" "$limit"
            JSON_ERROR_EMITTED=1
        else
            printf '暂无历史记录。\n'
        fi
        return 0
    fi
    ensure_secure_state || return 1
    if (( JSON_OUTPUT )) && ! command_exists jq; then
        die 'history JSON 输出需要 jq；请先执行 deps check/install --phase common。'
        return 1
    fi
    trusted_tmp_dir || return 1
    temp=$(mktemp /tmp/vps-proxy-tune-history.XXXXXXXX) || return 1
    : > "$temp" || { rm -f -- "$temp"; return 1; }
    shopt -s nullglob
    local -a run_dirs=("$STATE_DIR"/runs/*)
    shopt -u nullglob
    for ((ri=${#run_dirs[@]}-1; ri>=0; ri--)); do
        run_dir=${run_dirs[$ri]}
        [[ -d "$run_dir" && ! -L "$run_dir" ]] || continue
        run=$(basename "$run_dir")
        validate_run_id "$run" || continue
        metrics="$run_dir/metrics.tsv"
        [[ -r "$metrics" ]] || continue
        run_status=$(cat "$run_dir/status" 2>/dev/null || printf unknown)
        profile=$(metric_get "$metrics" PROFILE 2>/dev/null || printf tcp)
        confidence=$(metric_get "$metrics" CONFIDENCE 2>/dev/null || printf unknown)
        quality=$(metric_get "$metrics" QUALITY 2>/dev/null || printf unknown)
        created=$(metric_get "$metrics" CREATED_AT 2>/dev/null || printf unknown)
        mbps=$(metric_get "$metrics" EFFECTIVE_MBPS 2>/dev/null || printf 0)
        rtt=$(metric_get "$metrics" RTT_P95_MS 2>/dev/null || printf 0)
        txn_status=$(cat "$STATE_DIR/transactions/$run/status" 2>/dev/null || printf none)
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$run" "$run_status" "$txn_status" "$profile" "$confidence" "$quality" "$created" "$mbps" "$rtt" >> "$temp" || { rm -f -- "$temp"; return 1; }
        rows=$((rows + 1)); (( rows >= limit )) && break
    done
    if (( JSON_OUTPUT )); then
        if ! jq -Rsc --arg schema "$SCHEMA_VERSION" --argjson limit "$limit" \
            '{schema_version:$schema,outcome:"ok",reason_code:"history_list",limit:$limit,runs:([split("\n")[] | select(length>0) | split("\t") | {run_id:.[0],measurement_status:.[1],transaction_status:.[2],profile:.[3],confidence:.[4],quality:.[5],created_at:.[6],effective_mbps:(.[7]|tonumber? // null),rtt_p95_ms:(.[8]|tonumber? // null)}] | .[:$limit]),rollback_status:"not-applicable"}' < "$temp"; then
            rm -f -- "$temp"
            die '无法生成稳定的 history JSON。'
            return 1
        fi
        JSON_ERROR_EMITTED=1
    else
        printf 'run_id\tmeasurement\ttransaction\tprofile\tconfidence\tquality\tcreated_at\teffective_mbps\trtt_p95_ms\n'
        LC_ALL=C sort -r "$temp"
    fi
    rm -f -- "$temp"
}

cmd_status() {
    local arg run_id="" status=none owned_sysctl=0 owned_modules=0 chain_ok=1 recovery=0 recovery_managed=0 recovery_qdisc=0 recovery_qdisc_managed=0 guard_unit="" warning_text="" state_format=legacy
    local recovery_source_run="" recovery_binding=none config_source qdisc_source
    JSON_OUTPUT=0; DRY_RUN=0; JSON_ERROR_EMITTED=0
    for arg in "$@"; do case "$arg" in --json) JSON_OUTPUT=1 ;; *) die "status 不支持参数: $arg"; return 1 ;; esac; done
    (( EUID == 0 )) || { die 'status 需要 root 才能读取 0700 状态目录。'; return 1; }
    if [[ ! -d "$STATE_DIR" || -L "$STATE_DIR" ]]; then
        if (( JSON_OUTPUT )); then
            printf '{"schema_version":%s,"outcome":"ok","reason_code":"status_empty","state_format":"none","run_id":null,"transaction_status":"none","chain_valid":true,"recovery_unit_enabled":false,"recovery_unit_managed":false,"recovery_qdisc_unit_enabled":false,"recovery_qdisc_unit_managed":false,"recovery_source_run":null,"recovery_binding":"none","owned_files":{"sysctl":false,"modules_load":false},"warnings":["state directory is not initialized"]}\n' \
                "$(json_string "$SCHEMA_VERSION")"
            JSON_ERROR_EMITTED=1
        else
            printf '当前 run: none\n事务状态: none\n状态目录尚未初始化: %s\n' "$STATE_DIR"
        fi
        return 0
    fi
    ensure_secure_state || return 1
    if (( JSON_OUTPUT )) && ! command_exists jq; then
        die 'status JSON 输出需要 jq；请先执行 deps check/install --phase common。'
        return 1
    fi
    if [[ -r "$(state_format_file)" ]]; then state_format=$(cat "$(state_format_file)" 2>/dev/null || printf legacy); fi
    if [[ -r "$STATE_DIR/current_run" ]]; then
        run_id=$(cat "$STATE_DIR/current_run" 2>/dev/null || true)
        validate_run_id "$run_id" || { chain_ok=0; warning_text='current_run 指针无效'; run_id=""; }
    fi
    if [[ -n "$run_id" && -r "$STATE_DIR/transactions/$run_id/status" ]]; then
        status=$(cat "$STATE_DIR/transactions/$run_id/status" 2>/dev/null || printf unknown)
        guard_unit=$(transaction_get "$STATE_DIR/transactions/$run_id" GUARD_UNIT 2>/dev/null || true)
    elif [[ -n "$run_id" ]]; then
        chain_ok=0; warning_text='current_run 指向缺失事务'
    fi
    if ! validate_transaction_chain >/dev/null 2>&1; then chain_ok=0; [[ -n "$warning_text" ]] || warning_text='事务链校验失败'; fi
    managed_file_has_marker "$SYSCTL_FILE" && owned_sysctl=1
    managed_file_has_marker "$MODULES_FILE" && owned_modules=1
    if managed_file_has_marker "$RECOVERY_UNIT_PATH"; then
        recovery_managed=1
        if command_exists systemctl && systemctl is-enabled --quiet vps-proxy-tune-recover.service 2>/dev/null; then
            recovery=1
        fi
    fi
    if managed_file_has_marker "$RECOVERY_QDISC_UNIT_PATH"; then
        recovery_qdisc_managed=1
        if command_exists systemctl && systemctl is-enabled --quiet vps-proxy-tune-recover-qdisc.service 2>/dev/null; then
            recovery_qdisc=1
        fi
    fi
    if (( recovery_managed || recovery_qdisc_managed )); then
        config_source=$(recovery_unit_source_run "$RECOVERY_UNIT_PATH" 2>/dev/null || true)
        qdisc_source=$(recovery_unit_source_run "$RECOVERY_QDISC_UNIT_PATH" 2>/dev/null || true)
        recovery_binding=$(recovery_binding_state)
        if [[ -n "$config_source" && "$config_source" == "$qdisc_source" ]]; then
            recovery_source_run=$config_source
        else
            chain_ok=0
            [[ -z "$warning_text" ]] || warning_text+='; '
            warning_text+='恢复单元 source run 元数据缺失或不一致'
        fi
        if [[ "$recovery_binding" == stale ]]; then
            [[ -z "$warning_text" ]] || warning_text+='; '
            warning_text+="恢复单元绑定 $recovery_source_run，但 current_run 为 ${run_id:-none}"
        elif [[ "$recovery_binding" == invalid ]]; then
            chain_ok=0
        fi
    fi
    if (( JSON_OUTPUT )); then
        jq -n --arg schema "$SCHEMA_VERSION" --arg run "$run_id" --arg status "$status" --arg guard "$guard_unit" --arg warning "$warning_text" --arg format "$state_format" \
            --argjson chain "$chain_ok" --argjson recovery "$recovery" --argjson recovery_managed "$recovery_managed" --argjson recovery_qdisc "$recovery_qdisc" --argjson recovery_qdisc_managed "$recovery_qdisc_managed" --argjson sysctl "$owned_sysctl" --argjson modules "$owned_modules" \
            --arg source "$recovery_source_run" --arg binding "$recovery_binding" \
            '{schema_version:$schema,outcome:(if $chain==1 then "ok" else "blocked" end),reason_code:(if $chain==1 then "status" else "ownership_drift" end),state_format:$format,run_id:(if $run=="" then null else $run end),transaction_status:$status,chain_valid:($chain==1),guard_unit:(if $guard=="" then null else $guard end),recovery_unit_enabled:($recovery==1),recovery_unit_managed:($recovery_managed==1),recovery_qdisc_unit_enabled:($recovery_qdisc==1),recovery_qdisc_unit_managed:($recovery_qdisc_managed==1),recovery_source_run:(if $source=="" then null else $source end),recovery_binding:$binding,owned_files:{sysctl:($sysctl==1),modules_load:($modules==1)},warnings:(if $warning=="" then [] else [$warning] end)}'
    else
        printf '当前 run: %s\n事务状态: %s\n事务链有效: %s\n状态格式: %s\nowned sysctl: %s\nowned modules-load: %s\n启动恢复单元: enabled=%s managed=%s；qdisc 恢复单元: enabled=%s managed=%s\n恢复绑定: source=%s state=%s\n' \
            "${run_id:-none}" "$status" "$chain_ok" "$state_format" "$owned_sysctl" "$owned_modules" "$recovery" "$recovery_managed" "$recovery_qdisc" "$recovery_qdisc_managed" "${recovery_source_run:-none}" "$recovery_binding"
        [[ -z "$guard_unit" ]] || printf '回滚守卫: %s\n' "$guard_unit"
        [[ -z "$warning_text" ]] || warn "$warning_text"
        printf '审计历史: %s\n' "$STATE_DIR/runs"
    fi
}

current_authenticated_chain_head() {
    local current record
    [[ -f "$STATE_DIR/current_run" && ! -L "$STATE_DIR/current_run" ]] || return 1
    secure_private_path "$STATE_DIR/current_run" || return 1
    record=$(state_hash_file current_run) || return 1
    state_hash_pair_is_valid "$STATE_DIR/current_run" "$record" || return 1
    current=$(cat "$STATE_DIR/current_run") || return 1
    validate_run_id "$current" || return 1
    # The helper is deliberately anchored at the authenticated pointer.  A
    # directory that happens to contain the same value is not ownership proof;
    # validate_transaction_chain also rejects unreachable committed records and
    # all incomplete records outside the current chain.
    validate_transaction_chain || return 1
    printf '%s\n' "$current"
}

capture_current_chain_proof() {
    local head transaction status previous snapshot_hash count=0
    BASELINE_OWNERSHIP_PROOF=()
    [[ -f "$STATE_DIR/current_run" && ! -L "$STATE_DIR/current_run" ]] || return 1
    head=$(current_authenticated_chain_head) || return 1
    while [[ -n "$head" ]]; do
        transaction="$STATE_DIR/transactions/$head"
        transaction_snapshot_is_valid "$transaction" || return 1
        status=$(cat "$transaction/status" 2>/dev/null || true)
        if (( count == 0 )); then
            [[ "$status" == committed || "$status" == pending-confirm ]] || return 1
        else
            [[ "$status" == committed ]] || return 1
        fi
        snapshot_hash=$(sha256sum "$transaction/snapshot.sha256" 2>/dev/null | awk '{print $1}') || return 1
        [[ "$snapshot_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
        BASELINE_OWNERSHIP_PROOF+=("$head${TAB}$status${TAB}$snapshot_hash")
        previous=$(transaction_get "$transaction" PREVIOUS_RUN 2>/dev/null || true)
        [[ -z "$previous" ]] || validate_run_id "$previous" || return 1
        head="$previous"
        count=$((count + 1))
        (( count <= 256 )) || return 1
    done
    (( ${#BASELINE_OWNERSHIP_PROOF[@]} > 0 ))
}

verify_captured_chain_rolled_back() {
    local entry proof_run proof_status proof_hash extra transaction status actual_hash
    (( ${#BASELINE_OWNERSHIP_PROOF[@]} > 0 )) || return 1
    for entry in "${BASELINE_OWNERSHIP_PROOF[@]}"; do
        IFS=$'\t' read -r proof_run proof_status proof_hash extra <<< "$entry"
        [[ -z "${extra:-}" && "$proof_run" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$ &&
           "$proof_status" =~ ^(committed|pending-confirm)$ && "$proof_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
        transaction="$STATE_DIR/transactions/$proof_run"
        transaction_snapshot_is_valid "$transaction" || return 1
        status=$(cat "$transaction/status" 2>/dev/null || true)
        [[ "$status" == rolled-back ]] || return 1
        actual_hash=$(sha256sum "$transaction/snapshot.sha256" 2>/dev/null | awk '{print $1}') || return 1
        [[ "$actual_hash" == "$proof_hash" ]] || return 1
    done
}

collect_baseline_authorized_transactions() {
    local head transaction status previous count=0
    BASELINE_AUTHORIZED_TRANSACTIONS=()
    # Only a live, authenticated current_run chain can authorize an owned
    # runtime value.  A captured pre-uninstall proof is used to authenticate
    # that the LIFO rollback sequence was started from a valid chain, but a
    # rolled-back historical transaction is never an authorization source.
    [[ -f "$STATE_DIR/current_run" && ! -L "$STATE_DIR/current_run" ]] || return 1
    head=$(current_authenticated_chain_head) || return 1
    while [[ -n "$head" ]]; do
        transaction="$STATE_DIR/transactions/$head"
        transaction_snapshot_is_valid "$transaction" || return 1
        status=$(cat "$transaction/status" 2>/dev/null || true)
        if (( count == 0 )); then
            [[ "$status" == committed || "$status" == pending-confirm ]] || return 1
        else
            [[ "$status" == committed ]] || return 1
        fi
        BASELINE_AUTHORIZED_TRANSACTIONS+=("$head")
        previous=$(transaction_get "$transaction" PREVIOUS_RUN 2>/dev/null || true)
        [[ -z "$previous" ]] || validate_run_id "$previous" || return 1
        head="$previous"
        count=$((count + 1))
        (( count <= 256 )) || return 1
    done
    (( ${#BASELINE_AUTHORIZED_TRANSACTIONS[@]} > 0 ))
}

baseline_runtime_value_is_owned() {
    local key="$1" current="$2" transaction status desired_key desired_value desired_before desired_reason desired_change_type extra head current_head
    is_target_sysctl_key "$key" || return 1
    [[ -n "$current" ]] || return 1
    # Once uninstall has rolled the authenticated chain back, current_run is
    # intentionally absent.  Matching a value from a rolled-back transaction
    # is not proof of current ownership: an administrator may have recreated
    # that historical value after the rollback.  In that state only an exact
    # baseline match is a no-op; any drift must stop uninstall.
    [[ -f "$STATE_DIR/current_run" && ! -L "$STATE_DIR/current_run" ]] || return 1
    current_head=$(cat "$STATE_DIR/current_run") || return 1
    collect_baseline_authorized_transactions || return 1
    for head in "${BASELINE_AUTHORIZED_TRANSACTIONS[@]}"; do
        transaction="$STATE_DIR/transactions/$head"
        status=$(cat "$transaction/status" 2>/dev/null || true)
        if [[ "$head" == "$current_head" ]]; then
            [[ "$status" == committed || "$status" == pending-confirm ]] || return 1
        else
            [[ "$status" == committed ]] || return 1
        fi
        while IFS=$'\t' read -r desired_key desired_value desired_before desired_reason desired_change_type extra || [[ -n "${desired_key:-}" ]]; do
            [[ -z "${extra:-}" && -n "$desired_key" && -n "$desired_value" &&
               -n "$desired_before" && -n "$desired_reason" ]] || return 1
            plan_change_type "$desired_change_type" >/dev/null || return 1
            if [[ "$desired_key" == "$key" ]]; then
                # The newest reachable transaction is authoritative.  Do not
                # fall through to an older record when an administrator has
                # changed the value after that transaction.  A persist-only
                # entry did not change runtime state, so it cannot authorize
                # overwriting an administrator value during baseline restore.
                [[ "${desired_change_type:-runtime_change}" == runtime_change &&
                   "$desired_value" == "$current" ]] && return 0
                return 1
            fi
        done < "$transaction/desired.tsv"
    done
    return 1
}

baseline_qdisc_value_is_owned() {
    local iface="$1" current_hash="$2" transaction status changed transaction_iface transaction_after_hash head current_head
    [[ "$iface" =~ ^[A-Za-z0-9_.:-]{1,15}$ && "$current_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
    # See baseline_runtime_value_is_owned: a rolled-back historical qdisc hash
    # is not ownership evidence after current_run has been removed.
    [[ -f "$STATE_DIR/current_run" && ! -L "$STATE_DIR/current_run" ]] || return 1
    current_head=$(cat "$STATE_DIR/current_run") || return 1
    collect_baseline_authorized_transactions || return 1
    for head in "${BASELINE_AUTHORIZED_TRANSACTIONS[@]}"; do
        transaction="$STATE_DIR/transactions/$head"
        status=$(cat "$transaction/status" 2>/dev/null || true)
        if [[ "$head" == "$current_head" ]]; then
            [[ "$status" == committed || "$status" == pending-confirm ]] || return 1
        else
            [[ "$status" == committed ]] || return 1
        fi
        changed=$(transaction_get "$transaction" QDISC_CHANGED 2>/dev/null || printf 0)
        transaction_iface=$(transaction_get "$transaction" QDISC_IFACE 2>/dev/null || true)
        transaction_after_hash=$(transaction_get "$transaction" QDISC_AFTER_HASH 2>/dev/null || true)
        if [[ "$changed" == 1 && "$transaction_iface" == "$iface" ]]; then
            # As with sysctl, an authenticated reachable transaction that
            # touched this interface is the newest authority.  A matching
            # hash proves ownership; a different hash proves administrator
            # drift and must not be authorized by an older historical run.
            [[ "$transaction_after_hash" == "$current_hash" ]] && return 0
            return 1
        fi
    done
    return 1
}

restore_initial_baseline() {
    local initial="$STATE_DIR/baseline/initial" uid mode key value current iface kind expected_hash actual_hash actual_kind restore_spec extra rc=0
    [[ -d "$initial" && ! -L "$initial" && -r "$initial/runtime.tsv" && -r "$initial/qdisc.tsv" ]] || return 1
    uid=$(stat -c %u "$initial" 2>/dev/null || true)
    mode=$(stat -c %a "$initial" 2>/dev/null || true)
    [[ "$uid" == 0 && "$mode" == 700 ]] || return 1
    verify_hash_manifest "$initial" "$initial/manifest.sha256" || {
        warn '首次 baseline manifest 校验失败；拒绝恢复。'; return 1;
    }
    if [[ -f "$initial/metadata" && ! -L "$initial/metadata" ]] && managed_file_has_current_metadata "$initial/metadata"; then
        baseline_identity_is_current "$initial" || {
            warn '首次 baseline identity 校验失败；拒绝恢复。'; return 1;
        }
    fi
    # cmd_uninstall captures the authenticated current chain before it starts
    # LIFO rollback.  Validate that proof after the pointer is removed, but do
    # not use any rolled-back transaction as ownership evidence for a drifted
    # runtime value.
    if [[ ! -e "$STATE_DIR/current_run" && ! -L "$STATE_DIR/current_run" &&
          ${#BASELINE_OWNERSHIP_PROOF[@]} -gt 0 ]]; then
        verify_captured_chain_rolled_back || {
            warn '卸载前捕获的 current_run 链未能证明已完整回滚；拒绝恢复 baseline。'; return 1;
        }
    fi
    # Preflight every baseline item before changing any of them.  A value that
    # is already the baseline is a safe no-op; a different value is accepted
    # only when an authenticated terminal transaction proves that it was the
    # value written by this tool.  Unknown administrator drift remains a hard
    # stop, so an earlier entry cannot be restored while a later entry is still
    # unverified.
    while IFS=$'\t' read -r key value extra || [[ -n "${key:-}" ]]; do
        [[ -n "$key" && -n "$value" && -z "${extra:-}" ]] || { rc=1; continue; }
        is_target_sysctl_key "$key" || { rc=1; continue; }
        current=$(sysctl_read "$key" 2>/dev/null || true)
        [[ "$current" == "$value" ]] && continue
        if ! baseline_runtime_value_is_owned "$key" "$current"; then
            warn "baseline sysctl 漂移，拒绝覆盖管理员值: $key"
            rc=1
        fi
    done < "$initial/runtime.tsv"
    while IFS=$'\t' read -r iface kind expected_hash restore_spec extra || [[ -n "${iface:-}" ]]; do
        if [[ "$iface" =~ ^[A-Za-z0-9_.:-]{1,15}$ && "$kind" =~ ^[A-Za-z0-9_-]+$ &&
              -z "${expected_hash:-}" && -z "${restore_spec:-}" && -z "${extra:-}" ]]; then
            # v1 baselines stored only the qdisc kind.  They remain readable
            # for a controlled, read-only uninstall check; without an exact
            # replay specification they cannot authorize a qdisc mutation.
            actual_kind=$(interface_qdisc_kind "$iface" 2>/dev/null || true)
            [[ "$actual_kind" == "$kind" ]] || {
                warn "legacy baseline qdisc 类型漂移，拒绝覆盖管理员配置: $iface"; rc=1;
            }
            continue
        fi
        [[ "$iface" =~ ^[A-Za-z0-9_.:-]{1,15}$ && "$kind" =~ ^[A-Za-z0-9_-]+$ &&
           "$expected_hash" =~ ^[0-9a-f]{64}$ && -z "${extra:-}" ]] || { rc=1; continue; }
        actual_hash=$(qdisc_root_fingerprint "$iface" 2>/dev/null || true)
        [[ "$actual_hash" == "$expected_hash" ]] && continue
        if ! baseline_qdisc_value_is_owned "$iface" "$actual_hash"; then
            warn "baseline qdisc 已发生未认证漂移，拒绝覆盖管理员配置: $iface"
            rc=1
            continue
        fi
        if [[ "$restore_spec" == - ]] || ! qdisc_spec_is_safe "$restore_spec"; then
            warn "baseline qdisc 缺少安全 replay spec，拒绝恢复: $iface"; rc=1;
        fi
    done < "$initial/qdisc.tsv"
    (( rc == 0 )) || return 1

    # Recheck immediately before each write to close the interval between the
    # read-only preflight and the actual restore.  The caller holds the global
    # tool lock, but an administrator can still change sysctl/qdisc out of band.
    while IFS=$'\t' read -r key value extra || [[ -n "${key:-}" ]]; do
        [[ -n "$key" && -n "$value" && -z "${extra:-}" ]] || { rc=1; continue; }
        current=$(sysctl_read "$key" 2>/dev/null || true)
        [[ "$current" == "$value" ]] && continue
        baseline_runtime_value_is_owned "$key" "$current" || { warn "baseline sysctl 在恢复前发生漂移: $key"; rc=1; continue; }
        if ! sysctl -q -w "$key=$value" >/dev/null 2>&1 || [[ "$(sysctl_read "$key" 2>/dev/null || true)" != "$value" ]]; then
            warn "baseline sysctl 无法恢复: $key"
            rc=1
        fi
    done < "$initial/runtime.tsv"
    while IFS=$'\t' read -r iface kind expected_hash restore_spec extra || [[ -n "${iface:-}" ]]; do
        [[ "$expected_hash" =~ ^[0-9a-f]{64}$ && "$restore_spec" != - ]] || continue
        actual_hash=$(qdisc_root_fingerprint "$iface" 2>/dev/null || true)
        [[ "$actual_hash" == "$expected_hash" ]] && continue
        baseline_qdisc_value_is_owned "$iface" "$actual_hash" || { warn "baseline qdisc 在恢复前发生漂移: $iface"; rc=1; continue; }
        if [[ "$restore_spec" == - ]] || ! qdisc_spec_is_safe "$restore_spec"; then
            warn "baseline qdisc replay spec 在恢复前发生变化: $iface"; rc=1; continue;
        fi
        if ! qdisc_replace_from_spec "$iface" "$restore_spec" >/dev/null 2>&1 ||
           [[ "$(qdisc_root_fingerprint "$iface" 2>/dev/null || true)" != "$expected_hash" ]]; then
            warn "baseline qdisc 无法恢复: $iface"
            rc=1
        fi
    done < "$initial/qdisc.tsv"
    return "$rc"
}

cmd_uninstall() {
    local arg assume_yes=0 answer run_id current_record failures=0
    JSON_OUTPUT=0; DRY_RUN=0; JSON_ERROR_EMITTED=0
    BASELINE_OWNERSHIP_PROOF=()
    while (($#)); do
        arg=$1; shift
        case "$arg" in --yes) assume_yes=1 ;; --json) JSON_OUTPUT=1 ;; --dry-run) DRY_RUN=1 ;; *) die "uninstall 不支持参数: $arg"; return 1 ;; esac
    done
    require_root || return 1; require_real_apply_roots || return 1; ensure_secure_state || return 1
    if (( DRY_RUN )); then
        if (( JSON_OUTPUT )); then json_operation_result ok uninstall_preview "" dry-run
        else printf 'dry-run：将按 LIFO 回滚所有当前事务、校验首次 baseline，并删除 owned 配置；审计历史保留。\n'; fi
        return 0
    fi
    require_recovery_commands || return 1
    acquire_lock 30 || return 1
    validate_transaction_chain || {
        die '事务链含未完成、链外或损坏记录；卸载停止，请先执行 recover/rollback。'; return 40;
    }
    if (( assume_yes == 0 )); then
        [[ -t 0 ]] || { die '非交互卸载必须提供 --yes。'; return 1; }
        printf '输入 UNINSTALL 确认按 LIFO 回滚并校验首次 baseline: ' >&2; IFS= read -r answer
        [[ "$answer" == UNINSTALL ]] || { die '用户取消。'; return 1; }
    fi
    if [[ -r "$STATE_DIR/current_run" ]] && ! capture_current_chain_proof; then
        warn '无法建立当前 authenticated current_run 链的 baseline 所有权证明；卸载停止并保留管理员值。'
        failures=1
    fi
    while (( failures == 0 )) && [[ -r "$STATE_DIR/current_run" ]]; do
        run_id=$(cat "$STATE_DIR/current_run")
        validate_run_id "$run_id" || { failures=1; break; }
        restore_transaction "$STATE_DIR/transactions/$run_id" || { failures=1; break; }
        cancel_rollback_guard "$STATE_DIR/transactions/$run_id" || { failures=1; break; }
    done
    if (( failures != 0 )); then
        warn '事务链回滚未完成；卸载停止，current_run 与 owned 文件均保留以便重试。'
    elif [[ -e "$STATE_DIR/baseline/initial" || -L "$STATE_DIR/baseline/initial" ]] && ! restore_initial_baseline; then
        failures=1
    elif [[ -e "$SYSCTL_FILE" || -L "$SYSCTL_FILE" || -e "$MODULES_FILE" || -L "$MODULES_FILE" ]]; then
        warn 'LIFO 回滚后仍存在 owned 主配置；为避免误删，卸载停止。'
        failures=1
    elif ! validate_service_registry || [[ -s "$STATE_DIR/owned-services.tsv" ]]; then
        warn 'LIFO 回滚后服务所有权 registry 非空或损坏；卸载停止。'
        failures=1
    elif [[ -e "$RECOVERY_UNIT_PATH" || -L "$RECOVERY_UNIT_PATH" ||
            -e "$RECOVERY_QDISC_UNIT_PATH" || -L "$RECOVERY_QDISC_UNIT_PATH" ||
            -e "$RECOVERY_SCRIPT_PATH" || -L "$RECOVERY_SCRIPT_PATH" ||
            -e "$(recovery_qdisc_online_wants_path)" || -L "$(recovery_qdisc_online_wants_path)" ||
            -e "$(recovery_qdisc_multi_wants_path)" || -L "$(recovery_qdisc_multi_wants_path)" ]]; then
        if ! recovery_artifacts_are_valid || ! command_exists systemctl; then
            warn '启动恢复单元或恢复脚本所有权校验失败；卸载停止。'
            failures=1
        else
            if [[ -e "$RECOVERY_UNIT_PATH" || -L "$RECOVERY_UNIT_PATH" ]] &&
               ! systemctl disable vps-proxy-tune-recover.service >/dev/null 2>&1; then
                failures=1
            fi
            if [[ -e "$RECOVERY_QDISC_UNIT_PATH" || -L "$RECOVERY_QDISC_UNIT_PATH" ]] &&
               ! systemctl disable vps-proxy-tune-recover-qdisc.service >/dev/null 2>&1; then
                failures=1
            fi
            # Releases before the consumer-style qdisc unit could leave an
            # extra link under network-online.target.wants.  It is outside the
            # current [Install] section, so systemctl disable cannot remove it;
            # remove it only after re-authenticating that it points to our unit.
            if (( failures == 0 )) &&
               ! remove_managed_recovery_wants_link "$(recovery_qdisc_online_wants_path)" "$RECOVERY_QDISC_UNIT_PATH"; then
                failures=1
            fi
            if (( failures == 0 )) &&
               ! remove_managed_recovery_wants_link "$(recovery_qdisc_multi_wants_path)" "$RECOVERY_QDISC_UNIT_PATH"; then
                failures=1
            fi
            if (( failures == 0 )) &&
               ! rm -f -- "$RECOVERY_UNIT_PATH" "$RECOVERY_QDISC_UNIT_PATH" \
                    "$RECOVERY_UNIT_HASH_FILE" "$RECOVERY_QDISC_UNIT_HASH_FILE" \
                    "$RECOVERY_SCRIPT_PATH" "$RECOVERY_SCRIPT_HASH_FILE"; then
                failures=1
            fi
            if (( failures == 0 )) && ! systemctl daemon-reload >/dev/null 2>&1; then failures=1; fi
            if (( failures != 0 )); then
                warn '启动恢复单元未能安全移除；卸载停止。'
            fi
        fi
    fi
    if (( failures == 0 )); then
        current_record=$(state_hash_file current_run) || failures=1
        if (( failures == 0 )) && [[ -e "$STATE_DIR/current_run" || -L "$STATE_DIR/current_run" ||
            -e "$current_record" || -L "$current_record" ]]; then
            state_hash_pair_is_valid "$STATE_DIR/current_run" "$current_record" || failures=1
            if (( failures == 0 )); then
                rm -f -- "$STATE_DIR/current_run" "$current_record" || failures=1
            fi
        fi
    fi
    if (( failures == 0 )); then
        if ! write_uninstalled_at; then
            failures=1
        fi
    fi
    if (( JSON_OUTPUT )); then
        jq -n --arg schema "$SCHEMA_VERSION" --argjson failed "$failures" \
            '{schema_version:$schema,run_id:null,outcome:(if $failed==1 then "rollback_failed" else "ok" end),reason_code:(if $failed==1 then "recovery_pending" else "uninstalled" end),environment:{},path:{},metrics:{},quality:"not-measured",confidence:"not-measured",recommendations:{},changes:[],warnings:(if $failed==1 then ["one or more baseline items failed"] else [] end),rollback_status:(if $failed==1 then "partial" else "uninstalled" end)}'
        JSON_ERROR_EMITTED=1
    else
        if (( failures == 0 )); then printf '卸载完成：事务变更已按 LIFO 恢复并校验首次 baseline，审计历史保留在 %s。\n' "$STATE_DIR"; else warn '卸载仅部分完成，请检查 verify/status。'; fi
    fi
    (( failures == 0 ))
}

auto_preview_cleanup() {
    local directory="${1:-}" saved_state="${2:-}" saved_run="${3:-}" saved_lock="${4:-}"
    STATE_DIR=$saved_state
    RUN_ROOT=$saved_run
    LOCK_FILE=$saved_lock
    LOCK_HELD_PATH=""
    if [[ -n "$directory" ]]; then
        case "$directory" in
            /tmp/vps-proxy-tune-auto.*) rm -rf -- "$directory" ;;
            *) return 1 ;;
        esac
    fi
}

AUTO_PREVIEW_DIR=""
AUTO_PREVIEW_SAVED_STATE=""
AUTO_PREVIEW_SAVED_RUN=""
AUTO_PREVIEW_SAVED_LOCK=""

auto_preview_exit_cleanup() {
    local saved_status=$?
    trap - EXIT INT TERM HUP
    if [[ -n "$AUTO_PREVIEW_DIR" ]]; then
        auto_preview_cleanup "$AUTO_PREVIEW_DIR" "$AUTO_PREVIEW_SAVED_STATE" \
            "$AUTO_PREVIEW_SAVED_RUN" "$AUTO_PREVIEW_SAVED_LOCK" || true
    fi
    AUTO_PREVIEW_DIR=""
    return "$saved_status"
}

auto_preview_dispose() {
    auto_preview_exit_cleanup
}

cmd_auto() {
    local -a measure_args=() apply_args=()
    local mode=safe service="" assume_yes=0 dry=0 json=0 install_deps=0 arg value
    local measure_json plan_json run_id confidence retrans_known block_reason auto_preview_dir=""
    local saved_state="$STATE_DIR" saved_run="$RUN_ROOT" saved_lock="$LOCK_FILE" result
    AUTO_PREVIEW_DIR=""; AUTO_PREVIEW_SAVED_STATE=""; AUTO_PREVIEW_SAVED_RUN=""; AUTO_PREVIEW_SAVED_LOCK=""
    while (($#)); do
        arg=$1; shift
        case "$arg" in
            --peer|--family|--budget-mib|--profile)
                (($#)) || { die "$arg 缺少值"; return 1; }; value=$1; shift; measure_args+=("$arg" "$value") ;;
            --peer=*|--family=*|--budget-mib=*|--profile=*) measure_args+=("$arg") ;;
            --mode) (($#)) || { die '--mode 缺少值'; return 1; }; mode=$1; shift ;;
            --mode=*) mode=${arg#*=} ;;
            --service) (($#)) || { die '--service 缺少值'; return 1; }; service=$1; shift ;;
            --service=*) service=${arg#*=} ;;
            --yes) assume_yes=1 ;;
            --dry-run) dry=1 ;;
            --json) json=1 ;;
            --install-deps) install_deps=1 ;;
            *) die "auto 不支持参数: $arg"; return 1 ;;
        esac
    done
    (( dry == 0 || install_deps == 0 )) || { die '--dry-run 与 --install-deps 不能同时使用。'; return 1; }
    [[ "$mode" == safe || "$mode" == fresh ]] || { die '--mode 只能是 safe 或 fresh。'; return 1; }
    if [[ -n "$service" ]] && ! validate_unit "$service"; then die '无效的 --service。'; return 1; fi
    (( install_deps == 0 )) || measure_args+=(--install-deps)
    if (( dry )); then
        trusted_tmp_dir || { die '/tmp 不是可信的 root-owned 目录。'; return 1; }
        auto_preview_dir=$(mktemp -d /tmp/vps-proxy-tune-auto.XXXXXXXX) || return 1
        AUTO_PREVIEW_DIR="$auto_preview_dir"
        AUTO_PREVIEW_SAVED_STATE="$saved_state"
        AUTO_PREVIEW_SAVED_RUN="$saved_run"
        AUTO_PREVIEW_SAVED_LOCK="$saved_lock"
        trap auto_preview_exit_cleanup EXIT
        trap 'exit 130' INT TERM HUP
        if ! chmod 0700 "$auto_preview_dir" ||
           ! install -d -m 0700 "$auto_preview_dir/state" "$auto_preview_dir/run"; then
            auto_preview_dispose || true
            return 1
        fi
        STATE_DIR="$auto_preview_dir/state"
        RUN_ROOT="$auto_preview_dir/run"
        LOCK_FILE="$RUN_ROOT/lock/vps-proxy-tune/lock"
    fi
    collect_audit
    if (( json == 0 )); then print_audit_human; fi
    if ! measure_json=$(cmd_measure "${measure_args[@]}" --json); then
        if (( dry )); then auto_preview_dispose || true; fi
        return 1
    fi
    if ! run_id=$(jq -er '.run_id' <<< "$measure_json"); then
        if (( dry )); then auto_preview_dispose || true; fi
        die 'auto 测量未返回可用 run_id。'; return 1
    fi
    if ! plan_json=$(cmd_plan --run "$run_id" --json); then
        if (( dry )); then auto_preview_dispose || true; fi
        return 1
    fi
    confidence=$(jq -r '.confidence' <<< "$plan_json") || {
        if (( dry )); then auto_preview_dispose || true; fi
        return 1
    }
    retrans_known=$(jq -r '.metrics.retransmits_known // false' <<< "$plan_json") || {
        if (( dry )); then auto_preview_dispose || true; fi
        return 1
    }
    if (( json == 0 )); then
        jq -r '"auto 计划: run_id=\(.run_id) quality=\(.quality) confidence=\(.confidence)", (.recommendations|to_entries[]?|"  \(.key) = \(.value)"), (.warnings[]?|"[WARN] \(.)")' <<< "$plan_json"
    fi
    block_reason=measurement_confidence_low
    if [[ "$retrans_known" != true ]]; then
        block_reason=retransmission_counter_unavailable
    fi
    if [[ "$confidence" != high || "$retrans_known" != true ]]; then
        warn 'auto 因置信度不足停止，保证零系统变更。'
        [[ "$retrans_known" == true ]] || warn 'auto 因 TCP 重传计数不可证明停止，保证零系统变更。'
        if (( json )); then
            jq --arg reason "$block_reason" '.outcome="blocked" | .reason_code=$reason | .rollback_status="blocked"' <<< "$plan_json"
            JSON_ERROR_EMITTED=1
        fi
        result=10
        if (( dry )); then auto_preview_dispose || true; fi
        return "$result"
    fi
    apply_args=(--run "$run_id" --mode "$mode")
    [[ -z "$service" ]] || apply_args+=(--service "$service")
    if (( dry )); then
        apply_args+=(--dry-run)
        (( json == 0 )) || apply_args+=(--json)
        cmd_apply "${apply_args[@]}"; result=$?
        auto_preview_dispose || true
        return "$result"
    fi
    (( assume_yes == 0 )) || apply_args+=(--yes)
    (( json == 0 )) || apply_args+=(--json)
    cmd_apply "${apply_args[@]}"
}

print_usage() {
    cat <<'USAGE'
vps-proxy-tune v2.1.2 — 日本/美国代理 VPS 自适应网络调优

用法:
  vps-proxy-tune.sh audit [--json] [--dry-run] [--install-deps]
  vps-proxy-tune.sh measure --peer HOST[:PORT] [--peer HOST[:PORT] ...]
                            [--family auto|4|6] [--profile tcp|mixed] [--budget-mib MiB] [--json]
                            [--dry-run] [--install-deps]
  vps-proxy-tune.sh plan --run RUN_ID [--json] [--dry-run] [--install-deps]
  vps-proxy-tune.sh apply --run RUN_ID [--mode safe|fresh]
                          [--service UNIT] [--yes] [--dry-run] [--json]
                          [--install-deps]
  vps-proxy-tune.sh auto --peer HOST[:PORT] [--peer ...]
                         [--family auto|4|6] [--profile tcp|mixed] [--budget-mib MiB]
                         [--mode safe|fresh] [--service UNIT]
                         [--yes] [--dry-run] [--json] [--install-deps]
  vps-proxy-tune.sh verify [--scope config|path|all] [--json]
  vps-proxy-tune.sh deps check|install [--phase common|audit|measure|apply|recovery|all]
                              [--dry-run] [--yes] [--json]
  vps-proxy-tune.sh status [--json]
  vps-proxy-tune.sh history list [--limit N] [--json]
  vps-proxy-tune.sh history prune --keep N [--yes|--dry-run] [--json]
  vps-proxy-tune.sh rollback [--run RUN_ID] [--dry-run] [--json]
  vps-proxy-tune.sh confirm --run RUN_ID [--json]
  vps-proxy-tune.sh recover [--run RUN_ID] [--boot] [--phase all|config|qdisc] [--json]
  vps-proxy-tune.sh uninstall [--yes] [--dry-run] [--json]

说明:
  measure 的主动请求只发送到用户给出的 iperf3 peer；默认总预算 1024 MiB，最大 4096 MiB。
  profile=mixed 会额外测量双向 UDP（作为 QUIC/UDP 用户态代理的路径近似）；UDP 失败会降低置信度。
  apply 默认 safe，不实时替换 root qdisc；应用后必须显式 confirm，超时由 systemd 守卫自动回滚。
  tcp_mtu_probing 没有黑洞证据时保持原值；fresh qdisc 仅接受 RX/TX 均为单队列的白名单接口。
  apply --dry-run 只检查预览所需依赖，不要求网络测量工具，也不创建 current_run 或事务。
  启动恢复分为配置/sysctl 阶段和 network-online 后的 qdisc 阶段；恢复脚本使用哈希绑定快照。
  只有 confidence=high 且 TCP 重传计数可证明时才允许任何 apply；否则始终零变更。
USAGE
}

main() {
    local command="${1:-help}" rc=0 arg json_requested=0
    # Preserve the JSON contract even when argument parsing fails before a
    # subcommand reaches its normal --json branch (for example, --bad --json).
    for arg in "$@"; do
        [[ "$arg" == --json ]] && json_requested=1
    done
    if (( json_requested )); then JSON_OUTPUT=1; fi
    if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
        die "需要 Bash 4.4+（当前 $BASH_VERSION）。" || true
        return 1
    fi
    (($# == 0)) || shift
    case "$command" in
        audit) cmd_audit "$@" || rc=$? ;;
        measure) cmd_measure "$@" || rc=$? ;;
        plan) cmd_plan "$@" || rc=$? ;;
        apply) cmd_apply "$@" || rc=$? ;;
        auto) cmd_auto "$@" || rc=$? ;;
        deps) cmd_deps "$@" || rc=$? ;;
        confirm) cmd_confirm "$@" || rc=$? ;;
        recover) cmd_recover "$@" || rc=$? ;;
        verify) cmd_verify "$@" || rc=$? ;;
        status) cmd_status "$@" || rc=$? ;;
        history) cmd_history "$@" || rc=$? ;;
        rollback) cmd_rollback "$@" || rc=$? ;;
        uninstall) cmd_uninstall "$@" || rc=$? ;;
        _guard-rollback) cmd_guard_rollback "$@" || rc=$? ;;
        _boot-recover) cmd_recover --boot "$@" || rc=$? ;;
        help|-h|--help) print_usage ;;
        version|-V|--version) printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION" ;;
        *)
            die "未知命令: $command" || true
            print_usage >&2
            rc=1
            ;;
    esac
    if (( json_requested )); then JSON_OUTPUT=1; fi
    if (( rc != 0 && rc != 20 && JSON_OUTPUT && JSON_ERROR_EMITTED == 0 )); then
        emit_json_error "${REASON_CODE:-operation_failed}"
    fi
    return "$rc"
}

if [[ "${VPS_TUNE_LIB_ONLY:-0}" != 1 ]]; then
    main "$@"
fi
