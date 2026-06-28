#!/bin/bash
# =============================================================================
# nginx_setup.sh — NGINX Setup & Management Script
# Reference: IBFT Setup & Deploy Guideline (BO01Y23ISS-GDL-01)
# =============================================================================
set -euo pipefail

# =============================================================================
# COLORS & FORMATTING
# =============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'


# =============================================================================
# SYSTEMD HELPER
# =============================================================================
_has_systemd() {
    pidof systemd > /dev/null 2>&1 || [ "$(cat /proc/1/comm 2>/dev/null)" = "systemd" ]
}

_systemctl() {
    if _has_systemd; then
        _systemctl "$@" 2>/dev/null || true
    else
        log_warn "systemd not available (Docker?) — skipping: _systemctl $*"
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
# 1. INSTALL NGINX
# =============================================================================
_setup_base() {
    # --- Create groups and user ---
    log_info "Creating groups and user..."
    if ! getent group "$LOG_GROUP" > /dev/null 2>&1; then
        groupadd -g "$LOG_GID" "$LOG_GROUP"
        log_done "Group $LOG_GROUP created (GID=$LOG_GID)"
    else
        log_warn "Group $LOG_GROUP already exists — skipping"
    fi

    if ! getent group "$NGINX_GROUP" > /dev/null 2>&1; then
        groupadd -g "$NGINX_GID" "$NGINX_GROUP"
        log_done "Group $NGINX_GROUP created (GID=$NGINX_GID)"
    else
        log_warn "Group $NGINX_GROUP already exists — skipping"
    fi

    if ! id "$NGINX_USER" > /dev/null 2>&1; then
        useradd -d /home/"$NGINX_USER" -s /bin/bash \
            -g "$NGINX_GROUP" -G "$LOG_GROUP" \
            -u "$NGINX_UID" "$NGINX_USER"
        log_done "User $NGINX_USER created (UID=$NGINX_UID)"
    else
        log_warn "User $NGINX_USER already exists — skipping"
    fi

    # --- Kernel parameters ---
    log_info "Setting kernel.pid_max..."
    if ! grep -q "kernel.pid_max" /etc/sysctl.conf; then
        echo "kernel.pid_max=4194303" >> /etc/sysctl.conf
        sysctl -p > /dev/null 2>&1 || true
        log_done "kernel.pid_max=4194303 set"
    else
        log_warn "kernel.pid_max already set — skipping"
    fi

    # --- SELinux tools ---
    log_info "Installing SELinux tools..."
    yum install -y policycoreutils-python-utils > /dev/null 2>&1 \
        && log_done "policycoreutils-python-utils installed" \
        || log_warn "Could not install policycoreutils-python-utils"

    # --- Create directories ---
    log_info "Creating directories..."
    mkdir -p /appvol
    chown -R root:root /appvol
    chmod -R 755 /appvol

    mkdir -p "$NGINX_LOG_BASE"
    chown -R "$NGINX_USER":"$LOG_GROUP" /appvol/logs
    chmod -R 2755 /appvol/logs

    mkdir -p "$NGINX_CACHE"
    chmod -R 750 "$NGINX_CACHE"
    chown -R "$NGINX_USER":"$NGINX_GROUP" "$NGINX_CACHE"

    mkdir -p "$NGINX_LIB"
    chmod -R 750 "$NGINX_LIB"
    chown -R "$NGINX_USER":"$NGINX_GROUP" "$NGINX_LIB"

    chmod -R 750 /var/log/nginx 2>/dev/null || true
    chown -R "$NGINX_USER":"$LOG_GROUP" /var/log/nginx 2>/dev/null || true

    mkdir -p "$NGINX_INST_BASE"
    log_done "Directories created"
}

# =============================================================================
# 1a. INSTALL NGINX — RHSCL (Red Hat subscription)
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

    yum install -y rh-nginx118 \
        && log_done "rh-nginx118 installed" \
        || { log_error "NGINX install failed"; return 1; }

    log_section "NGINX installed successfully"
    log_info "Next step: Create an instance"
}

