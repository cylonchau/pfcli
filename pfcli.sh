#!/usr/bin/bash

# Script purpose: Dynamically manage socat port mappings, supporting addition, removal, listing, and automatic recovery of domains and IPs
# Usage: ./pfcli.sh <command> [parameters]
# Commands: add <local IP:port> <remote IP or domain:port> | remove <local IP:port> | list | restore | help

# Mapping information storage file
MAPPING_FILE="${MAPPING_FILE:-$HOME/.socat_mappings}"
# Log file
LOG_FILE="${LOG_FILE:-/var/log/socat_manage.log}"

# Check dependencies
MISSING_DEPS=()
if ! command -v socat &> /dev/null; then
    MISSING_DEPS+=("socat")
fi

# Check for domain resolution tools (host or nslookup)
HAS_RESOLVER=0
if command -v host &> /dev/null || command -v nslookup &> /dev/null || command -v getent &> /dev/null; then
    HAS_RESOLVER=1
fi

if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
    echo "Error: The following required dependencies are missing: ${MISSING_DEPS[*]}"
    echo "Please install them using your package manager (e.g., yum install ${MISSING_DEPS[*]} or apt-get install ${MISSING_DEPS[*]})"
    exit 1
fi

# Create mapping file and log file (if they do not exist)
touch "$MAPPING_FILE" "$LOG_FILE" || {
    echo "Error: Unable to create file $MAPPING_FILE or $LOG_FILE"
    exit 1
}

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Validate IP or domain
validate_host() {
    local host="$1"
    # IP address format validation
    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 0
    # Domain name format validation
    elif [[ "$host" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*(\.[a-zA-Z0-9][a-zA-Z0-9-]*)*$ ]]; then
        # Check if domain resolution tools are available
        if [ "$HAS_RESOLVER" -eq 0 ]; then
            echo "Warning: No domain resolution tool (host, nslookup, getent) found. Skipping resolution check for $host."
            return 0
        fi

        # Attempt to resolve domain
        if host "$host" >/dev/null 2>&1 || nslookup "$host" >/dev/null 2>&1 || getent hosts "$host" >/dev/null 2>&1; then
            return 0
        else
            echo "Error: Unable to resolve domain $host. If this is a private domain, ensure your resolver is configured correctly."
            return 1
        fi
    else
        echo "Error: Invalid IP or domain format $host"
        return 1
    fi
}

# Validate address format (IP:port or domain:port)
validate_address() {
    local addr="$1"
    local is_local="$2"  # 1 for local (must be IP), 0 for remote (IP or domain)
    if [[ "$addr" =~ ^([^:]+):([0-9]+)$ ]]; then
        local host="${BASH_REMATCH[1]}"
        local port="${BASH_REMATCH[2]}"
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "${#port}" -gt 5 ] || [ "$port" -gt 65535 ]; then
            echo "Error: Port must be a number between 1 and 65535"
            return 1
        fi
        if [ "$is_local" = "1" ]; then
            if ! [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo "Error: Local address must be IP:port format"
                return 1
            fi
        else
            if ! validate_host "$host"; then
                return 1
            fi
        fi
        return 0
    else
        echo "Error: Invalid address format $addr (expected host:port)"
        return 1
    fi
}

# Check and start a single mapping
start_mapping() {
    local local_addr="$1"
    local remote_addr="$2"
    local local_ip=$(echo "$local_addr" | cut -d: -f1)
    local local_port=$(echo "$local_addr" | cut -d: -f2)
    local remote_host=$(echo "$remote_addr" | cut -d: -f1)
    local remote_port=$(echo "$remote_addr" | cut -d: -f2)

    # Check if port is occupied
    if netstat -tuln | grep -q ":$local_port "; then
        log "Port $local_port is already occupied, skipping start"
        return 1
    fi

    # Start socat process
    socat TCP-LISTEN:"$local_port",bind="$local_ip",reuseaddr,fork TCP:"$remote_host":"$remote_port" &
    local pid=$!
    log "Started mapping: $local_addr -> $remote_addr, PID: $pid"
    echo "$local_addr $remote_addr $pid" >> "$MAPPING_FILE"
    return 0
}

