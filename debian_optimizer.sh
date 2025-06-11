#!/bin/bash
# -----------------------------------------------------------------------------
# | Debian/Ubuntu Server Optimizer for High-Speed Torrent Racing              |
# | Author: Your Name/Handle Here                                             |
# | Version: 2.2 (Final)                                                      |
# |---------------------------------------------------------------------------|
# | HOW TO USE:                                                               |
# | This script is designed for two primary scenarios.                         |
# |                                                                           |
# | 1. STANDARD DEBIAN/UBUNTU (Bare-metal, KVM VM, Cloud VPS):                |
# |    - The script will work fully. All optimizations can be applied.        |
# |    - Just run the script, choose 'Apply ALL', and reboot when done.       |
# |                                                                           |
# | 2. PROXMOX LXC CONTAINER:                                                 |
# |    - The script can apply non-kernel tweaks (e.g., file limits).          |
# |    - It will FAIL to apply network kernel (sysctl) settings, as these     |
# |      must be set on the Proxmox Host itself. This is expected.             |
# |    - For full optimization, run the script in the container, then apply   |
# |      the network tweaks manually on the Proxmox Host.                     |
# |---------------------------------------------------------------------------|
# | DISCLAIMER:                                                               |
# | This script modifies system configuration files. Run it at your own risk. |
# -----------------------------------------------------------------------------

# --- Global Variables and Color Codes ---
readonly SCRIPT_VERSION="2.2"
readonly CONFIG_MARKER_BEGIN="# --- BEGIN TORRENT OPTIMIZATIONS ---"
readonly CONFIG_MARKER_END="# --- END TORRENT OPTIMIZATIONS ---"
readonly TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")

# ANSI Color Codes
readonly C_RESET='\e[0m'
readonly C_BLUE='\e[1;34m'
readonly C_GREEN='\e[1;32m'
readonly C_YELLOW='\e[1;33m'
readonly C_RED='\e[1;31m'

# --- Helper Functions ---

print_header() { echo -e "\n${C_BLUE}=======================================================================${C_RESET}\n${C_BLUE}  $1${C_RESET}\n${C_BLUE}=======================================================================${C_RESET}"; }
print_info() { echo -e "${C_BLUE}[INFO] $1${C_RESET}"; }
print_warn() { echo -e "${C_YELLOW}[WARN] $1${C_RESET}"; }
print_success() { echo -e "${C_GREEN}[SUCCESS] $1${C_RESET}"; }
print_error() { echo -e "${C_RED}[ERROR] $1${C_RESET}"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run with root privileges. Use 'sudo ./script_name.sh'."
        exit 1
    fi
    # Specifically check for sysctl and offer to install its package if missing
    if [[ ! -x "/usr/sbin/sysctl" && ! -x "/bin/sysctl" && ! -x "/usr/bin/sysctl" ]]; then
         print_warn "The 'sysctl' command was not found. It is part of the 'procps' package."
         read -rp "$(echo -e "${C_YELLOW}Do you want to install 'procps' now? (y/N): ${C_RESET}")" choice
         if [[ "$choice" =~ ^[Yy]$ ]]; then
             if apt-get update && apt-get install -y procps; then
                 print_success "'procps' installed successfully."
             else
                 print_error "Failed to install 'procps'. Aborting."
                 exit 1
             fi
         else
             print_error "Cannot proceed without 'sysctl'. Aborting."
             exit 1
         fi
    fi
    # Define SYSCTL_CMD path after potential installation
    if [[ -x "/usr/sbin/sysctl" ]]; then SYSCTL_CMD="/usr/sbin/sysctl"; elif [[ -x "/bin/sysctl" ]]; then SYSCTL_CMD="/bin/sysctl"; else SYSCTL_CMD="/usr/bin/sysctl"; fi
}

ask_confirm() {
    read -rp "$(echo -e "${C_YELLOW}Do you want to apply these changes? (y/N): ${C_RESET}")" choice
    [[ "$choice" =~ ^[Yy]$ ]]
}

