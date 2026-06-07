#!/usr/bin/env bash
# =============================================================================
# CLI RESOURCES SYNC SCRIPT
# 
# Synchronizes master config and skills from current directory to CLI default directories.
# Target CLIs: Mistral Vibe, Claude Code, Open Code (configurable)
# 
# Design Patterns Applied:
# - Single Responsibility Principle: Each function has one purpose
# - DRY (Don't Repeat Yourself): Reusable sync functions
# - Separation of Concerns: Configuration vs Logic
# - Template Method: Generic sync flow with specialized steps
# - Fail-Fast: Exit on errors with set -euo pipefail
# 
# Usage: ./setup.sh [OPTIONS] [CLI...]
#   If no arguments: Show help
#   Options:
#     --all    Sync to all configured CLIs
#     --help, -h  Show help message
#   Examples:
#     ./setup.sh                    # Show help
#     ./setup.sh --all              # Sync to all CLIs
#     ./setup.sh vibe               # Sync only to Vibe
#     ./setup.sh claude-code        # Sync to specific CLI
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION SECTION
# =============================================================================

# --- Target CLI Directories --------------------------------------------------
# Define the base directories for each CLI
# These can be customized by the user
declare -A CLI_TARGETS=(
    ["vibe"]="${HOME}/.vibe"
    ["claude-code"]="${HOME}/.claude-code/custom"
    ["open-code"]="${HOME}/.opencode"
    ["test-cli"]="./test-cli"
)

# --- Source Directories -------------------------------------------------------
# The script syncs from these directories in the current working directory
readonly SOURCE_DIR="$(pwd)"
readonly SKILLS_SRC="${SOURCE_DIR}/skills"
readonly MASTER_SRC="${SOURCE_DIR}/master"

# =============================================================================
# CONSTANTS & STYLES
# =============================================================================

# --- Colors -------------------------------------------------------------------
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly NC='\033[0m' # No Color

# =============================================================================
# LOGGING FUNCTIONS (Observer-like pattern for consistent messaging)
# =============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_header() {
    echo -e "\n${CYAN}=== $1 ===${NC}"
}

log_question() {
    echo -e "${MAGENTA}[?]${NC} $1"
}

# =============================================================================
# CORE FUNCTIONS (Strategy Pattern - interchangeable algorithms)
# =============================================================================

# --- Directory Management ------------------------------------------------------

# Ensures a directory exists, creates it if needed
# @param dir: The directory path to ensure
ensure_directory() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        log_info "Creating directory: $dir"
        mkdir -p "$dir" || {
            log_error "Failed to create directory: $dir"
            return 1
        }
    fi
    return 0
}

# --- File System Checks --------------------------------------------------------

# Checks if a path exists in the destination
# @param dest_dir: Base destination directory
# @param relative_path: Path relative to dest_dir
# @return: 0 if exists, 1 otherwise
path_exists_in_dest() {
    local dest_dir="$1"
    local relative_path="$2"
    [[ -e "${dest_dir}/${relative_path}" ]]
}

# --- Diff & Comparison ---------------------------------------------------------

# Shows a unified diff between source and destination files
# @param src: Source file path
# @param dest: Destination file path
show_diff() {
    local src="$1"
    local dest="$2"

    echo -e "\n${YELLOW}--- DIFF: Comparing files ---${NC}"
    echo "--- ${dest} (current/destination)"
    echo "+++ ${src} (new/source)"
    
    # Use diff with color if available, fallback to plain diff
    if command -v colordiff &> /dev/null; then
        diff -u "$dest" "$src" | colordiff || true
    else
        diff -u "$dest" "$src" || true
    fi
    
    echo "----------------------------------------"
}

# --- User Interaction --------------------------------------------------------

# Asks user for confirmation with default option
# @param message: The prompt message
# @param default: Default answer (y or n)
# @return: 0 for yes, 1 for no
confirm_action() {
    local message="$1"
    local default="${2:-n}"
    local choice

    if [[ "$default" == "y" ]]; then
        read -rp "$message [Y/n]: " choice
        [[ "$choice" =~ ^[Yy]$ ]] || [[ -z "$choice" ]]
    else
        read -rp "$message [y/N]: " choice
        [[ "$choice" =~ ^[Yy]$ ]]
    fi
}

# --- File Operations -----------------------------------------------------------

