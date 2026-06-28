#!/usr/bin/env bash
# =============================================================================
#  Spring Boot Application Starter  v1.1
# =============================================================================
#
#  Actions  : start | stop | restart | status
#  Services : user-defined (enter app name at runtime)
#  Profiles : prod | uat | sit | <custom>
#
#  Directory layout:
#
#    ROOT_DIR/                    <- application root  (script directory)
#    |- jar-ctl.sh               <- this script  (rename as you like)
#    |- lib/                     <- recommended location for JAR files
#    |   +- *.jar
#    +- env/                     <- recommended location for config files
#        +- *.conf               <- naming convention: {app}-{profile}.conf
#
#    /var/log/springboot/<service>/     <- runtime logs   (override: SB_LOG_DIR)
#       (managed entirely by Spring -- configure in application.yml or .conf)
#
#    /var/run/springboot/               <- PID files      (override: SB_RUN_DIR)
#    +- <service>.pid
#
#  Interactive usage:
#    ./jar-ctl.sh
#
#  Non-interactive / CI:
#    ./jar-ctl.sh -x start   -a <app>  -p <profile>
#    ./jar-ctl.sh -x stop    -a <app>
#    ./jar-ctl.sh -x restart -a <app>  -p <profile>
#    ./jar-ctl.sh -x status
#
#  File resolution:
#    JAR  : ask scan current dir [y/n] -> if no, enter folder -> scan *.jar  -> pick menu
#    CONF : ask scan current dir [y/n] -> if no, enter folder -> scan *.conf -> pick menu
#
#  Override paths:
#    export SB_LOG_DIR=/data/logs
#    export SB_RUN_DIR=/data/run
# =============================================================================

set -euo pipefail

# ─────────────────────────── Directory Layout ─────────────────────────────────
readonly BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR="$BIN_DIR"
readonly ENV_DIR="$ROOT_DIR/env"
readonly LIB_DIR="$ROOT_DIR/lib"

readonly LOGS_DIR="${SB_LOG_DIR:-/var/log/springboot}"
readonly RUN_DIR="${SB_RUN_DIR:-/var/run/springboot}"

readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly LOG_TIMESTAMP_FMT="%Y-%m-%d %H:%M:%S"
readonly JAVA_MIN_VERSION=11
readonly STOP_TIMEOUT=30

# ─────────────────────────── Color Codes ──────────────────────────────────────
if [[ -t 1 ]]; then
  C_RESET='\033[0m';   C_BOLD='\033[1m'
  C_RED='\033[0;31m';  C_GREEN='\033[0;32m'
  C_YELLOW='\033[1;33m'; C_CYAN='\033[0;36m'
  C_WHITE='\033[1;37m';  C_DIM='\033[2m'
  C_BLUE='\033[0;34m'
else
  C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''
  C_YELLOW=''; C_CYAN=''; C_WHITE=''; C_DIM=''; C_BLUE=''
fi

# ─────────────────────────── Logging ──────────────────────────────────────────
log()      { printf "${C_DIM}[%s]${C_RESET} ${C_WHITE}[INFO ]${C_RESET}  %s\n"  "$(date +"$LOG_TIMESTAMP_FMT")" "$*"; }
log_ok()   { printf "${C_DIM}[%s]${C_RESET} ${C_GREEN}[OK   ]${C_RESET}  %s\n"  "$(date +"$LOG_TIMESTAMP_FMT")" "$*"; }
log_warn() { printf "${C_DIM}[%s]${C_RESET} ${C_YELLOW}[WARN ]${C_RESET}  %s\n" "$(date +"$LOG_TIMESTAMP_FMT")" "$*" >&2; }
log_err()  { printf "${C_DIM}[%s]${C_RESET} ${C_RED}[ERROR]${C_RESET}  %s\n"    "$(date +"$LOG_TIMESTAMP_FMT")" "$*" >&2; }
log_step() { printf "\n${C_CYAN}${C_BOLD}==> %s${C_RESET}\n" "$*"; }
divider()  { printf "${C_DIM}%s${C_RESET}\n" "────────────────────────────────────────────────────────────"; }

