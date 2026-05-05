#!/usr/bin/env bash
# SPDX-License-Identifier: UPL-1.0
#
# migrate-to-oracle-linux.sh - migrate EL-compatible systems to Oracle Linux.
#
# Supported sources:
#   CentOS Linux 7.9
#   CentOS Linux 8.4+
#   CentOS Stream 8, 9, 10
#   AlmaLinux 8, 9, 10
#   Amazon Linux 2 (exception path to Oracle Linux 7 latest)
#   Red Hat Enterprise Linux 7.9
#   Red Hat Enterprise Linux 8, 9, 10
#   Rocky Linux 8, 9, 10
# Supported architectures:
#   x86_64, aarch64
#
# The script preserves installed package EVRAs whenever Oracle Linux publishes
# the exact same NEVRA. On RHEL sources, exact reinstall is attempted for every
# installed RPM by default.

set -Eeuo pipefail

PROGRAM_NAME="$(basename "$0")"
readonly PROGRAM_NAME
readonly SCRIPT_VERSION="0.2.1"
readonly STATE_ROOT="/var/lib/migrate-to-oracle-linux"
readonly LOG_ROOT="/var/log/migrate-to-oracle-linux"
readonly DEFAULT_ORACLE_YUM_BASE="https://yum.oracle.com"

ASSUME_YES=0
DRY_RUN=0
STRICT_EVR=0
REINSTALL_ALL="auto"
NO_REBOOT_CHECK=0
KEEP_BOOTSTRAP_REPOS=0
DEBUG=0
KERNEL_FLAVOR="uek"
KERNEL_FLAVOR_REQUESTED=0
TARGET_VERSION=""
EFFECTIVE_TARGET_VERSION=""
MIGRATION_MODE=""
MIGRATION_START_EPOCH=""
ORACLE_YUM_BASE="$DEFAULT_ORACLE_YUM_BASE"
YUM_MIRROR_REQUESTED=0
PROXY_URL=""

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
STATE_DIR="${STATE_ROOT}/${RUN_ID}"
LOG_FILE="${LOG_ROOT}/${RUN_ID}.log"

SOURCE_ID=""
SOURCE_NAME=""
SOURCE_VERSION_ID=""
SOURCE_PRETTY_NAME=""
SOURCE_MAJOR=""
SOURCE_MINOR=""
SOURCE_FAMILY=""
BASEARCH=""
DNF_CMD=""
DNF_BASE_ARGS=()
ORACLE_REPO_ARGS=()
ORACLE_TARGET_EXCLUDE_ARGS=()

usage() {
    cat <<EOF
Usage: ${PROGRAM_NAME} [options]

Migrate CentOS, CentOS Stream, AlmaLinux, Amazon Linux 2, RHEL, or Rocky Linux
to Oracle Linux. Major-version upgrades are not supported during migration. The
only cross-number exception is Amazon Linux 2, which targets Oracle Linux 7
latest because Amazon Linux 2 is EL7-compatible.

Options:
  -y, --assumeyes              Run dnf/yum operations non-interactively.
      --dry-run                Print commands and write reports without changing the system.
      --reinstall-all          Attempt exact reinstall for every installed RPM.
      --no-reinstall-all       Only exact reinstall packages from the source OS vendor.
      --target-version VERSION Lock Oracle Linux target to the same major VERSION, for example 8.6, or use "latest". EL7 and CentOS Stream only support "latest".
      --kernel FLAVOR          Select the Oracle Linux kernel flavor: uek or rhck. Defaults to uek.
      --yum-mirror URL         Use an Oracle Linux yum mirror origin, for example https://yum-mirror.example.com.
      --proxy URL              Use an HTTP proxy for yum/dnf access, for example http://myproxy.example.com:3128.
      --strict-evr             Stop when Oracle repos cannot provide exact NEVRAs.
      --no-strict-evr          Continue when exact NEVRAs are unavailable. This is the default.
      --no-reboot-check        Do not require booting into the newest installed kernel first.
      --keep-bootstrap-repos   Leave temporary Oracle bootstrap repo file in place.
      --debug                  Enable shell tracing.
  -h, --help                   Show this help.
  -V, --version                Show version.

Reports and snapshots are written below:
  ${STATE_ROOT}/<run-id>/
  ${LOG_ROOT}/<run-id>.log
EOF
}

log() {
    local level="$1"
    shift
    local line
    line="$(printf '[%s] %s: %s\n' "$(date -u +%FT%TZ)" "$level" "$*")"
    printf '%s\n' "$line" >&2
    if [[ -d "$LOG_ROOT" ]]; then
        printf '%s\n' "$line" >> "$LOG_FILE"
    fi
}

info() {
    log INFO "$@"
}

warn() {
    log WARN "$@"
}

die() {
    log ERROR "$@"
    exit 1
}

format_duration_hms() {
    local duration="$1"
    local hours minutes seconds

    if [[ ! "$duration" =~ ^[0-9]+$ ]]; then
        printf 'Not available\n'
        return
    fi

    hours=$((duration / 3600))
    minutes=$(((duration % 3600) / 60))
    seconds=$((duration % 60))
    printf '%02d:%02d:%02d\n' "$hours" "$minutes" "$seconds"
}

record_migration_start() {
    MIGRATION_START_EPOCH="$(date +%s)"
    printf '%s\n' "$MIGRATION_START_EPOCH" > "${STATE_DIR}/migration-start.epoch"
}

record_migration_end() {
    local end_epoch start_epoch duration

    end_epoch="$(date +%s)"
    printf '%s\n' "$end_epoch" > "${STATE_DIR}/migration-end.epoch"

    if [[ -s "${STATE_DIR}/migration-start.epoch" ]]; then
        start_epoch="$(<"${STATE_DIR}/migration-start.epoch")"
    else
        start_epoch="$MIGRATION_START_EPOCH"
    fi

    if [[ "$start_epoch" =~ ^[0-9]+$ && "$end_epoch" =~ ^[0-9]+$ && "$end_epoch" -ge "$start_epoch" ]]; then
        duration=$((end_epoch - start_epoch))
        printf '%s\n' "$duration" > "${STATE_DIR}/migration-duration.seconds"
    fi
}

migration_duration_hms() {
    local start_file="${STATE_DIR}/migration-start.epoch"
    local end_file="${STATE_DIR}/migration-end.epoch"
    local duration_file="${STATE_DIR}/migration-duration.seconds"
    local start_epoch end_epoch duration

    if [[ -s "$duration_file" ]]; then
        duration="$(<"$duration_file")"
        format_duration_hms "$duration"
        return
    fi

    if [[ ! -s "$start_file" ]]; then
        printf 'Not available\n'
        return
    fi

    start_epoch="$(<"$start_file")"
    if [[ -s "$end_file" ]]; then
        end_epoch="$(<"$end_file")"
    else
        end_epoch="$(date +%s)"
    fi

    if [[ "$start_epoch" =~ ^[0-9]+$ && "$end_epoch" =~ ^[0-9]+$ && "$end_epoch" -ge "$start_epoch" ]]; then
        duration=$((end_epoch - start_epoch))
        format_duration_hms "$duration"
    else
        printf 'Not available\n'
    fi
}

run() {
    info "+ $*"
    if (( DRY_RUN )); then
        return 0
    fi
    "$@" 2>&1 | tee -a "$LOG_FILE"
}

run_capture() {
    local outfile="$1"
    shift
    info "+ $* > ${outfile}"
    "$@" > "$outfile" 2>> "$LOG_FILE"
}

snapshot_enabled_repos() {
    local outfile="$1"

    if [[ "$SOURCE_MAJOR" == "7" ]]; then
        run_capture "$outfile" "$DNF_CMD" repolist enabled
    else
        run_capture "$outfile" "$DNF_CMD" repolist --enabled
    fi
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

normalize_yum_mirror_url() {
    local mirror="$1"

    mirror="${mirror%/}"
    [[ "$mirror" =~ ^https://[A-Za-z0-9._-]+(:[0-9]+)?$ ]] || \
        die "--yum-mirror must be an HTTPS origin only, for example https://yum-mirror.example.com"

    printf '%s\n' "$mirror"
}

normalize_proxy_url() {
    local proxy="$1"

    proxy="${proxy%/}"
    [[ "$proxy" =~ ^http://[A-Za-z0-9._-]+(:[0-9]+)?$ ]] || \
        die "--proxy must be an HTTP proxy URL, for example http://myproxy.example.com:3128"

    printf '%s\n' "$proxy"
}

target_label() {
    if [[ "$MIGRATION_MODE" == "latest-sync" ]]; then
        printf 'Oracle Linux %s latest\n' "$SOURCE_MAJOR"
    elif [[ -n "$EFFECTIVE_TARGET_VERSION" ]]; then
        printf 'Oracle Linux %s\n' "$EFFECTIVE_TARGET_VERSION"
    elif [[ -n "$TARGET_VERSION" ]]; then
        printf 'Oracle Linux %s\n' "$TARGET_VERSION"
    else
        printf 'Oracle Linux %s\n' "$SOURCE_MAJOR"
    fi
}

confirm() {
    if (( ASSUME_YES || DRY_RUN )); then
        return 0
    fi
    printf 'Proceed with migration to %s? [y/N] ' "$(target_label)" >&2
    read -r answer
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) die "aborted by user" ;;
    esac
}

parse_args() {
    while (($#)); do
        case "$1" in
            -y|--assumeyes)
                ASSUME_YES=1
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            --reinstall-all)
                REINSTALL_ALL=1
                ;;
            --no-reinstall-all)
                REINSTALL_ALL=0
                ;;
            --target-version)
                shift
                [[ $# -gt 0 ]] || die "--target-version requires a value"
                TARGET_VERSION="$1"
                ;;
            --kernel)
                shift
                [[ $# -gt 0 ]] || die "--kernel requires a value: uek or rhck"
                case "$1" in
                    uek|rhck)
                        KERNEL_FLAVOR="$1"
                        KERNEL_FLAVOR_REQUESTED=1
                        ;;
                    *)
                        die "--kernel must be either uek or rhck; got $1"
                        ;;
                esac
                ;;
            --uek)
                KERNEL_FLAVOR="uek"
                KERNEL_FLAVOR_REQUESTED=1
                ;;
            --rhck)
                KERNEL_FLAVOR="rhck"
                KERNEL_FLAVOR_REQUESTED=1
                ;;
            --yum-mirror)
                shift
                [[ $# -gt 0 ]] || die "--yum-mirror requires a value"
                ORACLE_YUM_BASE="$(normalize_yum_mirror_url "$1")"
                YUM_MIRROR_REQUESTED=1
                ;;
            --proxy)
                shift
                [[ $# -gt 0 ]] || die "--proxy requires a value"
                PROXY_URL="$(normalize_proxy_url "$1")"
                ;;
            --strict-evr)
                STRICT_EVR=1
                ;;
            --no-strict-evr)
                STRICT_EVR=0
                ;;
            --no-reboot-check)
                NO_REBOOT_CHECK=1
                ;;
            --keep-bootstrap-repos)
                KEEP_BOOTSTRAP_REPOS=1
                ;;
            --debug)
                DEBUG=1
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -V|--version)
                printf '%s %s\n' "$PROGRAM_NAME" "$SCRIPT_VERSION"
                exit 0
                ;;
            *)
                die "unknown option: $1"
                ;;
        esac
        shift
    done

    if (( DEBUG )); then
        set -x
    fi

    if (( YUM_MIRROR_REQUESTED )) && [[ -n "$PROXY_URL" ]]; then
        die "--proxy cannot be used together with --yum-mirror because the mirror is expected to be local"
    fi
}

load_os_release() {
    [[ -r /etc/os-release ]] || die "/etc/os-release is missing"
    # shellcheck disable=SC1091
    . /etc/os-release
    SOURCE_ID="${ID:-}"
    SOURCE_NAME="${NAME:-}"
    SOURCE_VERSION_ID="${VERSION_ID:-}"
    SOURCE_PRETTY_NAME="${PRETTY_NAME:-${NAME:-unknown}}"
    SOURCE_MAJOR="${SOURCE_VERSION_ID%%.*}"
    SOURCE_MINOR=""
    if [[ "$SOURCE_VERSION_ID" == *.* ]]; then
        SOURCE_MINOR="${SOURCE_VERSION_ID#*.}"
        SOURCE_MINOR="${SOURCE_MINOR%%.*}"
    fi

    [[ -n "$SOURCE_ID" ]] || die "unable to determine source distribution ID"
    [[ "$SOURCE_MAJOR" =~ ^[0-9]+$ ]] || die "unable to determine source major version from VERSION_ID=${SOURCE_VERSION_ID}"
}

detect_source() {
    load_os_release

    case "$SOURCE_ID" in
        centos)
            if [[ "$SOURCE_NAME" == *Stream* || "$SOURCE_PRETTY_NAME" == *Stream* ]]; then
                SOURCE_FAMILY="centos-stream"
            else
                SOURCE_FAMILY="centos-linux"
            fi
            ;;
        almalinux)
            SOURCE_FAMILY="almalinux"
            ;;
        amzn)
            SOURCE_FAMILY="amazon-linux"
            ;;
        rhel)
            SOURCE_FAMILY="rhel"
            ;;
        rocky)
            SOURCE_FAMILY="rocky"
            ;;
        ol|oracle)
            die "this system already appears to be Oracle Linux: ${SOURCE_PRETTY_NAME}"
            ;;
        *)
            die "unsupported source distribution ID=${SOURCE_ID} (${SOURCE_PRETTY_NAME})"
            ;;
    esac

    case "$SOURCE_FAMILY:$SOURCE_MAJOR" in
        centos-linux:7)
            if ! rpm -q centos-release --qf '%{VERSION} %{RELEASE}\n' 2>/dev/null | awk '$1 == "7" && $2 ~ /^9[.]/ { found = 1 } END { exit found ? 0 : 1 }'; then
                die "CentOS Linux 7 source must be CentOS Linux 7.9 to migrate to Oracle Linux 7 latest"
            fi
            ;;
        centos-linux:8)
            local minor="${SOURCE_MINOR:-0}"
            [[ "$minor" =~ ^[0-9]+$ ]] || die "CentOS Linux 8 VERSION_ID must include a numeric minor release"
            (( minor >= 4 )) || die "CentOS Linux ${SOURCE_VERSION_ID} is unsupported; use 8.4 or newer"
            ;;
        amazon-linux:2)
            SOURCE_MAJOR="7"
            SOURCE_MINOR=""
            ;;
        centos-stream:8|centos-stream:9|centos-stream:10|\
        almalinux:8|almalinux:9|almalinux:10|\
        rhel:7|\
        rhel:8|rhel:9|rhel:10|\
        rocky:8|rocky:9|rocky:10)
            ;;
        *)
            die "unsupported source/release combination: ${SOURCE_PRETTY_NAME}"
            ;;
    esac

    if [[ "$SOURCE_FAMILY" == "rhel" && "$SOURCE_MAJOR" == "7" && "$SOURCE_VERSION_ID" != "7.9" ]]; then
        die "RHEL 7 source must be RHEL 7.9 to migrate to Oracle Linux 7 latest"
    fi

    if [[ "$REINSTALL_ALL" == "auto" ]]; then
        if [[ "$SOURCE_FAMILY" == "rhel" ]]; then
            REINSTALL_ALL=1
        else
            REINSTALL_ALL=0
        fi
    fi

    BASEARCH="$(rpm --eval '%{_basearch}')"
    if [[ "$BASEARCH" == "%{_basearch}" || -z "$BASEARCH" ]]; then
        BASEARCH="$(rpm --eval '%{_target_cpu}')"
    fi
    if [[ "$BASEARCH" == "%{_target_cpu}" || -z "$BASEARCH" ]]; then
        BASEARCH="$(rpm --eval '%{_arch}')"
    fi
    [[ -n "$BASEARCH" ]] || die "unable to determine RPM base architecture"
    case "$BASEARCH" in
        x86_64|aarch64)
            ;;
        *)
            die "unsupported architecture: ${BASEARCH}; supported architectures are x86_64 and aarch64"
            ;;
    esac

    if [[ "$BASEARCH" == "aarch64" && "$KERNEL_FLAVOR" == "rhck" ]]; then
        if (( KERNEL_FLAVOR_REQUESTED )); then
            die "RHCK is not available on Oracle Linux aarch64; use --kernel uek or omit --kernel"
        fi
        KERNEL_FLAVOR="uek"
    fi
}

select_migration_mode() {
    if [[ "$SOURCE_FAMILY" == "centos-stream" ]]; then
        if [[ -n "$TARGET_VERSION" && "$TARGET_VERSION" != "latest" ]]; then
            die "CentOS Stream migrations always target Oracle Linux ${SOURCE_MAJOR} latest; use --target-version latest or omit --target-version"
        fi
        EFFECTIVE_TARGET_VERSION=""
        MIGRATION_MODE="latest-sync"
        return
    fi

    if [[ "$SOURCE_MAJOR" == "7" ]]; then
        if [[ -n "$TARGET_VERSION" && "$TARGET_VERSION" != "latest" ]]; then
            die "EL7 migrations always target Oracle Linux 7 latest; use --target-version latest or omit --target-version"
        fi
        EFFECTIVE_TARGET_VERSION=""
        MIGRATION_MODE="latest-sync"
        return
    fi

    if [[ -z "$TARGET_VERSION" ]]; then
        if [[ "$SOURCE_VERSION_ID" == *.* ]]; then
            EFFECTIVE_TARGET_VERSION="$SOURCE_VERSION_ID"
            MIGRATION_MODE="preserve-release"
        else
            EFFECTIVE_TARGET_VERSION=""
            MIGRATION_MODE="latest-sync"
        fi
    elif [[ "$TARGET_VERSION" == "latest" ]]; then
        EFFECTIVE_TARGET_VERSION=""
        MIGRATION_MODE="latest-sync"
    else
        case "$TARGET_VERSION" in
            "${SOURCE_MAJOR}."*)
                EFFECTIVE_TARGET_VERSION="$TARGET_VERSION"
                ;;
            *)
                die "--target-version must be latest or match the source major release ${SOURCE_MAJOR}; got ${TARGET_VERSION}"
                ;;
        esac

        if [[ "$EFFECTIVE_TARGET_VERSION" == "$SOURCE_VERSION_ID" ]]; then
            MIGRATION_MODE="preserve-release"
        else
            MIGRATION_MODE="release-sync"
        fi
    fi
}

