#!/bin/sh
# deploy.sh — status page + wifi-suite incremental upload to an OpenWrt router
#
# Usage: ./deploy.sh -i <router_ip> [-p <ssh_port>]
#
# Files deployed:
#   www/cgi-bin/status.cgi      → /www/cgi-bin/status.cgi
#   www/status/index.html       → /www/status/index.html
#   www/status/css/style.css    → /www/status/css/style.css
#   www/status/js/app.js        → /www/status/js/app.js
#   utils/wifi-suite.sh         → /www/cgi-bin/wifi-suite.sh
#
# Only files whose content has changed (compared via checksum) are copied.

usage() {
    cat <<EOF
Usage: $(basename "$0") -i <router_ip> [-p <ssh_port>]

Options:
  -i, --ip      Router IP address (required)
  -p, --port    SSH port (default: 22)
  -h, --help    Show this help message
EOF
    exit 1
}

# --- arguments ---------------------------------------------------------------
PORT=22
ROUTER_IP=""

while [ $# -gt 0 ]; do
    case "$1" in
        -i|--ip)   ROUTER_IP="$2"; shift 2 ;;
        -p|--port) PORT="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
done

[ -z "$ROUTER_IP" ] && usage

ROOT="root@$ROUTER_IP"

# --- map of local → remote paths --------------------------------------------
# Format: local_path:remote_path
FILES="\
www/cgi-bin/status.cgi:/www/cgi-bin/status.cgi
www/status/index.html:/www/status/index.html
www/status/css/style.css:/www/status/css/style.css
www/status/js/app.js:/www/status/js/app.js
utils/wifi-suite.sh:/www/cgi-bin/wifi-suite.sh"

# --- helper: get remote md5sum; returns the hash (or empty if missing) -----
remote_md5() {
    # shellcheck disable=SC2029
    # We explicitly want the remote host to run the command.
    ssh -p "$PORT" "$ROOT" "md5sum '$1' 2>/dev/null" | awk '{print $1}'
}

# --- helper: get local md5sum -----------------------------------------------
local_md5() {
    md5sum "$1" 2>/dev/null | awk '{print $1}'
}

# --- create remote directories -----------------------------------------------
echo "==> Creating remote directories..."
# Collect unique directories from the remote paths
dirs=""
IFS='
'
for entry in $FILES; do
    dir=$(dirname "${entry#*:}")
    # accumulate unique dirs
    case "$dirs" in
        *"$dir"*) ;;
        *) dirs="$dirs $dir" ;;
    esac
done
# shellcheck disable=SC2086
ssh -p "$PORT" "$ROOT" "mkdir -p $dirs"

# --- iterate over files and copy only changed ones --------------------------
echo ""
echo "==> Checking and copying modified files to $ROUTER_IP (port $PORT)..."

copied=0
skipped=0
failed=0

IFS='
'
for entry in $FILES; do
    local_path="${entry%%:*}"
    remote_path="${entry#*:}"

    if [ ! -f "$local_path" ]; then
        echo "  [SKIP]  $local_path  (local file not found)"
        skipped=$((skipped + 1))
        continue
    fi

    local_hash=$(local_md5 "$local_path")
    remote_hash=$(remote_md5 "$remote_path")

    if [ "$local_hash" = "$remote_hash" ]; then
        echo "  [  OK  ] $local_path  (unchanged)"
        skipped=$((skipped + 1))
    else
        echo "  [COPY]  $local_path  →  $remote_path"
        if scp -O -P "$PORT" "$local_path" "$ROOT":"$remote_path"; then
            copied=$((copied + 1))
        else
            echo "  [FAIL]  $local_path"
            failed=$((failed + 1))
        fi
    fi
done

# --- set executable bits ----------------------------------------------------
echo ""
echo "==> Setting executable permissions..."
ssh -p "$PORT" "$ROOT" "chmod +x /www/cgi-bin/status.cgi /www/cgi-bin/wifi-suite.sh"

# --- summary ----------------------------------------------------------------
echo ""
echo "==> Done! Files deployed to $ROUTER_IP."
echo "    Copied: $copied | Skipped (unchanged/missing): $skipped | Failed: $failed"