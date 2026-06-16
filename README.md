# REDesNat Status

> **Routers para Emergencias y Desastres Naturales** — Panel de monitoreo en tiempo real para routers OpenWrt.

Interfaz web liviana que muestra el estado en vivo de un router OpenWrt, diseñada especialmente para despliegues de emergencia. Consume recursos mínimos y funciona sin frameworks externos.

## Capturas

| Vista Básica | Vista Avanzada |
|---|---|
| Información esencial: carga del sistema, bandas WiFi por radio, clientes conectados y tráfico total. | Datos detallados por interfaz (WiFi type, canal, ancho de banda, cifrado, SNR), leases DHCP completos, estado SQM y tabla de estaciones. |

## Arquitectura

```
├── www/
│   ├── cgi-bin/
│   │   └── status.cgi          # CGI en shell → JSON endpoint
│   └── status/
│       ├── index.html           # Página principal
│       ├── css/
│       │   └── style.css        # Estilos responsivos
│       └── js/
│           └── app.js           # Aplicación frontend (Vanilla JS)
├── utils/
│   └── wifi-suite.sh            # Script avanzado de diagnóstico WiFi
├── deploy.sh                    # Despliegue incremental por SSH
├── build-embed.sh               # Build: minificación + empaquetado
└── README.md
```

## Requisitos

- Router con **OpenWrt** (21.02 o superior)
- Paquetes: `uhttpd`, `ubus`, `iwinfo` (o `iw`), `hostapd` (con `hostapd-cli`)
- **SQM** (opcional): `sqm-scripts` para mostrar estado de colas
- Python 3 (opcional, para build local)

## Instalación

### Opción 1: Despliegue por SSH (recomendado)

```bash
./deploy.sh -i 192.168.1.1
```

El script copia solo los archivos modificados (verifica checksums MD5) y crea los directorios necesarios automáticamente.

### Opción 2: Build + empaquetado para uci-defaults

```bash
./build-embed.sh
```

Genera `dist/embed.sh`: un script autónomo que minifica, comprime (gzip) y codifica (base64) todos los assets. Copia este archivo al router como `/etc/uci-defaults/99-status-page` y se ejecutará automáticamente en el próximo reinicio.

```
scp dist/embed.sh root@192.168.1.1:/etc/uci-defaults/99-status-page
ssh root@192.168.1.1 sh /etc/uci-defaults/99-status-page
```

### Opción 3: Manual

```bash
# Copiar archivos al router
scp www/cgi-bin/status.cgi      root@192.168.1.1:/www/cgi-bin/
scp www/status/index.html       root@192.168.1.1:/www/status/
scp www/status/css/style.css    root@192.168.1.1:/www/status/css/
scp www/status/js/app.js        root@192.168.1.1:/www/status/js/
scp utils/wifi-suite.sh         root@192.168.1.1:/www/cgi-bin/

# Dar permisos de ejecución
ssh root@192.168.1.1 chmod +x /www/cgi-bin/status.cgi /www/cgi-bin/wifi-suite.sh
```

## Uso

Abrir en el navegador: `http://<ip-del-router>/status/`

### Modos de visualización

| Modo | Intervalo | Descripción |
|---|---|---|
| **Básico** | 30 s | Vista consolidada por radio: SSID, banda, clientes conectados y tráfico total RX/TX. Ideal para monitoreo rápido. |
| **Avanzado** | 10 s | Datos completos por interfaz, leases DHCP con MAC y expiración, estado SQM, tabla de estaciones vía `wifi-suite.sh`. |

El modo seleccionado se persiste en una cookie (`status_mode`).

### Datos mostrados

- **Router**: modelo del dispositivo
- **Tiempo activo**: uptime del sistema
- **Carga del sistema**: promedio 1 / 5 / 15 minutos
- **Interfaces WiFi por radio**:
  - SSID, banda (2.4 / 5 / 6 GHz)
  - Tipo WiFi (Wi‑Fi 4/5/6/7)
  - Canal y frecuencia
  - Ancho de banda (20/40/80/160/320 MHz)
  - Bitrate, modo, cifrado
  - Señal / Ruido (dBm)
  - Clientes conectados y capacidad
  - Tráfico RX/TX por interfaz
- **Clientes DHCP**: hostname, IP, MAC, tiempo restante de concesión
- **SQM**: estado (habilitado / deshabilitado) por interfaz, velocidades, disciplina de cola
- **Tráfico total**: RX, TX y total acumulado en GB

## Personalización

Para cambiar el intervalo de actualización, modificar `resetCountdown()` en `app.js`:

```js
// Modo básico: 30 s / Modo avanzado: 10 s
secondsUntilRefresh = (currentMode === 'basic') ? 30 : 10;
```

## Licencia

Este proyecto se distribuye bajo licencia **MIT**.
