#!/bin/sh
#==============================================================================
# Cloud Infrastructure Dashboard
# A POSIX-compliant TUI for monitoring and managing cloud VMs and services
#
# Version: 5.0.0
# Author: Diego Nepomuceno Marcos
# Last Updated: 2025-12-02
#
# Dependencies: jq, ssh, curl, ping
# Data Source: cloud-infrastructure.json
#==============================================================================

set -eu

#==============================================================================
# CONFIGURATION
#==============================================================================

VERSION="5.0.0"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/cloud-infrastructure.json"

# Timeouts (seconds)
SSH_TIMEOUT=5
PING_TIMEOUT=2
CURL_TIMEOUT=5

# Colors
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_MAGENTA='\033[0;35m'
C_CYAN='\033[0;36m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_RESET='\033[0m'

# Box drawing
BOX_H='-'
BOX_V='|'

#==============================================================================
# DEPENDENCY CHECK
#==============================================================================

check_deps() {
    missing=""
    for cmd in jq ssh curl ping; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing="$missing $cmd"
        fi
    done

    if [ -n "$missing" ]; then
        printf "%bError: Missing dependencies:%s%b\n" "$C_RED" "$missing" "$C_RESET"
        exit 1
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        printf "%bError: Config not found: %s%b\n" "$C_RED" "$CONFIG_FILE" "$C_RESET"
        exit 1
    fi
}

#==============================================================================
# JSON DATA ACCESS
#==============================================================================

get_vm_ids() {
    jq -r '.virtualMachines | keys[]' "$CONFIG_FILE" 2>/dev/null
}

get_vm_ids_by_category() {
    _cat="$1"
    jq -r ".virtualMachines | to_entries[] | select(.value.category == \"$_cat\") | .key" "$CONFIG_FILE" 2>/dev/null
}

get_vm_categories() {
    jq -r '.vmCategories | keys[]' "$CONFIG_FILE" 2>/dev/null
}

get_vm_category_name() {
    _cat="$1"
    jq -r ".vmCategories[\"$_cat\"].name" "$CONFIG_FILE" 2>/dev/null
}

get_vm() {
    _id="$1"
    _prop="$2"
    jq -r ".virtualMachines[\"$_id\"]$_prop" "$CONFIG_FILE" 2>/dev/null
}

get_service_ids() {
    jq -r '.services | keys[]' "$CONFIG_FILE" 2>/dev/null
}

get_service_ids_by_category() {
    _cat="$1"
    jq -r ".services | to_entries[] | select(.value.category == \"$_cat\") | .key" "$CONFIG_FILE" 2>/dev/null
}

get_service_categories() {
    jq -r '.serviceCategories | keys[]' "$CONFIG_FILE" 2>/dev/null
}

get_service_category_name() {
    _cat="$1"
    jq -r ".serviceCategories[\"$_cat\"].name" "$CONFIG_FILE" 2>/dev/null
}

get_svc() {
    _id="$1"
    _prop="$2"
    jq -r ".services[\"$_id\"]$_prop" "$CONFIG_FILE" 2>/dev/null
}

expand_path() {
    _path="$1"
    case "$_path" in
        "~"*) printf "%s%s" "$HOME" "${_path#\~}" ;;
        *) printf "%s" "$_path" ;;
    esac
}

#==============================================================================
# HEALTH CHECK FUNCTIONS
#==============================================================================

check_ping() {
    _host="$1"
    ping -c 1 -W "$PING_TIMEOUT" "$_host" >/dev/null 2>&1
}

check_ssh() {
    _host="$1"
    _user="$2"
    _key="$3"
    ssh -i "$_key" \
        -o BatchMode=yes \
        -o ConnectTimeout="$SSH_TIMEOUT" \
        -o StrictHostKeyChecking=no \
        "$_user@$_host" "true" >/dev/null 2>&1
}

check_http() {
    _url="$1"
    [ -z "$_url" ] && return 2
    [ "$_url" = "null" ] && return 2

    _code=$(curl -s -o /dev/null -w "%{http_code}" \
            --connect-timeout "$CURL_TIMEOUT" \
            --max-time "$((CURL_TIMEOUT + 2))" \
            "$_url" 2>/dev/null || printf "000")

    case "$_code" in
        2*|3*) return 0 ;;
        *) return 1 ;;
    esac
}

