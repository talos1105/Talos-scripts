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
#    +- jar-ctl.sh                <- this script  (rename as you like)
#
#    JAR / CONF files are resolved interactively (or via -j / -c) --
#    no fixed sub-folders are required or auto-created.
#
#    Application logging (console / file) is configured and managed
#    entirely by the Spring Boot app itself (application.yml / .conf) --
#    this script does not create or manage a log directory.
#
#    /var/run/springboot/               <- PID files      (override: SB_RUN_DIR)
#    +- <service>.pid
#    +- <service>.meta                  <- remembers last JAR/CONF/profile for restart
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
#    export SB_RUN_DIR=/data/run
# =============================================================================

set -euo pipefail

# ─────────────────────────── Directory Layout ─────────────────────────────────
readonly BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR="$BIN_DIR"

RUN_DIR="${SB_RUN_DIR:-/var/run/springboot}"

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

# ─────────────────────────── Console Output ────────────────────────────────────
msg()      { printf "${C_DIM}[%s]${C_RESET} ${C_WHITE}[INFO]${C_RESET}: %s\n"  "$(date +"$LOG_TIMESTAMP_FMT")" "$*"; }
msg_ok()   { printf "${C_DIM}[%s]${C_RESET} ${C_GREEN}[OK]${C_RESET}: %s\n"    "$(date +"$LOG_TIMESTAMP_FMT")" "$*"; }
msg_warn() { printf "${C_DIM}[%s]${C_RESET} ${C_YELLOW}[WARN]${C_RESET}: %s\n" "$(date +"$LOG_TIMESTAMP_FMT")" "$*" >&2; }
msg_err()  { printf "${C_DIM}[%s]${C_RESET} ${C_RED}[ERROR]${C_RESET}: %s\n"   "$(date +"$LOG_TIMESTAMP_FMT")" "$*" >&2; }
step()     { printf "\n${C_CYAN}${C_BOLD}==> %s${C_RESET}\n" "$*"; }
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
  restart  stop + start -- reuses the JAR/CONF/profile from the last
           successful start (saved in <service>.meta) unless -p/-c/-j
           are given, so it works non-interactively too
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
  PID dir  : ${SB_RUN_DIR:-/var/run/springboot}   (override: export SB_RUN_DIR=<path>)

${C_BOLD}JAR REQUIREMENTS${C_RESET}
  Must be a Spring Boot executable fat JAR (spring-boot-maven-plugin repackage).
  Validated checks: magic bytes (PK header) + Main-Class in MANIFEST.MF.
EOF
}

# ─────────────────────────── PID: File Helpers ────────────────────────────────
get_pid_filepath() { echo "$RUN_DIR/${1}.pid"; }
get_meta_filepath() { echo "$RUN_DIR/${1}.meta"; }

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

# Persist JAR/CONF/profile used for the most recent successful start of a
# service, so that 'restart' can reuse them without forcing the operator
# through the interactive pick menus again.
save_service_meta() {
  local svc="$1" jar="$2" conf="$3" profile="$4"
  local mf
  mf="$(get_meta_filepath "$svc")"
  {
    printf 'JAR_FILE=%q\n' "$jar"
    printf 'ENV_FILE=%q\n' "$conf"
    printf 'SPRING_PROFILE=%q\n' "$profile"
  } > "$mf"
}

# Fills JAR_FILE / ENV_FILE / SPRING_PROFILE from the saved meta file, but
# only for values not already set (e.g. via -j/-c/-p on the command line).
# Returns 1 if no meta file exists for this service.
load_service_meta() {
  local svc="$1"
  local mf
  mf="$(get_meta_filepath "$svc")"
  [[ -f "$mf" ]] || return 1

  local _meta_jar="" _meta_conf="" _meta_profile=""
  # shellcheck disable=SC1090
  source <(sed \
    -e 's/^JAR_FILE=/_meta_jar=/' \
    -e 's/^ENV_FILE=/_meta_conf=/' \
    -e 's/^SPRING_PROFILE=/_meta_profile=/' \
    "$mf")

  [[ -z "${JAR_FILE:-}"       && -n "$_meta_jar"     ]] && JAR_FILE="$_meta_jar"
  [[ -z "${ENV_FILE:-}"       && -n "$_meta_conf"    ]] && ENV_FILE="$_meta_conf"
  [[ -z "${SPRING_PROFILE:-}" && -n "$_meta_profile" ]] && SPRING_PROFILE="$_meta_profile"

  if [[ -n "${JAR_FILE:-}" && ! -f "$JAR_FILE" ]]; then
    msg_warn "Previous JAR no longer exists: $JAR_FILE -- will prompt to reselect."
    JAR_FILE=""
  fi
  if [[ -n "${ENV_FILE:-}" && ! -f "$ENV_FILE" ]]; then
    msg_warn "Previous conf no longer exists: $ENV_FILE -- will prompt to reselect."
    ENV_FILE=""
  fi

  return 0
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
  step "Directory Layout"

  if [[ -d "$RUN_DIR" ]] && [[ -w "$RUN_DIR" ]]; then
    msg "  run   OK      $RUN_DIR"
  elif mkdir -p "$RUN_DIR" 2>/dev/null; then
    msg_ok "  run   created $RUN_DIR"
  else
    local fallback="$ROOT_DIR/var/run"
    msg_warn "  run   DENIED  $RUN_DIR"
    msg_warn "  run   fallback -> $fallback"
    msg_warn "  (set SB_RUN_DIR to override system paths)"
    mkdir -p "$fallback"
    RUN_DIR="$fallback"
  fi

  echo ""
  msg "  App root : $ROOT_DIR"
  msg "  PID dir  : $RUN_DIR"
}

