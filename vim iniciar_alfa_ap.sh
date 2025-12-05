#!/bin/bash

# --- VARIABLES DE CONFIGURACIÓN ---
AP_INTERFACE="wlan0"
INTERNET_INTERFACE="eth0" 
GATEWAY_IP="10.0.0.1"
SETUP_FLAG="/var/tmp/alfa_ap_setup_done"
DRIVER_REPO="https://github.com/morrownr/7612u.git"

# Verificar permisos de root
if [ "$EUID" -ne 0 ]; then
    echo "❌ Error: Por favor, ejecuta este script con sudo: sudo ./iniciar_alfa_ap.sh"
    exit 1
fi

# ----------------------------------------------------
# --- PARTE 1: INSTALACIÓN INICIAL Y DRIVER (Pre-Reboot) ---
# ----------------------------------------------------
if [ ! -f "$SETUP_FLAG" ]; then

    echo -e "\n=========================================================================="
    echo "--- PASO 1/2: INSTALACIÓN Y CONFIGURACIÓN INICIAL (Solo la primera vez) ---"
    echo "=========================================================================="
    
    # 1. Instalar paquetes necesarios
    echo -e "\nInstalando paquetes: hostapd, dnsmasq, git y build-essential..."
    apt update
    apt install -y hostapd dnsmasq git build-essential dkms

    # 2. Obtener datos del usuario
    read -p "Introduce el nombre de tu red Wi-Fi (SSID): " USER_SSID
    read -p "Introduce la contraseña WPA (mínimo 8 caracteres): " USER_PASSWD

    # 3. Descarga y compilación del driver MediaTek (para modo AP)
    echo -e "\nInstalando driver de kernel MediaTek (${DRIVER_REPO})... Esto puede tardar unos minutos."
    git clone ${DRIVER_REPO} /tmp/mtk_driver 
    cd /tmp/mtk_driver
    ./install.sh

    # 4. Creación de archivos de configuración
    echo -e "\nCreando archivos de configuración de hostapd y dnsmasq..."
    
    # hostapd.conf (Usando nl80211, ahora soportado por el nuevo driver)
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
    
    # Crea el flag para saber que la instalación se hizo
    touch $SETUP_FLAG

    echo -e "\n=========================================================================="
    echo "✅ CONFIGURACIÓN E INSTALACIÓN DE DRIVER COMPLETADA."
    echo "   >> Es OBLIGATORIO REINICIAR el sistema para cargar el nuevo driver."
    echo "   >> Por favor, ejecuta: sudo reboot"
    echo "   >> Después de reiniciar, ejecuta este script UNA VEZ MÁS para iniciar el AP."
    echo "=========================================================================="
    exit 0
fi

# --------------------------------------------------------
# --- PARTE 2: INICIO DEL PUNTO DE ACCESO (Post-Reboot) ---
# --------------------------------------------------------
echo -e "\n=========================================================================="
echo "--- PASO 2/2: CONFIGURACIÓN DE RED E INICIO DEL PUNTO DE ACCESO ---"
echo "=========================================================================="

# 1. Detener servicios en conflicto
echo "Deteniendo servicios en conflicto..."
systemctl stop NetworkManager 2>/dev/null
systemctl stop wpa_supplicant 2>/dev/null
killall dhclient 2>/dev/null

# 2. Asignar la IP estática (Gateway)
echo "Asignando IP estática ${GATEWAY_IP} a ${AP_INTERFACE}..."
ip addr flush dev ${AP_INTERFACE} 
ip addr add ${GATEWAY_IP}/24 dev ${AP_INTERFACE}
ip link set dev ${AP_INTERFACE} up

# 3. Aplicar reglas de NAT (Enrutamiento)
echo "Configurando NAT (Enrutamiento de Internet)..."
echo 1 > /proc/sys/net/ipv4/ip_forward
iptables -t nat -A POSTROUTING -o ${INTERNET_INTERFACE} -j MASQUERADE
iptables -A FORWARD -i ${INTERNET_INTERFACE} -o ${AP_INTERFACE} -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i ${AP_INTERFACE} -o ${INTERNET_INTERFACE} -j ACCEPT
echo "NAT configurado. El tráfico de ${AP_INTERFACE} se enrutará a ${INTERNET_INTERFACE}."

# 4. Reiniciar Dnsmasq
echo "Reiniciando dnsmasq (servidor DHCP)..."
systemctl restart dnsmasq

# 5. Iniciar Hostapd
echo -e "\n=========================================================================="
echo "🚀 ¡INICIANDO HOSTAPD! El AP '${USER_SSID}' debería estar ahora activo."
echo "   Presiona Ctrl+C en esta ventana para detener el AP y devolver la terminal."
echo "=========================================================================="

# Ejecutar hostapd
hostapd /etc/hostapd/hostapd.conf

echo -e "\n--- AP DETENIDO ---"

# 6. (Opcional) Limpiar las reglas de iptables y reestablecer la red
echo "Restableciendo servicios de red (NetworkManager)..."
systemctl start NetworkManager 2>/dev/null
iptables -F
iptables -t nat -F

exit 0