# Safely copies a file or directory with backup of existing destination
# @param src: Source path
# @param dest: Destination path
# @return: 0 on success, 1 on failure
safe_copy() {
    local src="$1"
    local dest="$2"

    # If destination exists, create backup
    if [[ -e "$dest" ]]; then
        local backup="${dest}.bak_$(date +%Y%m%d_%H%M%S)"
        log_info "Backing up existing: $dest -> $backup"
        cp -rf "$dest" "$backup" || {
            log_error "Failed to create backup: $dest"
            return 1
        }
    fi

    # Copy source to destination
    log_info "Copying: $src -> $dest"
    cp -rf "$src" "$dest" || {
        log_error "Failed to copy: $src -> $dest"
        return 1
    }
    
    return 0
}

# =============================================================================
# SYNC FUNCTIONS (Template Method Pattern)
# =============================================================================

# Creates the entire directory structure in destination
# @param src_dir: Source directory
# @param dest_dir: Destination base directory
# @param resource_type: Type of resource (skills or master)
sync_directories() {
    local src_dir="$1"
    local dest_dir="$2"
    local resource_type="$3"

    log_info "Syncing directory structure for ${resource_type}..."

    # Find all directories (excluding the root source directory)
    while IFS= read -r -d '' dir || [[ -n "$dir" ]]; do
        local relative_path="${dir#${src_dir}/}"
        local dest_path="${dest_dir}/${relative_path}"

        # Check if a file exists where we want to create a directory
        if [[ -f "$dest_path" ]]; then
            log_error "Conflict: cannot create directory '${relative_path}' - a file exists at destination"
            continue
        fi
        
        if ! ensure_directory "$dest_path"; then
            log_error "Failed to create directory structure for: ${relative_path}"
            continue
        fi
    done < <(find "$src_dir" -mindepth 1 -type d -print0)

    return 0
}

# Synchronizes files with diff comparison and user confirmation
# @param src_dir: Source directory
# @param dest_dir: Destination directory
# @param resource_type: Type of resource (skills or master)
# @param cli_name: Name of the target CLI
sync_files() {
    local src_dir="$1"
    local dest_dir="$2"
    local resource_type="$3"
    local cli_name="$4"
    local synced_count=0
    local skipped_count=0

    # Find all files in source directory
    while IFS= read -r -d '' file || [[ -n "$file" ]]; do
        local relative_path="${file#${src_dir}/}"
        local dest_path="${dest_dir}/${relative_path}"
        local diff_exit_code=0

        # Check if destination file exists
        if path_exists_in_dest "$dest_dir" "$relative_path"; then
            # Check if destination is a directory (we're trying to copy a file)
            if [[ -d "$dest_path" ]]; then
                log_error "Conflict: '${relative_path}' is a directory in destination but a file in source"
                skipped_count=$((skipped_count + 1))
                continue
            fi
            
            # Check if files are identical (nothing to do)
            diff -q "$dest_path" "$file" > /dev/null 2>&1 || true
            local diff_exit_code=${PIPESTATUS[0]}
            
            if [[ $diff_exit_code -eq 0 ]]; then
                log_info "Nothing to do: '${relative_path}' in ${cli_name} (files are identical)"
                skipped_count=$((skipped_count + 1))
                continue
            elif [[ $diff_exit_code -eq 2 ]]; then
                log_warning "Cannot compare files (binary or permission issue): '${relative_path}'"
            fi
            
            log_warning "Conflict in ${cli_name}: '${relative_path}' already exists"
            
            # Show diff between existing and new file
            show_diff "$file" "$dest_path"
            
            # Ask user for confirmation
            log_question "Overwrite '${relative_path}' in ${cli_name}?"
            if confirm_action "Continue with overwrite?" "n"; then
                if safe_copy "$file" "$dest_path"; then
                    synced_count=$((synced_count + 1))
                else
                    log_error "Failed to sync: ${relative_path}"
                fi
            else
                log_info "Skipped: ${relative_path} in ${cli_name}"
                skipped_count=$((skipped_count + 1))
            fi
        else
            # Destination doesn't exist, just copy
            ensure_directory "$(dirname "$dest_path")"
            if safe_copy "$file" "$dest_path"; then
                synced_count=$((synced_count + 1))
            else
                log_error "Failed to sync: ${relative_path}"
            fi
        fi
    done < <(find "$src_dir" -mindepth 1 -type f -print0)

    echo "  ${resource_type}: Synced=${synced_count}, Skipped=${skipped_count}"
    return 0
}