# =============================================================================
# 1b. INSTALL NGINX — Manual RPM (nginx.org)
# =============================================================================
do_install_manual() {
    check_root
    log_section "Install NGINX via Manual RPM"

    _setup_base

    # --- Fetch available versions ---
    log_info "Fetching available NGINX versions from nginx.org..."
    local rpm_list
    rpm_list=$(curl -s --max-time 10 \
        "http://nginx.org/packages/mainline/rhel/8/x86_64/RPMS/" \
        | grep -oP 'nginx-[\d.]+-[\d]+\.el8\.ngx\.x86_64\.rpm' \
        | sort -V | uniq)

    if [[ -n "$rpm_list" ]]; then
        # Chỉ lấy 5 version mới nhất
        local recent_list
        recent_list=$(echo "$rpm_list" | tail -5)

        echo ""
        echo -e "  ${BOLD}Recent versions (latest 5):${NC}"
        local i=1
        local versions=()
        while IFS= read -r rpm; do
            local ver
            ver=$(echo "$rpm" | grep -oP 'nginx-[\d.]+' | head -1 | sed 's/nginx-//')
            echo "    $i. $ver  ($rpm)"
            versions+=("$rpm")
            (( i++ ))
        done <<< "$recent_list"

        local latest="${versions[-1]}"
        echo ""
        echo    "  # For older versions: http://nginx.org/packages/mainline/rhel/8/x86_64/RPMS/"
        echo    "  Enter number to select, or press Enter for latest (${latest})"
        echo    "  Enter 'c' to input a custom RPM URL or older version"
        ask VERSION_INPUT "Select option" ""

        local selected_rpm
        if [[ -z "$VERSION_INPUT" ]]; then
            selected_rpm="$latest"
        elif [[ "$VERSION_INPUT" == "c" ]]; then
            ask_required selected_rpm "Custom RPM URL or filename"
        elif [[ "$VERSION_INPUT" =~ ^[0-9]+$ ]]; then
            local idx=$(( VERSION_INPUT - 1 ))
            selected_rpm="${versions[$idx]}"
        else
            selected_rpm="$VERSION_INPUT"
        fi
    else
        log_warn "Could not fetch version list from nginx.org"
        echo    "  # Browse all versions: http://nginx.org/packages/mainline/rhel/8/x86_64/RPMS/"
        echo ""
        echo    "  Enter 'c' to input a custom RPM URL, or press Enter for fallback version"
        ask VERSION_INPUT "Select option" ""
        if [[ "$VERSION_INPUT" == "c" ]]; then
            ask_required selected_rpm "Custom RPM URL or filename"
        else
            selected_rpm="nginx-1.25.3-1.el8.ngx.x86_64.rpm"
            log_warn "Using fallback: $selected_rpm"
        fi
    fi

    # --- Install ---
    local rpm_url
    if [[ "$selected_rpm" =~ ^http ]]; then
        rpm_url="$selected_rpm"
    else
        rpm_url="http://nginx.org/packages/mainline/rhel/8/x86_64/RPMS/${selected_rpm}"
    fi

    log_info "Installing: $rpm_url"
    yum install -y "$rpm_url" \
        && log_done "NGINX installed: $selected_rpm" \
        || { log_error "NGINX install failed"; return 1; }

    log_section "NGINX installed successfully"
    log_info "Next step: Create an instance"
}


