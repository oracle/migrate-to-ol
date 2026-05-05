# Testing

Migration testing must be done on disposable systems. Use VM snapshots and keep
console access available in case repository or bootloader state needs manual
repair.

## Suggested Matrix

| Source | Release | Expected target |
| --- | --- | --- |
| CentOS Linux | 7.9 | Oracle Linux 7 latest |
| CentOS Linux | 8.4 or newer | Oracle Linux 8 |
| CentOS Stream | 8, 9, 10 | Oracle Linux latest within the matching major |
| AlmaLinux | 8, 9, 10 | Oracle Linux matching major |
| RHEL | 7.9 | Oracle Linux 7 latest |
| RHEL | 8, 9, 10 | Oracle Linux matching major |
| Rocky Linux | 8, 9, 10 | Oracle Linux matching major |

## Basic Smoke Test

```bash
sudo ./migrate-to-oracle-linux.sh --dry-run
sudo ./migrate-to-oracle-linux.sh -y
sudo reboot
cat /etc/os-release
rpm -q oraclelinux-release-el$(rpm -E '%{rhel}')
dnf repolist --enabled
```

## RHEL Exact Reinstall Validation

Before migration:

```bash
rpm -qa --qf '%{nevra}\n' | sort -u > /root/before.nevra
```

After migration:

```bash
rpm -qa --qf '%{nevra}\n' | sort -u > /root/after.nevra
comm -23 /root/before.nevra /root/after.nevra
```

Expected differences are release/repository/GPG packages and packages listed in
`/var/lib/migrate-to-oracle-linux/<run-id>/missing-exact.nevra`.
