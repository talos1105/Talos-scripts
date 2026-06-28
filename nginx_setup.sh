#!/bin/bash
# =============================================================================
# nginx_setup.sh — NGINX Setup & Management Script
# Version: 1.0
# =============================================================================
set -euo pipefail

# =============================================================================
# COLORS
# =============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

# =============================================================================
# PACKAGE MANAGER
# =============================================================================
if   command -v dnf > /dev/null 2>&1; then PKG_MGR="dnf"
elif command -v yum > /dev/null 2>&1; then PKG_MGR="yum"
else                                        PKG_MGR=""
fi
NGINX_REPO_BASE="http://nginx.org/packages/mainline/rhel/8/x86_64/RPMS"

pkg_install() {
    if [[ -z "$PKG_MGR" ]]; then
        log_error "No package manager found (dnf or yum required)"
        return 1
    fi
    $PKG_MGR install -y "$@"
}

# =============================================================================
# SYSTEMD HELPER
# =============================================================================
_has_systemd() {
    pidof systemd > /dev/null 2>&1 || [[ "$(cat /proc/1/comm 2>/dev/null)" == "systemd" ]]
}

_systemctl() {
    if _has_systemd; then
        systemctl "$@" 2>/dev/null || true
    else
        log_warn "systemd not available — skipping: systemctl $*"
    fi
}

# =============================================================================
# CONSTANTS
# =============================================================================
NGINX_BIN="/usr/sbin/nginx"
NGINX_INST_BASE="/opt/nginx"
NGINX_LOG_BASE="/appvol/logs/nginx"
NGINX_CACHE="/var/cache/nginx"
NGINX_LIB="/var/lib/nginx"
SSL_CERTS="/etc/ssl/certs"
SSL_PRIVATE="/etc/ssl/private"

NGINX_USER="nxadm"
NGINX_GROUP="nxgrp"
LOG_GROUP="loggrp"
NGINX_UID=200030066
NGINX_GID=400013162
LOG_GID=400000002

# =============================================================================
# LOGGING
# =============================================================================
log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_done()    { echo -e "${GREEN}  ✔${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_section() {
    echo ""
    echo -e "${BOLD}══════════════════════════════════════${NC}"
    echo -e "${BOLD}  $*${NC}"
    echo -e "${BOLD}══════════════════════════════════════${NC}"
}

# =============================================================================
# INPUT HELPERS
# =============================================================================
ask() {
    local var="$1" prompt="$2" default="${3:-}"
    if [[ -n "$default" ]]; then
        read -rp "$(echo -e "  ${BOLD}▶${NC} ${prompt}[${default}]: ")" val
        printf -v "$var" '%s' "${val:-$default}"
    else
        read -rp "$(echo -e "  ${BOLD}▶${NC} ${prompt}: ")" val
        printf -v "$var" '%s' "$val"
    fi
}

ask_required() {
    local var="$1" prompt="$2" val
    while true; do
        read -rp "$(echo -e "  ${BOLD}▶${NC} ${prompt}: ")" val
        if [[ -n "$val" ]]; then
            printf -v "$var" '%s' "$val"
            break
        fi
        log_warn "This field is required."
    done
}

ask_yn() {
    local var="$1" prompt="$2" default="${3:-y}"
    ask "$var" "$prompt (y/n) " "$default"
    [[ "${!var}" =~ ^[Yy]$ ]] && printf -v "$var" 'y' || printf -v "$var" 'n'
}

check_root() {
    [[ "$EUID" -eq 0 ]] || { log_error "Must run as root: sudo $0"; exit 1; }
}

# =============================================================================
# BASE SETUP (shared by install options)
# =============================================================================
_setup_base() {
    log_info "Creating groups and user..."
    if ! getent group "$LOG_GROUP" > /dev/null 2>&1; then
        groupadd -g "$LOG_GID" "$LOG_GROUP" && log_done "Group $LOG_GROUP created (GID=$LOG_GID)"
    else
        log_warn "Group $LOG_GROUP already exists — skipping"
    fi

    if ! getent group "$NGINX_GROUP" > /dev/null 2>&1; then
        groupadd -g "$NGINX_GID" "$NGINX_GROUP" && log_done "Group $NGINX_GROUP created (GID=$NGINX_GID)"
    else
        log_warn "Group $NGINX_GROUP already exists — skipping"
    fi

    if ! id "$NGINX_USER" > /dev/null 2>&1; then
        useradd -d /home/"$NGINX_USER" -s /bin/bash \
            -g "$NGINX_GROUP" -G "$LOG_GROUP" -u "$NGINX_UID" "$NGINX_USER" \
            && log_done "User $NGINX_USER created (UID=$NGINX_UID)"
    else
        log_warn "User $NGINX_USER already exists — skipping"
    fi

    log_info "Setting kernel.pid_max..."
    if ! grep -q "kernel.pid_max" /etc/sysctl.conf 2>/dev/null; then
        echo "kernel.pid_max=4194303" >> /etc/sysctl.conf
        sysctl -p > /dev/null 2>&1 || true
        log_done "kernel.pid_max=4194303 set"
    else
        log_warn "kernel.pid_max already set — skipping"
    fi

    log_info "Installing SELinux tools..."
    pkg_install policycoreutils-python-utils > /dev/null 2>&1 \
        && log_done "policycoreutils-python-utils installed" \
        || log_warn "Could not install policycoreutils-python-utils"

    log_info "Creating directories..."
    mkdir -p /appvol && chown root:root /appvol && chmod 755 /appvol
    mkdir -p "$NGINX_LOG_BASE"
    chown -R "$NGINX_USER":"$LOG_GROUP" /appvol/logs && chmod -R 2755 /appvol/logs
    mkdir -p "$NGINX_CACHE" && chown -R "$NGINX_USER":"$NGINX_GROUP" "$NGINX_CACHE" && chmod 750 "$NGINX_CACHE"
    mkdir -p "$NGINX_LIB"   && chown -R "$NGINX_USER":"$NGINX_GROUP" "$NGINX_LIB"   && chmod 750 "$NGINX_LIB"
    chmod 750 /var/log/nginx 2>/dev/null || true
    chown -R "$NGINX_USER":"$LOG_GROUP" /var/log/nginx 2>/dev/null || true
    mkdir -p "$NGINX_INST_BASE"
    log_done "Directories created"
}