get_vm_status() {
    _id="$1"
    _ip=$(get_vm "$_id" ".network.publicIp")

    if [ "$_ip" = "pending" ]; then
        printf "%b◐ PENDING%b" "$C_YELLOW" "$C_RESET"
        return
    fi

    _user=$(get_vm "$_id" ".ssh.user")
    _key=$(expand_path "$(get_vm "$_id" ".ssh.keyPath")")

    # Use SSH directly (Oracle Cloud blocks ICMP/ping)
    if check_ssh "$_ip" "$_user" "$_key"; then
        printf "%b● ONLINE%b" "$C_GREEN" "$C_RESET"
    else
        # Fallback: try ping if SSH fails (might be key issue)
        if check_ping "$_ip"; then
            printf "%b◐ NO SSH%b" "$C_YELLOW" "$C_RESET"
        else
            printf "%b○ OFFLINE%b" "$C_RED" "$C_RESET"
        fi
    fi
}

# Get RAM usage percentage via SSH
get_vm_ram_percent() {
    _id="$1"
    _ip=$(get_vm "$_id" ".network.publicIp")

    if [ "$_ip" = "pending" ]; then
        printf "-"
        return
    fi

    _user=$(get_vm "$_id" ".ssh.user")
    _key=$(expand_path "$(get_vm "$_id" ".ssh.keyPath")")

    # Get RAM percentage via SSH
    _ram=$(ssh -i "$_key" \
        -o BatchMode=yes \
        -o ConnectTimeout="$SSH_TIMEOUT" \
        -o StrictHostKeyChecking=no \
        "$_user@$_ip" "free | awk '/^Mem:/{printf \"%.0f\", \$3/\$2*100}'" 2>/dev/null || printf "-")

    printf "%s" "$_ram"
}

get_svc_status() {
    _id="$1"
    _status=$(get_svc "$_id" ".status")

    if [ "$_status" = "planned" ] || [ "$_status" = "development" ]; then
        printf "%b◑ DEV%b" "$C_BLUE" "$C_RESET"
        return
    fi

    _url=$(get_svc "$_id" ".urls.gui // .urls.admin" 2>/dev/null)

    if [ -z "$_url" ] || [ "$_url" = "null" ]; then
        printf "%b- N/A%b" "$C_DIM" "$C_RESET"
        return
    fi

    if check_http "$_url"; then
        printf "%b● HEALTHY%b" "$C_GREEN" "$C_RESET"
    else
        printf "%b✖ ERROR%b" "$C_RED" "$C_RESET"
    fi
}

#==============================================================================
# TUI HELPERS
#==============================================================================

cls() {
    printf '\033[2J\033[H'
}

hline() {
    _w="${1:-78}"
    _c="${2:--}"
    _i=0
    while [ "$_i" -lt "$_w" ]; do
        printf "%s" "$_c"
        _i=$((_i + 1))
    done
}

wait_key() {
    printf "\n%bPress Enter to continue...%b" "$C_DIM" "$C_RESET"
    read -r _dummy
}