prepare_environment() {
    [[ "$(id -u)" -eq 0 ]] || die "run as root"
    require_cmd rpm
    require_cmd awk
    require_cmd sed
    require_cmd sort
    require_cmd comm
    require_cmd xargs

    if [[ "$SOURCE_MAJOR" == "7" ]]; then
        require_cmd yum
        DNF_CMD="yum"
    else
        require_cmd dnf
        DNF_CMD="dnf"
    fi
    set_dnf_base_args
    set_oracle_repo_args

    mkdir -p "$STATE_DIR" "$LOG_ROOT"
    touch "$LOG_FILE"
    chmod 0600 "$LOG_FILE"
    record_migration_start
    configure_proxy

    info "run id: ${RUN_ID}"
    info "source: ${SOURCE_PRETTY_NAME}"
    info "target: $(target_label)"
    info "migration mode: ${MIGRATION_MODE}"
    info "kernel flavor: ${KERNEL_FLAVOR}"
    info "architecture: ${BASEARCH}"
    info "Oracle yum base URL: ${ORACLE_YUM_BASE}"
    if [[ -n "$PROXY_URL" ]]; then
        info "proxy URL: ${PROXY_URL}"
        printf '%s\n' "$PROXY_URL" > "${STATE_DIR}/proxy-url"
    fi
    printf '%s\n' "$ORACLE_YUM_BASE" > "${STATE_DIR}/oracle-yum-base-url"
}

set_dnf_base_args() {
    if [[ "$SOURCE_MAJOR" == "7" ]]; then
        DNF_BASE_ARGS=(
            "--setopt=reposdir=${STATE_DIR}/dnf.repos.d"
            "--releasever=${SOURCE_MAJOR}"
            "--setopt=keepcache=1"
        )
    else
        DNF_BASE_ARGS=(
            "--setopt=reposdir=${STATE_DIR}/dnf.repos.d"
            "--releasever=${SOURCE_MAJOR}"
            "--setopt=module_platform_id=platform:el${SOURCE_MAJOR}"
            "--setopt=keepcache=1"
        )
    fi

    if [[ -n "$PROXY_URL" ]]; then
        DNF_BASE_ARGS+=("--setopt=proxy=${PROXY_URL}")
    fi

    if (( YUM_MIRROR_REQUESTED )); then
        DNF_BASE_ARGS+=("--setopt=sslverify=0")
    fi
}

configure_proxy_file() {
    local config_file="$1"
    local tmp_file

    if (( DRY_RUN )); then
        info "dry-run: would configure proxy=${PROXY_URL} in ${config_file}"
        return 0
    fi

    mkdir -p "$(dirname "$config_file")"
    if [[ -f "$config_file" ]]; then
        cp -a "$config_file" "${STATE_DIR}/$(basename "$config_file").before-proxy"
    else
        : > "${STATE_DIR}/$(basename "$config_file").before-proxy"
    fi

    tmp_file="$(mktemp "${STATE_DIR}/$(basename "$config_file").XXXXXX")"
    if [[ -s "$config_file" ]]; then
        awk -v proxy="$PROXY_URL" '
            BEGIN {
                in_main = 0
                seen_main = 0
                wrote_proxy = 0
            }
            /^[[:space:]]*\[main\][[:space:]]*$/ {
                if (in_main && !wrote_proxy) {
                    print "proxy=" proxy
                    wrote_proxy = 1
                }
                in_main = 1
                seen_main = 1
                print
                next
            }
            /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
                if (in_main && !wrote_proxy) {
                    print "proxy=" proxy
                    wrote_proxy = 1
                }
                in_main = 0
                print
                next
            }
            in_main && /^[[:space:]]*proxy[[:space:]]*=/ {
                if (!wrote_proxy) {
                    print "proxy=" proxy
                    wrote_proxy = 1
                }
                next
            }
            {
                print
            }
            END {
                if (!seen_main) {
                    print ""
                    print "[main]"
                    print "proxy=" proxy
                } else if (in_main && !wrote_proxy) {
                    print "proxy=" proxy
                }
            }
        ' "$config_file" > "$tmp_file"
    else
        {
            printf '[main]\n'
            printf 'proxy=%s\n' "$PROXY_URL"
        } > "$tmp_file"
    fi

    install -m 0644 "$tmp_file" "$config_file"
    rm -f "$tmp_file"
}

configure_proxy() {
    [[ -n "$PROXY_URL" ]] || return 0

    info "configuring yum/dnf proxy"
    if [[ "$SOURCE_MAJOR" == "7" ]]; then
        configure_proxy_file /etc/yum.conf
        if [[ -d /etc/dnf || -f /etc/dnf/dnf.conf ]]; then
            configure_proxy_file /etc/dnf/dnf.conf
        fi
    else
        configure_proxy_file /etc/dnf/dnf.conf
        if [[ -f /etc/yum.conf ]]; then
            configure_proxy_file /etc/yum.conf
        fi
    fi
}

set_oracle_repo_args() {
    ORACLE_TARGET_EXCLUDE_ARGS=()

    if [[ "$SOURCE_MAJOR" == "7" ]]; then
        ORACLE_REPO_ARGS=(
            "--disablerepo=*"
            "--enablerepo=ol7_latest"
            "--enablerepo=ol7_addons"
            "--enablerepo=ol7_optional_latest"
        )
    else
        ORACLE_REPO_ARGS=(
            "--disablerepo=*"
            "--enablerepo=ol${SOURCE_MAJOR}_baseos_latest"
            "--enablerepo=ol${SOURCE_MAJOR}_appstream"
            "--enablerepo=ol${SOURCE_MAJOR}_addons"
            "--enablerepo=ol${SOURCE_MAJOR}_codeready_builder"
        )
    fi

    if [[ "$KERNEL_FLAVOR" == "uek" ]]; then
        ORACLE_REPO_ARGS+=("--enablerepo=$(uek_repo_id)")
    fi

    if [[ "$MIGRATION_MODE" == "release-sync" && "$EFFECTIVE_TARGET_VERSION" == "${SOURCE_MAJOR}."* ]]; then
        set_target_minor_exclude_args
    fi
}

set_target_minor_exclude_args() {
    local target_minor next_minor

    target_minor="${EFFECTIVE_TARGET_VERSION#"${SOURCE_MAJOR}".}"
    [[ "$target_minor" =~ ^[0-9]+$ ]] || return 0

    for ((next_minor = target_minor + 1; next_minor <= 20; next_minor++)); do
        ORACLE_TARGET_EXCLUDE_ARGS+=("--exclude=*.el${SOURCE_MAJOR}_${next_minor}*")
    done
}

uek_repo_id() {
    case "$SOURCE_MAJOR" in
        7) printf 'ol7_UEKR6\n' ;;
        8) printf 'ol8_UEKR7\n' ;;
        9) printf 'ol9_UEKR8\n' ;;
        10) printf 'ol10_UEKR8\n' ;;
        *) die "no UEK repository is defined for Oracle Linux ${SOURCE_MAJOR}" ;;
    esac
}

uek_repo_path() {
    case "$SOURCE_MAJOR" in
        7) printf 'UEKR6\n' ;;
        8) printf 'UEKR7\n' ;;
        9|10) printf 'UEKR8\n' ;;
        *) die "no UEK repository path is defined for Oracle Linux ${SOURCE_MAJOR}" ;;
    esac
}

snapshot_system() {
    info "creating package and repository snapshots in ${STATE_DIR}"
    run_capture "${STATE_DIR}/hostname" cat /proc/sys/kernel/hostname
    run_capture "${STATE_DIR}/os-release.before" cat /etc/os-release
    run_capture "${STATE_DIR}/rpmdb.before.tsv" rpm -qa --qf '%{NAME}\t%{EPOCHNUM}\t%{VERSION}\t%{RELEASE}\t%{ARCH}\t%{VENDOR}\t%{INSTALLTIME}\n'
    run_capture "${STATE_DIR}/rpmdb.before.nevra" rpm -qa --qf '%{nevra}\n'
    run_capture "${STATE_DIR}/release-packages.before" rpm -qa '*release*' '*repos*' '*gpg*'
    if ! snapshot_enabled_repos "${STATE_DIR}/enabled-repos.before"; then
        warn "could not snapshot enabled source repositories; continuing"
        : > "${STATE_DIR}/enabled-repos.before"
    fi

    if [[ -d /etc/yum.repos.d ]]; then
        mkdir -p "${STATE_DIR}/yum.repos.d.before"
        if ! (( DRY_RUN )); then
            cp -a /etc/yum.repos.d/. "${STATE_DIR}/yum.repos.d.before/"
        fi
    fi
}

check_kernel_state() {
    (( NO_REBOOT_CHECK )) && return 0

    local running installed_latest
    running="$(uname -r)"
    if [[ "$SOURCE_MAJOR" == "7" ]]; then
        installed_latest="$(rpm -q --last kernel 2>/dev/null | awk 'NR == 1 {print $1}' | sed 's/^kernel-//')"
    else
        installed_latest="$(rpm -q --last kernel-core 2>/dev/null | awk 'NR == 1 {print $1}' | sed 's/^kernel-core-//')"
    fi
    if [[ -n "$installed_latest" && "$running" != "$installed_latest" ]]; then
        die "running kernel (${running}) is not the newest installed kernel-core (${installed_latest}); reboot first or use --no-reboot-check"
    fi
}

check_rpmdb() {
    info "checking RPM database"
    run rpm --verifydb
}

write_bootstrap_repos() {
    local repo_dir="${STATE_DIR}/dnf.repos.d"
    local repo_file="${repo_dir}/oraclelinux-migration-bootstrap.repo"
    local gpg_key="${ORACLE_YUM_BASE}/RPM-GPG-KEY-oracle-ol${SOURCE_MAJOR}"
    local repo_tls_options=""

    if (( YUM_MIRROR_REQUESTED )); then
        repo_tls_options=$'\nsslverify=0'
    fi

    info "writing temporary Oracle Linux bootstrap repositories to ${repo_file}"
    mkdir -p "$repo_dir"

    if [[ "$SOURCE_MAJOR" == "7" ]]; then
        cat > "$repo_file" <<EOF
[ol7_latest]
name=Oracle Linux 7 Latest bootstrap
baseurl=${ORACLE_YUM_BASE}/repo/OracleLinux/OL7/latest/\$basearch/
enabled=1
gpgcheck=1
gpgkey=${gpg_key}${repo_tls_options}

[ol7_addons]
name=Oracle Linux 7 Addons bootstrap
baseurl=${ORACLE_YUM_BASE}/repo/OracleLinux/OL7/addons/\$basearch/
enabled=1
gpgcheck=1
gpgkey=${gpg_key}${repo_tls_options}

[ol7_optional_latest]
name=Oracle Linux 7 Optional Latest bootstrap
baseurl=${ORACLE_YUM_BASE}/repo/OracleLinux/OL7/optional/latest/\$basearch/
enabled=1
gpgcheck=1
gpgkey=${gpg_key}${repo_tls_options}
EOF
        if [[ "$KERNEL_FLAVOR" == "uek" ]]; then
            cat >> "$repo_file" <<EOF

[$(uek_repo_id)]
name=Oracle Linux 7 UEK bootstrap
baseurl=${ORACLE_YUM_BASE}/repo/OracleLinux/OL7/$(uek_repo_path)/\$basearch/
enabled=1
gpgcheck=1
gpgkey=${gpg_key}${repo_tls_options}
EOF
        fi
        return
    fi

    local baseos_path="baseos/latest"
    if [[ "$MIGRATION_MODE" != "latest-sync" ]]; then
        baseos_path="${EFFECTIVE_TARGET_VERSION#"${SOURCE_MAJOR}".}/baseos/base"
    fi

    cat > "$repo_file" <<EOF
[ol${SOURCE_MAJOR}_baseos_latest]
name=Oracle Linux ${SOURCE_MAJOR} BaseOS Latest bootstrap
baseurl=${ORACLE_YUM_BASE}/repo/OracleLinux/OL${SOURCE_MAJOR}/${baseos_path}/\$basearch/
enabled=1
gpgcheck=1
gpgkey=${gpg_key}${repo_tls_options}

[ol${SOURCE_MAJOR}_baseos_exception_latest]
name=Oracle Linux ${SOURCE_MAJOR} BaseOS Latest exception bootstrap
baseurl=${ORACLE_YUM_BASE}/repo/OracleLinux/OL${SOURCE_MAJOR}/baseos/latest/\$basearch/
enabled=0
gpgcheck=1
gpgkey=${gpg_key}${repo_tls_options}

[ol${SOURCE_MAJOR}_appstream]
name=Oracle Linux ${SOURCE_MAJOR} AppStream bootstrap
baseurl=${ORACLE_YUM_BASE}/repo/OracleLinux/OL${SOURCE_MAJOR}/appstream/\$basearch/
enabled=1
gpgcheck=1
gpgkey=${gpg_key}${repo_tls_options}

[ol${SOURCE_MAJOR}_addons]
name=Oracle Linux ${SOURCE_MAJOR} Addons bootstrap
baseurl=${ORACLE_YUM_BASE}/repo/OracleLinux/OL${SOURCE_MAJOR}/addons/\$basearch/
enabled=1
gpgcheck=1
gpgkey=${gpg_key}${repo_tls_options}

[ol${SOURCE_MAJOR}_codeready_builder]
name=Oracle Linux ${SOURCE_MAJOR} CodeReady Builder bootstrap
baseurl=${ORACLE_YUM_BASE}/repo/OracleLinux/OL${SOURCE_MAJOR}/codeready/builder/\$basearch/
enabled=1
gpgcheck=1
gpgkey=${gpg_key}${repo_tls_options}
EOF

    if [[ "$KERNEL_FLAVOR" == "uek" ]]; then
        cat >> "$repo_file" <<EOF

[$(uek_repo_id)]
name=Oracle Linux ${SOURCE_MAJOR} UEK bootstrap
baseurl=${ORACLE_YUM_BASE}/repo/OracleLinux/OL${SOURCE_MAJOR}/$(uek_repo_path)/\$basearch/
enabled=1
gpgcheck=1
gpgkey=${gpg_key}${repo_tls_options}
EOF
    fi
}

disable_source_repos() {
    local backup_dir="${STATE_DIR}/disabled-source-repos"
    local repo

    [[ -d /etc/yum.repos.d ]] || return 0
    mkdir -p "$backup_dir"

    info "disabling source distribution repository files"
    while IFS= read -r repo; do
        [[ -n "$repo" ]] || continue
        case "$(basename "$repo")" in
            oraclelinux-migration-bootstrap.repo|oracle-linux-ol*.repo|uek-ol*.repo)
                continue
                ;;
        esac
        if grep -Eiq '(amazon|amzn|centos|almalinux|rocky|red ?hat|rhel)' "$repo"; then
            info "disabling $(basename "$repo")"
            if ! (( DRY_RUN )); then
                cp -a "$repo" "${backup_dir}/$(basename "$repo")"
                if [[ "$SOURCE_FAMILY" == "amazon-linux" ]]; then
                    mv "$repo" "${repo}.disabled-by-oracle-migration"
                else
                    sed -i.bak -E 's/^[[:space:]]*enabled[[:space:]]*=[[:space:]]*1[[:space:]]*$/enabled=0/I' "$repo"
                fi
            fi
        fi
    done < <(find /etc/yum.repos.d -maxdepth 1 -type f -name '*.repo' | sort)
}

