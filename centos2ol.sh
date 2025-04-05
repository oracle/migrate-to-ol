#!/bin/bash
# Copyright (c) 2020, 2021 Oracle and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl.
#
# Script to switch CentOS (or other similar distribution) to the
# Oracle Linux yum repository.
#

set -e
unset CDPATH

yum_url=https://yum.oracle.com
github_url=https://github.com/oracle/centos2ol/
arch=$(uname -m)
bad_packages=(centos-backgrounds centos-gpg-keys centos-logos centos-release centos-release-cr desktop-backgrounds-basic \
              centos-release-advanced-virtualization centos-release-ansible26 centos-release-ansible-27 \
              centos-release-ansible-28 centos-release-ansible-29 centos-release-azure \
              centos-release-ceph-jewel centos-release-ceph-luminous centos-release-ceph-nautilus \
              centos-release-ceph-octopus centos-release-configmanagement centos-release-dotnet centos-release-fdio \
              centos-release-gluster40 centos-release-gluster41 centos-release-gluster5 \
              centos-release-gluster6 centos-release-gluster7 centos-release-gluster8 \
              centos-release-gluster-legacy centos-release-messaging centos-release-nfs-ganesha28 \
              centos-release-nfs-ganesha30 centos-release-nfv-common \
              centos-release-nfv-openvswitch centos-release-openshift-origin centos-release-openstack-queens \
              centos-release-openstack-rocky centos-release-openstack-stein centos-release-openstack-train \
              centos-release-openstack-ussuri centos-release-opstools centos-release-ovirt42 centos-release-ovirt43 \
              centos-release-ovirt44 centos-release-paas-common centos-release-qemu-ev centos-release-qpid-proton \
              centos-release-rabbitmq-38 centos-release-samba411 centos-release-samba412 \
              centos-release-scl centos-release-scl-rh centos-release-storage-common \
              centos-release-virt-common centos-release-xen centos-release-xen-410 \
              centos-release-xen-412 centos-release-xen-46 centos-release-xen-48 centos-release-xen-common \
              libreport-centos libreport-plugin-mantisbt libreport-plugin-rhtsupport python3-syspurpose \
              python-oauth rocky-backgrounds rocky-gpg-keys rocky-logos rocky-release sl-logos yum-rhn-plugin)

usage() {
    echo "Usage: ${0##*/} [OPTIONS]"
    echo
    echo "OPTIONS"
    echo "-h"
    echo "        Display this help and exit"
    echo "-k"
    echo "        Do not install the UEK kernel and disable UEK repos"
    echo "-r"
    echo "        Reinstall all CentOS RPMs with Oracle Linux RPMs"
    echo "        Note: This is not necessary for support"
    echo "-V"
    echo "        Verify RPM information before and after the switch"
    exit 1
} >&2

have_program() {
    hash "$1" >/dev/null 2>&1
}

dep_check() {
    if ! have_program "$1"; then
        exit_message "'${1}' command not found. Please install or add it to your PATH and try again."
    fi
}

exit_message() {
    echo "$1"
    echo "For assistance, please open an issue via GitHub: ${github_url}."
    exit 1
} >&2

final_failure() {
    echo "An error occurred while attempting to switch this system to Oracle Linux and it may be in an unstable/unbootable state. To avoid further issues, the script has terminated."
}

generate_rpms_info() {
    echo "Creating a list of RPMs installed $1 the switch"
    rpm -qa --qf "%{NAME}-%{EPOCH}:%{VERSION}-%{RELEASE}.%{ARCH}|%{INSTALLTIME}|%{VENDOR}|%{BUILDTIME}|%{BUILDHOST}|%{SOURCERPM}|%{LICENSE}|%{PACKAGER}\n" | sed 's/(none)://g' | sort > "/var/tmp/$(hostname)-rpms-list-$1.log"
    echo "Verifying RPMs installed $1 the switch against RPM database"
    rpm -Va | sort -k3 > "/var/tmp/$(hostname)-rpms-verified-$1.log"
}

## Start of script

reinstall_all_rpms=false

verify_all_rpms=false

install_uek_kernel=true

while getopts "hrkV" option; do
    case "$option" in
        h) usage ;;
        r) reinstall_all_rpms=true ;;
        k) install_uek_kernel=false ;;
        V) verify_all_rpms=true ;;
        *) usage ;;
    esac
done