confirm() {
    printf "%b%s [y/N]: %b" "$C_YELLOW" "$1" "$C_RESET"
    read -r _resp
    case "$_resp" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

#==============================================================================
# DISPLAY FUNCTIONS
#==============================================================================

print_header() {
    printf "\n"
    printf "  %b+%s+%b\n" "$C_BOLD$C_CYAN" "$(hline 76 '=')" "$C_RESET"
    printf "  %b|%b" "$C_BOLD$C_CYAN" "$C_RESET"
    printf "           CLOUD INFRASTRUCTURE DASHBOARD v%s                   " "$VERSION"
    printf "%b|%b\n" "$C_BOLD$C_CYAN" "$C_RESET"
    printf "  %b+%s+%b\n" "$C_BOLD$C_CYAN" "$(hline 76 '=')" "$C_RESET"
    printf "\n"
}

print_vm_table() {
    printf "  %b+%s+%b\n" "$C_BOLD" "$(hline 76 '-')" "$C_RESET"
    printf "  %b| VIRTUAL MACHINES                                                         |%b\n" "$C_BOLD" "$C_RESET"

    for _cat in $(get_vm_categories); do
        _cat_name=$(get_vm_category_name "$_cat")
        _vms=$(get_vm_ids_by_category "$_cat")

        # Skip empty categories
        [ -z "$_vms" ] && continue

        printf "  +--------------------------------------------------------------------------+\n"
        printf "  %b| %-72s |%b\n" "$C_BOLD$C_MAGENTA" "$_cat_name" "$C_RESET"
        printf "  +----------------------+---------------+----------+------+----------------+\n"
        printf "  | %-20s | %-13s | %-8s | %4s | %-14s |\n" "NAME" "IP" "STATUS" "RAM%" "TYPE"
        printf "  +----------------------+---------------+----------+------+----------------+\n"

        for _id in $_vms; do
            _name=$(get_vm "$_id" ".name" | cut -c1-20)
            _ip=$(get_vm "$_id" ".network.publicIp" | cut -c1-13)
            _type=$(get_vm "$_id" ".instanceType" | cut -c1-14)
            _stat=$(get_vm_status "$_id")
            _ram=$(get_vm_ram_percent "$_id")

            if [ "$_ram" = "-" ]; then
                _ram_display="-"
            else
                _ram_display="${_ram}%"
            fi

            printf "  | %-20s | %-13s | %b | %4s | %-14s |\n" "$_name" "$_ip" "$_stat" "$_ram_display" "$_type"
        done
    done

    printf "  +----------------------+---------------+----------+------+----------------+\n"
    printf "\n"
}

print_svc_table() {
    printf "  %b+%s+%b\n" "$C_BOLD" "$(hline 76 '-')" "$C_RESET"
    printf "  %b| SERVICES                                                                  |%b\n" "$C_BOLD" "$C_RESET"

    for _cat in $(get_service_categories); do
        _cat_name=$(get_service_category_name "$_cat")
        _svcs=$(get_service_ids_by_category "$_cat")

        # Skip empty categories
        [ -z "$_svcs" ] && continue

        printf "  +--------------------------------------------------------------------------+\n"
        printf "  %b| %-72s |%b\n" "$C_BOLD$C_MAGENTA" "$_cat_name" "$C_RESET"
        printf "  +----------------------+--------------------------------------+----------+\n"
        printf "  | %-20s | %-36s | %-8s |\n" "NAME" "URL" "STATUS"
        printf "  +----------------------+--------------------------------------+----------+\n"

        for _id in $_svcs; do
            _name=$(get_svc "$_id" ".name" | cut -c1-20)
            _url=$(get_svc "$_id" ".urls.gui // .urls.admin" 2>/dev/null)

            if [ -n "$_url" ] && [ "$_url" != "null" ]; then
                _short_url=$(printf "%s" "$_url" | sed 's|https://||;s|http://||' | cut -c1-36)
            else
                _short_url="-"
            fi

            _stat=$(get_svc_status "$_id")

            printf "  | %-20s | %-36s | %b |\n" "$_name" "$_short_url" "$_stat"
        done
    done

    printf "  +----------------------+--------------------------------------+----------+\n"
    printf "\n"
}

print_menu() {
    printf "  %b+%s+%b\n" "$C_BOLD" "$(hline 76 '-')" "$C_RESET"
    printf "  %b| COMMANDS                                                                  |%b\n" "$C_BOLD" "$C_RESET"
    printf "  +--------------------------------------------------------------------------+\n"
    printf "  |                                                                          |\n"
    printf "  |   %b[1]%b VM Details        %b[4]%b Restart Container   %b[7]%b SSH to VM           |\n" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf "  |   %b[2]%b Container Status  %b[5]%b View Logs           %b[8]%b Open URL            |\n" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf "  |   %b[3]%b Reboot VM         %b[6]%b Stop/Start          %b[R]%b Refresh             |\n" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf "  |                                                                          |\n"
    printf "  |   %b[S]%b Quick Status      %b[Q]%b Quit                                        |\n" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf "  |                                                                          |\n"
    printf "  +--------------------------------------------------------------------------+\n"
    printf "\n"
}

display_dashboard() {
    cls
    print_header
    print_vm_table
    print_svc_table
    print_menu
}

#==============================================================================
# SELECTION HELPERS
#==============================================================================

# Select VM - outputs VM ID or empty string
# Usage: vm_id=$(select_vm "online")
select_vm() {
    _filter="${1:-all}"
    _count=0
    _ids=""

    printf "\n%bSelect VM:%b\n" "$C_BOLD" "$C_RESET"

    for _id in $(get_vm_ids); do
        _ip=$(get_vm "$_id" ".network.publicIp")
        _name=$(get_vm "$_id" ".name")

        case "$_filter" in
            online) [ "$_ip" = "pending" ] && continue ;;
            pending) [ "$_ip" != "pending" ] && continue ;;
        esac

        _count=$((_count + 1))
        _ids="$_ids $_id"
        printf "  [%d] %s (%s)\n" "$_count" "$_name" "$_ip"
    done

    printf "  [0] Cancel\n"
    printf "Choice: "
    read -r _choice

    if [ -z "$_choice" ] || [ "$_choice" = "0" ]; then
        printf ""
        return
    fi

    # Extract nth ID
    printf "%s" "$_ids" | tr ' ' '\n' | sed -n "${_choice}p"
}

