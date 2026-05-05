# 🔄 migrate-to-oracle-linux.sh

`migrate-to-oracle-linux.sh` migrates supported Enterprise Linux systems to
Oracle Linux.

🎯 Run this script on the system that will be migrated to Oracle Linux.

⚠️ Do not run this script on the yum mirror server unless that mirror server is
itself the system being migrated.

🚫 Major upgrades are not supported. A 7.x source can target only Oracle Linux 7
latest; an 8.x source can target only Oracle Linux 8.x or 8 latest.

✨ Exception: Amazon Linux 2 is treated as an EL7-compatible source and targets
Oracle Linux 7 latest.

## ✅ Supported Sources

Architectures:

- 🖥️ `x86_64`
- 🔧 `aarch64`

| Source | Supported releases | Target |
| --- | --- | --- |
| CentOS Linux | 7.9, 8.4+ | OL 7 latest, OL 8 |
| CentOS Stream | 8, 9, 10 | OL latest in the same major |
| AlmaLinux | 8, 9, 10 | OL 8, 9, 10 |
| Amazon Linux | 2 | OL 7 latest |
| Red Hat Enterprise Linux | 7.9, 8, 9, 10 | OL 7 latest, OL 8, 9, 10 |
| Rocky Linux | 8, 9, 10 | OL 8, 9, 10 |

Unsupported:

- 🚫 cross-major migrations, such as 8.x to 9.x;
- 🚫 fixed-minor targets for EL7;
- 🚫 fixed-minor targets for CentOS Stream;
- 🚫 RHCK on `aarch64`.

## 🧭 Migration Modes

| Mode | Selection | Behavior |
| --- | --- | --- |
| Same release | Omit `--target-version` on fixed-minor sources, or pass the current version | Replaces release packages, reinstalls exact Oracle NEVRAs, then uses nearest Oracle EVRs where needed. Higher EVRs are preferred; lower EVRs are last fallback. |
| Specific newer release | `--target-version 8.10`, `--target-version 9.7`, etc. | Replaces release packages and syncs installed RPMs to the selected same-major Oracle Linux release. |
| Latest | `--target-version latest` | Replaces release packages and syncs installed RPMs to Oracle Linux latest repositories, including `baseos_latest` or `ol7_latest`. |

Special cases:

- 🌊 CentOS Stream always targets Oracle Linux latest within the same major.
- 7️⃣ RHEL 7.9 and CentOS Linux 7.9 always target Oracle Linux 7 latest.
- ✨ Amazon Linux 2 always targets Oracle Linux 7 latest.
- 🕒 `tzdata` and `ca-certificates` may use newer Oracle Linux builds in
  same-release mode and are not downgraded unless no other replacement exists.
- 🧹 RHEL subscription-management packages, Red Hat-only support packages, and
  `gpg-pubkey` pseudo-packages are removed and reported as
  `removed-rhel-only`.
- ✨ Amazon Linux 2 uses an exception path to OL 7 latest. Amazon-only packages
  with no OL 7 equivalent are removed and reported as `removed-amazon-only`;
  required OL providers such as `oracle-logos`, `python-setuptools`, and
  `python-six` are installed after the OL sync.
- 🔁 On RHEL sources, `--reinstall-all` is enabled automatically unless
  `--no-reinstall-all` is passed.
- 📦 Third-party packages are reported as `3rd Party` and are not treated as
  Oracle replacements.

## 🧠 Kernel Selection

Default: install UEK and set it as the default boot kernel.

```bash
sudo ./migrate-to-oracle-linux.sh -y --kernel uek
sudo ./migrate-to-oracle-linux.sh -y --kernel rhck
```

Accepted values:

- `uek`
- `rhck` on `x86_64` only

Aliases:

- `--uek`
- `--rhck` on `x86_64` only

On `aarch64`, Oracle Linux RHCK is not available. The script always uses UEK
and rejects `--kernel rhck`.

