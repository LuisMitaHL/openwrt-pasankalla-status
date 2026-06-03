#!/bin/sh
# build-embed.sh — Minify, embed, compress all status page files into a
#                  single uci-defaults compatible script (embed.sh).
#
# Usage: ./build-embed.sh
#
# Output: dist/embed.sh  (drop into /etc/uci-defaults/ on the router)
#
# Pipeline:
#   1. Minify CSS  (basic sed-based minification)
#   2. Minify JS   (basic sed-based minification)
#   3. Minify HTML & inline CSS/JS
#   4. Gzip all payloads
#   5. Base64-encode all payloads
#   6. Write embed.sh with extraction commands
#
# Dependencies: gzip, base64, python3 (recommended) or sed

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$SCRIPT_DIR/dist"
WORK_DIR=$(mktemp -d)

# Cleanup on exit
trap 'rm -rf "$WORK_DIR"' EXIT

echo "==> build-embed.sh — OpenWrt Status Page packager"
echo ""

# ------------------------------------------------------------------
# 1. Source files
# ------------------------------------------------------------------
CSS_SRC="$SCRIPT_DIR/www/status/css/style.css"
JS_SRC="$SCRIPT_DIR/www/status/js/app.js"
HTML_SRC="$SCRIPT_DIR/www/status/index.html"
CGI_SRC="$SCRIPT_DIR/www/cgi-bin/status.cgi"
WIFI_SRC="$SCRIPT_DIR/utils/wifi-suite.sh"

for f in "$CSS_SRC" "$JS_SRC" "$HTML_SRC" "$CGI_SRC" "$WIFI_SRC"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: Missing source file: $f"
        exit 1
    fi
done

# ------------------------------------------------------------------
# 2. Minify CSS (via csso-cli or sed fallback)
# ------------------------------------------------------------------
echo "   [1/7] Minifying CSS..."
CSS_SIZE=$(wc -c < "$CSS_SRC")
if command -v npx >/dev/null 2>&1; then
    if npx --yes csso-cli -i "$CSS_SRC" -o "$WORK_DIR/style.min.css" 2>/dev/null; then
        echo "   CSS: $(wc -c < "$WORK_DIR/style.min.css") bytes (was $CSS_SIZE bytes, csso)"
    else
        # Fallback to basic minification
        echo "   WARNING: csso-cli failed. Falling back to basic CSS minification."
        tr -d '\n\t\r' < "$CSS_SRC" | sed \
            -e 's/  */ /g' \
            -e 's/ *{ */ {/g' \
            -e 's/ *} */}\n/g' \
            -e 's/ *: */:/g' \
            -e 's/ *; */;/g' \
            -e 's/ *, */,/g' \
            -e 's/^ *//' \
            -e 's/ *$//' \
            -e '/^$/d' \
            -e 's/\/\*.*\*\///g' > "$WORK_DIR/style.min.css"
        echo "   CSS: $(wc -c < "$WORK_DIR/style.min.css") bytes (was $CSS_SIZE bytes)"
    fi
else
    # No npx — basic sed minification
    echo "   WARNING: npx not found. Using basic CSS minification."
    tr -d '\n\t\r' < "$CSS_SRC" | sed \
        -e 's/  */ /g' \
        -e 's/ *{ */ {/g' \
        -e 's/ *} */}\n/g' \
        -e 's/ *: */:/g' \
        -e 's/ *; */;/g' \
        -e 's/ *, */,/g' \
        -e 's/^ *//' \
        -e 's/ *$//' \
        -e '/^$/d' \
        -e 's/\/\*.*\*\///g' > "$WORK_DIR/style.min.css"
    echo "   CSS: $(wc -c < "$WORK_DIR/style.min.css") bytes (was $CSS_SIZE bytes)"
fi

# ------------------------------------------------------------------
# 3. Minify JS (via terser or sed fallback)
# ------------------------------------------------------------------
echo "   [2/7] Minifying JavaScript..."
JS_SIZE=$(wc -c < "$JS_SRC")
if command -v npx >/dev/null 2>&1; then
    if npx --yes terser "$JS_SRC" -o "$WORK_DIR/app.min.js" -c -m 2>/dev/null; then
        echo "   JS: $(wc -c < "$WORK_DIR/app.min.js") bytes (was $JS_SIZE bytes, terser)"
    else
        # Fallback to basic minification
        echo "   WARNING: terser failed. Falling back to basic JS minification."
        sed 's|//.*$||' "$JS_SRC" | tr -d '\n\t\r' | sed 's/  */ /g' > "$WORK_DIR/app.min.js"
        echo "   JS: $(wc -c < "$WORK_DIR/app.min.js") bytes (was $JS_SIZE bytes)"
    fi