remove_source_release_packages() {
    local pkg remove_list=()
    local candidates=(
        almalinux-gpg-keys almalinux-release almalinux-repos
        amazon-linux-extras amazon-linux-repo-cdn amazon-linux-repo-s3 system-release system-release-cpe
        centos-gpg-keys centos-linux-release centos-linux-repos centos-release centos-repos centos-stream-release centos-stream-repos
        redhat-release redhat-release-eula redhat-release-server redhat-release-workstation
        rocky-gpg-keys rocky-release rocky-repos
    )

    for pkg in "${candidates[@]}"; do
        if rpm -q "$pkg" >/dev/null 2>&1; then
            remove_list+=("$pkg")
        fi
    done

    if ((${#remove_list[@]} == 0)); then
        warn "no source release packages matched the built-in removal list"
        return 0
    fi

    printf '%s\n' "${remove_list[@]}" > "${STATE_DIR}/source-release-packages.removed"
    info "removing source release packages with rpm --nodeps: ${remove_list[*]}"
    run rpm -e --nodeps "${remove_list[@]}"
}

is_rhel_only_removed_package_name() {
    case "$1" in
        gpg-pubkey|\
        insights-client|\
        kpatch|\
        kpatch-dnf|\
        dnf-plugin-subscription-manager|\
        libdnf-plugin-subscription-manager|\
        python-rhsm|\
        python-syspurpose|\
        python3-cloud-what|\
        python3-subscription-manager-rhsm|\
        python3-syspurpose|\
        Red_Hat_Enterprise_Linux-Release_Notes-*|\
        redhat-logos|\
        rhsm-icons|\
        rhc|\
        redhat-support-lib-python|\
        redhat-support-tool|\
        subscription-manager|\
        subscription-manager-cockpit|\
        subscription-manager-rhsm|\
        subscription-manager-rhsm-certificates)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_amazon_only_removed_package_name() {
    case "$1" in
        amd-ucode-firmware|\
        amazon-ssm-agent|\
        awscli|\
        cpp10|\
        gcc10|\
        gcc10-*|\
        glibc-all-langpacks|\
        glibc-devel|\
        glibc-headers|\
        glibc-locale-source|\
        glibc-minimal-langpack|\
        kernel-devel|\
        libcrypt|\
        libctf|\
        libfdisk|\
        libsanitizer|\
        python2-botocore|\
        python2-rpm|\
        python2-s3transfer|\
        update-motd|\
        vim-data|\
        xxd)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

remove_amazon_only_packages() {
    [[ "$SOURCE_FAMILY" == "amazon-linux" ]] || return 0

    local removed_tsv="${STATE_DIR}/amazon-only-packages.removed.tsv"
    local removed_nevra="${STATE_DIR}/amazon-only-packages.removed.nevra"
    local compat_lib_dir="${STATE_DIR}/amazon-compat-lib64"
    local compat_python_dir="${STATE_DIR}/amazon-compat-python2.7"
    local python_site
    local rpm remove_list=()

    awk -F '\t' '
        function nevra(name, epoch, version, release, arch) {
            return name "-" (epoch > 0 ? epoch ":" : "") version "-" release "." arch
        }
        function removed_name(name) {
            return name == "amd-ucode-firmware" ||
                name == "amazon-ssm-agent" ||
                name == "awscli" ||
                name == "cpp10" ||
                name == "gcc10" ||
                name ~ /^gcc10-/ ||
                name == "glibc-all-langpacks" ||
                name == "glibc-devel" ||
                name == "glibc-headers" ||
                name == "glibc-locale-source" ||
                name == "glibc-minimal-langpack" ||
                name == "kernel-devel" ||
                name == "libcrypt" ||
                name == "libctf" ||
                name == "libfdisk" ||
                name == "libsanitizer" ||
                name == "python2-botocore" ||
                name == "python2-rpm" ||
                name == "python2-s3transfer" ||
                name == "update-motd" ||
                name == "vim-data" ||
                name == "xxd"
        }
        BEGIN {
            print "source_nevra\ttarget_nevra\tname\tepoch\tversion\tsource_release\ttarget_release\tarch\tstatus"
        }
        removed_name($1) {
            print nevra($1, $2, $3, $4, $5) "\t\t" $1 "\t" $2 "\t" $3 "\t" $4 "\t\t" $5 "\tremoved-amazon-only"
        }
    ' "${STATE_DIR}/rpmdb.before.tsv" > "$removed_tsv"

    tail -n +2 "$removed_tsv" | cut -f 1 | sort -u > "$removed_nevra"
    if [[ ! -s "$removed_nevra" ]]; then
        info "no Amazon Linux 2-only packages need pre-sync removal"
        return 0
    fi

    while IFS= read -r rpm; do
        [[ -n "$rpm" ]] || continue
        remove_list+=("$rpm")
    done < <(
        rpm -qa --qf '%{NAME}\t%{NVRA}\n' | awk -F '\t' '
            $1 == "amd-ucode-firmware" ||
            $1 == "amazon-ssm-agent" ||
            $1 == "awscli" ||
            $1 == "cpp10" ||
            $1 == "gcc10" ||
            $1 ~ /^gcc10-/ ||
            $1 == "glibc-all-langpacks" ||
            $1 == "glibc-devel" ||
            $1 == "glibc-headers" ||
            $1 == "glibc-locale-source" ||
            $1 == "glibc-minimal-langpack" ||
            $1 == "kernel-devel" ||
            $1 == "libcrypt" ||
            $1 == "libctf" ||
            $1 == "libfdisk" ||
            $1 == "libsanitizer" ||
            $1 == "python2-botocore" ||
            $1 == "python2-rpm" ||
            $1 == "python2-s3transfer" ||
            $1 == "update-motd" ||
            $1 == "vim-data" ||
            $1 == "xxd" {
                print $2
            }
        ' | sort -u
    )

    if [[ "${#remove_list[@]}" -eq 0 ]]; then
        info "Amazon Linux 2-only packages were already absent"
        return 0
    fi

    if rpm -q libcrypt >/dev/null 2>&1 && [[ -e /lib64/libcrypt.so.1 ]]; then
        mkdir -p "$compat_lib_dir"
        if ! (( DRY_RUN )); then
            cp -L /lib64/libcrypt.so.1 "${compat_lib_dir}/libcrypt.so.1"
        fi
        printf '%s\n' "$compat_lib_dir" > "${STATE_DIR}/amazon-compat-libcrypt.path"
    fi

    if rpm -q python2-rpm >/dev/null 2>&1; then
        for python_site in /usr/lib64/python2.7/site-packages /usr/lib/python2.7/site-packages; do
            [[ -e "${python_site}/rpm" || -e "${python_site}/rpmUtils" || -e "${python_site}/rpm-4.11.3-py2.7.egg-info" ]] || continue
            mkdir -p "$compat_python_dir"
            if ! (( DRY_RUN )); then
                cp -a "${python_site}/rpm" "$compat_python_dir/" 2>/dev/null || true
                cp -a "${python_site}/rpmUtils" "$compat_python_dir/" 2>/dev/null || true
                cp -a "${python_site}/rpm-4.11.3-py2.7.egg-info" "$compat_python_dir/" 2>/dev/null || true
            fi
            printf '%s\n' "$compat_python_dir" > "${STATE_DIR}/amazon-compat-python.path"
            break
        done
    fi

    info "removing Amazon Linux 2-only packages before Oracle Linux 7 distro-sync: ${remove_list[*]}"
    run rpm -e --nodeps "${remove_list[@]}"
}

remove_remaining_amazon_only_packages() {
    [[ "$SOURCE_FAMILY" == "amazon-linux" ]] || return 0

    local rpm remove_list=()
    local candidates=(
        amazon-linux-onprem
        generic-logos
        iptables-libs
        isl
        kpatch-runtime
        libidn2
        libmetalink
        libmpx
        libnghttp2
        libpsl
        publicsuffix-list-dafsa
        python-repoze-lru
        python2-colorama
        python2-dateutil
        python2-jmespath
        python2-jsonschema
        python2-rsa
        python2-setuptools
        python2-six
        sysctl-defaults
    )

    for rpm in "${candidates[@]}"; do
        if rpm -q "$rpm" >/dev/null 2>&1; then
            remove_list+=("$rpm")
        fi
    done

    if [[ "${#remove_list[@]}" -eq 0 ]]; then
        info "no remaining Amazon Linux 2-only leaf packages need removal"
        return 0
    fi

    info "removing remaining Amazon Linux 2-only leaf packages after Oracle Linux distro-sync: ${remove_list[*]}"
    run rpm -e --nodeps "${remove_list[@]}"

    info "installing Oracle Linux providers for dependencies previously satisfied by Amazon-only leaf packages"
    run "$DNF_CMD" -y \
        "${DNF_BASE_ARGS[@]}" \
        "${ORACLE_REPO_ARGS[@]}" \
        install oracle-logos python-setuptools python-six
}

is_el10_split_firmware_package_name() {
    [[ "$SOURCE_MAJOR" == "10" ]] || return 1

    case "$1" in
        amd-gpu-firmware|\
        amd-ucode-firmware|\
        atheros-firmware|\
        brcmfmac-firmware|\
        cirrus-audio-firmware|\
        intel-audio-firmware|\
        intel-gpu-firmware|\
        iwlwifi-dvm-firmware|\
        iwlwifi-mvm-firmware|\
        mt7xxx-firmware|\
        nxpwireless-firmware|\
        nvidia-gpu-firmware|\
        tiwilink-firmware|\
        realtek-firmware)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

remove_el10_split_firmware_packages() {
    [[ "$SOURCE_MAJOR" == "10" ]] || return 0

    local remove_list=()
    local rpm_name rpm_nvra

    while IFS=$'\t' read -r rpm_name rpm_nvra; do
        [[ -n "$rpm_name" && -n "$rpm_nvra" ]] || continue
        if is_el10_split_firmware_package_name "$rpm_name"; then
            remove_list+=("$rpm_nvra")
        fi
    done < <(rpm -qa --qf '%{NAME}\t%{NVRA}\n' | sort -u)

    if [[ "${#remove_list[@]}" -eq 0 ]]; then
        info "no EL10 split firmware packages found"
        return 0
    fi

    info "removing EL10 split firmware packages replaced by Oracle Linux linux-firmware: ${remove_list[*]}"
    run rpm -e --nodeps "${remove_list[@]}"
}

remove_rhel_only_packages() {
    local removed_tsv="${STATE_DIR}/rhel-only-packages.removed.tsv"
    local removed_nevra="${STATE_DIR}/rhel-only-packages.removed.nevra"
    local rpm remove_list=()

    awk -F '\t' '
        function nevra(name, epoch, version, release, arch) {
            return name "-" (epoch > 0 ? epoch ":" : "") version "-" release "." arch
        }
        function removed_name(name) {
            return name == "gpg-pubkey" ||
                name == "insights-client" ||
                name == "kpatch" ||
                name == "kpatch-dnf" ||
                name == "dnf-plugin-subscription-manager" ||
                name == "libdnf-plugin-subscription-manager" ||
                name == "python-rhsm" ||
                name == "python-syspurpose" ||
                name == "python3-cloud-what" ||
                name == "python3-subscription-manager-rhsm" ||
                name == "python3-syspurpose" ||
                name ~ /^Red_Hat_Enterprise_Linux-Release_Notes-/ ||
                name == "rhc" ||
                name == "redhat-logos" ||
                name == "rhsm-icons" ||
                name == "redhat-support-lib-python" ||
                name == "redhat-support-tool" ||
                name == "subscription-manager" ||
                name == "subscription-manager-cockpit" ||
                name == "subscription-manager-rhsm" ||
                name == "subscription-manager-rhsm-certificates"
        }
        BEGIN {
            print "source_nevra\ttarget_nevra\tname\tepoch\tversion\tsource_release\ttarget_release\tarch\tstatus"
        }
        removed_name($1) {
            print nevra($1, $2, $3, $4, $5) "\t\t" $1 "\t" $2 "\t" $3 "\t" $4 "\t\t" $5 "\tremoved-rhel-only"
        }
    ' "${STATE_DIR}/rpmdb.before.tsv" > "$removed_tsv"

    tail -n +2 "$removed_tsv" | cut -f 1 | sort -u > "$removed_nevra"
    if [[ ! -s "$removed_nevra" ]]; then
        info "no source-only subscription or GPG pseudo-packages found"
        return 0
    fi

    while IFS= read -r rpm; do
        [[ -n "$rpm" ]] || continue
        remove_list+=("$rpm")
    done < <(
        rpm -qa --qf '%{NAME}\t%{NVRA}\n' | awk -F '\t' '
            $1 == "gpg-pubkey" ||
            $1 == "insights-client" ||
            $1 == "kpatch" ||
            $1 == "kpatch-dnf" ||
            $1 == "dnf-plugin-subscription-manager" ||
            $1 == "libdnf-plugin-subscription-manager" ||
            $1 == "python-rhsm" ||
            $1 == "python-syspurpose" ||
            $1 == "python3-cloud-what" ||
            $1 == "python3-subscription-manager-rhsm" ||
            $1 == "python3-syspurpose" ||
            $1 ~ /^Red_Hat_Enterprise_Linux-Release_Notes-/ ||
            $1 == "rhc" ||
            $1 == "redhat-logos" ||
            $1 == "rhsm-icons" ||
            $1 == "redhat-support-lib-python" ||
            $1 == "redhat-support-tool" ||
            $1 == "subscription-manager" ||
            $1 == "subscription-manager-cockpit" ||
            $1 == "subscription-manager-rhsm" ||
            $1 == "subscription-manager-rhsm-certificates" {
                print $2
            }
        ' | sort -u
    )

    info "removing source-only subscription-manager packages and GPG pseudo-packages: ${remove_list[*]}"
    run rpm -e --nodeps "${remove_list[@]}"
}

install_oracle_release_packages() {
    local release_pkgs=("oraclelinux-release-el${SOURCE_MAJOR}" "oraclelinux-release")

    info "installing Oracle Linux release packages"
    run "$DNF_CMD" -y \
        "${DNF_BASE_ARGS[@]}" \
        "${ORACLE_REPO_ARGS[@]}" \
        install "${release_pkgs[@]}"
}

refresh_oracle_repos() {
    info "refreshing Oracle Linux repository metadata"
    run "$DNF_CMD" -y \
        "${DNF_BASE_ARGS[@]}" \
        "${ORACLE_REPO_ARGS[@]}" \
        clean all
    run "$DNF_CMD" -y \
        "${DNF_BASE_ARGS[@]}" \
        "${ORACLE_REPO_ARGS[@]}" \
        makecache
}

ensure_repoquery_available() {
    if command -v repoquery >/dev/null 2>&1; then
        return 0
    fi

    if [[ "$SOURCE_MAJOR" == "7" ]]; then
        info "installing yum-utils to provide repoquery"
        run "$DNF_CMD" -y \
            "${DNF_BASE_ARGS[@]}" \
            "${ORACLE_REPO_ARGS[@]}" \
            install yum-utils
        require_cmd repoquery
    fi
}

repoquery_available_nevras() {
    local out="$1"

    info "querying Oracle repositories for available NEVRAs"
    if [[ "$SOURCE_MAJOR" == "7" ]]; then
        ensure_repoquery_available
        run_capture "$out" repoquery \
            "${DNF_BASE_ARGS[@]}" \
            "${ORACLE_REPO_ARGS[@]}" \
            ${ORACLE_TARGET_EXCLUDE_ARGS[@]+"${ORACLE_TARGET_EXCLUDE_ARGS[@]}"} \
            --archlist="$BASEARCH,noarch" --queryformat '%{name}-%{epoch}:%{version}-%{release}.%{arch}' \
            '*'
        awk -F '[:-]' '
            {
                split($0, parts, "-")
                name = parts[1]
                for (i = 2; i < length(parts); i++) {
                    name = name "-" parts[i]
                }
                sub("-0:", "-", $0)
                print
            }
        ' "$out" > "${out}.normalized"
        mv "${out}.normalized" "$out"
    else
        run_capture "$out" "$DNF_CMD" \
            "${DNF_BASE_ARGS[@]}" \
            "${ORACLE_REPO_ARGS[@]}" \
            ${ORACLE_TARGET_EXCLUDE_ARGS[@]+"${ORACLE_TARGET_EXCLUDE_ARGS[@]}"} \
            repoquery --available --arch "$BASEARCH" --arch noarch --queryformat '%{name}-%{evr}.%{arch}'
    fi
}

repoquery_available_packages() {
    local out="$1"

    info "querying Oracle repositories for available package metadata"
    if [[ "$SOURCE_MAJOR" == "7" ]]; then
        ensure_repoquery_available
        run_capture "$out" repoquery \
            "${DNF_BASE_ARGS[@]}" \
            "${ORACLE_REPO_ARGS[@]}" \
            ${ORACLE_TARGET_EXCLUDE_ARGS[@]+"${ORACLE_TARGET_EXCLUDE_ARGS[@]}"} \
            --archlist="$BASEARCH,noarch" --queryformat $'%{name}\t%{epoch}\t%{version}\t%{release}\t%{arch}' \
            '*'
        awk -F '\t' '
            function nevra(name, epoch, version, release, arch) {
                return name "-" (epoch > 0 ? epoch ":" : "") version "-" release "." arch
            }
            {
                epoch = ($2 == "" || $2 == "(none)") ? 0 : $2
                print $1 "\t" epoch "\t" $3 "\t" $4 "\t" $5 "\t" nevra($1, epoch, $3, $4, $5)
            }
        ' "$out" > "${out}.normalized"
        mv "${out}.normalized" "$out"
    else
        run_capture "$out" "$DNF_CMD" \
            "${DNF_BASE_ARGS[@]}" \
            "${ORACLE_REPO_ARGS[@]}" \
            ${ORACLE_TARGET_EXCLUDE_ARGS[@]+"${ORACLE_TARGET_EXCLUDE_ARGS[@]}"} \
            repoquery --available --arch "$BASEARCH" --arch noarch --queryformat $'%{name}\t%{epoch}\t%{version}\t%{release}\t%{arch}\t%{name}-%{evr}.%{arch}'
    fi
}

repoquery_update_exception_packages() {
    local out="$1"

    info "querying Oracle BaseOS latest metadata for update-only exception packages"
    run_capture "$out" "$DNF_CMD" \
        "${DNF_BASE_ARGS[@]}" \
        --disablerepo='*' \
        "--enablerepo=ol${SOURCE_MAJOR}_baseos_exception_latest" \
        repoquery --available --arch "$BASEARCH" --arch noarch --queryformat $'%{name}\t%{epoch}\t%{version}\t%{release}\t%{arch}\t%{name}-%{evr}.%{arch}' \
        ca-certificates tzdata
}

build_reinstall_plan() {
    local available_nevra="${STATE_DIR}/oracle.available.nevra"
    local available_tsv="${STATE_DIR}/oracle.available.tsv"
    local exception_available_tsv="${STATE_DIR}/oracle.update-exceptions.available.tsv"
    local wanted_tsv="${STATE_DIR}/wanted-installed.tsv"
    local wanted_nevra="${STATE_DIR}/wanted-installed.nevra"
    local exact_nevra="${STATE_DIR}/exact-reinstall.nevra"
    local exact_standard_nevra="${STATE_DIR}/exact-standard-reinstall.nevra"
    local exact_tsv="${STATE_DIR}/exact-reinstall.tsv"
    local nearest_nevra="${STATE_DIR}/nearest-reinstall.nevra"
    local nearest_higher_nevra="${STATE_DIR}/nearest-higher-reinstall.nevra"
    local nearest_higher_standard_nevra="${STATE_DIR}/nearest-higher-standard-reinstall.nevra"
    local nearest_lower_nevra="${STATE_DIR}/nearest-lower-reinstall.nevra"
    local update_exception_nevra="${STATE_DIR}/update-exception-reinstall.nevra"
    local nearest_tsv="${STATE_DIR}/nearest-reinstall.tsv"
    local unavailable_nevra="${STATE_DIR}/unavailable-reinstall.nevra"
    local unavailable_tsv="${STATE_DIR}/unavailable-reinstall.tsv"
    local missing_nevra="${STATE_DIR}/missing-exact.nevra"
    local release_exceptions="${STATE_DIR}/release-package-exceptions.nevra"

    repoquery_available_nevras "$available_nevra"
    repoquery_available_packages "$available_tsv"
    repoquery_update_exception_packages "$exception_available_tsv"
    cat "$exception_available_tsv" >> "$available_tsv"
    cut -f 6 "$exception_available_tsv" >> "$available_nevra"
    sort -u "${STATE_DIR}/rpmdb.before.nevra" > "${STATE_DIR}/rpmdb.before.nevra.sorted"
    sort -u "$available_nevra" > "${available_nevra}.sorted"

    if (( REINSTALL_ALL )); then
        awk -F '\t' '
            function nevra(name, epoch, version, release, arch) {
                return name "-" (epoch > 0 ? epoch ":" : "") version "-" release "." arch
            }
            {
                print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" nevra($1, $2, $3, $4, $5)
            }
        ' "${STATE_DIR}/rpmdb.before.tsv" | sort -u > "$wanted_tsv"
    else
        awk -F '\t' '
            BEGIN { IGNORECASE = 1 }
            $6 ~ /(AlmaLinux|Amazon|CentOS|Red Hat|Rocky)/ {
                print $1
            }
        ' "${STATE_DIR}/rpmdb.before.tsv" | sort -u > "${STATE_DIR}/wanted-names"

        awk -F '\t' '
            function nevra(name, epoch, version, release, arch) {
                return name "-" (epoch > 0 ? epoch ":" : "") version "-" release "." arch
            }
            NR == FNR {
                wanted[$1] = 1
                next
            }
            wanted[$1] {
                print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" nevra($1, $2, $3, $4, $5)
            }
        ' "${STATE_DIR}/wanted-names" "${STATE_DIR}/rpmdb.before.tsv" | sort -u > "$wanted_tsv"
    fi

    if [[ -s "${STATE_DIR}/rhel-only-packages.removed.nevra" ]]; then
        awk -F '\t' '
            NR == FNR {
                removed[$1] = 1
                next
            }
            !($6 in removed)
        ' "${STATE_DIR}/rhel-only-packages.removed.nevra" "$wanted_tsv" > "${wanted_tsv}.filtered"
        mv "${wanted_tsv}.filtered" "$wanted_tsv"
    fi

    cut -f 6 "$wanted_tsv" | sort -u > "$wanted_nevra"
    comm -12 "$wanted_nevra" "${available_nevra}.sorted" > "$exact_nevra"
    comm -23 "$wanted_nevra" "${available_nevra}.sorted" > "$missing_nevra"

    awk -F '\t' -v exact_out="$exact_tsv" -v nearest_out="$nearest_tsv" -v unavailable_out="$unavailable_tsv" '
        function normalize_epoch(epoch) {
            return (epoch == "" || epoch == "(none)") ? 0 : epoch
        }
        function common_prefix_len(left, right,    i, max) {
            max = length(left) < length(right) ? length(left) : length(right)
            for (i = 1; i <= max; i++) {
                if (substr(left, i, 1) != substr(right, i, 1)) {
                    return i - 1
                }
            }
            return max
        }
        function tokenize_release(value, tokens,    rest, n) {
            delete tokens
            rest = value
            n = 0
            while (match(rest, /[0-9]+|[A-Za-z]+/)) {
                tokens[++n] = substr(rest, RSTART, RLENGTH)
                rest = substr(rest, RSTART + RLENGTH)
            }
            return n
        }
        function compare_release(left, right,    left_parts, right_parts, left_count, right_count, idx, left_token, right_token, left_numeric, right_numeric) {
            left_count = tokenize_release(left, left_parts)
            right_count = tokenize_release(right, right_parts)
            for (idx = 1; idx <= left_count || idx <= right_count; idx++) {
                if (idx > left_count) {
                    return -1
                }
                if (idx > right_count) {
                    return 1
                }
                left_token = left_parts[idx]
                right_token = right_parts[idx]
                left_numeric = left_token ~ /^[0-9]+$/
                right_numeric = right_token ~ /^[0-9]+$/
                if (left_numeric && right_numeric) {
                    left_token += 0
                    right_token += 0
                    if (left_token < right_token) {
                        return -1
                    }
                    if (left_token > right_token) {
                        return 1
                    }
                } else if (left_numeric != right_numeric) {
                    return left_numeric ? 1 : -1
                } else {
                    if (left_token < right_token) {
                        return -1
                    }
                    if (left_token > right_token) {
                        return 1
                    }
                }
            }
            return 0
        }
        function compare_evr(left_version, left_release, right_version, right_release,    version_cmp) {
            version_cmp = compare_release(left_version, right_version)
            if (version_cmp != 0) {
                return version_cmp
            }
            return compare_release(left_release, right_release)
        }
        function is_update_exception(name) {
            return name == "ca-certificates" || name == "tzdata"
        }
        function is_better_candidate(name, source_version, source_release, candidate_version, candidate_release, best_version, best_release,    direction, best_direction, candidate_cmp, prefix, best_prefix) {
            direction = compare_evr(candidate_version, candidate_release, source_version, source_release)
            if (direction == 0) {
                return 0
            }
            if (is_update_exception(name) && direction < 0) {
                return 0
            }
            if (best_release == "") {
                return 1
            }

            best_direction = compare_evr(best_version, best_release, source_version, source_release)
            if (direction > 0 && best_direction < 0) {
                return 1
            }
            if (direction < 0 && best_direction > 0) {
                return 0
            }

            candidate_cmp = compare_evr(candidate_version, candidate_release, best_version, best_release)
            if (direction > 0) {
                if (is_update_exception(name)) {
                    if (candidate_cmp > 0) {
                        return 1
                    }
                    if (candidate_cmp < 0) {
                        return 0
                    }
                }
                if (candidate_cmp < 0) {
                    return 1
                }
                if (candidate_cmp > 0) {
                    return 0
                }
            } else {
                if (candidate_cmp > 0) {
                    return 1
                }
                if (candidate_cmp < 0) {
                    return 0
                }
            }

            prefix = common_prefix_len(source_version "-" source_release, candidate_version "-" candidate_release)
            best_prefix = common_prefix_len(source_version "-" source_release, best_version "-" best_release)
            return prefix > best_prefix
        }
        function header(file) {
            print "source_nevra\ttarget_nevra\tname\tepoch\tversion\tsource_release\ttarget_release\tarch\tstatus" > file
        }
        function source_nevra(name, epoch, version, release, arch) {
            return name "-" (epoch > 0 ? epoch ":" : "") version "-" release "." arch
        }
        BEGIN {
            header(exact_out)
            header(nearest_out)
            header(unavailable_out)
        }
        NR == FNR {
            name = $1
            epoch = normalize_epoch($2)
            version = $3
            release = $4
            arch = $5
            nevra = $6
            exact[name SUBSEP epoch SUBSEP version SUBSEP release SUBSEP arch] = nevra
            group = name SUBSEP epoch SUBSEP arch
            candidate_count[group]++
            available_versions[group SUBSEP candidate_count[group]] = version
            available_releases[group SUBSEP candidate_count[group]] = release
            available_nevras[group SUBSEP candidate_count[group]] = nevra
            next
        }
        {
            name = $1
            epoch = normalize_epoch($2)
            version = $3
            release = $4
            arch = $5
            source = $6
            exact_key = name SUBSEP epoch SUBSEP version SUBSEP release SUBSEP arch
            group = name SUBSEP epoch SUBSEP arch
            if (exact_key in exact) {
                print source "\t" exact[exact_key] "\t" name "\t" epoch "\t" version "\t" release "\t" release "\t" arch "\texact" >> exact_out
                next
            }
            best_version = ""
            best_release = ""
            for (idx = 1; idx <= candidate_count[group]; idx++) {
                candidate_version = available_versions[group SUBSEP idx]
                candidate_release = available_releases[group SUBSEP idx]
                if (is_better_candidate(name, version, release, candidate_version, candidate_release, best_version, best_release)) {
                    best_version = candidate_version
                    best_release = candidate_release
                    best_idx = idx
                }
            }
            if (best_release != "") {
                target = available_nevras[group SUBSEP best_idx]
                replacement_status = compare_evr(best_version, best_release, version, release) > 0 ? "nearest-higher-release" : "nearest-lower-release"
                print source "\t" target "\t" name "\t" epoch "\t" version "\t" release "\t" best_release "\t" arch "\t" replacement_status >> nearest_out
            } else {
                print source "\t\t" name "\t" epoch "\t" version "\t" release "\t\t" arch "\tunavailable" >> unavailable_out
            }
        }
    ' "$available_tsv" "$wanted_tsv"

    awk -F '\t' 'NR > 1 && $9 == "nearest-higher-release" { print $2 }' "$nearest_tsv" | sort -u > "$nearest_higher_nevra"
    awk -F '\t' 'NR > 1 && $9 == "nearest-higher-release" && $3 != "ca-certificates" && $3 != "tzdata" { print $2 }' "$nearest_tsv" | sort -u > "$nearest_higher_standard_nevra"
    awk -F '\t' 'NR > 1 && $9 == "nearest-lower-release" { print $2 }' "$nearest_tsv" | sort -u > "$nearest_lower_nevra"
    {
        awk -F '\t' 'NR > 1 && ($3 == "ca-certificates" || $3 == "tzdata") { print $2 }' "$exact_tsv"
        awk -F '\t' 'NR > 1 && ($3 == "ca-certificates" || $3 == "tzdata") && $9 == "nearest-higher-release" { print $2 }' "$nearest_tsv"
    } | sort -u > "$update_exception_nevra"
    awk -F '\t' 'NR > 1 && $3 != "ca-certificates" && $3 != "tzdata" { print $2 }' "$exact_tsv" | sort -u > "$exact_standard_nevra"
    cat "$nearest_higher_nevra" "$nearest_lower_nevra" | sort -u > "$nearest_nevra"
    tail -n +2 "$unavailable_tsv" | cut -f 1 | sort -u > "$unavailable_nevra"

    grep -E '(^|/)(almalinux|centos|redhat|rocky|oraclelinux)-(release|repos|gpg-keys)|^redhat-release' \
        "$unavailable_nevra" > "$release_exceptions" || true
    grep -Ev '(^|/)(almalinux|centos|redhat|rocky|oraclelinux)-(release|repos|gpg-keys)|^redhat-release' \
        "$unavailable_nevra" > "${missing_nevra}.strict" || true

    info "exact reinstall candidates: $(wc -l < "$exact_nevra" | tr -d ' ')"
    info "nearest-release reinstall candidates: $(wc -l < "$nearest_nevra" | tr -d ' ')"
    info "packages without Oracle replacement: $(wc -l < "$unavailable_nevra" | tr -d ' ')"

    generate_html_reports "$exact_tsv" "$nearest_tsv" "$unavailable_tsv" "$available_tsv"

    if [[ -s "$nearest_nevra" || -s "${missing_nevra}.strict" ]]; then
        warn "some packages do not have exact Oracle NEVRAs; see ${nearest_tsv} and ${missing_nevra}.strict"
        if (( STRICT_EVR )); then
            die "strict EVR preservation failed; rerun without --strict-evr to continue"
        fi
    fi
}

write_html_report() {
    local title="$1"
    local input="$2"
    local output="$3"

    {
        cat <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>${title}</title>
<style>
body { font-family: system-ui, sans-serif; margin: 2rem; color: #1f2933; }
table { border-collapse: collapse; width: 100%; }
th, td { border: 1px solid #cbd5e1; padding: 0.35rem 0.5rem; text-align: left; font-size: 0.9rem; }
th { background: #e5e7eb; }
caption { font-size: 1.2rem; font-weight: 700; margin-bottom: 1rem; text-align: left; }
.meta { margin-bottom: 1rem; color: #52606d; }
.release-meta { border: 1px solid #cbd5e1; margin-bottom: 1rem; }
.release-meta th { width: 16rem; vertical-align: top; }
.release-meta pre { margin: 0; white-space: pre-wrap; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 0.85rem; }
</style>
</head>
<body>
<div class="meta">Generated by ${PROGRAM_NAME} run ${RUN_ID}</div>
EOF
        write_html_metadata
        cat <<EOF
<table>
<caption>${title}</caption>
<thead><tr><th>Source NEVRA</th><th>Target NEVRA</th><th>Name</th><th>Epoch</th><th>Version</th><th>Source Release</th><th>Target Release</th><th>Arch</th><th>Status</th></tr></thead>
<tbody>
EOF
        awk -F '\t' '
        function esc(value) {
            gsub(/&/, "\\&amp;", value)
            gsub(/</, "\\&lt;", value)
            gsub(/>/, "\\&gt;", value)
            gsub(/"/, "\\&quot;", value)
            return value
        }
        NR > 1 {
            print "<tr>"
            for (i = 1; i <= 9; i++) {
                print "<td>" esc($i) "</td>"
            }
            print "</tr>"
        }' "$input"
        cat <<EOF
</tbody>
</table>
</body>
</html>
EOF
    } > "$output"
}

write_html_metadata() {
    local hostname_file="${STATE_DIR}/hostname"
    local source_release_file="${STATE_DIR}/os-release.before"
    local target_release_file="${STATE_DIR}/os-release.after"
    local rpmdb_after_file="${STATE_DIR}/rpmdb.after.tsv"

    cat <<EOF
<table class="release-meta">
<tbody>
<tr><th>Hostname</th><td><pre>
EOF
    if [[ -s "$hostname_file" ]]; then
        awk '
        function esc(value) {
            gsub(/&/, "\\&amp;", value)
            gsub(/</, "\\&lt;", value)
            gsub(/>/, "\\&gt;", value)
            return value
        }
        { print esc($0) }' "$hostname_file"
    else
        printf 'Not available\n'
    fi
    cat <<EOF
</pre></td></tr>
<tr><th>Source Enterprise Linux release</th><td><pre>
EOF
    if [[ -s "$source_release_file" ]]; then
        awk '
        function esc(value) {
            gsub(/&/, "\\&amp;", value)
            gsub(/</, "\\&lt;", value)
            gsub(/>/, "\\&gt;", value)
            return value
        }
        { print esc($0) }' "$source_release_file"
    else
        printf 'Not available\n'
    fi
    cat <<EOF
</pre></td></tr>
<tr><th>Target Enterprise Linux release</th><td><pre>
EOF
    if [[ -s "$target_release_file" ]]; then
        awk '
        function esc(value) {
            gsub(/&/, "\\&amp;", value)
            gsub(/</, "\\&lt;", value)
            gsub(/>/, "\\&gt;", value)
            return value
        }
        { print esc($0) }' "$target_release_file"
    else
        printf 'Not available: migration has not completed in this report context.\n'
    fi
    cat <<EOF
</pre></td></tr>
<tr><th>Architecture</th><td>${BASEARCH}</td></tr>
<tr><th>Kernel flavor selected</th><td>${KERNEL_FLAVOR}</td></tr>
<tr><th>Migration Time</th><td>$(migration_duration_hms)</td></tr>
EOF
    if [[ -s "$rpmdb_after_file" ]]; then
        awk -F '\t' '
        function esc(value) {
            gsub(/&/, "\\&amp;", value)
            gsub(/</, "\\&lt;", value)
            gsub(/>/, "\\&gt;", value)
            return value
        }
        {
            vendor = $6
            if (vendor == "") {
                vendor = "Unknown vendor"
            }
            counts[vendor]++
        }
        END {
            oracle_count = counts["Oracle America"] + 0
            print "<tr><th>Number of packages from Oracle America</th><td>" oracle_count "</td></tr>"
            for (vendor in counts) {
                if (vendor != "Oracle America") {
                    print "<tr><th>Number of packages from " esc(vendor) "</th><td>" counts[vendor] "</td></tr>"
                }
            }
        }' "$rpmdb_after_file"
    else
        cat <<EOF
<tr><th>Number of packages from Oracle America</th><td>Not available: migration has not completed in this report context.</td></tr>
EOF
    fi
    cat <<EOF
</tbody>
</table>
EOF
}

generate_html_reports() {
    local exact_tsv="$1"
    local nearest_tsv="$2"
    local unavailable_tsv="$3"
    local available_tsv="${4:-}"

    write_html_report "RPMs Reinstalled With Identical Oracle Linux Releases" \
        "$exact_tsv" "${STATE_DIR}/reinstalled-oracle-exact.html"
    write_html_report "RPMs Reinstalled With Nearest Oracle Linux Release" \
        "$nearest_tsv" "${STATE_DIR}/reinstalled-oracle-nearest.html"
    write_html_report "RPMs Without Available Oracle Linux Replacement" \
        "$unavailable_tsv" "${STATE_DIR}/not-reinstalled-oracle.html"

    if [[ -n "$available_tsv" ]]; then
        generate_same_release_html_report "$exact_tsv" "$nearest_tsv" "$unavailable_tsv" "$available_tsv"
    fi
}

regenerate_preserve_release_reports() {
    local exact_tsv="${STATE_DIR}/exact-reinstall.tsv"
    local nearest_tsv="${STATE_DIR}/nearest-reinstall.tsv"
    local unavailable_tsv="${STATE_DIR}/unavailable-reinstall.tsv"
    local available_tsv="${STATE_DIR}/oracle.available.tsv"

    if [[ -f "$exact_tsv" && -f "$nearest_tsv" && -f "$unavailable_tsv" && -f "$available_tsv" ]]; then
        info "regenerating same-release HTML reports with final target release metadata"
        generate_html_reports "$exact_tsv" "$nearest_tsv" "$unavailable_tsv" "$available_tsv"
    fi
}

generate_same_release_html_report() {
    local exact_tsv="$1"
    local nearest_tsv="$2"
    local unavailable_tsv="$3"
    local available_tsv="$4"
    local removed_tsv="${STATE_DIR}/rhel-only-packages.removed.tsv"
    local rpmdb_after_tsv="${STATE_DIR}/rpmdb.after.tsv"
    local final_rpmdb_available=0
    local output_tsv="${STATE_DIR}/migration-rpm-map.tsv"
    local output_html="${STATE_DIR}/migration-rpm-map.html"

    if [[ ! -f "$removed_tsv" ]]; then
        printf 'source_nevra\ttarget_nevra\tname\tepoch\tversion\tsource_release\ttarget_release\tarch\tstatus\n' > "$removed_tsv"
    fi

    [[ -f "$rpmdb_after_tsv" ]] && final_rpmdb_available=1

    awk -F '\t' -v exact_tsv="$exact_tsv" -v nearest_tsv="$nearest_tsv" -v removed_tsv="$removed_tsv" -v unavailable_tsv="$unavailable_tsv" -v rpmdb_after_tsv="$rpmdb_after_tsv" -v final_rpmdb_available="$final_rpmdb_available" -v output_tsv="$output_tsv" -v source_major="$SOURCE_MAJOR" '
        function normalize_epoch(epoch) {
            return (epoch == "" || epoch == "(none)") ? 0 : epoch
        }
        function nevra(name, epoch, version, release, arch) {
            epoch = normalize_epoch(epoch)
            return name "-" (epoch > 0 ? epoch ":" : "") version "-" release "." arch
        }
        function append(list, value) {
            return list == "" ? value : list "; " value
        }
        function tokenize_release(value, tokens,    rest, n) {
            delete tokens
            rest = value
            n = 0
            while (match(rest, /[0-9]+|[A-Za-z]+/)) {
                tokens[++n] = substr(rest, RSTART, RLENGTH)
                rest = substr(rest, RSTART + RLENGTH)
            }
            return n
        }
        function compare_release(left, right,    left_parts, right_parts, left_count, right_count, idx, left_token, right_token, left_numeric, right_numeric) {
            left_count = tokenize_release(left, left_parts)
            right_count = tokenize_release(right, right_parts)
            for (idx = 1; idx <= left_count || idx <= right_count; idx++) {
                if (idx > left_count) {
                    return -1
                }
                if (idx > right_count) {
                    return 1
                }
                left_token = left_parts[idx]
                right_token = right_parts[idx]
                left_numeric = left_token ~ /^[0-9]+$/
                right_numeric = right_token ~ /^[0-9]+$/
                if (left_numeric && right_numeric) {
                    left_token += 0
                    right_token += 0
                    if (left_token < right_token) {
                        return -1
                    }
                    if (left_token > right_token) {
                        return 1
                    }
                } else if (left_numeric != right_numeric) {
                    return left_numeric ? 1 : -1
                } else {
                    if (left_token < right_token) {
                        return -1
                    }
                    if (left_token > right_token) {
                        return 1
                    }
                }
            }
            return 0
        }
        function compare_evr(left_epoch, left_version, left_release, right_epoch, right_version, right_release,    version_cmp) {
            left_epoch = normalize_epoch(left_epoch)
            right_epoch = normalize_epoch(right_epoch)
            if (left_epoch < right_epoch) {
                return -1
            }
            if (left_epoch > right_epoch) {
                return 1
            }
            version_cmp = compare_release(left_version, right_version)
            if (version_cmp != 0) {
                return version_cmp
            }
            return compare_release(left_release, right_release)
        }
        function is_source_release_package(name) {
            return name ~ /^(almalinux|centos|centos-linux|centos-stream|redhat|rocky)-(release|repos|gpg-keys)$/ || name == "redhat-release" || name ~ /^(amazon-linux-(extras|repo-(cdn|s3))|system-release(-cpe)?)$/
        }
        function is_oracle_release_package(name) {
            return name == "oraclelinux-release" || name ~ /^oraclelinux-release-el[0-9]+$/ || name == "redhat-release"
        }
        function is_rhel_only_removed_package(name) {
            return name == "gpg-pubkey" ||
                name == "insights-client" ||
                name == "kpatch" ||
                name == "kpatch-dnf" ||
                name == "dnf-plugin-subscription-manager" ||
                name == "libdnf-plugin-subscription-manager" ||
                name == "python-rhsm" ||
                name == "python-syspurpose" ||
                name == "python3-cloud-what" ||
                name == "python3-subscription-manager-rhsm" ||
                name == "python3-syspurpose" ||
                name ~ /^Red_Hat_Enterprise_Linux-Release_Notes-/ ||
                name == "rhc" ||
                name == "redhat-logos" ||
                name == "redhat-release-eula" ||
                name == "rhsm-icons" ||
                name == "redhat-support-lib-python" ||
                name == "redhat-support-tool" ||
                name == "subscription-manager" ||
                name == "subscription-manager-cockpit" ||
                name == "subscription-manager-rhsm" ||
                name == "subscription-manager-rhsm-certificates"
        }
        function is_amazon_only_removed_package(name) {
            return name == "amd-ucode-firmware" ||
                name == "amazon-linux-onprem" ||
                name == "amazon-ssm-agent" ||
                name == "awscli" ||
                name == "generic-logos" ||
                name == "cpp10" ||
                name == "gcc10" ||
                name ~ /^gcc10-/ ||
                name == "glibc-all-langpacks" ||
                name == "glibc-devel" ||
                name == "glibc-headers" ||
                name == "glibc-locale-source" ||
                name == "glibc-minimal-langpack" ||
                name == "iptables-libs" ||
                name == "isl" ||
                name == "kernel-devel" ||
                name == "kpatch-runtime" ||
                name == "libcrypt" ||
                name == "libctf" ||
                name == "libfdisk" ||
                name == "libidn2" ||
                name == "libmetalink" ||
                name == "libmpx" ||
                name == "libnghttp2" ||
                name == "libpsl" ||
                name == "libsanitizer" ||
                name == "publicsuffix-list-dafsa" ||
                name == "python-repoze-lru" ||
                name == "python2-botocore" ||
                name == "python2-colorama" ||
                name == "python2-dateutil" ||
                name == "python2-jmespath" ||
                name == "python2-jsonschema" ||
                name == "python2-rpm" ||
                name == "python2-rsa" ||
                name == "python2-s3transfer" ||
                name == "python2-setuptools" ||
                name == "python2-six" ||
                name == "sysctl-defaults" ||
                name == "update-motd" ||
                name == "vim-data" ||
                name == "xxd"
        }
        function is_el10_split_firmware_package(name) {
            if (source_major != "10") {
                return 0
            }
            return name == "amd-gpu-firmware" ||
                name == "amd-ucode-firmware" ||
                name == "atheros-firmware" ||
                name == "brcmfmac-firmware" ||
                name == "cirrus-audio-firmware" ||
                name == "intel-audio-firmware" ||
                name == "intel-gpu-firmware" ||
                name == "iwlwifi-dvm-firmware" ||
                name == "iwlwifi-mvm-firmware" ||
                name == "mt7xxx-firmware" ||
                name == "nxpwireless-firmware" ||
                name == "nvidia-gpu-firmware" ||
                name == "tiwilink-firmware" ||
                name == "realtek-firmware"
        }
        function is_oracle_vendor(vendor) {
            return vendor == "Oracle America"
        }
        function is_third_party_vendor(vendor) {
            return vendor != "" && !is_oracle_vendor(vendor) && vendor !~ /Red Hat/
        }
        function emit_row(source_nevra, target_nevra, name, epoch, version, source_release, target_release, arch, status) {
            print source_nevra "\t" target_nevra "\t" name "\t" epoch "\t" version "\t" source_release "\t" target_release "\t" arch "\t" status >> output_tsv
        }
        function copy_rows(input,    key, status) {
            while ((getline line < input) > 0) {
                if (line ~ /^source_nevra\t/) {
                    continue
                }
                split(line, fields, "\t")
                key = fields[3] SUBSEP fields[8]
                status = fields[9]
                if (status == "removed-rhel-only") {
                    print line >> output_tsv
                } else if (key in after_vendor && is_third_party_vendor(after_vendor[key])) {
                    status = "3rd Party"
                    emit_row(fields[1], fields[1], fields[3], fields[4], fields[5], fields[6], fields[6], fields[8], status)
                } else {
                    print line >> output_tsv
                }
            }
            close(input)
        }
        function load_final_rpmdb(    line, fields, key, candidate_nevra, cmp) {
            while ((getline line < rpmdb_after_tsv) > 0) {
                split(line, fields, "\t")
                if (fields[6] ~ /Red Hat/) {
                    continue
                }
                key = fields[1] SUBSEP fields[5]
                candidate_nevra = nevra(fields[1], fields[2], fields[3], fields[4], fields[5])
                if (fields[1] ~ /^linux-firmware/) {
                    firmware_targets = append(firmware_targets, candidate_nevra)
                }
                if (!(key in after_nevra)) {
                    after_nevra[key] = candidate_nevra
                    after_epoch[key] = fields[2]
                    after_version[key] = fields[3]
                    after_release[key] = fields[4]
                    after_vendor[key] = fields[6]
                    continue
                }
                cmp = compare_evr(fields[2], fields[3], fields[4], after_epoch[key], after_version[key], after_release[key])
                if (cmp > 0) {
                    after_nevra[key] = candidate_nevra
                    after_epoch[key] = fields[2]
                    after_version[key] = fields[3]
                    after_release[key] = fields[4]
                    after_vendor[key] = fields[6]
                }
            }
            close(rpmdb_after_tsv)
        }
        function reconciled_status(key, source_epoch, source_version, source_release,    relation) {
            relation = compare_evr(after_epoch[key], after_version[key], after_release[key], source_epoch, source_version, source_release)
            if (relation > 0) {
                return "nearest-higher-release"
            }
            if (relation < 0) {
                return "nearest-lower-release"
            }
            return "exact"
        }
        BEGIN {
            print "source_nevra\ttarget_nevra\tname\tepoch\tversion\tsource_release\ttarget_release\tarch\tstatus" > output_tsv
            if (final_rpmdb_available) {
                load_final_rpmdb()
            }
        }
        is_oracle_release_package($1) {
            oracle_release_targets = append(oracle_release_targets, $6)
        }
        END {
            copy_rows(exact_tsv)
            copy_rows(nearest_tsv)
            copy_rows(removed_tsv)
            while ((getline line < unavailable_tsv) > 0) {
                if (line ~ /^source_nevra\t/) {
                    continue
                }
                split(line, fields, "\t")
                if (is_source_release_package(fields[3]) && oracle_release_targets != "") {
                    fields[2] = oracle_release_targets
                    fields[9] = "replaced-distribution-package"
                    print fields[1] "\t" fields[2] "\t" fields[3] "\t" fields[4] "\t" fields[5] "\t" fields[6] "\t" fields[7] "\t" fields[8] "\t" fields[9] >> output_tsv
                } else if (is_el10_split_firmware_package(fields[3]) && firmware_targets != "") {
                    fields[2] = firmware_targets
                    fields[9] = "replaced-by-linux-firmware"
                    emit_row(fields[1], fields[2], fields[3], fields[4], fields[5], fields[6], fields[7], fields[8], fields[9])
                } else if (is_rhel_only_removed_package(fields[3])) {
                    fields[9] = "removed-rhel-only"
                    emit_row(fields[1], fields[2], fields[3], fields[4], fields[5], fields[6], fields[7], fields[8], fields[9])
                } else if (is_amazon_only_removed_package(fields[3])) {
                    fields[9] = "removed-amazon-only"
                    emit_row(fields[1], fields[2], fields[3], fields[4], fields[5], fields[6], fields[7], fields[8], fields[9])
                } else if ((fields[3] SUBSEP fields[8]) in after_nevra) {
                    key = fields[3] SUBSEP fields[8]
                    if (is_third_party_vendor(after_vendor[key])) {
                        fields[2] = fields[1]
                        fields[7] = fields[6]
                        fields[9] = "3rd Party"
                    } else {
                        fields[2] = after_nevra[key]
                        fields[7] = after_release[key]
                        fields[9] = reconciled_status(key, fields[4], fields[5], fields[6])
                    }
                    emit_row(fields[1], fields[2], fields[3], fields[4], fields[5], fields[6], fields[7], fields[8], fields[9])
                } else {
                    print line >> output_tsv
                }
            }
            close(unavailable_tsv)
        }
    ' "$available_tsv"

    write_colored_package_report "Same-Release RPM Migration Report" "$output_tsv" "$output_html"
}

write_colored_package_report() {
    local title="$1"
    local input="$2"
    local output="$3"

    {
        cat <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>${title}</title>
<style>
body { font-family: system-ui, sans-serif; margin: 2rem; color: #1f2933; }
table { border-collapse: collapse; width: 100%; }
th, td { border: 1px solid #cbd5e1; padding: 0.35rem 0.5rem; text-align: left; font-size: 0.9rem; vertical-align: top; }
th { background: #e5e7eb; }
caption { font-size: 1.2rem; font-weight: 700; margin-bottom: 1rem; text-align: left; }
.meta { margin-bottom: 1rem; color: #52606d; }
.release-meta { border: 1px solid #cbd5e1; margin-bottom: 1rem; }
.release-meta th { width: 16rem; vertical-align: top; }
.release-meta pre { margin: 0; white-space: pre-wrap; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 0.85rem; }
tr.exact { background: #dcfce7; }
tr.unavailable { background: #fee2e2; }
tr.nearest-higher-release { background: #fef9c3; }
tr.nearest-lower-release { background: #ffedd5; }
tr.third-party { background: #ffedd5; }
tr.replaced-distribution-package { background: #e0f2fe; }
tr.replaced-by-linux-firmware { background: #e0f2fe; }
tr.removed-rhel-only { background: #fee2e2; }
tr.removed-amazon-only { background: #fee2e2; }
.legend { margin-bottom: 1rem; display: flex; flex-wrap: wrap; gap: 0.75rem; color: #52606d; }
.legend span { border: 1px solid #cbd5e1; padding: 0.2rem 0.45rem; }
</style>
</head>
<body>
<div class="meta">Generated by ${PROGRAM_NAME} run ${RUN_ID}</div>
EOF
        write_html_metadata
        cat <<EOF
<div class="legend">
<span>exact: identical Oracle Linux NEVRA</span>
<span>nearest-higher-release: closest higher Oracle Linux package EVR</span>
<span>nearest-lower-release: lower Oracle Linux package EVR used only when no higher replacement exists</span>
<span>3rd Party: package retained from a non-Oracle third-party vendor</span>
<span>unavailable: no Oracle Linux replacement found</span>
<span>replaced-distribution-package: source release package replaced by Oracle Linux release packages</span>
<span>replaced-by-linux-firmware: EL10 split firmware package replaced by Oracle Linux linux-firmware packages</span>
<span>removed-rhel-only: RHEL-only source package or GPG pseudo-package intentionally removed by policy</span>
<span>removed-amazon-only: Amazon Linux 2-only package intentionally removed by policy</span>
</div>
<table>
<caption>${title}</caption>
<thead><tr><th>Source NEVRA</th><th>Target NEVRA</th><th>Name</th><th>Epoch</th><th>Version</th><th>Source Release</th><th>Target Release</th><th>Arch</th><th>Status</th></tr></thead>
<tbody>
EOF
        awk -F '\t' '
        function esc(value) {
            gsub(/&/, "\\&amp;", value)
            gsub(/</, "\\&lt;", value)
            gsub(/>/, "\\&gt;", value)
            gsub(/"/, "\\&quot;", value)
            return value
        }
        function status_class(status) {
            if (status == "3rd Party") {
                return "third-party"
            }
            return status
        }
        NR > 1 {
            row_class = esc(status_class($9))
            print "<tr class=\"" row_class "\">"
            for (i = 1; i <= 9; i++) {
                print "<td>" esc($i) "</td>"
            }
            print "</tr>"
        }' "$input"
        cat <<EOF
</tbody>
</table>
</body>
</html>
EOF
    } > "$output"
}

build_sync_report() {
    local output_tsv="${STATE_DIR}/migration-rpm-map.tsv"
    local output_html="${STATE_DIR}/migration-rpm-map.html"
    local vendor_regex

    vendor_regex="$(source_vendor_regex)" || vendor_regex='Red Hat'

    info "building RPM migration mapping report"
    awk -F '\t' -v output_tsv="$output_tsv" -v source_major="$SOURCE_MAJOR" -v source_vendor_regex="$vendor_regex" '
        function normalize_epoch(epoch) {
            return (epoch == "" || epoch == "(none)") ? 0 : epoch
        }
        function nevra(name, epoch, version, release, arch) {
            return name "-" (epoch > 0 ? epoch ":" : "") version "-" release "." arch
        }
        function append(list, value) {
            return list == "" ? value : list "; " value
        }
        function tokenize_release(value, tokens,    rest, n) {
            delete tokens
            rest = value
            n = 0
            while (match(rest, /[0-9]+|[A-Za-z]+/)) {
                tokens[++n] = substr(rest, RSTART, RLENGTH)
                rest = substr(rest, RSTART + RLENGTH)
            }
            return n
        }
        function compare_release(left, right,    left_parts, right_parts, left_count, right_count, idx, left_token, right_token, left_numeric, right_numeric) {
            left_count = tokenize_release(left, left_parts)
            right_count = tokenize_release(right, right_parts)
            for (idx = 1; idx <= left_count || idx <= right_count; idx++) {
                if (idx > left_count) {
                    return -1
                }
                if (idx > right_count) {
                    return 1
                }
                left_token = left_parts[idx]
                right_token = right_parts[idx]
                left_numeric = left_token ~ /^[0-9]+$/
                right_numeric = right_token ~ /^[0-9]+$/
                if (left_numeric && right_numeric) {
                    left_token += 0
                    right_token += 0
                    if (left_token < right_token) {
                        return -1
                    }
                    if (left_token > right_token) {
                        return 1
                    }
                } else if (left_numeric != right_numeric) {
                    return left_numeric ? 1 : -1
                } else {
                    if (left_token < right_token) {
                        return -1
                    }
                    if (left_token > right_token) {
                        return 1
                    }
                }
            }
            return 0
        }
        function compare_evr(left_epoch, left_version, left_release, right_epoch, right_version, right_release,    version_cmp) {
            left_epoch = normalize_epoch(left_epoch)
            right_epoch = normalize_epoch(right_epoch)
            if (left_epoch < right_epoch) {
                return -1
            }
            if (left_epoch > right_epoch) {
                return 1
            }
            version_cmp = compare_release(left_version, right_version)
            if (version_cmp != 0) {
                return version_cmp
            }
            return compare_release(left_release, right_release)
        }
        function mapped_status(source_nevra, key, source_epoch, source_version, source_release,    idx, best_idx, candidate_cmp, relation) {
            if (source_nevra in after_exact) {
                return "reinstalled; same release"
            }

            best_idx = 1
            for (idx = 2; idx <= after_count[key]; idx++) {
                candidate_cmp = compare_evr(after_epoch[key SUBSEP idx], after_version[key SUBSEP idx], after_release[key SUBSEP idx], after_epoch[key SUBSEP best_idx], after_version[key SUBSEP best_idx], after_release[key SUBSEP best_idx])
                if (candidate_cmp > 0) {
                    best_idx = idx
                }
            }

            relation = compare_evr(after_epoch[key SUBSEP best_idx], after_version[key SUBSEP best_idx], after_release[key SUBSEP best_idx], source_epoch, source_version, source_release)
            if (relation > 0) {
                return "updated"
            }
            if (relation < 0) {
                return "downgraded"
            }
            return "reinstalled; same release"
        }
        function best_name_key(name, source_epoch, source_version, source_release,    idx, candidate_key, best_key, candidate_cmp) {
            best_key = after_name_key[name SUBSEP 1]
            for (idx = 2; idx <= after_name_count[name]; idx++) {
                candidate_key = after_name_key[name SUBSEP idx]
                candidate_cmp = compare_evr(after_epoch[candidate_key SUBSEP 1], after_version[candidate_key SUBSEP 1], after_release[candidate_key SUBSEP 1], after_epoch[best_key SUBSEP 1], after_version[best_key SUBSEP 1], after_release[best_key SUBSEP 1])
                if (candidate_cmp > 0) {
                    best_key = candidate_key
                }
            }
            return best_key
        }
        function is_release_package(name) {
            return name ~ /^(almalinux|centos|centos-linux|centos-stream|redhat|rocky|oraclelinux)-(release|repos|gpg-keys)$/ || name ~ /^oraclelinux-release-el[0-9]+$/ || name == "redhat-release" || name ~ /^(amazon-linux-(extras|repo-(cdn|s3))|system-release(-cpe)?)$/
        }
        function is_rhel_only_removed_package(name) {
            return name == "gpg-pubkey" ||
                name == "insights-client" ||
                name == "kpatch" ||
                name == "kpatch-dnf" ||
                name == "dnf-plugin-subscription-manager" ||
                name == "libdnf-plugin-subscription-manager" ||
                name == "python-rhsm" ||
                name == "python-syspurpose" ||
                name == "python3-cloud-what" ||
                name == "python3-subscription-manager-rhsm" ||
                name == "python3-syspurpose" ||
                name ~ /^Red_Hat_Enterprise_Linux-Release_Notes-/ ||
                name == "rhc" ||
                name == "redhat-logos" ||
                name == "redhat-release-eula" ||
                name == "rhsm-icons" ||
                name == "redhat-support-lib-python" ||
                name == "redhat-support-tool" ||
                name == "subscription-manager" ||
                name == "subscription-manager-cockpit" ||
                name == "subscription-manager-rhsm" ||
                name == "subscription-manager-rhsm-certificates"
        }
        function is_amazon_only_removed_package(name) {
            return name == "amd-ucode-firmware" ||
                name == "amazon-linux-onprem" ||
                name == "amazon-ssm-agent" ||
                name == "awscli" ||
                name == "generic-logos" ||
                name == "cpp10" ||
                name == "gcc10" ||
                name ~ /^gcc10-/ ||
                name == "glibc-all-langpacks" ||
                name == "glibc-devel" ||
                name == "glibc-headers" ||
                name == "glibc-locale-source" ||
                name == "glibc-minimal-langpack" ||
                name == "iptables-libs" ||
                name == "isl" ||
                name == "kernel-devel" ||
                name == "kpatch-runtime" ||
                name == "libcrypt" ||
                name == "libctf" ||
                name == "libfdisk" ||
                name == "libidn2" ||
                name == "libmetalink" ||
                name == "libmpx" ||
                name == "libnghttp2" ||
                name == "libpsl" ||
                name == "libsanitizer" ||
                name == "publicsuffix-list-dafsa" ||
                name == "python-repoze-lru" ||
                name == "python2-botocore" ||
                name == "python2-colorama" ||
                name == "python2-dateutil" ||
                name == "python2-jmespath" ||
                name == "python2-jsonschema" ||
                name == "python2-rpm" ||
                name == "python2-rsa" ||
                name == "python2-s3transfer" ||
                name == "python2-setuptools" ||
                name == "python2-six" ||
                name == "sysctl-defaults" ||
                name == "update-motd" ||
                name == "vim-data" ||
                name == "xxd"
        }
        function is_el10_split_firmware_package(name) {
            if (source_major != "10") {
                return 0
            }
            return name == "amd-gpu-firmware" ||
                name == "amd-ucode-firmware" ||
                name == "atheros-firmware" ||
                name == "brcmfmac-firmware" ||
                name == "cirrus-audio-firmware" ||
                name == "intel-audio-firmware" ||
                name == "intel-gpu-firmware" ||
                name == "iwlwifi-dvm-firmware" ||
                name == "iwlwifi-mvm-firmware" ||
                name == "mt7xxx-firmware" ||
                name == "nxpwireless-firmware" ||
                name == "nvidia-gpu-firmware" ||
                name == "tiwilink-firmware" ||
                name == "realtek-firmware"
        }
        function is_source_runtime_kernel_package(name) {
            return name == "kernel" ||
                name == "kernel-core" ||
                name == "kernel-modules" ||
                name == "kernel-modules-core" ||
                name == "kernel-modules-extra" ||
                name == "kernel-uek" ||
                name == "kernel-uek-core" ||
                name == "kernel-uek-modules" ||
                name == "kernel-uek-modules-core" ||
                name == "kernel-uek-modules-extra"
        }
        function is_source_vendor_retained(source_vendor, target_vendor) {
            return source_vendor ~ source_vendor_regex && target_vendor ~ source_vendor_regex
        }
        function is_third_party_vendor(source_vendor, target_vendor) {
            return source_vendor !~ "(Oracle America|" source_vendor_regex ")" && target_vendor !~ "(Oracle America|" source_vendor_regex ")"
        }
        function status_class(status) {
            if (status == "skipped") {
                return "skipped"
            }
            if (status == "3rd Party") {
                return "third-party"
            }
            if (status == "source-vendor-retained") {
                return "source-vendor-retained"
            }
            if (status == "removed-rhel-only") {
                return "removed"
            }
            if (status == "removed-amazon-only") {
                return "removed"
            }
            if (status == "removed-source-kernel") {
                return "removed"
            }
            if (status == "replaced-distribution-package" || status == "replaced-by-linux-firmware") {
                return "replaced"
            }
            if (status == "updated") {
                return "updated"
            }
            if (status == "downgraded") {
                return "downgraded"
            }
            return "reinstalled-same-release"
        }
        function header() {
            print "source_nevra\ttarget_nevra\tname\tarch\tsource_vendor\ttarget_vendor\tstatus\tstatus_class" > output_tsv
        }
        BEGIN {
            header()
        }
        NR == FNR {
            name = $1
            epoch = $2
            version = $3
            release = $4
            arch = $5
            vendor = $6
            target_nevra = nevra(name, epoch, version, release, arch)
            key = name SUBSEP arch
            after_nevra[key] = append(after_nevra[key], target_nevra)
            after_vendor[key] = append(after_vendor[key], vendor)
            after_count[key]++
            after_epoch[key SUBSEP after_count[key]] = epoch
            after_version[key SUBSEP after_count[key]] = version
            after_release[key SUBSEP after_count[key]] = release
            if (!(key in after_key_seen_for_name)) {
                after_name_count[name]++
                after_name_key[name SUBSEP after_name_count[name]] = key
                after_key_seen_for_name[key] = 1
            }
            after_exact[target_nevra] = 1
            if (is_release_package(name)) {
                release_targets = append(release_targets, target_nevra)
                release_target_vendors = append(release_target_vendors, vendor)
            }
            if (name ~ /^linux-firmware/) {
                firmware_targets = append(firmware_targets, target_nevra)
                firmware_target_vendors = append(firmware_target_vendors, vendor)
            }
            next
        }
        {
            name = $1
            epoch = $2
            version = $3
            release = $4
            arch = $5
            vendor = $6
            source_nevra = nevra(name, epoch, version, release, arch)
            key = name SUBSEP arch
            target_key = key

            if (is_rhel_only_removed_package(name)) {
                status = "removed-rhel-only"
                print source_nevra "\t\t" name "\t" arch "\t" vendor "\t\t" status "\t" status_class(status) >> output_tsv
            } else if (is_amazon_only_removed_package(name)) {
                status = "removed-amazon-only"
                print source_nevra "\t\t" name "\t" arch "\t" vendor "\t\t" status "\t" status_class(status) >> output_tsv
            } else if (key in after_nevra) {
                if (is_third_party_vendor(vendor, after_vendor[key])) {
                    status = "3rd Party"
                } else if (is_source_vendor_retained(vendor, after_vendor[key])) {
                    status = "source-vendor-retained"
                } else {
                    status = mapped_status(source_nevra, key, epoch, version, release)
                }
                print source_nevra "\t" after_nevra[key] "\t" name "\t" arch "\t" vendor "\t" after_vendor[key] "\t" status "\t" status_class(status) >> output_tsv
            } else if (name in after_name_count) {
                target_key = best_name_key(name, epoch, version, release)
                if (is_third_party_vendor(vendor, after_vendor[target_key])) {
                    status = "3rd Party"
                } else if (is_source_vendor_retained(vendor, after_vendor[target_key])) {
                    status = "source-vendor-retained"
                } else {
                    status = mapped_status(source_nevra, target_key, epoch, version, release)
                }
                print source_nevra "\t" after_nevra[target_key] "\t" name "\t" arch "\t" vendor "\t" after_vendor[target_key] "\t" status "\t" status_class(status) >> output_tsv
            } else if (is_release_package(name) && release_targets != "") {
                status = "replaced-distribution-package"
                print source_nevra "\t" release_targets "\t" name "\t" arch "\t" vendor "\t" release_target_vendors "\t" status "\t" status_class(status) >> output_tsv
            } else if (is_el10_split_firmware_package(name) && firmware_targets != "") {
                status = "replaced-by-linux-firmware"
                print source_nevra "\t" firmware_targets "\t" name "\t" arch "\t" vendor "\t" firmware_target_vendors "\t" status "\t" status_class(status) >> output_tsv
            } else if (vendor ~ source_vendor_regex && is_source_runtime_kernel_package(name)) {
                status = "removed-source-kernel"
                print source_nevra "\t\t" name "\t" arch "\t" vendor "\t\t" status "\t" status_class(status) >> output_tsv
            } else {
                status = "skipped"
                print source_nevra "\t\t" name "\t" arch "\t" vendor "\t\t" status "\t" status_class(status) >> output_tsv
            }
        }
    ' "${STATE_DIR}/rpmdb.after.tsv" "${STATE_DIR}/rpmdb.before.tsv"

    write_sync_html_report "$output_tsv" "$output_html"
}

write_sync_html_report() {
    local input="$1"
    local output="$2"
    local title="RPM Migration Mapping"

    {
        cat <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>${title}</title>
<style>
body { font-family: system-ui, sans-serif; margin: 2rem; color: #1f2933; }
table { border-collapse: collapse; width: 100%; }
th, td { border: 1px solid #cbd5e1; padding: 0.35rem 0.5rem; text-align: left; font-size: 0.9rem; vertical-align: top; }
th { background: #e5e7eb; }
caption { font-size: 1.2rem; font-weight: 700; margin-bottom: 1rem; text-align: left; }
.meta { margin-bottom: 1rem; color: #52606d; }
.release-meta { border: 1px solid #cbd5e1; margin-bottom: 1rem; }
.release-meta th { width: 16rem; vertical-align: top; }
.release-meta pre { margin: 0; white-space: pre-wrap; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 0.85rem; }
tr.skipped { background: #fee2e2; }
tr.source-vendor-retained { background: #fee2e2; }
tr.replaced { background: #fef3c7; }
tr.updated { background: #dbeafe; }
tr.downgraded { background: #ffedd5; }
tr.third-party { background: #ffedd5; }
tr.reinstalled-same-release { background: #ecfdf5; }
tr.removed { background: #fee2e2; }
.legend { margin-bottom: 1rem; display: flex; flex-wrap: wrap; gap: 0.75rem; color: #52606d; }
.legend span { border: 1px solid #cbd5e1; padding: 0.2rem 0.45rem; }
</style>
</head>
<body>
<div class="meta">Generated by ${PROGRAM_NAME} run ${RUN_ID}</div>
EOF
        write_html_metadata
        cat <<EOF
<div class="legend">
<span>reinstalled; same release: same NEVRA installed after migration</span>
<span>updated: Oracle Linux package EVR is newer than the source package EVR</span>
<span>downgraded: Oracle Linux package EVR is older than the source package EVR</span>
<span>replaced-distribution-package: source release package replaced by Oracle Linux release packages</span>
<span>replaced-by-linux-firmware: EL10 split firmware package replaced by Oracle Linux linux-firmware packages</span>
<span>removed-rhel-only: RHEL-only source package or GPG pseudo-package intentionally removed by policy</span>
<span>removed-amazon-only: Amazon Linux 2-only package intentionally removed by policy</span>
<span>removed-source-kernel: source-vendor runtime kernel removed after selected Oracle kernel installation</span>
<span>source-vendor-retained: source-vendor RPM retained because no Oracle replacement was available</span>
<span>3rd Party: package retained from a non-Oracle third-party vendor</span>
<span>skipped: source RPM was unexpectedly not found after migration</span>
</div>
<table>
<caption>${title}</caption>
<thead><tr><th>Source NEVRA</th><th>Target NEVRA</th><th>Name</th><th>Arch</th><th>Source Vendor</th><th>Target Vendor</th><th>Status</th></tr></thead>
<tbody>
EOF
        awk -F '\t' '
        function esc(value) {
            gsub(/&/, "\\&amp;", value)
            gsub(/</, "\\&lt;", value)
            gsub(/>/, "\\&gt;", value)
            gsub(/"/, "\\&quot;", value)
            return value
        }
        NR > 1 {
            row_class = esc($8)
            print "<tr class=\"" row_class "\">"
            for (i = 1; i <= 7; i++) {
                print "<td>" esc($i) "</td>"
            }
            print "</tr>"
        }' "$input"
        cat <<EOF
</tbody>
</table>
</body>
</html>
EOF
    } > "$output"
}

reinstall_exact_packages() {
    local exact_nevra="${STATE_DIR}/exact-reinstall.nevra"
    local exact_standard_nevra="${STATE_DIR}/exact-standard-reinstall.nevra"
    if [[ ! -s "$exact_nevra" ]]; then
        warn "no exact package reinstall candidates were found"
        return 0
    fi
    if [[ ! -s "$exact_standard_nevra" ]]; then
        info "no standard exact package reinstall candidates were found"
        return 0
    fi

    info "reinstalling packages with exact matching NEVRAs from Oracle repositories"
    if (( DRY_RUN )); then
        info "dry-run: would reinstall $(wc -l < "$exact_standard_nevra" | tr -d ' ') standard exact packages"
        return 0
    fi

    xargs -r -a "$exact_standard_nevra" -n 80 "$DNF_CMD" -y \
        "${DNF_BASE_ARGS[@]}" \
        "${ORACLE_REPO_ARGS[@]}" \
        ${ORACLE_TARGET_EXCLUDE_ARGS[@]+"${ORACLE_TARGET_EXCLUDE_ARGS[@]}"} \
        reinstall 2>&1 | tee -a "$LOG_FILE"
}

reinstall_nearest_packages() {
    local nearest_higher_nevra="${STATE_DIR}/nearest-higher-reinstall.nevra"
    local nearest_higher_standard_nevra="${STATE_DIR}/nearest-higher-standard-reinstall.nevra"
    local nearest_lower_nevra="${STATE_DIR}/nearest-lower-reinstall.nevra"
    [[ -s "$nearest_higher_nevra" || -s "$nearest_lower_nevra" ]] || return 0

    info "installing nearest-release Oracle replacements"
    if (( DRY_RUN )); then
        if [[ -s "$nearest_higher_standard_nevra" ]]; then
            info "dry-run: would install $(wc -l < "$nearest_higher_standard_nevra" | tr -d ' ') standard nearest higher-release replacement packages"
        fi
        if [[ -s "$nearest_lower_nevra" ]]; then
            info "dry-run: would downgrade $(wc -l < "$nearest_lower_nevra" | tr -d ' ') nearest lower-release replacement packages"
        fi
        return 0
    fi

    if [[ -s "$nearest_higher_standard_nevra" ]]; then
        if [[ "$DNF_CMD" == "dnf" ]]; then
            xargs -r -a "$nearest_higher_standard_nevra" -n 80 "$DNF_CMD" -y \
                "${DNF_BASE_ARGS[@]}" \
                "${ORACLE_REPO_ARGS[@]}" \
                ${ORACLE_TARGET_EXCLUDE_ARGS[@]+"${ORACLE_TARGET_EXCLUDE_ARGS[@]}"} \
                --nobest \
                --skip-broken \
                install 2>&1 | tee -a "$LOG_FILE"
        else
            xargs -r -a "$nearest_higher_standard_nevra" -n 80 "$DNF_CMD" -y \
                "${DNF_BASE_ARGS[@]}" \
                "${ORACLE_REPO_ARGS[@]}" \
                ${ORACLE_TARGET_EXCLUDE_ARGS[@]+"${ORACLE_TARGET_EXCLUDE_ARGS[@]}"} \
                install 2>&1 | tee -a "$LOG_FILE"
        fi
    fi

    if [[ -s "$nearest_lower_nevra" ]]; then
        if [[ "$DNF_CMD" == "dnf" ]]; then
            xargs -r -a "$nearest_lower_nevra" -n 80 "$DNF_CMD" -y \
                "${DNF_BASE_ARGS[@]}" \
                "${ORACLE_REPO_ARGS[@]}" \
                ${ORACLE_TARGET_EXCLUDE_ARGS[@]+"${ORACLE_TARGET_EXCLUDE_ARGS[@]}"} \
                --skip-broken \
                downgrade 2>&1 | tee -a "$LOG_FILE"
        else
            xargs -r -a "$nearest_lower_nevra" -n 80 "$DNF_CMD" -y \
                "${DNF_BASE_ARGS[@]}" \
                "${ORACLE_REPO_ARGS[@]}" \
                ${ORACLE_TARGET_EXCLUDE_ARGS[@]+"${ORACLE_TARGET_EXCLUDE_ARGS[@]}"} \
                downgrade 2>&1 | tee -a "$LOG_FILE"
        fi
    fi
}

install_update_exception_packages() {
    local update_exception_nevra="${STATE_DIR}/update-exception-reinstall.nevra"
    [[ -s "$update_exception_nevra" ]] || return 0

    info "installing update-only Oracle replacements for tzdata and ca-certificates"
    if (( DRY_RUN )); then
        info "dry-run: would install $(wc -l < "$update_exception_nevra" | tr -d ' ') update-only exception packages"
        return 0
    fi

    xargs -r -a "$update_exception_nevra" -n 80 "$DNF_CMD" -y \
        "${DNF_BASE_ARGS[@]}" \
        "${ORACLE_REPO_ARGS[@]}" \
        "--enablerepo=ol${SOURCE_MAJOR}_baseos_exception_latest" \
        install 2>&1 | tee -a "$LOG_FILE"

    xargs -r -a "$update_exception_nevra" -n 80 "$DNF_CMD" -y \
        "${DNF_BASE_ARGS[@]}" \
        "${ORACLE_REPO_ARGS[@]}" \
        "--enablerepo=ol${SOURCE_MAJOR}_baseos_exception_latest" \
        reinstall 2>&1 | tee -a "$LOG_FILE"
}

install_uek_firmware_exception() {
    [[ "$KERNEL_FLAVOR" == "uek" ]] || return 0
    [[ "$SOURCE_MAJOR" == "7" ]] && return 0

    info "installing latest Oracle Linux firmware required by UEK modules"
    if (( DRY_RUN )); then
        info "dry-run: would install linux-firmware from Oracle Linux ${SOURCE_MAJOR} BaseOS latest"
        return 0
    fi

    run "$DNF_CMD" -y \
        "${DNF_BASE_ARGS[@]}" \
        "${ORACLE_REPO_ARGS[@]}" \
        "--enablerepo=ol${SOURCE_MAJOR}_baseos_exception_latest" \
        install linux-firmware
}

is_runtime_kernel_package_name() {
    case "$1" in
        kernel|kernel-core|kernel-modules|kernel-modules-core|kernel-modules-extra|\
        kernel-uek|kernel-uek-core|kernel-uek-modules|kernel-uek-modules-core|kernel-uek-modules-extra)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_selected_kernel_flavor_package_name() {
    if [[ "$KERNEL_FLAVOR" == "uek" ]]; then
        [[ "$1" == kernel-uek || "$1" == kernel-uek-* ]]
        return
    fi

    [[ "$1" == kernel || "$1" == kernel-* ]] && [[ "$1" != kernel-uek && "$1" != kernel-uek-* ]]
}

is_oracle_vendor() {
    [[ "$1" =~ Oracle[[:space:]]+America ]]
}

source_vendor_regex() {
    case "$SOURCE_FAMILY" in
        rhel)
            printf 'Red Hat'
            ;;
        amazon-linux)
            printf 'Amazon|Amazon.com|Amazon Linux'
            ;;
        centos-linux|centos-stream)
            printf '^CentOS$'
            ;;
        almalinux)
            printf 'AlmaLinux'
            ;;
        rocky)
            printf 'Rocky'
            ;;
        *)
            return 1
            ;;
    esac
}

remove_nonrunning_runtime_kernels() {
    local running_kernel remove_list=()
    local name nvra kernel_version vendor

    running_kernel="$(uname -r)"

    while IFS=$'\t' read -r name nvra kernel_version vendor; do
        [[ -n "$name" && -n "$nvra" && -n "$kernel_version" ]] || continue
        is_runtime_kernel_package_name "$name" || continue
        [[ "$kernel_version" != "$running_kernel" ]] || continue
        if is_selected_kernel_flavor_package_name "$name" && is_oracle_vendor "$vendor"; then
            continue
        fi
        remove_list+=("$nvra")
    done < <(rpm -qa --qf '%{NAME}\t%{NVRA}\t%{VERSION}-%{RELEASE}.%{ARCH}\t%{VENDOR}\n' | sort -u)

    if [[ "${#remove_list[@]}" -eq 0 ]]; then
        info "no non-running runtime kernel packages need removal before selected kernel install"
        return 0
    fi

    info "removing non-running runtime kernel packages to free /boot space: ${remove_list[*]}"
    run rpm -e --nodeps "${remove_list[@]}"
}

remove_source_vendor_runtime_kernels() {
    local vendor_regex

    vendor_regex="$(source_vendor_regex)" || return 0

    local remove_list=()
    local name nvra vendor

    while IFS=$'\t' read -r name nvra vendor; do
        [[ -n "$name" && -n "$nvra" ]] || continue
        is_runtime_kernel_package_name "$name" || continue
        [[ "$vendor" =~ $vendor_regex ]] || continue
        remove_list+=("$nvra")
    done < <(rpm -qa --qf '%{NAME}\t%{NVRA}\t%{VENDOR}\n' | sort -u)

    if [[ "${#remove_list[@]}" -eq 0 ]]; then
        info "no remaining source-vendor runtime kernel packages need removal"
        return 0
    fi

    info "removing source-vendor runtime kernel packages after selected Oracle kernel install: ${remove_list[*]}"
    run rpm -e --nodeps "${remove_list[@]}"
}

distro_sync_oracle() {
    case "$MIGRATION_MODE" in
        preserve-release)
            info "skipping broad Oracle Linux distro-sync in preserve-release mode"
            return 0
            ;;
        release-sync)
            info "syncing all installed RPMs to Oracle Linux ${EFFECTIVE_TARGET_VERSION}"
            ;;
        latest-sync)
            info "syncing all installed RPMs to the latest Oracle Linux ${SOURCE_MAJOR} packages"
            ;;
    esac
    if [[ "$DNF_CMD" == "dnf" ]]; then
        run "$DNF_CMD" -y \
            "${DNF_BASE_ARGS[@]}" \
            "${ORACLE_REPO_ARGS[@]}" \
            ${ORACLE_TARGET_EXCLUDE_ARGS[@]+"${ORACLE_TARGET_EXCLUDE_ARGS[@]}"} \
            --nobest \
            distro-sync
    else
        if [[ "$SOURCE_FAMILY" == "amazon-linux" && -s "${STATE_DIR}/amazon-compat-libcrypt.path" ]]; then
            local compat_lib_dir compat_python_dir python_path_value
            compat_lib_dir="$(<"${STATE_DIR}/amazon-compat-libcrypt.path")"
            python_path_value="${PYTHONPATH:-}"
            if [[ -s "${STATE_DIR}/amazon-compat-python.path" ]]; then
                compat_python_dir="$(<"${STATE_DIR}/amazon-compat-python.path")"
                python_path_value="${compat_python_dir}${python_path_value:+:${python_path_value}}"
            fi
            run env "LD_LIBRARY_PATH=${compat_lib_dir}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
                "PYTHONPATH=${python_path_value}" \
                "$DNF_CMD" -y \
                "${DNF_BASE_ARGS[@]}" \
                "${ORACLE_REPO_ARGS[@]}" \
                ${ORACLE_TARGET_EXCLUDE_ARGS[@]+"${ORACLE_TARGET_EXCLUDE_ARGS[@]}"} \
                distro-sync
        else
            run "$DNF_CMD" -y \
                "${DNF_BASE_ARGS[@]}" \
                "${ORACLE_REPO_ARGS[@]}" \
                ${ORACLE_TARGET_EXCLUDE_ARGS[@]+"${ORACLE_TARGET_EXCLUDE_ARGS[@]}"} \
                distro-sync
        fi
    fi
}

replace_source_vendor_packages() {
    local vendor_regex

    vendor_regex="$(source_vendor_regex)" || return 0

    local available_tsv="${STATE_DIR}/oracle.available.post-sync.tsv"
    local redhat_tsv="${STATE_DIR}/redhat-vendor-packages.after-sync.tsv"
    local reinstall_nevra="${STATE_DIR}/redhat-vendor-oracle-reinstall.nevra"
    local replacement_install_nevra="${STATE_DIR}/redhat-vendor-oracle-replacement-install.nevra"
    local replacement_preremove_nvra="${STATE_DIR}/redhat-vendor-source-preremoval.nvra"
    local replacement_remove_nvra="${STATE_DIR}/redhat-vendor-source-removal.nvra"
    local replacement_still_installed_nvra="${STATE_DIR}/redhat-vendor-source-removal.still-installed.nvra"
    local replacement_remove_tsv="${STATE_DIR}/redhat-vendor-source-removal.tsv"
    local unavailable_tsv="${STATE_DIR}/redhat-vendor-oracle-unavailable.tsv"
    local remaining_tsv="${STATE_DIR}/redhat-vendor-packages.after-reinstall.tsv"
    local remaining_after_exact_tsv="${STATE_DIR}/redhat-vendor-packages.after-exact-reinstall.tsv"
    local installed_nvra="${STATE_DIR}/installed.after-source-vendor-replacement.nvra"

    info "checking for installed RPMs still signed by the source vendor"
    rpm -qa --qf '%{NAME}\t%{EPOCHNUM}\t%{VERSION}\t%{RELEASE}\t%{ARCH}\t%{VENDOR}\n' | awk -F '\t' -v vendor_regex="$vendor_regex" '
        BEGIN { IGNORECASE = 1 }
        $6 ~ vendor_regex {
            print
        }
    ' | sort -u > "$redhat_tsv"

    if [[ ! -s "$redhat_tsv" ]]; then
        info "no remaining source-vendor RPMs detected"
        : > "$reinstall_nevra"
        printf 'source_nevra\tname\tepoch\tversion\trelease\tarch\tvendor\tstatus\n' > "$unavailable_tsv"
        return 0
    fi

    repoquery_available_packages "$available_tsv"
    : > "$reinstall_nevra"
    awk -F '\t' -v reinstall_nevra="$reinstall_nevra" -v unavailable_tsv="$unavailable_tsv" '
        function normalize_epoch(epoch) {
            return (epoch == "" || epoch == "(none)") ? 0 : epoch
        }
        function nevra(name, epoch, version, release, arch) {
            return name "-" (epoch > 0 ? epoch ":" : "") version "-" release "." arch
        }
        BEGIN {
            print "source_nevra\tname\tepoch\tversion\trelease\tarch\tvendor\tstatus" > unavailable_tsv
        }
        NR == FNR {
            epoch = normalize_epoch($2)
            available[$1 SUBSEP epoch SUBSEP $3 SUBSEP $4 SUBSEP $5] = $6
            next
        }
        {
            epoch = normalize_epoch($2)
            key = $1 SUBSEP epoch SUBSEP $3 SUBSEP $4 SUBSEP $5
            source = nevra($1, epoch, $3, $4, $5)
            if (key in available) {
                print available[key] >> reinstall_nevra
            } else {
                print source "\t" $1 "\t" epoch "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\tsource-vendor-retained" >> unavailable_tsv
            }
        }
    ' "$available_tsv" "$redhat_tsv"
    sort -u "$reinstall_nevra" -o "$reinstall_nevra"

    if [[ -s "$reinstall_nevra" ]]; then
        info "reinstalling $(wc -l < "$reinstall_nevra" | tr -d ' ') source-vendor RPMs from Oracle repositories"
        xargs -r -a "$reinstall_nevra" -n 80 "$DNF_CMD" -y \
            "${DNF_BASE_ARGS[@]}" \
            "${ORACLE_REPO_ARGS[@]}" \
            ${ORACLE_TARGET_EXCLUDE_ARGS[@]+"${ORACLE_TARGET_EXCLUDE_ARGS[@]}"} \
            reinstall 2>&1 | tee -a "$LOG_FILE"
    fi

    rpm -qa --qf '%{NAME}\t%{NVRA}\t%{EPOCHNUM}\t%{VERSION}\t%{RELEASE}\t%{ARCH}\t%{VENDOR}\n' | awk -F '\t' -v vendor_regex="$vendor_regex" '
        BEGIN { IGNORECASE = 1 }
        $7 ~ vendor_regex {
            print
        }
    ' | sort -u > "$remaining_after_exact_tsv"

    : > "$replacement_install_nevra"
    : > "$replacement_preremove_nvra"
    : > "$replacement_remove_nvra"
    awk -F '\t' -v install_nevra="$replacement_install_nevra" -v preremove_nvra="$replacement_preremove_nvra" -v remove_nvra="$replacement_remove_nvra" -v remove_tsv="$replacement_remove_tsv" -v unavailable_tsv="$unavailable_tsv" '
        function normalize_epoch(epoch) {
            return (epoch == "" || epoch == "(none)") ? 0 : epoch
        }
        function nevra(name, epoch, version, release, arch) {
            return name "-" (epoch > 0 ? epoch ":" : "") version "-" release "." arch
        }
        function tokenize_release(value, tokens,    rest, n) {
            delete tokens
            rest = value
            n = 0
            while (match(rest, /[0-9]+|[A-Za-z]+/)) {
                tokens[++n] = substr(rest, RSTART, RLENGTH)
                rest = substr(rest, RSTART + RLENGTH)
            }
            return n
        }
        function compare_release(left, right,    left_parts, right_parts, left_count, right_count, idx, left_token, right_token, left_numeric, right_numeric) {
            left_count = tokenize_release(left, left_parts)
            right_count = tokenize_release(right, right_parts)
            for (idx = 1; idx <= left_count || idx <= right_count; idx++) {
                if (idx > left_count) {
                    return -1
                }
                if (idx > right_count) {
                    return 1
                }
                left_token = left_parts[idx]
                right_token = right_parts[idx]
                left_numeric = left_token ~ /^[0-9]+$/
                right_numeric = right_token ~ /^[0-9]+$/
                if (left_numeric && right_numeric) {
                    left_token += 0
                    right_token += 0
                    if (left_token < right_token) {
                        return -1
                    }
                    if (left_token > right_token) {
                        return 1
                    }
                } else if (left_numeric != right_numeric) {
                    return left_numeric ? 1 : -1
                } else {
                    if (left_token < right_token) {
                        return -1
                    }
                    if (left_token > right_token) {
                        return 1
                    }
                }
            }
            return 0
        }
        function compare_evr(left_version, left_release, right_version, right_release,    version_cmp) {
            version_cmp = compare_release(left_version, right_version)
            if (version_cmp != 0) {
                return version_cmp
            }
            return compare_release(left_release, right_release)
        }
        function common_prefix_len(left, right,    i, max) {
            max = length(left) < length(right) ? length(left) : length(right)
            for (i = 1; i <= max; i++) {
                if (substr(left, i, 1) != substr(right, i, 1)) {
                    return i - 1
                }
            }
            return max
        }
        function is_better_candidate(source_version, source_release, candidate_version, candidate_release, best_version, best_release,    direction, best_direction, candidate_cmp, prefix, best_prefix) {
            direction = compare_evr(candidate_version, candidate_release, source_version, source_release)
            if (best_release == "") {
                return 1
            }

            best_direction = compare_evr(best_version, best_release, source_version, source_release)
            if (direction > 0 && best_direction < 0) {
                return 1
            }
            if (direction < 0 && best_direction > 0) {
                return 0
            }

            candidate_cmp = compare_evr(candidate_version, candidate_release, best_version, best_release)
            if (direction >= 0) {
                if (candidate_cmp < 0) {
                    return 1
                }
                if (candidate_cmp > 0) {
                    return 0
                }
            } else {
                if (candidate_cmp > 0) {
                    return 1
                }
                if (candidate_cmp < 0) {
                    return 0
                }
            }

            prefix = common_prefix_len(source_version "-" source_release, candidate_version "-" candidate_release)
            best_prefix = common_prefix_len(source_version "-" source_release, best_version "-" best_release)
            return prefix > best_prefix
        }
        BEGIN {
            print "source_nevra\tname\tepoch\tversion\trelease\tarch\tvendor\tstatus" > unavailable_tsv
            print "source_nvra\ttarget_nevra\tname\tepoch\tversion\tsource_release\ttarget_release\tarch\tstatus" > remove_tsv
        }
        function replacement_name(name) {
            if (name == "centos-logos") {
                return "oracle-logos"
            }
            return name
        }
        NR == FNR {
            epoch = normalize_epoch($2)
            group = $1 SUBSEP $5
            candidate_count[group]++
            available_versions[group SUBSEP candidate_count[group]] = $3
            available_releases[group SUBSEP candidate_count[group]] = $4
            available_nevras[group SUBSEP candidate_count[group]] = $6
            next
        }
        {
            name = $1
            nvra = $2
            epoch = normalize_epoch($3)
            version = $4
            release = $5
            arch = $6
            vendor = $7
            target_name = replacement_name(name)
            group = target_name SUBSEP arch
            best_version = ""
            best_release = ""
            best_idx = 0
            for (idx = 1; idx <= candidate_count[group]; idx++) {
                candidate_version = available_versions[group SUBSEP idx]
                candidate_release = available_releases[group SUBSEP idx]
                if (is_better_candidate(version, release, candidate_version, candidate_release, best_version, best_release)) {
                    best_version = candidate_version
                    best_release = candidate_release
                    best_idx = idx
                }
            }
            source = nevra(name, epoch, version, release, arch)
            if (best_idx > 0) {
                target = available_nevras[group SUBSEP best_idx]
                print target >> install_nevra
                if (target_name != name || compare_evr(best_version, best_release, version, release) < 0) {
                    print nvra >> preremove_nvra
                } else {
                    print nvra >> remove_nvra
                }
                print nvra "\t" target "\t" name "\t" epoch "\t" version "\t" release "\t" best_release "\t" arch "\treplaced-source-vendor" >> remove_tsv
            } else {
                print source "\t" name "\t" epoch "\t" version "\t" release "\t" arch "\t" vendor "\tsource-vendor-retained" >> unavailable_tsv
            }
        }
    ' "$available_tsv" "$remaining_after_exact_tsv"
    sort -u "$replacement_install_nevra" -o "$replacement_install_nevra"
    sort -u "$replacement_preremove_nvra" -o "$replacement_preremove_nvra"
    sort -u "$replacement_remove_nvra" -o "$replacement_remove_nvra"

    if [[ -s "$replacement_preremove_nvra" ]]; then
        rpm -qa --qf '%{NVRA}\n' | sort -u > "$installed_nvra"
        awk 'NR == FNR { installed[$0] = 1; next } installed[$0]' "$installed_nvra" "$replacement_preremove_nvra" > "$replacement_still_installed_nvra"
        if [[ -s "$replacement_still_installed_nvra" ]]; then
            info "removing $(wc -l < "$replacement_still_installed_nvra" | tr -d ' ') source-vendor RPM instances before cross-name Oracle replacement install"
            xargs -r -a "$replacement_still_installed_nvra" -n 80 rpm -e --nodeps 2>&1 | tee -a "$LOG_FILE"
        fi
    fi

    if [[ -s "$replacement_install_nevra" ]]; then
        info "installing $(wc -l < "$replacement_install_nevra" | tr -d ' ') Oracle replacements for remaining source-vendor RPMs"
        xargs -r -a "$replacement_install_nevra" -n 80 "$DNF_CMD" -y \
            "${DNF_BASE_ARGS[@]}" \
            "${ORACLE_REPO_ARGS[@]}" \
            ${ORACLE_TARGET_EXCLUDE_ARGS[@]+"${ORACLE_TARGET_EXCLUDE_ARGS[@]}"} \
            install 2>&1 | tee -a "$LOG_FILE"
    fi

    if [[ -s "$replacement_remove_nvra" ]]; then
        rpm -qa --qf '%{NVRA}\n' | sort -u > "$installed_nvra"
        awk 'NR == FNR { installed[$0] = 1; next } installed[$0]' "$installed_nvra" "$replacement_remove_nvra" > "$replacement_still_installed_nvra"
        if [[ -s "$replacement_still_installed_nvra" ]]; then
            info "removing $(wc -l < "$replacement_still_installed_nvra" | tr -d ' ') replaced source-vendor RPM instances"
            xargs -r -a "$replacement_still_installed_nvra" -n 80 rpm -e --nodeps 2>&1 | tee -a "$LOG_FILE"
        else
            info "all replaced source-vendor RPM instances were already removed by the package transaction"
        fi
    fi

    rpm -qa --qf '%{NAME}\t%{EPOCHNUM}\t%{VERSION}\t%{RELEASE}\t%{ARCH}\t%{VENDOR}\n' | awk -F '\t' -v vendor_regex="$vendor_regex" '
        BEGIN { IGNORECASE = 1 }
        $6 ~ vendor_regex {
            print
        }
    ' | sort -u > "$remaining_tsv"

    if [[ -s "$remaining_tsv" ]]; then
        warn "some RPMs are still from the source vendor after Oracle reinstall pass; they will be highlighted in the HTML report"
    else
        info "all replaceable source-vendor RPMs were reinstalled from Oracle repositories"
    fi
}

latest_installed_kernel_version() {
    local package="$1"
    local oracle_version

    oracle_version="$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\t%{VENDOR}\n' "$package" 2>/dev/null \
        | awk -F '\t' '$2 ~ /Oracle[[:space:]]+America/ { print $1 }' \
        | sort -V \
        | tail -n 1)"
    if [[ -n "$oracle_version" ]]; then
        printf '%s\n' "$oracle_version"
        return
    fi

    rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' "$package" 2>/dev/null | sort -V | tail -n 1
}

selected_kernel_package() {
    if [[ "$KERNEL_FLAVOR" == "uek" ]]; then
        printf 'kernel-uek\n'
        return
    fi

    if rpm -q kernel-core >/dev/null 2>&1; then
        printf 'kernel-core\n'
    else
        printf 'kernel\n'
    fi
}

install_selected_kernel() {
    local kernel_pkg packages

    printf '%s\n' "$KERNEL_FLAVOR" > "${STATE_DIR}/kernel-flavor.selected"

    if [[ "$KERNEL_FLAVOR" == "uek" ]]; then
        packages=(kernel-uek grubby)
        info "installing Oracle Linux UEK and boot default tooling"
        install_uek_firmware_exception
    else
        packages=(kernel grubby)
        info "installing Oracle Linux RHCK and boot default tooling"
    fi

    if [[ "$KERNEL_FLAVOR" == "uek" && "$DNF_CMD" == "dnf" ]]; then
        run "$DNF_CMD" -y \
            "${DNF_BASE_ARGS[@]}" \
            "${ORACLE_REPO_ARGS[@]}" \
            "--enablerepo=ol${SOURCE_MAJOR}_baseos_exception_latest" \
            --nobest \
            install "${packages[@]}"
    else
        run "$DNF_CMD" -y \
            "${DNF_BASE_ARGS[@]}" \
            "${ORACLE_REPO_ARGS[@]}" \
            ${ORACLE_TARGET_EXCLUDE_ARGS[@]+"${ORACLE_TARGET_EXCLUDE_ARGS[@]}"} \
            install "${packages[@]}"
    fi

    kernel_pkg="$(selected_kernel_package)"
    set_default_boot_kernel "$kernel_pkg"
}

reassert_selected_kernel_default() {
    local kernel_pkg

    kernel_pkg="$(selected_kernel_package)"
    info "reasserting selected ${KERNEL_FLAVOR} kernel as default boot kernel"
    set_default_boot_kernel "$kernel_pkg"
}

set_default_boot_kernel() {
    local kernel_pkg="$1"
    local kernel_version kernel_path

    if ! command -v grubby >/dev/null 2>&1; then
        warn "grubby is not available; cannot set default boot kernel"
        return 0
    fi

    kernel_version="$(latest_installed_kernel_version "$kernel_pkg")"
    if [[ -z "$kernel_version" ]]; then
        warn "could not determine installed ${kernel_pkg} version; cannot set default boot kernel"
        return 0
    fi

    kernel_path="/boot/vmlinuz-${kernel_version}"
    printf '%s\n' "$kernel_path" > "${STATE_DIR}/kernel-default.requested"
    if [[ ! -f "$kernel_path" ]]; then
        warn "kernel image ${kernel_path} is not present; skipping grubby default-kernel update"
        return 0
    fi

    info "+ grubby --set-default ${kernel_path}"
    if grubby --set-default "$kernel_path" 2>&1 | tee -a "$LOG_FILE"; then
        grubby --default-kernel > "${STATE_DIR}/kernel-default.after" 2>> "$LOG_FILE" || true
        info "default boot kernel set to ${kernel_path}"
    else
        warn "grubby could not set ${kernel_path} as the default boot kernel; continuing"
    fi
}

cleanup_bootstrap_repos() {
    (( KEEP_BOOTSTRAP_REPOS )) && return 0
    local repo_file="${STATE_DIR}/dnf.repos.d/oraclelinux-migration-bootstrap.repo"
    if [[ -f "$repo_file" ]]; then
        info "removing temporary bootstrap repo file"
        run rm -f "$repo_file"
    fi
}

verify_result() {
    info "collecting post-migration state"
    run_capture "${STATE_DIR}/os-release.after" cat /etc/os-release
    run_capture "${STATE_DIR}/rpmdb.after.tsv" rpm -qa --qf '%{NAME}\t%{EPOCHNUM}\t%{VERSION}\t%{RELEASE}\t%{ARCH}\t%{VENDOR}\t%{INSTALLTIME}\n'
    run_capture "${STATE_DIR}/rpmdb.after.nevra" rpm -qa --qf '%{nevra}\n'
    snapshot_enabled_repos "${STATE_DIR}/enabled-repos.after"

    if ! grep -Eq '^ID="?ol"?' /etc/os-release; then
        die "migration did not produce Oracle Linux /etc/os-release"
    fi

    if [[ -n "$EFFECTIVE_TARGET_VERSION" ]] && ! grep -Eq "^VERSION_ID=\"?${EFFECTIVE_TARGET_VERSION}\"?$" /etc/os-release; then
        die "migration did not produce target version ${EFFECTIVE_TARGET_VERSION} in /etc/os-release"
    fi

    if ! rpm -q "oraclelinux-release-el${SOURCE_MAJOR}" >/dev/null 2>&1; then
        die "oraclelinux-release-el${SOURCE_MAJOR} is not installed"
    fi

    verify_selected_kernel
    record_migration_end

    if [[ "$MIGRATION_MODE" == "preserve-release" ]]; then
        verify_evr_preservation
        regenerate_preserve_release_reports
    else
        info "skipping EVR preservation verification in ${MIGRATION_MODE} mode"
        build_sync_report
    fi

    info "migration verification completed"
}

strict_evr_filter() {
    awk -F '\t' '
        $1 !~ /^(almalinux|centos|centos-linux|centos-stream|redhat|rocky|oraclelinux)-(release|repos|gpg-keys)/ &&
        $1 !~ /^(amazon-linux-(extras|repo-(cdn|s3))|system-release(-cpe)?)$/ &&
        $1 !~ /^redhat-release/ &&
        $1 !~ /^kernel-uek/ &&
        $1 !~ /^linux-firmware/ &&
        $1 != "grubby" &&
        $1 != "numactl-libs" {
            print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5
        }
    ' "$1" | sort -u
}

verify_selected_kernel() {
    local kernel_pkg kernel_version kernel_path current_default

    kernel_pkg="$(selected_kernel_package)"
    if ! rpm -q "$kernel_pkg" >/dev/null 2>&1; then
        die "selected kernel package ${kernel_pkg} is not installed"
    fi

    kernel_version="$(latest_installed_kernel_version "$kernel_pkg")"
    if [[ -z "$kernel_version" ]]; then
        die "unable to determine installed selected kernel version for ${kernel_pkg}"
    fi

    kernel_path="/boot/vmlinuz-${kernel_version}"
    if command -v grubby >/dev/null 2>&1 && [[ -f "$kernel_path" ]]; then
        current_default="$(grubby --default-kernel 2>/dev/null || true)"
        printf '%s\n' "$current_default" > "${STATE_DIR}/kernel-default.verified"
        if [[ "$current_default" != "$kernel_path" ]]; then
            die "default boot kernel is ${current_default:-unknown}, expected ${kernel_path}"
        fi
    fi

    info "selected ${KERNEL_FLAVOR} kernel verified through ${kernel_pkg}"
}

verify_evr_preservation() {
    local before="${STATE_DIR}/strict-evr.before"
    local after="${STATE_DIR}/strict-evr.after"
    local diff="${STATE_DIR}/strict-evr.diff"

    strict_evr_filter "${STATE_DIR}/rpmdb.before.tsv" > "$before"
    strict_evr_filter "${STATE_DIR}/rpmdb.after.tsv" > "$after"
    comm -3 "$before" "$after" > "$diff" || true

    if [[ -s "$diff" ]]; then
        warn "package EVRA differences detected; see ${diff}"
        if (( STRICT_EVR )); then
            die "strict EVR preservation failed during post-migration verification"
        fi
    fi
}

print_summary() {
    if [[ "$MIGRATION_MODE" == "preserve-release" ]]; then
        cat <<EOF | tee -a "$LOG_FILE"

Migration completed.

Source: ${SOURCE_PRETTY_NAME}
Target: $(target_label)
Mode:   ${MIGRATION_MODE}
Kernel: ${KERNEL_FLAVOR}
State:  ${STATE_DIR}
Log:    ${LOG_FILE}

Review missing exact package matches, if any:
  ${STATE_DIR}/missing-exact.nevra

HTML reports:
  ${STATE_DIR}/migration-rpm-map.html
  ${STATE_DIR}/reinstalled-oracle-exact.html
  ${STATE_DIR}/reinstalled-oracle-nearest.html
  ${STATE_DIR}/not-reinstalled-oracle.html

Reboot into Oracle Linux when ready:
  reboot
EOF
    else
        cat <<EOF | tee -a "$LOG_FILE"

Migration completed.

Source: ${SOURCE_PRETTY_NAME}
Target: $(target_label)
Mode:   ${MIGRATION_MODE}
Kernel: ${KERNEL_FLAVOR}
State:  ${STATE_DIR}
Log:    ${LOG_FILE}

The system was synced to Oracle Linux repositories for the selected target.

HTML report:
  ${STATE_DIR}/migration-rpm-map.html

Reboot into Oracle Linux when ready:
  reboot
EOF
    fi
}

print_dry_run_summary() {
    if [[ "$MIGRATION_MODE" == "preserve-release" ]]; then
        cat <<EOF | tee -a "$LOG_FILE"

Dry-run completed. No package changes were made.

Source: ${SOURCE_PRETTY_NAME}
Target: $(target_label)
Mode:   ${MIGRATION_MODE}
Kernel: ${KERNEL_FLAVOR}
State:  ${STATE_DIR}
Log:    ${LOG_FILE}

Review the exact reinstall plan:
  ${STATE_DIR}/exact-reinstall.nevra

Review missing exact package matches, if any:
  ${STATE_DIR}/missing-exact.nevra

HTML reports:
  ${STATE_DIR}/migration-rpm-map.html
  ${STATE_DIR}/reinstalled-oracle-exact.html
  ${STATE_DIR}/reinstalled-oracle-nearest.html
  ${STATE_DIR}/not-reinstalled-oracle.html
EOF
    else
        cat <<EOF | tee -a "$LOG_FILE"

Dry-run completed. No package changes were made.

Source: ${SOURCE_PRETTY_NAME}
Target: $(target_label)
Mode:   ${MIGRATION_MODE}
Kernel: ${KERNEL_FLAVOR}
State:  ${STATE_DIR}
Log:    ${LOG_FILE}

In ${MIGRATION_MODE} mode the script replaces source distribution release
packages with Oracle Linux release packages and syncs all installed RPMs to the
selected Oracle Linux repositories.

The RPM mapping HTML report is generated after a real migration because it
compares the pre-migration RPM database with the post-migration RPM database.
EOF
    fi
}

main() {
    parse_args "$@"
    detect_source
    select_migration_mode
    prepare_environment
    snapshot_system
    check_kernel_state
    check_rpmdb
    confirm
    write_bootstrap_repos
    disable_source_repos
    remove_source_release_packages
    remove_rhel_only_packages
    install_oracle_release_packages
    refresh_oracle_repos
    if [[ "$MIGRATION_MODE" == "preserve-release" ]]; then
        build_reinstall_plan
    fi
    if (( DRY_RUN )); then
        info "dry-run completed; no packages were changed"
        print_dry_run_summary
        exit 0
    fi
    remove_amazon_only_packages
    remove_el10_split_firmware_packages
    if [[ "$MIGRATION_MODE" == "preserve-release" ]]; then
        reinstall_exact_packages
        reinstall_nearest_packages
    fi
    distro_sync_oracle
    remove_remaining_amazon_only_packages
    if [[ "$MIGRATION_MODE" == "preserve-release" ]]; then
        install_update_exception_packages
    fi
    remove_nonrunning_runtime_kernels
    install_selected_kernel
    remove_source_vendor_runtime_kernels
    replace_source_vendor_packages
    reassert_selected_kernel_default
    cleanup_bootstrap_repos
    verify_result
    print_summary
}

main "$@"