UEK repositories:

| Oracle Linux major | UEK repository |
| --- | --- |
| 7 | `ol7_UEKR6` |
| 8 | `ol8_UEKR7` |
| 9 | `ol9_UEKR8` |
| 10 | `ol10_UEKR8` |

## 🚀 Usage

Run on the system being migrated:

```bash
curl -O https://raw.githubusercontent.com/<owner>/migrate-to-oracle-linux/main/migrate-to-oracle-linux.sh
chmod +x migrate-to-oracle-linux.sh
sudo ./migrate-to-oracle-linux.sh -y
```

Dry run:

```bash
sudo ./migrate-to-oracle-linux.sh --dry-run
```

Options:

```text
-y, --assumeyes              Run package operations non-interactively
    --dry-run                Print commands and write reports without changes
    --reinstall-all          Attempt exact reinstall for every installed RPM
    --no-reinstall-all       Only exact reinstall source-vendor packages
    --target-version VERSION Use same-major target version, such as 8.6, or latest
    --kernel FLAVOR          Select uek or rhck; aarch64 always uses uek
    --yum-mirror URL         Use mirror origin, such as https://yum-mirror.example.com
    --proxy URL              Use HTTP proxy for yum/dnf, such as http://myproxy.example.com:3128
    --strict-evr             Stop when exact Oracle NEVRAs are unavailable
    --no-strict-evr          Continue when exact NEVRAs are unavailable; default
    --no-reboot-check        Skip newest-installed-kernel boot check
    --keep-bootstrap-repos   Keep temporary Oracle bootstrap repo file
    --debug                  Enable shell tracing
-h, --help                   Show help
-V, --version                Show version
```

Use `--strict-evr` only when exact package release preservation is mandatory.
Default non-strict mode is more practical: it uses exact Oracle NEVRAs when
available, then nearest Oracle replacements.

`--yum-mirror` accepts only the HTTPS origin. Do not include
`/repo/OracleLinux/...`; the script builds the Oracle public yum paths itself.
For example, `--yum-mirror https://yum-mirror.example.com` makes the OL10 BaseOS
Latest bootstrap URL:

```text
https://yum-mirror.example.com/repo/OracleLinux/OL10/baseos/latest/x86_64/
```

When `--yum-mirror` is used, the temporary Oracle repository definitions set
`sslverify=0`, and yum/dnf commands receive `--setopt=sslverify=0`. This allows
local mirrors that use self-signed certificates or certificates whose hostname
does not match the mirror hostname. RPM GPG signature checking remains enabled.

`--proxy` accepts an HTTP proxy URL and configures it in the system yum/dnf
configuration before Oracle repositories are used. It also passes the proxy to
all migration yum/dnf commands. `--proxy` cannot be used with `--yum-mirror`.

## 🛠️ What The Script Does

1. ✅ Validates source OS, release, architecture, and target version.
2. 📝 Records `/etc/os-release`, enabled repositories, hostname, and RPM database.
3. 🔍 Verifies the RPM database.
4. 🧠 Requires the newest installed kernel to be booted unless
   `--no-reboot-check` is passed.
5. 📦 Adds temporary Oracle Linux bootstrap repositories.
6. 🚫 Disables source distribution repositories.
7. 🧹 Removes source release packages.
8. 🧹 Removes RHEL-only packages on RHEL sources.
9. 🐧 Installs Oracle Linux release packages.
10. 🔁 Replaces installed RPMs:
    - same-release mode: exact Oracle NEVRAs, nearest higher EVRs, then nearest
      lower EVRs;
    - specific-release/latest mode: Oracle Linux `distro-sync --nobest`.
11. 🧠 Installs the selected Oracle Linux kernel flavor.
12. 🔍 Rechecks source-vendor RPMs and replaces remaining RHEL-vendor packages
    when Oracle replacements exist.
13. ✅ Verifies `ID=ol` and the requested target version.
14. 📊 Writes TSV and HTML reports.

