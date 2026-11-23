#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_DIR="$(cd "${TEST_DIR}/.." && pwd)"
readonly MIGRATION_SCRIPT="${REPO_DIR}/migrate-to-oracle-linux.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    local file="$1"
    local expected="$2"

    grep -Fq -- "$expected" "$file" || \
        fail "expected ${file} to contain: ${expected}"
}

assert_not_exists() {
    local path="$1"

    [[ ! -e "$path" ]] || fail "did not expect ${path} to exist"
}

run_scenario() {
    local scenario="$1"
    local expected_status="$2"
    local tmp_dir status

    tmp_dir="$(mktemp -d)"

    set +e
    (
        # Load the production functions without invoking main.
        source "$MIGRATION_SCRIPT"

        SOURCE_MAJOR="7"
        DRY_RUN=0
        LOG_FILE="${tmp_dir}/migration.log"

        running_under_uefi() {
            [[ "$scenario" == uefi-* ]]
        }

        mountpoint() {
            printf '%s\n' "$*" > "${tmp_dir}/mountpoint.args"
            [[ "$scenario" != uefi-unmounted ]]
        }

        grub2-mkconfig() {
            printf '%s\n' "$*" > "${tmp_dir}/grub2-mkconfig.args"
            [[ "$scenario" != *-command-fails ]]
        }

        ensure_el7_uefi_boot_entry() {
            printf '%s\n' called > "${tmp_dir}/ensure-uefi-boot-entry.args"
        }

        if [[ "$scenario" == missing-command ]]; then
            command() {
                if [[ "$1" == -v && "$2" == grub2-mkconfig ]]; then
                    return 1
                fi
                builtin command "$@"
            }
        fi

        if [[ "$scenario" == non-el7 ]]; then
            SOURCE_MAJOR="8"
        fi

        regenerate_el7_grub_config
    ) > "${tmp_dir}/output" 2>&1
    status=$?
    set -e

    [[ "$status" -eq "$expected_status" ]] || {
        sed -n '1,160p' "${tmp_dir}/output" >&2
        fail "${scenario}: expected status ${expected_status}, got ${status}"
    }

    case "$scenario" in
        bios-success)
            assert_contains "${tmp_dir}/grub2-mkconfig.args" "-o /boot/grub2/grub.cfg"
            assert_not_exists "${tmp_dir}/mountpoint.args"
            assert_not_exists "${tmp_dir}/ensure-uefi-boot-entry.args"
            ;;
        uefi-success)
            assert_contains "${tmp_dir}/mountpoint.args" "-q /boot/efi"
            assert_contains "${tmp_dir}/grub2-mkconfig.args" "-o /boot/efi/EFI/redhat/grub.cfg"
            assert_contains "${tmp_dir}/ensure-uefi-boot-entry.args" "called"
            ;;
        uefi-unmounted)
            assert_contains "${tmp_dir}/output" "/boot/efi is not mounted"
            assert_not_exists "${tmp_dir}/grub2-mkconfig.args"
            ;;
        bios-command-fails)
            assert_contains "${tmp_dir}/output" "do not reboot until the boot configuration is repaired"
            ;;
        missing-command)
            assert_contains "${tmp_dir}/output" "grub2-mkconfig is required"
            assert_not_exists "${tmp_dir}/grub2-mkconfig.args"
            ;;
        non-el7)
            assert_not_exists "${tmp_dir}/grub2-mkconfig.args"
            assert_not_exists "${tmp_dir}/mountpoint.args"
            ;;
    esac

    rm -rf "$tmp_dir"
    printf 'PASS: %s\n' "$scenario"
}

run_scenario bios-success 0
run_scenario uefi-success 0
run_scenario uefi-unmounted 1
run_scenario bios-command-fails 1
run_scenario missing-command 1
run_scenario non-el7 0