# ─────────────────────────── Pre-flight: Java Runtime Check ───────────────────
verify_java_runtime() {
  step "Pre-flight Check -- Java Runtime"

  if ! command -v java &>/dev/null; then
    msg_err "Java executable not found in PATH. Install Java $JAVA_MIN_VERSION+ first."
    exit 1
  fi

  local java_path version_string major_version
  java_path="$(command -v java)"
  version_string="$(java -version 2>&1 | head -1)"
  msg "Java binary    : $java_path"
  msg "Version string : $version_string"

  major_version="$(java -version 2>&1 \
    | grep -oE '"[0-9]+\.[0-9]+' | head -1 | tr -d '"' \
    | awk -F'.' '{ if ($1=="1") print $2; else print $1 }')"

  if [[ -z "$major_version" ]]; then
    msg_warn "Could not parse Java version -- proceeding with caution."
    return
  fi

  msg "Major version  : $major_version"

  if (( major_version < JAVA_MIN_VERSION )); then
    msg_err "Java $major_version detected -- Java $JAVA_MIN_VERSION+ is required."
    exit 1
  fi

  msg_ok "Java $major_version satisfies requirement (Java $JAVA_MIN_VERSION+)."
  [[ -n "${JAVA_HOME:-}" ]] \
    && msg "JAVA_HOME      : $JAVA_HOME" \
    || msg_warn "JAVA_HOME not set -- using system PATH java."
}

# ─────────────────────────── Action: Interactive Selection ────────────────────
prompt_action() {
  step "Select Action"
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
      *) msg_warn "Invalid selection. Enter 1, 2, 3, or 4." ;;
    esac
  done

  msg_ok "Action: $ACTION"
}

# ─────────────────────────── Service: Interactive Selection ───────────────────
prompt_service() {
  local action_label="${1:-}"
  step "Select Service  [$action_label]"
  render_status_board

  while true; do
    printf "  Enter app name: "
    read -r APP_NAME
    [[ -n "$APP_NAME" ]] && break
    msg_warn "App name cannot be empty."
  done

  msg_ok "Service: $APP_NAME"
}

# ─────────────────────────── Profile: Interactive Selection ───────────────────
prompt_spring_profile() {
  step "Select Spring Profile"

  while true; do
    printf "  Enter profile name: "
    read -r SPRING_PROFILE
    [[ -n "$SPRING_PROFILE" ]] && break
    msg_warn "Profile name cannot be empty."
  done

  msg_ok "Spring profile: $SPRING_PROFILE"
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
      *) msg_warn "Please enter y or n." ;;
    esac
  done

  if [[ "$yn" =~ ^[Nn]$ ]]; then
    while true; do
      printf "  Enter folder path containing %s files: " "$_label"
      read -r _result_dir
      _result_dir="${_result_dir/#\~/$HOME}"
      if [[ -z "$_result_dir" ]]; then
        msg_warn "Path cannot be empty."
      elif [[ ! -d "$_result_dir" ]]; then
        msg_warn "Directory not found: $_result_dir"
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
    idx=$(( idx + 1 ))
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
      msg_warn "Invalid selection. Enter 1-$(( idx - 1 ))."
    fi
  done
}