## 📊 Reports

Every run creates:

```text
/var/lib/migrate-to-oracle-linux/<run-id>/
/var/log/migrate-to-oracle-linux/<run-id>.log
```

Key files:

| File | Purpose |
| --- | --- |
| `rpmdb.before.tsv` | Pre-migration RPM inventory |
| `rpmdb.after.tsv` | Post-migration RPM inventory |
| `enabled-repos.before` | Enabled repositories before migration |
| `enabled-repos.after` | Enabled repositories after migration |
| `exact-reinstall.nevra` | Same-release exact Oracle replacements |
| `nearest-higher-reinstall.nevra` | Same-release nearest higher Oracle replacements |
| `nearest-lower-reinstall.nevra` | Same-release nearest lower Oracle fallback replacements |
| `update-exception-reinstall.nevra` | `tzdata` and `ca-certificates` replacements |
| `unavailable-reinstall.nevra` | Packages without an Oracle replacement |
| `missing-exact.nevra` | Packages without exact Oracle NEVRAs |
| `rhel-only-packages.removed.tsv` | RHEL-only packages intentionally removed |
| `redhat-vendor-oracle-reinstall.nevra` | Remaining Red Hat-vendor RPMs reinstalled from Oracle repos |
| `redhat-vendor-oracle-replacement-install.nevra` | Non-exact Oracle replacements for remaining Red Hat-vendor RPMs |
| `redhat-vendor-source-removal.nvra` | Red Hat-vendor RPM instances removed after replacement |
| `redhat-vendor-oracle-unavailable.tsv` | Red Hat-vendor RPMs without Oracle replacement |
| `kernel-flavor.selected` | Selected kernel flavor |
| `kernel-default.verified` | Final default boot kernel reported by `grubby` |
| `migration-rpm-map.tsv` | Machine-readable RPM migration map |
| `migration-rpm-map.html` | Main HTML RPM migration report |

Legacy same-release HTML summaries may also be written:

- `reinstalled-oracle-exact.html`
- `reinstalled-oracle-nearest.html`
- `not-reinstalled-oracle.html`

`migration-rpm-map.html` includes:

- hostname;
- migration time in `HH:MM:SS`;
- source `/etc/os-release`;
- target `/etc/os-release`;
- architecture;
- selected kernel flavor;
- vendor package counts after migration.

Status colors:

| Status | Meaning | Color |
| --- | --- | --- |
| `exact` | Reinstalled with identical Oracle NEVRA | Light green |
| `reinstalled; same release` | Reinstalled without EVRA change | Light green |
| `nearest-higher-release` | Replaced with nearest higher Oracle EVR | Light yellow |
| `nearest-lower-release` | Replaced with nearest lower Oracle EVR | Light orange |
| `updated` | Target Oracle package is newer | Light blue |
| `downgraded` | Target Oracle package is older | Light orange |
| `3rd Party` | Non-source-vendor, non-Oracle package | Light orange |
| `replaced-distribution-package` | Source release package replaced by Oracle release package | Light blue |
| `replaced-by-linux-firmware` | EL10 split firmware package replaced by Oracle `linux-firmware` packages | Light blue |
| `removed-rhel-only` | RHEL-only package intentionally removed | Light red |
| `removed-source-kernel` | Source-vendor runtime kernel removed after Oracle kernel install | Light red |
| `unavailable` | No Oracle replacement found | Light red |
| `source-vendor-retained` | Source-vendor package remains installed | Light red |
| `skipped` | Source RPM was unexpectedly not found after migration | Light red |

## 🧯 Operational Notes

- 📸 Take a VM snapshot or full system backup first.
- 📦 Remove or disable third-party repositories unless intentionally retained.
- 🔄 Reboot after migration to start the selected Oracle Linux kernel.
- 🔐 Test RHEL migrations on subscribed systems with access to required package
  metadata.