# Force the UEK on Arm hosts
if [ "$arch" == "aarch64" ]; then
    install_uek_kernel=true
fi

if [ "$(id -u)" -ne 0 ]; then
    exit_message "You must run this script as root.
Try running 'su -c ${0}'."
fi

echo "Checking for required packages..."
for pkg in rpm yum curl; do
    dep_check "${pkg}"
done

echo "Checking your distribution..."
if ! old_release=$(rpm -q --whatprovides /etc/redhat-release); then
    exit_message "You appear to be running an unsupported distribution."
fi

if [ "$(echo "${old_release}" | wc -l)" -ne 1 ]; then
    exit_message "Could not determine your distribution because multiple
packages are providing redhat-release:
$old_release
"
fi

# Collect information about RPMs before the switch
if "${verify_all_rpms}"; then
    generate_rpms_info before
fi

case "${old_release}" in
    redhat-release*) ;;
    centos-release* | centos-linux-release*) ;;
    rocky-release*) ;;
    sl-release*) ;;
    oraclelinux-release*|enterprise-release*)
        exit_message "You appear to be already running Oracle Linux."
        ;;
    *) exit_message "You appear to be running an unsupported distribution." ;;
esac

os_version=$(rpm -q "${old_release}" --qf "%{version}")
major_os_version=${os_version:0:1}
if "${install_uek_kernel}"; then
  base_packages=(basesystem initscripts oracle-logos kernel-uek)
else
  base_packages=(basesystem initscripts oracle-logos)
fi

case "$os_version" in
    9*)
	repo_file=public-yum-ol9.repo
	new_releases=(oraclelinux-release oraclelinux-release-el9 redhat-release)
	base_packages=("${base_packages[@]}" plymouth grub2 grubby)
	;;
    8*)
        repo_file=public-yum-ol8.repo
        new_releases=(oraclelinux-release oraclelinux-release-el8 redhat-release)
        base_packages=("${base_packages[@]}" plymouth grub2 grubby)
        ;;
    7*)
        repo_file=public-yum-ol7.repo
        new_releases=(oraclelinux-release oraclelinux-release-el7 redhat-release-server)
        base_packages=("${base_packages[@]}" plymouth grub2 grubby)
        ;;
    6*)
        repo_file=public-yum-ol6.repo
        new_releases=(oraclelinux-release oraclelinux-release-el6 redhat-release-server)
        base_packages=("${base_packages[@]}" oraclelinux-release-notes plymouth grub grubby)
        ;;
    *) exit_message "You appear to be running an unsupported distribution." ;;
esac

# Some packages need to be replaced as part of switch
# Store as key value, if the first RPM is found then it's removed and the associated RPM installed
declare -A packages_to_replace=(
    [epel-release]="oracle-epel-release-el${major_os_version}"
)
# Switch RPMs if they're installed
for package_name in "${!packages_to_replace[@]}"; do
    if rpm -q "${package_name}" ; then
        bad_packages+=("${package_name}")
        base_packages+=("${packages_to_replace[${package_name}]}")
    fi
done


echo "Checking for yum lock..."
if [ -f /var/run/yum.pid ]; then
    yum_lock_pid=$(cat /var/run/yum.pid)
    yum_lock_comm=$(cat "/proc/${yum_lock_pid}/comm")
    exit_message "Another app is currently holding the yum lock.
The other application is: $yum_lock_comm
Running as pid: $yum_lock_pid
Run 'kill $yum_lock_pid' to stop it, then run this script again."
fi

echo "Checking for required python packages..."
case "$os_version" in
    8* | 9* )
        dep_check /usr/libexec/platform-python
        ;;
    *)
        dep_check python2
        ;;
esac

