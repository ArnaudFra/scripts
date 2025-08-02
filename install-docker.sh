#!/usr/bin/env bash
# Docker Installation Script for Ubuntu 22.04, 24.04, and 24.10
# Supports virtualization detection, haveged installation, and user management
# GitHub-hostable and executable via curl/wget
# 
# Usage: curl -fsSL https://raw.githubusercontent.com/ArnaudFra/scripts/refs/heads/main/install-docker.sh | bash
# Or: wget -qO- https://raw.githubusercontent.com/ArnaudFra/scripts/refs/heads/main/install-docker.sh | bash

set -eo pipefail

# Script configuration
SCRIPT_NAME="install-docker.sh"
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
elif [[ -n "${0:-}" ]]; then
    SCRIPT_NAME="$(basename "${0}")"
fi
LOGFILE="/tmp/${SCRIPT_NAME%.sh}.log"
MIN_UBUNTU_VERSION="20.04"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

###########################################
# Logging and Output Functions
###########################################

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOGFILE"
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

status_ok() { echo -e "${GREEN}✓${NC} $*"; }
status_warn() { echo -e "${YELLOW}⚠${NC} $*" >&2; }
status_error() { echo -e "${RED}✗${NC} $*" >&2; }
status_info() { echo -e "${BLUE}ℹ${NC} $*"; }

###########################################
# Error Handling
###########################################

cleanup() {
    log_info "Cleaning up temporary files"
    # Add any cleanup operations here
}

error_handler() {
    local line_no=$1
    local error_code=$2
    log_error "Error on line $line_no: command exited with status $error_code"
    cleanup
    exit "$error_code"
}

trap 'error_handler $LINENO $?' ERR
trap cleanup EXIT

###########################################
# Input Handling Functions
###########################################

is_interactive() {
    [[ -t 0 ]] && [[ -t 1 ]]
}

read_user_input() {
    local prompt="$1"
    local default="${2:-}"
    local response
    
    # Always try to read from /dev/tty first for piped execution
    if [[ -c /dev/tty ]]; then
        printf "%s" "$prompt" >/dev/tty
        read -r response </dev/tty
        echo "$response"
    elif is_interactive; then
        read -p "$prompt" -r response
        echo "$response"
    else
        # Fallback to default or empty
        echo "$default"
    fi
}

read_user_choice() {
    local prompt="$1"
    local default="${2:-}"
    local response
    
    # Always try to read from /dev/tty first for piped execution
    if [[ -c /dev/tty ]]; then
        printf "%s" "$prompt" >/dev/tty
        read -n 1 -r response </dev/tty
        printf "\n" >/dev/tty
        echo "$response"
    elif is_interactive; then
        read -p "$prompt" -n 1 -r response
        echo
        echo "$response"
    else
        # Fallback to default
        echo "$default"
    fi
}

get_ubuntu_version() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        if [[ "$ID" == "ubuntu" ]]; then
            echo "$VERSION_ID"
            return 0
        fi
    fi
    return 1
}

version_greater_equal() {
    local version1="$1"
    local version2="$2"
    
    local v1_major=$(echo "$version1" | cut -d. -f1)
    local v1_minor=$(echo "$version1" | cut -d. -f2)
    local v2_major=$(echo "$version2" | cut -d. -f1)
    local v2_minor=$(echo "$version2" | cut -d. -f2)
    
    if (( v1_major > v2_major )); then
        return 0
    elif (( v1_major == v2_major && v1_minor >= v2_minor )); then
        return 0
    else
        return 1
    fi
}

check_ubuntu_compatibility() {
    local current_version
    current_version=$(get_ubuntu_version) || {
        status_error "This script requires Ubuntu. Detected OS is not Ubuntu."
        return 1
    }
    
    if version_greater_equal "$current_version" "$MIN_UBUNTU_VERSION"; then
        status_ok "Ubuntu $current_version is compatible (>= $MIN_UBUNTU_VERSION)"
        return 0
    else
        status_error "Ubuntu $current_version is not compatible (< $MIN_UBUNTU_VERSION)"
        return 1
    fi
}