# =============================================================================
# 1a. INSTALL — RHSCL
# =============================================================================
do_install_rhscl() {
    check_root
    log_section "Install NGINX via RHSCL"
    log_warn "Requires a valid Red Hat subscription and pool ID."
    log_warn "Not available on Oracle Linux / CentOS / Rocky Linux."
    echo ""

    _setup_base

    log_info "Attaching Red Hat subscription..."
    ask_yn ALREADY_ATTACHED "Already attached to a subscription?" "n"

    if [[ "$ALREADY_ATTACHED" != "y" ]]; then
        ask_required POOL_ID "Red Hat subscription pool ID"
        subscription-manager attach --pool="$POOL_ID" \
            && log_done "Subscription attached" \
            || { log_error "Failed to attach subscription"; return 1; }
    fi

    subscription-manager repos --enable rhel-server-rhscl-8-rpms \
        && log_done "RHSCL repository enabled" \
        || { log_error "Failed to enable RHSCL repository"; return 1; }

    pkg_install rh-nginx118 \
        && log_done "rh-nginx118 installed" \
        || { log_error "NGINX install failed"; return 1; }

    log_section "NGINX installed successfully"
    log_info "Next step: Create an instance"
}

# =============================================================================
# 1b. INSTALL — Manual RPM (nginx.org)
# =============================================================================
do_install_manual() {
    check_root
    log_section "Install NGINX via Manual RPM"

    _setup_base

    # Check curl
    if ! command -v curl > /dev/null 2>&1; then
        log_warn "curl not found — installing..."
        pkg_install curl > /dev/null 2>&1 \
            && log_done "curl installed" \
            || { log_error "curl required but could not be installed"; return 1; }
    fi

    log_info "Fetching available NGINX versions from nginx.org..."
    local rpm_list=""
    rpm_list=$(curl -s --max-time 10 "${NGINX_REPO_BASE}/" \
        | grep -oP 'nginx-[\d.]+-[\d]+\.el[\d]+\.ngx\.x86_64\.rpm' \
        | sort -V | uniq || true)

    [[ -z "$rpm_list" ]] && {
        log_error "Could not fetch version list from nginx.org"
        log_error "Check: curl is installed and nginx.org is reachable"
        return 1
    }

    local recent_list versions=() i=1
    recent_list=$(echo "$rpm_list" | tail -5)

    echo ""
    echo -e "  ${BOLD}Recent versions (latest 5):${NC}"
    while IFS= read -r rpm; do
        local ver
        ver=$(echo "$rpm" | grep -oP 'nginx-[\d.]+' | head -1 | sed 's/nginx-//')
        echo "    $i. $ver  ($rpm)"
        versions+=("$rpm")
        (( i++ ))
    done <<< "$recent_list"

    local latest="${versions[-1]}"
    echo ""
    echo    "  # All versions: ${NGINX_REPO_BASE}/"
    echo    "  Press Enter for latest (${latest}) or enter number"
    ask VERSION_INPUT "Select option" ""

    local selected_rpm
    if   [[ -z "$VERSION_INPUT" ]];                    then selected_rpm="$latest"
    elif [[ "$VERSION_INPUT" =~ ^[0-9]+$ ]];           then selected_rpm="${versions[$(( VERSION_INPUT - 1 ))]}"
    else                                                     selected_rpm="$VERSION_INPUT"
    fi

    local tmp_rpm="/tmp/${selected_rpm}"
    log_info "Downloading: ${NGINX_REPO_BASE}/${selected_rpm}"
    curl -# -L --max-time 120 -o "$tmp_rpm" "${NGINX_REPO_BASE}/${selected_rpm}" \
        && log_done "Downloaded: $tmp_rpm" \
        || { log_error "Download failed"; return 1; }

    log_info "Installing: $selected_rpm"
    $PKG_MGR install -y "$tmp_rpm" \
        && log_done "NGINX installed: $selected_rpm" \
        || { rm -f "$tmp_rpm"; log_error "NGINX install failed"; return 1; }

    rm -f "$tmp_rpm" && log_done "Temp file cleaned up"

    log_section "NGINX installed successfully"
    log_info "Next step: Create an instance"
}