if [[ "$os_version" =~ 8.* ]]; then
    echo "Identifying dnf modules that are enabled"
    # There are a few dnf modules that are named after the distribution
    #  for each steam named 'rhel' or 'rhel8' we need to make alterations to 'ol' or 'ol8'
    #  Before we start the switch, identify if there are any present we don't know how to handle
    mapfile -t modules_enabled < <(dnf module list --enabled | grep rhel | awk '{print $1}')
    if [[ "${modules_enabled[*]}" ]]; then
        # Create an array of modules we don't know how to manage
        unknown_modules=()
        for module in "${modules_enabled[@]}"; do
            case ${module} in
                container-tools|go-toolset|jmc|llvm-toolset|rust-toolset|virt)
                    ;;
                *)
                    # Add this module name to our array of modules we don't know how to manage
                    unknown_modules+=("${module}")
                    ;;
            esac
        done
        # If we have any modules we don't know how to manage, ask the user how to proceed
        if [ ${#unknown_modules[@]} -gt 0 ]; then
            echo "This tool is unable to automatically switch module(s) '${unknown_modules[*]}' from a CentOS 'rhel' stream to
an Oracle Linux equivalent. Do you want to continue and resolve it manually?
You may want select No to stop and raise an issue on ${github_url} for advice."
            select yn in "Yes" "No"; do
                case $yn in
                    Yes )
                        break
                        ;;
                    No )
                        echo "Unsure how to switch module(s) '${unknown_modules[*]}'. Exiting as requested"
                        exit 1
                        ;;
                esac
            done
        fi
    fi
fi

echo "Finding your repository directory..."
case "$os_version" in
    8* | 9* )
reposdir=$(/usr/libexec/platform-python -c "
import dnf
import os

dir = dnf.Base().conf.get_reposdir
if os.path.isdir(dir):
    print(dir)
")
        ;;
    *)
        reposdir=$(python2 -c "
import yum
import os

for dir in yum.YumBase().doConfigSetup(init_plugins=False).reposdir:
    if os.path.isdir(dir):
        print dir
        break
")
        ;;
esac

echo "Learning which repositories are enabled..."
case "$os_version" in
    8* | 9* )
        enabled_repos=$(/usr/libexec/platform-python -c "
import dnf

base = dnf.Base()
base.read_all_repos()
for repo in base.repos.iter_enabled():
  print(repo.id)
")
        ;;
    *)
        enabled_repos=$(python2 -c "
import yum

base = yum.YumBase()
base.doConfigSetup(init_plugins=False)
for repo in base.repos.listEnabled():
  print repo
")
        ;;
esac
echo -e "Repositories enabled before update include:\n${enabled_repos}"

if [ -z "${reposdir}" ]; then
    exit_message "Could not locate your repository directory."
fi
cd "$reposdir"

# No https://yum.oracle.com/public-yum-ol8.repo file exists
# Download the content for 6 and 7 based systems and directly enter the content for 8 based systems
case "$os_version" in


    9*)
         cat > "switch-to-oraclelinux.repo" <<-'EOF'
		[ol9_baseos_latest]
		name=Oracle Linux 9 BaseOS Latest ($basearch)
		baseurl=https://yum.oracle.com/repo/OracleLinux/OL9/baseos/latest/$basearch/
		gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle
		gpgcheck=1
		enabled=1

		[ol9_appstream]
		name=Oracle Linux 9 Application Stream ($basearch)
		baseurl=https://yum.oracle.com/repo/OracleLinux/OL9/appstream/$basearch/
		gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle
		gpgcheck=1
		enabled=1

EOF
        if [ "$arch" == "x86_64" ]; then
            cat >> "switch-to-oraclelinux.repo" <<-'EOF'
    		[ol9_UEKR7]
		name=Latest Unbreakable Enterprise Kernel Release 7 for Oracle Linux $releasever ($basearch)
		baseurl=https://yum.oracle.com/repo/OracleLinux/OL9/UEKR7/$basearch/
		gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle
		gpgcheck=1
		enabled=1
EOF
        fi
        ;;
    8*)
        cat > "switch-to-oraclelinux.repo" <<-'EOF'
		[ol8_baseos_latest]
		name=Oracle Linux 8 BaseOS Latest ($basearch)
		baseurl=https://yum.oracle.com/repo/OracleLinux/OL8/baseos/latest/$basearch/
		gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle
		gpgcheck=1
		enabled=1

		[ol8_appstream]
		name=Oracle Linux 8 Application Stream ($basearch)
		baseurl=https://yum.oracle.com/repo/OracleLinux/OL8/appstream/$basearch/
		gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle
		gpgcheck=1
		enabled=1

EOF
        if [ "$arch" == "x86_64" ]; then
            cat >> "switch-to-oraclelinux.repo" <<-'EOF'
    		[ol8_UEKR6]
		name=Latest Unbreakable Enterprise Kernel Release 6 for Oracle Linux $releasever ($basearch)
		baseurl=https://yum.oracle.com/repo/OracleLinux/OL8/UEKR6/$basearch/
		gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle
		gpgcheck=1
		enabled=1
