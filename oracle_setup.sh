#!/bin/bash
# =============================================================================
#  oracle_setup_all.sh
#  All-in-one Oracle Database setup — runs as root, fully automated.
#
#  What it does (in order):
#    1. System preparation (hostname, kernel, limits, packages, user, dirs)
#    2. Firewall: open Oracle ports (or disable, your choice)
#    3. Configure the oracle user environment (.bash_profile)
#    4. Silent install of Oracle software (run automatically as oracle)
#    5. Run the root configuration scripts automatically
#
#  Usage:
#    chmod +x oracle_setup_all.sh
#    sudo ./oracle_setup_all.sh
#
#  Press Enter to accept the default value shown in [brackets].
# =============================================================================

set -uo pipefail

# =============================================================================
# COLORS
# =============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_section() { echo -e "\n${BLUE}${BOLD}══════════════════════════════════════${NC}"; \
                echo -e "${BLUE}${BOLD}  $1${NC}"; \
                echo -e "${BLUE}${BOLD}══════════════════════════════════════${NC}"; }
log_done()    { echo -e "${GREEN}${BOLD}  ✔ $1${NC}"; }
log_skip()    { echo -e "${YELLOW}  ⊘ $1 (already exists, skipping)${NC}"; }

ask() {
    local var=$1 prompt=$2 default=$3
    echo -ne "${CYAN}  ▶ ${prompt} [${BOLD}${default}${NC}${CYAN}]: ${NC}"
    read -r input
    eval "$var=\"${input:-$default}\""
}

ask_required() {
    local var=$1 prompt=$2
    while true; do
        echo -ne "${CYAN}  ▶ ${prompt}: ${NC}"
        read -r input
        if [[ -n "$input" ]]; then eval "$var=\"$input\""; break
        else log_error "This field is required. Please enter a value."; fi
    done
}

ask_number() {
    # ask_number VAR "prompt" DEFAULT  — accepts digits only
    local var=$1 prompt=$2 default=$3
    while true; do
        echo -ne "${CYAN}  ▶ ${prompt} [${BOLD}${default}${NC}${CYAN}]: ${NC}"
        read -r input
        input="${input:-$default}"
        if [[ "$input" =~ ^[0-9]+$ ]]; then
            eval "$var=\"$input\""; break
        else
            log_error "Must be a number (digits only). You typed: $input"
        fi
    done
}

ask_password() {
    local var=$1 prompt=$2
    while true; do
        echo -ne "${CYAN}  ▶ ${prompt}        : ${NC}"; read -rs pass1; echo
        echo -ne "${CYAN}  ▶ Confirm password : ${NC}"; read -rs pass2; echo
        if [[ "$pass1" == "$pass2" && -n "$pass1" ]]; then
            eval "$var=\"$pass1\""; break
        else log_error "Passwords do not match or are empty. Please try again."; fi
    done
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root. Use: sudo $0"
        exit 1
    fi
}

