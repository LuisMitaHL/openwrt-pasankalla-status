#!/bin/sh
# Copyright 2021-2023 Hannu Nyman
# Modified by Double-G, Version 16 2026-02-25
# Source: https://forum.openwrt.org/t/802-11r-fast-transition-how-to-understand-that-ft-works/110920/229?u=double-g
#
# Parameters:
#  -s, --sort   Sort clients by hostname/IP within each interface
#  -l, --local  Skip network lookups (ARP/DNS), use only local leases/UCI
#  -h, --help   Show this help text
#
# SPDX-License-Identifier: GPL-2.0-only

# --- HELP FUNCTION ---
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -s, --sort   Sort clients alphabetically by hostname/IP.
  -l, --local  Fast mode: Only use local DHCP leases and UCI config. 
  -h, --help   Display this help message.

EOF
    exit 0
}

# --- AUTOMATIC QUALITY CHECKS ---
if [ ! -d "/var/run/hostapd" ]; then
    echo "Error: /var/run/hostapd directory not found. Is hostapd running?"
    exit 1
fi

if ! command -v hostapd_cli >/dev/null 2>&1; then
    echo "Error: hostapd_cli command not found. Please install hostapd-utils."
    exit 1
fi

# --- PARAMETER PARSING ---
SORT_BY_NAME=false
LOCAL_ONLY=false

while [ "$#" -gt 0 ]; do
    case "$1" in
        -s|--sort)  SORT_BY_NAME=true ;;
        -l|--local) LOCAL_ONLY=true ;;
        -h|--help)  show_help ;;
        *) echo "Unknown parameter: $1 (Use -h for help)"; exit 1 ;;
    esac
    shift
done

cd /var/run/hostapd || exit 1

