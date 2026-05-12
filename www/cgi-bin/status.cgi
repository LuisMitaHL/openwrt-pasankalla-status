#!/bin/sh

# OpenWrt Router Status CGI - outputs JSON
# Deploy to /www/cgi-bin/status.cgi

QUERY_STRING="${QUERY_STRING:-}"

# Parse mode from query string
mode="basic"
echo "$QUERY_STRING" | grep -qi "mode=advanced" && mode="advanced"

# Set JSON content type
echo "Content-Type: application/json"
echo ""

# --- Helper: json escape ---
json_escape() {
    echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r//g' | awk '{printf "%s\\n", $0}' | sed '$ s/\\n$//'
}

# --- Router Model ---
model=""
if [ -f /tmp/sysinfo/model ]; then
    model=$(head -n1 /tmp/sysinfo/model 2>/dev/null)
fi
[ -z "$model" ] && model=$(ubus call system board 2>/dev/null | grep '"model"' | cut -d'"' -f4)
[ -z "$model" ] && model="Unknown"
model_escaped=$(json_escape "$model")

# --- Uptime ---
uptime_seconds=$(cat /proc/uptime 2>/dev/null | awk '{print int($1)}')
[ -z "$uptime_seconds" ] && uptime_seconds=0

uptime_str=""
d=$((uptime_seconds / 86400))
h=$(( (uptime_seconds % 86400) / 3600 ))
m=$(( (uptime_seconds % 3600) / 60 ))
s=$(( uptime_seconds % 60 ))
[ "$d" -gt 0 ] && uptime_str="${d}d "
[ "$h" -gt 0 ] && uptime_str="${uptime_str}${h}h "
[ "$m" -gt 0 ] && uptime_str="${uptime_str}${m}m "
uptime_str="${uptime_str}${s}s"

# --- Discover wireless interfaces ---
# Use iwinfo to list interfaces
wireless_ifaces=""
if command -v iwinfo >/dev/null 2>&1; then
    wireless_ifaces=$(iwinfo 2>/dev/null | grep -oE '^[^ ]+')
fi
# fallback with iw dev
if [ -z "$wireless_ifaces" ] && command -v iw >/dev/null 2>&1; then
    wireless_ifaces=$(iw dev 2>/dev/null | grep "Interface" | awk '{print $2}')
fi

# --- Per-interface data ---
interfaces_json=""
total_tx_bytes=0
total_rx_bytes=0

# Track which phy we've seen and their band for max clients
iface_list=""
for iface in $wireless_ifaces; do
    iface_list="$iface_list $iface"
done

