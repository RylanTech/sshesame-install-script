#!/usr/bin/env bash                                                           
set -euo pipefail 

# ==============================================================================
# Configuration Variables (Edit these before running)
# ==============================================================================
BIND_ADDRESS="0.0.0.0"
BIND_PORT="2022"
BANNER=""
LOGFILE="/etc/sshesame/sshesame.log"

# ==============================================================================
# Installation Paths & Service Settings
# ==============================================================================
SSHESAME_USER="sshesame"
BINARY_PATH="/usr/local/bin/sshesame"
CONFIG_DIR="/etc/sshesame"
CONFIG_FILE="${CONFIG_DIR}/sshesame.yaml"
SERVICE_FILE="/etc/systemd/system/sshesame.service"
RELEASE_URL="https://github.com/jaksi/sshesame/releases/latest/download/sshesame-linux-amd64"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Error: This script must be run as root (e.g. sudo $0)." >&2
  exit 1
fi

# Safeguard: abort if OpenSSH (sshd) is already listening on BIND_PORT
if command -v ss >/dev/null 2>&1; then
  if ss -tlpn "sport = :${BIND_PORT}" 2>/dev/null | grep -qE '"sshd"|ssh\.socket'; then
    echo "Error: OpenSSH (sshd) is already listening on port ${BIND_PORT}." >&2
    exit 1
  fi
elif command -v lsof >/dev/null 2>&1; then
  if lsof -nP -iTCP:"${BIND_PORT}" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx 'sshd'; then
    echo "Error: OpenSSH (sshd) is already listening on port ${BIND_PORT}." >&2
    exit 1
  fi
fi

echo "[1/5] Downloading sshesame-linux-amd64 from GitHub releases..."
if command -v curl >/dev/null 2>&1; then
  curl -fsSL -o "${BINARY_PATH}" "${RELEASE_URL}"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "${BINARY_PATH}" "${RELEASE_URL}"
else
  echo "Error: Neither curl nor wget is installed." >&2
  exit 1
fi

chmod +x "${BINARY_PATH}"
chown root:root "${BINARY_PATH}"

echo "[2/5] Creating system user '${SSHESAME_USER}' and directory '${CONFIG_DIR}'..."
if ! id -u "${SSHESAME_USER}" >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin "${SSHESAME_USER}"
fi

mkdir -p "${CONFIG_DIR}"

echo "[3/5] Writing default configuration to '${CONFIG_FILE}'..."
cat <<EOF > "${CONFIG_FILE}"
server:
  listen_address: ${BIND_ADDRESS}:${BIND_PORT}
  # Host private key files.
  # If unspecified, null or empty, an RSA, ECDSA and Ed25519 key will be generated and stored.
  host_keys: null
  # Fake internal services for handling direct-tcpip channels (\`ssh -L\`).
  # If unspecified or null, sensible defaults will be used.
  # If empty, no direct-tcpip channels will be accepted.
  tcpip_services:
    25: SMTP
    80: HTTP
    110: POP3
    587: SMTP
    8080: HTTP

logging:
  # The log file to output activity logs to. Debug and error logs are still written to standard error.
  # If unspecified or null, activity logs are written to standard out.
  file: ${LOGFILE}
  # Make activity logs JSON-formatted instead of human readable.
  json: false
  # Include timestamps in the logs.
  timestamps: true
  # Log full raw details of all global requests, channels and channel requests.
  debug: false
  # Address to export and serve prometheus metrics on.
  # If unspecified or null, metrics are not served.
  metrics_address: null
  # When logging in JSON, log addresses as objects including the hostname and the port instead of strings.
  split_host_port: false

auth:
  # Allow clients to connect without authenticating.
  no_auth: false
  # The maximum number of authentication attempts permitted per connection.
  # If set to a negative number, the number of attempts are unlimited.
  # If unspecified, null or zero, a sensible default is used.
  max_tries: 0
  password_auth:
    # Offer password authentication as an authentication option.
    enabled: true
    # Accept all passwords.
    accepted: true
  public_key_auth:
    # Offer public key authentication as an authentication option.
    enabled: true
    # Accept all public keys.
    accepted: false
  keyboard_interactive_auth:
    # Offer keyboard interactive authentication as an authentication option.
    enabled: false
    # Accept all keyboard interactive answers.
    accepted: false
    # Instruction for the keyboard interactive authentication.
    instruction: Answer these weird questions to log in!
    questions:
      - text: "User: " # Keyboard interactive authentication question text.
        echo: true # Enable echoing the answer.
      - text: "Password: "
        echo: false

ssh_proto:
  # The version identification string to announce in the public handshake.
  # If unspecified or null, a reasonable default is used.
  # Note that RFC 4253 section 4.2 requires that this string start with "SSH-2.0-".
  version: SSH-2.0-sshesame
  # Sent to the client after key exchange completed but before authentication.
  # If unspecified or null, a reasonable default is used.
  # If empty, no banner is sent.
  banner: ${BANNER}
  # The maximum number of bytes sent or received after which a new key is negotiated. It must be at least 256.
  # If unspecified, null or 0, a size suitable for the chosen cipher is used.
  rekey_threshold: 0
  # The allowed key exchanges algorithms.
  # If unspecified or null, a default set of algorithms is used.
  key_exchanges: null
  # The allowed cipher algorithms.
  # If unspecified or null, a sensible default is used.
  ciphers: null
  # The allowed MAC algorithms.
  # If unspecified or null, a sensible default is used.
  macs: null
EOF

chown -R "${SSHESAME_USER}:${SSHESAME_USER}" "${CONFIG_DIR}"
chmod 750 "${CONFIG_DIR}"
chmod 640 "${CONFIG_FILE}"

echo "[4/5] Creating systemd unit file '${SERVICE_FILE}'..."
cat <<EOF > "${SERVICE_FILE}"
[Unit]
Description=sshesame SSH Honeypot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SSHESAME_USER}
Group=${SSHESAME_USER}
ExecStart=${BINARY_PATH} -config ${CONFIG_FILE} -data_dir ${CONFIG_DIR}
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "[5/5] Reloading systemd, enabling, and starting sshesame service..."
systemctl daemon-reload
systemctl enable --now sshesame.service

echo "Done! Check service status with: systemctl status sshesame.service"