detect_virtualization() {
    local virt_type=""
    local confidence="unknown"
    
    # Primary detection using systemd-detect-virt
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        virt_type=$(systemd-detect-virt 2>/dev/null || echo "none")
        if [[ "$virt_type" != "none" ]]; then
            confidence="high"
            echo "$virt_type"
            log_info "Detected virtualization: $virt_type (confidence: $confidence)"
            return 0
        fi
    fi
    
    # Secondary detection using /proc/cpuinfo
    if [[ -r /proc/cpuinfo ]] && grep -q "hypervisor" /proc/cpuinfo; then
        virt_type="vm-detected"
        confidence="medium"
        echo "$virt_type"
        log_info "Hypervisor flag detected in /proc/cpuinfo (confidence: $confidence)"
        return 0
    fi
    
    # Tertiary detection using dmidecode (if available and root)
    if command -v dmidecode >/dev/null 2>&1 && [[ $EUID -eq 0 ]]; then
        local product_name
        product_name=$(dmidecode -s system-product-name 2>/dev/null | tr '[:upper:]' '[:lower:]')
        case "$product_name" in
            *vmware*) echo "vmware"; return 0 ;;
            *virtualbox*) echo "virtualbox"; return 0 ;;
            *kvm*|*qemu*) echo "kvm"; return 0 ;;
        esac
    fi
    
    echo "none"
    log_info "No virtualization detected"
    return 1
}

should_install_haveged() {
    local virt_type
    virt_type=$(detect_virtualization)
    
    case "$virt_type" in
        none)
            status_info "Running on bare metal - haveged not needed"
            return 1
            ;;
        kvm|qemu|vmware|virtualbox|xen|microsoft|oracle)
            status_info "Detected virtualization ($virt_type) - haveged recommended for entropy"
            return 0
            ;;
        *)
            # Ask user if detection is uncertain
            status_warn "Unable to reliably detect virtualization environment"
            local user_choice
            user_choice=$(read_user_choice "Are you running in a virtual machine or VPS? (y/n): " "n")
            if [[ "$user_choice" =~ ^[Yy]$ ]]; then
                status_info "User confirmed virtualization - will install haveged"
                return 0
            elif [[ "$user_choice" =~ ^[Nn]$ ]]; then
                status_info "User confirmed bare metal - skipping haveged"
                return 1
            else
                status_info "No response or invalid input - defaulting to bare metal (no haveged)"
                return 1
            fi
            ;;
    esac
}

###########################################
# Docker Installation Functions
###########################################

is_docker_installed() {
    command -v docker >/dev/null 2>&1 && docker --version >/dev/null 2>&1
}

is_docker_compose_installed() {
    docker compose version >/dev/null 2>&1
}