# Synchronizes a specific resource type to a specific CLI
# @param cli_name: Name of the CLI (key in CLI_TARGETS)
# @param resource_type: Either "skills" or "master"
sync_resource_to_cli() {
    local cli_name="$1"
    local resource_type="$2"
    local src_dir="${SOURCE_DIR}/${resource_type}"
    local dest_base="${CLI_TARGETS[$cli_name]}"
    local dest_dir="${dest_base}/${resource_type}"

    log_header "Syncing ${resource_type} to ${cli_name} (${dest_dir})"

    # Validate source directory exists
    if [[ ! -d "$src_dir" ]]; then
        log_warning "Source directory not found: $src_dir (resource: ${resource_type})"
        return 1
    fi

    # Create base destination directory
    ensure_directory "$dest_dir"

    # Sync directory structure first
    sync_directories "$src_dir" "$dest_dir" "$resource_type"

    # Sync files with conflict resolution
    sync_files "$src_dir" "$dest_dir" "$resource_type" "$cli_name"

    return 0
}

# =============================================================================
# VALIDATION FUNCTIONS
# =============================================================================

# Validates that source directories exist
validate_source() {
    if [[ ! -d "$SKILLS_SRC" ]]; then
        log_error "Skills source directory not found: $SKILLS_SRC"
        log_error "Please ensure there is a 'skills' directory in: $SOURCE_DIR"
        return 1
    fi

    if [[ ! -d "$MASTER_SRC" ]]; then
        log_error "Master source directory not found: $MASTER_SRC"
        log_error "Please ensure there is a 'master' directory in: $SOURCE_DIR"
        return 1
    fi

    return 0
}

# =============================================================================
# MAIN SYNC FUNCTION (Orchestrator - Command Pattern)
# =============================================================================

# Synchronizes resources to specified CLIs
# @param target_clis: Array of CLI names to sync to (default: all)
sync_all() {
    local target_clis=("$@")

    # If no arguments, use all CLIs
    if [[ ${#target_clis[@]} -eq 0 ]]; then
        target_clis=("${!CLI_TARGETS[@]}")
    fi

    log_header "STARTING CLI RESOURCES SYNCHRONIZATION"
    log_info "Source directory: ${SOURCE_DIR}"
    log_info "Target CLIs: ${target_clis[*]}"
    echo

    for cli in "${target_clis[@]}"; do
        log_header "Processing CLI: ${cli}"

        # Sync master config for this CLI
        sync_resource_to_cli "$cli" "master"

        # Sync skills for this CLI
        sync_resource_to_cli "$cli" "skills"

        echo
    done

    log_success "Synchronization completed successfully!"
    return 0
}

# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

# Shows help message
show_help() {
    echo -e "\n${CYAN}=== CLI RESOURCES SYNC SCRIPT ===${NC}"
    echo -e "Synchronizes master config and skills from current directory to CLI default directories."
    echo ""
    echo -e "${CYAN}Usage:${NC}"
    echo -e "  $(basename "$0") [OPTIONS] [CLI...]"
    echo ""
    echo -e "${CYAN}Options:${NC}"
    echo -e "  --all              Sync to ALL configured CLIs"
    echo -e "  --help, -h         Show this help message"
    echo ""
    echo -e "${CYAN}Available CLIs:${NC}"
    for cli in "${!CLI_TARGETS[@]}"; do
        echo -e "  - ${cli}          (${CLI_TARGETS[$cli]})"
    done
    echo ""
    echo -e "${CYAN}Examples:${NC}"
    echo -e "  $(basename "$0")                    # Show this help"
    echo -e "  $(basename "$0") --all              # Sync to all CLIs"
    echo -e "  $(basename "$0") vibe               # Sync only to Vibe"
    echo -e "  $(basename "$0") claude-code        # Sync to specific CLI"
    echo ""
}



main() {
    # Show help if --help or -h OR no arguments
    if [[ "$#" -eq 0 || ("$#" -gt 0 && ("$1" == "--help" || "$1" == "-h")) ]]; then
        show_help
        exit 0
    fi

    # Validate source directories exist
    if ! validate_source; then
        exit 1
    fi

    local target_clis=()
    
    # Handle --all flag
    if [[ "$1" == "--all" ]]; then
        target_clis=("${!CLI_TARGETS[@]}")
        shift
    else
        # Arguments provided as CLI names
        target_clis=("$@")
    fi

    # Validate target CLIs exist in CLI_TARGETS
    local valid_clis=()
    for cli in "${target_clis[@]}"; do
        if [[ -n "${CLI_TARGETS[$cli]+x}" ]]; then
            valid_clis+=("$cli")
        else
            log_error "Unknown CLI target: $cli. Available: ${!CLI_TARGETS[*]}"
            show_help
            exit 1
        fi
    done

    # Run the synchronization
    sync_all "${valid_clis[@]}"
}

# Execute main function with all arguments
main "$@"