EOF
        fi
        ;;
    *)
        echo "Downloading Oracle Linux yum repository file..."
        if ! curl -o "switch-to-oraclelinux.repo" "${yum_url}/${repo_file}"; then
            exit_message "Could not download $repo_file from $yum_url.
        Are you behind a proxy? If so, make sure the 'http_proxy' environment
        variable is set with your proxy address."
        fi
        ;;
esac

echo "Looking for yumdownloader..."
if ! have_program yumdownloader; then
    # CentOS 6 mirrors are now offline, if yumdownloader tool is not present then
    #  use OL6 as source for yum-utils and disable all other repos.
    # Use the existing distributions copy for other platforms
    case "$os_version" in
        6*)
            curl -o /etc/pki/rpm-gpg/RPM-GPG-KEY-oracle https://yum.oracle.com/RPM-GPG-KEY-oracle-ol6
            yum -y install yum-utils --disablerepo \* --enablerepo ol6_latest || true
            ;;
        *)
            yum -y install yum-utils --disablerepo ol\* || true
            ;;
    esac
    dep_check yumdownloader
fi

cd "$(mktemp -d)"
trap final_failure ERR

# Most distros keep their /etc/yum.repos.d content in the -release rpm. CentOS 8 does not and the behaviour changes between
#  minor releases; 8.0 uses 'centos-repos' while 8.3 uses 'centos-linux-repos', glob for simplicity.
if [[ $old_release =~ ^centos-release-8.* ]] || [[ $old_release =~ ^centos-linux-release-8.* ]]; then
    old_release=$(rpm -qa centos*repos)
fi
# Most distros keep their /etc/yum.repos.d content in the -release rpm. Rocky Linux 8 does not.
if [[ $old_release =~ ^rocky-release-*.* ]]; then
    old_release=$(rpm -qa rocky*repos)
fi

echo "Backing up and removing old repository files..."
# Identify repo files from the base OS
rpm -ql "$old_release" | grep '\.repo$' > repo_files
# Identify repo files from 'CentOS extras'
if [ "$(rpm -qa "centos-release-*" | wc -l)" -gt 0 ] ; then
    rpm -qla "centos-release-*" | grep '\.repo$' >> repo_files
fi
while read -r repo; do
    if [ -f "$repo" ]; then
        cat - "$repo" > "$repo".disabled <<EOF
# This is a yum repository file that was disabled by
# ${0##*/}, a script to convert CentOS to Oracle Linux.
# Please see $yum_url for more information.

EOF
        tmpfile=$(mktemp repo.XXXXX)
        echo "$repo" | cat - "$repo" > "$tmpfile"
        rm "$repo"
    fi
done < repo_files

# Disable the explicit distroverpkg as centos-release provides the correct value
# for system-release(releasever).
# See https://github.com/oracle/centos2ol/issues/53
echo "Removing CentOS-specific yum configuration from /etc/yum.conf"
sed -i.bak -e 's/^distroverpkg/#&/g' -e 's/^bugtracker_url/#&/g' /etc/yum.conf

echo "Downloading Oracle Linux release package..."
if ! yumdownloader "${new_releases[@]}"; then
    {
        echo "Could not download the following packages from $yum_url:"
        echo "${new_releases[@]}"
        echo
        echo "Are you behind a proxy? If so, make sure the 'http_proxy' environment"
        echo "variable is set with your proxy address."
    } >&2
    final_failure
fi

echo "Switching old release package with Oracle Linux..."
rpm -i --force "${new_releases[@]/%/*.rpm}"
rpm -e --nodeps "$old_release"
rm -f "${reposdir}/switch-to-oraclelinux.repo"

# Disable UEK repos if UEK kernel is not being installed
if ! "${install_uek_kernel}"; then
  echo "Disabling UEK repositories since we are not installing the UEK kernel"
  yum-config-manager --disable \*UEK*
fi

# At this point, the switch is completed.
trap - ERR