remove_conflicting_packages() {
    local packages=(docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc)
    local to_remove=()
    
    status_info "Checking for conflicting packages..."
    
    for pkg in "${packages[@]}"; do
        if dpkg -l | grep -q "^ii.*$pkg"; then
            to_remove+=("$pkg")
        fi
    done
    
    if [[ ${#to_remove[@]} -gt 0 ]]; then
        status_warn "Removing conflicting packages: ${to_remove[*]}"
        apt-get remove -y "${to_remove[@]}" || {
            status_warn "Some packages could not be removed, continuing..."
        }
    else
        status_ok "No conflicting packages found"
    fi
}

install_prerequisites() {
    status_info "Installing prerequisites..."
    
    apt-get update
    apt-get install -y ca-certificates curl
    
    # Create keyring directory
    install -m 0755 -d /etc/apt/keyrings
    
    status_ok "Prerequisites installed"
}

setup_docker_repository() {
    local gpg_key_path="/etc/apt/keyrings/docker.asc"
    local sources_list="/etc/apt/sources.list.d/docker.list"
    
    status_info "Setting up Docker repository..."
    
    # Download and install GPG key
    if [[ ! -f "$gpg_key_path" ]] || ! gpg --quiet --batch --verify "$gpg_key_path" >/dev/null 2>&1; then
        status_info "Downloading Docker GPG key..."
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$gpg_key_path"
        chmod a+r "$gpg_key_path"
    else
        status_ok "Docker GPG key already present"
    fi
    
    # Add repository
    if [[ ! -f "$sources_list" ]]; then
        status_info "Adding Docker repository..."
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=$gpg_key_path] https://download.docker.com/linux/ubuntu \
          $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
          tee "$sources_list" > /dev/null
        apt-get update
    else
        status_ok "Docker repository already configured"
    fi
    
    status_ok "Docker repository setup complete"
}

install_docker() {
    if is_docker_installed; then
        status_ok "Docker is already installed"
        docker --version
        return 0
    fi
    
    status_info "Installing Docker packages..."
    
    # Install Docker packages
    apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin
    
    # Enable and start Docker service
    systemctl enable docker
    systemctl start docker
    
    status_ok "Docker installation complete"
    docker --version
    
    # Verify Docker Compose plugin
    if is_docker_compose_installed; then
        status_ok "Docker Compose plugin installed"
        docker compose version
    else
        status_warn "Docker Compose plugin may not be properly installed"
    fi
}

install_haveged() {
    if dpkg -l | grep -q "^ii.*haveged"; then
        status_ok "haveged is already installed"
        return 0
    fi
    
    status_info "Installing haveged for improved entropy in virtualized environment..."
    
    apt-get install -y haveged
    systemctl enable haveged
    systemctl start haveged
    
    # Check entropy levels
    local entropy_before entropy_after
    entropy_after=$(cat /proc/sys/kernel/random/entropy_avail 2>/dev/null || echo "unknown")
    
    status_ok "haveged installed and started"
    status_info "Current entropy level: $entropy_after bits"
}

###########################################
# User Management Functions
###########################################

is_user_in_group() {
    local user="$1"
    local group="$2"
    
    getent group "$group" | grep -q "\b$user\b" || \
    groups "$user" 2>/dev/null | grep -q "\b$group\b" || \
    id -nG "$user" 2>/dev/null | grep -q "\b$group\b"
}

get_regular_users() {
    # Get users with UID >= 1000 and < 65534, excluding system accounts
    getent passwd | awk -F: '
        $3 >= 1000 && $3 < 65534 && $7 !~ /false|nologin/ { 
            printf "%s\n", $1 
        }'
}

parse_user_selection() {
    local input="$1"
    local -a result=()
    
    # Split on commas, spaces, and handle ranges
    IFS=', ' read -a ranges <<< "$input"
    
    for range in "${ranges[@]}"; do
        if [[ "$range" =~ ^[0-9]+$ ]]; then
            # Single number
            result+=("$range")
        elif [[ "$range" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            # Range (e.g., 1-3)
            local start="${BASH_REMATCH[1]}"
            local end="${BASH_REMATCH[2]}"
            for ((i=start; i<=end; i++)); do
                result+=("$i")
            done
        fi
    done
    
    printf '%s\n' "${result[@]}" | sort -n | uniq
}

add_user_to_docker_group() {
    local user="$1"
    
    # Verify user exists
    if ! getent passwd "$user" >/dev/null; then
        status_error "User $user does not exist"
        return 1
    fi
    
    # Check if already in docker group
    if is_user_in_group "$user" "docker"; then
        status_ok "User $user is already in docker group"
        return 0
    fi
    
    # Add user to docker group
    if usermod -aG docker "$user"; then
        status_ok "Added $user to docker group"
        log_info "Added user $user to docker group"
        return 0
    else
        status_error "Failed to add $user to docker group"
        return 1
    fi
}

manage_docker_users() {
    local users=()
    local eligible_users=()
    
    # Get all regular users
    readarray -t users < <(get_regular_users)
    
    if [[ ${#users[@]} -eq 0 ]]; then
        status_warn "No regular user accounts found"
        return 0
    fi
    
    # Filter users not already in docker group
    for user in "${users[@]}"; do
        if ! is_user_in_group "$user" "docker"; then
            eligible_users+=("$user")
        fi
    done
    
    if [[ ${#eligible_users[@]} -eq 0 ]]; then
        status_ok "All user accounts are already in docker group"
        return 0
    fi
    
    # If not interactive, provide information but don't prompt
    if ! is_interactive && [[ ! -c /dev/tty ]]; then
        status_warn "Non-interactive mode detected. Cannot prompt for user selection."
        status_info "User accounts that could be added to docker group:"
        for i in "${!eligible_users[@]}"; do
            echo "  - ${eligible_users[$i]}"
        done
        status_info "To add users to docker group later, run:"
        echo "  sudo usermod -aG docker USERNAME"
        echo "  OR re-run this script interactively: sudo bash install-docker.sh"
        return 0
    fi
    
    echo
    status_info "Available user accounts (not in docker group):"
    for i in "${!eligible_users[@]}"; do
        echo "  $((i+1)). ${eligible_users[$i]}"
    done
    
    echo
    echo "Enter user selection:"
    echo "  - Single numbers: 1,2,3"
    echo "  - Ranges: 1-3,5"
    echo "  - Press Enter to skip user management"
    local user_selection
    user_selection=$(read_user_input "Selection: " "")
    
    if [[ -z "$user_selection" ]]; then
        status_info "Skipping user management"
        return 0
    fi
    
    # Parse selection and add users
    local indices
    readarray -t indices < <(parse_user_selection "$user_selection")
    
    local added_users=()
    for index in "${indices[@]}"; do
        if (( index > 0 && index <= ${#eligible_users[@]} )); then
            local user="${eligible_users[$((index-1))]}"
            if add_user_to_docker_group "$user"; then
                added_users+=("$user")
            fi
        else
            status_warn "Invalid selection: $index"
        fi
    done
    
    if [[ ${#added_users[@]} -gt 0 ]]; then
        echo
        status_ok "Successfully added ${#added_users[@]} user(s) to docker group: ${added_users[*]}"
        status_info "Users will need to log out and back in for group changes to take effect"
        status_info "Or run: newgrp docker"
    fi
}

###########################################
# Main Installation Function
###########################################

main() {
    echo "========================================"
    echo "Docker Installation Script for Ubuntu"
    echo "Supports: 22.04 LTS, 24.04 LTS, 24.10"
    echo "========================================"
    echo
    
    log_info "Starting Docker installation script"
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        status_error "This script must be run as root (use sudo)"
        exit 1
    fi
    
    # Check Ubuntu compatibility
    check_ubuntu_compatibility || exit 1
    
    # Remove conflicting packages
    remove_conflicting_packages
    
    # Install prerequisites
    install_prerequisites
    
    # Setup Docker repository
    setup_docker_repository
    
    # Install Docker
    install_docker
    
    # Check if haveged should be installed
    if should_install_haveged; then
        install_haveged
    fi
    
    # Manage user accounts
    manage_docker_users
    
    # Final verification
    echo
    status_info "Installation verification:"
    if is_docker_installed; then
        status_ok "Docker: $(docker --version)"
    else
        status_error "Docker installation failed"
        exit 1
    fi
    
    if is_docker_compose_installed; then
        status_ok "Docker Compose: $(docker compose version)"
    else
        status_warn "Docker Compose plugin may not be working properly"
    fi
    
    echo
    status_ok "Docker installation completed successfully!"
    echo
    echo "Next steps:"
    echo "  1. Users added to docker group need to log out and back in"
    echo "  2. Test installation: sudo docker run hello-world"
    echo "  3. Test Docker Compose: docker compose --version"
    echo
    
    log_info "Docker installation script completed successfully"
}

# Handle both direct execution and piped execution from curl/wget
# Check if script is being executed directly (not sourced)
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]] || [[ -z "${BASH_SOURCE[0]:-}" ]]; then
    main "$@"
fi
