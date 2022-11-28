#!/usr/bin/env bash

set -e

# Clean up old apt sources
rm -rf /var/lib/apt/lists/*

TAILSCALE_VERSION="${VERSION:-"latest"}"

architecture="$(uname -m)"
case ${architecture} in
    x86_64) architecture="amd64";;
    aarch64 | armv8*) architecture="arm64";;
    aarch32 | armv7* | armvhf*) architecture="arm";;
    i?86) architecture="386";;
    *) echo "(!) Architecture ${architecture} unsupported"; exit 1 ;;
esac

if [ "$(id -u)" -ne 0 ]; then
    echo -e 'Script must be run as root. Use sudo, su, or add "USER root" to your Dockerfile before running this script.'
    exit 1
fi

# Figure out correct version of a three part version number is not passed
find_version_from_git_tags() {
    local variable_name=$1
    local requested_version=${!variable_name}
    if [ "${requested_version}" = "none" ]; then return; fi
    local repository=$2
    local prefix=${3:-"tags/v"}
    local separator=${4:-"."}
    local last_part_optional=${5:-"false"}
    if [ "$(echo "${requested_version}" | grep -o "." | wc -l)" != "2" ]; then
        local escaped_separator=${separator//./\\.}
        local last_part
        if [ "${last_part_optional}" = "true" ]; then
            last_part="(${escaped_separator}[0-9]+)?"
        else
            last_part="${escaped_separator}[0-9]+"
        fi
        local regex="${prefix}\\K[0-9]+${escaped_separator}[0-9]+${last_part}$"
        local version_list="$(git ls-remote --tags ${repository} | grep -oP "${regex}" | tr -d ' ' | tr "${separator}" "." | sort -rV)"
        if [ "${requested_version}" = "latest" ] || [ "${requested_version}" = "current" ] || [ "${requested_version}" = "lts" ]; then
            declare -g ${variable_name}="$(echo "${version_list}" | head -n 1)"
        else
            set +e
            declare -g ${variable_name}="$(echo "${version_list}" | grep -E -m 1 "^${requested_version//./\\.}([\\.\\s]|$)")"
            set -e
        fi
    fi
    if [ -z "${!variable_name}" ] || ! echo "${version_list}" | grep "^${!variable_name//./\\.}$" > /dev/null 2>&1; then
        echo -e "Invalid ${variable_name} value: ${requested_version}\nValid values:\n${version_list}" >&2
        exit 1
    fi
    echo "${variable_name}=${!variable_name}"
}

apt_get_update()
{
    if [ "$(find /var/lib/apt/lists/* | wc -l)" = "0" ]; then
        echo "Running apt-get update..."
        apt-get update -y
    fi
}

# Checks if packages are installed and installs them if not
check_packages() {
    if ! dpkg -s "$@" > /dev/null 2>&1; then
        apt_get_update
        apt-get -y install --no-install-recommends "$@"
    fi
}

# Ensure apt is in non-interactive to avoid prompts
export DEBIAN_FRONTEND=noninteractive

# Install dependencies if missing
check_packages curl ca-certificates gnupg2 coreutils dnsutils
if ! type git > /dev/null 2>&1; then
    check_packages git
fi

# Verify requested version is available, if not, use latest
find_version_from_git_tags TAILSCALE_VERSION 'https://github.com/tailscale/tailscale' 'v'

# Create temporary directory for tailscale download
mkdir -p /tmp/tailscale-downloads
cd /tmp/tailscale-downloads

# Install tailscale
echo "Downloading tailscale..."

# Todo: Add support for customization by version and architecture
tailscale_filename="tailscale_${TAILSCALE_VERSION}_${architecture}.tgz"

# Download tailscale
curl -sSL -o ${tailscale_filename} https://pkgs.tailscale.com/stable/${tailscale_filename}

# Unpack tailscale
tar xzf ${TSFILE} --strip-components=1

# Move tailscale binaries to /usr/local/bin/
mv -f tailscaled /usr/local/bin/
mv -f tailscale /usr/local/bin/

# Create symlinks to tailscaled binary
ln -sf /usr/local/bin/tailscaled /usr/sbin/tailscaled
ln -sf /usr/local/bin/tailscale /usr/bin/tailscale

# Download tailscaled init.d script from tailscale/codespace Github to /etc/init.d/tailscaled
curl -sSL -o /etc/init.d/tailscaled https://raw.githubusercontent.com/tailscale/codespace/main/tailscaled

# Make sure tailscaled init.d script is executable
chmod +x /etc/init.d/tailscaled

# Create tailscale directories
mkdir -p /var/run/tailscale /var/cache/tailscale /var/lib/tailscale

# Clean up
rm -rf /tmp/tailscale-downloads
rm -rf /var/lib/apt/lists/*

echo "Done!"