# =============================================================================
# SSL — Generate self-signed
# =============================================================================
_generate_ssl() {
    local inst_name="$1"
    log_section "Generate Self-Signed SSL Certificate"

    # Check openssl
    if ! command -v openssl > /dev/null 2>&1; then
        log_info "openssl not found — installing..."
        pkg_install openssl \
            && log_done "openssl installed" \
            || { log_error "openssl required but could not be installed"; return 1; }
    fi

    # Auto-detect from OS
    local default_c="" default_l=""
    local lang_var=""
    lang_var=$(locale 2>/dev/null | grep "^LANG=" | head -1 | cut -d= -f2 \
        || cat /etc/default/locale 2>/dev/null | grep "^LANG=" | head -1 | cut -d= -f2 \
        || true)
    [[ -n "$lang_var" ]] && default_c=$(echo "$lang_var" | grep -oP '(?<=_)[A-Z]{2}' | head -1 || true)

    local tz=""
    tz=$(cat /etc/timezone 2>/dev/null \
        || timedatectl 2>/dev/null | grep "Time zone" | awk '{print $3}' \
        || true)
    [[ -n "$tz" ]] && default_l=$(echo "$tz" | cut -d/ -f2 | tr '_' ' ' || true)

    echo ""
    echo -e "${BOLD}  [ Certificate Details ]${NC}"
    echo    "  # Country must be 2-letter ISO code (e.g. VN, US, SG)"
    while true; do
        ask SSL_C "Country (C)              " "${default_c}"
        if [[ ${#SSL_C} -eq 2 ]]; then
            SSL_C="${SSL_C^^}"
            break
        fi
        log_warn "Country must be exactly 2 characters (e.g. VN, US)"
    done
    ask SSL_ST   "State (ST)               " ""
    ask SSL_L    "City (L)                 " "${default_l}"
    ask SSL_O    "Organization (O)         " ""
    ask SSL_OU   "Unit (OU)                " ""
    ask SSL_CN   "Common Name (e.g. your-hostname) " ""
    ask SSL_DAYS "Validity (days)          " "3650"

    echo ""
    echo -e "${BOLD}  [ Subject Alternative Names ]${NC}"
    echo    "  Enter DNS names one per line. Empty line to finish."
    local dns_list=() i=1
    while true; do
        local dns_entry
        read -rp "$(echo -e "  ${BOLD}▶${NC} DNS.$i: ")" dns_entry
        [[ -z "$dns_entry" ]] && break
        dns_list+=("DNS.$i=$dns_entry")
        (( i++ ))
    done
    [[ ${#dns_list[@]} -eq 0 ]] && dns_list=("DNS.1=${SSL_CN}")

    local conf_file="${SSL_PRIVATE}/san_${inst_name}.conf"
    local key_file="${SSL_PRIVATE}/${inst_name}.key"
    local csr_file="${SSL_CERTS}/${inst_name}.csr"
    local crt_file="${SSL_CERTS}/${inst_name}.crt"
    local dhp_file="${SSL_CERTS}/dhparam.pem"

    mkdir -p "$SSL_PRIVATE" "$SSL_CERTS"

    cat > "$conf_file" << EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
req_extensions = req_ext
distinguished_name = dn

[dn]
C = ${SSL_C}
ST = ${SSL_ST}
L = ${SSL_L}
O = ${SSL_O}
OU = ${SSL_OU}
CN = ${SSL_CN}

[req_ext]
subjectAltName = @alt_names

[alt_names]
$(printf '%s\n' "${dns_list[@]}")
EOF

    if [[ ! -f "$dhp_file" ]]; then
        log_info "Generating DH params (2048-bit) — this may take a moment..."
        openssl dhparam -out "$dhp_file" 2048 \
            && log_done "dhparam.pem generated" \
            || { log_error "Failed to generate DH params"; return 1; }
    else
        log_warn "dhparam.pem already exists — skipping"
    fi

    log_info "Generating key and CSR..."
    openssl req -newkey rsa:2048 -nodes \
        -keyout "$key_file" -out "$csr_file" -config "$conf_file" \
        && log_done "Key and CSR generated" \
        || { log_error "Failed to generate key and CSR"; return 1; }

    [[ -f "$key_file" ]] || { log_error "Key file not created: $key_file"; return 1; }
    [[ -f "$csr_file" ]] || { log_error "CSR file not created: $csr_file"; return 1; }

    log_info "Signing certificate..."
    openssl x509 -signkey "$key_file" -in "$csr_file" \
        -req -days "$SSL_DAYS" -out "$crt_file" \
        && log_done "Certificate signed (valid ${SSL_DAYS} days)" \
        || { log_error "Failed to sign certificate"; return 1; }

    [[ -f "$crt_file" ]] || { log_error "Certificate file not created: $crt_file"; return 1; }

    chown -R "$NGINX_USER":"$NGINX_GROUP" "$SSL_PRIVATE" 2>/dev/null || true
    chown "$NGINX_USER":"$NGINX_GROUP" "$crt_file" 2>/dev/null || true
    chmod 600 "$key_file"
    chmod 644 "$crt_file"

    log_info "Verifying certificate matches key..."
    local crt_md5 key_md5
    crt_md5=$(openssl x509 -noout -modulus -in "$crt_file" | openssl md5)
    key_md5=$(openssl rsa  -noout -modulus -in "$key_file" | openssl md5)
    [[ "$crt_md5" == "$key_md5" ]] \
        && log_done "Certificate and key match ✔" \
        || { log_error "Certificate and key do NOT match!"; return 1; }

    SSL_CRT="$crt_file"
    SSL_KEY="$key_file"
    SSL_DHP="$dhp_file"
}

# =============================================================================
# SSL — Use existing certificate
# =============================================================================
_use_existing_ssl() {
    log_section "Use Existing SSL Certificate"
    echo ""
    ask_required SSL_CRT "Path to .crt file"
    ask_required SSL_KEY "Path to .key file"
    ask SSL_DHP "Path to dhparam.pem (optional)" "${SSL_CERTS}/dhparam.pem"

    [[ -f "$SSL_CRT" ]] || { log_error "CRT file not found: $SSL_CRT"; return 1; }
    [[ -f "$SSL_KEY" ]] || { log_error "KEY file not found: $SSL_KEY"; return 1; }

    local crt_md5 key_md5
    crt_md5=$(openssl x509 -noout -modulus -in "$SSL_CRT" | openssl md5)
    key_md5=$(openssl rsa  -noout -modulus -in "$SSL_KEY" | openssl md5)
    [[ "$crt_md5" == "$key_md5" ]] \
        && log_done "Certificate and key match ✔" \
        || { log_error "Certificate and key do NOT match!"; return 1; }

    if [[ ! -f "$SSL_DHP" ]]; then
        log_info "Generating DH params..."
        openssl dhparam -out "$SSL_DHP" 2048 \
            && log_done "dhparam.pem generated" \
            || { log_error "Failed to generate DH params"; return 1; }
    fi
}

# =============================================================================
# 3. CREATE INSTANCE
# =============================================================================
do_create_instance() {
    check_root
    log_section "Create NGINX Instance"

    [[ -x "$NGINX_BIN" ]] || { log_error "NGINX not installed. Run Install first (option 1 or 2)."; return 1; }

    echo ""
    echo -e "${BOLD}  [ Instance Configuration ]${NC}"
    ask_required INST_NAME   "Instance name     (e.g. APP01-WS)   "
    ask_required LISTEN_PORT "NGINX listen port (e.g. 8080)       "

    echo ""
    ask_yn ENABLE_SSL "Enable SSL/HTTPS for this instance?" "y"

    local SSL_CRT="" SSL_KEY="" SSL_DHP="" USE_SSL=false
    if [[ "$ENABLE_SSL" == "y" ]]; then
        USE_SSL=true
        echo ""
        echo    "  1. Generate self-signed certificate"
        echo    "  2. Use existing certificate files"
        ask SSL_OPT "Select option" "1"
        [[ "$SSL_OPT" == "1" ]] && _generate_ssl "$INST_NAME" || _use_existing_ssl
    fi

    # SELinux
    log_info "Adding port $LISTEN_PORT to SELinux http_port_t..."
    semanage port -a -t http_port_t -p tcp "$LISTEN_PORT" 2>/dev/null \
        && log_done "SELinux: port $LISTEN_PORT allowed" \
        || log_warn "SELinux port already registered or semanage failed"

    # Firewall
    log_info "Opening firewall port $LISTEN_PORT..."
    firewall-cmd --zone=public --add-port="${LISTEN_PORT}/tcp" --permanent 2>/dev/null \
        && firewall-cmd --reload 2>/dev/null \
        && log_done "Firewall: port $LISTEN_PORT opened" \
        || log_warn "firewall-cmd failed — check manually"

    # Directories
    local inst_dir="${NGINX_INST_BASE}/${INST_NAME}"
    local log_dir="${NGINX_LOG_BASE}/${INST_NAME}"
    log_info "Creating instance directories..."
    mkdir -p "${inst_dir}/conf.d" "$log_dir"
    chown -R "$NGINX_USER":"$NGINX_GROUP" "$inst_dir"
    chown -R "$NGINX_USER":"$LOG_GROUP"   "$log_dir"
    log_done "Directories created"

    # nginx.conf
    local proto="http"
    $USE_SSL && proto="https"

    log_info "Creating nginx.conf for $INST_NAME..."
    cat > "${inst_dir}/nginx.conf" << EOF
worker_processes  1;

error_log ${log_dir}/error.log warn;
pid       /run/nginx/${INST_NAME}.pid;

events {
    worker_connections  1024;
}

http {
    tcp_nopush  on;
    tcp_nodelay on;
    server_tokens off;

    include      /etc/nginx/mime.types;
    default_type application/octet-stream;

    add_header X-Content-Type-Options nosniff;
    add_header Strict-Transport-Security "max-age=16070400; includeSubDomains; preload";
    add_header X-Frame-Options SAMEORIGIN;

    client_body_timeout   10;
    client_header_timeout 10;
    keepalive_timeout     5 5;
    send_timeout          10;

    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent" "\$http_x_forwarded_for"';
    access_log ${log_dir}/access.log main;

    include ${inst_dir}/conf.d/*.conf;

    server {
        listen ${LISTEN_PORT}$(${USE_SSL} && echo ' ssl default_server' || echo '');
        server_name ${INST_NAME};

        if (\$request_method !~ ^(GET|POST|OPTIONS)\$) {
            return 405;
        }

        gzip off;

$(if $USE_SSL; then cat << SSLEOF
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_prefer_server_ciphers on;
        ssl_session_timeout 30m;
        ssl_session_tickets off;
        ssl_session_cache shared:SSL:10m;
        ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
        ssl_certificate     ${SSL_CRT};
        ssl_certificate_key ${SSL_KEY};
        ssl_dhparam         ${SSL_DHP};
SSLEOF
fi)

        proxy_redirect off;
        proxy_set_header X-Real-IP        \$remote_addr;
        proxy_set_header X-Forwarded-For  \$proxy_add_x_forwarded_for;
        proxy_set_header Host             \$http_host;

        location / {
            # TODO: configure service — use option "Config Instance > Proxy"
            # proxy_pass http://localhost:8443/;
        }
    }
}
EOF
    chown "$NGINX_USER":"$NGINX_GROUP" "${inst_dir}/nginx.conf"
    log_done "nginx.conf created"

    # Test config
    log_info "Testing NGINX configuration..."
    mkdir -p /run/nginx
    "$NGINX_BIN" -c "${inst_dir}/nginx.conf" -t \
        && log_done "Configuration test passed" \
        || { log_error "Configuration test failed"; return 1; }

    # Systemd service
    log_info "Creating systemd service: ${INST_NAME}.service..."
    cat > "/etc/systemd/system/${INST_NAME}.service" << EOF
[Unit]
Description=nginx — ${INST_NAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
User=${NGINX_USER}
Group=${NGINX_GROUP}
SupplementaryGroups=${LOG_GROUP}
RuntimeDirectory=nginx
PIDFile=/run/nginx/${INST_NAME}.pid
ExecStart=${NGINX_BIN} -c ${inst_dir}/nginx.conf
ExecReload=/bin/sh -c "/bin/kill -s HUP \$(/bin/cat /run/nginx/${INST_NAME}.pid)"
ExecStop=/bin/sh -c "/bin/kill -s TERM \$(/bin/cat /run/nginx/${INST_NAME}.pid)"
Restart=on-failure
RestartSec=30s
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    _systemctl daemon-reload
    _systemctl enable "${INST_NAME}.service"
    log_done "Service ${INST_NAME} created"

    # Log rotation
    log_info "Setting up log rotation..."
    pkg_install logrotate > /dev/null 2>&1 || true
    cat > "/etc/logrotate.d/${INST_NAME}_log.conf" << EOF
${log_dir}/* {
    daily
    missingok
    create 0640 ${NGINX_USER} ${LOG_GROUP}
    rotate 30
    size 100M
    dateext
    postrotate
        if [ -f /run/nginx/${INST_NAME}.pid ]; then
            kill -USR1 \$(cat /run/nginx/${INST_NAME}.pid)
        fi
    endscript
}
EOF
    log_done "Log rotation configured"

    # Summary
    local db_host
    db_host=$(cat /etc/hostname 2>/dev/null | tr -d ' \n\r' || echo "localhost")

    log_section "Instance ${INST_NAME} created successfully"
    echo -e "  ${BOLD}[ Access URLs ]${NC}"
    echo    "  Inside server  : ${proto}://localhost:${LISTEN_PORT}"
    echo    "  Docker host    : ${proto}://host.docker.internal:${LISTEN_PORT}"
    echo    "  Hostname       : ${proto}://${db_host}:${LISTEN_PORT}"
    echo ""
    echo -e "  ${BOLD}[ Files ]${NC}"
    echo    "  Config : ${inst_dir}/nginx.conf"
    echo    "  Logs   : ${log_dir}/"
    $USE_SSL && echo "  Cert   : ${SSL_CRT}"
    $USE_SSL && echo "  Key    : ${SSL_KEY}"
}

# =============================================================================
# 4. CONFIG INSTANCE
# =============================================================================
_select_instance() {
    if [[ ! -d "$NGINX_INST_BASE" ]] || [[ -z "$(ls -A "$NGINX_INST_BASE" 2>/dev/null)" ]]; then
        log_error "No instances found in $NGINX_INST_BASE"
        return 1
    fi
    log_info "Available instances:"
    ls "$NGINX_INST_BASE" | while read -r inst; do echo "  - $inst"; done
    echo ""
    ask_required INST_NAME "Instance name"
    INST_DIR="${NGINX_INST_BASE}/${INST_NAME}"
    INST_CONF="${INST_DIR}/nginx.conf"
    [[ -f "$INST_CONF" ]] || { log_error "Config not found: $INST_CONF"; return 1; }

    local port server_name proxy_pass ssl_status
    port=$(grep        "listen "        "$INST_CONF" | grep -v "#" | awk '{print $2}' | grep -oP '^\d+' | head -1 || true)
    server_name=$(grep "server_name"   "$INST_CONF" | grep -v "#" | awk '{print $2}' | tr -d ';'       | head -1 || true)
    proxy_pass=$(grep  "proxy_pass"    "$INST_CONF" | grep -v "#" | awk '{print $2}' | tr -d ';'       | head -1 || true)
    grep -q "ssl_certificate" "$INST_CONF" && ssl_status="enabled" || ssl_status="disabled"

    echo ""
    echo -e "  ${BOLD}[ ${INST_NAME} ]${NC}"
    echo    "  Config       : $INST_CONF"
    echo    "  Listen port  : ${port:-—}"
    echo    "  Server name  : ${server_name:-—}"
    echo    "  SSL          : $ssl_status"
    echo    "  Proxy pass   : ${proxy_pass:-not configured}"
    echo ""
}

_reload_instance() {
    log_info "Testing configuration..."
    mkdir -p /run/nginx
    if "$NGINX_BIN" -c "$INST_CONF" -t 2>/dev/null; then
        log_done "Configuration test passed"
        _systemctl reload "${INST_NAME}.service" \
            || _systemctl restart "${INST_NAME}.service" \
            || true
        log_done "Service reloaded"
    else
        log_error "Configuration test failed — restoring backup"
        cp "${INST_CONF}.bak" "$INST_CONF" 2>/dev/null || true
        return 1
    fi
}

_config_ssl() {
    log_section "Config SSL — ${INST_NAME}"
    cp "$INST_CONF" "${INST_CONF}.bak"

    local has_ssl=false
    grep -q "ssl_certificate" "$INST_CONF" && has_ssl=true

    if $has_ssl; then
        echo ""
        echo -e "  ${BOLD}SSL is currently enabled.${NC}"
        echo    "  1. Update certificate"
        echo    "  2. Disable SSL"
        ask SSL_ACTION "Select option" "1"

        if [[ "$SSL_ACTION" == "2" ]]; then
            sed -i 's/listen \(.*\) ssl.*/listen \1;/' "$INST_CONF"
            sed -i '/ssl_/d' "$INST_CONF"
            log_done "SSL disabled"
        else
            echo ""
            echo "  1. Generate new self-signed certificate"
            echo "  2. Use existing certificate files"
            ask SSL_OPT "Select option" "1"
            [[ "$SSL_OPT" == "1" ]] && _generate_ssl "$INST_NAME" || _use_existing_ssl
            sed -i "s|ssl_certificate .*|ssl_certificate     ${SSL_CRT};|"     "$INST_CONF"
            sed -i "s|ssl_certificate_key .*|ssl_certificate_key ${SSL_KEY};|" "$INST_CONF"
            sed -i "s|ssl_dhparam .*|ssl_dhparam         ${SSL_DHP};|"         "$INST_CONF"
            log_done "Certificate updated"
        fi
    else
        echo ""
        echo -e "  ${BOLD}SSL is currently disabled.${NC}"
        echo    "  1. Generate new self-signed certificate"
        echo    "  2. Use existing certificate files"
        ask SSL_OPT "Select option" "1"
        [[ "$SSL_OPT" == "1" ]] && _generate_ssl "$INST_NAME" || _use_existing_ssl

        sed -i 's/listen \([0-9]*\);/listen \1 ssl default_server;/' "$INST_CONF"
        sed -i "/proxy_redirect off/i\\
        ssl_protocols TLSv1.2 TLSv1.3;\\
        ssl_prefer_server_ciphers on;\\
        ssl_session_timeout 30m;\\
        ssl_session_tickets off;\\
        ssl_session_cache shared:SSL:10m;\\
        ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;\\
        ssl_certificate     ${SSL_CRT};\\
        ssl_certificate_key ${SSL_KEY};\\
        ssl_dhparam         ${SSL_DHP};\\
" "$INST_CONF"
        log_done "SSL enabled"
    fi
    _reload_instance
}

_config_hostname() {
    log_section "Config Hostname — ${INST_NAME}"
    cp "$INST_CONF" "${INST_CONF}.bak"

    local current
    current=$(grep "server_name" "$INST_CONF" | awk '{print $2}' | tr -d ';' || true)
    log_info "Current server_name: $current"

    ask_required NEW_HOSTNAME "New server_name (domain or hostname)"
    sed -i "s/server_name .*/server_name ${NEW_HOSTNAME};/" "$INST_CONF"
    log_done "server_name updated to: $NEW_HOSTNAME"
    _reload_instance
}

_config_proxy() {
    log_section "Config Proxy — ${INST_NAME}"
    cp "$INST_CONF" "${INST_CONF}.bak"

    local current
    current=$(grep "proxy_pass" "$INST_CONF" | grep -v "#" | awk '{print $2}' | tr -d ';' || true)
    [[ -n "$current" ]] && log_info "Current proxy_pass: $current"

    echo ""
    echo -e "  ${BOLD}[ Service Configuration ]${NC}"
    ask      SVC_PROTO "Service protocol (e.g. http)       " "http"
    ask_required SVC_HOST  "Service host     (e.g. localhost)  "
    ask_required SVC_PORT  "Service port     (e.g. 8443)       "

    local proxy_pass="${SVC_PROTO}://${SVC_HOST}:${SVC_PORT}/"

    if grep -q "proxy_pass" "$INST_CONF" 2>/dev/null; then
        sed -i "s|proxy_pass .*;|proxy_pass ${proxy_pass};|"     "$INST_CONF"
        sed -i "s|# proxy_pass .*;|proxy_pass ${proxy_pass};|"   "$INST_CONF"
    else
        sed -i "s|# TODO.*||" "$INST_CONF"
        sed -i "/location \/ {/a\\            proxy_pass ${proxy_pass};" "$INST_CONF"
    fi
    log_done "proxy_pass set to: $proxy_pass"
    _reload_instance
}

_config_port() {
    log_section "Config Port — ${INST_NAME}"
    cp "$INST_CONF" "${INST_CONF}.bak"

    local current_port
    current_port=$(grep "listen " "$INST_CONF" | grep -v "#" | awk '{print $2}' | grep -oP '^\d+' || true)
    log_info "Current listen port: $current_port"

    ask_required NEW_PORT "New listen port (e.g. 8081)"

    semanage port -d -t http_port_t -p tcp "$current_port" 2>/dev/null || true
    semanage port -a -t http_port_t -p tcp "$NEW_PORT"     2>/dev/null \
        && log_done "SELinux: port $NEW_PORT allowed" \
        || log_warn "SELinux port update failed"

    firewall-cmd --zone=public --remove-port="${current_port}/tcp" --permanent 2>/dev/null || true
    firewall-cmd --zone=public --add-port="${NEW_PORT}/tcp" --permanent 2>/dev/null \
        && firewall-cmd --reload 2>/dev/null \
        && log_done "Firewall: port $NEW_PORT opened" \
        || log_warn "firewall-cmd failed"

    sed -i "s/listen ${current_port}/listen ${NEW_PORT}/" "$INST_CONF"
    log_done "Listen port updated: $current_port → $NEW_PORT"
    _reload_instance
}

_config_methods() {
    log_section "Config Methods — ${INST_NAME}"
    cp "$INST_CONF" "${INST_CONF}.bak"

    local current
    current=$(grep "request_method" "$INST_CONF" | grep -oP '\(.*\)' || true)
    log_info "Current allowed methods: ${current:-not set}"

    echo ""
    echo    "  1. GET|POST|OPTIONS           (default)"
    echo    "  2. GET|POST|PUT|DELETE|OPTIONS (REST API)"
    echo    "  3. Custom"
    ask METHOD_OPT "Select option" "1"

    local methods
    case "$METHOD_OPT" in
        1) methods="GET|POST|OPTIONS" ;;
        2) methods="GET|POST|PUT|DELETE|OPTIONS" ;;
        3) ask_required methods "Enter methods separated by |" ;;
    esac

    sed -i "s|request_method !~ .*|request_method !~ ^(${methods})\$) {|" "$INST_CONF"
    log_done "Allowed methods updated: $methods"
    _reload_instance
}

do_config_instance() {
    check_root
    log_section "Config Instance"

    _select_instance || return 1

    echo -e "  ${BOLD}What would you like to configure?${NC}"
    echo    "  1. SSL        — enable / update / disable SSL certificate"
    echo    "  2. Hostname   — set server_name (domain)"
    echo    "  3. Proxy      — set service host and port"
    echo    "  4. Port       — change NGINX listen port"
    echo    "  5. Methods    — set allowed HTTP methods"
    echo    "  6. Start      — start instance"
    echo    "  7. Stop       — stop instance"
    echo    "  8. View       — show current nginx.conf"
    echo ""
    ask CONFIG_OPT "Select option" ""

    case "$CONFIG_OPT" in
        1) _config_ssl      ;;
        2) _config_hostname ;;
        3) _config_proxy    ;;
        4) _config_port     ;;
        5) _config_methods  ;;
        6)
            log_info "Starting instance ${INST_NAME}..."
            mkdir -p /run/nginx
            "$NGINX_BIN" -c "$INST_CONF" -t \
                && log_done "Configuration test passed" \
                || { log_error "Configuration test failed"; return 1; }
            if _has_systemd; then
                _systemctl start "${INST_NAME}.service"
            else
                "$NGINX_BIN" -c "$INST_CONF"
            fi
            local port
            port=$(grep "listen " "$INST_CONF" | grep -v "#" | awk '{print $2}' | grep -oP '^\d+' | head -1 || true)
            log_done "Instance ${INST_NAME} started"
            [[ -n "$port" ]] && log_info "Listening on port: $port"
            ;;
        7)
            log_info "Stopping instance ${INST_NAME}..."
            if _has_systemd; then
                _systemctl stop "${INST_NAME}.service"
            else
                local pid_file="/run/nginx/${INST_NAME}.pid"
                if [[ -f "$pid_file" ]]; then
                    kill "$(cat "$pid_file")" 2>/dev/null || true
                    rm -f "$pid_file"
                else
                    "$NGINX_BIN" -c "$INST_CONF" -s stop 2>/dev/null || true
                fi
            fi
            log_done "Instance ${INST_NAME} stopped"
            ;;
        8)
            log_section "Current config — ${INST_NAME}"
            cat "$INST_CONF"
            ;;
        *) log_error "Unknown option: $CONFIG_OPT" ;;
    esac
}

