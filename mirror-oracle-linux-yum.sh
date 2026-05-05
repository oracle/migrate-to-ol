#!/usr/bin/env bash
# SPDX-License-Identifier: UPL-1.0
#
# mirror-oracle-linux-yum.sh - build an Oracle Linux yum mirror.

set -Eeuo pipefail

PROGRAM_NAME="$(basename "$0")"
readonly PROGRAM_NAME
readonly SCRIPT_VERSION="0.1.0"
readonly ORACLE_YUM_BASE="https://yum.oracle.com"
readonly DEFAULT_RELEASES="7,8,9,10"
readonly DEFAULT_ARCHES="x86_64,aarch64"

DEST_DIR=""
RELEASES="$DEFAULT_RELEASES"
ARCHES="$DEFAULT_ARCHES"
WORK_DIR=""
PUBLIC_BASE_URL=""
DRY_RUN=0
KEEP_WORK_DIR=0
SKIP_UNAVAILABLE=1
INCLUDE_OL7_MINOR=0
JOBS=1
WEB_DISCOVERY=1
CONFIGURE_APACHE=1
SERVER_NAME=""
MIGRATION_YUM_MIRROR_URL=""
EXTRA_REPOSYNC_ARGS=()
PARALLEL_FAILED=0

usage() {
    cat <<EOF
Usage: ${PROGRAM_NAME} --dest DIR [options]

Create a local mirror of Oracle Linux yum repositories for OL7, OL8, OL9, and
OL10. The default repository set is curated for OS migration and includes the
latest BaseOS/AppStream-style repositories, listed developer/EPEL/KVM/builder
repositories, supported minor BaseOS media repositories for OL8 and newer, and
only the selected latest UEK repository for each major release.

Options:
      --dest DIR               Mirror destination directory.
      --release-list LIST      Comma-separated OL majors. Default: ${DEFAULT_RELEASES}
      --arch-list LIST         Comma-separated arches. Default: ${DEFAULT_ARCHES}
      --public-base-url URL    Mirror origin used in client .repo files, e.g. https://mirror.example.com.
      --work-dir DIR           Temporary work directory.
      --jobs N                 Number of repositories to sync in parallel. Default: 1
      --no-web-discovery       Do not add repositories listed only on yum.oracle.com pages.
      --include-ol7-minors     Also mirror OL7 update media repositories.
      --fail-unavailable       Fail when a repo is unavailable for an arch.
      --skip-unavailable       Skip unavailable repo/arch combinations. Default.
      --dry-run                Build repo files and print reposync commands only.
      --keep-work-dir          Keep generated temporary files.
      --reposync-arg ARG       Extra argument passed to reposync. Repeatable.
      --server-name NAME       Apache TLS certificate common name. Default: public URL host or system hostname.
      --no-configure-apache    Do not configure Apache, TLS, SELinux context, or firewalld.
  -h, --help                   Show help.
  -V, --version                Show version.

Output layout:
  DIR/RPM-GPG-KEY-oracle-ol<major>
  DIR/repo/OracleLinux/OL<major>/<repository-path>/<arch>/
  DIR/repo-files/oracle-linux-<major>-<arch>.repo
  DIR/manifests/oracle-linux-<major>-<arch>.tsv
EOF
}

log() {
    printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >&2
}

warn() {
    log "WARNING: $*"
}