# =============================================================================
_generate_ssl() {
    local inst_name="$1"
    log_section "Generate Self-Signed SSL Certificate"

    echo ""
    echo -e "${BOLD}  [ Certificate Details ]${NC}"
    ask SSL_C    "Country (C)               " "VN"
    ask SSL_ST   "State (ST)                " "HCMC"
    ask SSL_L    "City (L)                  " "Ho Chi Minh City"
    ask SSL_O    "Organization (O)          " "BANK"
    ask SSL_OU   "Unit (OU)                 " "Software Development Division"
    ask SSL_CN   "Common Name (CN/domain)   " "$(cat /etc/hostname 2>/dev/null | tr -d '\n' || echo 'server.local')"
    ask SSL_DAYS "Validity (days)           " "3650"

    echo ""
    echo -e "${BOLD}  [ Subject Alternative Names (DNS) ]${NC}"
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

    # SAN config
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

    # DH params
    if [[ ! -f "$dhp_file" ]]; then
        log_info "Generating DH params (2048-bit) — this may take a moment..."
        openssl dhparam -out "$dhp_file" 2048 2>/dev/null \
            && log_done "dhparam.pem generated"
    else
        log_warn "dhparam.pem already exists — skipping"
    fi

    # Key + CSR
    log_info "Generating key and CSR..."
    openssl req -newkey rsa:2048 -nodes \
        -keyout "$key_file" \
        -out "$csr_file" \
        -config "$conf_file" 2>/dev/null \
        && log_done "Key and CSR generated"

    # Self-sign
    log_info "Signing certificate..."
    openssl x509 -signkey "$key_file" \
        -in "$csr_file" \
        -req -days "$SSL_DAYS" \
        -out "$crt_file" 2>/dev/null \
        && log_done "Certificate signed (valid ${SSL_DAYS} days)"

    # Permissions
    chown -R "$NGINX_USER":"$NGINX_GROUP" "$SSL_PRIVATE"
    chown "$NGINX_USER":"$NGINX_GROUP" "$crt_file"
    chmod 600 "$key_file"
    chmod 644 "$crt_file"

    # Verify match
    log_info "Verifying certificate matches key..."
    local crt_md5 key_md5
    crt_md5=$(openssl x509 -noout -modulus -in "$crt_file" | openssl md5)
    key_md5=$(openssl rsa  -noout -modulus -in "$key_file" | openssl md5)
    if [[ "$crt_md5" == "$key_md5" ]]; then
        log_done "Certificate and key match ✔"
    else
        log_error "Certificate and key do NOT match!"
        return 1
    fi

    SSL_CRT="$crt_file"
    SSL_KEY="$key_file"
    SSL_DHP="$dhp_file"
}

_use_existing_ssl() {
    log_section "Use Existing SSL Certificate"
    echo ""
    ask_required SSL_CRT "Path to .crt file"
    ask_required SSL_KEY "Path to .key file"
    ask SSL_DHP "Path to dhparam.pem (optional)" "${SSL_CERTS}/dhparam.pem"

    [[ -f "$SSL_CRT" ]] || { log_error "CRT file not found: $SSL_CRT"; return 1; }
    [[ -f "$SSL_KEY" ]] || { log_error "KEY file not found: $SSL_KEY"; return 1; }

    # Verify match
    local crt_md5 key_md5
    crt_md5=$(openssl x509 -noout -modulus -in "$SSL_CRT" | openssl md5)
    key_md5=$(openssl rsa  -noout -modulus -in "$SSL_KEY" | openssl md5)
    if [[ "$crt_md5" == "$key_md5" ]]; then
        log_done "Certificate and key match ✔"
    else
        log_error "Certificate and key do NOT match!"
        return 1
    fi

    # Generate dhparam if missing
    if [[ ! -f "$SSL_DHP" ]]; then
        log_info "Generating DH params..."
        openssl dhparam -out "$SSL_DHP" 2048 2>/dev/null \
            && log_done "dhparam.pem generated"
    fi
}