# ─────────────────────────── Conf: Interactive Resolution ─────────────────────
# Asks scan dir preference, scans all *.conf, shows pick menu.
# Falls back to manual path input if no files found.
resolve_conf_interactive() {
  step "Select Config File"

  local scan_dir
  ask_scan_dir scan_dir ".conf"
  msg "Scanning: $scan_dir  (pattern: *.conf, maxdepth 6)"

  local found_confs=()
  while IFS= read -r -d '' f; do
    found_confs+=("$f")
  done < <(find "$scan_dir" -maxdepth 6 -name "*.conf" -print0 2>/dev/null | sort -z)

  echo ""
  divider
  echo ""

  if [[ "${#found_confs[@]}" -gt 0 ]]; then
    msg_ok "Found ${#found_confs[@]} .conf file(s)."
    echo ""
    render_conf_pick_menu found_confs "$scan_dir"
    msg_ok "Conf file selected: $ENV_FILE"
    return
  fi

  # No files found -- fall back to manual input
  msg_warn "No .conf files found under: $scan_dir"
  while true; do
    printf "  Enter full path to .conf file: "
    read -r ENV_FILE
    ENV_FILE="${ENV_FILE/#\~/$HOME}"
    if [[ -z "$ENV_FILE" ]];   then msg_warn "Path cannot be empty."
    elif [[ ! -f "$ENV_FILE" ]]; then msg_warn "File not found: $ENV_FILE"
    else break
    fi
  done

  msg_ok "Conf file selected: $ENV_FILE"
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
    idx=$(( idx + 1 ))
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
      msg_warn "Invalid selection. Enter 1-$(( idx - 1 ))."
    fi
  done
}

# ─────────────────────────── JAR: Interactive Resolution ──────────────────────
# Asks scan dir preference, scans all *.jar, shows pick menu.
# Falls back to manual path input if no files found.
resolve_jar_interactive() {
  step "Select JAR File"

  local scan_dir
  ask_scan_dir scan_dir "JAR"
  msg "Scanning: $scan_dir  (pattern: *.jar, maxdepth 6)"

  local found_jars=()
  while IFS= read -r -d '' f; do
    found_jars+=("$f")
  done < <(find "$scan_dir" -maxdepth 6 -name "*.jar" -print0 2>/dev/null | sort -Vz)

  echo ""
  divider
  echo ""

  if [[ "${#found_jars[@]}" -gt 0 ]]; then
    msg_ok "Found ${#found_jars[@]} JAR file(s)."
    echo ""
    render_jar_pick_menu found_jars "$scan_dir"
    msg_ok "JAR selected: $JAR_FILE"
    return
  fi

  # No files found -- fall back to manual input
  msg_warn "No JAR files found under: $scan_dir"
  while true; do
    printf "  Enter full path to JAR file: "
    read -r JAR_FILE
    JAR_FILE="${JAR_FILE/#\~/$HOME}"
    if [[ -z "$JAR_FILE" ]];   then msg_warn "Path cannot be empty."
    elif [[ ! -f "$JAR_FILE" ]]; then msg_warn "File not found: $JAR_FILE"
    else break
    fi
  done

  msg_ok "JAR selected: $JAR_FILE"
}

# ─────────────────────────── Conf: Load and Export Variables ──────────────────
load_env_config() {
  step "Loading Config File"
  msg "Source: $ENV_FILE"

  [[ -f "$ENV_FILE" ]] || { msg_err "Config file not found: $ENV_FILE"; exit 1; }

  # Strip Windows line endings (\r) -- file edited on Windows causes values
  # to include \r, e.g. "60s\r" which breaks Spring Duration parsing.
  if grep -qP '\r' "$ENV_FILE" 2>/dev/null; then
    msg_warn "Windows line endings (CRLF) detected -- stripping \\r from $ENV_FILE"
    sed -i 's/\r//' "$ENV_FILE"
    msg_ok "Line endings converted to LF."
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

  msg_ok "$line_count variable(s) loaded from $(basename "$ENV_FILE")."
  msg "  SERVER_PORT              = ${SERVER_PORT:-<not set>}"
  msg "  SERVER_CONTEXT_PATH      = ${SERVER_CONTEXT_PATH:-<not set>}"
  msg "  DB_URL                   = ${DB_URL:+**** (set)}${DB_URL:-<not set>}"
  msg "  SERVLET_SESSION_TIMEOUT  = ${SERVLET_SESSION_TIMEOUT:-<not set>}"
}