backup_file() {
    local file_path="$1"
    if [[ -f "$file_path" ]]; then
        local backup_path="${file_path}.bak-${TIMESTAMP}"
        print_info "Backing up '$file_path' to '$backup_path'..."
        if cp "$file_path" "$backup_path"; then
            print_success "Backup created successfully."
        else
            print_error "Failed to create backup for '$file_path'. Aborting change."
            return 1
        fi
    fi
    return 0
}

remove_existing_config() {
    local file_path="$1"
    if [[ -f "$file_path" ]] && grep -q "$CONFIG_MARKER_BEGIN" "$file_path"; then
        print_info "Removing previously applied settings from '$file_path' to prevent duplicates."
        sed -i.bak-sed-tmp "/${CONFIG_MARKER_BEGIN}/,/${CONFIG_MARKER_END}/d" "$file_path"
        sed -i -e :a -e '/^\n*$/{$d;N;};/\n$/ba' "$file_path"
    fi
}

check_and_install_pkg() {
    local pkg_name="$1"
    if ! dpkg -l | grep -qw "$pkg_name"; then
        print_warn "The package '$pkg_name' is required but not installed."
        read -rp "$(echo -e "${C_YELLOW}Do you want to install it now? (y/N): ${C_RESET}")" choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            if apt-get update && apt-get install -y "$pkg_name"; then
                print_success "'$pkg_name' installed successfully."
            else
                print_error "Failed to install '$pkg_name'."
                return 1
            fi
        else
            print_error "Installation of '$pkg_name' skipped. Cannot proceed."
            return 1
        fi
    fi
    return 0
}

# --- Core Tuning Functions ---

tune_network() {
    print_header "Network Stack Tuning (sysctl)"
    print_info "Checking current network stack configuration..."

    local all_ok=true
    # Use 2>/dev/null to prevent errors in containers where /proc/sys is restricted
    local current_congestion; current_congestion=$($SYSCTL_CMD -n net.ipv4.tcp_congestion_control 2>/dev/null)
    
    if [[ -z "$current_congestion" ]]; then
        print_warn "Could not read kernel parameters. This is expected in an LXC container."
        print_warn "This section will likely fail. Apply these settings on the Proxmox Host."
        all_ok=false
    else
        # ... perform detailed checks only if we can read the values
        local current_qdisc; current_qdisc=$($SYSCTL_CMD -n net.core.default_qdisc 2>/dev/null)
        local current_swappiness; current_swappiness=$($SYSCTL_CMD -n vm.swappiness 2>/dev/null)
        
        printf "%-35s | %-20s | %-20s\n" "Setting" "Current" "Recommended"
        echo "------------------------------------+----------------------+---------------------"
        if [[ "$current_congestion" == "bbr" ]]; then
            printf "%-35s | ${C_GREEN}%-20s${C_RESET} | %-20s\n" "TCP Congestion Control" "$current_congestion" "bbr"
        else
            printf "%-35s | ${C_YELLOW}%-20s${C_RESET} | %-20s\n" "TCP Congestion Control" "$current_congestion" "bbr"; all_ok=false
        fi
        if [[ "$current_qdisc" == "fq" ]]; then
            printf "%-35s | ${C_GREEN}%-20s${C_RESET} | %-20s\n" "Packet Scheduler" "$current_qdisc" "fq"
        else
            printf "%-35s | ${C_YELLOW}%-20s${C_RESET} | %-20s\n" "Packet Scheduler" "$current_qdisc" "fq"; all_ok=false
        fi
        if [[ "$current_swappiness" -le 10 ]]; then
            printf "%-35s | ${C_GREEN}%-20s${C_RESET} | %-20s\n" "VM Swappiness" "$current_swappiness" "10"
        else
            printf "%-35s | ${C_YELLOW}%-20s${C_RESET} | %-20s\n" "VM Swappiness" "$current_swappiness" "10"; all_ok=false
        fi
    fi
    
    echo ""
    if [[ "$all_ok" == true ]]; then
        print_success "All key network settings appear to be optimized. No changes needed."
        return
    fi
    
    if ! ask_confirm; then
        print_warn "Network tuning skipped by user."
        return
    fi

    local conf_file="/etc/sysctl.d/99-torrent-racing-optimizations.conf"
    local settings
    read -r -d '' settings <<'EOF'
# --- BEGIN TORRENT OPTIMIZATIONS ---
# Enable BBR congestion control and FQ packet scheduler
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# Increase TCP/UDP buffer sizes for 1Gbps+ networks
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432
net.core.netdev_max_backlog = 30000
# Increase connection tracking table size
net.netfilter.nf_conntrack_max = 1048576
# Increase TCP SYN backlog
net.ipv4.tcp_max_syn_backlog = 8192
# Lower swappiness to prioritize RAM
vm.swappiness = 10
# --- END TORRENT OPTIMIZATIONS ---
EOF

    if backup_file "$conf_file"; then
        echo "$settings" > "$conf_file"
        print_info "Configuration file written to '$conf_file'."
        print_info "Attempting to apply settings immediately..."
        if $SYSCTL_CMD -p "$conf_file"; then
            print_success "Network stack optimizations have been applied and made persistent."
        else
            print_error "Failed to apply sysctl settings."
            print_warn "This is expected if running in an LXC container."
            print_warn "Apply these settings on the Proxmox Host instead."
        fi
    fi
}