# =============================================================================
# 2. CREATE INSTANCE
# =============================================================================
do_create_instance() {
    check_root
    log_section "Create NGINX Instance"

    [[ -x "$NGINX_BIN" ]] || { log_error "NGINX not installed. Run Install first (option 1 or 2)."; return 1; }

    echo ""
    echo -e "${BOLD}  [ Instance Configuration ]${NC}"
    ask_required INST_NAME    "Instance name (e.g. PVNAPP01-WS)    "
    ask_required LISTEN_PORT  "NGINX listen port  (e.g. 31001)           "

    echo ""
    ask_yn ENABLE_SSL "Enable SSL/HTTPS for this instance?" "y"

    local SSL_CRT="" SSL_KEY="" SSL_DHP="" USE_SSL=false
    if [[ "$ENABLE_SSL" == "y" ]]; then
        USE_SSL=true
        echo ""
        echo -e "  ${BOLD}SSL certificate:${NC}"
        echo    "  1. Generate self-signed certificate"
        echo    "  2. Use existing certificate files"
        ask SSL_OPT "Select option" "1"

        if [[ "$SSL_OPT" == "1" ]]; then
            _generate_ssl "$INST_NAME"
        else
            _use_existing_ssl
        fi
    fi

    # --- SELinux port ---
    log_info "Adding port $LISTEN_PORT to SELinux http_port_t..."
    semanage port -a -t http_port_t -p tcp "$LISTEN_PORT" 2>/dev/null \
        && log_done "SELinux: port $LISTEN_PORT allowed" \
        || log_warn "SELinux port already registered or semanage failed"

    # --- Firewall ---
    log_info "Opening firewall port $LISTEN_PORT..."
    firewall-cmd --zone=public --add-port="${LISTEN_PORT}/tcp" --permanent 2>/dev/null \
        && firewall-cmd --reload 2>/dev/null \
        && log_done "Firewall: port $LISTEN_PORT opened" \
        || log_warn "firewall-cmd failed — check manually"

    # --- Instance directories ---
    local inst_dir="${NGINX_INST_BASE}/${INST_NAME}"
    local log_dir="${NGINX_LOG_BASE}/${INST_NAME}"

    log_info "Creating instance directories..."
    mkdir -p "${inst_dir}/conf.d" "$log_dir"
    cp /etc/nginx/nginx.conf "$inst_dir/" 2>/dev/null || true
    chown -R "$NGINX_USER":"$NGINX_GROUP" "$inst_dir"
    chown -R "$NGINX_USER":"$LOG_GROUP"   "$log_dir"
    log_done "Directories created"

    # --- nginx.conf ---
    log_info "Creating nginx.conf for $INST_NAME..."

    local proto="http"
    $USE_SSL && proto="https"

    cat > "${inst_dir}/nginx.conf" << EOF
# NGINX Instance: ${INST_NAME}
# Generated by nginx_setup.sh

worker_processes  1;

error_log ${log_dir}/error.log warn;
pid       /run/nginx/${INST_NAME}.pid;

events {
    worker_connections  1024;
}

http {
    ### Basic settings
    tcp_nopush  on;
    tcp_nodelay on;
    types_hash_max_size 2048;
    server_tokens off;

    include      /etc/nginx/mime.types;
    default_type application/octet-stream;

    ### HTTP Security Headers
    add_header X-Content-Type-Options nosniff;
    add_header Strict-Transport-Security "max-age=16070400; includeSubDomains; preload";
    add_header X-Frame-Options SAMEORIGIN;

    ### Mitigating Slow HTTP DoS Attack
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

        ### Allow only safe HTTP methods
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
        ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;

        ssl_certificate     ${SSL_CRT};
        ssl_certificate_key ${SSL_KEY};
        ssl_dhparam         ${SSL_DHP};
SSLEOF
fi)

        ### Reverse Proxy
        proxy_redirect off;
        proxy_set_header X-Real-IP        \$remote_addr;
        proxy_set_header X-Forwarded-For  \$proxy_add_x_forwarded_for;
        proxy_set_header Host             \$http_host;

        location / {
            # TODO: configure backend — use option "Config Proxy" to set this
            # proxy_pass http://localhost:8080/;
        }
    }
}
EOF
    chown "$NGINX_USER":"$NGINX_GROUP" "${inst_dir}/nginx.conf"
    log_done "nginx.conf created"

    # --- Test configuration ---
    log_info "Testing NGINX configuration..."
    mkdir -p /run/nginx
    "$NGINX_BIN" -c "${inst_dir}/nginx.conf" -t \
        && log_done "Configuration test passed" \
        || { log_error "Configuration test failed — check ${inst_dir}/nginx.conf"; return 1; }

    # --- Systemd service ---
    log_info "Creating systemd service: ${INST_NAME}.service..."
    cat > "/etc/systemd/system/${INST_NAME}.service" << EOF
