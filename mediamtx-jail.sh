#!/bin/sh
# Build an iocage jail under TrueNAS 13.0 and install MediaMTX
# git clone https://github.com/tschettervictor/truenas-iocage-mediamtx

# Check for root privileges
if ! [ $(id -u) = 0 ]; then
   echo "This script must be run with root privileges"
   exit 1
fi

#####
#
# General configuration
#
#####

# Initialize defaults
JAIL_IP=""
JAIL_INTERFACES=""
DEFAULT_GW_IP=""
INTERFACE="vnet0"
VNET="on"
POOL_PATH=""
JAIL_NAME="mediamtx"
CONFIG_NAME="mediamtx-config"

# Check for icecast-config and set configuration
SCRIPT=$(readlink -f "$0")
SCRIPTPATH=$(dirname "${SCRIPT}")
if ! [ -e "${SCRIPTPATH}"/"${CONFIG_NAME}" ]; then
  echo "${SCRIPTPATH}/${CONFIG_NAME} must exist."
  exit 1
fi
. "${SCRIPTPATH}"/"${CONFIG_NAME}"
INCLUDES_PATH="${SCRIPTPATH}"/includes

JAILS_MOUNT=$(zfs get -H -o value mountpoint $(iocage get -p)/iocage)
RELEASE=$(freebsd-version | cut -d - -f -1)"-RELEASE"
# If release is 13.1-RELEASE, change to 13.2-RELEASE
if [ "${RELEASE}" = "13.1-RELEASE" ]; then
  RELEASE="13.2-RELEASE"
fi 

#####
#
# Input/Config Sanity checks
#
#####

# Check that necessary variables were set by uptimekuma-config
if [ -z "${JAIL_IP}" ]; then
  echo 'Configuration error: JAIL_IP must be set'
  exit 1
fi
if [ -z "${JAIL_INTERFACES}" ]; then
  echo 'JAIL_INTERFACES not set, defaulting to: vnet0:bridge0'
JAIL_INTERFACES="vnet0:bridge0"
fi
if [ -z "${DEFAULT_GW_IP}" ]; then
  echo 'Configuration error: DEFAULT_GW_IP must be set'
  exit 1
fi
if [ -z "${POOL_PATH}" ]; then
  echo 'Configuration error: POOL_PATH must be set'
  exit 1
fi

# Extract IP and netmask, sanity check netmask
IP=$(echo ${JAIL_IP} | cut -f1 -d/)
NETMASK=$(echo ${JAIL_IP} | cut -f2 -d/)
if [ "${NETMASK}" = "${IP}" ]
then
  NETMASK="24"
fi
if [ "${NETMASK}" -lt 8 ] || [ "${NETMASK}" -gt 30 ]
then
  NETMASK="24"
fi

#####
#
# Jail Creation
#
#####

# List packages to be auto-installed after jail creation
cat <<__EOF__ >/tmp/pkg.json
{
  "pkgs": [
  "git-lite",
  "go122"
  ]
}
__EOF__

# Create the jail and install previously listed packages
if ! iocage create --name "${JAIL_NAME}" -p /tmp/pkg.json -r "${RELEASE}" interfaces="${JAIL_INTERFACES}" ip4_addr="${INTERFACE}|${IP}/${NETMASK}" defaultrouter="${DEFAULT_GW_IP}" boot="on" host_hostname="${JAIL_NAME}" vnet="${VNET}"
then
	echo "Failed to create jail"
	exit 1
fi
rm /tmp/pkg.json

#####
#
# Directory Creation and Mounting
#
#####

# Create and mount directories
iocage exec "${JAIL_NAME}" mkdir -p /mnt/includes/
mkdir -p "${POOL_PATH}"/mediamtx
iocage exec "${JAIL_NAME}" mkdir -p /usr/local/www/mediamtx
iocage exec "${JAIL_NAME}" mkdir -p /usr/local/etc/rc.d/
iocage fstab -a "${JAIL_NAME}" "${INCLUDES_PATH}" /mnt/includes nullfs rw 0 0
iocage fstab -a "${JAIL_NAME}" "${POOL_PATH}"/mediamtx /usr/local/www/mediamtx nullfs rw 0 0

#####
#
# MediaMTX Installation 
#
#####

iocage exec "${JAIL_NAME}" git clone https://github.com/bluenviron/mediamtx
if ! iocage exec "${JAIL_NAME}" "cd /mediamtx && go122 generate ./..."
then
    echo "Failed to generate"
    exit 1
fi
if ! iocage exec "${JAIL_NAME}" "cd /mediamtx && go122 build ."
then
    echo "Failed to build"
    exit 1
fi
iocage exec "${JAIL_NAME}" cp /mediamtx/mediamtx /usr/local/bin/mediamtx
iocage exec "${JAIL_NAME}" chmod +x /usr/local/bin/mediamtx
if ! [ "$(ls -A "${POOL_PATH}/mediamtx")" ]; then
    iocage exec "${JAIL_NAME}" cp /mediamtx/mediamtx.yml /usr/local/www/mediamtx/
fi
iocage exec "${JAIL_NAME}" cp /mnt/includes/mediamtx /usr/local/etc/rc.d/
iocage exec "${JAIL_NAME}" chown -R www:www /usr/local/www/mediamtx
iocage exec "${JAIL_NAME}" sysrc mediamtx_enable="YES"
iocage exec "${JAIL_NAME}" sysrc mediamtx_config="/usr/local/www/mediamtx/mediamtx.yml"

# Don't need /mnt/includes any more, so unmount it
iocage fstab -r "${JAIL_NAME}" "${INCLUDES_PATH}" /mnt/includes nullfs rw 0 0

# Restart
iocage restart "${JAIL_NAME}"

echo "---------------"
echo "Installation Complete!"
echo "---------------"
echo "MediaMTX is now installed and running. See the config file to configure preferred streaming protocols."
echo "---------------"