# =============================================================================
# 5. REMOVE INSTANCE
# =============================================================================
do_remove_instance() {
    check_root
    log_section "Remove NGINX Instance"

    if [[ ! -d "$NGINX_INST_BASE" ]] || [[ -z "$(ls -A "$NGINX_INST_BASE" 2>/dev/null)" ]]; then
        log_error "No instances found in $NGINX_INST_BASE"
        return 1
    fi

    log_info "Available instances:"
    ls "$NGINX_INST_BASE" | while read -r inst; do echo "  - $inst"; done
    echo ""
    ask_required INST_NAME "Instance name to remove"

    local inst_dir="${NGINX_INST_BASE}/${INST_NAME}"
    [[ -d "$inst_dir" ]] || { log_error "Instance not found: $inst_dir"; return 1; }

    ask CONFIRM "Confirm removal of instance '$INST_NAME'? (y/n)" "n"
    [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && { log_warn "Cancelled."; return 0; }

    _systemctl stop    "${INST_NAME}.service"
    _systemctl disable "${INST_NAME}.service"
    rm -f "/etc/systemd/system/${INST_NAME}.service"
    _systemctl daemon-reload
    log_done "Service removed"

    rm -f "/etc/logrotate.d/${INST_NAME}_log.conf"
    log_done "Log rotation config removed"

    rm -rf "$inst_dir"
    rm -rf "${NGINX_LOG_BASE}/${INST_NAME}"
    log_done "Instance files removed"

    log_section "Instance ${INST_NAME} removed"
}

# =============================================================================
# 6. UNINSTALL
# =============================================================================
do_uninstall() {
    check_root
    log_section "Uninstall NGINX (Full Clean)"

    echo ""
    log_warn "WARNING — this will permanently remove ALL of the following:"
    echo    "  - NGINX package"
    echo    "  - All instances in $NGINX_INST_BASE"
    echo    "  - All logs in $NGINX_LOG_BASE"
    echo    "  - All systemd services"
    echo    "  - User $NGINX_USER and groups $NGINX_GROUP $LOG_GROUP"
    echo    "  - Directories: /appvol, $NGINX_CACHE, $NGINX_LIB"
    echo ""
    ask CONFIRM "Confirm full uninstall? (y/n)" "n"
    [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && { log_warn "Uninstall cancelled."; return 0; }

    log_info "Stopping and removing all NGINX services..."
    if _has_systemd; then
        for svc in $(systemctl list-units --type=service --all 2>/dev/null | grep -i nginx | awk '{print $1}' || true); do
            _systemctl stop    "$svc"
            _systemctl disable "$svc"
            rm -f "/etc/systemd/system/$svc"
        done
        _systemctl daemon-reload
    fi
    log_done "Services removed"

    log_info "Removing NGINX package..."
    $PKG_MGR remove -y nginx rh-nginx118 2>/dev/null || true
    log_done "NGINX package removed"

    log_info "Removing directories..."
    rm -rf "$NGINX_INST_BASE" /appvol "$NGINX_CACHE" "$NGINX_LIB" /var/log/nginx
    log_done "Directories removed"

    rm -f /etc/logrotate.d/*_log.conf
    log_done "Log rotation configs removed"

    log_info "Removing user and groups..."
    userdel -r "$NGINX_USER" 2>/dev/null || true
    groupdel "$NGINX_GROUP"  2>/dev/null || true
    groupdel "$LOG_GROUP"    2>/dev/null || true
    log_done "User and groups removed"

    log_info "Cleaning kernel.pid_max..."
    sed -i '/kernel.pid_max/d' /etc/sysctl.conf
    sysctl -p > /dev/null 2>&1 || true
    log_done "kernel.pid_max removed"

    log_section "NGINX uninstalled successfully"
}

# =============================================================================
# MAIN MENU
# =============================================================================
main() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════╗${NC}"
    echo -e "${BOLD}║     NGINX Setup Manager v1.0     ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════╝${NC}"

    case "${1:-}" in
        install-rhscl)  do_install_rhscl;    exit $? ;;
        install-manual) do_install_manual;   exit $? ;;
        create)         do_create_instance;  exit $? ;;
        config)         do_config_instance;  exit $? ;;
        remove)         do_remove_instance;  exit $? ;;
        uninstall)      do_uninstall;        exit $? ;;
    esac

    echo ""
    echo -e "  ${BOLD}1.${NC} Install NGINX (RHSCL)    Red Hat subscription — RHEL only"
    echo -e "  ${BOLD}2.${NC} Install NGINX (Manual)   RPM from nginx.org — no subscription needed"
    echo -e "  ${BOLD}3.${NC} Create Instance           New reverse proxy instance with optional SSL"
    echo -e "  ${BOLD}4.${NC} Config Instance           SSL / Hostname / Proxy / Port / Start / Stop"
    echo -e "  ${BOLD}5.${NC} Remove Instance           Remove a specific instance"
    echo -e "  ${BOLD}6.${NC} Uninstall                 Full clean — remove all NGINX files"
    echo ""
    ask CHOICE "Select option" "3"

    case "$CHOICE" in
        1) do_install_rhscl   ;;
        2) do_install_manual  ;;
        3) do_create_instance ;;
        4) do_config_instance ;;
        5) do_remove_instance ;;
        6) do_uninstall       ;;
        *) log_error "Unknown choice: $CHOICE" ;;
    esac
}

main "$@"