[Unit]
Description=nginx – ${INST_NAME}
Documentation=http://nginx.org/en/docs/
After=network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
User=${NGINX_USER}
Group=${NGINX_GROUP}
SupplementaryGroups=${LOG_GROUP}

ProtectHome=read-only
RuntimeDirectory=nginx
ReadWriteDirectories=/var /run /tmp -/appvol

PIDFile=/run/nginx/${INST_NAME}.pid
ExecStart=${NGINX_BIN} -c ${inst_dir}/nginx.conf
ExecReload=/bin/sh -c "/bin/kill -s HUP \$(/bin/cat /run/nginx/${INST_NAME}.pid)"
ExecStop=/bin/sh -c "/bin/kill -s TERM \$(/bin/cat /run/nginx/${INST_NAME}.pid)"

Restart=on-failure
RestartSec=30s

RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
DevicePolicy=closed

LimitNOFILE=65536
LimitNPROC=131072
LimitMEMLOCK=65536

[Install]
WantedBy=multi-user.target
EOF
    _systemctl daemon-reload
    _systemctl enable  "${INST_NAME}.service" > /dev/null 2>&1
    _systemctl start   "${INST_NAME}.service"
    log_done "Service ${INST_NAME} enabled and started"

    # Fix log ownership after start
    chown "$NGINX_USER":"$LOG_GROUP" "${log_dir}"/* 2>/dev/null || true

    # --- Log rotation ---
    log_info "Setting up log rotation..."
    yum install -y logrotate > /dev/null 2>&1 || true
    cat > "/etc/logrotate.d/${INST_NAME}_log.conf" << EOF
${log_dir}/* {
    daily
    missingok
    create 0640 ${NGINX_USER} ${LOG_GROUP}
    rotate 30
    size 100M
    dateext
    dateformat -%Y%m%d
    postrotate
        if [ -f /run/nginx/${INST_NAME}.pid ]; then
            kill -USR1 \$(cat /run/nginx/${INST_NAME}.pid)
        fi
    endscript
}
EOF
    log_done "Log rotation configured (daily, 30 days, 100MB max)"

    local db_host
    db_host=$(cat /etc/hostname 2>/dev/null | tr -d ' \n\r')
    [[ -z "$db_host" ]] && db_host="localhost"

    log_section "Instance ${INST_NAME} created successfully"
    echo -e "  ${BOLD}[ Access URLs ]${NC}"
    echo    "  Inside server  : ${proto}://localhost:${LISTEN_PORT}"
    echo    "  Docker host    : ${proto}://host.docker.internal:${LISTEN_PORT}"
    echo    "  Hostname       : ${proto}://${db_host}:${LISTEN_PORT}"
    echo ""
    echo -e "  ${BOLD}[ Files ]${NC}"
    echo    "  Config         : ${inst_dir}/nginx.conf"
    echo    "  Logs           : ${log_dir}/"
    $USE_SSL && echo "  Certificate    : ${SSL_CRT}"
    $USE_SSL && echo "  Key            : ${SSL_KEY}"
}

# =============================================================================
# 3. REMOVE INSTANCE
# =============================================================================
# =============================================================================
# 4. CONFIG INSTANCE
# =============================================================================

_select_instance() {
    if [[ ! -d "$NGINX_INST_BASE" ]] || [[ -z "$(ls -A $NGINX_INST_BASE 2>/dev/null)" ]]; then
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

    # Show key info from nginx.conf
    local port server_name proxy_pass ssl_status
    port=$(grep "listen " "$INST_CONF" | grep -v "#" | awk '{print $2}' | grep -oP '^\d+' | head -1)
    server_name=$(grep "server_name" "$INST_CONF" | grep -v "#" | awk '{print $2}' | tr -d ';' | head -1)
    proxy_pass=$(grep "proxy_pass" "$INST_CONF" | grep -v "#" | awk '{print $2}' | tr -d ';' | head -1)
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
        _systemctl reload "${INST_NAME}.service" 2>/dev/null \
            || _systemctl restart "${INST_NAME}.service" 2>/dev/null \
            || log_warn "Could not reload service — restart manually"
        log_done "Service reloaded"
    else
        log_error "Configuration test failed — restoring backup"
        cp "${INST_CONF}.bak" "$INST_CONF" 2>/dev/null || true
        return 1
    fi
}

# --- 4a. SSL ---
_config_ssl() {
    log_section "Config SSL — ${INST_NAME}"
    cp "$INST_CONF" "${INST_CONF}.bak"

    local has_ssl=false
    grep -q "ssl_certificate" "$INST_CONF" && has_ssl=true

    if $has_ssl; then
        echo ""
        echo -e "  ${BOLD}SSL is currently enabled.${NC}"
        echo    "  1. Update certificate"
        echo    "  2. Disable SSL (switch to HTTP)"
        ask SSL_ACTION "Select option" "1"

        if [[ "$SSL_ACTION" == "2" ]]; then
            # Disable SSL
            sed -i 's/listen \(.*\) ssl.*/listen \1;/' "$INST_CONF"
            sed -i '/ssl_/d' "$INST_CONF"
            log_done "SSL disabled — switched to HTTP"
        else
            # Update cert
            echo ""
            echo    "  1. Generate new self-signed certificate"
            echo    "  2. Use existing certificate files"
            ask SSL_OPT "Select option" "1"
            [[ "$SSL_OPT" == "1" ]] && _generate_ssl "$INST_NAME" || _use_existing_ssl

            sed -i "s|ssl_certificate .*|ssl_certificate     ${SSL_CRT};|" "$INST_CONF"
            sed -i "s|ssl_certificate_key .*|ssl_certificate_key ${SSL_KEY};|" "$INST_CONF"
            sed -i "s|ssl_dhparam .*|ssl_dhparam         ${SSL_DHP};|" "$INST_CONF"
            log_done "Certificate updated"
        fi
    else
        echo ""
        echo -e "  ${BOLD}SSL is currently disabled.${NC}"
        echo    "  1. Generate new self-signed certificate"
        echo    "  2. Use existing certificate files"
        ask SSL_OPT "Select option" "1"
        [[ "$SSL_OPT" == "1" ]] && _generate_ssl "$INST_NAME" || _use_existing_ssl

        # Enable SSL in listen directive
        sed -i 's/listen \([0-9]*\);/listen \1 ssl default_server;/' "$INST_CONF"

        # Add ssl params before proxy section
        sed -i "/proxy_redirect off/i\\
        ssl_protocols TLSv1.2 TLSv1.3;\\
        ssl_prefer_server_ciphers on;\\
        ssl_session_timeout 30m;\\
        ssl_session_tickets off;\\
        ssl_session_cache shared:SSL:10m;\\
        ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;\\
        ssl_certificate     ${SSL_CRT};\\
        ssl_certificate_key ${SSL_KEY};\\
        ssl_dhparam         ${SSL_DHP};\\
