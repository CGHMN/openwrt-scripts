#!/bin/busybox sh
# Configures your OpenWRT router to join the CGHMN Network

set -o pipefail
set -e

# -- Static variables -- #

# Wireguard transport tunnel configuration
WG_PEER_ADDRESS="us.wg.cghmn.org"
WG_PEER_PUBKEY="k/QiJIbMakMKgTCHVt8/D+8k4DzRVM6U33F3gMZfRUg="
WG_PEER_PORT=42070
WG_MTU=1320
WG_TUNNEL_REMOTE_SUBNETS_IP4="100.64.0.0/10"

# Shows script usage
usage() {
	cat <<-EOF
		Configures your OpenWRT router to join the CGHMN Network.

		Usage: $(basename "$0") <action> [<action-params>]

		Where [action] is one of the following:
			install-pkgs  Step 1, installs required packages
			init          Step 2, initializes the CGHMN network configuration
			set-tunnel-ip Step 3, sets your tunnel IP address
			pubkey-qr     Prints your Wireguard public key as QR code
			help          Show this help

		And <action-params> can be any of the following:
			-f	Forces a step, even if it already has been configured
			-v  Verbose output, logs more details
	EOF
}

# Tests if a UCI configuration exists
uci_config_exists() {
	if [ -z "${1}" ]; then
		return 1
	fi
	uci -q get "${1}" >/dev/null 2>&1
}