tune_disk() {
    print_header "Disk I/O Scheduler Tuning"
    local udev_file="/etc/udev/rules.d/60-persistent-io-schedulers.rules"
    local changes_made=false

    lsblk -d -n -o NAME,ROTA | while read -r name rota; do
        local current_scheduler recommended_scheduler device_type
        current_scheduler=$(cat "/sys/block/${name}/queue/scheduler")
        
        if [[ "$rota" -eq 0 ]]; then
            device_type="SSD/NVMe"; recommended_scheduler="none"
        elif [[ "$rota" -eq 1 ]]; then
            device_type="HDD"; recommended_scheduler="mq-deadline"
        else
            continue
        fi

        echo -e "\n${C_BLUE}--- Device: /dev/${name} (${device_type}) ---${C_RESET}"
        print_info "Current I/O scheduler(s): ${current_scheduler}"
        print_info "Recommended scheduler: '${recommended_scheduler}'"

        if [[ "$current_scheduler" == *"[${recommended_scheduler}]"* ]]; then
            print_success "Device /dev/${name} is already using the optimal scheduler."
            continue
        fi
        
        print_warn "Scheduler for /dev/${name} is not optimal."
        if ask_confirm; then
            if ! $changes_made ; then
                backup_file "$udev_file"; changes_made=true
            fi
            
            sed -i "/KERNEL==\"${name}\"/d" "$udev_file" 2>/dev/null
            echo "ACTION==\"add|change\", KERNEL==\"${name}\", ATTR{queue/scheduler}=\"${recommended_scheduler}\"" >> "$udev_file"

            if echo "$recommended_scheduler" > "/sys/block/${name}/queue/scheduler"; then
                print_success "Set I/O scheduler for /dev/${name} to '${recommended_scheduler}' and made it persistent."
            else
                print_error "Failed to set I/O scheduler for /dev/${name}."
            fi
        else
            print_warn "Skipped tuning for /dev/${name}."
        fi
    done

    if $changes_made ; then
        print_info "Reloading udev rules to apply persistent settings..."
        udevadm control --reload-rules && udevadm trigger
    fi
}

tune_cpu() {
    print_header "CPU Governor Tuning"
    
    local gov_files=(/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor)
    if [[ ! -e "${gov_files[0]}" ]]; then
        print_warn "Could not find CPU governor files. This can happen on some virtualized platforms."
        print_warn "Skipping CPU tuning."
        return
    fi
    
    print_info "Checking current CPU governors..."
    local needs_tuning=false
    for gov_file in "${gov_files[@]}"; do
        if [[ -f "$gov_file" ]]; then
            local current_gov; current_gov=$(cat "$gov_file")
            if [[ "$current_gov" != "performance" ]]; then
                needs_tuning=true
            fi
        fi
    done
    
    if ! $needs_tuning; then
        print_success "All CPU cores are already set to the 'performance' governor."
        return
    fi
    print_warn "One or more CPU cores are not using the 'performance' governor."

    if ! check_and_install_pkg "cpufrequtils"; then return; fi
    
    if ! ask_confirm; then
        print_warn "CPU tuning skipped by user."
        return
    fi

    local conf_file="/etc/default/cpufrequtils"
    if backup_file "$conf_file"; then
        if grep -q "^GOVERNOR=" "$conf_file"; then
            sed -i 's/^GOVERNOR=.*/GOVERNOR="performance"/' "$conf_file"
        else
            echo 'GOVERNOR="performance"' >> "$conf_file"
        fi

        print_info "Applying 'performance' governor to all CPU cores..."
        find /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor -exec sh -c 'echo performance > {}' \;
        print_success "CPU governor set to 'performance' and made persistent."
    fi
}