# When an additional enabled CentOS repository has a match with Oracle Linux
#  then automatically enable the OL repository to ensure the RPM is maintained
#
# Create an associate array where the key is the CentOS reponame and the value
#  contains the method of getting the content (Enable a repo or install an RPM)
#  and the details of the repo or RPM
case "$os_version" in
    6*)
        declare -A repositories=(
            [base-debuginfo]="REPO https://oss.oracle.com/ol6/debuginfo/"
            [updates]="REPO ol6_latest"
        )
        ;;
    7*)
        declare -A repositories=(
            [base-debuginfo]="REPO https://oss.oracle.com/ol7/debuginfo/"
            [updates]="REPO ol7_latest,ol7_optional_latest"
            [centos-ceph-jewel]="RPM oracle-ceph-release-el7"
            [centos-gluster41]="RPM oracle-gluster-release-el7"
            [centos-gluster5]="RPM oracle-gluster-release-el7"
            [centos-gluster46]="RPM oracle-gluster-release-el7"
            [centos-nfs-ganesha30]="RPM oracle-gluster-release-el7"
            [centos-ovirt42]="RPM oracle-ovirt-release-el7"
            [centos-ovirt43]="RPM oracle-ovirt-release-el7"
            [centos-sclo-sclo]="RPM oracle-softwarecollection-release-el7"
            [centos-sclo-rh]="RPM oracle-softwarecollection-release-el7"
        )
        ;;

    9*)
        declare -A repositories=(
	    [AppStream]="REPO ol9_appstream"
            [appstream]="REPO ol9_appstream"
            [BaseOS]="REPO ol9_baseos_latest"
            [baseos]="REPO ol9_baseos_latest"
	)
	;;

    8*)
        declare -A repositories=(
            [AppStream]="REPO ol8_appstream"
            [appstream]="REPO ol8_appstream"
            [BaseOS]="REPO ol8_baseos_latest"
            [baseos]="REPO ol8_baseos_latest"
            [HighAvailability]="REPO ol8_addons"
            [ha]="REPO ol8_addons"
            [PowerTools]="REPO ol8_codeready_builder"
            [powertools]="REPO ol8_codeready_builder"
            [centos-release-nfs-ganesha28]="RPM oracle-gluster-release-el8"
            [centos-gluster6-test]="RPM oracle-gluster-release-el8"
            [centos-gluster7]="RPM oracle-gluster-release-el8"
            [centos-gluster8]="RPM oracle-gluster-release-el8"
        )
        ;;
esac

# For each entry in the list, enable it
for reponame in ${enabled_repos}; do
    # action[0] will be REPO or RPM
    # action[1] will be the repos details or the RPMs name
    IFS=" " read -r -a action <<< "${repositories[${reponame}]}"
    if [[ -n ${action[0]} ]]; then
        if [ "${action[0]}" == "REPO" ] ; then
            matching_repo=${action[1]}
            echo "Enabling ${matching_repo} which replaces ${reponame}"
            # An RPM that describes debuginfo repository does not exist
            #  check to see if the repo id starts with https, if it does then
            #  create a new repo pointing to the repository
            if [[ ${matching_repo} =~ https.* ]]; then
                yum-config-manager --add-repo "${matching_repo}"
            else
                yum-config-manager --enable "${matching_repo}"
            fi
        elif [ "${action[0]}" == "RPM" ] ; then
            matching_rpm=${action[1]}
            echo "Installing ${matching_rpm} to get content that replaces ${reponame}"
            yum --assumeyes --disablerepo "*" --enablerepo "ol*_latest" install "${matching_rpm}"
        fi
    fi
done

echo "Installing base packages for Oracle Linux..."
if ! yum shell -y <<EOF
remove ${bad_packages[@]}
install ${base_packages[@]}
run
EOF
then
    exit_message "Could not install base packages.
Run 'yum distro-sync' to manually install them."
fi
if [ -x /usr/libexec/plymouth/plymouth-update-initrd ]; then
    echo "Updating initrd..."
    /usr/libexec/plymouth/plymouth-update-initrd
fi

echo "Switch successful. Syncing with Oracle Linux repositories."

if ! yum -y distro-sync; then
    exit_message "Could not automatically sync with Oracle Linux repositories.
Check the output of 'yum distro-sync' to manually resolve the issue."
fi

