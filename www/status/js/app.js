/**
 * OpenWrt Router Status Page - Main Application
 * Vanilla JS - No frameworks
 */

(function() {
    'use strict';

    // State
    var currentMode = 'basic';
    var countdownTimer = null;
    var secondsUntilRefresh = 10;
    var initialLoad = true;

    // DOM references
    var el = {};

    function initDom() {
        el.loading     = document.getElementById('loading');
        el.error       = document.getElementById('error');
        el.content     = document.getElementById('content');
        el.lastUpdate  = document.getElementById('last-update');
        el.countdown   = document.getElementById('countdown');
        el.summarySection = document.getElementById('summary-section');
        el.summary     = document.getElementById('summary');
        el.interfacesSection = document.getElementById('interfaces-section');
        el.interfaces  = document.getElementById('interfaces');
        el.dhcpSection = document.getElementById('dhcp-section');
        el.dhcp        = document.getElementById('dhcp');
        el.sqmSection  = document.getElementById('sqm-section');
        el.sqm         = document.getElementById('sqm');
        el.trafficSection = document.getElementById('traffic-section');
        el.traffic     = document.getElementById('traffic');
        el.advanced    = document.getElementById('advanced');
        el.advancedPre = document.getElementById('advanced-pre');
        el.basicBtn    = document.getElementById('mode-basic');
        el.advancedBtn = document.getElementById('mode-advanced');
    }

    // HTML escape using char codes to survive auto-formatters
    function escHtml(str) {
        if (!str) return '';
        return String(str)
            .replace(/\x26/g, function() { return '\x26amp;'; })
            .replace(/\x3C/g, function() { return '\x26lt;'; })
            .replace(/\x3E/g, function() { return '\x26gt;'; })
            .replace(/\x22/g, function() { return '\x26quot;'; })
            .replace(/\x27/g, function() { return '\x26#039;'; });
    }

    function getCookie(name) {
        var match = document.cookie.match(new RegExp('(^| )' + name + '=([^;]+)'));
        return match ? decodeURIComponent(match[2]) : null;
    }

    function setCookie(name, value, days) {
        var expires = new Date(Date.now() + days * 864e5).toUTCString();
        document.cookie = name + '=' + encodeURIComponent(value) + '; expires=' + expires + '; path=/';
    }

    function setMode(mode) {
        currentMode = mode;
        setCookie('status_mode', mode, 365);
        el.basicBtn.className = 'mode-btn' + (mode === 'basic' ? ' active' : '');
        el.advancedBtn.className = 'mode-btn' + (mode === 'advanced' ? ' active' : '');
        el.advanced.className = 'advanced-panel' + (mode !== 'advanced' ? ' hidden' : '');
        initialLoad = true;
        fetchStatus();
    }

    function fetchStatus() {
        var url = '/cgi-bin/status.cgi?mode=' + encodeURIComponent(currentMode);

        // On initial load, show loading spinner and hide content.
        // On background refresh, keep content visible.
        if (initialLoad) {
            el.loading.className = 'loading';
            el.error.className = 'error hidden';
            el.content.className = 'hidden';
        }

        fetch(url)
            .then(function(response) {
                if (!response.ok) throw new Error('HTTP ' + response.status);
                return response.json();
            })
            .then(function(data) {
                if (initialLoad) {
                    el.loading.className = 'loading hidden';
                    el.content.className = '';
                    initialLoad = false;
                }
                render(data);
            })
            .catch(function(err) {
                if (initialLoad) {
                    el.loading.className = 'loading hidden';
                    el.error.className = 'error';
                    var msgEl = el.error.querySelector('.error-msg');
                    if (msgEl) msgEl.textContent = 'Conexi\u00F3n perdida: ' + err.message;
                }
                // On background refresh errors, stay silent — keep showing old data
            });
    }

    function render(data) {
        if (currentMode === 'basic') {
            renderBasic(data);
        } else {
            renderAdvanced(data);
        }
        updateTimestamp();
        resetCountdown();
    }

    // ---- Basic mode rendering ----

    function renderBasic(data) {
        // Hide sections not used in basic mode
        el.summarySection.className = 'section hidden';
        el.sqmSection.className = 'section hidden';

        // Interfaces: show simplified per-radio cards
        renderInterfacesBasic(data.interfaces);

        // Traffic: just RX and TX
        renderTrafficBasic(data.traffic);

        // DHCP: hostname + IP only
        renderDhcpBasic(data.dhcp_leases);
    }

    function getBandLabel(freq) {
        if (!freq || freq < 4000) return '2.4 GHz';
        if (freq < 6000) return '5 GHz';
        return '6 GHz';
    }

    function getBandClass(freq) {
        if (!freq || freq < 4000) return 'band-2g';
        if (freq < 6000) return 'band-5g';
        return 'band-6g';
    }

    function isUnencrypted(iface) {
        var enc = iface.encryption;
        return !enc || /none|open/i.test(enc);
    }

    function renderInterfacesBasic(interfaces) {
        if (!interfaces || !interfaces.length) {
            el.interfaces.innerHTML = '<div class="empty-state">No se encontraron interfaces inal\u00E1mbricas.</div>';
            el.interfacesSection.className = 'section';
            return;
        }

        el.interfacesSection.className = 'section';

        // Consolidate per-phy: group interfaces by phy name
        var phyMap = {};
        for (var i = 0; i < interfaces.length; i++) {
            var iface = interfaces[i];
            var phy = iface.phy || 'phy0';
            if (!phyMap[phy]) {
                phyMap[phy] = {
                    phy: phy,
                    visibleSsids: [],
                    hiddenSsids: [],
                    clients: 0,
                    maxClients: 0,
                    freq: 0
                };
            }
            var group = phyMap[phy];
            // Always exclude OWE SSIDs entirely
            //if (iface.encryption && /owe/i.test(iface.encryption)) continue;

            group.clients += (iface.clients || 0);
            // Track the frequency (use the first non-0 value)
            if (iface.frequency && !group.freq) group.freq = iface.frequency;
            // Take the highest max_clients across interfaces in this phy
            if ((iface.max_clients || 0) > group.maxClients) {
                group.maxClients = iface.max_clients;
            }
            // Separate into visible (preferred) and hidden SSIDs
            if (isUnencrypted(iface)) {
                group.visibleSsids.push(iface.ssid || '(sin SSID)');
            } else {
                group.hiddenSsids.push(iface.ssid || '(sin SSID)');
            }
        }

        // Build the SSID list for each phy:
        // - If there are unencrypted SSIDs, show only those
        // - Otherwise show the encrypted ones
        var html = '';
        for (var phy in phyMap) {
            var g = phyMap[phy];
            var ssidList;
            if (g.visibleSsids.length > 0) {
                ssidList = g.visibleSsids.join(', ');
            } else if (g.hiddenSsids.length > 0) {
                ssidList = g.hiddenSsids.join(', ');
            } else {
                ssidList = '(sin SSID)';
            }
            var capClass = g.clients >= g.maxClients ? 'full' : 'ok';
            var capText = g.clients >= g.maxClients ? '\u26A0 Lleno' : (g.clients + '/' + g.maxClients);
            var bandLabel = getBandLabel(g.freq);
            var bandClass = getBandClass(g.freq);

            html +=
            '<div class="iface-card ' + bandClass + '">' +
                '<div class="iface-header">' +
                    '<div>' +
                        '<div class="iface-name">' + escHtml(ssidList) + '</div>' +
                        '<div class="iface-ssid">' + escHtml(bandLabel) + '</div>' +
                    '</div>' +
                    '<div style="text-align:right;">' +
                        '<div class="iface-client-count">' + (g.clients || 0) + '</div>' +
                        '<div class="iface-capacity-badge ' + capClass + '">' + capText + '</div>' +
                    '</div>' +
                '</div>' +
            '</div>';
        }
        el.interfaces.innerHTML = html;
    }

    function renderTrafficBasic(traffic) {
        el.trafficSection.className = 'section';
        if (!traffic) {
            el.traffic.innerHTML = '<div class="empty-state">Sin datos de tr\u00E1fico.</div>';
            return;
        }
        el.traffic.innerHTML =
            '<div class="traffic-total">' +
                '<div class="traffic-total-item"><div class="label">RX Total</div><div class="val">' + (traffic.total_rx_gb || '0.00') + ' GB</div></div>' +
                '<div class="traffic-total-item"><div class="label">TX Total</div><div class="val">' + (traffic.total_tx_gb || '0.00') + ' GB</div></div>' +
            '</div>';
    }

    function renderDhcpBasic(leases) {
        el.dhcpSection.className = 'section';
        if (!leases || !leases.length) {
            el.dhcp.innerHTML = '<div class="empty-state">Sin concesiones DHCP activas.</div>';
            return;
        }

        var html = '<table class="dhcp-table"><thead><tr><th>Hostname</th><th>Direcci\u00F3n IP</th></tr></thead><tbody>';
        for (var k = 0; k < leases.length; k++) {
            var lease = leases[k];
            var host = lease.hostname || '?';
            html +=
                '<tr>' +
                    '<td>' + escHtml(host) + '</td>' +
                    '<td>' + escHtml(lease.ip) + '</td>' +
                '</tr>';
        }
        html += '</tbody></table>';
        el.dhcp.innerHTML = html;
    }

    // ---- Advanced mode rendering ----

    function renderAdvanced(data) {
        // Show all sections
        el.summarySection.className = 'section';
        el.sqmSection.className = 'section';
        el.trafficSection.className = 'section';
        el.dhcpSection.className = 'section';
        el.interfacesSection.className = 'section';

        renderSummary(data);
        renderInterfacesAdvanced(data.interfaces);
        renderDhcpAdvanced(data.dhcp_leases);
        renderSqm(data.sqm);
        renderTrafficAdvanced(data.traffic);
        if (data.advanced) {
            el.advancedPre.textContent = data.advanced;
        }
    }

    function renderSummary(data) {
        var totalClients = 0;
        var ifaces = data.interfaces;
        if (ifaces) {
            for (var i = 0; i < ifaces.length; i++) {
                totalClients += ifaces[i].clients || 0;
            }
        }
        el.summary.innerHTML =
            '<div class="summary-card">' +
                '<div class="label">Router</div>' +
                '<div class="value" style="font-size:0.95rem;">' + escHtml(data.model || 'Desconocido') + '</div>' +
            '</div>' +
            '<div class="summary-card">' +
                '<div class="label">Tiempo activo</div>' +
                '<div class="value uptime">' + escHtml(data.uptime || '0s') + '</div>' +
            '</div>' +
            '<div class="summary-card">' +
                '<div class="label">Clientes Totales</div>' +
                '<div class="value">' + totalClients + '</div>' +
            '</div>' +
            '<div class="summary-card">' +
                '<div class="label">Datos Totales</div>' +
                '<div class="value" style="font-size:1rem;">' + (data.traffic ? data.traffic.total_gb : '0') + ' GB</div>' +
            '</div>';
    }

    function renderInterfacesAdvanced(interfaces) {
        if (!interfaces || !interfaces.length) {
            el.interfaces.innerHTML = '<div class="empty-state">No se encontraron interfaces inal\u00E1mbricas.</div>';
            return;
        }

        var html = '';
        for (var j = 0; j < interfaces.length; j++) {
            var iface = interfaces[j];
            var capClass = iface.at_capacity ? 'full' : 'ok';
            var capText = iface.at_capacity ? '\u26A0 Lleno' : (iface.clients + '/' + iface.max_clients);
            var bandClass = getBandClass(iface.frequency);

            html +=
            '<div class="iface-card ' + bandClass + '">' +
                '<div class="iface-header">' +
                    '<div>' +
                        '<div class="iface-name">' + escHtml(iface.ssid || iface.ifname) + '</div>' +
                        '<div class="iface-ssid">' + escHtml(iface.ifname) + ' \u00B7 ' + escHtml(iface.band) + '</div>' +
                    '</div>' +
                    '<div style="text-align:right;">' +
                        '<div class="iface-client-count">' + (iface.clients || 0) + '</div>' +
                        '<div class="iface-capacity-badge ' + capClass + '">' + capText + '</div>' +
                    '</div>' +
                '</div>' +
                '<div class="iface-body">' +
                    '<div class="iface-detail-row">' +
                        '<span class="iface-detail-label">Tipo WiFi</span>' +
                        '<span class="iface-detail-value">' + escHtml(iface.wifi_type) + '</span>' +
                    '</div>' +
                    '<div class="iface-detail-row">' +
                        '<span class="iface-detail-label">Canal</span>' +
                        '<span class="iface-detail-value">' + escHtml(iface.channel) + ' (' + escHtml(iface.frequency) + ' MHz)</span>' +
                    '</div>' +
                    '<div class="iface-detail-row">' +
                        '<span class="iface-detail-label">Ancho de banda</span>' +
                        '<span class="iface-detail-value">' + escHtml(iface.bandwidth) + '</span>' +
                    '</div>' +
                    '<div class="iface-detail-row">' +
                        '<span class="iface-detail-label">Bitrate</span>' +
                        '<span class="iface-detail-value">' + escHtml(iface.bitrate || 'N/A') + '</span>' +
                    '</div>' +
                    '<div class="iface-detail-row">' +
                        '<span class="iface-detail-label">Cifrado</span>' +
                        '<span class="iface-detail-value">' + escHtml(iface.encryption || 'N/A') + '</span>' +
                    '</div>' +
                    '<div class="iface-detail-row">' +
                        '<span class="iface-detail-label">Se\u00F1al / Ruido</span>' +
                        '<span class="iface-detail-value">' + escHtml(iface.signal || '?') + ' / ' + escHtml(iface.noise || '?') + ' dBm</span>' +
                    '</div>' +
                    '<div class="iface-traffic">' +
                        '<div class="iface-traffic-item"><div class="val">' + (iface.rx_gb || '0.00') + ' GB</div><div style="color:var(--text-muted);font-size:0.72rem;">RX</div></div>' +
                        '<div class="iface-traffic-item"><div class="val">' + (iface.tx_gb || '0.00') + ' GB</div><div style="color:var(--text-muted);font-size:0.72rem;">TX</div></div>' +
                    '</div>' +
                '</div>' +
            '</div>';
        }
        el.interfaces.innerHTML = html;
    }

    function renderDhcpAdvanced(leases) {
        if (!leases || !leases.length) {
            el.dhcp.innerHTML = '<div class="empty-state">Sin concesiones DHCP activas.</div>';
            return;
        }

        var html = '<table class="dhcp-table"><thead><tr><th>Hostname</th><th>Direcci\u00F3n IP</th><th>Direcci\u00F3n MAC</th><th>Expira</th></tr></thead><tbody>';
        for (var k = 0; k < leases.length; k++) {
            var lease = leases[k];
            var host = lease.hostname || '?';
            var expiresStr = lease.expires > 0 ? Math.floor(lease.expires / 60) + 'm ' + (lease.expires % 60) + 's' : 'Expirado';
            html +=
                '<tr>' +
                    '<td>' + escHtml(host) + '</td>' +
                    '<td>' + escHtml(lease.ip) + '</td>' +
                    '<td class="mac-addr">' + escHtml((lease.mac || '').toLowerCase()) + '</td>' +
                    '<td>' + expiresStr + '</td>' +
                '</tr>';
        }
        html += '</tbody></table>';
        el.dhcp.innerHTML = html;
    }

    function renderSqm(sqm) {
        if (!sqm) {
            el.sqm.innerHTML = '<div class="sqm-card"><div class="sqm-status"><span class="sqm-dot disabled"></span> SQM: No disponible</div></div>';
            return;
        }

        var enabled = sqm.enabled === true;
        var dotClass = enabled ? 'enabled' : 'disabled';
        var statusText = enabled ? 'Habilitado' : 'Deshabilitado';
        var speedHtml = '';

        if (enabled && (sqm.download_speed || sqm.upload_speed)) {
            speedHtml = '<div class="sqm-speeds">';
            if (sqm.download_speed) speedHtml += '<div class="sqm-speed-item">Descarga: <span class="val">' + escHtml(sqm.download_speed) + ' Kbps</span></div>';
            if (sqm.upload_speed)   speedHtml += '<div class="sqm-speed-item">Subida:   <span class="val">' + escHtml(sqm.upload_speed) + ' Kbps</span></div>';
            speedHtml += '</div>';
        }

        el.sqm.innerHTML =
            '<div class="sqm-card">' +
                '<div class="sqm-status">' +
                    '<span class="sqm-dot ' + dotClass + '"></span>' +
                    'SQM: <strong>' + statusText + '</strong>' +
                    (sqm.interface ? ' en ' + escHtml(sqm.interface) : '') +
                '</div>' +
                speedHtml +
            '</div>';
    }

    function renderTrafficAdvanced(traffic) {
        if (!traffic) {
            el.traffic.innerHTML = '<div class="empty-state">Sin datos de tr\u00E1fico.</div>';
            return;
        }
        el.traffic.innerHTML =
            '<div class="traffic-total">' +
                '<div class="traffic-total-item"><div class="label">RX Total</div><div class="val">' + (traffic.total_rx_gb || '0.00') + ' GB</div></div>' +
                '<div class="traffic-total-item"><div class="label">TX Total</div><div class="val">' + (traffic.total_tx_gb || '0.00') + ' GB</div></div>' +
                '<div class="traffic-total-item"><div class="label">Total</div><div class="val">' + (traffic.total_gb || '0.00') + ' GB</div></div>' +
            '</div>';
    }

    function resetCountdown() {
        secondsUntilRefresh = 10;
        if (el.countdown) el.countdown.textContent = 'Actualizando en ' + secondsUntilRefresh + 's';
        if (countdownTimer) clearInterval(countdownTimer);
        countdownTimer = setInterval(function() {
            secondsUntilRefresh--;
            if (el.countdown) el.countdown.textContent = 'Actualizando en ' + secondsUntilRefresh + 's';
            if (secondsUntilRefresh <= 0) {
                clearInterval(countdownTimer);
                countdownTimer = null;
                fetchStatus();
            }
        }, 1000);
    }

    function updateTimestamp() {
        var now = new Date();
        if (el.lastUpdate) el.lastUpdate.textContent = '\u00DAltima actualizaci\u00F3n: ' + now.toLocaleTimeString();
    }

    // --- Init ---
    initDom();

    el.basicBtn.addEventListener('click', function() { setMode('basic'); });
    el.advancedBtn.addEventListener('click', function() { setMode('advanced'); });

    var savedMode = getCookie('status_mode');
    setMode(savedMode === 'basic' || savedMode === 'advanced' ? savedMode : 'basic');
})();