" "$INST_CONF"
        log_done "SSL enabled"
    fi

    _reload_instance
}

# --- 4b. Hostname ---
_config_hostname() {
    log_section "Config Hostname — ${INST_NAME}"
    cp "$INST_CONF" "${INST_CONF}.bak"

    local current
    current=$(grep "server_name" "$INST_CONF" | awk '{print $2}' | tr -d ';')
    log_info "Current server_name: $current"

    ask_required NEW_HOSTNAME "New server_name (domain or hostname)"
    sed -i "s/server_name .*/server_name ${NEW_HOSTNAME};/" "$INST_CONF"
    log_done "server_name updated to: $NEW_HOSTNAME"

    _reload_instance
}

# --- 4c. Proxy ---
_config_proxy() {
    log_section "Config Proxy — ${INST_NAME}"
    cp "$INST_CONF" "${INST_CONF}.bak"

    local current
    current=$(grep "proxy_pass" "$INST_CONF" | grep -v "#" | awk '{print $2}' | tr -d ';')
    [[ -n "$current" ]] && log_info "Current proxy_pass: $current"

    echo ""
    echo -e "  ${BOLD}[ Backend Configuration ]${NC}"
    ask BACKEND_PROTO "Protocol             (e.g. http)      " "http"
    ask_required BACKEND_HOST "Backend host         (e.g. localhost) "
    ask_required BACKEND_PORT "Backend port         (e.g. 8443)      "

    local proxy_pass="${BACKEND_PROTO}://${BACKEND_HOST}:${BACKEND_PORT}/"

    if grep -q "proxy_pass" "$INST_CONF"; then
        sed -i "s|proxy_pass .*;|proxy_pass ${proxy_pass};|" "$INST_CONF"
        sed -i "s|# proxy_pass .*;|proxy_pass ${proxy_pass};|" "$INST_CONF"
    else
        sed -i "s|# TODO.*||" "$INST_CONF"
        sed -i "/location \/ {/a\\            proxy_pass ${proxy_pass};" "$INST_CONF"
    fi
    log_done "proxy_pass set to: $proxy_pass"

    _reload_instance
}

