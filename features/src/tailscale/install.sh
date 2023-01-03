#!/usr/bin/env bash

set -e

# Clean up old apt sources
rm -rf /var/lib/apt/lists/*

# Set codespace options
TAILSCALE_VERSION="${VERSION:-"latest"}"
TAILSCALE_HOSTNAME_PREFIX="${HOSTNAME_PREFIX:-"codespaces-"}"
TAILSCALE_TAGS="${TAGS:-""}"
TAILSCALE_OPTIONS="${TAILSCALE_OPTIONS:-""}"

# Other options
FIX_ENVIRONMENT="${FIX_ENVIRONMENT:-"true"}"

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
tar xzf ${tailscale_filename} --strip-components=1

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

# Set TAILSCALE_HOSTNAME to prefix + hostname of container
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME_PREFIX}$(cat /etc/hostname)"

# Create list of tailscale tags in format of "tag:value1,tag:value2"
# Note: TAILSCALE_TAGS variable is a comma separated list of values and needs to have tag: prefix added
TAILSCALE_TAGS=""
if [ ! -z "${TAILSCALE_TAGS}" ]; then
    for tag in $(echo "${TAILSCALE_TAGS}" | tr "," "\n"); do
        TAILSCALE_TAGS="${TAILSCALE_TAGS}tag:${tag},"
    done
    TAILSCALE_TAGS="${TAILSCALE_TAGS::-1}"
fi

# If there are tags, add --advertise-tags before the tags
if [ ! -z "${TAILSCALE_TAGS}" ]; then
    TAILSCALE_TAGS="--advertise-tags ${TAILSCALE_TAGS}"
fi

# Patch tailscaled init.d script to use TAILSCALE_HOSTNAME instead
sed -i "s/tailscale up/tailscale up --hostname ${TAILSCALE_HOSTNAME} ${TAILSCALE_TAGS} ${TAILSCALE_OPTIONS}/g" /etc/init.d/tailscaled

# Create tailscale directories
mkdir -p /var/run/tailscale /var/cache/tailscale /var/lib/tailscale

# Script to store variables that exist at the time the ENTRYPOINT is fired
store_env_script="$(cat << 'EOF'
# Wire in codespaces secret processing to zsh if present (since may have been added to image after script was run)
if [ -f  /etc/zsh/zlogin ] && ! grep '/etc/profile.d/00-restore-secrets.sh' /etc/zsh/zlogin > /dev/null 2>&1; then
    if [ -f /etc/profile.d/00-restore-secrets.sh ]; then
        . /etc/profile.d/00-restore-secrets.sh
    fi
    $(cat /etc/zsh/zlogin 2>/dev/null || echo '') | sudoIf tee /etc/zsh/zlogin > /dev/null
fi
EOF
)"

# Script to ensure login shells get the latest Codespaces secrets
restore_secrets_script="$(cat << 'EOF'
#!/bin/sh
if [ "${CODESPACES}" != "true" ] || [ "${VSCDC_FIXED_SECRETS}" = "true" ] || [ ! -z "${GITHUB_CODESPACES_TOKEN}" ]; then
    # Not codespaces, already run, or secrets already in environment, so return
    return
fi
if [ -f /workspaces/.codespaces/shared/.env-secrets ]; then
    while read line
    do
        key=$(echo $line | sed "s/=.*//")
        value=$(echo $line | sed "s/$key=//1")
        decodedValue=$(echo $value | base64 -d)
        export $key="$decodedValue"
    done < /workspaces/.codespaces/shared/.env-secrets
fi
export VSCDC_FIXED_SECRETS=true
EOF
)"

# Write out a script that can be referenced as an ENTRYPOINT to auto-start tailscaled
tee /usr/local/share/tailscaled-init.sh > /dev/null \
<< 'EOF'
#!/usr/bin/env zsh
# This script is intended to be run as root with a container that runs as root (even if you connect with a different user)
# However, it supports running as a user other than root if passwordless sudo is configured for that same user.
set -e
sudoIf()
{
    if [ "$(id -u)" -ne 0 ]; then
        sudo "$@"
    else
        "$@"
    fi
}
EOF

if [ "${FIX_ENVIRONMENT}" = "true" ]; then
    echo "${store_env_script}" >> /usr/local/share/tailscaled-init.sh
    echo "${restore_secrets_script}" > /etc/profile.d/00-restore-secrets.sh
    chmod +x /etc/profile.d/00-restore-secrets.sh
    tee -a /usr/local/share/tailscaled-init.sh > /dev/null \
<< 'EOF'
# Make sure this current script gets codespaces secret processing
if [ -f /etc/profile.d/00-restore-secrets.sh ]; then
    . /etc/profile.d/00-restore-secrets.sh
fi
EOF
fi

tee -a /usr/local/share/tailscaled-init.sh > /dev/null \
<< 'EOF'
# ** Start tailscaled **
sudoIf /etc/init.d/tailscaled start 2>&1 | sudoIf tee /tmp/tailscaled.log > /dev/null
set +e

# Execute whatever commands were passed in (if any). This allows us
# to set this script to ENTRYPOINT while still executing the default CMD.
exec "$@"
EOF
chmod +x /usr/local/share/tailscaled-init.sh

# If we should start tailscaled now, do so
if [ "${START_TAILSCALED}" = "true" ]; then
    /usr/local/share/tailscaled-init.sh
fi

# Clean up
rm -rf /tmp/tailscale-downloads
rm -rf /var/lib/apt/lists/*

echo "tailscale script has completed!"