# Finds a UCI config which has the 'name' attribute but uses IDs or
# auto generated names in the actual UCI config
# find_named_uci_config <uci.path> <name>
# ex. find_named_uci_config firewall.@zone wan
find_named_uci_config() {
	if [ $# -ne 2 ]; then
		return 1
	fi

	INDEX=0
	
	while NAME="$(uci -q get "${1}[${INDEX}].name")"; do
		if [ "${NAME}" = "${2}" ]; then
			echo "${INDEX}"
			return 0
		fi
		INDEX=$(( INDEX+1 ))
	done

	return 1
}

# Ensure a step in the network setup has already been configured prior
ensure_step_configured() {
	if [ ${FORCE_ACTIONS:-0} -eq 1 ] || [ -z "${1}" ]; then
		return 0
	fi

	if ! uci_config_exists "system.@system[0].cghmn_step_${1}"; then
		echo "The previous step '${1}' has not been configured yet." >&2
		echo "Please ensure that step ran successfully before this one." >&2
		echo "To force executing this step, add the -f parameter." >&2
		exit 1
	fi
}

# Ensure a step in the network setup is not run twice without -f
ensure_step_not_configured() {
	if [ ${FORCE_ACTIONS:-0} -eq 1 ] || [ -z "${1}" ]; then
		return 0
	fi

	if uci_config_exists "system.@system[0].cghmn_step_${1}"; then
		echo "This step is already configured." >&2
		echo "To force a re-run of this step, add the -f parameter." >&2
		exit 1
	fi
}

# Marks the specified step as configured
mark_step_configured() {
	if ! uci_config_exists "system.@system[0].cghmn_step_${1}"; then
		uci -q set "system.@system[0].cghmn_step_${1}"=1 >/dev/null
	fi
}

# Ensures the specified UCI configuration path is not already configured
ensure_uci_config_not_exists() {
	if [ ${FORCE_ACTIONS:-0} -eq 1 ] || [ -z "${1}" ]; then
		return 0
	fi

	if uci_config_exists "${1}"; then
		echo "The UCI configuration '${1}' is already set, refusing to override." >&2
		echo "To force a re-run of this step, add the -f parameter." >&2
		exit 1
	fi
}

# Echoes text if the -v parameter is set
echo_verbose() {
	if [ ${VERBOSE:-0} -eq 1 ]; then
		echo "$@"
	fi
}

# Echoes piped text if the -v parameter is set
echo_pipe_verbose() {
	if [ ${VERBOSE:-0} -eq 1 ]; then
		cat
	else
		cat >/dev/null
	fi
}

# Echoes an error to the user and exits
failed() {
	if [ $# -gt 0 ]; then
		echo "Oops! The script failed on: $*" >&2
	else
		echo "Something went wrong!" >&2
	fi

	exit 1
}

# First step of the setup. Install required packages.
step_install_pkgs () {
	echo "Installing required packages for the CGHMN Network"
	
	echo_verbose "Updating package database ..."
	apk update | echo_pipe_verbose || failed "updating package database"

	echo_verbose "Installing packages luci-proto-wireguard, luci-proto-gre, kmod-nft-bridge"
	apk add \
		luci-proto-wireguard \
		luci-proto-gre \
		kmod-nft-bridge \
			| echo_pipe_verbose || \
				failed "installing required packages"

	echo "OK"
}

# Install qrencode package
install_qrencode () {
	echo_verbose "Updating package database ..."
	apk update | echo_pipe_verbose || failed "updating package database"

	echo_verbose "Installing qrencode"
	apk add \
		qrencode \
			| echo_pipe_verbose || \
				failed "installing required packages"

	echo "OK"
}

# Installs NFT filters to block IP traffic on L2 tunnels
install_gretap_nft_filter() {
	echo_verbose "Installing GRETAP bridge filter"
	cat >/etc/cghmn-bridge-filter.nft <<-EONFT || failed "copy bridge-filter ruleset"
		#!/usr/sbin/nft -f

		table bridge filter {}
		flush table bridge filter

		table bridge filter {
		    chain forward {
		        type filter hook forward priority 0; policy accept;
		        jump drop_in
		        jump drop_out
		    }
		    chain output {
		        type filter hook output priority 0; policy accept;
		        jump drop_out
		    }
		    chain input {
		        type filter hook input priority 0; policy accept;
		        jump drop_in
		    }
		    chain drop_in {
		        iifname gre4t* meta ibrname br-retrolan meta protocol ip drop comment "Drop IP packets flowing out of bridge via GRE"
		        iifname vxlan* meta ibrname br-retrolan meta protocol ip drop comment "Drop IP packets flowing out of bridge via VXLAN"
		    }
		    chain drop_out {
		        oifname gre4t* meta obrname br-retrolan meta protocol ip drop comment "Drop IP packets flowing out of bridge via GRE"
		        oifname vxlan* meta obrname br-retrolan meta protocol ip drop comment "Drop IP packets flowing out of bridge via VXLAN"
		    }
		}
	EONFT

	cat >/etc/init.d/cghmn-bridge-filter <<-EOINITD || failed "copy bridge-filter service"
		#!/bin/sh /etc/rc.common
		# Init script for CGHMN nftables GRE and VXLAN IP filter

		USE_PROCD=1

		START=10
		STOP=15

		start_service () {
		    procd_open_instance cghmn-nftables-bridge-filter
		    procd_set_param command /usr/sbin/nft -f /etc/cghmn-bridge-filter.nft
		    procd_close_instance
		}
	EOINITD
	chmod +x /etc/init.d/cghmn-bridge-filter || failed "mark bridge-filter service executable"
	service cghmn-bridge-filter enable || failed "enable bridge-filter service at boot"
	service cghmn-bridge-filter start || failed "start bridge-filter service now"
}

# Second step of the setup. Creates a generic Wireguard configuration for the CGHMN,
# generates a new public/private key pair and echoes it to the user to send to the CGHMN
# admins to be added to the server configuration.
# Also creates basic network interfaces and firewall rules.
step_init() {
	ensure_step_not_configured "init"
	ensure_uci_config_not_exists "network.cghmn_wg"

	if ! wg -v >/dev/null 2>&1; then
		echo "Wireguard Tools not found." >&2
		echo "Please ensure the step 'install-pkgs' ran successfully first." >&2
		exit 1
	fi

	echo "Please enter the name of the network port you'd like to use as Retro LAN port."
	echo "This must be an unused port, not assigned to any existing network."
	echo "You may have to allow web UI access from WAN and delete the LAN interface"
	echo "if your device only has two network ports."
	echo ""
	echo "Example: eth1"
	echo ""
	echo -n "Network Port: "
	read -r RETRO_LAN_PORT

	if [ -z "${RETRO_LAN_PORT}" ]; then
		echo "Aborted."
		exit 0
	elif [ ! -e "/sys/class/net/${RETRO_LAN_PORT}" ]; then
		echo "The specified port does not currently exist." >&2
		echo "Please check the spelling and use 'ip link show' to see" >&2
		echo "if the interface does exist on the system." >&2
		exit 1
	fi

	echo "Initializing CGHMN network configuration ..."

	echo_verbose "Installing GRETAP scripts"
	
	install_gretap_nft_filter || failed "Install GRETAP NFT filter"

	cat >/etc/hotplug.d/iface/90-cghmn-wg <<-"EOHOTPLUGD" || failed "copy wg hotplug.d handler"
		#!/bin/sh

		[ "${INTERFACE}" = "cghmn_wg" ] || exit 0

		if [ "${ACTION}" = "ifup" ]; then
		    [ -e "/sys/class/net/gre4t-cghmn_gre" ] && exit 0
		    logger -t hotplug "${INTERFACE} went up, creating GRETAP interface"
		    ip link add "gre4t-cghmn_gre" type gretap remote 100.64.11.12 ignore-df nopmtudisc
		    ip link set "gre4t-cghmn_gre" up
		elif [ "${ACTION}" = "ifdown" ]; then
		    [ -e "/sys/class/net/gre4t-cghmn_gre" ] || exit 0
		    logger -t hotplug "${INTERFACE} went down, reomving GRETAP interface"
		    ip link delete "gre4t-cghmn_gre"
		fi
	EOHOTPLUGD
	chmod +x /etc/hotplug.d/iface/90-cghmn-wg || failed "mark wg hotplug.d handler executable"
	cat >/etc/hotplug.d/net/90-cghmn-gretap <<-"EOHOTPLUGD" || failed "copy gretap hotplug.d handler"
		#!/bin/sh

		if [ "${INTERFACE}" = "gre4t-cghmn_gre" ] && [ "${ACTION}" = "add" ]; then
		    logger -t hotplug "${INTERFACE} went up, adding to parent bridge"
		    /usr/sbin/nft -f /etc/cghmn-bridge-filter.nft
		    ip link set "${INTERFACE}" master "br-retrolan" mtu 1500
		    ip link set "br-retrolan" mtu 1500
		fi
	EOHOTPLUGD
	chmod +x /etc/hotplug.d/net/90-cghmn-gretap || failed "mark gretap hotplug.d handler executable"

	echo_verbose "Generating new Wireguard private key"
	WG_PRIVKEY="$(wg genkey)" || failed "generating Wireguard private key"

	echo_verbose "Adding basic Wireguard interface and CGHMN peer"
	uci -q batch >/dev/null <<-EOUCI || failed "adding basic Wireguard interface and peer"
		# Local Wireguard interface
		set network.cghmn_wg=interface
		set network.cghmn_wg.proto='wireguard'
		set network.cghmn_wg.private_key='${WG_PRIVKEY}'
		set network.cghmn_wg.mtu='${WG_MTU}'
		set network.cghmn_wg.auto='0'

		# Remote CGHMN Wireguard peer
		add network wireguard_cghmn_wg
		set network.@wireguard_cghmn_wg[-1].description='CGHMN Peer'
		set network.@wireguard_cghmn_wg[-1].persistent_keepalive='15'
		set network.@wireguard_cghmn_wg[-1].route_allowed_ips='1'
		set network.@wireguard_cghmn_wg[-1].public_key='${WG_PEER_PUBKEY}'
		set network.@wireguard_cghmn_wg[-1].endpoint_host='${WG_PEER_ADDRESS}'
		set network.@wireguard_cghmn_wg[-1].endpoint_port='${WG_PEER_PORT}'
	EOUCI

	echo_verbose "Adding allowed IPs to CGHMN Wireguard peer"
	for SUBNET in ${WG_TUNNEL_REMOTE_SUBNETS_IP4}; do
		uci -q add_list network.@wireguard_cghmn_wg[-1].allowed_ips="${SUBNET}" || \
			failed "adding allowed IP '${SUBNET}' to CGHMN Wireguard peer"
	done

	if ! find_named_uci_config firewall.@zone retro_lan >/dev/null; then
		echo_verbose "Creating CGHMN Retro LAN firewall zone"
		uci -q batch >/dev/null <<-EOUCI || failed "creating Retro LAN firewall zone"
			add firewall zone
			set firewall.@zone[-1].name='retro_lan'
			set firewall.@zone[-1].input='ACCEPT'
			set firewall.@zone[-1].output='ACCEPT'
			set firewall.@zone[-1].forward='REJECT'
			add_list firewall.@zone[-1].network='retro_lan'
		EOUCI
	fi

	if ! find_named_uci_config firewall.@zone cghmn_tunnel >/dev/null; then
		echo_verbose "Creating CGHMN Transport Tunnel firewall zone"
		uci -q batch >/dev/null <<-EOUCI || failed "creating Transport Tunnel firewall zone"
			add firewall zone
			set firewall.@zone[-1].name='cghmn_tunnel'
			set firewall.@zone[-1].input='REJECT'
			set firewall.@zone[-1].output='ACCEPT'
			set firewall.@zone[-1].forward='REJECT'
			set firewall.@zone[-1].masq='1'
			add_list firewall.@zone[-1].network='cghmn_wg'
			add_list firewall.@zone[-1].network='cghmn_vxlan'
			add_list firewall.@zone[-1].network='cghmn_gretap'
		EOUCI
	fi

	if ! find_named_uci_config firewall.@forwarding cghmn_lan_tun >/dev/null; then
		echo_verbose "Creating forwarding from Retro LAN to the Tunnel Network"
		uci -q batch >/dev/null <<-EOUCI || failed "creating forwarding from Retro LAN to the Tunnel Network"
			add firewall forwarding
			set firewall.@forwarding[-1].src='retro_lan'
			set firewall.@forwarding[-1].dest='cghmn_tunnel'
			set firewall.@forwarding[-1].name='cghmn_lan_tun'
		EOUCI
	fi

	if ! find_named_uci_config firewall.@forwarding cghmn_lan_wan >/dev/null; then
		echo_verbose "Creating forwarding from Retro LAN to the Tunnel Network"
		uci -q batch >/dev/null <<-EOUCI || failed "creating forwarding from Retro LAN to the Tunnel Network"
			add firewall forwarding
			set firewall.@forwarding[-1].src='retro_lan'
			set firewall.@forwarding[-1].dest='wan'
			set firewall.@forwarding[-1].name='cghmn_lan_wan'
		EOUCI
	fi

	if ! find_named_uci_config firewall.@rule "CGHMN: Allow GRE from transport network" >/dev/null; then
		echo_verbose "Allowing GRE traffic from transport network"
		uci -q batch >/dev/null <<-EOUCI || failed "allowing GRE traffic from transport network"
			add firewall rule
			set firewall.@rule[-1].name='CGHMN: Allow GRE from transport network'
			set firewall.@rule[-1].proto='gre'
			set firewall.@rule[-1].src='cghmn_tunnel'
			set firewall.@rule[-1].target='ACCEPT'
		EOUCI
	fi

	if ! find_named_uci_config firewall.@rule "CGHMN: Allow ICMP packets from tunnel interface" >/dev/null; then
		echo_verbose "Allowing ICMP packets from tunnel interface"
		uci -q batch >/dev/null <<-EOUCI || failed "allowing ICMP packets from tunnel interface"
			add firewall rule
			set firewall.@rule[-1].name='CGHMN: Allow ICMP packets from tunnel interface'
			set firewall.@rule[-1].proto='icmp'
			set firewall.@rule[-1].src='cghmn_tunnel'
			set firewall.@rule[-1].target='ACCEPT'
		EOUCI
	fi

	if ! find_named_uci_config network.@device "br-retrolan" >/dev/null; then
		echo_verbose "Creating Retro LAN bridge"
		uci -q batch >/dev/null <<-EOUCI || failed "creating Retro LAN bridge"
			add network device
			set network.@device[-1].type='bridge'
			set network.@device[-1].name='br-retrolan'
			set network.@device[-1].bridge_empty='1'
			add_list network.@device[-1].ports='${RETRO_LAN_PORT}'
			add_list network.@device[-1].ports='gre4t-cghmn_gre'
		EOUCI
	fi

	if ! uci_config_exists network.retro_lan >/dev/null; then
		echo_verbose "Creating Retro LAN interface with placeholder subnet"
		uci -q batch >/dev/null <<-EOUCI || failed "creating Retro LAN interface with placeholder subnet"
			set network.retro_lan=interface
			set network.retro_lan.proto='static'
			set network.retro_lan.device='br-retrolan'
			set network.retro_lan.ipaddr='192.168.134.1/24'
			set network.retro_lan.netmask='255.255.255.0'
		EOUCI
	fi

	if ! uci_config_exists network.cghmn_gretap >/dev/null; then
		echo_verbose "Creating unmanaged GRETAP interface"
		uci -q batch >/dev/null <<-EOUCI || failed "creating unmanaged GRETAP interface"
			set network.cghmn_gretap=interface
			set network.cghmn_gretap.proto='none'
			set network.cghmn_gretap.device='gre4t-cghmn_gre'
		EOUCI
	fi

	if ! uci_config_exists dhcp.retro_lan >/dev/null; then
		echo_verbose "Creating DHCP server for Retro LAN"
		uci -q batch >/dev/null <<-EOUCI || failed "creating DHCP server for Retro LAN"
			set dhcp.retro_lan=dhcp
			set dhcp.retro_lan.interface='retro_lan'
			set dhcp.retro_lan.start='100'
			set dhcp.retro_lan.limit='200'
			set dhcp.retro_lan.leasetime='12h'
		EOUCI
	fi

	echo_verbose "Configuring DNSmasq"
	uci -q batch >/dev/null <<-EOUCI || failed "configuring DNSmasq"
		set dhcp.@dnsmasq[-1].strictorder='1'
		set dhcp.@dnsmasq[-1].localservice='1'
		set dhcp.@dnsmasq[-1].boguspriv='0'
		set dhcp.@dnsmasq[-1].rebind_protection='0'
	EOUCI

	if ! uci -q get dhcp.@dnsmasq[-1].server | grep -q "100.64.12.2"; then
		echo_verbose "Adding CGHMN DNS server to DNS server list"
		uci -q add_list dhcp.@dnsmasq[-1].server='/cghmn/100.64.12.2' || \
			failed "adding CGHMN DNS server to DNS server list (.cghmn)"
		uci -q add_list dhcp.@dnsmasq[-1].server='/retro/100.64.12.2' || \
			failed "adding CGHMN DNS server to DNS server list (.retro)"
		uci -q add_list dhcp.@dnsmasq[-1].server='/chivanet/100.64.12.2' || \
			failed "adding CGHMN DNS server to DNS server list (.chivanet)"
		uci -q add_list dhcp.@dnsmasq[-1].server='/mac/100.64.12.2' || \
			failed "adding CGHMN DNS server to DNS server list (.mac)"
		uci -q add_list dhcp.@dnsmasq[-1].server='/goat/100.64.12.2' || \
			failed "adding CGHMN DNS server to DNS server list (.goat)"
	fi

	echo_verbose "Committing UCI configuration"
	uci -q commit || failed "committing UCI configuration"

	echo_verbose "Generating Wireguard public key"
	WG_PUBKEY="$(echo "${WG_PRIVKEY}" | wg pubkey)" || failed "generating Wireguard public key"

	echo ""
	echo "Below will be printed your Wireguard public key."
	echo "Please send this key to one of the CGHMN admins so we can add your"
	echo "Wireguard client to the CGHMN server configuration."
	echo ""
	echo "In return, you will receive one IPv4 address and one IPv4 subnet from us,"
	echo "these can be added to this configuration with the 'set-tunnel-ip' step."
	echo ""
	echo "###############################################################"
	echo "# WG Public Key: ${WG_PUBKEY} #"
	echo "###############################################################"
	echo ""
	echo "You should now at the very least get a lease on port '${RETRO_LAN_PORT}'"
	echo "and have internet access through your own internet connection on your retro machines."
	echo ""
	echo "Once you run the 'set-tunnel-ip' step, you should also be able to reach any other"
	echo "clients and servers on the CGHMN network."
	echo ""
	echo "Per default, you can access the web UI of this router on the network port mentioned above."
	echo "Change the 'INPUT' mode from 'accept' to 'reject' on the Retro LAN zone under"
	echo "the web UI menu Network -> Firewall if that is not desired."
	echo ""
	echo "PS: If copy-paste is not available, run '$(basename "$0") pubkey-qr' to show your public key"
	echo "    in QR code format to scan with a phone or tablet. This installs qrencode, make sure there"
	echo "    is enough flash space available (~80k)"

	echo "OK"
	mark_step_configured "init"
}

step_set_tunnel_ip() {
	ensure_step_not_configured "add_tunnel_ip"
	ensure_step_configured "init"

	echo "We're about to bring up the Wireguard tunnel and connect you to the CGHMN network."
	echo "This assumed you've already received your tunnel IP and your routed subnet from us"
	echo "in response to you sending us your Wireguard public key."
	echo ""
	echo "Please enter your tunnel IP, routed subnet IP and optionally a Preshared Key below:"
	echo ""
	echo -n "Tunnel IP: "
	read -r TUNNEL_IP
	echo -n "Routed subnet: "
	read -r ROUTED_SUBNET
	echo -n "Preshared Key (Leave blank for none): "
	read -r PSK

	if [ -z "${TUNNEL_IP}" ]; then
		echo "The tunnel IP cannot be empty."
		exit 1
	elif [ -z "${ROUTED_SUBNET}" ]; then
		echo "The routed subnet cannot be empty."
		exit 1
	fi

	TUNNEL_IP="${TUNNEL_IP/\/32/}"
	RETRO_LAN_IP="${ROUTED_SUBNET/.0\/24/.1}"

	echo "Configuring network to join the CGHMN ..."

	if uci_config_exists "network.cghmn_wg.addresses"; then
		echo_verbose "Removing existing CGHMN Wireguard Tunnel interface IPs"
		while uci -q delete network.cghmn_wg.@addresses[0]; do :; done
	fi

	echo_verbose "Adding CGHMN Wireguard tunnel interface IP address"
	uci -q add_list network.cghmn_wg.addresses="${TUNNEL_IP}/32" || \
		failed "adding CGHMN Wireguard tunnel interface IP address"

	if [ -n "${PSK}" ]; then
		echo_verbose "Adding CGHMN Wireguard tunnel interface Preshared Key"
		uci -q set network.@wireguard_cghmn_wg[-1].preshared_key="${PSK}" || \
			failed "adding CGHMN Wireguard tunnel Preshared Key"
	fi

	if uci_config_exists network.cghmn_wg.auto; then
		echo_verbose "Enabling interface autostart for CGHMN Wireguard tunnel"
		uci -q delete network.cghmn_wg.auto || failed "enabling interface autostart for CGHMN Wireguard tunnel"
	fi

	echo_verbose "Setting Retro LAN bridge IP address"
	uci -q set network.retro_lan.ipaddr="${RETRO_LAN_IP}" || failed "setting Retro LAN bridge IP address"
	uci -q set network.retro_lan.netmask='255.255.255.0' || failed "setting Retro LAN bridge IP netmask"

	echo_verbose "Committing UCI configuration"
	uci -q commit || failed "committing UCI configuration"

	echo ""
	echo "All done, once the Wireguard and Retro LAN interfaces are restarted"
	echo "(or you have rebooted the entire router once), you should be on the"
	echo "CGHMN network! Welcome!"
	echo ""

	echo "OK"
	mark_step_configured "add_tunnel_ip"
}

ACTION="${1:-NONE}"
FORCE_ACTIONS=0
VERBOSE=0

if [ "${ACTION}" = "NONE" ]; then
	echo "You must specify an action." >&2
	usage >&2
	exit 1
elif [ "${ACTION}" = "help" ]; then
	usage
	exit 0
fi

shift

while [ $# -gt 0 ]; do
	case "${1}" in
		-f)
			FORCE_ACTIONS=1
			;;
		-v)
			VERBOSE=1
			;;
		*)
			echo "Ignoring unknown parameter ${1}" >&2
			;;
	esac
	shift
done

case "${ACTION}" in
	install-pkgs)
		step_install_pkgs
		;;
	init)
		step_init
		;;
	set-tunnel-ip)
		step_set_tunnel_ip
		;;
	install-bridge-filter)
		install_gretap_nft_filter || failed "install GRETAP bridge filter"
		;;
	pubkey-qr)
		install_qrencode || failed "install qrencode"
		uci get network.cghmn_wg.private_key | wg pubkey | qrencode -t ansiutf8
		;;
	*)
		echo "Unknown action '${ACTION}'" >&2
		exit 1
		;;
esac