else
    # No npx — basic sed minification
    echo "   WARNING: npx not found. Using basic JS minification."
    sed 's|//.*$||' "$JS_SRC" | tr -d '\n\t\r' | sed 's/  */ /g' > "$WORK_DIR/app.min.js"
    echo "   JS: $(wc -c < "$WORK_DIR/app.min.js") bytes (was $JS_SIZE bytes)"
fi

# ------------------------------------------------------------------
# 3b. Minify wifi-suite.sh (strip comments, blank lines, trim whitespace)
# ------------------------------------------------------------------
echo "   [3/7] Minifying wifi-suite.sh..."
WIFI_SIZE=$(wc -c < "$WIFI_SRC")
# Safe shell minification: strip comment-only lines, blank lines, and leading/trailing whitespace.
# Does NOT touch heredoc content or inline comments (# inside strings).
sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$WIFI_SRC" > "$WORK_DIR/wifi-suite.min.sh"
MIN_WIFI_SIZE=$(wc -c < "$WORK_DIR/wifi-suite.min.sh")
echo "   wifi-suite.sh: $MIN_WIFI_SIZE bytes (was $WIFI_SIZE bytes)"

# ------------------------------------------------------------------
# 4. Inline CSS & JS into HTML
# ------------------------------------------------------------------
echo "   [4/7] Building self-contained HTML..."

if command -v python3 >/dev/null 2>&1; then
    # Write temporary inline script to avoid shell/Python quoting conflicts
    cat > "$WORK_DIR/inline.py" << 'PYEOF'
import sys, re

html_path = sys.argv[1]
css_path = sys.argv[2]
js_path = sys.argv[3]
out_path = sys.argv[4]

with open(html_path, 'r') as f:
    html = f.read()

with open(css_path, 'r') as f:
    css_min = f.read()

with open(js_path, 'r') as f:
    js_min = f.read()

# Replace <link rel="stylesheet" ...> with inline <style>
html = re.sub(
    r'<link[^>]*rel=["\']stylesheet["\'][^>]*>',
    lambda m: '<style>' + css_min + '</style>',
    html
)

# Replace <script src="..."></script> with inline <script>
html = re.sub(
    r'<script[^>]*src=["\'][^"\']*["\'][^>]*></script>',
    lambda m: '<script>' + js_min + '</script>',
    html
)

# Collapse blank lines
html = re.sub(r'\n\s*\n', '\n', html)
html = html.strip()

with open(out_path, 'w') as f:
    f.write(html)
PYEOF
    python3 "$WORK_DIR/inline.py" "$HTML_SRC" "$WORK_DIR/style.min.css" "$WORK_DIR/app.min.js" "$WORK_DIR/index.html"
else
    # Fallback: sed-based replacement
    echo "   WARNING: python3 not found, using sed fallback..."
    MIN_CSS=$(cat "$WORK_DIR/style.min.css")
    MIN_JS=$(cat "$WORK_DIR/app.min.js")
    CSS_ESC=$(echo "$MIN_CSS" | sed 's/[\/&"'\'']/\\&/g')
    JS_ESC=$(echo "$MIN_JS" | sed 's/[\/&"'\'']/\\&/g')
    sed \
        -e "s|<link[^>]*stylesheet[^>]*>|<style>$(echo "$CSS_ESC")</style>|g" \
        -e "s|<script[^>]*src=\"[^\"]*\"[^>]*></script>|<script>$(echo "$JS_ESC")</script>|g" \
        "$HTML_SRC" > "$WORK_DIR/index.html"
fi

INLINE_HTML_SIZE=$(wc -c < "$WORK_DIR/index.html")
echo "   HTML (self-contained): $INLINE_HTML_SIZE bytes"

# ------------------------------------------------------------------
# 4b. Minify self-contained HTML (via html-minifier-terser or skip)
# ------------------------------------------------------------------
echo "   [5/7] Minifying self-contained HTML..."
if command -v npx >/dev/null 2>&1; then
    if npx --yes html-minifier-terser \
        --collapse-whitespace \
        --remove-comments \
        --remove-optional-tags \
        --remove-redundant-attributes \
        --remove-script-type-attributes \
        --remove-tag-whitespace \
        --use-short-doctype \
        --minify-css \
        --minify-js \
        -o "$WORK_DIR/index.html" \
        "$WORK_DIR/index.html" 2>/dev/null; then
        MIN_HTML_SIZE=$(wc -c < "$WORK_DIR/index.html")
        echo "   HTML minified: $MIN_HTML_SIZE bytes (html-minifier-terser)"
    else
        echo "   WARNING: html-minifier-terser failed. Using unminified HTML."
    fi