# --- 4d. Port ---
_config_port() {
    log_section "Config Port — ${INST_NAME}"
    cp "$INST_CONF" "${INST_CONF}.bak"

    local current_port
    current_port=$(grep "listen " "$INST_CONF" | grep -v "#" | awk '{print $2}' | grep -oP '^\d+')
    log_info "Current listen port: $current_port"

    ask_required NEW_PORT "New listen port (e.g. 31002)"

    # SELinux: remove old, add new
    semanage port -d -t http_port_t -p tcp "$current_port" 2>/dev/null || true
    semanage port -a -t http_port_t -p tcp "$NEW_PORT" 2>/dev/null \
        && log_done "SELinux: port $NEW_PORT allowed" \
        || log_warn "SELinux port update failed — check manually"

    # Firewall: remove old, add new
    firewall-cmd --zone=public --remove-port="${current_port}/tcp" --permanent 2>/dev/null || true
    firewall-cmd --zone=public --add-port="${NEW_PORT}/tcp" --permanent 2>/dev/null \
        && firewall-cmd --reload 2>/dev/null \
        && log_done "Firewall: port $NEW_PORT opened" \
        || log_warn "firewall-cmd failed — check manually"

    # Update nginx.conf
    sed -i "s/listen ${current_port}/listen ${NEW_PORT}/" "$INST_CONF"
    log_done "Listen port updated: $current_port → $NEW_PORT"

    _reload_instance
}

# --- 4e. Methods ---
_config_methods() {
    log_section "Config Allowed Methods — ${INST_NAME}"
    cp "$INST_CONF" "${INST_CONF}.bak"

    local current
    current=$(grep "request_method" "$INST_CONF" | grep -oP '\(.*\)')
    log_info "Current allowed methods: $current"

    echo ""
    echo    "  Common choices:"
    echo    "    1. GET|POST|OPTIONS          (default — read-only + form submit)"
    echo    "    2. GET|POST|PUT|DELETE|OPTIONS  (REST API)"
    echo    "    3. Custom"
    ask METHOD_OPT "Select option" "1"

    local methods
    case "$METHOD_OPT" in
        1) methods="GET|POST|OPTIONS" ;;
        2) methods="GET|POST|PUT|DELETE|OPTIONS" ;;
        3) ask_required methods "Enter methods separated by | (e.g. GET|POST)" ;;
    esac

    sed -i "s|request_method !~ .*|request_method !~ ^(${methods})\$) {|" "$INST_CONF"
    log_done "Allowed methods updated: $methods"

    _reload_instance
}