# Select Service - outputs service ID or empty string
select_service() {
    _filter="${1:-all}"
    _count=0
    _ids=""

    printf "\n%bSelect Service:%b\n" "$C_BOLD" "$C_RESET"

    for _id in $(get_service_ids); do
        _name=$(get_svc "$_id" ".name")
        _container=$(get_svc "$_id" ".docker.containerName")
        _status=$(get_svc "$_id" ".status")

        case "$_filter" in
            docker)
                [ -z "$_container" ] && continue
                [ "$_container" = "null" ] && continue
                ;;
            active)
                [ "$_status" = "planned" ] && continue
                [ "$_status" = "development" ] && continue
                ;;
        esac

        _count=$((_count + 1))
        _ids="$_ids $_id"

        if [ -n "$_container" ] && [ "$_container" != "null" ]; then
            printf "  [%d] %s (container: %s)\n" "$_count" "$_name" "$_container"
        else
            printf "  [%d] %s\n" "$_count" "$_name"
        fi
    done

    printf "  [0] Cancel\n"
    printf "Choice: "
    read -r _choice

    if [ -z "$_choice" ] || [ "$_choice" = "0" ]; then
        printf ""
        return
    fi

    printf "%s" "$_ids" | tr ' ' '\n' | sed -n "${_choice}p"
}

#==============================================================================
# ACTIONS
#==============================================================================

action_vm_details() {
    _vm_id=$(select_vm "online")
    [ -z "$_vm_id" ] && return

    _ip=$(get_vm "$_vm_id" ".network.publicIp")
    _user=$(get_vm "$_vm_id" ".ssh.user")
    _key=$(expand_path "$(get_vm "$_vm_id" ".ssh.keyPath")")
    _name=$(get_vm "$_vm_id" ".name")

    cls
    printf "\n%b=== VM Details: %s ===%b\n\n" "$C_BOLD$C_CYAN" "$_name" "$C_RESET"

    printf "%bLocal Config:%b\n" "$C_BOLD" "$C_RESET"
    printf "  ID:       %s\n" "$_vm_id"
    printf "  IP:       %s\n" "$_ip"
    printf "  User:     %s\n" "$_user"
    printf "  Provider: %s\n" "$(get_vm "$_vm_id" ".provider")"
    printf "  Category: %s\n" "$(get_vm "$_vm_id" ".category")"
    printf "  Type:     %s\n\n" "$(get_vm "$_vm_id" ".instanceType")"

    printf "%bRemote System Info:%b\n" "$C_BOLD" "$C_RESET"
    ssh -i "$_key" \
        -o ConnectTimeout="$SSH_TIMEOUT" \
        -o StrictHostKeyChecking=no \
        "$_user@$_ip" '
echo "  Hostname: $(hostname)"
echo "  Uptime:   $(uptime -p 2>/dev/null || uptime)"
echo "  Kernel:   $(uname -r)"
echo ""
echo "Resources:"
echo "  CPU:      $(nproc) cores"
echo "  RAM:      $(free -h | awk "/^Mem:/{print \$3 \"/\" \$2}")"
echo "  RAM %:    $(free | awk "/^Mem:/{printf \"%.1f%%\", \$3/\$2*100}")"
echo "  Disk:     $(df -h / | awk "NR==2{print \$3 \"/\" \$2}")"
echo ""
echo "Docker:"
echo "  Running:  $(sudo docker ps -q 2>/dev/null | wc -l) containers"
' 2>/dev/null || printf "  %bFailed to connect%b\n" "$C_RED" "$C_RESET"

    wait_key
}