else
    echo "   WARNING: npx not found. Using unminified HTML."
fi

# ------------------------------------------------------------------
# 5. Gzip each payload
# ------------------------------------------------------------------
echo "   [6/7] Compressing payloads..."
gzip -9 -k -f "$WORK_DIR/index.html"
gzip -9 -k -f "$CGI_SRC" -c > "$WORK_DIR/status.cgi.gz"
gzip -9 -k -f "$WORK_DIR/wifi-suite.min.sh" -c > "$WORK_DIR/wifi-suite.sh.gz"
gzip -9 -k -f "$WORK_DIR/style.min.css" -c > "$WORK_DIR/style.min.css.gz"
gzip -9 -k -f "$WORK_DIR/app.min.js" -c > "$WORK_DIR/app.min.js.gz"

# ------------------------------------------------------------------
# 6. Base64-encode each payload
# ------------------------------------------------------------------
echo "   [7/7] Generating embed.sh..."
mkdir -p "$DIST_DIR"

B64_HTML=$(base64 -w0 < "$WORK_DIR/index.html.gz")
B64_CGI=$(base64 -w0 < "$WORK_DIR/status.cgi.gz")
B64_WIFI=$(base64 -w0 < "$WORK_DIR/wifi-suite.sh.gz")
B64_CSS=$(base64 -w0 < "$WORK_DIR/style.min.css.gz")
B64_JS=$(base64 -w0 < "$WORK_DIR/app.min.js.gz")

# ------------------------------------------------------------------
# 7. Write embed.sh (uci-defaults compatible)
# ------------------------------------------------------------------
cat > "$DIST_DIR/embed.sh" << EOSCRIPT
#!/bin/sh
# OpenWrt Status Page — uci-defaults deployment script
# Generated by build-embed.sh on $(date)
# Drop this file into /etc/uci-defaults/ on the router and reboot,
# or run: sh /etc/uci-defaults/embed.sh

set -e

echo "==> OpenWrt Status Page: Installing files..."

# Create directories
mkdir -p /www/cgi-bin /www/status /www/status/css /www/status/js

# status.cgi
echo "$B64_CGI" | base64 -d | gunzip > /www/cgi-bin/status.cgi
chmod +x /www/cgi-bin/status.cgi

# index.html (self-contained: CSS + JS inlined)
echo "$B64_HTML" | base64 -d | gunzip > /www/status/index.html

# wifi-suite.sh
echo "$B64_WIFI" | base64 -d | gunzip > /www/cgi-bin/wifi-suite.sh
chmod +x /www/cgi-bin/wifi-suite.sh

# style.css (fallback, already inlined in HTML)
echo "$B64_CSS" | base64 -d | gunzip > /www/status/css/style.css

# app.js (fallback, already inlined in HTML)
echo "$B64_JS" | base64 -d | gunzip > /www/status/js/app.js

echo "==> Done! Reboot or reload uhttpd to apply."
exit 0
EOSCRIPT

chmod +x "$DIST_DIR/embed.sh"

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
GZ_HTML_SIZE=$(wc -c < "$WORK_DIR/index.html.gz")
GZ_CGI_SIZE=$(wc -c < "$WORK_DIR/status.cgi.gz")
GZ_WIFI_SIZE=$(wc -c < "$WORK_DIR/wifi-suite.sh.gz")
GZ_CSS_SIZE=$(wc -c < "$WORK_DIR/style.min.css.gz")
GZ_JS_SIZE=$(wc -c < "$WORK_DIR/app.min.js.gz")
RAW_WIFI_SIZE=$(wc -c < "$WORK_DIR/wifi-suite.min.sh")
EMBED_SIZE=$(wc -c < "$DIST_DIR/embed.sh")

echo ""
echo "================================================"
echo "  Build complete!"
echo "  Output: $DIST_DIR/embed.sh"
echo ""
echo "  File sizes:"
echo "    status.cgi       : $GZ_CGI_SIZE bytes (gzip'd)"
echo "    index.html       : $INLINE_HTML_SIZE bytes ($GZ_HTML_SIZE gzip'd)"
echo "    wifi-suite.sh    : $RAW_WIFI_SIZE bytes ($GZ_WIFI_SIZE gzip'd)"
echo "    style.css        : $GZ_CSS_SIZE bytes (gzip'd, minified)"
echo "    app.js           : $GZ_JS_SIZE bytes (gzip'd, minified)"
echo "    ------------------------------------"
echo "    embed.sh         : $EMBED_SIZE bytes"
echo "================================================"