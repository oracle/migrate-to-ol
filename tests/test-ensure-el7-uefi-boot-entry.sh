#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_DIR="$(cd "${TEST_DIR}/.." && pwd)"
readonly MIGRATION_SCRIPT="${REPO_DIR}/migrate-to-oracle-linux.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

run_scenario() {
    local scenario="$1"
    local expected_status="$2"
    local tmp_dir status

    tmp_dir="$(mktemp -d)"

    set +e
    (
        source "$MIGRATION_SCRIPT"

        DRY_RUN=0
        LOG_FILE="${tmp_dir}/migration.log"

        oracle_efi_shim_path() {
            [[ "$scenario" != missing-shim ]] || return 1
            printf '%s\n' /boot/efi/EFI/redhat/shimaa64.efi
        }

        efi_system_disk_and_partition() {
            printf '/dev/vda\t1\n'
        }

        efibootmgr() {
            if [[ "$1" == -v ]]; then
                if [[ "$scenario" == existing-entry ]]; then
                    printf '%s\n' 'Boot0004* Oracle Linux HD(...)\File(\EFI\redhat\shimaa64.efi)'
                else
                    printf '%s\n' 'Boot0003* CentOS Linux HD(...)\File(\EFI\centos\shimaa64.efi)'
                fi
                return 0
            fi
            printf '%s\n' "$*" > "${tmp_dir}/efibootmgr.args"
        }

        ensure_el7_uefi_boot_entry
    ) > "${tmp_dir}/output" 2>&1
    status=$?
    set -e

    [[ "$status" -eq "$expected_status" ]] || {
        sed -n '1,160p' "${tmp_dir}/output" >&2
        fail "${scenario}: expected status ${expected_status}, got ${status}"
    }

    case "$scenario" in
        stale-entry)
            grep -Fq -- '--create --disk /dev/vda --part 1 --label Oracle Linux --loader \EFI\redhat\shimaa64.efi' \
                "${tmp_dir}/efibootmgr.args" || fail "stale-entry: incorrect efibootmgr arguments"
            ;;
        existing-entry)
            [[ ! -e "${tmp_dir}/efibootmgr.args" ]] || \
                fail "existing-entry: boot entry should not be duplicated"
            ;;
        missing-shim)
            grep -Fq -- 'UEFI shim was not installed' "${tmp_dir}/output" || \
                fail "missing-shim: expected missing shim failure"
            ;;
    esac

    rm -rf "$tmp_dir"
    printf 'PASS: %s\n' "$scenario"
}

run_scenario stale-entry 0
run_scenario existing-entry 0
run_scenario missing-shim 1