action_container_status() {
    _vm_id=$(select_vm "online")
    [ -z "$_vm_id" ] && return

    _ip=$(get_vm "$_vm_id" ".network.publicIp")
    _user=$(get_vm "$_vm_id" ".ssh.user")
    _key=$(expand_path "$(get_vm "$_vm_id" ".ssh.keyPath")")
    _name=$(get_vm "$_vm_id" ".name")

    cls
    printf "\n%b=== Containers on %s ===%b\n\n" "$C_BOLD$C_CYAN" "$_name" "$C_RESET"

    ssh -i "$_key" \
        -o ConnectTimeout="$SSH_TIMEOUT" \
        -o StrictHostKeyChecking=no \
        "$_user@$_ip" \
        'sudo docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"' \
        2>/dev/null || printf "%bFailed to connect%b\n" "$C_RED" "$C_RESET"

    wait_key
}

action_reboot_vm() {
    _vm_id=$(select_vm "online")
    [ -z "$_vm_id" ] && return

    _name=$(get_vm "$_vm_id" ".name")
    _ip=$(get_vm "$_vm_id" ".network.publicIp")
    _user=$(get_vm "$_vm_id" ".ssh.user")
    _key=$(expand_path "$(get_vm "$_vm_id" ".ssh.keyPath")")

    printf "\n"
    if confirm "REBOOT ${_name} (${_ip})?"; then
        printf "%bSending reboot command...%b\n" "$C_YELLOW" "$C_RESET"
        ssh -i "$_key" \
            -o ConnectTimeout="$SSH_TIMEOUT" \
            -o StrictHostKeyChecking=no \
            "$_user@$_ip" 'sudo reboot' 2>/dev/null || true
        printf "%bReboot signal sent.%b\n" "$C_GREEN" "$C_RESET"
        wait_key
    fi
}

action_restart_container() {
    _svc_id=$(select_service "docker")
    [ -z "$_svc_id" ] && return

    _name=$(get_svc "$_svc_id" ".name")
    _container=$(get_svc "$_svc_id" ".docker.containerName")
    _vm_id=$(get_svc "$_svc_id" ".vmId")
    _ip=$(get_vm "$_vm_id" ".network.publicIp")
    _user=$(get_vm "$_vm_id" ".ssh.user")
    _key=$(expand_path "$(get_vm "$_vm_id" ".ssh.keyPath")")

    printf "\n"
    if confirm "Restart container '${_container}' (${_name})?"; then
        printf "%bRestarting...%b\n" "$C_YELLOW" "$C_RESET"
        ssh -i "$_key" \
            -o ConnectTimeout="$SSH_TIMEOUT" \
            -o StrictHostKeyChecking=no \
            "$_user@$_ip" "sudo docker restart $_container" 2>/dev/null
        printf "%bDone.%b\n" "$C_GREEN" "$C_RESET"
        wait_key
    fi
}

action_view_logs() {
    _svc_id=$(select_service "docker")
    [ -z "$_svc_id" ] && return

    _container=$(get_svc "$_svc_id" ".docker.containerName")
    _vm_id=$(get_svc "$_svc_id" ".vmId")
    _ip=$(get_vm "$_vm_id" ".network.publicIp")
    _user=$(get_vm "$_vm_id" ".ssh.user")
    _key=$(expand_path "$(get_vm "$_vm_id" ".ssh.keyPath")")

    printf "Lines to show [50]: "
    read -r _lines
    _lines="${_lines:-50}"

    cls
    printf "\n%b=== Logs: %s (last %s lines) ===%b\n\n" "$C_BOLD$C_CYAN" "$_container" "$_lines" "$C_RESET"

    ssh -i "$_key" \
        -o ConnectTimeout="$SSH_TIMEOUT" \
        -o StrictHostKeyChecking=no \
        "$_user@$_ip" "sudo docker logs --tail $_lines $_container" 2>&1

    wait_key
}