tune_limits() {
    print_header "System Open File Limits Tuning"
    print_info "Checking current open file limits..."

    local soft_limit; soft_limit=$(ulimit -Sn)
    local recommended_limit=1048576

    if [[ "$soft_limit" -ge "$recommended_limit" ]]; then
        print_success "Current soft file limit (${soft_limit}) is sufficient."
        if ! grep -q "soft nofile $recommended_limit" /etc/security/limits.conf; then
             print_warn "Consider adding the limit to /etc/security/limits.conf for system-wide persistence."
        fi
        return
    fi
    print_warn "Current soft file limit (${soft_limit}) is low. Recommended: ${recommended_limit}"

    if ! ask_confirm; then
        print_warn "File limit tuning skipped by user."
        return
    fi

    local conf_file="/etc/security/limits.conf"
    local settings
    read -r -d '' settings <<EOF

${CONFIG_MARKER_BEGIN}
# Increased for high-performance torrenting to prevent 'too many open files' errors
*    soft nofile 1048576
*    hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
${CONFIG_MARKER_END}
EOF

    if backup_file "$conf_file"; then
        remove_existing_config "$conf_file"
        echo "$settings" >> "$conf_file"
        print_success "System open file limits increased in '$conf_file'."
        print_warn "A system REBOOT or re-login is required for these changes to take full effect."
    fi
}

apply_all_tweaks() {
    tune_network
    read -rp "$(echo -e "\n${C_YELLOW}Press [Enter] to continue to Disk Tuning...${C_RESET}")"
    tune_disk
    read -rp "$(echo -e "\n${C_YELLOW}Press [Enter] to continue to CPU Tuning...${C_RESET}")"
    tune_cpu
    read -rp "$(echo -e "\n${C_YELLOW}Press [Enter] to continue to File Limit Tuning...${C_RESET}")"
    tune_limits
    print_header "All Optimizations Complete"
    print_warn "A system reboot is recommended to ensure all changes take effect."
}

# --- Main Menu and Script Logic ---
main_menu() {
    clear
    print_header "Debian/Ubuntu Torrent Racing Optimizer v${SCRIPT_VERSION}"
    echo -e "  This script checks your system and applies optimizations for high-speed torrenting."
    echo ""
    echo -e "${C_YELLOW}  Please select an option:${C_RESET}"
    echo "  1. Tune Network Stack (sysctl)"
    echo "  2. Tune Disk I/O Schedulers"
    echo "  3. Tune CPU Governor"
    echo "  4. Tune System-wide File Limits (ulimit)"
    echo "  ------------------------------------"
    echo "  5. Check & Apply ALL Recommended Tweaks"
    echo "  ------------------------------------"
    echo -e "  ${C_RED}q. Quit${C_RESET}"
    echo ""
}

# --- Main Execution ---
check_root

while true; do
    main_menu
    read -rp "$(echo -e "${C_YELLOW}Enter your choice [1-5, q]: ${C_RESET}")" choice

    case $choice in
        1) tune_network ;;
        2) tune_disk ;;
        3) tune_cpu ;;
        4) tune_limits ;;
        5) apply_all_tweaks ;;
        q|Q) echo "Exiting script."; exit 0 ;;
        *) print_error "Invalid option."; sleep 2 ;;
    esac

    if [[ "$choice" != "5" ]]; then
        read -rp "$(echo -e "\n${C_YELLOW}Press [Enter] to return to the main menu...${C_RESET}")"
    fi
done