# CentOS specific replacements
case "$os_version" in
    7*)
        # Prior to switch this is a dependency of the yum rpm, now we've switched we can remove it
        if rpm -q yum-plugin-fastestmirror; then
            yum erase -y yum-plugin-fastestmirror
        fi
        ;;
    8*)
        # There are a few dnf modules that are named after the distribution
        #  for each steam named 'rhel' or 'rhel8' perform a module reset and enable
        if [[ "${modules_enabled[*]}" ]]; then
            for module in "${modules_enabled[@]}"; do
                dnf module reset -y "${module}"
                case ${module} in
                container-tools|go-toolset|jmc|llvm-toolset|rust-toolset)
                    dnf module enable -y "${module}":ol8
                    ;;
                virt)
                    dnf module enable -y "${module}":ol
                    ;;
                *)
                    echo "Unsure how to transform module ${module}"
                    ;;
                esac
            done
            dnf --assumeyes --disablerepo "*" --enablerepo "ol8_appstream" update
        fi

        # Two logo RPMs aren't currently covered by 'replaces' metadata, replace by hand.
        if rpm -q centos-logos-ipa; then
            dnf swap -y centos-logos-ipa oracle-logos-ipa
        fi
        if rpm -q centos-logos-httpd; then
            dnf swap -y centos-logos-httpd oracle-logos-httpd
        fi
        ;;
esac

if "${reinstall_all_rpms}"; then
    echo "Testing for remaining CentOS RPMs"
    # If CentOS and Oracle Linux have identically versioned RPMs then those RPMs are left unchanged.
    #  This should have no technical impact but for completeness, reinstall these RPMs
    #  so there is no accidental cross pollination.
    case "$arch" in
        x86_64)
            mapfile -t list_of_centos_rpms < <(rpm -qa --qf "%{NAME}-%{VERSION}-%{RELEASE} %{VENDOR}\n" | grep CentOS |  awk '{print $1}')
            ;;
        aarch64)
            mapfile -t list_of_centos_rpms < <(rpm -qa --qf "%{NAME}-%{VERSION}-%{RELEASE} %{VENDOR}\n" | grep CentOS | grep -v kernel | awk '{print $1}')
            ;;
    esac

    if [[ -n "${list_of_centos_rpms[*]}" ]] && [[ "${#list_of_centos_rpms[@]}" -ne 0 ]]; then
        echo "Reinstalling RPMs: ${list_of_centos_rpms[*]}"
        yum --assumeyes --disablerepo "*" --enablerepo "ol*" reinstall "${list_of_centos_rpms[@]}"
    fi
    # See if non-Oracle RPMs are present and print them
    mapfile -t non_oracle_rpms < <(rpm -qa --qf "%{NAME}-%{VERSION}-%{RELEASE}|%{VENDOR}|%{PACKAGER}\n" |grep -v Oracle)
    if [[ -n "${non_oracle_rpms[*]}" ]]; then
        echo "The following non-Oracle RPMs are installed on the system:"
        printf '\t%s\n' "${non_oracle_rpms[@]}"
        echo "This may be expected of your environment and does not necessarily indicate a problem."
        echo "If a large number of CentOS RPMs are included and you're unsure why please open an issue on ${github_url}"
    fi
fi


echo "Sync successful."

if [ "$arch" == "aarch64" ]; then
    echo "Host is running an Arm CPU: removing RHCK."
    echo "Important: you MUST reboot this instance as soon as possible."
    dnf config-manager --setopt=protect_running_kernel=0 --save
    dnf -y remove kernel kernel-core kernel-modules
    dnf config-manager --setopt=protect_running_kernel=1 --save
fi

case "$os_version" in
    7* | 8* | 9* )
        echo "Updating the GRUB2 bootloader."
        if [ -d /sys/firmware/efi ]; then
            grub2-mkconfig -o /boot/efi/EFI/redhat/grub.cfg
        else
            grub2-mkconfig -o /boot/grub2/grub.cfg
        fi
    ;;
esac

if "${install_uek_kernel}"; then
    echo "Switching default boot kernel to the UEK."
    uek_path=$(find /boot -name "vmlinuz-*.el${os_version}uek.${arch}")
    grubby --set-default="${uek_path}"
fi

echo "Removing yum cache"
rm -rf /var/cache/{yum,dnf}

# Collect information about RPMs after the switch
if "${verify_all_rpms}"; then
    generate_rpms_info after
    echo "Review the output of following files:"
    find /var/tmp/ -type f -name "$(hostname)-rpms-*.log"
fi

echo "Switch complete."

case "$arch" in
    "x86_64")
        echo "Oracle recommends rebooting this system."
    ;;
    "aarch64")
        echo "This instance must be rebooted as soon as possible."
    ;;
esac