# =============================================================================
# SELECT ZIP — ask for a folder, scan it for .zip files, let the user pick
# =============================================================================
select_zip() {
    local folder
    while true; do
        ask_required folder "Folder that contains the Oracle installer zip"

        if [[ ! -d "$folder" ]]; then
            log_error "Not a directory: $folder"
            continue
        fi

        # Collect .zip files in that folder (non-recursive)
        local zips=()
        while IFS= read -r -d '' f; do
            zips+=("$f")
        done < <(find "$folder" -maxdepth 1 -type f -iname '*.zip' -print0 2>/dev/null | sort -z)

        if [[ ${#zips[@]} -eq 0 ]]; then
            log_warn "No .zip files found in: $folder"
            ask retry "Try another folder? (y/n)" "y"
            [[ "$retry" == "y" || "$retry" == "Y" ]] && continue
            # Fall back to manual full path
            ask_required ZIP_PATH "Full path to the Oracle database home zip"
            return
        fi

        # Show numbered list
        echo ""
        echo -e "${BOLD}  Found ${#zips[@]} zip file(s):${NC}"
        local i=1
        for z in "${zips[@]}"; do
            local size
            size=$(du -h "$z" 2>/dev/null | cut -f1)
            printf "    %2d = %s  (%s)\n" "$i" "$(basename "$z")" "$size"
            ((i++))
        done
        echo ""

        local pick
        ask pick "Select option" "1"
        if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#zips[@]} )); then
            ZIP_PATH="${zips[$((pick-1))]}"
            log_done "Selected: $ZIP_PATH"
            return
        else
            log_error "Invalid selection: $pick"
        fi
    done
}

# =============================================================================
# AUTO-CALCULATE KERNEL PARAMS BASED ON OS-ALLOCATED RAM
#  Source: /proc/meminfo -> MemTotal (RAM reported by kernel to OS)
# =============================================================================
calc_kernel_params() {
    local ram_kb
    ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    RAM_GB=$(( ram_kb / 1024 / 1024 ))

    # Fixed values per oracle-base.com / IBFT guideline
    SHMMAX=4398046511104   # ~4 TB ceiling
    SHMALL=1073741824      # SHMMAX / 4096
    FILEMAX=6815744
    NPROC=16384

    # Dynamic: 90% of OS RAM (MemTotal), phù hợp mọi cấu hình máy
    MEMLOCK_KB=$(( ram_kb * 90 / 100 ))
}

# =============================================================================
# BANNER
# =============================================================================
print_banner() {
    echo -e "${BOLD}"
    echo "  ╔═══════════════════════════════════════════════════════╗"
    echo "  ║        Oracle Database - All-in-One Setup             ║"
    echo "  ╚═══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# =============================================================================
# COLLECT INPUT PARAMETERS
# =============================================================================
collect_inputs() {
    log_section "CONFIGURATION"
    echo -e "  ${YELLOW}Tip:${NC} fields showing a default in [brackets] — just press Enter to accept it."
    echo -e "  ${YELLOW}    ${NC} fields without brackets are required and must be typed in."

    echo ""
    echo -e "${BOLD}  [ Hostname ]${NC}"
    ask DB_HOSTNAME   "Primary hostname       " "oracle-db.local"
    ask DB_HOSTNAME2  "Hostname alias (short) " "oracle-db-alias.local"

    echo ""
    echo -e "${BOLD}  [ Oracle Directories ]${NC}"
    echo    "  Software path example: /u01/app/oracle/product/19.0.0/dbhome_1"
    while true; do
        ask_required ORACLE_SW_DIR "Oracle software directory (ORACLE_HOME)"
        if [[ "$ORACLE_SW_DIR" != /* ]]; then
            log_error "Must start with '/'. You typed: $ORACLE_SW_DIR"
        elif [[ "$ORACLE_SW_DIR" != */product/* ]]; then
            log_error "Must contain '/product/'. Example: ${ORACLE_SW_DIR%/}/product/19.0.0/dbhome_1"
        else
            break
        fi
    done
    while true; do
        ask_required ORACLE_DATA_PATH "Oracle data directory"
        [[ "$ORACLE_DATA_PATH" == /* ]] && break
        log_error "Path must be absolute (start with '/'). You typed: $ORACLE_DATA_PATH"
    done

    echo ""
    echo -e "${BOLD}  [ Database Identifiers ]${NC}"
    echo    "  These define the names of the database to be created later:"
    echo    "    • ORACLE_SID     — instance name (the running database)"
    echo    "    • ORACLE_UNQNAME — unique database name (usually same as SID)"
    echo    "    • PDB_NAME       — pluggable database name (the application schema)"
    echo ""
    ask_required ORACLE_SID      "ORACLE_SID (instance name)"
    ask          ORACLE_UNQNAME  "ORACLE_UNQNAME            " "$ORACLE_SID"
    ask          PDB_NAME        "PDB_NAME (pluggable database) " "master"

    echo ""
    echo -e "${BOLD}  [ Oracle Groups ]${NC}"
    echo    "  Oracle uses three groups to separate privileges:"
    echo    "    • oinstall — owns the Oracle software and inventory"
    echo    "    • dba      — full administrative rights (SYSDBA) on the database"
    echo    "    • oper     — limited rights to start/stop the database (SYSOPER)"
    echo ""
    ask_number GID_OINSTALL "GID for group oinstall   " "54321"
    ask_number GID_DBA      "GID for group dba        " "54322"
    ask_number GID_OPER     "GID for group oper       " "54323"

    echo ""
    echo -e "${BOLD}  [ Oracle User ]${NC}"
    ask_number ORACLE_UID   "UID for user oracle      " "54321"
    ask_password ORACLE_PASS "Password for oracle user"

    echo ""
    echo -e "${BOLD}  [ Firewall ]${NC}"
    echo    "  1 = Open Oracle ports only (recommended for production)"
    echo    "  2 = Disable firewall completely (development/testing only)"
    ask FW_MODE "Select option" "1"
    if [[ "$FW_MODE" == "1" ]]; then
        ask FW_PORTS "Ports to open (comma-separated)  # default: Oracle DB + EM Express" "1521,5500"
    fi

    echo ""
    echo -e "${BOLD}  [ Network ]${NC}"
    echo    "  Network speed affects buffer size:"
    echo    "    1  = 1 Gbps  (rmem_max=4194304,  wmem_max=1048576)"
    echo    "    10 = 10 Gbps (rmem_max=16777216, wmem_max=16777216)"
    ask NET_SPEED "Select option" "1"

    echo ""
    echo -e "${BOLD}  [ Installer ]${NC}"
    echo    "  Enter the folder where the installer zip is located;"
    echo    "  the script will scan it and let you pick the file."
    select_zip

    # Auto kernel params
    echo ""
    log_info "Calculating kernel parameters from OS RAM (/proc/meminfo MemTotal)..."
    calc_kernel_params
    log_info "Detected OS RAM: ${RAM_GB} GB → memlock default = ${MEMLOCK_KB} KB"

    echo ""
    echo -e "${BOLD}  [ Kernel Parameters — press Enter to accept defaults ]${NC}"
    ask SHMMAX  "kernel.shmmax (bytes)        # default: oracle-base fixed value (~4TB ceiling)" "$SHMMAX"
    ask SHMALL  "kernel.shmall (pages)        # default: oracle-base fixed value" "$SHMALL"
    ask FILEMAX "fs.file-max                  # default: 6815744 (Oracle recommended)" "$FILEMAX"
    ask NPROC   "nproc limit (oracle user)    # default: 16384" "$NPROC"
    ask MEMLOCK "memlock     (KB)             # default: 90% OS RAM" "$MEMLOCK_KB"

    if [[ "$NET_SPEED" == "10" ]]; then RMEM_MAX=16777216; WMEM_MAX=16777216
    else RMEM_MAX=4194304; WMEM_MAX=1048576; fi

    ORACLE_SW_BASE=$(echo "$ORACLE_SW_DIR" | cut -d'/' -f1-3)
    ORACLE_DATA_BASE=$(echo "$ORACLE_DATA_PATH" | cut -d'/' -f1-2)
    ORACLE_BASE=$(echo "$ORACLE_SW_DIR" | sed 's|/product/.*||')
    ORA_INVENTORY="${ORACLE_SW_BASE}/oraInventory"

    echo ""
    log_section "CONFIGURATION SUMMARY"
    echo -e "  Primary hostname     : ${BOLD}${DB_HOSTNAME}${NC}"
    echo -e "  Software directory   : ${BOLD}${ORACLE_SW_DIR}${NC}"
    echo -e "  Data directory       : ${BOLD}${ORACLE_DATA_PATH}${NC}"
    echo -e "  ORACLE_SID / PDB     : ${BOLD}${ORACLE_SID} / ${PDB_NAME}${NC}"
    echo -e "  ORACLE_BASE          : ${BOLD}${ORACLE_BASE}${NC}"
    echo -e "  Installer zip        : ${BOLD}${ZIP_PATH}${NC}"
    if [[ "$FW_MODE" == "1" ]]; then
        echo -e "  Firewall             : ${BOLD}open ports ${FW_PORTS}${NC}"
    else
        echo -e "  Firewall             : ${BOLD}disabled${NC}"
    fi
    echo -e "  System RAM           : ${BOLD}${RAM_GB} GB${NC}"
    echo ""
    echo -ne "${YELLOW}  Proceed? (y/n) [y]: ${NC}"
    read -r confirm
    if [[ "${confirm:-y}" != "y" && "${confirm:-y}" != "Y" ]]; then
        echo "Aborted."; exit 0
    fi
}

# =============================================================================
# 1. HOSTNAME
# =============================================================================
setup_hostname() {
    log_section "1. Configure Hostname"
    if grep -q "$DB_HOSTNAME" /etc/hosts 2>/dev/null; then
        log_skip "Hostname already in /etc/hosts"
    else
        echo "127.0.0.1   ${DB_HOSTNAME} ${DB_HOSTNAME2}" >> /etc/hosts
        log_done "Added hostname entry to /etc/hosts"
    fi
    echo "$DB_HOSTNAME" > /etc/hostname
    hostnamectl set-hostname "$DB_HOSTNAME" 2>/dev/null || true
    log_done "Hostname set to: $DB_HOSTNAME"
}

# =============================================================================
# 2. KERNEL PARAMETERS
# =============================================================================
setup_kernel_params() {
    log_section "2. Configure Kernel Parameters"
    local marker="# Oracle Database - added by oracle_setup_all.sh"
    if grep -q "$marker" /etc/sysctl.conf 2>/dev/null; then
        log_skip "Kernel parameters already configured"
    else
        cat >> /etc/sysctl.conf << EOF

${marker}
fs.file-max = ${FILEMAX}
kernel.sem = 250 32000 100 128
kernel.shmmni = 4096
kernel.shmall = ${SHMALL}
kernel.shmmax = ${SHMMAX}
kernel.panic_on_oops = 1
net.core.rmem_default = 262144
net.core.rmem_max = 4194304
net.core.wmem_default = 262144
net.core.wmem_max = 1048576
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
fs.aio-max-nr = 1048576
net.ipv4.ip_local_port_range = 9000 65500
EOF
        log_done "Kernel parameters written to /etc/sysctl.conf"
    fi
    /sbin/sysctl -p > /dev/null 2>&1
    log_done "Kernel parameters applied"
}

# =============================================================================
# 3. RESOURCE LIMITS
# =============================================================================
setup_limits() {
    log_section "3. Configure Resource Limits"
    local f="/etc/security/limits.d/oracle-database-preinstall.conf"
    if [[ -f "$f" ]]; then
        log_skip "Limits file already exists"
    else
        cat > "$f" << EOF
# Oracle Database resource limits - generated by oracle_setup_all.sh
oracle   soft   nofile    1024
oracle   hard   nofile    65536
oracle   soft   nproc     ${NPROC}
oracle   hard   nproc     ${NPROC}
oracle   soft   stack     10240
oracle   hard   stack     32768
oracle   hard   memlock   ${MEMLOCK}
oracle   soft   memlock   ${MEMLOCK}
EOF
        log_done "Limits file created"
    fi
}

# =============================================================================
# 4. INSTALL PACKAGES
# =============================================================================
install_packages() {
    log_section "4. Install Required Packages"

    # libnsl is REQUIRED — runInstaller's Perl needs libnsl.so.1 or it crashes.
    # Install it first and on its own so a failure here is visible immediately.
    log_info "Installing libnsl (required by the installer)..."
    if dnf install -y libnsl libnsl2 > /tmp/oracle_libnsl.log 2>&1; then
        log_done "libnsl installed"
    else
        log_error "Failed to install libnsl — the installer will not run without it."
        log_error "See /tmp/oracle_libnsl.log. Try: dnf install -y libnsl libnsl2"
        exit 1
    fi

    # Remaining packages — install them individually so one missing package
    # (e.g. an unavailable .i686 build) does not abort all the others.
    local packages=(
        bc binutils compat-libstdc++-33 elfutils-libelf elfutils-libelf-devel
        fontconfig-devel glibc glibc-devel ksh libaio libaio-devel
        libXrender libXrender-devel libX11 libXau libXi libXtst
        libgcc libstdc++ libstdc++-devel libxcb make net-tools nfs-utils
        sysstat smartmontools unixODBC unzip
    )
    log_info "Installing ${#packages[@]} support packages..."
    local failed=()
    for pkg in "${packages[@]}"; do
        dnf install -y "$pkg" >> /tmp/oracle_dnf.log 2>&1 || failed+=("$pkg")
    done

    if [[ ${#failed[@]} -eq 0 ]]; then
        log_done "All support packages installed"
    else
        log_warn "Some optional packages were not installed: ${failed[*]}"
        log_warn "This is usually non-critical. See /tmp/oracle_dnf.log"
    fi
}

# =============================================================================
# 5. CREATE GROUPS AND USER
# =============================================================================
setup_user() {
    log_section "5. Create Oracle Groups and User"
    for entry in "${GID_OINSTALL}:oinstall" "${GID_DBA}:dba" "${GID_OPER}:oper"; do
        local gid="${entry%%:*}" gname="${entry##*:}"
        if getent group "$gname" > /dev/null 2>&1; then
            log_skip "Group '$gname' already exists"
        else
            if groupadd -g "$gid" "$gname"; then
                log_done "Group created: $gname (gid=$gid)"
            else
                log_error "Failed to create group $gname (gid=$gid). Is the GID already in use?"
                exit 1
            fi
        fi
    done

    if id oracle > /dev/null 2>&1; then
        log_skip "User 'oracle' already exists"
        # Make sure a home directory exists even if the user was created before
        if [[ ! -d /home/oracle ]]; then
            mkdir -p /home/oracle
            chown oracle:oinstall /home/oracle
            log_done "Created missing home directory /home/oracle"
        fi
    else
        # -m creates the home directory (some minimal images skip it otherwise)
        if useradd -u "$ORACLE_UID" -g oinstall -G dba,oper -m -d /home/oracle -s /bin/bash oracle; then
            log_done "User created: oracle (uid=$ORACLE_UID, home=/home/oracle)"
        else
            log_error "Failed to create user 'oracle'. Check that UID $ORACLE_UID is free."
            exit 1
        fi
    fi

    echo "oracle:${ORACLE_PASS}" | chpasswd \
        && log_done "Password set for user oracle" \
        || log_warn "Could not set password (chpasswd failed)"

    # Hard verification — do not continue if the user is missing
    if ! id oracle > /dev/null 2>&1; then
        log_error "User 'oracle' still does not exist. Aborting before install."
        exit 1
    fi
}

# =============================================================================
# 6. SELINUX AND FIREWALL
# =============================================================================
setup_selinux_firewall() {
    log_section "6. Configure SELinux and Firewall"

    if [[ -f /etc/selinux/config ]]; then
        sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
        sed -i 's/^SELINUX=enabled/SELINUX=permissive/'  /etc/selinux/config
        setenforce Permissive 2>/dev/null || true
        log_done "SELinux set to permissive"
    else
        log_warn "/etc/selinux/config not found, skipping"
    fi

    if [[ "$FW_MODE" == "1" ]]; then
        # Open Oracle ports — but only if firewalld is actually running
        if ! command -v firewall-cmd > /dev/null 2>&1; then
            log_warn "SKIPPED: firewalld is not installed on this system."
            log_warn "         No ports were opened. If you add a firewall later,"
            log_warn "         open these ports manually: ${FW_PORTS}/tcp."
        elif ! systemctl is-active --quiet firewalld 2>/dev/null; then
            log_warn "SKIPPED: firewalld is installed but not running (inactive/disabled)."
            log_warn "         No ports were opened. To enable it and open the ports later:"
            log_warn "           systemctl enable --now firewalld"
            for p in ${FW_PORTS//,/ }; do
                log_warn "           firewall-cmd --permanent --add-port=${p}/tcp"
            done
            log_warn "           firewall-cmd --reload"
        else
            IFS=',' read -ra PORTS <<< "$FW_PORTS"
            for p in "${PORTS[@]}"; do
                p=$(echo "$p" | tr -d ' ')
                firewall-cmd --permanent --add-port="${p}/tcp" > /dev/null 2>&1
                log_done "Opened port ${p}/tcp"
            done
            firewall-cmd --reload > /dev/null 2>&1
            log_done "Firewall reloaded (ports stay open across reboot)"
        fi
    else
        # Disable firewall completely
        if ! command -v firewall-cmd > /dev/null 2>&1; then
            log_skip "firewalld is not installed — nothing to disable"
        elif systemctl is-active --quiet firewalld 2>/dev/null; then
            systemctl stop firewalld
            systemctl disable firewalld
            log_done "Firewalld stopped and disabled"
            log_warn "Firewall fully disabled — development/testing only."
        else
            log_skip "firewalld is already inactive — nothing to disable"
        fi
    fi
}

# =============================================================================
# 7. CREATE DIRECTORIES
# =============================================================================
setup_directories() {
    log_section "7. Create Oracle Directories"
    mkdir -p "$ORACLE_SW_DIR" "$ORACLE_DATA_PATH"
    chown -R oracle:oinstall "$ORACLE_SW_BASE" "$ORACLE_DATA_BASE"
    chmod -R 775 "$ORACLE_SW_BASE" "$ORACLE_DATA_BASE"
    log_done "Software dir : $ORACLE_SW_DIR"
    log_done "Data dir     : $ORACLE_DATA_PATH"
}

# =============================================================================
# 8. ORACLE USER ENVIRONMENT (.bash_profile)
# =============================================================================
setup_environment() {
    log_section "8. Configure Oracle User Environment"
    local profile="/home/oracle/.bash_profile"
    local marker="# Oracle environment - added by oracle_setup_all.sh"
    if grep -q "$marker" "$profile" 2>/dev/null; then
        log_skip "Oracle environment already present"
    else
        cat >> "$profile" << EOF

${marker}
export TMP=/tmp
export TMPDIR=\$TMP
export ORACLE_HOSTNAME=${DB_HOSTNAME}
export ORACLE_UNQNAME=${ORACLE_UNQNAME}
export ORACLE_BASE=${ORACLE_BASE}
export ORACLE_HOME=${ORACLE_SW_DIR}
export ORA_INVENTORY=${ORA_INVENTORY}
export ORACLE_SID=${ORACLE_SID}
export PDB_NAME=${PDB_NAME}
export DATA_DIR=${ORACLE_DATA_PATH}
export PATH=/usr/sbin:/usr/local/bin:\$PATH
export PATH=\$ORACLE_HOME/bin:\$PATH
export LD_LIBRARY_PATH=\$ORACLE_HOME/lib:/lib:/usr/lib
export CLASSPATH=\$ORACLE_HOME/jlib:\$ORACLE_HOME/rdbms/jlib
EOF
        log_done "Environment written to $profile"
    fi
    chown oracle:oinstall "$profile"
}

# =============================================================================
# 9. SILENT INSTALL (run as oracle) + ROOT SCRIPTS (run as root)
# =============================================================================
install_software() {
    log_section "9. Install Oracle Software (silent, binaries only)"

    if [[ ! -f "$ZIP_PATH" ]]; then
        log_error "Installer zip not found: $ZIP_PATH"; return 1
    fi

    # Make sure unzip is available
    if ! command -v unzip > /dev/null 2>&1; then
        log_info "unzip not found — installing it..."
        dnf install -y unzip > /dev/null 2>&1 \
            && log_done "unzip installed" \
            || { log_error "Could not install unzip. Install it manually: dnf install -y unzip"; return 1; }
    fi

    # If ORACLE_HOME already contains a previous (possibly failed) unzip,
    # clean it so the binaries relink to the correct path.
    if [[ -e "${ORACLE_SW_DIR}/runInstaller" || -e "${ORACLE_SW_DIR}/install/orabasetab" ]]; then
        log_warn "ORACLE_HOME already contains files from a previous unzip."
        log_info "Cleaning ${ORACLE_SW_DIR} for a fresh install..."
        rm -rf "${ORACLE_SW_DIR:?}/"* "${ORACLE_SW_DIR:?}/".[!.]* 2>/dev/null
        log_done "ORACLE_HOME cleaned"
    fi
    mkdir -p "$ORACLE_SW_DIR"
    chown -R oracle:oinstall "$ORACLE_SW_DIR"

    # Unzip into ORACLE_HOME as oracle
    log_info "Unzipping into ${ORACLE_SW_DIR} (as oracle)..."
    su - oracle -c "cd '$ORACLE_SW_DIR' && unzip -oq '$ZIP_PATH'" \
        && log_done "Unzip complete" || { log_error "Unzip failed"; return 1; }

    # Build response file
    local rsp="/tmp/db_install_$(date +%Y%m%d_%H%M%S).rsp"
    cat > "$rsp" << EOF
oracle.install.responseFileVersion=/oracle/install/rspfmt_dbinstall_response_schema_v19.0.0
oracle.install.option=INSTALL_DB_SWONLY
UNIX_GROUP_NAME=oinstall
INVENTORY_LOCATION=${ORA_INVENTORY}
ORACLE_HOME=${ORACLE_SW_DIR}
ORACLE_BASE=${ORACLE_BASE}
oracle.install.db.InstallEdition=EE
oracle.install.db.OSDBA_GROUP=dba
oracle.install.db.OSOPER_GROUP=oper
oracle.install.db.OSBACKUPDBA_GROUP=dba
oracle.install.db.OSDGDBA_GROUP=dba
oracle.install.db.OSKMDBA_GROUP=dba
oracle.install.db.OSRACDBA_GROUP=dba
oracle.install.db.rootconfig.executeRootScript=false
EOF
    chown oracle:oinstall "$rsp"
    log_done "Response file created: $rsp"

    # Run installer as oracle (CV_ASSUME_DISTID makes 19c accept RHEL 8)
    log_info "Running silent installer as oracle — this can take several minutes..."
    su - oracle -c "export CV_ASSUME_DISTID=OEL7.6; \
        '$ORACLE_SW_DIR/runInstaller' -silent -noconfig -ignorePrereqFailure \
        -responseFile '$rsp'"

    # Run the root configuration scripts (we are already root)
    log_section "10. Run Root Configuration Scripts"
    local inv_root="${ORA_INVENTORY}/orainstRoot.sh"
    local home_root="${ORACLE_SW_DIR}/root.sh"

    if [[ -f "$inv_root" ]]; then
        log_info "Running $inv_root ..."
        "$inv_root" && log_done "orainstRoot.sh completed" || log_warn "orainstRoot.sh error"
    fi
    if [[ -f "$home_root" ]]; then
        log_info "Running $home_root ..."
        "$home_root" && log_done "root.sh completed" || log_warn "root.sh error"
    else
        log_warn "root.sh not found — installer may not have completed."
    fi
    log_done "Software installation finished."
}

# =============================================================================
# SUMMARY
# =============================================================================
print_summary() {
    log_section "COMPLETED"
    echo -e "${GREEN}${BOLD}"
    echo "  ✔ All-in-one setup completed!"
    echo -e "${NC}"
    echo "  The Oracle software is installed and the oracle environment is ready."
    echo ""
    echo "  Next: create the database (interactive, as oracle):"
    echo "    su - oracle"
    echo "    lsnrctl start"
    echo "    dbca"
    echo ""
    echo -e "  Full log: ${BOLD}${LOGFILE}${NC}"
    echo ""
}

# =============================================================================
# FULL SETUP + INSTALL (option 1)
# =============================================================================
do_full_setup() {
    check_root
    collect_inputs

    setup_hostname
    setup_kernel_params
    setup_limits
    install_packages
    setup_user
    setup_selinux_firewall
    setup_directories
    setup_environment
    install_software
    print_summary
}

# =============================================================================
# START — database + listener (option 2)
# =============================================================================
do_start() {
    log_section "Start Database and Listener"
    if [[ -z "${ORACLE_HOME:-}" || -z "${ORACLE_SID:-}" ]]; then
        log_error "ORACLE_HOME/ORACLE_SID not set. Run as oracle: su - oracle"
        return 1
    fi
    log_info "Starting listener..."
    lsnrctl start && log_done "Listener started" || log_warn "Listener may already be running"
    log_info "Starting database instance ${ORACLE_SID}..."
    sqlplus -s / as sysdba << 'EOF'
startup;
exit;
EOF
    log_done "Database start command issued"
}

# =============================================================================
# STOP — database + listener (option 2)
# =============================================================================
do_stop() {
    log_section "Stop Database and Listener"
    if [[ -z "${ORACLE_HOME:-}" || -z "${ORACLE_SID:-}" ]]; then
        log_error "ORACLE_HOME/ORACLE_SID not set. Run as oracle: su - oracle"
        return 1
    fi
    log_info "Stopping database instance ${ORACLE_SID}..."
    sqlplus -s / as sysdba << 'EOF'
shutdown immediate;
exit;
EOF
    log_done "Database stop command issued"
    log_info "Stopping listener..."
    lsnrctl stop && log_done "Listener stopped" || log_warn "Listener may already be stopped"
}

# =============================================================================
# LISTENER HELPER — common and advanced lsnrctl commands (option 3)
# =============================================================================
do_listener() {
    log_section "Listener Helper (lsnrctl)"
    echo -e "  ${BOLD}Common${NC}"
    echo "    1 = status         Show listener state, port, and registered services"
    echo "    2 = services       List databases currently served by the listener"
    echo "    3 = reload         Re-read listener.ora without a restart"
    echo "    4 = start          Start the listener"
    echo "    5 = stop           Stop the listener"
    echo ""
    echo -e "  ${BOLD}Advanced${NC}"
    echo "    6 = version        Show listener version"
    echo "    7 = show log_file  Print the path of the listener log file"
    echo "    8 = set log on     Enable listener logging"
    echo "    9 = set log off    Disable listener logging"
    echo "   10 = trace admin    Set trace level to admin (verbose diagnostics)"
    echo "   11 = trace off      Turn tracing off"
    echo ""
    ask LCHOICE "Select option" ""
    case "$LCHOICE" in
        1)  lsnrctl status ;;
        2)  lsnrctl services ;;
        3)  lsnrctl reload ;;
        4)  lsnrctl start ;;
        5)  lsnrctl stop ;;
        6)  lsnrctl version ;;
        7)  lsnrctl show log_file ;;
        8)  lsnrctl set log_status on ;;
        9)  lsnrctl set log_status off ;;
        10) lsnrctl set trc_level admin ;;
        11) lsnrctl set trc_level off ;;
        *)  log_error "Unknown command: $LCHOICE" ;;
    esac
}


# =============================================================================
# UNINSTALL — full clean (option 3)
# =============================================================================
do_uninstall() {
    check_root
    log_section "Uninstall Oracle (Full Clean)"

    local ora_sid ora_home ora_base ora_inv
    local errors=0

    # --- Auto-detect từ /etc/oratab ---
    if [[ -f /etc/oratab ]]; then
        local oratab_entry
        oratab_entry=$(grep -v "^#" /etc/oratab | grep -v "^$" | head -1)
        ora_sid=$(echo  "$oratab_entry" | cut -d: -f1)
        ora_home=$(echo "$oratab_entry" | cut -d: -f2)
        log_info "Detected from /etc/oratab   → SID=$ora_sid  HOME=$ora_home"
    else
        log_warn "/etc/oratab not found"
        (( errors++ ))
    fi

    # --- Auto-detect oraInventory từ /etc/oraInst.loc ---
    if [[ -f /etc/oraInst.loc ]]; then
        ora_inv=$(grep "^inventory_loc=" /etc/oraInst.loc | cut -d= -f2)
        log_info "Detected from /etc/oraInst.loc → inventory=$ora_inv"
    else
        log_warn "/etc/oraInst.loc not found — will skip oraInventory removal"
        ora_inv=""
    fi

    # --- Tính ORACLE_BASE từ ORACLE_HOME ---
    if [[ -n "$ora_home" ]]; then
        ora_base=$(echo "$ora_home" | sed 's|/product/.*||')
        log_info "Derived ORACLE_BASE          → $ora_base"
    fi

    # --- Không detect được thì dừng ---
    if [[ -z "$ora_home" || -z "$ora_sid" ]]; then
        log_error "Could not detect Oracle installation. Is Oracle installed?"
        log_error "Expected: /etc/oratab with entry SID:ORACLE_HOME:Y"
        return 1
    fi

    # --- Hiển thị những gì sẽ bị xóa ---
    echo ""
    log_warn "WARNING — this will permanently remove ALL of the following:"
    echo "     • ORACLE_SID          : $ora_sid"
    echo "     • ORACLE_HOME         : $ora_home"
    echo "     • ORACLE_BASE         : $ora_base"
    [[ -n "$ora_inv" ]] && \
    echo "     • oraInventory        : $ora_inv"
    echo "     • Data files          : $ora_base/oradata"
    echo "     • oracle user & groups: oracle, oinstall, dba, oper"
    echo "     • sysctl + limits files"
    echo ""
    ask CONFIRM "Confirm full uninstall? (y/n)" "n"
    [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && { log_warn "Uninstall cancelled."; return 0; }

    # --- 1. Dừng DB + listener ---
    log_info "Stopping database and listener..."
    su - oracle -c "
        export ORACLE_HOME=$ora_home
        export ORACLE_SID=$ora_sid
        export PATH=\$ORACLE_HOME/bin:\$PATH
        lsnrctl stop 2>/dev/null || true
        echo shutdown abort | sqlplus -s / as sysdba 2>/dev/null || true
    " 2>/dev/null || true
    log_done "Database and listener stopped"

    # --- 2. Xóa systemd services ---
    log_info "Removing Oracle systemd services..."
    for svc in $(systemctl list-units --type=service --all 2>/dev/null | grep -i oracle | awk '{print $1}'); do
        systemctl stop    "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
        rm -f "/etc/systemd/system/$svc"
    done
    systemctl daemon-reload 2>/dev/null || true
    log_done "Systemd services removed"

    # --- 3. Xóa ORACLE_HOME ---
    log_info "Removing ORACLE_HOME: $ora_home ..."
    rm -rf "$ora_home"
    log_done "ORACLE_HOME removed"

    # --- 4. Xóa oraInventory ---
    if [[ -n "$ora_inv" ]]; then
        log_info "Removing oraInventory: $ora_inv ..."
        rm -rf "$ora_inv"
        log_done "oraInventory removed"
    fi
    rm -f /etc/oraInst.loc

    # --- 5. Xóa data files ---
    log_info "Removing data files..."
    rm -rf "${ora_base}/oradata" "${ora_base}/fast_recovery_area" \
           "${ora_base}/admin"   "${ora_base}/diag"
    log_done "Data files removed"

    # --- 6. Xóa oracle user & groups ---
    log_info "Removing oracle user and groups..."
    userdel -r oracle 2>/dev/null || true
    groupdel oinstall 2>/dev/null || true
    groupdel dba      2>/dev/null || true
    groupdel oper     2>/dev/null || true
    log_done "oracle user and groups removed"

    # --- 7. Dọn sysctl + limits ---
    log_info "Cleaning kernel parameters..."
    sed -i "/# Oracle Database - added by oracle_setup_all.sh/,/^$/d" /etc/sysctl.conf
    sysctl --system > /dev/null 2>&1 || true
    rm -f /etc/security/limits.d/oracle-database-preinstall.conf
    rm -f /etc/oratab
    log_done "sysctl and limits files cleaned"

    log_section "Uninstall complete"
}

# =============================================================================
# CREATE DATABASE — silent dbca (option 4)
# =============================================================================
do_create_db() {
    log_section "Create Database (silent dbca)"

    if [[ "$(whoami)" != "oracle" ]]; then
        log_error "This option must be run as oracle user: su - oracle"
        return 1
    fi
    if [[ -z "${ORACLE_HOME:-}" || -z "${ORACLE_SID:-}" ]]; then
        log_error "ORACLE_HOME/ORACLE_SID not set. Check ~/.bash_profile"
        return 1
    fi

    # DB_NAME / DB_UNIQUE_NAME must match Install
    local db_name="${ORACLE_SID}"
    local db_unqname="${ORACLE_UNQNAME:-$ORACLE_SID}"
    log_info "DB_NAME        = $db_name  (from ORACLE_SID in ~/.bash_profile)"
    log_info "DB_UNIQUE_NAME = $db_unqname  (from ORACLE_UNQNAME in ~/.bash_profile)"

    local ram_kb ram_mb default_mem
    ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    ram_mb=$(( ram_kb / 1024 ))
    default_mem=$(( ram_mb * 40 / 100 ))

    echo ""
    echo -e "${BOLD}  [ Database Configuration ]${NC}"
    ask_required PDB      "PDB_NAME (application database)  "
    ask CHARSET   "CHARACTER_SET                    # default: Unicode UTF-8" "AL32UTF8"
    ask NCHARSET  "NATIONAL_CHARACTER_SET           # default: Unicode UTF-16" "AL16UTF16"
    ask MEM_MB    "Total memory for Oracle (MB)     # default: 40% OS RAM" "${default_mem}"
    ask DATA_DEST "Data file destination            # default: ORACLE_BASE/oradata" "${ORACLE_BASE}/oradata"
    ask RECO_DEST "Recovery area destination        # default: ORACLE_BASE/fast_recovery_area" "${ORACLE_BASE}/fast_recovery_area"

    echo ""
    echo -e "${BOLD}  [ APP_DATA Tablespace ]${NC}"
    echo    "  # AUTOEXTEND_NEXT: size Oracle adds each time the tablespace runs full"
    ask TS_NEXT   "Autoextend increment (MB)        # default: 100MB per extension" "100"
    echo    "  # MAX_SIZE: hard limit to prevent Oracle from consuming all disk"
    ask TS_MAX    "Max tablespace size (GB)         # default: 10GB hard limit" "10"

    echo ""
    echo -e "${BOLD}  [ Schema Owner ]${NC}"
    ask_required DB_USER "Username (schema owner)          "
    read -rsp "  Password        : " DB_PWD; echo

    echo ""
    echo -e "${BOLD}  [ CDB Passwords ]${NC}"
    read -rsp "  SYS password    : " SYS_PWD;    echo
    read -rsp "  SYSTEM password : " SYSTEM_PWD; echo

    # --- Detect CDB exists → chọn đúng flow ---
    local cdb_exists=false
    if pgrep -f "ora_pmon_${db_name}" > /dev/null 2>&1; then
        cdb_exists=true
        log_info "CDB '$db_name' is already running → will add PDB only"
    elif grep -q "^${db_name}:" /etc/oratab 2>/dev/null; then
        cdb_exists=true
        log_info "CDB '$db_name' found in /etc/oratab but not running → starting instance..."
        sqlplus -s / as sysdba << EOF
STARTUP;
EXIT;
EOF
        if ! pgrep -f "ora_pmon_${db_name}" > /dev/null 2>&1; then
            log_error "Failed to start Oracle instance '$db_name'"
            return 1
        fi
        log_done "Instance '$db_name' started"
    else
        log_info "No existing CDB found → will create CDB + PDB"
    fi

    if $cdb_exists; then
        # --- CDB đã tồn tại: chỉ tạo PDB ---
        log_info "Detecting pdbseed datafile path..."
        local pdbseed_dir
        pdbseed_dir=$(find "${DATA_DEST}" -type d -name "pdbseed" 2>/dev/null | head -1)
        if [[ -z "$pdbseed_dir" ]]; then
            # Fallback: tìm rộng hơn
            pdbseed_dir=$(find / -type d -name "pdbseed" 2>/dev/null | grep -v proc | head -1)
        fi
        if [[ -z "$pdbseed_dir" ]]; then
            log_error "Could not find pdbseed directory under ${DATA_DEST}"
            log_error "Check: find ${DATA_DEST} -type d -name pdbseed"
            return 1
        fi
        pdbseed_dir="${pdbseed_dir}/"
        log_info "pdbseed path: $pdbseed_dir"

        log_info "Adding PDB '$PDB' to existing CDB '$db_name'..."
        sqlplus -s / as sysdba << EOF
WHENEVER SQLERROR EXIT SQL.SQLCODE

CREATE PLUGGABLE DATABASE ${PDB}
  ADMIN USER pdbadmin IDENTIFIED BY "${SYS_PWD}"
  FILE_NAME_CONVERT=('${pdbseed_dir}', '${DATA_DEST}/${PDB}/');

ALTER PLUGGABLE DATABASE ${PDB} OPEN;
ALTER PLUGGABLE DATABASE ${PDB} SAVE STATE;

EXIT;
EOF
        local pdb_rc=$?
        if [[ $pdb_rc -ne 0 ]]; then
            log_error "Failed to create PDB '$PDB' (rc=$pdb_rc)"
            return 1
        fi
        log_done "PDB $PDB created and opened"
    else
        # --- CDB chưa tồn tại: tạo CDB + PDB bằng dbca ---
        local rsp="/tmp/dbca_${db_name}.rsp"
        cat > "$rsp" << RSPEOF
responseFileVersion=/oracle/assistants/rspfmt_dbca_response_schema_v19.0.0
gdbName=${db_name}
sid=${ORACLE_SID}
databaseConfigType=SI
createAsContainerDatabase=true
numberOfPDBs=1
pdbName=${PDB}
useLocalUndoForPDBs=true
templateName=General_Purpose.dbc
sysPassword=${SYS_PWD}
systemPassword=${SYSTEM_PWD}
datafileDestination=${DATA_DEST}
recoveryAreaDestination=${RECO_DEST}
storageType=FS
characterSet=${CHARSET}
nationalCharacterSet=${NCHARSET}
totalMemory=${MEM_MB}
emConfiguration=NONE
RSPEOF

        log_info "Running silent dbca — CDB=$db_name | PDB=$PDB | Memory=${MEM_MB} MB"
        echo ""
        "${ORACLE_HOME}/bin/dbca" -silent -createDatabase -responseFile "$rsp" -ignorePreReqs 2>&1 | tee "/tmp/dbca_${db_name}.log"
        local rc=${PIPESTATUS[0]}
        rm -f "$rsp"

        if [[ $rc -ne 0 ]]; then
            log_error "dbca failed (rc=$rc). Check log: /tmp/dbca_${db_name}.log"
            return 1
        fi
        log_done "CDB $db_name + PDB $PDB created"

        # Open PDB + save state
        sqlplus -s / as sysdba << EOF
ALTER PLUGGABLE DATABASE ${PDB} OPEN;
ALTER PLUGGABLE DATABASE ${PDB} SAVE STATE;
EXIT;
EOF
    fi

    # --- Tạo directory cho PDB datafile ---
    log_info "Creating PDB data directory: ${DATA_DEST}/${PDB}..."
    mkdir -p "${DATA_DEST}/${PDB}"
    chown oracle:oinstall "${DATA_DEST}/${PDB}"
    log_done "Directory created"

    # --- Create APP_DATA tablespace + user via local connection ---
    log_info "Creating APP_DATA tablespace and user ${DB_USER} in PDB ${PDB}..."
    sqlplus -s / as sysdba << EOF
WHENEVER SQLERROR EXIT SQL.SQLCODE

ALTER SESSION SET CONTAINER=${PDB};
ALTER SESSION SET "_ORACLE_SCRIPT"=true;

CREATE TABLESPACE APP_DATA
  DATAFILE '${DATA_DEST}/${PDB}/app_data01.dbf'
  SIZE 500M
  AUTOEXTEND ON NEXT ${TS_NEXT}M MAXSIZE ${TS_MAX}G
  EXTENT MANAGEMENT LOCAL
  SEGMENT SPACE MANAGEMENT AUTO;

CREATE USER ${DB_USER} IDENTIFIED BY "${DB_PWD}"
  DEFAULT TABLESPACE APP_DATA
  TEMPORARY TABLESPACE TEMP
  QUOTA UNLIMITED ON APP_DATA;

GRANT CREATE SESSION TO ${DB_USER};
GRANT ALL PRIVILEGES TO ${DB_USER};

EXIT;
EOF
    local sql_rc=$?
    if [[ $sql_rc -ne 0 ]]; then
        log_error "Failed to create tablespace/user in PDB ${PDB} (rc=$sql_rc)"
        return 1
    fi

    log_section "Database $db_name created successfully"
    log_info "PDB              : $PDB"
    log_info "Schema owner     : $DB_USER"
    log_info "Tablespace       : APP_DATA (500MB, autoextend ${TS_NEXT}MB, max ${TS_MAX}GB)"
    local db_host
    db_host=$(cat /etc/hostname 2>/dev/null | tr -d ' \n\r')
    [[ -z "$db_host" ]] && db_host="localhost"

    log_section "Database $db_name created successfully"
    log_info "PDB              : $PDB"
    log_info "Schema owner     : $DB_USER"
    log_info "Tablespace       : APP_DATA (500MB, autoextend ${TS_NEXT}MB, max ${TS_MAX}GB)"
    echo ""
    echo -e "${BOLD}  [ Connection Strings ]${NC}"
    echo    "  Inside container : jdbc:oracle:thin:@//localhost:1521/${PDB}"
    echo    "  Docker host      : jdbc:oracle:thin:@//host.docker.internal:1521/${PDB}"
    echo    "  Hostname/IP      : jdbc:oracle:thin:@//${db_host}:1521/${PDB}"
    log_info "Log              : /tmp/dbca_${db_name}.log"
}

# =============================================================================
# ADD USER — create user in existing PDB with permission level (option 5)
# =============================================================================
do_add_user() {
    log_section "Add User to PDB"

    if [[ "$(whoami)" != "oracle" ]]; then
        log_error "This option must be run as oracle user: su - oracle"
        return 1
    fi
    if [[ -z "${ORACLE_HOME:-}" || -z "${ORACLE_SID:-}" ]]; then
        log_error "ORACLE_HOME/ORACLE_SID not set. Check ~/.bash_profile"
        return 1
    fi

    # List available PDBs
    log_info "Available PDBs:"
    sqlplus -s / as sysdba << 'EOF'
SET PAGESIZE 20 LINESIZE 60 FEEDBACK OFF HEADING OFF
SELECT '  - ' || NAME FROM V$PDBS WHERE NAME != 'PDB$SEED' ORDER BY NAME;
EXIT;
EOF

    echo ""
    echo -e "${BOLD}  [ User Configuration ]${NC}"
    ask_required TARGET_PDB "PDB name to add user to     "
    ask_required NEW_USER   "Username                    "
    read -rsp "  Password        : " NEW_PWD; echo

    echo ""
    echo -e "${BOLD}  [ Permission Level ]${NC}"
    echo    "  1. Full          — DBA role, all privileges"
    echo    "  2. Read/Write    — CONNECT, RESOURCE, UNLIMITED TABLESPACE"
    echo    "  3. Read Only     — CONNECT + SELECT ANY TABLE"
    ask PERM_LEVEL "Select option" "2"

    # --- Create user ---
    log_info "Creating user ${NEW_USER} in PDB ${TARGET_PDB}..."

    local grant_sql
    case "$PERM_LEVEL" in
        1) grant_sql="GRANT CONNECT, RESOURCE, DBA TO ${NEW_USER};
GRANT UNLIMITED TABLESPACE TO ${NEW_USER};" ;;
        2) grant_sql="GRANT CONNECT, RESOURCE TO ${NEW_USER};
GRANT UNLIMITED TABLESPACE TO ${NEW_USER};" ;;
        3) grant_sql="GRANT CONNECT TO ${NEW_USER};
GRANT SELECT ANY TABLE TO ${NEW_USER};" ;;
        *) log_error "Invalid choice: $PERM_LEVEL"; return 1 ;;
    esac

    sqlplus -s / as sysdba << EOF
ALTER SESSION SET CONTAINER=${TARGET_PDB};

CREATE USER ${NEW_USER} IDENTIFIED BY "${NEW_PWD}"
  DEFAULT TABLESPACE APP_DATA
  TEMPORARY TABLESPACE TEMP;

${grant_sql}

EXIT;
EOF

    log_done "User ${NEW_USER} created in PDB ${TARGET_PDB}"
    local db_host
    db_host=$(ip addr show 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1 | head -1)
    [[ -z "$db_host" ]] && db_host=$(cat /etc/hostname 2>/dev/null | tr -d ' \n\r')
    [[ -z "$db_host" ]] && db_host="localhost"
    log_info "Connect string : jdbc:oracle:thin:@//${db_host}:1521/${TARGET_PDB}"
}

# =============================================================================
# MAIN MENU
# =============================================================================
main() {
    LOGFILE="/tmp/oracle_setup_all_$(date +%Y%m%d_%H%M%S).log"
    exec > >(tee -a "$LOGFILE") 2>&1

    print_banner

    # Direct command-line dispatch (skip menu): ./oracle_setup_all.sh start
    case "${1:-}" in
        setup|install) do_full_setup;  exit $? ;;
        start)         do_start;       exit $? ;;
        stop)          do_stop;        exit $? ;;
        listener)      do_listener;    exit $? ;;
        uninstall)     do_uninstall;   exit $? ;;
        createdb)      do_create_db;   exit $? ;;
        adduser)       do_add_user;    exit $? ;;
    esac

    # Interactive menu
    log_section "Oracle Setup Menu"
    echo -e "  ${BOLD}1.${NC} Install           Full system prep + silent install  (root)"
    echo -e "  ${BOLD}2.${NC} Listener helper   Common and advanced lsnrctl commands (oracle)"
    echo -e "  ${BOLD}3.${NC} Uninstall         Full clean — remove all Oracle files  (root)"
    echo -e "  ${BOLD}4.${NC} Create Database   Silent dbca create new database        (oracle)"
    echo -e "  ${BOLD}5.${NC} Add User          Create user in existing PDB             (oracle)"
    echo ""
    ask CHOICE "Select option" "1"

    case "$CHOICE" in
        1) do_full_setup  ;;
        2) do_listener    ;;
        3) do_uninstall   ;;
        4) do_create_db   ;;
        5) do_add_user    ;;
        *) log_error "Unknown choice: $CHOICE" ;;
    esac
}

main "$@"