for socket in *; do
    [ -S "$socket" ] || continue
    [ "$socket" = "global" ] && continue

    # Gather header info
    ssid=$(hostapd_cli -i "$socket" get_config 2>/dev/null | grep "^ssid=" | cut -d'=' -f2-)
    if_status=$(hostapd_cli -i "$socket" status)
    channel=$(echo "$if_status" | sed -n 's/^channel=//p' | head -n1)
    freq=$(echo "$if_status" | sed -n 's/^freq=//p' | head -n1)
    [ -z "$ssid" ] && ssid=$(echo "$if_status" | sed -n 's/^ssid=//p' | head -n1)

    # Determine AP Wi-Fi Version
    if echo "$if_status" | grep -q "ieee80211be=1"; then wifi_ver="Wi-Fi 7"
    elif echo "$if_status" | grep -q "ieee80211ax=1"; then wifi_ver="Wi-Fi 6"
    elif echo "$if_status" | grep -q "ieee80211ac=1"; then wifi_ver="Wi-Fi 5"
    elif echo "$if_status" | grep -q "ieee80211n=1"; then wifi_ver="Wi-Fi 4"
    else wifi_ver="Legacy/Unknown"; fi

    # Determine AP Bandwidth
    bw_vht=$(echo "$if_status" | sed -n 's/^vht_oper_chwidth=//p')
    bw_he=$(echo "$if_status" | sed -n 's/^he_oper_chwidth=//p')
    bw_eht=$(echo "$if_status" | sed -n 's/^eht_oper_chwidth=//p')
    bw_val="${bw_eht:-${bw_he:-$bw_vht}}"

    case "$bw_val" in
        1) ap_bw="80 MHz" ;;
        2) ap_bw="160 MHz" ;;
        3) ap_bw="80+80 MHz" ;;
        4) ap_bw="320 MHz" ;;
        *)
            if echo "$if_status" | grep -qE "secondary_channel=[1-9]|-1"; then
                ap_bw="40 MHz"
            else
                ap_bw="20 MHz"
            fi
        ;;
    esac

    printf "\n> IF: %s | SSID: %s | %s (%s) | Channel: %s (%s MHz) \n" \
           "$socket" "$ssid" "$wifi_ver" "$ap_bw" "${channel:-?}" "${freq:-?}"

    stations=$(hostapd_cli -i "$socket" list_sta)
    [ -z "$stations" ] && { echo "  (No stations connected)"; continue; }

    for assoc in $stations; do
        sta_info=$(hostapd_cli -i "$socket" sta "$assoc")

        # --- Identification ---
        u_ip="" u_name=""
        if [ -f /tmp/dhcp.leases ]; then
            lease_line=$(grep -i "$assoc" /tmp/dhcp.leases | head -n1)
            [ -n "$lease_line" ] && { u_ip=$(echo "$lease_line" | awk '{print $3}'); u_name=$(echo "$lease_line" | awk '{print $4}'); }
        fi
        if [ -z "$u_ip" ]; then
            cfg_sec=$(uci -q show dhcp | grep -i "$assoc" | cut -d'.' -f2)
            if [ -n "$cfg_sec" ]; then
                u_ip=$(uci -q get "dhcp.$cfg_sec.ip"); u_name=$(uci -q get "dhcp.$cfg_sec.name")
            fi
        fi
        if [ "$LOCAL_ONLY" = false ] && [ -z "$u_ip" ]; then
            u_ip=$(ip neigh show | grep -i "$assoc" | awk '{print $1}' | head -n1)
            if [ -n "$u_ip" ]; then
                u_name=$(nslookup "$u_ip" 2>/dev/null | grep "name =" | cut -d'=' -f2 | xargs | cut -d'.' -f1)
            fi
        fi
        display_name="${u_name:-?} ($u_ip)"
        [ -z "$u_ip" ] && display_name="$assoc"

        # --- Station Data ---
        if echo "$sta_info" | grep -qiE "EHT-CAP|EHT_CAP"; then sbw="Wi-Fi 7"
        elif echo "$sta_info" | grep -qiE "HE-CAP|HE_CAP"; then sbw="Wi-Fi 6"
        elif echo "$sta_info" | grep -qiE "VHT-CAP|VHT_CAP"; then sbw="Wi-Fi 5"
        elif echo "$sta_info" | grep -qiE "HT-CAP|HT_CAP"; then sbw="Wi-Fi 4"
        else sbw="Legacy"; fi

        suite=$(echo "$sta_info" | grep "AKMSuiteSelector" | cut -f 2 -d"=")
        wpa_ver=$(echo "$sta_info" | grep "^wpa=" | cut -f 2 -d"=")
        cipher_hex=$(echo "$sta_info" | grep "dot11RSNAStatsSelectedPairwiseCipher" | cut -f 2 -d"=")

        case "$suite" in
            00-0f-ac-1) akm="802.1X" ;; 00-0f-ac-2) akm="PSK" ;;
            00-0f-ac-3) akm="FT-802.1X" ;; 00-0f-ac-4) akm="FT-PSK" ;;
            00-0f-ac-8) akm="SAE" ;; 00-0f-ac-9) akm="FT-SAE" ;;
            00-0f-ac-18) akm="OWE" ;; *) akm="Other-$suite" ;;
        esac

        case "$cipher_hex" in
            00-0f-ac-4) cipher="CCMP-128" ;; 00-0f-ac-10) cipher="CCMP-256" ;;
            00-0f-ac-8) cipher="GCMP-128" ;; 00-0f-ac-9) cipher="GCMP-256" ;;
            *) cipher="AES/Other" ;;
        esac

        case "$suite" in
            00-0f-ac-8|00-0f-ac-9|00-0f-ac-11|00-0f-ac-12|00-0f-ac-18|00-0f-ac-24) wpa_proto="WPA3" ;;
            *) [ "$wpa_ver" = "2" ] && wpa_proto="WPA2" || wpa_proto="WPA/Leg" ;;
        esac

        printf "  STA: %-32s | %-8s | %-4s - %-8s | %-12s\n" \
               "$display_name" "$sbw" "$wpa_proto" "$akm" "$cipher"

    done | if [ "$SORT_BY_NAME" = true ]; then sort -i; else cat; fi
done