do_config_instance() {
    check_root
    log_section "Config Instance"

    _select_instance || return 1

    echo ""
    echo -e "  ${BOLD}What would you like to configure?${NC}"
    echo    "  1. SSL        — enable / update / disable SSL certificate"
    echo    "  2. Hostname   — set server_name (domain)"
    echo    "  3. Proxy      — set backend host and port"
    echo    "  4. Port       — change NGINX listen port"
    echo    "  5. Methods    — set allowed HTTP methods"
    echo    "  6. View       — show current nginx.conf"
    echo ""
    ask CONFIG_OPT "Select option" ""

    case "$CONFIG_OPT" in
        1) _config_ssl      ;;
        2) _config_hostname ;;
        3) _config_proxy    ;;
        4) _config_port     ;;
        5) _config_methods  ;;
        6)
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

    # List existing instances
    if [[ ! -d "$NGINX_INST_BASE" ]] || [[ -z "$(ls -A $NGINX_INST_BASE 2>/dev/null)" ]]; then
        log_error "No instances found in $NGINX_INST_BASE"
        return 1
    fi

    log_info "Available instances:"
    ls "$NGINX_INST_BASE" | while read -r inst; do
        echo "  - $inst"
    done
    echo ""
    ask_required INST_NAME "Instance name to remove"

    local inst_dir="${NGINX_INST_BASE}/${INST_NAME}"
    [[ -d "$inst_dir" ]] || { log_error "Instance not found: $inst_dir"; return 1; }

    ask CONFIRM "Confirm removal of instance '$INST_NAME'? (y/n)" "n"
    [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && { log_warn "Cancelled."; return 0; }

    # Stop + disable service
    _systemctl stop    "${INST_NAME}.service" 2>/dev/null || true
    _systemctl disable "${INST_NAME}.service" 2>/dev/null || true
    rm -f "/etc/systemd/system/${INST_NAME}.service"
    _systemctl daemon-reload
    log_done "Service removed"

    # Remove logrotate
    rm -f "/etc/logrotate.d/${INST_NAME}_log.conf"
    log_done "Log rotation config removed"

    # Remove instance dir and logs
    rm -rf "$inst_dir"
    rm -rf "${NGINX_LOG_BASE}/${INST_NAME}"
    log_done "Instance files removed"

    log_section "Instance ${INST_NAME} removed"
}

# =============================================================================
# 4. UNINSTALL
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

    # Stop + remove all services
    log_info "Stopping and removing all NGINX services..."
    for svc in $(if _has_systemd; then systemctl list-units --type=service --all 2>/dev/null | grep -i nginx | awk '{print $1}'; fi); do
        _systemctl stop    "$svc" 2>/dev/null || true
        _systemctl disable "$svc" 2>/dev/null || true
        rm -f "/etc/systemd/system/$svc"
    done
    _systemctl daemon-reload
    log_done "Services removed"

    # Remove NGINX package
    log_info "Removing NGINX package..."
    yum remove -y nginx rh-nginx118 2>/dev/null || true
    log_done "NGINX package removed"

    # Remove directories
    log_info "Removing directories..."
    rm -rf "$NGINX_INST_BASE"
    rm -rf "/appvol"
    rm -rf "$NGINX_CACHE"
    rm -rf "$NGINX_LIB"
    rm -rf /var/log/nginx
    log_done "Directories removed"

    # Remove logrotate configs
    rm -f /etc/logrotate.d/*_log.conf
    log_done "Log rotation configs removed"

    # Remove user + groups
    log_info "Removing user and groups..."
    userdel -r "$NGINX_USER" 2>/dev/null || true
    groupdel "$NGINX_GROUP"  2>/dev/null || true
    groupdel "$LOG_GROUP"    2>/dev/null || true
    log_done "User and groups removed"

    # Clean kernel param
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

    # CLI dispatch
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
    echo -e "  ${BOLD}4.${NC} Config Instance           SSL / Hostname / Proxy / Port / Methods"
    echo -e "  ${BOLD}5.${NC} Remove Instance           Remove a specific instance"
    echo -e "  ${BOLD}6.${NC} Uninstall                 Full clean — remove all NGINX files"
    echo ""
    ask CHOICE "Select option" "2"

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