# ─────────────────────────── Usage ────────────────────────────────────────────
print_usage() {
  cat <<EOF

${C_BOLD}Spring Boot Application Starter  v1.1${C_RESET}

${C_BOLD}USAGE${C_RESET}
  ./${SCRIPT_NAME} [OPTIONS]
  ./${SCRIPT_NAME}              (no args = fully interactive)

${C_BOLD}OPTIONS${C_RESET}
  -x <action>   Action      : start | stop | restart | status
  -a <app>      App name    : any string  (entered at runtime)
  -p <profile>  Profile     : prod | uat | sit | <custom>
  -c <path>     Conf file   : override scan  (default: scanned interactively)
  -j <path>     JAR file    : override scan  (default: scanned interactively)
  -h            Show this help

${C_BOLD}ACTIONS${C_RESET}
  start    Select app name -> profile -> pick .conf -> pick .jar -> launch
  stop     Select app name -> send SIGTERM -> wait ${STOP_TIMEOUT}s -> SIGKILL if needed
  restart  stop + start
  status   Show all running services (scanned from PID dir)

${C_BOLD}FILE RESOLUTION${C_RESET}
  JAR   Ask: scan current dir sub-folders? [y/n]
        If no  -> enter folder path -> scan that folder
        Result -> numbered pick menu (all *.jar found)

  CONF  Ask: scan current dir sub-folders? [y/n]
        If no  -> enter folder path -> scan that folder
        Result -> numbered pick menu (all *.conf found)

${C_BOLD}EXAMPLES${C_RESET}
  ./${SCRIPT_NAME}                               # interactive -- recommended
  ./${SCRIPT_NAME} -x start   -a payment-service -p prod
  ./${SCRIPT_NAME} -x stop    -a payment-service
  ./${SCRIPT_NAME} -x restart -a payment-service -p prod
  ./${SCRIPT_NAME} -x status

${C_BOLD}DIRECTORIES${C_RESET}
  App root : $ROOT_DIR
  Logs     : ${SB_LOG_DIR:-/var/log/springboot}   (override: export SB_LOG_DIR=<path>)
  PID dir  : ${SB_RUN_DIR:-/var/run/springboot}   (override: export SB_RUN_DIR=<path>)

${C_BOLD}JAR REQUIREMENTS${C_RESET}
  Must be a Spring Boot executable fat JAR (spring-boot-maven-plugin repackage).
  Validated checks: magic bytes (PK header) + Main-Class in MANIFEST.MF.
EOF
}

# ─────────────────────────── PID: File Helpers ────────────────────────────────
get_pid_filepath() { echo "$RUN_DIR/${1}.pid"; }

get_running_pid() {
  local svc="$1"
  local pf
  pf="$(get_pid_filepath "$svc")"
  if [[ -f "$pf" ]]; then
    local pid
    pid="$(cat "$pf")"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      echo "$pid"
      return
    fi
  fi
  echo ""
}