# ─────────────────────────── JAR: Artifact Validation ─────────────────────────
validate_jar_artifact() {
  step "Validating JAR Artifact"

  [[ -f "$JAR_FILE" ]] || { msg_err "JAR file not found: $JAR_FILE"; exit 1; }

  # Magic bytes -- JAR/ZIP files start with PK (0x504b0304)
  local magic
  magic="$(od -An -tx1 -N4 "$JAR_FILE" 2>/dev/null | tr -d ' \n')"
  if [[ "$magic" != "504b0304" ]]; then
    msg_err "Not a valid JAR file (bad magic bytes: $magic) -- expected ZIP/PK header."
    msg_err "Path: $JAR_FILE"
    exit 1
  fi

  local jar_size
  jar_size="$(du -sh "$JAR_FILE" | cut -f1)"
  msg_ok "JAR magic bytes OK -- $(basename "$JAR_FILE")  [$jar_size]"

  # Verify MANIFEST.MF and Main-Class
  if ! command -v jar &>/dev/null; then
    msg_err "'jar' command not found -- a full JDK (not just a JRE) is required to validate JAR manifests."
    msg_err "Install a JDK (e.g. apt install openjdk-${JAVA_MIN_VERSION}-jdk) or point JAVA_HOME at one."
    exit 1
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  if ! (cd "$tmp_dir" && jar xf "$JAR_FILE" META-INF/MANIFEST.MF) 2>/dev/null; then
    rm -rf "$tmp_dir"
    msg_err "Failed to extract META-INF/MANIFEST.MF from JAR (jar command failed)."
    msg_err "Path: $JAR_FILE"
    exit 1
  fi

  local manifest="$tmp_dir/META-INF/MANIFEST.MF"
  if [[ ! -f "$manifest" ]]; then
    rm -rf "$tmp_dir"
    msg_err "META-INF/MANIFEST.MF not found in JAR -- not a valid executable JAR."
    exit 1
  fi

  local main_class
  main_class="$(grep -i '^Main-Class:' "$manifest" | awk '{print $2}' | tr -d '\r')"
  rm -rf "$tmp_dir"

  if [[ -z "$main_class" ]]; then
    msg_err "No Main-Class in MANIFEST.MF -- JAR is not a Spring Boot executable JAR."
    msg_err "Fix: ensure the spring-boot-maven-plugin repackage goal ran at build time."
    exit 1
  fi
  msg_ok "Main-Class : $main_class"

  if jar tf "$JAR_FILE" 2>/dev/null | grep -q "application.yml"; then
    msg_ok "application.yml found inside JAR -- Spring Boot fat JAR confirmed."
  else
    msg_warn "application.yml not detected -- verify your build artifact."
  fi
}

# ─────────────────────────── ACTION: status ───────────────────────────────────
action_status() {
  step "Service Status"

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

  [[ "$found" -eq 0 ]] && msg "No services found in $RUN_DIR"
  echo ""
}

# ─────────────────────────── ACTION: stop ─────────────────────────────────────
action_stop() {
  step "Stopping Service -- $APP_NAME"

  local pf
  pf="$(get_pid_filepath "$APP_NAME")"
  local pid
  pid="$(get_running_pid "$APP_NAME")"

  if [[ -z "$pid" ]]; then
    msg_warn "$APP_NAME is not running (no active PID found)."
    [[ -f "$pf" ]] && rm -f "$pf" && msg "Removed stale PID file."
    return 0
  fi

  msg "Sending SIGTERM to $APP_NAME (PID $pid) ..."
  kill -SIGTERM "$pid" 2>/dev/null || true

  local elapsed=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( elapsed >= STOP_TIMEOUT )); then
      msg_warn "Process did not exit within ${STOP_TIMEOUT}s -- sending SIGKILL."
      kill -SIGKILL "$pid" 2>/dev/null || true
      sleep 1
      break
    fi
    printf "  ${C_DIM}waiting for shutdown ... %ds${C_RESET}\r" "$elapsed"
    sleep 1
    elapsed=$(( elapsed + 1 ))
  done

  echo ""
  rm -f "$pf"
  msg_ok "$APP_NAME stopped successfully."
}

