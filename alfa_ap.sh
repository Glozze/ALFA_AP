#!/bin/bash

# --- CONFIGURATION VARIABLES ---
AP_INTERFACE="wlan0"
INTERNET_INTERFACE="eth0" 
GATEWAY_IP="10.0.0.1"
SETUP_FLAG="/var/tmp/alfa_ap_setup_done"
DRIVER_REPO="https://github.com/morrownr/7612u.git"

# Check for root permissions
if [ "$EUID" -ne 0 ]; then
    echo " !! Error: Please run this script with sudo: sudo ./start_alfa_ap.sh"
    exit 1
fi

# ----------------------------------------------------
# --- PART 1: INITIAL INSTALLATION & DRIVER (Pre-Reboot) ---
# ----------------------------------------------------
if [ ! -f "$SETUP_FLAG" ]; then

    echo -e "\n=========================================================================="
    echo "--- STEP 1/2: INITIAL INSTALLATION AND CONFIGURATION (First time only) ---"
    echo "=========================================================================="
    
    # 1. Install necessary packages
    echo -e "\nInstalling packages: hostapd, dnsmasq, git, and build-essential..."
    apt update
    apt install -y hostapd dnsmasq git build-essential dkms

    # 2. Get user data
    read -p "Enter your Wi-Fi network name (SSID): " USER_SSID
    read -p "Enter the WPA password (minimum 8 characters): " USER_PASSWD

    # 3. Download and compile the MediaTek driver (for AP mode)
    echo -e "\nInstalling MediaTek kernel driver (${DRIVER_REPO})... This may take a few minutes."
    git clone ${DRIVER_REPO} /tmp/mtk_driver 
    cd /tmp/mtk_driver
    ./install.sh

    # 4. Create configuration files
    echo -e "\nCreating hostapd and dnsmasq configuration files..."
    
    # hostapd.conf (Using nl80211, now supported by the new driver)
    cat > /etc/hostapd/hostapd.conf << EOL
interface=${AP_INTERFACE}
driver=nl80211
ssid=${USER_SSID}
channel=6
hw_mode=g
wpa=2
wpa_passphrase=${USER_PASSWD}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOL

    # dnsmasq.conf
    cat > /etc/dnsmasq.conf << EOL
interface=${AP_INTERFACE}
dhcp-range=10.0.0.10,10.0.0.100,12h 
dhcp-option=3,${GATEWAY_IP} 
dhcp-option=6,8.8.8.8,8.8.4.4
bind-interfaces
EOL
    
    # Create the flag to know that the installation was done
    touch $SETUP_FLAG

    echo -e "\n=========================================================================="
    echo "  CONFIGURATION AND DRIVER INSTALLATION COMPLETE."
    echo "    >> It is MANDATORY to REBOOT the system to load the new driver."
    echo "    >> Please run: sudo reboot"
    echo "    >> After rebooting, run this script ONE MORE TIME to start the AP."
    echo "=========================================================================="
    exit 0
fi

# --------------------------------------------------------
# --- PART 2: STARTING THE ACCESS POINT (Post-Reboot) ---
# --------------------------------------------------------
echo -e "\n=========================================================================="
echo "--- STEP 2/2: NETWORK CONFIGURATION AND ACCESS POINT START ---"
echo "=========================================================================="

# 1. Stop conflicting services
echo "Stopping conflicting services..."
systemctl stop NetworkManager 2>/dev/null
systemctl stop wpa_supplicant 2>/dev/null
killall dhclient 2>/dev/null

# 2. Assign the static IP (Gateway)
echo "Assigning static IP ${GATEWAY_IP} to ${AP_INTERFACE}..."
ip addr flush dev ${AP_INTERFACE} 
ip addr add ${GATEWAY_IP}/24 dev ${AP_INTERFACE}
ip link set dev ${AP_INTERFACE} up

# 3. Apply NAT rules (Routing) 

[Image of Network Address Translation (NAT) diagram]

echo "Configuring NAT (Internet Routing)..."
echo 1 > /proc/sys/net/ipv4/ip_forward
iptables -t nat -A POSTROUTING -o ${INTERNET_INTERFACE} -j MASQUERADE
iptables -A FORWARD -i ${INTERNET_INTERFACE} -o ${AP_INTERFACE} -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i ${AP_INTERFACE} -o ${INTERNET_INTERFACE} -j ACCEPT
echo "NAT configured. Traffic from ${AP_INTERFACE} will be routed to ${INTERNET_INTERFACE}."

# 4. Restart Dnsmasq
echo "Restarting dnsmasq (DHCP server)..."
systemctl restart dnsmasq

# 5. Start Hostapd
echo -e "\n=========================================================================="
echo "  STARTING HOSTAPD! The AP '${USER_SSID}' should now be active."
echo "    Press Ctrl+C in this window to stop the AP and return the terminal."
echo "=========================================================================="

# Execute hostapd
hostapd /etc/hostapd/hostapd.conf

echo -e "\n--- AP STOPPED ---"

# 6. (Optional) Clear iptables rules and reset the network
echo "Resetting network services (NetworkManager)..."
systemctl start NetworkManager 2>/dev/null
iptables -F
iptables -t nat -F

exit 0