# If no wireless ifaces found, try /sys/class/net
if [ -z "$iface_list" ]; then
    for iface in /sys/class/net/*; do
        [ -d "$iface/wireless" ] && iface_list="$iface_list $(basename "$iface")"
    done
fi

# Read /proc/net/dev for bytes
proc_net=$(cat /proc/net/dev 2>/dev/null)

for iface in $iface_list; do
    # iwinfo info
    ssid=""
    channel=""
    freq=""
    mode="ap"
    signal=""
    noise=""
    bitrate=""
    encryption=""
    clients=0
    phy_name=""
    wifi_type=""
    bw=""

    if command -v iwinfo >/dev/null 2>&1; then
        info=$(iwinfo "$iface" info 2>/dev/null)
        ssid=$(echo "$info" | grep "ESSID:" | sed 's/.*ESSID: *"\(.*\)"/\1/')
        [ "$ssid" = "unknown" ] && ssid=""
        channel=$(echo "$info" | grep "Channel:" | awk '{print $2}')
        freq=$(echo "$info" | grep "Channel:" | awk '{print $5}' | tr -d '().')
        mode=$(echo "$info" | grep "Mode:" | awk '{print $2}')
        # Normalize mode to ap|sta
        case "$mode" in
            Master) mode="ap" ;;
            Client|Managed) mode="sta" ;;
            Ad-Hoc) mode="adhoc" ;;
            Monitor) mode="monitor" ;;
            Mesh*) mode="mesh" ;;
            *) mode=$(echo "$mode" | tr '[:upper:]' '[:lower:]') ;;
        esac
        # Get bitrate
        bitrate=$(echo "$info" | grep "Bit Rate:" | awk '{print $3, $4}')
        # Get encryption
        encryption=$(echo "$info" | grep "Encryption:" | awk '{print $2}')

        # Get station count
        assoclist=$(iwinfo "$iface" assoclist 2>/dev/null)
        clients=$(echo "$assoclist" | grep -c "SNR" 2>/dev/null)
        [ -z "$clients" ] && clients=0

        # Get signal/noise from first station
        signal=$(echo "$info" | grep "Signal:" | awk '{print $2}')
        noise=$(echo "$info" | grep "Signal:" | awk '{print $5}')
    fi

    # Try hostapd_cli for more details if iwinfo didn't give SSID
    if [ -z "$ssid" ]; then
        ssid=$(hostapd_cli -i "$iface" get_config 2>/dev/null | grep "^ssid=" | cut -d'=' -f2-)
    fi

    # Try iw for phy name
    if command -v iw >/dev/null 2>&1; then
        phy_name=$(iw dev "$iface" info 2>/dev/null | grep "wiphy" | awk '{print $2}')
    fi
    [ -z "$phy_name" ] && phy_name="phy0"

    # Determine frequency if missing
    if [ -z "$freq" ] || [ "$freq" = "0" ]; then
        if command -v iw >/dev/null 2>&1; then
            freq=$(iw dev "$iface" info 2>/dev/null | grep "channel" | awk '{print $2}' | head -n1)
        fi
    fi

    # Determine band from frequency
    band="Unknown"
    if [ -n "$freq" ] && [ "$freq" != "0" ]; then
        if [ "$freq" -lt 3000 ]; then
            band="2.4GHz"
        elif [ "$freq" -lt 6000 ]; then
            band="5GHz"
        else
            band="6GHz"
        fi
    fi

    # Determine WiFi type and bandwidth from hostapd_cli
    wifi_type=""
    bw=""
    if [ -S "/var/run/hostapd/$iface" ]; then
        if_status=$(hostapd_cli -i "$iface" status 2>/dev/null)
        if echo "$if_status" | grep -q "ieee80211be=1"; then wifi_type="Wi-Fi 7"
        elif echo "$if_status" | grep -q "ieee80211ax=1"; then wifi_type="Wi-Fi 6"
        elif echo "$if_status" | grep -q "ieee80211ac=1"; then wifi_type="Wi-Fi 5"
        elif echo "$if_status" | grep -q "ieee80211n=1"; then wifi_type="Wi-Fi 4"
        else
            # Try iwinfo
            hwmode=$(echo "$info" | grep "HW Mode(s)" | awk '{print $NF}')
            case "$hwmode" in
                *ax*) wifi_type="Wi-Fi 6" ;;
                *ac*) wifi_type="Wi-Fi 5" ;;
                *n*) wifi_type="Wi-Fi 4" ;;
                *) wifi_type="Legacy" ;;
            esac
        fi

        # Get AP bandwidth
        bw_vht=$(echo "$if_status" | sed -n 's/^vht_oper_chwidth=//p')
        bw_he=$(echo "$if_status" | sed -n 's/^he_oper_chwidth=//p')
        bw_eht=$(echo "$if_status" | sed -n 's/^eht_oper_chwidth=//p')
        bw_val="${bw_eht:-${bw_he:-$bw_vht}}"
        case "$bw_val" in
            1) bw="80 MHz" ;;
            2) bw="160 MHz" ;;
            3) bw="80+80 MHz" ;;
            4) bw="320 MHz" ;;
            *)
                if echo "$if_status" | grep -qE "secondary_channel=[1-9]|-1"; then
                    bw="40 MHz"
                else
                    bw="20 MHz"
                fi
            ;;
        esac
    fi
    [ -z "$wifi_type" ] && wifi_type="Unknown"
    [ -z "$bw" ] && bw="20 MHz"

    # Determine max clients based on band and wifi type
    max_clients=32
    if [ "$band" = "2.4GHz" ]; then
        max_clients=64
    elif [ "$band" = "5GHz" ]; then
        if echo "$wifi_type" | grep -q "6"; then
            max_clients=200
        else
            max_clients=100
        fi
    else
        max_clients=200
    fi
    at_capacity="false"
    [ "$clients" -ge "$max_clients" ] && at_capacity="true"

    # Get RX/TX bytes from /proc/net/dev
    rx_bytes=0
    tx_bytes=0
    if [ -n "$proc_net" ]; then
        line=$(echo "$proc_net" | grep "$iface:" 2>/dev/null | head -n 1)
        if [ -n "$line" ]; then
    rx_bytes=$(echo "$line" | awk '{print $2}')
    tx_bytes=$(echo "$line" | awk '{print $9}')
    rx_bytes=$(echo "$rx_bytes" | sed 's/[^0-9]//g')
    tx_bytes=$(echo "$tx_bytes" | sed 's/[^0-9]//g')
    [ -z "$rx_bytes" ] && rx_bytes=0
    [ -z "$tx_bytes" ] && tx_bytes=0
        fi
    fi
    rx_gb=$(awk "BEGIN {printf \"%.2f\", $rx_bytes / 1073741824}" 2>/dev/null)
    tx_gb=$(awk "BEGIN {printf \"%.2f\", $tx_bytes / 1073741824}" 2>/dev/null)
    total_rx_bytes=$((total_rx_bytes + rx_bytes))
    total_tx_bytes=$((total_tx_bytes + tx_bytes))

    ssid_escaped=$(json_escape "$ssid")
    encryption_escaped=$(json_escape "$encryption")

    # Build JSON for this interface
    iface_json=$(cat << EOF
{
    "ifname": "$iface",
    "phy": "$phy_name",
    "ssid": "$ssid_escaped",
    "mode": "$mode",
    "band": "$band",
    "channel": "${channel:-?}",
    "frequency": "${freq:-?}",
    "wifi_type": "$wifi_type",
    "bandwidth": "$bw",
    "bitrate": "${bitrate:-}",
    "encryption": "$encryption_escaped",
    "signal": "${signal:-}",
    "noise": "${noise:-}",
    "clients": $clients,
    "max_clients": $max_clients,
    "at_capacity": $at_capacity,
    "rx_gb": ${rx_gb:-0},
    "tx_gb": ${tx_gb:-0}
}
EOF
)
    [ -n "$interfaces_json" ] && interfaces_json="$interfaces_json,"
    interfaces_json="$interfaces_json$iface_json"
done

total_rx_gb=$(awk "BEGIN {printf \"%.2f\", $total_rx_bytes / 1073741824}" 2>/dev/null)
total_tx_gb=$(awk "BEGIN {printf \"%.2f\", $total_tx_bytes / 1073741824}" 2>/dev/null)
total_gb=$(awk "BEGIN {printf \"%.2f\", ($total_rx_bytes + $total_tx_bytes) / 1073741824}" 2>/dev/null)

# --- DHCP Leases ---
dhcp_json=""
if [ -f /tmp/dhcp.leases ]; then
    first=true
    while read -r line; do
        [ -z "$line" ] && continue
        expires=$(echo "$line" | awk '{print $1}')
        mac=$(echo "$line" | awk '{print $2}')
        ip=$(echo "$line" | awk '{print $3}')
        hostname=$(echo "$line" | awk '{print $4}')
        hostname_escaped=$(json_escape "$hostname")
        now=$(date +%s)
        remaining=$((expires - now))
        [ "$remaining" -lt 0 ] && remaining=0
        lease_json="{\"ip\":\"$ip\",\"mac\":\"$mac\",\"hostname\":\"$hostname_escaped\",\"expires\":$remaining}"
        [ "$first" = true ] && first=false || dhcp_json="$dhcp_json,"
        dhcp_json="$dhcp_json$lease_json"
    done < /tmp/dhcp.leases
fi
[ -z "$dhcp_json" ] && dhcp_json=""

# --- SQM Status ---
sqm_enabled="false"
sqm_iface=""
sqm_download=""
sqm_upload=""

if [ -f /etc/config/sqm ]; then
    # Parse /etc/config/sqm
    in_section=false
    while IFS= read -r line; do
        case "$line" in
            *config*queue*)
                in_section=true
                sqm_iface=""
                sqm_dl=""
                sqm_ul=""
                ;;
            *option*enabled*)
                val=$(echo "$line" | awk '{print $3}' | tr -d "'\"")
                if [ "$val" = "1" ]; then
                    sqm_enabled="true"
                fi
                ;;
            *option*interface*)
                sqm_iface=$(echo "$line" | awk '{print $3}' | tr -d "'\"")
                ;;
            *option*download*)
                sqm_download=$(echo "$line" | awk '{print $3}' | tr -d "'\"")
                ;;
            *option*upload*)
                sqm_upload=$(echo "$line" | awk '{print $3}' | tr -d "'\"")
                ;;
        esac
    done < /etc/config/sqm
fi

sqm_json=$(cat << EOF
{
    "enabled": $sqm_enabled,
    "interface": "${sqm_iface:-}",
    "download_speed": "${sqm_download:-}",
    "upload_speed": "${sqm_upload:-}"
}
EOF
)

# --- Advanced mode: run wifi-suite.sh ---
advanced_text=""
#if [ "$mode" = "advanced" ]; then
    # Try to find wifi-suite.sh in the same directory, then /www/cgi-bin/
    wsuite=""
    for d in "." "/www/cgi-bin" "/sbin"; do
        if [ -f "$d/wifi-suite.sh" ] && [ -x "$d/wifi-suite.sh" ]; then
            wsuite="$d/wifi-suite.sh"
            break
        fi
    done
    if [ -n "$wsuite" ]; then
        advanced_text=$($wsuite 2>&1)
    else
        advanced_text="wifi-suite.sh not found"
    fi
#fi
advanced_escaped=$(json_escape "$advanced_text")

# --- Final JSON output ---
cat << EOF
{
    "model": "$model_escaped",
    "uptime": "$uptime_str",
    "uptime_seconds": $uptime_seconds,
    "interfaces": [$interfaces_json],
    "dhcp_leases": [$dhcp_json],
    "sqm": $sqm_json,
    "traffic": {
        "total_rx_gb": ${total_rx_gb:-0},
        "total_tx_gb": ${total_tx_gb:-0},
        "total_gb": ${total_gb:-0}
    },
    "advanced": "$advanced_escaped"
}
EOF