die() {
    log "ERROR: $*"
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_oracle_linux_8_or_newer() {
    local os_id=""
    local version_id=""
    local pretty_name=""
    local major=""

    [[ -r /etc/os-release ]] || die "this script must run on Oracle Linux 8 or newer; /etc/os-release is missing"

    # shellcheck disable=SC1091
    . /etc/os-release
    os_id="${ID:-}"
    version_id="${VERSION_ID:-}"
    pretty_name="${PRETTY_NAME:-unknown operating system}"
    major="${version_id%%.*}"

    if [[ "$os_id" != "ol" || ! "$major" =~ ^[0-9]+$ || "$major" -lt 8 ]]; then
        die "this script must run on Oracle Linux 8 or newer; detected ${pretty_name}"
    fi
}

parse_args() {
    while (($#)); do
        case "$1" in
            --dest)
                shift
                [[ $# -gt 0 ]] || die "--dest requires a value"
                DEST_DIR="$1"
                ;;
            --release-list)
                shift
                [[ $# -gt 0 ]] || die "--release-list requires a value"
                RELEASES="$1"
                ;;
            --arch-list)
                shift
                [[ $# -gt 0 ]] || die "--arch-list requires a value"
                ARCHES="$1"
                ;;
            --public-base-url)
                shift
                [[ $# -gt 0 ]] || die "--public-base-url requires a value"
                PUBLIC_BASE_URL="${1%/}"
                ;;
            --work-dir)
                shift
                [[ $# -gt 0 ]] || die "--work-dir requires a value"
                WORK_DIR="$1"
                ;;
            --jobs)
                shift
                [[ $# -gt 0 ]] || die "--jobs requires a value"
                [[ "$1" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer"
                JOBS="$1"
                ;;
            --no-web-discovery)
                WEB_DISCOVERY=0
                ;;
            --include-ol7-minors)
                INCLUDE_OL7_MINOR=1
                ;;
            --fail-unavailable)
                SKIP_UNAVAILABLE=0
                ;;
            --skip-unavailable)
                SKIP_UNAVAILABLE=1
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            --keep-work-dir)
                KEEP_WORK_DIR=1
                ;;
            --reposync-arg)
                shift
                [[ $# -gt 0 ]] || die "--reposync-arg requires a value"
                EXTRA_REPOSYNC_ARGS+=("$1")
                ;;
            --server-name)
                shift
                [[ $# -gt 0 ]] || die "--server-name requires a value"
                SERVER_NAME="$1"
                ;;
            --no-configure-apache)
                CONFIGURE_APACHE=0
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
}

validate_list() {
    local list="$1"
    local pattern="$2"
    local label="$3"
    local item

    IFS=',' read -r -a items <<< "$list"
    for item in "${items[@]}"; do
        [[ -n "$item" ]] || die "${label} list contains an empty item"
        [[ "$item" =~ $pattern ]] || die "unsupported ${label}: $item"
    done
}

prepare() {
    [[ -n "$DEST_DIR" ]] || die "--dest is required"
    require_oracle_linux_8_or_newer
    if ((CONFIGURE_APACHE && !DRY_RUN && EUID != 0)); then
        die "Apache/firewalld configuration requires root; rerun with sudo or use --no-configure-apache"
    fi

    validate_list "$RELEASES" '^(7|8|9|10)$' "release"
    validate_list "$ARCHES" '^(x86_64|aarch64)$' "architecture"

    require_cmd awk
    require_cmd curl
    require_cmd gzip
    require_cmd python3
    require_cmd reposync
    require_cmd rpm2cpio
    require_cmd cpio

    mkdir -p "$DEST_DIR"
    DEST_DIR="$(cd "$DEST_DIR" && pwd)"
    mkdir -p "${DEST_DIR}/repo-files" "${DEST_DIR}/manifests"

    if [[ -z "$WORK_DIR" ]]; then
        WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/oracle-yum-mirror.XXXXXX")"
    else
        mkdir -p "$WORK_DIR"
        WORK_DIR="$(cd "$WORK_DIR" && pwd)"
    fi
}

cleanup() {
    if ((KEEP_WORK_DIR)); then
        log "keeping work directory: ${WORK_DIR}"
    elif [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}

fetch_url() {
    local url="$1"
    local output="$2"

    log "fetching ${url}"
    curl -fL --retry 5 --retry-delay 3 --connect-timeout 30 -o "$output" "$url"
}

extract_primary_href() {
    python3 - "$1" <<'PY'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
for data in root:
    if data.tag.endswith('data') and data.attrib.get('type') == 'primary':
        for child in data:
            if child.tag.endswith('location'):
                print(child.attrib['href'])
                raise SystemExit(0)
raise SystemExit('primary metadata not found')
PY
}

find_release_rpm_href() {
    local primary_gz="$1"
    local major="$2"

    python3 - "$primary_gz" "oraclelinux-release-el${major}" <<'PY'
import gzip
import re
import sys

primary_gz, wanted = sys.argv[1], sys.argv[2]
pattern = re.compile(r'<package type="rpm">(.*?)</package>', re.S)
best = None

with gzip.open(primary_gz, 'rt', encoding='utf-8', errors='ignore') as handle:
    data = handle.read()

for match in pattern.finditer(data):
    package = match.group(1)
    if f'<name>{wanted}</name>' not in package:
        continue
    arch = re.search(r'<arch>(.*?)</arch>', package)
    if not arch or arch.group(1) != 'x86_64':
        continue
    location = re.search(r'<location href="(.*?)"', package)
    build_time = re.search(r'<time file="[0-9]+" build="([0-9]+)"', package)
    if not location:
        continue
    score = int(build_time.group(1)) if build_time else 0
    candidate = (score, location.group(1))
    if best is None or candidate > best:
        best = candidate

if best is None:
    raise SystemExit(f'{wanted} RPM not found')

print(best[1])
PY
}

download_release_repo_file() {
    local major="$1"
    local output="$2"
    local release_root
    local repomd
    local primary_href
    local primary_gz
    local rpm_href
    local rpm_file
    local extract_dir

    if [[ "$major" == "7" ]]; then
        fetch_url "${ORACLE_YUM_BASE}/public-yum-ol7.repo" "$output"
        return
    fi

    release_root="${ORACLE_YUM_BASE}/repo/OracleLinux/OL${major}/baseos/latest/x86_64"
    repomd="${WORK_DIR}/ol${major}-repomd.xml"
    primary_gz="${WORK_DIR}/ol${major}-primary.xml.gz"
    rpm_file="${WORK_DIR}/oraclelinux-release-el${major}.rpm"
    extract_dir="${WORK_DIR}/extract-ol${major}"

    fetch_url "${release_root}/repodata/repomd.xml" "$repomd"
    primary_href="$(extract_primary_href "$repomd")"
    fetch_url "${release_root}/${primary_href}" "$primary_gz"
    rpm_href="$(find_release_rpm_href "$primary_gz" "$major")"
    fetch_url "${release_root}/${rpm_href}" "$rpm_file"

    mkdir -p "$extract_dir"
    (cd "$extract_dir" && rpm2cpio "$rpm_file" | cpio -idm --quiet './etc/yum.repos.d/*')
    find "$extract_dir/etc/yum.repos.d" -type f -name '*.repo' -print0 |
        xargs -0 cat > "$output"
}

append_web_repositories() {
    local major="$1"
    local repo_file="$2"
    local html_file="${WORK_DIR}/oracle-linux-${major}.html"

    if ((!WEB_DISCOVERY)); then
        return 0
    fi

    fetch_url "${ORACLE_YUM_BASE}/oracle-linux-${major}.html" "$html_file"
    local generated_count

    generated_count="$(python3 - "$major" "$repo_file" "$html_file" <<'PY'
import html
import re
import sys

major, repo_file, html_file = sys.argv[1], sys.argv[2], sys.argv[3]

with open(repo_file, encoding='utf-8', errors='ignore') as handle:
    repo_text = handle.read()
with open(html_file, encoding='utf-8', errors='ignore') as handle:
    page = handle.read()

existing_ids = set(re.findall(r'^\s*\[([^]]+)\]\s*$', repo_text, re.M))
existing_paths = set()

for baseurl in re.findall(r'^\s*baseurl\s*=\s*(\S+)', repo_text, re.M):
    value = baseurl
    value = value.replace('${basearch}', '$basearch').replace('$basearch', '$basearch')
    value = value.replace('${releasever}', major).replace('$releasever', major)
    value = value.replace('${ociregion}', '').replace('$ociregion', '')
    value = value.replace('${ocidomain}', 'oracle.com').replace('$ocidomain', 'oracle.com')
    value = re.sub(r'/+', '/', value.replace('https://', 'https:/'))
    value = value.replace('https:/', 'https://')
    match = re.search(rf'/OracleLinux/OL{major}/(.+?)/(?:\$basearch|x86_64|aarch64)/?$', value)
    if match:
        existing_paths.add(match.group(1).strip('/'))

def clean_markup(value):
    value = re.sub(r'<[^>]+>', ' ', value)
    value = html.unescape(value)
    return re.sub(r'\s+', ' ', value).strip()

def fallback_title(repo_path):
    return re.sub(r'[_/-]+', ' ', repo_path).strip().title() or f'Oracle Linux {major}'

def fallback_description(repo_path):
    return f'Oracle Linux {major} repository: {repo_path}.'

def release_safe_text(value, repo_path, fallback_factory):
    if any(found != major for found in re.findall(r'\bOracle Linux\s+([0-9]+)(?:\b|[.])', value)):
        return fallback_factory(repo_path)
    return value

def repo_id_from_path(path):
    parts = [part for part in path.strip('/').split('/') if part]
    if parts and parts[0].isdigit():
        parts[0] = f'u{parts[0]}'
    slug = '_'.join(parts)
    slug = re.sub(r'[^A-Za-z0-9_]+', '_', slug).strip('_')
    return f'ol{major}_{slug}'

def unique_repoid(repoid):
    if repoid not in existing_ids:
        existing_ids.add(repoid)
        return repoid
    index = 2
    while f'{repoid}_{index}' in existing_ids:
        index += 1
    repoid = f'{repoid}_{index}'
    existing_ids.add(repoid)
    return repoid

repo_blocks = re.split(r'<h3\s+class="hdg-xsm">', page)
generated = []

for block in repo_blocks[1:]:
    title_match = re.match(r'(.*?)</h3>', block, re.S)
    if not title_match:
        continue
    title = clean_markup(title_match.group(1))
    desc_match = re.search(r'<p>(.*?)</p>', block, re.S)
    description = clean_markup(desc_match.group(1)) if desc_match else title

    urls = re.findall(
        rf'https://yum\.oracle\.com/repo/OracleLinux/OL{major}/[^"\s<>]+/(?:x86_64|aarch64)/index\.html',
        block,
    )

    for url in urls:
        baseurl = url[:-len('index.html')]
        path_match = re.search(rf'/OracleLinux/OL{major}/(.+?)/(?:x86_64|aarch64)/$', baseurl)
        if not path_match:
            continue
        repo_path = path_match.group(1).strip('/')
        repo_path_lower = repo_path.lower()
        if (
            re.search(r'(^|/)(source|src|srpms)(/|$)', repo_path_lower)
            or 'getpackagesource' in repo_path_lower
        ):
            continue
        if repo_path in existing_paths:
            continue
        existing_paths.add(repo_path)

        title = release_safe_text(title, repo_path, fallback_title)
        description = release_safe_text(description, repo_path, fallback_description)
        repoid = unique_repoid(repo_id_from_path(repo_path))
        generic_baseurl = f'https://yum.oracle.com/repo/OracleLinux/OL{major}/{repo_path}/$basearch/'
        generated.append((repoid, title, description, generic_baseurl))

if generated:
    with open(repo_file, 'a', encoding='utf-8') as handle:
        handle.write('\n# Repositories discovered from yum.oracle.com repository index.\n')
        for repoid, title, description, baseurl in generated:
            handle.write(f'\n[{repoid}]\n')
            handle.write(f'name={title} ($basearch)\n')
            handle.write(f'description={description}\n')
            handle.write(f'baseurl={baseurl}\n')
            handle.write('gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle\n')
            handle.write('gpgcheck=1\n')
            handle.write('enabled=0\n')

print(len(generated))
PY
)"
    log "added ${generated_count} OL${major} repositories from yum.oracle.com page"
}

append_curated_repository() {
    local major="$1"
    local repo_file="$2"
    local repo_suffix="$3"
    local path="$4"
    local name="$5"
    local repoid="ol${major}_${repo_suffix}"

    if grep -Eq "^[[:space:]]*baseurl[[:space:]]*=.*\/OracleLinux\/OL${major}\/${path//\//\\/}\/(\\\$basearch|\\\$\\{basearch\\}|x86_64|aarch64)\/?[[:space:]]*$" "$repo_file"; then
        return 0
    fi

    {
        printf '\n[%s]\n' "$repoid"
        printf 'name=%s\n' "$name"
        printf 'description=%s\n' "$name"
        printf "baseurl=%s/repo/OracleLinux/OL%s/%s/\\\$basearch/\n" "$ORACLE_YUM_BASE" "$major" "$path"
        printf 'gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle\n'
        printf 'gpgcheck=1\n'
        printf 'enabled=0\n'
    } >> "$repo_file"
}

append_curated_repositories() {
    local major="$1"
    local repo_file="$2"
    local update

    if ! grep -Fq '# Curated Oracle Linux migration mirror repositories.' "$repo_file"; then
        {
            printf '\n# Curated Oracle Linux migration mirror repositories.\n'
        } >> "$repo_file"
    fi

    case "$major" in
        7)
            append_curated_repository "$major" "$repo_file" "latest" "latest" "Oracle Linux 7 Latest (\$basearch)"
            append_curated_repository "$major" "$repo_file" "addons" "addons" "Oracle Linux 7 Add ons (\$basearch)"
            append_curated_repository "$major" "$repo_file" "optional_latest" "optional/latest" "Oracle Linux 7 Optional Latest (\$basearch)"
            append_curated_repository "$major" "$repo_file" "preview" "preview" "Oracle Linux 7 Preview (\$basearch)"
            append_curated_repository "$major" "$repo_file" "security_validation" "security/validation" "Oracle Linux 7 Security Validations (\$basearch)"
            append_curated_repository "$major" "$repo_file" "kvm_utils" "kvm/utils" "Oracle Linux 7 KVM Utilities (\$basearch)"
            append_curated_repository "$major" "$repo_file" "leapp" "leapp" "Leapp for Oracle Linux 7 (\$basearch)"
            append_curated_repository "$major" "$repo_file" "software_collections" "SoftwareCollections" "Software Collection Library packages for Oracle Linux 7 (\$basearch)"
            append_curated_repository "$major" "$repo_file" "developer" "developer" "Oracle Linux 7 Development Packages (\$basearch)"
            append_curated_repository "$major" "$repo_file" "developer_EPEL" "developer_EPEL" "Oracle Linux 7 EPEL Packages (\$basearch)"
            append_curated_repository "$major" "$repo_file" "developer_nodejs10" "developer_nodejs10" "Oracle Linux 7 Node.js 10 Packages for Development and test (\$basearch)"
            append_curated_repository "$major" "$repo_file" "developer_php72" "developer_php72" "Oracle Linux 7 PHP 7.2 Packages for Development and test (\$basearch)"
            append_curated_repository "$major" "$repo_file" "UEKR6" "UEKR6" "Latest Unbreakable Enterprise Kernel Release 6 for Oracle Linux 7 (\$basearch)"
            ;;
        8)
            append_curated_repository "$major" "$repo_file" "baseos_latest" "baseos/latest" "Oracle Linux 8 BaseOS Latest (\$basearch)"
            append_curated_repository "$major" "$repo_file" "appstream" "appstream" "Oracle Linux 8 Application Stream (\$basearch)"
            for update in 0 1 2 3 4 5 6 7 8 9 10; do
                append_curated_repository "$major" "$repo_file" "u${update}_baseos_base" "${update}/baseos/base" "Oracle Linux 8.${update} BaseOS (\$basearch)"
            done
            append_curated_repository "$major" "$repo_file" "developer" "developer" "Developer Packages (\$basearch)"
            append_curated_repository "$major" "$repo_file" "developer_EPEL" "developer/EPEL" "EPEL Packages (\$basearch)"
            append_curated_repository "$major" "$repo_file" "addons" "addons" "Oracle Linux 8 Addons (\$basearch)"
            append_curated_repository "$major" "$repo_file" "kvm_appstream" "kvm/appstream" "Oracle Linux 8 KVM Application Stream (\$basearch)"
            append_curated_repository "$major" "$repo_file" "codeready_builder" "codeready/builder" "Oracle Linux 8 CodeReady Builder (\$basearch) - Unsupported"
            append_curated_repository "$major" "$repo_file" "distro_builder" "distro/builder" "Oracle Linux 8 Distro Builder (\$basearch) - Unsupported"
            append_curated_repository "$major" "$repo_file" "UEKR7" "UEKR7" "Latest Unbreakable Enterprise Kernel Release 7 for Oracle Linux 8 (\$basearch)"
            ;;
        9)
            append_curated_repository "$major" "$repo_file" "baseos_latest" "baseos/latest" "Oracle Linux 9 BaseOS Latest (\$basearch)"
            append_curated_repository "$major" "$repo_file" "appstream" "appstream" "Oracle Linux 9 Application Stream Packages (\$basearch)"
            for update in 0 1 2 3 4 5 6 7; do
                append_curated_repository "$major" "$repo_file" "u${update}_baseos_base" "${update}/baseos/base" "Oracle Linux 9.${update} BaseOS (\$basearch)"
            done
            append_curated_repository "$major" "$repo_file" "developer" "developer" "Developer Packages (\$basearch)"
            append_curated_repository "$major" "$repo_file" "developer_EPEL" "developer/EPEL" "EPEL Packages (\$basearch)"
            append_curated_repository "$major" "$repo_file" "addons" "addons" "Oracle Linux 9 Addons (\$basearch)"
            append_curated_repository "$major" "$repo_file" "kvm_utils" "kvm/utils" "Oracle Linux 9 KVM Utilities (\$basearch)"
            append_curated_repository "$major" "$repo_file" "codeready_builder" "codeready/builder" "Oracle Linux 9 CodeReady Builder (\$basearch) - Unsupported"
            append_curated_repository "$major" "$repo_file" "distro_builder" "distro/builder" "Oracle Linux 9 Distro Builder (\$basearch) - Unsupported"
            append_curated_repository "$major" "$repo_file" "UEKR8" "UEKR8" "Oracle Linux 9 UEK Release 8 (\$basearch)"
            ;;
        10)
            append_curated_repository "$major" "$repo_file" "baseos_latest" "baseos/latest" "Oracle Linux 10 BaseOS Latest (\$basearch)"
            append_curated_repository "$major" "$repo_file" "appstream" "appstream" "Oracle Linux 10 Application Stream Packages (\$basearch)"
            for update in 0 1; do
                append_curated_repository "$major" "$repo_file" "u${update}_baseos_base" "${update}/baseos/base" "Oracle Linux 10.${update} BaseOS (\$basearch)"
            done
            append_curated_repository "$major" "$repo_file" "developer" "developer" "Developer Packages (\$basearch)"
            append_curated_repository "$major" "$repo_file" "u1_developer_EPEL" "1/developer/EPEL" "EPEL Packages (\$basearch)"
            append_curated_repository "$major" "$repo_file" "addons" "addons" "Oracle Linux 10 Addons (\$basearch)"
            append_curated_repository "$major" "$repo_file" "kvm_utils" "kvm/utils" "Oracle Linux 10 KVM Utilities (\$basearch)"
            append_curated_repository "$major" "$repo_file" "codeready_builder" "codeready/builder" "Oracle Linux 10 CodeReady Builder (\$basearch) - Unsupported"
            append_curated_repository "$major" "$repo_file" "distro_builder" "distro/builder" "Oracle Linux 10 Distro Builder (\$basearch) - Unsupported"
            append_curated_repository "$major" "$repo_file" "UEKR8" "UEKR8" "Oracle Linux 10 UEK Release 8 (\$basearch)"
            ;;
    esac
}

write_repo_files_for_arch() {
    local source_repo="$1"
    local major="$2"
    local arch="$3"
    local sync_repo="$4"
    local client_repo="$5"
    local manifest="$6"
    local client_root="$7"
    local latest_uek="$8"

    : > "$sync_repo"
    : > "$client_repo"
    : > "$manifest"
    printf 'repoid\tname\tbaseurl\trepomd\tmirror_path\n' > "$manifest"

    awk \
        -v major="$major" \
        -v arch="$arch" \
        -v sync_repo="$sync_repo" \
        -v client_repo="$client_repo" \
        -v manifest="$manifest" \
        -v include_ol7_minor="$INCLUDE_OL7_MINOR" \
        -v dest_dir="$DEST_DIR" \
        -v client_root="$client_root" \
        -v latest_uek="$latest_uek" '
function trim(value) {
    sub(/^[[:space:]]+/, "", value)
    sub(/[[:space:]]+$/, "", value)
    return value
}

function replace_vars(value) {
    gsub(/\$\{basearch\}/, arch, value)
    gsub(/\$basearch/, arch, value)
    gsub(/\$\{releasever\}/, major, value)
    gsub(/\$releasever/, major, value)
    gsub(/\$\{ociregion\}/, "", value)
    gsub(/\$ociregion/, "", value)
    gsub(/\$\{ocidomain\}/, "oracle.com", value)
    gsub(/\$ocidomain/, "oracle.com", value)
    return value
}

function mirror_path_from_baseurl(value) {
    sub(/\/$/, "", value)
    marker = "/repo/OracleLinux/"
    marker_index = index(value, marker)
    if (marker_index == 0) {
        return ""
    }
    return substr(value, marker_index)
}

function uek_release(value, tmp) {
    tmp = value
    if (tmp !~ /UEKR[0-9]+/) {
        return 0
    }
    sub(/^.*UEKR/, "", tmp)
    sub(/[^0-9].*$/, "", tmp)
    return tmp + 0
}

function source_repository(value, lowered_id, lowered_name) {
    lowered_id = tolower(id)
    lowered_name = tolower(name)
    lowered_value = tolower(value)

    return lowered_value ~ /\/(source|src|srpms)(\/|$)/ ||
        lowered_value ~ /getpackagesource/ ||
        lowered_id ~ /(^|[_-])(source|src|srpms)([_-]|$)/ ||
        lowered_id ~ /getpackagesource/ ||
        lowered_name ~ /(^|[[:space:]])source([[:space:]]|$)/ ||
        lowered_name ~ /getpackagesource/ ||
        lowered_name ~ /source rpm|srpm/
}

function repo_path(value, path) {
    path = value
    sub(/\/$/, "", path)
    sub("^.*/OracleLinux/OL" major "/", "", path)
    sub("/" arch "$", "", path)
    return path
}

function curated_repository(value, path) {
    path = repo_path(value)

    if (major == "7") {
        return path == "addons" ||
            (include_ol7_minor == "1" && path ~ /^[0-9]+\/base$/) ||
            path == "developer" ||
            path == "developer_EPEL" ||
            path == "developer_nodejs10" ||
            path == "developer_php72" ||
            path == "kvm/utils" ||
            path == "latest" ||
            path == "leapp" ||
            path == "optional/latest" ||
            path == "preview" ||
            path == "security/validation" ||
            path == "SoftwareCollections" ||
            path == "UEKR6"
    }
    if (major == "8") {
        return path == "baseos/latest" ||
            path == "appstream" ||
            path ~ /^(0|1|2|3|4|5|6|7|8|9|10)\/baseos\/base$/ ||
            path == "developer" ||
            path == "developer/EPEL" ||
            path == "addons" ||
            path == "kvm/appstream" ||
            path == "codeready/builder" ||
            path == "distro/builder" ||
            path == "UEKR7"
    }
    if (major == "9") {
        return path == "baseos/latest" ||
            path == "appstream" ||
            path ~ /^(0|1|2|3|4|5|6|7)\/baseos\/base$/ ||
            path == "developer" ||
            path == "developer/EPEL" ||
            path == "addons" ||
            path == "kvm/utils" ||
            path == "codeready/builder" ||
            path == "distro/builder" ||
            path == "UEKR8"
    }
    if (major == "10") {
        return path == "baseos/latest" ||
            path == "appstream" ||
            path ~ /^(0|1)\/baseos\/base$/ ||
            path == "developer" ||
            path == "1/developer/EPEL" ||
            path == "addons" ||
            path == "kvm/utils" ||
            path == "codeready/builder" ||
            path == "distro/builder" ||
            path == "UEKR8"
    }
    return 0
}

function skip_section() {
    concrete_baseurl = replace_vars(baseurl)
    uek = uek_release(concrete_baseurl)

    if (id == "" || baseurl == "") {
        return 1
    }
    if (source_repository(concrete_baseurl)) {
        return 1
    }
    if (!curated_repository(concrete_baseurl)) {
        return 1
    }
    if (latest_uek > 0 && (uek > 0 || id ~ /UEK/ || name ~ /UEK/ || concrete_baseurl ~ /UEK/)) {
        latest_uek_path = "/UEKR" latest_uek "/" arch
        if (index(concrete_baseurl, latest_uek_path) == 0) {
            return 1
        }
    }
    if (major == "7" && include_ol7_minor != "1") {
        if (id ~ /^ol7_u[0-9]+_/) {
            return 1
        }
        if (baseurl ~ "/OL7/[0-9]+/") {
            return 1
        }
    }
    return 0
}

function emit() {
    if (skip_section()) {
        reset()
        return
    }

    concrete_baseurl = replace_vars(baseurl)
    repomd_url = concrete_baseurl
    sub(/\/$/, "", repomd_url)
    repomd_url = repomd_url "/repodata/repomd.xml"

    mirror_path = mirror_path_from_baseurl(concrete_baseurl)
    if (mirror_path == "") {
        reset()
        return
    }

    local_baseurl = client_root
    if (local_baseurl == "") {
        local_baseurl = "file://" dest_dir
    }
    sub(/\/$/, "", local_baseurl)
    local_baseurl = local_baseurl mirror_path "/"

    print id "\t" name "\t" concrete_baseurl "\t" repomd_url "\t" mirror_path >> manifest

    print "[" id "]" >> sync_repo
    print "[" id "]" >> client_repo
    for (i = 1; i <= count; i++) {
        line = lines[i]
        if (line ~ /^[[:space:]]*baseurl[[:space:]]*=/) {
            print "baseurl=" concrete_baseurl >> sync_repo
            print "baseurl=" local_baseurl >> client_repo
        } else if (line ~ /^[[:space:]]*enabled[[:space:]]*=/) {
            print "enabled=1" >> sync_repo
            print line >> client_repo
        } else if (line ~ /^[[:space:]]*(mirrorlist|metalink)[[:space:]]*=/) {
            continue
        } else {
            print line >> sync_repo
            print line >> client_repo
        }
    }
    print "" >> sync_repo
    print "" >> client_repo
    reset()
}

function reset() {
    id = ""
    name = ""
    baseurl = ""
    count = 0
    delete lines
}

BEGIN { reset() }

/^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
    emit()
    id = $0
    sub(/^[[:space:]]*\[/, "", id)
    sub(/\][[:space:]]*$/, "", id)
    next
}

id != "" {
    lines[++count] = $0
    if ($0 ~ /^[[:space:]]*name[[:space:]]*=/) {
        name = $0
        sub(/^[^=]*=/, "", name)
        name = trim(name)
    } else if ($0 ~ /^[[:space:]]*baseurl[[:space:]]*=/) {
        baseurl = $0
        sub(/^[^=]*=/, "", baseurl)
        baseurl = trim(baseurl)
    }
}

END {
    emit()
}
' "$source_repo"
}

latest_uek_release_from_repo_file() {
    local source_repo="$1"
    local major="$2"
    local arch="$3"

    python3 - "$source_repo" "$major" "$arch" <<'PY'
import re
import sys

repo_file, major, arch = sys.argv[1], sys.argv[2], sys.argv[3]

with open(repo_file, encoding='utf-8', errors='ignore') as handle:
    repo_text = handle.read()

latest = 0

for baseurl in re.findall(r'^\s*baseurl\s*=\s*(\S+)', repo_text, re.M):
    value = baseurl
    value = value.replace('${basearch}', '$basearch').replace('$basearch', arch)
    value = value.replace('${releasever}', major).replace('$releasever', major)
    value = value.replace('${ociregion}', '').replace('$ociregion', '')
    value = value.replace('${ocidomain}', 'oracle.com').replace('$ocidomain', 'oracle.com')
    value = re.sub(r'/+', '/', value.replace('https://', 'https:/'))
    value = value.replace('https:/', 'https://')

    if not re.search(rf'/OracleLinux/OL{major}/.+/(?:{re.escape(arch)})/?$', value):
        continue

    match = re.search(r'UEKR([0-9]+)', value)
    if match:
        latest = max(latest, int(match.group(1)))

print(latest)
PY
}

repo_available() {
    local repomd_url="$1"

    curl -fsIL --connect-timeout 20 --retry 2 "$repomd_url" >/dev/null 2>&1
}

reposync_arch_args() {
    local arch="$1"

    case "$arch" in
        x86_64)
            printf '%s\n' --arch x86_64 --arch noarch --arch i686 --arch i586 --arch i386
            ;;
        aarch64)
            printf '%s\n' --arch aarch64 --arch noarch
            ;;
        *)
            die "unsupported architecture for reposync: ${arch}"
            ;;
    esac
}