# ─────────────────────────── Service: Status Board ────────────────────────────
render_status_board() {
  echo ""
  local found=0
  local pid_file name pid
  for pid_file in "$RUN_DIR"/*.pid; do
    [[ -f "$pid_file" ]] || continue
    name="$(basename "$pid_file" .pid)"
    pid="$(get_running_pid "$name")"
    if [[ -n "$pid" ]]; then
      printf "  ${C_GREEN}●${C_RESET} %-20s ${C_GREEN}RUNNING${C_RESET}   PID %s\n" "$name" "$pid"
    else
      printf "  ${C_DIM}○${C_RESET} %-20s ${C_DIM}STOPPED${C_RESET}\n" "$name"
    fi
    found=1
  done
  [[ "$found" -eq 0 ]] && printf "  ${C_DIM}○  no services found${C_RESET}\n"
  echo ""
}

# ─────────────────────────── Directory: Initialization ────────────────────────
initialize_directories() {
  log_step "Directory Layout"

  local app_dir
  for app_dir in "$ENV_DIR" "$LIB_DIR"; do
    if [[ -d "$app_dir" ]]; then
      log "  app   OK      ${app_dir#$ROOT_DIR/}"
    else
      log_warn "  app   MISSING ${app_dir#$ROOT_DIR/}  -- creating"
      mkdir -p "$app_dir"
    fi
  done

  local -A runtime_map=( ["logs"]="$LOGS_DIR" ["run"]="$RUN_DIR" )
  local key
  for key in logs run; do
    local target="${runtime_map[$key]}"
    if [[ -d "$target" ]] && [[ -w "$target" ]]; then
      log "  run   OK      $target"
    elif mkdir -p "$target" 2>/dev/null; then
      log_ok "  run   created $target"
    else
      local fallback="$ROOT_DIR/var/$key"
      log_warn "  run   DENIED  $target"
      log_warn "  run   fallback -> $fallback"
      log_warn "  (set SB_LOG_DIR / SB_RUN_DIR to override system paths)"
      mkdir -p "$fallback"
      if [[ "$key" == "logs" ]]; then LOGS_DIR="$fallback"
      else                           RUN_DIR="$fallback"
      fi
    fi
  done

  echo ""
  log "  App root : $ROOT_DIR"
  log "  Logs     : $LOGS_DIR"
  log "  PID dir  : $RUN_DIR"
}

# ─────────────────────────── Pre-flight: Java Runtime Check ───────────────────
verify_java_runtime() {
  log_step "Pre-flight Check -- Java Runtime"

  if ! command -v java &>/dev/null; then
    log_err "Java executable not found in PATH. Install Java $JAVA_MIN_VERSION+ first."
    exit 1
  fi

  local java_path version_string major_version
  java_path="$(command -v java)"
  version_string="$(java -version 2>&1 | head -1)"
  log "Java binary    : $java_path"
  log "Version string : $version_string"

  major_version="$(java -version 2>&1 \
    | grep -oE '"[0-9]+\.[0-9]+' | head -1 | tr -d '"' \
    | awk -F'.' '{ if ($1=="1") print $2; else print $1 }')"

  if [[ -z "$major_version" ]]; then
    log_warn "Could not parse Java version -- proceeding with caution."
    return
  fi

  log "Major version  : $major_version"

  if (( major_version < JAVA_MIN_VERSION )); then
    log_err "Java $major_version detected -- Java $JAVA_MIN_VERSION+ is required."
    exit 1
  fi

  log_ok "Java $major_version satisfies requirement (Java $JAVA_MIN_VERSION+)."
  [[ -n "${JAVA_HOME:-}" ]] \
    && log "JAVA_HOME      : $JAVA_HOME" \
    || log_warn "JAVA_HOME not set -- using system PATH java."
}

# ─────────────────────────── Action: Interactive Selection ────────────────────
prompt_action() {
  log_step "Select Action"
  render_status_board

  printf "  ${C_GREEN}[1]${C_RESET}  start    -- Start a service\n"
  printf "  ${C_GREEN}[2]${C_RESET}  stop     -- Stop a running service\n"
  printf "  ${C_GREEN}[3]${C_RESET}  restart  -- Stop then start a service\n"
  printf "  ${C_GREEN}[4]${C_RESET}  status   -- Show service status and exit\n"
  echo ""
  divider

  local choice
  while true; do
    printf "  Select option [1-4]: "
    read -r choice
    case "$choice" in
      1) ACTION="start";   break ;;
      2) ACTION="stop";    break ;;
      3) ACTION="restart"; break ;;
      4) ACTION="status";  break ;;
      *) log_warn "Invalid selection. Enter 1, 2, 3, or 4." ;;
    esac
  done

  log_ok "Action: $ACTION"
}

# ─────────────────────────── Service: Interactive Selection ───────────────────
prompt_service() {
  local action_label="${1:-}"
  log_step "Select Service  [$action_label]"
  render_status_board

  while true; do
    printf "  Enter app name: "
    read -r APP_NAME
    [[ -n "$APP_NAME" ]] && break
    log_warn "App name cannot be empty."
  done

  log_ok "Service: $APP_NAME"
}

# ─────────────────────────── Profile: Interactive Selection ───────────────────
prompt_spring_profile() {
  log_step "Select Spring Profile"

  while true; do
    printf "  Enter profile name: "
    read -r SPRING_PROFILE
    [[ -n "$SPRING_PROFILE" ]] && break
    log_warn "Profile name cannot be empty."
  done

  log_ok "Spring profile: $SPRING_PROFILE"
}

# ─────────────────────────── Conf: Ask Scan Directory ─────────────────────────
# Asks whether to scan the script's directory or a user-supplied folder.
# Returns the chosen scan directory in the variable named by $1.
ask_scan_dir() {
  local -n _result_dir=$1
  local _label="$2"

  local yn
  while true; do
    printf "  Scan sub-folders of ${C_BOLD}%s${C_RESET} (script dir)? [y/n]: " "$(basename "$BIN_DIR")"
    read -r yn
    case "$yn" in
      [Yy]) _result_dir="$BIN_DIR"; break ;;
      [Nn]) break ;;
      *) log_warn "Please enter y or n." ;;
    esac
  done

  if [[ "$yn" =~ ^[Nn]$ ]]; then
    while true; do
      printf "  Enter folder path containing %s files: " "$_label"
      read -r _result_dir
      _result_dir="${_result_dir/#\~/$HOME}"
      if [[ -z "$_result_dir" ]]; then
        log_warn "Path cannot be empty."
      elif [[ ! -d "$_result_dir" ]]; then
        log_warn "Directory not found: $_result_dir"
      else
        break
      fi
    done
  fi
}

# ─────────────────────────── Conf: Render Numbered Pick Menu ──────────────────
# Renders a numbered table of .conf files; sets ENV_FILE on selection.
render_conf_pick_menu() {
  local -n _conf_list=$1
  local _scan_dir="${2:-$BIN_DIR}"
  local idx=1
  declare -A _conf_map

  printf "  ${C_BOLD}%-4s  %-12s  %s${C_RESET}\n" "No." "Modified" "Path"
  printf "  %-4s  %-12s  %s\n" "---" "------------" "------------------------------------------------------"

  local f
  for f in "${_conf_list[@]}"; do
    local mtime rel
    mtime="$(date -r "$f" "+%Y-%m-%d" 2>/dev/null || echo "?")"
    rel="${f#${_scan_dir}/}"
    printf "  ${C_GREEN}[%s]${C_RESET}  %-12s  %s\n" "$idx" "$mtime" "$rel"
    _conf_map[$idx]="$f"
    (( idx++ ))
  done
  echo ""
  divider

  local choice
  while true; do
    printf "  Select option [1-%s]: " "$(( idx - 1 ))"
    read -r choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < idx )); then
      ENV_FILE="${_conf_map[$choice]}"
      return 0
    else
      log_warn "Invalid selection. Enter 1-$(( idx - 1 ))."
    fi
  done
}

# ─────────────────────────── Conf: Interactive Resolution ─────────────────────
# Asks scan dir preference, scans all *.conf, shows pick menu.
# Falls back to manual path input if no files found.
resolve_conf_interactive() {
  log_step "Select Config File"

  local scan_dir
  ask_scan_dir scan_dir ".conf"
  log "Scanning: $scan_dir  (pattern: *.conf, maxdepth 6)"

  local found_confs=()
  while IFS= read -r -d '' f; do
    found_confs+=("$f")
  done < <(find "$scan_dir" -maxdepth 6 -name "*.conf" -print0 2>/dev/null | sort -z)

  echo ""
  divider
  echo ""

  if [[ "${#found_confs[@]}" -gt 0 ]]; then
    log_ok "Found ${#found_confs[@]} .conf file(s)."
    echo ""
    render_conf_pick_menu found_confs "$scan_dir"
    log_ok "Conf file selected: $ENV_FILE"
    return
  fi

  # No files found -- fall back to manual input
  log_warn "No .conf files found under: $scan_dir"
  while true; do
    printf "  Enter full path to .conf file: "
    read -r ENV_FILE
    ENV_FILE="${ENV_FILE/#\~/$HOME}"
    if [[ -z "$ENV_FILE" ]];   then log_warn "Path cannot be empty."
    elif [[ ! -f "$ENV_FILE" ]]; then log_warn "File not found: $ENV_FILE"
    else break
    fi
  done

  log_ok "Conf file selected: $ENV_FILE"
}

# ─────────────────────────── JAR: Render Numbered Pick Menu ───────────────────
# Renders a numbered table of JAR files; sets JAR_FILE on selection.
render_jar_pick_menu() {
  local -n _jar_list=$1
  local _scan_dir="${2:-$BIN_DIR}"
  local idx=1
  declare -A _jar_map

  printf "  ${C_BOLD}%-4s  %-10s  %-12s  %s${C_RESET}\n" "No." "Size" "Modified" "Path"
  printf "  %-4s  %-10s  %-12s  %s\n" \
    "---" "----------" "------------" "------------------------------------------------------"

  local f
  for f in "${_jar_list[@]}"; do
    local size mtime rel
    size="$(du -sh "$f" 2>/dev/null | cut -f1)"
    mtime="$(date -r "$f" "+%Y-%m-%d" 2>/dev/null || echo "?")"
    rel="${f#${_scan_dir}/}"
    printf "  ${C_GREEN}[%s]${C_RESET}  %-10s  %-12s  %s\n" "$idx" "$size" "$mtime" "$rel"
    _jar_map[$idx]="$f"
    (( idx++ ))
  done
  echo ""
  divider

  local choice
  while true; do
    printf "  Select option [1-%s]: " "$(( idx - 1 ))"
    read -r choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < idx )); then
      JAR_FILE="${_jar_map[$choice]}"
      return 0
    else
      log_warn "Invalid selection. Enter 1-$(( idx - 1 ))."
    fi
  done
}

# ─────────────────────────── JAR: Interactive Resolution ──────────────────────
# Asks scan dir preference, scans all *.jar, shows pick menu.
# Falls back to manual path input if no files found.
resolve_jar_interactive() {
  log_step "Select JAR File"

  local scan_dir
  ask_scan_dir scan_dir "JAR"
  log "Scanning: $scan_dir  (pattern: *.jar, maxdepth 6)"

  local found_jars=()
  while IFS= read -r -d '' f; do
    found_jars+=("$f")
  done < <(find "$scan_dir" -maxdepth 6 -name "*.jar" -print0 2>/dev/null | sort -Vz)

  echo ""
  divider
  echo ""

  if [[ "${#found_jars[@]}" -gt 0 ]]; then
    log_ok "Found ${#found_jars[@]} JAR file(s)."
    echo ""
    render_jar_pick_menu found_jars "$scan_dir"
    log_ok "JAR selected: $JAR_FILE"
    return
  fi

  # No files found -- fall back to manual input
  log_warn "No JAR files found under: $scan_dir"
  while true; do
    printf "  Enter full path to JAR file: "
    read -r JAR_FILE
    JAR_FILE="${JAR_FILE/#\~/$HOME}"
    if [[ -z "$JAR_FILE" ]];   then log_warn "Path cannot be empty."
    elif [[ ! -f "$JAR_FILE" ]]; then log_warn "File not found: $JAR_FILE"
    else break
    fi
  done

  log_ok "JAR selected: $JAR_FILE"
}

# ─────────────────────────── Conf: Load and Export Variables ──────────────────
load_env_config() {
  log_step "Loading Config File"
  log "Source: $ENV_FILE"

  [[ -f "$ENV_FILE" ]] || { log_err "Config file not found: $ENV_FILE"; exit 1; }

  # Strip Windows line endings (\r) -- file edited on Windows causes values
  # to include \r, e.g. "60s\r" which breaks Spring Duration parsing.
  if grep -qP '\r' "$ENV_FILE" 2>/dev/null; then
    log_warn "Windows line endings (CRLF) detected -- stripping \\r from $ENV_FILE"
    sed -i 's/\r//' "$ENV_FILE"
    log_ok "Line endings converted to LF."
  fi

  local line_count
  line_count="$(grep -cE '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE" 2>/dev/null || echo 0)"

  # set -a: auto-export all assignments so the Java process inherits them.
  set -a
  set +u
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
  set -u

  log_ok "$line_count variable(s) loaded from $(basename "$ENV_FILE")."
  log "  SERVER_PORT              = ${SERVER_PORT:-<not set>}"
  log "  SERVER_CONTEXT_PATH      = ${SERVER_CONTEXT_PATH:-<not set>}"
  log "  DB_URL                   = ${DB_URL:+**** (set)}${DB_URL:-<not set>}"
  log "  SERVLET_SESSION_TIMEOUT  = ${SERVLET_SESSION_TIMEOUT:-<not set>}"
}

# ─────────────────────────── JAR: Artifact Validation ─────────────────────────
validate_jar_artifact() {
  log_step "Validating JAR Artifact"

  [[ -f "$JAR_FILE" ]] || { log_err "JAR file not found: $JAR_FILE"; exit 1; }

  # Magic bytes -- JAR/ZIP files start with PK (0x504b0304)
  local magic
  magic="$(od -An -tx1 -N4 "$JAR_FILE" 2>/dev/null | tr -d ' \n')"
  if [[ "$magic" != "504b0304" ]]; then
    log_err "Not a valid JAR file (bad magic bytes: $magic) -- expected ZIP/PK header."
    log_err "Path: $JAR_FILE"
    exit 1
  fi

  local jar_size
  jar_size="$(du -sh "$JAR_FILE" | cut -f1)"
  log_ok "JAR magic bytes OK -- $(basename "$JAR_FILE")  [$jar_size]"

  # Verify MANIFEST.MF and Main-Class
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  (cd "$tmp_dir" && jar xf "$JAR_FILE" META-INF/MANIFEST.MF 2>/dev/null)

  local manifest="$tmp_dir/META-INF/MANIFEST.MF"
  if [[ ! -f "$manifest" ]]; then
    rm -rf "$tmp_dir"
    log_err "META-INF/MANIFEST.MF not found in JAR -- not a valid executable JAR."
    exit 1
  fi

  local main_class
  main_class="$(grep -i '^Main-Class:' "$manifest" | awk '{print $2}' | tr -d '\r')"
  rm -rf "$tmp_dir"

  if [[ -z "$main_class" ]]; then
    log_err "No Main-Class in MANIFEST.MF -- JAR is not a Spring Boot executable JAR."
    log_err "Fix: ensure the spring-boot-maven-plugin repackage goal ran at build time."
    exit 1
  fi
  log_ok "Main-Class : $main_class"

  if jar tf "$JAR_FILE" 2>/dev/null | grep -q "application.yml"; then
    log_ok "application.yml found inside JAR -- Spring Boot fat JAR confirmed."
  else
    log_warn "application.yml not detected -- verify your build artifact."
  fi
}

# ─────────────────────────── ACTION: status ───────────────────────────────────
action_status() {
  log_step "Service Status"

  local found=0
  local pid_file name pid
  for pid_file in "$RUN_DIR"/*.pid; do
    [[ -f "$pid_file" ]] || continue
    name="$(basename "$pid_file" .pid)"
    pid="$(get_running_pid "$name")"
    found=1

    if [[ -n "$pid" ]]; then
      local uptime=""
      if [[ -f "/proc/$pid/stat" ]]; then
        local start_ticks btime hz elapsed
        start_ticks="$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || echo 0)"
        btime="$(grep btime /proc/stat 2>/dev/null | awk '{print $2}' || echo 0)"
        hz="$(getconf CLK_TCK 2>/dev/null || echo 100)"
        elapsed=$(( $(date +%s) - btime - start_ticks / hz ))
        if (( elapsed >= 3600 )); then
          uptime="  uptime $(( elapsed/3600 ))h $(( elapsed%3600/60 ))m"
        else
          uptime="  uptime $(( elapsed/60 ))m $(( elapsed%60 ))s"
        fi
      fi
      printf "  ${C_GREEN}● RUNNING${C_RESET}  %-22s  PID %s%s\n" "$name" "$pid" "${uptime}"
    else
      printf "  ${C_DIM}○ STOPPED${C_RESET}  %-22s  (stale PID file)\n" "$name"
    fi
  done

  [[ "$found" -eq 0 ]] && log "No services found in $RUN_DIR"
  echo ""
}

# ─────────────────────────── ACTION: stop ─────────────────────────────────────
action_stop() {
  log_step "Stopping Service -- $APP_NAME"

  local pf
  pf="$(get_pid_filepath "$APP_NAME")"
  local pid
  pid="$(get_running_pid "$APP_NAME")"

  if [[ -z "$pid" ]]; then
    log_warn "$APP_NAME is not running (no active PID found)."
    [[ -f "$pf" ]] && rm -f "$pf" && log "Removed stale PID file."
    return 0
  fi

  log "Sending SIGTERM to $APP_NAME (PID $pid) ..."
  kill -SIGTERM "$pid" 2>/dev/null || true

  local elapsed=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( elapsed >= STOP_TIMEOUT )); then
      log_warn "Process did not exit within ${STOP_TIMEOUT}s -- sending SIGKILL."
      kill -SIGKILL "$pid" 2>/dev/null || true
      sleep 1
      break
    fi
    printf "  ${C_DIM}waiting for shutdown ... %ds${C_RESET}\r" "$elapsed"
    sleep 1
    (( elapsed++ ))
  done

  echo ""
  rm -f "$pf"
  log_ok "$APP_NAME stopped successfully."
}

# ─────────────────────────── ACTION: start ────────────────────────────────────
action_start() {
  log_step "Starting Service -- $APP_NAME"

  local pf
  pf="$(get_pid_filepath "$APP_NAME")"
  local running_pid
  running_pid="$(get_running_pid "$APP_NAME")"

  if [[ -n "$running_pid" ]]; then
    log_err "$APP_NAME is already running (PID $running_pid)."
    log_err "Use 'restart' to restart it, or 'stop' to stop it first."
    exit 1
  fi

  [[ -f "$pf" ]] && rm -f "$pf"

  # Resolve .conf
  [[ -z "${ENV_FILE:-}" ]] && resolve_conf_interactive

  # Resolve JAR
  [[ -z "${JAR_FILE:-}" ]] && resolve_jar_interactive

  load_env_config
  validate_jar_artifact

  # Launch summary
  echo ""
  divider
  printf "  ${C_BOLD}${C_WHITE}LAUNCH SUMMARY${C_RESET}\n"
  divider
  printf "  %-24s %s\n" "Root dir:"       "$ROOT_DIR"
  printf "  %-24s %s\n" "Service:"        "$APP_NAME"
  printf "  %-24s %s\n" "Spring profile:" "$SPRING_PROFILE"
  printf "  %-24s %s\n" "Conf file:"      "$(basename "$ENV_FILE")"
  printf "  %-24s %s\n" "JAR:"            "$(basename "$JAR_FILE")"
  printf "  %-24s %s\n" "Server port:"    "${SERVER_PORT:-<from application.yml>}"
  printf "  %-24s %s\n" "PID file:"       "$pf"
  divider
  echo ""

  local jvm_opts="-server -Xms256m -Xmx512m -XX:+UseG1GC"
  jvm_opts+=" -Djava.security.egd=file:/dev/./urandom -Dfile.encoding=UTF-8"
  local app_args="--spring.profiles.active=${SPRING_PROFILE}"

  log "JVM options : $jvm_opts"
  log "App args    : $app_args"
  echo ""

  # Redirect stdout+stderr to a startup log so operator can watch the boot sequence.
  # This file captures Spring's console output until the operator detaches (Ctrl+C).
  # Spring's own file log (if configured in application.yml) is separate and unaffected.
  local startup_log
  startup_log="$(mktemp /tmp/${APP_NAME}-startup-XXXXXX.log)"

  java $jvm_opts \
    -jar "$JAR_FILE" \
    $app_args \
    >> "$startup_log" 2>&1 &

  local app_pid=$!
  echo "$app_pid" > "$pf"

  log "Starting $APP_NAME (PID $app_pid) ..."
  log "Startup log : $startup_log"
  echo ""

  # Tail log immediately so operator sees Spring output in real time
  tail -f "$startup_log" &
  local tail_pid=$!

  # Monitor process health for 10s -- catch early failures
  # (port conflict, bad bean, missing config typically exit within seconds)
  local wait=0
  while (( wait < 10 )); do
    sleep 1
    (( wait++ ))
    if ! kill -0 "$app_pid" 2>/dev/null; then
      sleep 0.5
      kill "$tail_pid" 2>/dev/null
      wait "$tail_pid" 2>/dev/null
      echo ""
      log_err "$APP_NAME failed to start (exited after ${wait}s)."
      log_err "Full startup log: $startup_log"
      rm -f "$pf"
      exit 1
    fi
  done

  # Stop tailing after health check
  kill "$tail_pid" 2>/dev/null
  wait "$tail_pid" 2>/dev/null

  echo ""
  log_ok "$APP_NAME is running (PID $app_pid)"
  echo ""

  local yn
  while true; do
    printf "  Keep watching log? [y/n]: "
    read -r yn
    case "$yn" in
      [Yy])
        log "Press Ctrl+C to detach (service keeps running)."
        echo ""
        trap 'echo ""; log "Detached. Service still running (PID $app_pid)."; exit 0' INT
        tail -f "$startup_log"
        break
        ;;
      [Nn]) break ;;
      *) log_warn "Please enter y or n." ;;
    esac
  done
}

# ─────────────────────────── ACTION: restart ──────────────────────────────────
action_restart() {
  log_step "Restarting Service -- $APP_NAME"
  action_stop
  sleep 2
  action_start
}

# ─────────────────────────── Main ─────────────────────────────────────────────
main() {
  echo ""
  printf "${C_BOLD}${C_CYAN}"
  printf "  +----------------------------------------------------------+\n"
  printf "  |         Spring Boot Application Starter  v1.1           |\n"
  printf "  +----------------------------------------------------------+\n"
  printf "${C_RESET}"
  log "Script  : ./$SCRIPT_NAME"
  log "Version : 1.1"
  log "Root    : $ROOT_DIR"
  log "Time    : $(date +"$LOG_TIMESTAMP_FMT")"
  echo ""

  ACTION=""
  APP_NAME=""
  SPRING_PROFILE=""
  ENV_FILE=""
  JAR_FILE=""

  while getopts ":x:a:p:c:j:h" opt; do
    case $opt in
      x) ACTION="$OPTARG" ;;
      a) APP_NAME="$OPTARG" ;;
      p) SPRING_PROFILE="$OPTARG" ;;
      c) ENV_FILE="$OPTARG" ;;
      j) JAR_FILE="$OPTARG" ;;
      h) print_usage; exit 0 ;;
      :) log_err "Option -$OPTARG requires an argument."; print_usage; exit 1 ;;
      \?) log_err "Unknown option: -$OPTARG"; print_usage; exit 1 ;;
    esac
  done

  if [[ -n "$ACTION" ]]; then
    case "$ACTION" in
      start|stop|restart|status) ;;
      *) log_err "Invalid action: '$ACTION'. Valid: start | stop | restart | status"
         exit 1 ;;
    esac
  fi

  initialize_directories

  [[ -z "$ACTION" ]] && prompt_action

  if [[ "$ACTION" == "status" ]]; then
    action_status
    exit 0
  fi

  [[ -z "$APP_NAME" ]] && prompt_service "$ACTION"

  if [[ "$ACTION" == "start" || "$ACTION" == "restart" ]]; then
    if [[ -z "$SPRING_PROFILE" ]]; then
      if [[ "$ACTION" == "restart" ]]; then
        local pf
        pf="$(get_pid_filepath "$APP_NAME")"
        [[ -f "$pf" ]] && log "Service is currently running -- will stop then prompt for profile."
      fi
      prompt_spring_profile
    fi
    verify_java_runtime
  fi

  case "$ACTION" in
    start)   action_start   ;;
    stop)    action_stop    ;;
    restart) action_restart ;;
  esac
}

main "$@"