# ─────────────────────────── ACTION: start ────────────────────────────────────
action_start() {
  step "Starting Service -- $APP_NAME"

  local pf
  pf="$(get_pid_filepath "$APP_NAME")"
  local running_pid
  running_pid="$(get_running_pid "$APP_NAME")"

  if [[ -n "$running_pid" ]]; then
    msg_err "$APP_NAME is already running (PID $running_pid)."
    msg_err "Use 'restart' to restart it, or 'stop' to stop it first."
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

  msg "JVM options : $jvm_opts"
  msg "App args    : $app_args"
  echo ""

  # Capture stdout+stderr to a temp file so the boot sequence can be traced
  # right here at start time. This is independent of -- and does not
  # replace -- whatever logging.file.path Spring itself is configured with.
  local startup_log
  startup_log="$(mktemp "/tmp/${APP_NAME}-startup-XXXXXX.log")"

  java $jvm_opts \
    -jar "$JAR_FILE" \
    $app_args \
    >> "$startup_log" 2>&1 &

  local app_pid=$!
  echo "$app_pid" > "$pf"

  msg "Starting $APP_NAME (PID $app_pid) ..."
  msg "Startup log : $startup_log"
  echo ""

  # Tail immediately so the operator sees the boot sequence in real time.
  # --pid=$app_pid makes tail exit on its own once the app process dies,
  # so it never lingers as an orphan after the app is gone.
  tail -f --pid="$app_pid" "$startup_log" &
  local tail_pid=$!

  # Monitor process health for 10s -- catch early failures
  # (port conflict, bad bean, missing config typically exit within seconds)
  local wait=0
  while (( wait < 10 )); do
    sleep 1
    wait=$(( wait + 1 ))
    if ! kill -0 "$app_pid" 2>/dev/null; then
      kill "$tail_pid" 2>/dev/null
      wait "$tail_pid" 2>/dev/null || true
      echo ""
      msg_err "$APP_NAME failed to start (exited after ${wait}s)."
      msg_err "Full startup log: $startup_log"
      rm -f "$pf"
      exit 1
    fi
  done

  # Stop the health-check tail cleanly before moving on.
  kill "$tail_pid" 2>/dev/null
  wait "$tail_pid" 2>/dev/null || true

  echo ""
  msg_ok "$APP_NAME is running (PID $app_pid)"
  echo ""

  save_service_meta "$APP_NAME" "$JAR_FILE" "$ENV_FILE" "$SPRING_PROFILE"

  # Skip the interactive prompt entirely when stdin isn't a real terminal
  # (cron, systemd, CI, `-x restart` piped from another process) -- a
  # blocking `read` here would otherwise hang forever even though the
  # service is already up and running fine in the background.
  if [[ ! -t 0 ]]; then
    msg "Non-interactive session detected -- not watching the startup log."
    return 0
  fi

  local yn
  while true; do
    printf "  Keep watching log? [y/n]: "
    if ! read -r yn; then
      echo ""
      msg "No input (EOF) -- detaching. Service still running (PID $app_pid)."
      break
    fi
    case "$yn" in
      [Yy])
        msg "Press Ctrl+C to detach (service keeps running)."
        echo ""
        tail -f --pid="$app_pid" "$startup_log" &
        local watch_pid=$!
        # Explicitly kill+reap the tail on INT so it actually stops
        # printing the moment Ctrl+C is pressed, instead of relying on
        # signal propagation that can leave it running in some shells.
        trap 'kill "$watch_pid" 2>/dev/null; wait "$watch_pid" 2>/dev/null || true; trap - INT; echo ""; msg "Detached. Service still running (PID $app_pid)."; exit 0' INT
        wait "$watch_pid" 2>/dev/null || true
        trap - INT
        break
        ;;
      [Nn]) break ;;
      *) msg_warn "Please enter y or n." ;;
    esac
  done
}

# ─────────────────────────── ACTION: restart ──────────────────────────────────
action_restart() {
  step "Restarting Service -- $APP_NAME"
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
  msg "Script  : ./$SCRIPT_NAME"
  msg "Version : 1.1"
  msg "Root    : $ROOT_DIR"
  msg "Time    : $(date +"$LOG_TIMESTAMP_FMT")"
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
      :) msg_err "Option -$OPTARG requires an argument."; print_usage; exit 1 ;;
      \?) msg_err "Unknown option: -$OPTARG"; print_usage; exit 1 ;;
    esac
  done

  if [[ -n "$ACTION" ]]; then
    case "$ACTION" in
      start|stop|restart|status) ;;
      *) msg_err "Invalid action: '$ACTION'. Valid: start | stop | restart | status"
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
    if [[ "$ACTION" == "restart" ]]; then
      if [[ -z "$SPRING_PROFILE" || -z "$ENV_FILE" || -z "$JAR_FILE" ]]; then
        if load_service_meta "$APP_NAME"; then
          msg_ok "Reusing previous run config for $APP_NAME (from $(get_meta_filepath "$APP_NAME"))."
          msg "  JAR_FILE       = ${JAR_FILE:-<will prompt>}"
          msg "  ENV_FILE       = ${ENV_FILE:-<will prompt>}"
          msg "  SPRING_PROFILE = ${SPRING_PROFILE:-<will prompt>}"
        else
          msg_warn "No previous run info for $APP_NAME -- will prompt for profile/conf/jar."
        fi
      fi
    fi

    if [[ -z "$SPRING_PROFILE" ]]; then
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