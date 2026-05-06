# 🐧 migrate-to-oracle-linux

This repository contains two scripts for Oracle Linux migration workflows:

- 🔄 `migrate-to-oracle-linux.sh` migrates supported Enterprise Linux systems to
  Oracle Linux, including the Amazon Linux 2 to Oracle Linux 7 exception.
- 🪞 `mirror-oracle-linux-yum.sh` builds an Oracle Linux yum mirror that migration
  targets can use instead of reaching `yum.oracle.com` directly.

**NOTE: those scripts are based on a community effort and are not officially supported by Oracle.**

## 📍 Where To Run Each Script

🪞 Run `mirror-oracle-linux-yum.sh` only on the yum mirror system.

🎯 Run `migrate-to-oracle-linux.sh` on each system that will be migrated to Oracle
Linux.

These are separate roles. The mirror script prepares and serves Oracle Linux
repositories. The migration script changes the operating system installed on a
target host.

## 📚 Main Documentation

- 🔄 [Migration script README](README-migrate-to-oracle-linux.md)
- 🪞 [Yum mirror script README](README-mirror-oracle-linux-yum.md)

## 🚀 Typical Workflow

1. 🪞 On the yum mirror system, build and publish the Oracle Linux mirror:

   ```bash
   sudo ./mirror-oracle-linux-yum.sh \
     --dest /srv/mirror \
     --public-base-url https://yum-mirror.example.com \
     --jobs 4
   ```

2. 📝 Note the `--yum-mirror` value reported by the mirror script.

3. 🎯 On each system being migrated, run the migration script:

   ```bash
   sudo ./migrate-to-oracle-linux.sh -y --yum-mirror https://yum-mirror.example.com
   ```

The mirror script writes the migration mirror value to:

```text
<dest>/migrate-to-oracle-linux-yum-mirror.txt
```

## 🌐 Direct Internet Workflow

If migration targets can reach `yum.oracle.com` directly, the mirror is optional:

```bash
sudo ./migrate-to-oracle-linux.sh -y
```

For proxied internet access, run the migration script on the target system with
`--proxy`:

```bash
sudo ./migrate-to-oracle-linux.sh -y --proxy http://myproxy.example.com:3128
```

`--proxy` cannot be used with `--yum-mirror`.

## 🧪 Development

```bash
make check
```

The Vagrant scaffolding under `tests/vagrant` is for smoke testing. It is not a
substitute for testing real subscribed RHEL systems.

## ⚖️ License

The shell scripts use UPL-1.0. See [LICENSE.txt](LICENSE.txt).