action_stop_start() {
    _svc_id=$(select_service "docker")
    [ -z "$_svc_id" ] && return

    _container=$(get_svc "$_svc_id" ".docker.containerName")
    _vm_id=$(get_svc "$_svc_id" ".vmId")
    _ip=$(get_vm "$_vm_id" ".network.publicIp")
    _user=$(get_vm "$_vm_id" ".ssh.user")
    _key=$(expand_path "$(get_vm "$_vm_id" ".ssh.keyPath")")

    printf "\n  [1] Start\n  [2] Stop\nAction: "
    read -r _action

    case "$_action" in
        1) _cmd="start" ;;
        2) _cmd="stop" ;;
        *) return ;;
    esac

    if confirm "${_cmd} container '${_container}'?"; then
        printf "%bExecuting docker %s...%b\n" "$C_YELLOW" "$_cmd" "$C_RESET"
        ssh -i "$_key" \
            -o ConnectTimeout="$SSH_TIMEOUT" \
            -o StrictHostKeyChecking=no \
            "$_user@$_ip" "sudo docker $_cmd $_container" 2>/dev/null
        printf "%bDone.%b\n" "$C_GREEN" "$C_RESET"
        wait_key
    fi
}

action_ssh() {
    _vm_id=$(select_vm "online")
    [ -z "$_vm_id" ] && return

    _ip=$(get_vm "$_vm_id" ".network.publicIp")
    _user=$(get_vm "$_vm_id" ".ssh.user")
    _key=$(expand_path "$(get_vm "$_vm_id" ".ssh.keyPath")")
    _name=$(get_vm "$_vm_id" ".name")

    printf "\n%bConnecting to %s...%b\n" "$C_CYAN" "$_name" "$C_RESET"
    printf "%bType 'exit' to return%b\n\n" "$C_DIM" "$C_RESET"

    ssh -i "$_key" -o StrictHostKeyChecking=no "$_user@$_ip"
}

action_open_url() {
    _svc_id=$(select_service "active")
    [ -z "$_svc_id" ] && return

    _url=$(get_svc "$_svc_id" ".urls.gui // .urls.admin" 2>/dev/null)

    if [ -z "$_url" ] || [ "$_url" = "null" ]; then
        printf "%bNo URL available.%b\n" "$C_YELLOW" "$C_RESET"
        wait_key
        return
    fi

    printf "%bOpening %s...%b\n" "$C_CYAN" "$_url" "$C_RESET"

    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$_url" >/dev/null 2>&1 &
    elif command -v open >/dev/null 2>&1; then
        open "$_url" >/dev/null 2>&1 &
    else
        printf "%bNo browser opener. URL: %s%b\n" "$C_YELLOW" "$_url" "$C_RESET"
        wait_key
    fi

    sleep 1
}

action_quick_status() {
    printf "\n%b=== Quick Status ===%b\n\n" "$C_BOLD$C_CYAN" "$C_RESET"

    for _cat in $(get_vm_categories); do
        _cat_name=$(get_vm_category_name "$_cat")
        _vms=$(get_vm_ids_by_category "$_cat")
        [ -z "$_vms" ] && continue

        printf "%b%s VMs:%b\n" "$C_BOLD$C_MAGENTA" "$_cat_name" "$C_RESET"
        for _id in $_vms; do
            _name=$(get_vm "$_id" ".name")
            _ip=$(get_vm "$_id" ".network.publicIp")
            _stat=$(get_vm_status "$_id")
            _ram=$(get_vm_ram_percent "$_id")
            if [ "$_ram" = "-" ]; then
                printf "  %-25s %-16s %b\n" "$_name" "$_ip" "$_stat"
            else
                printf "  %-25s %-16s %b RAM: %s%%\n" "$_name" "$_ip" "$_stat" "$_ram"
            fi
        done
        printf "\n"
    done

    for _cat in $(get_service_categories); do
        _cat_name=$(get_service_category_name "$_cat")
        _svcs=$(get_service_ids_by_category "$_cat")
        [ -z "$_svcs" ] && continue

        printf "%b%s Services:%b\n" "$C_BOLD$C_MAGENTA" "$_cat_name" "$C_RESET"
        for _id in $_svcs; do
            _name=$(get_svc "$_id" ".name")
            _stat=$(get_svc_status "$_id")
            printf "  %-25s %b\n" "$_name" "$_stat"
        done
        printf "\n"
    done

    wait_key
}