# Add port mapping
add_mapping() {
    if [ "$#" -ne 2 ]; then
        echo "Usage: $0 add <local IP:port> <remote IP or domain:port>"
        echo "Example: $0 add 127.0.0.1:8080 example.com:80"
        exit 1
    fi

    local local_addr="$1"
    local remote_addr="$2"

    # Validate addresses
    if ! validate_address "$local_addr" 1; then
        exit 1
    fi
    if ! validate_address "$remote_addr" 0; then
        exit 1
    fi

    # Check if identical mapping already exists
    if grep -q "^$local_addr" "$MAPPING_FILE"; then
        echo "Error: Mapping $local_addr already exists"
        exit 1
    fi

    # Start mapping
    if start_mapping "$local_addr" "$remote_addr"; then
        echo "Successfully added mapping: $local_addr -> $remote_addr"
    else
        echo "Error: Unable to add mapping $local_addr -> $remote_addr"
        exit 1
    fi
}

# Remove port mapping
remove_mapping() {
    if [ "$#" -ne 1 ]; then
        echo "Usage: $0 remove <local IP:port>"
        echo "Example: $0 remove 127.0.0.1:8080"
        exit 1
    fi

    local local_addr="$1"

    # Validate local address format
    if ! validate_address "$local_addr" 1; then
        exit 1
    fi

    # Find matching mapping
    mapping=$(grep "^$local_addr" "$MAPPING_FILE")
    if [ -z "$mapping" ]; then
        echo "Error: Mapping $local_addr not found"
        exit 1
    fi

    # Extract PID and terminate process
    pid=$(echo "$mapping" | awk '{print $3}')
    if kill -9 "$pid" 2>/dev/null; then
        log "Removed mapping: $local_addr, PID: $pid"
        # Delete mapping record
        grep -v "^$local_addr" "$MAPPING_FILE" > "${MAPPING_FILE}.tmp" && mv "${MAPPING_FILE}.tmp" "$MAPPING_FILE"
        echo "Successfully removed mapping: $local_addr"
    else
        echo "Warning: Process PID $pid does not exist, cleaning up record"
        grep -v "^$local_addr" "$MAPPING_FILE" > "${MAPPING_FILE}.tmp" && mv "${MAPPING_FILE}.tmp" "$MAPPING_FILE"
    fi
}

# List all mappings
list_mappings() {
    if [ ! -s "$MAPPING_FILE" ]; then
        echo "No active mappings currently"
        return
    fi

    echo "Current port mappings:"
    echo "Local address:port -> Remote address:port (PID)"
    echo "-----------------------------------"
    while IFS=' ' read -r local remote pid; do
        if ps -p "$pid" > /dev/null 2>&1; then
            echo "$local -> $remote ($pid)"
        else
            echo "$local -> $remote ($pid, invalid)"
        fi
    done < "$MAPPING_FILE"
}

# Restore all mappings
restore_mappings() {
    if [ ! -s "$MAPPING_FILE" ]; then
        log "No mapping records to restore"
        echo "No mapping records to restore"
        return
    fi

    echo "Restoring mappings..."
    # Temporary file for storing valid mappings
    : > "${MAPPING_FILE}.tmp"
    while IFS=' ' read -r local_addr remote_addr pid; do
        # Check if process still exists
        if ! ps -p "$pid" > /dev/null 2>&1; then
            log "Mapping $local_addr -> $remote_addr (PID: $pid) is invalid, attempting to restart"
            if start_mapping "$local_addr" "$remote_addr"; then
                echo "Restored mapping: $local_addr -> $remote_addr"
            else
                echo "Unable to restore mapping: $local_addr -> $remote_addr"
            fi
        else
            echo "$local_addr $remote_addr $pid" >> "${MAPPING_FILE}.tmp"
            echo "Mapping $local_addr -> $remote_addr (PID: $pid) is still running"
        fi
    done < "$MAPPING_FILE"
    mv "${MAPPING_FILE}.tmp" "$MAPPING_FILE"
}

# Show help information
show_help() {
    echo "Usage: $0 <command> [parameters]"
    echo "Commands:"
    echo "  add           <local IP:port> <remote IP or domain:port>  - Add a new port mapping"
    echo "  remove|del|rm <local IP:port>                             - Remove a specified port mapping"
    echo "  list|ls                                                    - List all active mappings"
    echo "  restore                                                    - Restore all failed mappings"
    echo "  help                                                       - Show this help information"
    echo "Example:"
    echo "  $0 add 127.0.0.1:8080 example.com:80"
    echo "  $0 rm 127.0.0.1:8080"
    echo "  $0 ls"
    echo "  $0 restore"
}


# Main logic
case "$1" in
    add)
        shift
        add_mapping "$@"
        ;;
    remove|rm|del)
        shift
        remove_mapping "$@"
        ;;
    list|ls)
        list_mappings
        ;;
    restore)
        restore_mappings
        ;;
    help)
        show_help
        ;;
    *)
        show_help
        exit 1
        ;;
esac