# 🪞 mirror-oracle-linux-yum.sh

`mirror-oracle-linux-yum.sh` builds a local Oracle Linux yum mirror for OL7,
OL8, OL9, and OL10.

🪞 Run this script only on the yum mirror system.

⚠️ Do not run this script on the system being migrated unless that same system is
intended to become the yum mirror.

✅ Requirement: run it on Oracle Linux 8 or newer.

## ⚙️ Default Behavior

- 🖥️ mirrors `x86_64` and `aarch64`;
- 📦 uses a curated Oracle Linux repository set for migration targets;
- 🧱 includes OL8, OL9, and OL10 BaseOS minor-release repositories;
- 7️⃣ excludes OL7 minor-release repositories;
- 🏷️ keeps Oracle repo IDs and `name=` values from Oracle release repo files when
  available;
- 🔎 adds repositories listed on Oracle yum index pages and stores their page
  description in `description=` when they match the curated set;
- 🚫 excludes source RPM repositories and does not mirror `.src.rpm` packages;
- 📚 mirrors all available binary RPM builds in each selected repository;
- 🧠 mirrors only the latest UEK kernel repository for each OL major release;
- 🔁 runs `reposync --download-metadata --delete --remote-time`,
  preserving upstream metadata, including modularity metadata;
- ⚡ supports parallel repository syncs with `--jobs` by isolating dnf cache,
  persist, and log directories per repository worker;
- 🌐 configures Apache to serve the mirror over HTTPS from the same public path
  used by `yum.oracle.com`;
- 🔐 creates a self-signed Apache certificate when one is not already present;
- 🛡️ labels the mirror directory for Apache when SELinux tools are available;
- 🔥 opens HTTPS port `443/tcp` in firewalld when firewalld is installed.

## 🗂️ Mirrored Repositories

The default repository set is:

| Oracle Linux major | Repositories |
| --- | --- |
| OL7 | `addons`, `developer`, `developer_EPEL`, `developer_nodejs10`, `developer_php72`, `kvm`, `latest`, `leapp`, `optional`, `preview`, `security`, `SoftwareCollections`, `UEKR6` |
| OL8 | `0`, `1`, `2`, `3`, `4`, `5`, `6`, `7`, `8`, `9`, `10`, `addons`, `appstream`, `developer`, `developer_EPEL`, `baseos`, `kvm`, `codeready`, `distro`, `UEKR7` |
| OL9 | `0`, `1`, `2`, `3`, `4`, `5`, `6`, `7`, `addons`, `appstream`, `developer`, `developer_EPEL`, `baseos`, `kvm`, `codeready`, `distro`, `UEKR8` |
| OL10 | `0`, `1`, `addons`, `appstream`, `developer`, `developer_EPEL`, `baseos`, `kvm`, `codeready`, `distro`, `UEKR8` |

Repository paths keep the Oracle public yum layout under
`/repo/OracleLinux/OL<major>/.../<arch>/`.

## 🚀 Usage

Run on the yum mirror system:

```bash
sudo ./mirror-oracle-linux-yum.sh \
  --dest /srv/mirror \
  --public-base-url https://yum-mirror.example.com \
  --jobs 4
```

The mirror keeps the Oracle public yum path. For example:

```text
https://yum.oracle.com/repo/OracleLinux/OL10/baseos/latest/x86_64/
https://yum-mirror.example.com/repo/OracleLinux/OL10/baseos/latest/x86_64/
```

At the end of a successful mirror run, the script prints the exact
`migrate-to-oracle-linux.sh --yum-mirror` value to use on migration targets. It
also writes the same information to:

```text
<dest>/migrate-to-oracle-linux-yum-mirror.txt
```

## 💾 Disk Space Estimate

Repository size changes as Oracle publishes new packages. The values below are
planning estimates for the default mirror behavior: binary RPMs only, all
available RPM builds from each selected repository, minor-release repositories
for OL8, OL9, and OL10, no OL7 minor repositories, and only the latest UEK
kernel repository per major release.

Reserve at least 20-30% additional free space for metadata, temporary files,
future package growth, and filesystem overhead.

| Oracle Linux major | Architecture | Estimated mirror size |
| --- | --- | --- |
| OL7 | `x86_64` | 450-700 GB |
| OL7 | `aarch64` | 150-250 GB |
| OL8 | `x86_64` | 900 GB-1.4 TB |
| OL8 | `aarch64` | 650 GB-1.0 TB |
| OL9 | `x86_64` | 700 GB-1.1 TB |
| OL9 | `aarch64` | 500-850 GB |
| OL10 | `x86_64` | 250-450 GB |
| OL10 | `aarch64` | 220-400 GB |

For a full default mirror of OL7, OL8, OL9, and OL10 for both `x86_64` and
`aarch64`, plan for roughly 4-6 TB usable space before local retention,
snapshot, backup, or filesystem overhead policies.

## 🎛️ Options

```text
--release-list 8,9       Mirror selected OL major releases
--arch-list x86_64       Mirror selected architectures
--jobs N                 Number of repositories to sync in parallel
--include-ol7-minors     Include OL7 update media repositories
--no-web-discovery       Use only Oracle release repo files
--server-name NAME       Apache TLS certificate common name
--no-configure-apache    Only build the mirror content and repo files
--fail-unavailable       Fail instead of skipping unavailable repo/arch pairs
--dry-run                Build repo files and print reposync commands only
```

## 📁 Output Layout

```text
<dest>/RPM-GPG-KEY-oracle-ol<major>
<dest>/repo/OracleLinux/OL<major>/<repository-path>/<arch>/
<dest>/repo-files/oracle-linux-<major>-<arch>.repo
<dest>/manifests/oracle-linux-<major>-<arch>.tsv
<dest>/migrate-to-oracle-linux-yum-mirror.txt
```

## 🎯 Using The Mirror For Migration

After the mirror is available, run `migrate-to-oracle-linux.sh` on each system
that will be migrated:

```bash
sudo ./migrate-to-oracle-linux.sh -y --yum-mirror https://yum-mirror.example.com
```

Pass only the HTTPS origin to `--yum-mirror`. Do not include
`/repo/OracleLinux/...`; the migration script builds the Oracle public yum paths
itself.