remove_source_rpms() {
    local target_dir="$1"

    [[ -d "$target_dir" ]] || return 0
    find "$target_dir" -type f -name '*.src.rpm' -delete
}

mirror_gpg_key() {
    local major="$1"
    local key_name="RPM-GPG-KEY-oracle-ol${major}"
    local key_url="${ORACLE_YUM_BASE}/${key_name}"
    local key_path="${DEST_DIR}/${key_name}"

    if ((DRY_RUN)); then
        printf 'curl -fL --retry 5 --retry-delay 3 --connect-timeout 30 -o %q %q\n' "$key_path" "$key_url"
        return
    fi

    fetch_url "$key_url" "$key_path"
}

sync_one_repo() {
    local repo_file="$1"
    local arch="$2"
    local repoid="$3"
    local mirror_path="$4"
    local target_dir="${DEST_DIR}${mirror_path}"
    local worker_state="${WORK_DIR}/dnf-state/${arch}/${repoid}"
    local worker_cache="${worker_state}/cache"
    local worker_persist="${worker_state}/persist"
    local worker_log="${worker_state}/log"
    local arch_args=()

    mkdir -p "$target_dir" "$worker_cache" "$worker_persist" "$worker_log"
    mapfile -t arch_args < <(reposync_arch_args "$arch")

    log "syncing ${repoid} (${arch})"
    if ((DRY_RUN)); then
        printf 'reposync --config %q --setopt %q --setopt %q --setopt %q' \
            "$repo_file" \
            "cachedir=${worker_cache}" \
            "persistdir=${worker_persist}" \
            "logdir=${worker_log}"
        printf ' %q' "${arch_args[@]}"
        printf ' --repoid %q --download-path %q --download-metadata --newest-only --delete --remote-time --norepopath' \
            "$repoid" \
            "$target_dir"
        if ((${#EXTRA_REPOSYNC_ARGS[@]})); then
            printf ' %q' "${EXTRA_REPOSYNC_ARGS[@]}"
        fi
        printf '\n'
        return
    fi

    reposync \
        --config "$repo_file" \
        --setopt "cachedir=${worker_cache}" \
        --setopt "persistdir=${worker_persist}" \
        --setopt "logdir=${worker_log}" \
        "${arch_args[@]}" \
        --repoid "$repoid" \
        --download-path "$target_dir" \
        --download-metadata \
        --newest-only \
        --delete \
        --remote-time \
        --norepopath \
        "${EXTRA_REPOSYNC_ARGS[@]}"
    remove_source_rpms "$target_dir"
}

wait_for_slot() {
    local running

    while true; do
        running="$(jobs -pr | wc -l | tr -d ' ')"
        ((running < JOBS)) && return
        if ! wait -n; then
            PARALLEL_FAILED=1
        fi
    done
}

sync_repositories_from_manifest() {
    local repo_file="$1"
    local arch="$2"
    local manifest="$3"
    local failed=0
    local repoid _name baseurl repomd mirror_path

    PARALLEL_FAILED=0

    while IFS=$'\t' read -r repoid _name baseurl repomd mirror_path; do
        [[ "$repoid" != "repoid" ]] || continue
        [[ -n "$repoid" ]] || continue

        if ! repo_available "$repomd"; then
            if ((SKIP_UNAVAILABLE)); then
                log "skipping unavailable ${repoid} (${arch}): ${baseurl}"
                continue
            fi
            die "repository unavailable for ${arch}: ${repoid} (${baseurl})"
        fi

        if ((JOBS > 1)); then
            wait_for_slot
            sync_one_repo "$repo_file" "$arch" "$repoid" "$mirror_path" &
        else
            sync_one_repo "$repo_file" "$arch" "$repoid" "$mirror_path" || failed=1
        fi
    done < "$manifest"

    if ((JOBS > 1)); then
        while [[ -n "$(jobs -pr)" ]]; do
            if ! wait -n; then
                failed=1
            fi
        done
        ((PARALLEL_FAILED)) && failed=1
    fi

    return "$failed"
}

hostname_from_public_base_url() {
    local value="${PUBLIC_BASE_URL#https://}"

    value="${value%%/*}"
    value="${value%%:*}"
    value="${value#[}"
    value="${value%]}"

    printf '%s\n' "$value"
}

default_server_name() {
    local candidate=""

    if [[ -n "$PUBLIC_BASE_URL" && "$PUBLIC_BASE_URL" == https://* ]]; then
        candidate="$(hostname_from_public_base_url)"
    fi
    if [[ -z "$candidate" ]]; then
        candidate="$(hostname -f 2>/dev/null || hostname)"
    fi

    printf '%s\n' "$candidate"
}

validate_server_name() {
    local value="$1"

    [[ "$value" =~ ^[A-Za-z0-9._:-]+$ ]] || die "invalid Apache server name: ${value}"
}

migration_yum_mirror_url() {
    local server_name="$1"

    if [[ -n "$PUBLIC_BASE_URL" ]]; then
        printf '%s\n' "$PUBLIC_BASE_URL"
    elif [[ -n "$server_name" ]]; then
        printf 'https://%s\n' "$server_name"
    fi
}

certificate_alt_names() {
    local name="$1"
    local san=""
    local ip

    if [[ "$name" =~ ^[0-9]+(\.[0-9]+){3}$ || "$name" == *:* ]]; then
        san="IP:${name}"
    else
        san="DNS:${name}"
    fi

    while IFS= read -r ip; do
        [[ -n "$ip" ]] || continue
        [[ "$ip" == 127.* || "$ip" == "::1" ]] && continue
        [[ "$san" == *"IP:${ip}"* ]] && continue
        san="${san},IP:${ip}"
    done < <(hostname -I 2>/dev/null | tr ' ' '\n')

    printf '%s\n' "$san"
}

install_apache_packages() {
    local missing=()
    local package

    for package in httpd mod_ssl openssl; do
        if ! rpm -q "$package" >/dev/null 2>&1; then
            missing+=("$package")
        fi
    done

    if ((${#missing[@]})); then
        require_cmd dnf
        log "installing Apache/TLS packages: ${missing[*]}"
        dnf -y install "${missing[@]}"
    fi
}

write_apache_certificate() {
    local server_name="$1"
    local cert_dir="/etc/pki/tls/certs"
    local key_dir="/etc/pki/tls/private"
    local cert_path="${cert_dir}/oracle-linux-yum-mirror.crt"
    local key_path="${key_dir}/oracle-linux-yum-mirror.key"
    local san

    require_cmd openssl
    mkdir -p "$cert_dir" "$key_dir"

    if [[ -s "$cert_path" && -s "$key_path" ]]; then
        log "using existing Apache TLS certificate: ${cert_path}"
        ensure_mod_ssl_default_certificate "$cert_path" "$key_path"
        return
    fi

    san="$(certificate_alt_names "$server_name")"
    log "generating self-signed Apache TLS certificate for ${server_name}"
    if ! openssl req -x509 -nodes -newkey rsa:4096 -sha256 -days 3650 \
        -keyout "$key_path" \
        -out "$cert_path" \
        -subj "/CN=${server_name}" \
        -addext "subjectAltName=${san}"; then
        rm -f "$cert_path" "$key_path"
        openssl req -x509 -nodes -newkey rsa:4096 -sha256 -days 3650 \
            -keyout "$key_path" \
            -out "$cert_path" \
            -subj "/CN=${server_name}"
    fi

    chmod 0644 "$cert_path"
    chmod 0600 "$key_path"
    ensure_mod_ssl_default_certificate "$cert_path" "$key_path"
}

ensure_mod_ssl_default_certificate() {
    local cert_path="$1"
    local key_path="$2"
    local default_cert="/etc/pki/tls/certs/localhost.crt"
    local default_key="/etc/pki/tls/private/localhost.key"

    [[ -f /etc/httpd/conf.d/ssl.conf ]] || return 0

    if [[ ! -s "$default_cert" ]]; then
        log "creating missing mod_ssl default certificate: ${default_cert}"
        cp -f "$cert_path" "$default_cert"
        chmod 0644 "$default_cert"
    fi
    if [[ ! -s "$default_key" ]]; then
        log "creating missing mod_ssl default private key: ${default_key}"
        cp -f "$key_path" "$default_key"
        chmod 0600 "$default_key"
    fi
}

write_apache_config() {
    local server_name="$1"
    local conf_path="/etc/httpd/conf.d/oracle-linux-yum-mirror.conf"
    local cert_path="/etc/pki/tls/certs/oracle-linux-yum-mirror.crt"
    local key_path="/etc/pki/tls/private/oracle-linux-yum-mirror.key"

    log "writing Apache yum mirror configuration: ${conf_path}"
    cat > "$conf_path" <<EOF
# Managed by ${PROGRAM_NAME}.
ServerName ${server_name}

<VirtualHost *:80>
    ServerName ${server_name}
    DocumentRoot "${DEST_DIR}"

    <Directory "${DEST_DIR}">
        Options Indexes FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>
</VirtualHost>

<VirtualHost *:443>
    ServerName ${server_name}
    DocumentRoot "${DEST_DIR}"

    SSLEngine on
    SSLCertificateFile "${cert_path}"
    SSLCertificateKeyFile "${key_path}"

    <Directory "${DEST_DIR}">
        Options Indexes FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>
</VirtualHost>
EOF
}

configure_selinux_for_apache() {
    if command -v semanage >/dev/null 2>&1; then
        semanage fcontext -a -t httpd_sys_content_t "${DEST_DIR}(/.*)?" 2>/dev/null ||
            semanage fcontext -m -t httpd_sys_content_t "${DEST_DIR}(/.*)?"
    fi

    if command -v restorecon >/dev/null 2>&1; then
        restorecon -R "$DEST_DIR" || true
    elif command -v chcon >/dev/null 2>&1; then
        chcon -R -t httpd_sys_content_t "$DEST_DIR" || true
    fi
}

configure_firewalld() {
    local changed=0

    if ! command -v firewall-cmd >/dev/null 2>&1; then
        log "firewalld is not installed; skipping firewall configuration"
        return
    fi

    if command -v systemctl >/dev/null 2>&1; then
        log "enabling and starting firewalld"
        systemctl enable --now firewalld
    fi

    log "opening HTTPS port 443/tcp in firewalld"
    if ! firewall-cmd --permanent --query-port=443/tcp >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port=443/tcp
        changed=1
    fi
    if ! firewall-cmd --permanent --query-service=https >/dev/null 2>&1; then
        firewall-cmd --permanent --add-service=https
        changed=1
    fi

    if ((changed)); then
        if ! firewall-cmd --reload; then
            warn "firewalld reload failed; restarting firewalld"
            systemctl restart firewalld
        fi
    else
        log "firewalld already allows HTTPS port 443/tcp"
    fi
}

configure_apache_service() {
    local server_name="$SERVER_NAME"

    if ((!CONFIGURE_APACHE)); then
        MIGRATION_YUM_MIRROR_URL="$(migration_yum_mirror_url "")"
        return
    fi
    if ((DRY_RUN)); then
        log "dry-run requested; skipping Apache, TLS, SELinux, and firewalld configuration"
        server_name="$(default_server_name)"
        MIGRATION_YUM_MIRROR_URL="$(migration_yum_mirror_url "$server_name")"
        return
    fi

    [[ -n "$server_name" ]] || server_name="$(default_server_name)"
    [[ -n "$server_name" ]] || die "unable to determine Apache server name"
    validate_server_name "$server_name"

    install_apache_packages
    write_apache_certificate "$server_name"
    write_apache_config "$server_name"
    configure_selinux_for_apache

    require_cmd httpd
    require_cmd systemctl
    httpd -t
    systemctl enable --now httpd
    configure_firewalld

    MIGRATION_YUM_MIRROR_URL="$(migration_yum_mirror_url "$server_name")"
    log "Apache yum mirror is available at https://${server_name}/repo/OracleLinux/"
}

report_migration_yum_mirror_url() {
    local output_file="${DEST_DIR}/migrate-to-oracle-linux-yum-mirror.txt"

    if [[ -z "$MIGRATION_YUM_MIRROR_URL" ]]; then
        warn "no public mirror URL was configured; pass --public-base-url or --server-name to report the migrate-to-oracle-linux.sh --yum-mirror value"
        return 0
    fi

    log "use this mirror with migrate-to-oracle-linux.sh: --yum-mirror ${MIGRATION_YUM_MIRROR_URL}"
    log "example: ./migrate-to-oracle-linux.sh --yum-mirror ${MIGRATION_YUM_MIRROR_URL}"

    if ((DRY_RUN)); then
        return 0
    fi

    {
        printf 'Use this mirror with migrate-to-oracle-linux.sh:\n'
        printf '  --yum-mirror %s\n' "$MIGRATION_YUM_MIRROR_URL"
        printf '\n'
        printf 'Example:\n'
        printf '  ./migrate-to-oracle-linux.sh --yum-mirror %s\n' "$MIGRATION_YUM_MIRROR_URL"
        printf '\n'
        printf 'Oracle Linux repository root:\n'
        printf '  %s/repo/OracleLinux/\n' "$MIGRATION_YUM_MIRROR_URL"
    } > "$output_file"
    log "wrote migrate-to-oracle-linux mirror usage file: ${output_file}"
}

process_release_arch() {
    local major="$1"
    local arch="$2"
    local source_repo="${WORK_DIR}/oracle-linux-${major}.repo"
    local sync_repo="${WORK_DIR}/oracle-linux-${major}-${arch}.repo"
    local client_repo="${DEST_DIR}/repo-files/oracle-linux-${major}-${arch}.repo"
    local manifest="${DEST_DIR}/manifests/oracle-linux-${major}-${arch}.tsv"
    local latest_uek

    if [[ ! -s "$source_repo" ]]; then
        download_release_repo_file "$major" "$source_repo"
        if ((WEB_DISCOVERY)); then
            log "adding Oracle yum page repository entries for OL${major}"
            append_web_repositories "$major" "$source_repo"
        fi
    fi
    append_curated_repositories "$major" "$source_repo"

    latest_uek="$(latest_uek_release_from_repo_file "$source_repo" "$major" "$arch")"
    if [[ "$latest_uek" =~ ^[1-9][0-9]*$ ]]; then
        log "using only latest UEK kernel repository for OL${major} ${arch}: UEKR${latest_uek}"
    fi

    log "building repo definitions for OL${major} ${arch}"
    write_repo_files_for_arch "$source_repo" "$major" "$arch" "$sync_repo" "$client_repo" "$manifest" "$PUBLIC_BASE_URL" "$latest_uek"
    sync_repositories_from_manifest "$sync_repo" "$arch" "$manifest"
}

main() {
    local major arch

    parse_args "$@"
    prepare
    trap cleanup EXIT

    IFS=',' read -r -a release_items <<< "$RELEASES"
    IFS=',' read -r -a arch_items <<< "$ARCHES"

    for major in "${release_items[@]}"; do
        mirror_gpg_key "$major"
        for arch in "${arch_items[@]}"; do
            process_release_arch "$major" "$arch"
        done
    done

    configure_apache_service
    report_migration_yum_mirror_url
    log "mirror completed: ${DEST_DIR}"
}

main "$@"