#==============================================================================
# CLI MODE
#==============================================================================

cli_status() {
    printf "Cloud Infrastructure Status\n"
    printf "============================\n\n"

    for _cat in $(get_vm_categories); do
        _cat_name=$(get_vm_category_name "$_cat")
        _vms=$(get_vm_ids_by_category "$_cat")
        [ -z "$_vms" ] && continue

        printf "%s VMs:\n" "$_cat_name"
        for _id in $_vms; do
            _name=$(get_vm "$_id" ".name")
            _ip=$(get_vm "$_id" ".network.publicIp")

            if [ "$_ip" = "pending" ]; then
                printf "  %s: PENDING\n" "$_name"
            else
                _user=$(get_vm "$_id" ".ssh.user")
                _key=$(expand_path "$(get_vm "$_id" ".ssh.keyPath")")
                if check_ssh "$_ip" "$_user" "$_key"; then
                    printf "  %s (%s): ONLINE\n" "$_name" "$_ip"
                else
                    printf "  %s (%s): OFFLINE\n" "$_name" "$_ip"
                fi
            fi
        done
        printf "\n"
    done

    for _cat in $(get_service_categories); do
        _cat_name=$(get_service_category_name "$_cat")
        _svcs=$(get_service_ids_by_category "$_cat")
        [ -z "$_svcs" ] && continue

        printf "%s Services:\n" "$_cat_name"
        for _id in $_svcs; do
            _name=$(get_svc "$_id" ".name")
            _url=$(get_svc "$_id" ".urls.gui // .urls.admin" 2>/dev/null)
            _status=$(get_svc "$_id" ".status")

            if [ "$_status" = "planned" ] || [ "$_status" = "development" ]; then
                printf "  %s: DEV/PLANNED\n" "$_name"
            elif [ -z "$_url" ] || [ "$_url" = "null" ]; then
                printf "  %s: NO URL\n" "$_name"
            elif check_http "$_url"; then
                printf "  %s: HEALTHY\n" "$_name"
            else
                printf "  %s: ERROR\n" "$_name"
            fi
        done
        printf "\n"
    done
}

cli_help() {
    cat << EOF
Cloud Infrastructure Dashboard v${VERSION}

Usage: $(basename "$0") [command]

Commands:
  (no args)     Launch interactive TUI dashboard
  status        Show quick status of all VMs and services
  help          Show this help message

Interactive Commands:
  1 - VM Details          4 - Restart Container    7 - SSH to VM
  2 - Container Status    5 - View Logs            8 - Open URL
  3 - Reboot VM           6 - Stop/Start           R - Refresh
  S - Quick Status        Q - Quit

Config: ${CONFIG_FILE}
EOF
}

#==============================================================================
# MAIN
#==============================================================================

main_loop() {
    while true; do
        display_dashboard
        printf "  Command: "
        read -r _cmd

        case "$_cmd" in
            1) action_vm_details ;;
            2) action_container_status ;;
            3) action_reboot_vm ;;
            4) action_restart_container ;;
            5) action_view_logs ;;
            6) action_stop_start ;;
            7) action_ssh ;;
            8) action_open_url ;;
            [sS]) action_quick_status ;;
            [rR]) ;; # refresh
            [qQ])
                cls
                printf "%bGoodbye!%b\n" "$C_CYAN" "$C_RESET"
                exit 0
                ;;
            *)
                printf "%bInvalid command%b\n" "$C_RED" "$C_RESET"
                sleep 1
                ;;
        esac
    done
}

main() {
    check_deps

    case "${1:-}" in
        status) cli_status ;;
        help|--help|-h) cli_help ;;
        "") main_loop ;;
        *)
            printf "Unknown command: %s\n" "$1"
            cli_help
            exit 1
            ;;
    esac
}

main "$@"
