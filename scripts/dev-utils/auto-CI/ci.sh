#!/usr/bin/env bash

set -euo pipefail

# =============================================================================
# X Layer Optimism Local CI Script
# =============================================================================
# This script runs CI checks locally without GitHub Actions:
# 1. Pulls latest code from upstream
# 2. Runs Go linting (golangci-lint and go mod tidy check)
# 3. Runs Semgrep security scan
# 4. Runs ShellCheck on shell scripts
# 5. Checks for contract changes
# 6. Runs make build-contracts if contracts-bedrock changed
# 7. Runs test-unit (all tests, collecting all failures)
# 8. Runs contract tests (forge tests in contracts-bedrock)
# 9. Runs fraud proof tests (optional)
# 10. Runs Op-E2E Actions tests (optional)
# 11. Runs Contracts static checks (optional)
# 12. Runs Op-E2E WebSocket tests (optional)
# 13. Runs Op-E2E HTTP tests (optional)
# 14. Runs Cannon VM tests (optional)
# 15. Generates comprehensive summary
# 16. Sends Lark notification (if LARK_WEBHOOK_URL is set)
# 17. Stores logs in specified directory
#
# Build Artifact Reuse:
# - Contract artifacts are stored in packages/contracts-bedrock/:
#   * artifacts/
#   * forge-artifacts/
#   * cache/
# - If no changes are detected in contracts-bedrock and artifacts exist,
#   the build step is skipped and existing artifacts are reused.
#
# Test Execution:
# - Tests run with -v (verbose) flag to capture all t.Logf() output
# - Tests continue running even when some fail (no -failfast)
# - All failures are collected and summarized at the end
# - Detailed failure context is extracted and saved separately
#
# Dependencies:
# - Required: git, go, make, golangci-lint
# - Optional: just, semgrep, shellcheck (for additional checks)
# - To install all dependencies, run: ./install-ci-dependencies.sh
#
# Usage:
#   ./install-ci-dependencies.sh                   # First time: install dependencies
#   cp .example.env .env                           # Create configuration file
#   # Edit .env with your settings
#   ./ci.sh                                        # Run full CI (all checks and tests)
#   ./ci.sh -dev                                   # Run dev mode (quick: linting + unit tests only)
#
# Options:
#   -dev, --dev    Development mode - runs only essential checks:
#                  • Go linting (golangci-lint + go mod tidy)
#                  • Unit tests
#                  Skips: semgrep, shellcheck, contracts, other test suites, and Lark notifications
#
# Configuration:
#   All configuration is read from the .env file in the same directory.
#   Edit .env to change settings (repo path, branches, tests, notifications, etc.)
#   See .example.env for all available options.
# =============================================================================

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse command-line arguments
DEV_MODE=false
for arg in "$@"; do
    case "$arg" in
        -dev|--dev)
            DEV_MODE=true
            echo -e "${BLUE}[INFO]${NC} Running in DEV mode (quick checks only)"
            ;;
        *)
            echo -e "${RED}[ERROR]${NC} Unknown option: $arg"
            exit 1
            ;;
    esac
done

# Load configuration from .env file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}[ERROR]${NC} Configuration file not found: $ENV_FILE"
    echo -e "${YELLOW}[INFO]${NC} Please create .env file:"
    echo -e "  cd $SCRIPT_DIR"
    echo -e "  cp .example.env .env"
    echo -e "  # Edit .env with your configuration"
    exit 1
fi

echo -e "${BLUE}[INFO]${NC} Loading configuration from $ENV_FILE"
set -a  # automatically export all variables
source "$ENV_FILE"
set +a

# Validate required variables
if [ -z "$REPO_DIR" ]; then
    echo -e "${RED}[ERROR]${NC} REPO_DIR not set in .env"
    exit 1
fi

BASE_DATE=$(date +%Y%m%d)
BASE_DIR="${LOG_DIR:-./ci-logs}"
mkdir -p "$BASE_DIR"

COUNTER=$(find "$BASE_DIR" -maxdepth 1 -type d -name "${BASE_DATE}_*" \
           | sed -E "s/.*_${BASE_DATE}_?//; s/.*_//" \
           | sort -n | tail -1)

COUNTER=$(( ${COUNTER:- -1} + 1 ))
LOG_DIR="$BASE_DIR/${BASE_DATE}_${COUNTER}"


# =============================================================================
# Helper Functions
# =============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_section() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# Create log directory and log file
setup_logging() {
    # Create the log directory first
    mkdir -p "$LOG_DIR"
    
    # Resolve to absolute path
    LOG_DIR=$(cd "$LOG_DIR" && pwd)
    
    LOG_FILE="$LOG_DIR/ci.log"
    touch "$LOG_FILE"
    log_info "Logs will be stored in: $LOG_DIR"
}

# Log to both console and file
log_tee() {
    echo "$1" | tee -a "$LOG_FILE"
}

# =============================================================================
# Generic Test Runner Helpers
# =============================================================================

# Generic test runner that handles common boilerplate
# Usage: run_generic_test "Test Name" "test_key" "make command" ["phase_num"]
run_generic_test() {
    local test_name="$1"
    local test_key="$2"
    local test_command="$3"
    local phase_num="${4:-}"
    
    if [ -n "$phase_num" ]; then
        log_section "Phase $phase_num: $test_name"
    else
        log_section "$test_name"
    fi
    
    local test_log="$LOG_DIR/test-${test_key//_/-}.log"
    log_info "Test log: $test_log"
    log_info "Running $test_name..."
    
    local start_time
    start_time=$(date +%s)
    
    set +e
    $test_command 2>&1 | tee "$test_log"
    local exit_code=$?
    set -e
    
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    echo "$duration" > "$LOG_DIR/${test_key}_duration.txt"
    
    if [[ $exit_code -eq 0 ]]; then
        log_success "$test_name passed"
        log_success "Duration: $((duration / 60))m $((duration % 60))s"
        echo "success" > "$LOG_DIR/${test_key}_status.txt"
        return 0
    else
        log_error "$test_name failed"
        log_error "Duration: $((duration / 60))m $((duration % 60))s"
        echo "failed" > "$LOG_DIR/${test_key}_status.txt"
        return 1
    fi
}

# Get test status from file
get_test_status() {
    local test_key="$1"
    cat "$LOG_DIR/${test_key}_status.txt" 2>/dev/null || echo "unknown"
}

# Get test duration from file
get_test_duration() {
    local test_key="$1"
    cat "$LOG_DIR/${test_key}_duration.txt" 2>/dev/null || echo "0"
}

# Display test result in summary
display_test_result() {
    local test_name="$1"
    local test_key="$2"
    
    local status
    status=$(get_test_status "$test_key")
    local duration
    duration=$(get_test_duration "$test_key")
    
    local duration_str=""
    if [[ "$duration" != "0" ]] && [[ "$duration" != "unknown" ]]; then
        duration_str=" ($((duration / 60))m $((duration % 60))s)"
    fi
    
    case "$status" in
        success)
            echo "✅ $test_name: SUCCESS$duration_str"
            ;;
        failed)
            echo "❌ $test_name: FAILED$duration_str"
            ;;
        skipped)
            echo "⏭️  $test_name: SKIPPED"
            ;;
        unknown)
            echo "⏭️  $test_name: NOT RUN"
            ;;
        *)
            echo "❓ $test_name: $status$duration_str"
            ;;
    esac
    
    # Show failure details if test failed
    if [[ "$status" == "failed" ]]; then
        local log_file="$LOG_DIR/test-${test_key//_/-}.log"
        if [[ -f "$log_file" ]]; then
            # Show first few failure lines
            echo "   First failures:"
            grep -i "FAIL\|ERROR" "$log_file" 2>/dev/null | head -5 | sed 's/^/   /' || true
        fi
    fi
}

# Check if test passed (for overall status checking)
test_passed() {
    local test_key="$1"
    local optional="${2:-false}"
    
    local status
    status=$(get_test_status "$test_key")
    
    if [[ "$optional" == "true" ]]; then
        [[ "$status" == "success" ]] || [[ "$status" == "unknown" ]] || [[ "$status" == "skipped" ]]
    else
        [[ "$status" == "success" ]]
    fi
}

# Display test result with duration (simplified version without failure details)
display_test_with_duration() {
    local test_name="$1"
    local test_key="$2"
    
    local status=$(get_test_status "$test_key")
    local duration=$(get_test_duration "$test_key")
    
    local duration_str=""
    if [[ "$duration" != "0" ]] && [[ "$duration" != "unknown" ]]; then
        duration_str=" ($((duration / 60))m $((duration % 60))s)"=
    fi
    
    case "$status" in
        success)
            echo "✅ $test_name: SUCCESS$duration_str"
            ;;
        failed)
            echo "❌ $test_name: FAILED$duration_str"
            ;;
        skipped)
            echo "⏭️  $test_name: SKIPPED"
            ;;
        unknown)
            echo "❓ $test_name: NOT RUN"
            ;;
        *)
            echo "❓ $test_name: $status$duration_str"
            ;;
    esac
}

# Display a simple phase result (for non-test phases like linting)
display_phase_result() {
    local phase_name="$1"
    local status_key="$2"
    
    local status
    status=$(cat "$LOG_DIR/${status_key}_status.txt" 2>/dev/null || echo "unknown")
    
    case "$status" in
        success)
            echo "✅ $phase_name: SUCCESS"
            ;;
        failed)
            echo "❌ $phase_name: FAILED"
            ;;
        warning)
            echo "⚠️  $phase_name: COMPLETED WITH FINDINGS"
            ;;
        skipped)
            echo "⏭️  $phase_name: SKIPPED"
            ;;
        reused)
            echo "♻️  $phase_name: REUSED (no changes, using cached artifacts)"
            ;;
        *)
            echo "❓ $phase_name: UNKNOWN"
            ;;
    esac
}

# Display result with dev mode handling
display_result_with_dev_mode() {
    local phase_name="$1"
    local status_key="$2"
    
    if [ "$DEV_MODE" = "true" ]; then
        echo "⏭️  $phase_name: SKIPPED (dev mode)"
    else
        display_phase_result "$phase_name" "$status_key"
    fi
}

# Display failure log location if a test/check failed
show_failure_logs() {
    local name="$1"
    local status_key="$2"
    local log_file="$3"
    
    local status=$(get_test_status "$status_key")
    
    if [[ "$status" == "failed" ]] || [[ "$status" == "warning" ]]; then
        echo ""
        if [[ "$status" == "warning" ]]; then
            echo "$name Findings:"
        else
            echo "$name Failure Information:"
        fi
        echo "  📄 Full log:           $log_file"
        
        # Special handling for unit tests
        if [[ "$status_key" == "unit_test" ]] && [[ "$status" == "failed" ]]; then
            [[ -f "$LOG_DIR/test-failures-summary.txt" ]] && echo "  📋 Failed tests list:  $LOG_DIR/test-failures-summary.txt"
            [[ -f "$LOG_DIR/test-failures-detail.log" ]] && echo "  🔍 Failure context:    $LOG_DIR/test-failures-detail.log"
            [[ -f "$LOG_DIR/test-failures.log" ]] && echo "  ⚠️  All failure lines: $LOG_DIR/test-failures.log"
        fi
    fi
}

# =============================================================================
# Phase 0: Setup and Validation
# =============================================================================

print_usage() {
    cat << EOF
Usage: $0 [REPO_DIR]

Environment Variables:
  REPO_DIR          Path to optimism repository (default: /data1/brendon/xlayer-repos/optimism)
  LOG_DIR           Path to store CI logs (default: ./ci-logs/TIMESTAMP)
  TEST_FILTER       Filter to run specific tests (e.g., TestBatcherAutoDA)
  LARK_WEBHOOK_URL  Lark webhook URL for notifications (optional)
  FORCE_REBUILD     Force rebuild of fraud proof binaries (default: false)

Examples:
  $0                                                # Uses default repo directory
  $0 /path/to/optimism                              # Uses specified directory
  REPO_DIR=/path/to/optimism $0                     # Uses REPO_DIR env var
  REPO_DIR=/path/to/optimism LOG_DIR=/tmp/logs $0   # Custom log directory
  TEST_FILTER=TestBatcherAutoDA $0                  # Run only specific test
  LARK_WEBHOOK_URL=https://... $0                   # Send notifications to Lark
  FORCE_REBUILD=true $0                             # Force rebuild fraud proof binaries

Binary Caching:
  Fraud proof test binaries are automatically cached and only rebuilt if:
  - Binaries don't exist
  - Source files are newer than binaries
  - FORCE_REBUILD=true is set

EOF
}

setup_environment() {
    log_section "Phase 0: Setup and Validation"
    
    # Validate REPO_DIR is provided
    if [[ -z "$REPO_DIR" ]]; then
        log_error "Repository directory not specified"
        echo ""
        print_usage
        exit 1
    fi
    
    # Resolve to absolute path
    REPO_DIR=$(cd "$REPO_DIR" && pwd)
    log_info "Repository directory: $REPO_DIR"
    
    # Check if directory exists
    if [[ ! -d "$REPO_DIR" ]]; then
        log_error "Repository directory does not exist: $REPO_DIR"
        exit 1
    fi
    
    # Change to repository directory
    cd "$REPO_DIR" || {
        log_error "Failed to change to repository directory: $REPO_DIR"
        exit 1
    }
    
    log_success "Changed to repository directory: $REPO_DIR"
    
    # Check if we're in the optimism repo
    if [[ ! -f "go.mod" ]] || ! grep -q "github.com/ethereum-optimism/optimism" go.mod 2>/dev/null; then
        log_error "Not a valid optimism repository: $REPO_DIR"
        log_error "Expected to find go.mod with github.com/ethereum-optimism/optimism"
        exit 1
    fi
    
    log_success "Repository validated"
    
    # Check required tools
    local required_tools=("git" "go" "make")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            log_error "$tool is not installed"
            exit 1
        fi
        log_success "$tool found: $(command -v $tool)"
    done
    
    # Check for uncommitted changes
    if [[ -n $(git status --porcelain) ]]; then
        log_warning "You have uncommitted changes. They will be preserved during upstream sync."
        git status --short
    fi
}

# =============================================================================
# Phase 1: Sync from Upstream
# =============================================================================

sync_upstream() {
    log_section "Phase 1: Sync from Upstream"
    
    local current_branch
    current_branch=$(git branch --show-current)
    log_info "Current branch: $current_branch"
    
    # Add upstream remote if it doesn't exist
    if ! git remote | grep -q "^upstream$"; then
        log_info "Adding upstream remote: $UPSTREAM_REPO"
        git remote add upstream "$UPSTREAM_REPO"
    else
        log_info "Upstream remote already exists"
    fi
    
    # Show remotes
    log_info "Git remotes:"
    git remote -v | tee -a "$LOG_FILE"
    
    # Fetch upstream
    log_info "Fetching from upstream/$UPSTREAM_BRANCH..."
    if git fetch upstream "$UPSTREAM_BRANCH" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Fetch completed"
    else
        log_error "Failed to fetch from upstream"
        exit 1
    fi
    
    # Checkout to the target branch
    log_info "Checking out to branch: $UPSTREAM_BRANCH..."
    if git show-ref --verify --quiet "refs/heads/$UPSTREAM_BRANCH"; then
        # Local branch exists, checkout to it
        log_info "Local branch $UPSTREAM_BRANCH exists, checking out..."
        if git checkout "$UPSTREAM_BRANCH" 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Checked out to $UPSTREAM_BRANCH"
        else
            log_error "Failed to checkout to $UPSTREAM_BRANCH"
            exit 1
        fi
    else
        # Local branch doesn't exist, create it tracking upstream
        log_info "Local branch $UPSTREAM_BRANCH doesn't exist, creating from upstream..."
        if git checkout -b "$UPSTREAM_BRANCH" "upstream/$UPSTREAM_BRANCH" 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Created and checked out to $UPSTREAM_BRANCH"
        else
            log_error "Failed to create branch $UPSTREAM_BRANCH"
            exit 1
        fi
    fi
    
    # Get commit before merge
    local before_commit
    before_commit=$(git rev-parse HEAD)
    
    # Attempt merge
    log_info "Attempting to merge upstream/$UPSTREAM_BRANCH..."
    if git merge --no-edit "upstream/$UPSTREAM_BRANCH" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Merge successful"
        
        # Get commit after merge
        local after_commit
        after_commit=$(git rev-parse HEAD)
        
        # Show changes
        if [[ "$before_commit" != "$after_commit" ]]; then
            log_info "Recent upstream changes:"
            git log --oneline --graph --decorate -10 "$before_commit..$after_commit" | tee -a "$LOG_FILE"
        else
            log_info "Already up to date with upstream"
        fi
        
        # Store commit info
        echo "$before_commit" > "$LOG_DIR/before_merge_commit.txt"
        echo "$after_commit" > "$LOG_DIR/after_merge_commit.txt"
    else
        log_error "Merge conflict detected"
        log_error "Please resolve conflicts manually:"
        log_error "  1. Run: git merge upstream/$UPSTREAM_BRANCH"
        log_error "  2. Resolve conflicts"
        log_error "  3. Run: git merge --continue"
        log_error "  4. Re-run this CI script"
        git merge --abort 2>/dev/null || true
        exit 1
    fi
}

# =============================================================================
# Phase 2: Go Linting
# =============================================================================

run_go_linting() {
    log_section "Phase 2: Go Linting"
    
    local lint_log="$LOG_DIR/lint-go.log"
    log_info "Go linting log: $lint_log"
    
    # Check if golangci-lint is installed
    if ! command -v golangci-lint &> /dev/null; then
        log_error "golangci-lint is not installed. Please run:"
        log_error "  ./install-ci-dependencies.sh"
        echo "failed" > "$LOG_DIR/lint_go_status.txt"
        return 1
    fi
    
    log_info "Running golangci-lint..."
    
    set +e  # Temporarily disable exit on error
    golangci-lint run --timeout=10m 2>&1 | tee "$lint_log"
    local lint_exit_code=$?
    set -e  # Re-enable exit on error
    
    # Check go mod tidy
    log_info "Checking go mod tidy..."
    go mod tidy
    if git diff --exit-code go.mod go.sum >> "$lint_log" 2>&1; then
        log_success "go.mod and go.sum are tidy"
    else
        log_error "go.mod or go.sum needs tidying"
        lint_exit_code=1
    fi
    
    if [[ $lint_exit_code -eq 0 ]]; then
        log_success "Go linting passed"
        echo "success" > "$LOG_DIR/lint_go_status.txt"
    else
        log_error "Go linting failed"
        echo "failed" > "$LOG_DIR/lint_go_status.txt"
        log_error "Full output: $lint_log"
        return 1
    fi
}

# =============================================================================
# Phase 3: Semgrep Security Scan
# =============================================================================

run_semgrep_scan() {
    log_section "Phase 3: Semgrep Security Scan"
    
    local semgrep_log="$LOG_DIR/semgrep-scan.log"
    log_info "Semgrep scan log: $semgrep_log"
    
    # Check if semgrep is installed
    if ! command -v semgrep &> /dev/null; then
        log_warning "semgrep is not installed. Skipping security scan."
        log_info "To install all dependencies, run: ./install-ci-dependencies.sh"
        echo "skipped" > "$LOG_DIR/semgrep_status.txt"
        return 0
    fi
    
    # Check if just is installed
    if ! command -v just &> /dev/null; then
        log_warning "just is not installed. Skipping semgrep scan."
        log_info "To install all dependencies, run: ./install-ci-dependencies.sh"
        echo "skipped" > "$LOG_DIR/semgrep_status.txt"
        return 0
    fi
    
    # Check if custom semgrep rules exist
    if [ ! -d ".semgrep/rules" ]; then
        log_info "No custom semgrep rules found at .semgrep/rules, skipping..."
        echo "skipped" > "$LOG_DIR/semgrep_status.txt"
        return 0
    fi
    
    log_info "Running semgrep security scan..."
    
    set +e  # Temporarily disable exit on error
    just semgrep 2>&1 | tee "$semgrep_log"
    local semgrep_exit_code=$?
    set -e  # Re-enable exit on error
    
    if [[ $semgrep_exit_code -eq 0 ]]; then
        log_success "Semgrep scan completed successfully"
        echo "success" > "$LOG_DIR/semgrep_status.txt"
    else
        log_warning "Semgrep scan completed with findings"
        echo "warning" > "$LOG_DIR/semgrep_status.txt"
        log_info "Full output: $semgrep_log"
    fi
}

# =============================================================================
# Phase 4: Shell Script Check
# =============================================================================

run_shellcheck() {
    log_section "Phase 4: Shell Script Check"
    
    local shellcheck_log="$LOG_DIR/shellcheck.log"
    log_info "ShellCheck log: $shellcheck_log"
    
    # Check if shellcheck is installed
    if ! command -v shellcheck &> /dev/null; then
        log_warning "shellcheck is not installed. Skipping shell script check."
        log_info "To install all dependencies, run: ./install-ci-dependencies.sh"
        echo "skipped" > "$LOG_DIR/shellcheck_status.txt"
        return 0
    fi
    
    # Check if just is installed
    if ! command -v just &> /dev/null; then
        log_warning "just is not installed. Skipping shellcheck."
        log_info "To install all dependencies, run: ./install-ci-dependencies.sh"
        echo "skipped" > "$LOG_DIR/shellcheck_status.txt"
        return 0
    fi
    
    log_info "Running ShellCheck..."
    
    set +e  # Temporarily disable exit on error
    just shellcheck 2>&1 | tee "$shellcheck_log"
    local shellcheck_exit_code=$?
    set -e  # Re-enable exit on error
    
    if [[ $shellcheck_exit_code -eq 0 ]]; then
        log_success "ShellCheck passed"
        echo "success" > "$LOG_DIR/shellcheck_status.txt"
    else
        log_warning "ShellCheck completed with findings"
        echo "warning" > "$LOG_DIR/shellcheck_status.txt"
        log_info "Full output: $shellcheck_log"
    fi
}

# =============================================================================
# Phase 5: Check for Contract Changes
# =============================================================================

check_contract_changes() {
    log_section "Phase 5: Check for Contract Changes"
    
    local before_commit after_commit
    before_commit=$(cat "$LOG_DIR/before_merge_commit.txt" 2>/dev/null || echo "")
    after_commit=$(cat "$LOG_DIR/after_merge_commit.txt" 2>/dev/null || echo "")
    
    if [[ -z "$before_commit" ]] || [[ "$before_commit" == "$after_commit" ]]; then
        log_info "No new commits from upstream, checking for local changes in $CONTRACTS_DIR..."
        
        # Check if there are uncommitted changes in contracts directory
        if git diff --name-only "$CONTRACTS_DIR" | grep -q .; then
            log_warning "Found uncommitted changes in $CONTRACTS_DIR"
            echo "true" > "$LOG_DIR/contracts_changed.txt"
            return 0
        else
            log_info "No changes in $CONTRACTS_DIR"
            echo "false" > "$LOG_DIR/contracts_changed.txt"
            return 1
        fi
    fi
    
    # Check if contracts changed in the merge
    log_info "Checking for changes in $CONTRACTS_DIR between $before_commit and $after_commit..."
    
    if git diff --name-only "$before_commit" "$after_commit" | grep -q "^$CONTRACTS_DIR/"; then
        log_success "Changes detected in $CONTRACTS_DIR"
        git diff --name-only "$before_commit" "$after_commit" -- "$CONTRACTS_DIR/" | tee -a "$LOG_FILE"
        echo "true" > "$LOG_DIR/contracts_changed.txt"
        return 0
    else
        log_info "No changes in $CONTRACTS_DIR"
        echo "false" > "$LOG_DIR/contracts_changed.txt"
        return 1
    fi
}

# =============================================================================
# Phase 6: Build Contracts (if needed)
# =============================================================================

build_contracts() {
    log_section "Phase 6: Build Contracts"
    
    local contracts_changed
    contracts_changed=$(cat "$LOG_DIR/contracts_changed.txt" 2>/dev/null || echo "false")
    
    # Check if build artifacts exist
    local artifacts_exist=true
    local artifacts_dir="$REPO_DIR/$CONTRACTS_DIR"
    
    log_info "Checking for existing build artifacts in $artifacts_dir..."
    
    # Required artifact directories
    local required_artifacts=(
        "artifacts"
        "forge-artifacts"
        "cache"
    )
    
    for artifact in "${required_artifacts[@]}"; do
        if [[ ! -d "$artifacts_dir/$artifact" ]] || [[ -z "$(ls -A "$artifacts_dir/$artifact" 2>/dev/null)" ]]; then
            log_warning "Artifact directory missing or empty: $artifact"
            artifacts_exist=false
            break
        else
            log_info "✓ Found artifact: $artifact"
        fi
    done
    
    # Decide whether to build
    if [[ "$contracts_changed" == "true" ]]; then
        log_info "Building contracts due to detected changes..."
        
        local build_log="$LOG_DIR/build-contracts.log"
        log_info "Build log: $build_log"
        
        if make build-contracts 2>&1 | tee "$build_log"; then
            log_success "Contracts built successfully"
            echo "success" > "$LOG_DIR/build_status.txt"
        else
            log_error "Contract build failed"
            echo "failed" > "$LOG_DIR/build_status.txt"
            log_error "Check build log: $build_log"
            exit 1
        fi
    elif [[ "$artifacts_exist" == "false" ]]; then
        log_warning "Build artifacts not found or incomplete"
        log_info "Building contracts to generate artifacts..."
        
        local build_log="$LOG_DIR/build-contracts.log"
        log_info "Build log: $build_log"
        
        if make build-contracts 2>&1 | tee "$build_log"; then
            log_success "Contracts built successfully"
            echo "success" > "$LOG_DIR/build_status.txt"
        else
            log_error "Contract build failed"
            echo "failed" > "$LOG_DIR/build_status.txt"
            log_error "Check build log: $build_log"
            exit 1
        fi
    else
        log_success "No changes detected and build artifacts exist"
        log_info "Reusing existing contract artifacts"
        log_info "  - artifacts: $artifacts_dir/artifacts"
        log_info "  - forge-artifacts: $artifacts_dir/forge-artifacts"
        log_info "  - cache: $artifacts_dir/cache"
        echo "reused" > "$LOG_DIR/build_status.txt"
    fi
}

# =============================================================================
# Phase 7: Run Unit Tests
# =============================================================================

run_unit_tests() {
    log_section "Phase 7: Run Unit Tests"
    
    local test_log="$LOG_DIR/test-unit.log"
    log_info "Test log: $test_log"
    
    if [[ -n "$TEST_FILTER" ]]; then
        log_info "Running filtered tests: $TEST_FILTER"
        log_info "Test filter applied - running subset of tests for faster debugging"
    else
        log_info "Running all unit tests with verbose output for better error diagnostics..."
        log_info "This may take a while (typically 10-30 minutes)..."
        log_info "Note: Tests will continue running even if some fail (no -failfast)"
    fi
    
    local test_start
    test_start=$(date +%s)
    
    # Run with -v flag for verbose output to capture t.Logf() messages even on failure
    # If TEST_FILTER is set, add -run flag to filter specific tests
    # Do NOT use -failfast so all tests run and we collect all failures
    local test_flags="-v"
    if [[ -n "$TEST_FILTER" ]]; then
        test_flags="$test_flags -run $TEST_FILTER"
    fi
    
    # Always run all tests regardless of individual failures to collect complete failure data
    # Note: We explicitly do NOT use -failfast to ensure all tests run
    set +e  # Temporarily disable exit on error
    GOFLAGS="$test_flags" make test-unit 2>&1 | tee "$test_log"
    local test_exit_code=$?
    set -e  # Re-enable exit on error
    
    local test_end
    test_end=$(date +%s)
    local duration=$((test_end - test_start))
    
    # Extract and analyze failures regardless of exit code
    log_info "Extracting test results..."
    local failures_log="$LOG_DIR/test-failures.log"
    local failures_detail="$LOG_DIR/test-failures-detail.log"
    local failures_summary="$LOG_DIR/test-failures-summary.txt"
    
    {
        grep -E "^--- FAIL:" "$test_log" || true
        grep -E "^FAIL\s+" "$test_log" || true
        grep -E "^\# .* \[build failed\]" "$test_log" || true
        grep -i "panic:" "$test_log" || true
        grep -i "context deadline exceeded" "$test_log" || true
    } | sort -u > "$failures_log"
    
    # Extract more detailed failure context (100 lines before each FAIL)
    grep -B 100 -E "^--- FAIL:" "$test_log" > "$failures_detail" 2>/dev/null || true
    
    # Generate a summary of unique failing tests
    grep -E "^--- FAIL:" "$test_log" | awk '{print $3}' | sort -u > "$failures_summary" 2>/dev/null || true
    
    if [[ $test_exit_code -eq 0 ]]; then
        log_success "All unit tests passed"
        log_success "Test duration: $((duration / 60))m $((duration % 60))s"
        echo "success" > "$LOG_DIR/unit_test_status.txt"
        echo "$duration" > "$LOG_DIR/unit_test_duration.txt"
    else
        log_error "Some unit tests failed"
        log_error "Test duration: $((duration / 60))m $((duration % 60))s"
        echo "failed" > "$LOG_DIR/unit_test_status.txt"
        echo "$duration" > "$LOG_DIR/unit_test_duration.txt"
        
        if [[ -s "$failures_summary" ]]; then
            local fail_count
            fail_count=$(wc -l < "$failures_summary")
            log_error "Failed tests ($fail_count unique):"
            cat "$failures_summary" | while read -r test_name; do
                log_error "  ❌ $test_name"
            done
            echo ""
            log_error "Failure logs:"
            log_error "  - Summary: $failures_summary"
            log_error "  - All failures: $failures_log"
            log_error "  - Detailed context: $failures_detail"
            log_error "  - Full output: $test_log"
        fi
        
        # Don't exit immediately - let the script continue to generate summary
        return 1
    fi
}

# =============================================================================
# Phase 8: Run Contract Tests
# =============================================================================

run_contract_tests() {
    log_section "Phase 8: Run Contract Tests"
    
    local test_log="$LOG_DIR/test-contracts.log"
    log_info "Contract test log: $test_log"
    
    # Check if just is installed
    if ! command -v just &> /dev/null; then
        log_error "just is not installed. Please run:"
        log_error "  ./install-ci-dependencies.sh"
        echo "failed" > "$LOG_DIR/contract_test_status.txt"
        return 1
    fi
    
    log_info "Running contract tests..."
    log_info "This will run forge tests in packages/contracts-bedrock"
    
    local test_start
    test_start=$(date +%s)
    
    # Run contract tests
    set +e  # Temporarily disable exit on error
    (cd "$REPO_DIR/packages/contracts-bedrock" && just test) 2>&1 | tee "$test_log"
    local test_exit_code=$?
    set -e  # Re-enable exit on error
    
    local test_end
    test_end=$(date +%s)
    local duration=$((test_end - test_start))
    
    if [[ $test_exit_code -eq 0 ]]; then
        log_success "All contract tests passed"
        log_success "Test duration: $((duration / 60))m $((duration % 60))s"
        echo "success" > "$LOG_DIR/contract_test_status.txt"
        echo "$duration" > "$LOG_DIR/contract_test_duration.txt"
    else
        log_error "Some contract tests failed"
        log_error "Test duration: $((duration / 60))m $((duration % 60))s"
        echo "failed" > "$LOG_DIR/contract_test_status.txt"
        echo "$duration" > "$LOG_DIR/contract_test_duration.txt"
        log_error "Full output: $test_log"
        
        # Don't exit immediately - let the script continue to generate summary
        return 1
    fi
}

# =============================================================================
# Helper: Check if fraud proof binaries need rebuilding
# =============================================================================

check_fraud_proof_binaries() {
    log_info "Checking fraud proof binary cache..."
    
    # List of required binaries and their source directories
    local required_binaries=(
        "bin/cannon"
        "op-program/bin/op-program-client"
        "op-program/bin/op-program-host"
        "op-program/bin/op-program-client.elf"
        "op-program/bin/prestate-proof-mt.json"
        "op-program/bin/prestate-proof-mt64.json"
    )
    
    local all_exist=true
    local oldest_binary_time=999999999999
    
    # Check if all binaries exist
    for binary in "${required_binaries[@]}"; do
        if [[ ! -f "$REPO_DIR/$binary" ]]; then
            log_info "Binary not found: $binary"
            all_exist=false
            break
        fi
        
        # Get modification time of binary
        local binary_time
        binary_time=$(stat -c %Y "$REPO_DIR/$binary" 2>/dev/null || stat -f %m "$REPO_DIR/$binary" 2>/dev/null)
        if [[ $binary_time -lt $oldest_binary_time ]]; then
            oldest_binary_time=$binary_time
        fi
    done
    
    if [[ "$all_exist" == "false" ]]; then
        log_warning "Some binaries are missing - rebuild required"
        return 1
    fi
    
    log_success "All binaries exist"
    
    # Check if source files are newer than binaries
    local source_dirs=(
        "cannon"
        "op-program"
    )
    
    local newest_source_time=0
    for dir in "${source_dirs[@]}"; do
        # Find newest .go file in the directory
        local newest_file
        newest_file=$(find "$REPO_DIR/$dir" -name "*.go" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
        
        if [[ -n "$newest_file" ]]; then
            local file_time
            file_time=$(stat -c %Y "$newest_file" 2>/dev/null || stat -f %m "$newest_file" 2>/dev/null)
            if [[ $file_time -gt $newest_source_time ]]; then
                newest_source_time=$file_time
            fi
        fi
    done
    
    if [[ $newest_source_time -gt $oldest_binary_time ]]; then
        log_warning "Source files are newer than binaries - rebuild required"
        log_info "Newest source: $(date -d @$newest_source_time '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r $newest_source_time '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
        log_info "Oldest binary: $(date -d @$oldest_binary_time '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r $oldest_binary_time '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
        return 1
    fi
    
    log_success "Binaries are up to date - using cached versions"
    return 0
}

# =============================================================================
# Phase 9: Run Fraud Proof Tests
# =============================================================================

run_fraud_proof_tests() {
    log_section "Phase 9: Run Fraud Proof Tests"
    
    local test_log="$LOG_DIR/test-fraud-proofs.log"
    local build_log="$LOG_DIR/fraud-proof-build.log"
    log_info "Fraud proof test log: $test_log"
    log_info "Build log: $build_log"
    
    # Check if we can use cached binaries
    local need_build=false
    if [[ "${FORCE_REBUILD:-false}" == "true" ]]; then
        log_warning "FORCE_REBUILD=true - forcing rebuild of all binaries"
        need_build=true
    elif ! check_fraud_proof_binaries; then
        need_build=true
    fi
    
    if [[ "$need_build" == "true" ]]; then
        # Build required dependencies for fraud proof tests
        log_info "Building fraud proof test dependencies (this may take a while)..."
        log_info "Building: op-program-client, op-program-host, cannon, cannon-prestates"
        
        local build_start
        build_start=$(date +%s)
        
        set +e  # Temporarily disable exit on error
        {
            log_info "Building op-program-client..."
            make op-program-client
            
            log_info "Building op-program-host..."
            make op-program-host
            
            log_info "Building cannon..."
            make cannon
            
            log_info "Building cannon-prestates (this is the slowest step)..."
            make cannon-prestates
            
            log_info "Running pre-test setup..."
            make make-pre-test
        } 2>&1 | tee "$build_log"
        local build_exit_code=$?
        set -e  # Re-enable exit on error
        
        local build_end
        build_end=$(date +%s)
        local build_duration=$((build_end - build_start))
        
        if [[ $build_exit_code -ne 0 ]]; then
            log_error "Failed to build fraud proof test dependencies"
            log_error "Build duration: $((build_duration / 60))m $((build_duration % 60))s"
            log_error "Build log: $build_log"
            echo "failed" > "$LOG_DIR/fraud_proof_test_status.txt"
            return 1
        fi
        
        log_success "Fraud proof test dependencies built successfully"
        log_success "Build duration: $((build_duration / 60))m $((build_duration % 60))s"
        echo "built" > "$LOG_DIR/fraud_proof_build_status.txt"
    else
        log_success "Using cached fraud proof binaries - skipping build"
        echo "cached" > "$LOG_DIR/fraud_proof_build_status.txt"
    fi
    
    # Make binaries executable
    chmod +x bin/* 2>/dev/null || true
    chmod +x op-program/bin/* 2>/dev/null || true
    
    log_info "Running fraud proof tests..."
    
    local test_start
    test_start=$(date +%s)
    
    # Run fraud proof tests
    set +e  # Temporarily disable exit on error
    make go-tests-fraud-proofs-ci 2>&1 | tee "$test_log"
    local test_exit_code=$?
    set -e  # Re-enable exit on error
    
    local test_end
    test_end=$(date +%s)
    local duration=$((test_end - test_start))
    local total_duration=$((build_duration + duration))
    
    if [[ $test_exit_code -eq 0 ]]; then
        log_success "All fraud proof tests passed"
        log_success "Test duration: $((duration / 60))m $((duration % 60))s"
        log_success "Total duration (build + test): $((total_duration / 60))m $((total_duration % 60))s"
        echo "success" > "$LOG_DIR/fraud_proof_test_status.txt"
        echo "$duration" > "$LOG_DIR/fraud_proof_test_duration.txt"
    else
        log_error "Some fraud proof tests failed"
        log_error "Test duration: $((duration / 60))m $((duration % 60))s"
        log_error "Total duration (build + test): $((total_duration / 60))m $((total_duration % 60))s"
        echo "failed" > "$LOG_DIR/fraud_proof_test_status.txt"
        echo "$duration" > "$LOG_DIR/fraud_proof_test_duration.txt"
        log_error "Full output: $test_log"
        log_error "Build log: $build_log"
        
        # Don't exit immediately - let the script continue to generate summary
        return 1
    fi
}

# =============================================================================
# Phase 10: Run Op-E2E Actions Tests
# =============================================================================

run_op_e2e_actions_tests() {
    log_section "Phase 10: Run Op-E2E Actions Tests"
    
    local test_log="$LOG_DIR/test-op-e2e-actions.log"
    log_info "Op-E2E Actions test log: $test_log"
    
    log_info "Running Op-E2E Actions tests..."
    
    local test_start
    test_start=$(date +%s)
    
    # Run Actions tests
    set +e  # Temporarily disable exit on error
    (cd "$REPO_DIR/op-e2e" && make test-actions) 2>&1 | tee "$test_log"
    local test_exit_code=$?
    set -e  # Re-enable exit on error
    
    local test_end
    test_end=$(date +%s)
    local duration=$((test_end - test_start))
    
    if [[ $test_exit_code -eq 0 ]]; then
        log_success "All Op-E2E Actions tests passed"
        log_success "Test duration: $((duration / 60))m $((duration % 60))s"
        echo "success" > "$LOG_DIR/op_e2e_actions_test_status.txt"
        echo "$duration" > "$LOG_DIR/op_e2e_actions_test_duration.txt"
    else
        log_error "Some Op-E2E Actions tests failed"
        log_error "Test duration: $((duration / 60))m $((duration % 60))s"
        echo "failed" > "$LOG_DIR/op_e2e_actions_test_status.txt"
        echo "$duration" > "$LOG_DIR/op_e2e_actions_test_duration.txt"
        log_error "Full output: $test_log"
        
        # Don't exit immediately - let the script continue to generate summary
        return 1
    fi
}

# =============================================================================
# Phase 11: Run Contracts Static Checks
# =============================================================================

run_contracts_static_checks() {
    log_section "Phase 11: Run Contracts Static Checks"
    
    local test_log="$LOG_DIR/test-contracts-static.log"
    log_info "Contracts static checks log: $test_log"
    
    # Check if just is installed
    if ! command -v just &> /dev/null; then
        log_error "just is not installed. Please run:"
        log_error "  ./install-ci-dependencies.sh"
        echo "failed" > "$LOG_DIR/contracts_static_test_status.txt"
        return 1
    fi
    
    log_info "Running contracts static checks..."
    log_info "These checks will run with continue-on-error (warnings allowed)"
    
    local test_start
    test_start=$(date +%s)
    
    local contracts_dir="$REPO_DIR/packages/contracts-bedrock"
    local check_failed=0
    
    {
        echo "Running interfaces check..."
        (cd "$contracts_dir" && just interfaces-check-no-build) || true
        
        echo "Running unused imports check..."
        (cd "$contracts_dir" && just unused-imports-check-no-build) || true
        
        echo "Running valid semver check..."
        (cd "$contracts_dir" && just valid-semver-check-no-build) || true
        
        echo "Running semver diff check..."
        (cd "$contracts_dir" && just semver-diff-check-no-build) || true
        
        echo "Running validate spacers..."
        (cd "$contracts_dir" && just validate-spacers-no-build) || true
        
        echo "Running reinitializer check..."
        (cd "$contracts_dir" && just reinitializer-check-no-build) || true
        
        echo "Running lint forge tests check..."
        (cd "$contracts_dir" && just lint-forge-tests-check-no-build) || true
        
        echo "Running validate deploy configs..."
        (cd "$contracts_dir" && just validate-deploy-configs) || true
    } 2>&1 | tee "$test_log"
    
    local test_end
    test_end=$(date +%s)
    local duration=$((test_end - test_start))
    
    # Since these checks are allowed to fail (continue-on-error), we mark as success
    log_success "Contracts static checks completed (warnings allowed)"
    log_success "Check duration: $((duration / 60))m $((duration % 60))s"
    echo "success" > "$LOG_DIR/contracts_static_test_status.txt"
    echo "$duration" > "$LOG_DIR/contracts_static_test_duration.txt"
}

# =============================================================================
# Phase 12: Run Op-E2E WebSocket Tests
# =============================================================================

run_op_e2e_ws_tests() {
    log_section "Phase 12: Run Op-E2E WebSocket Tests"
    
    local test_log="$LOG_DIR/test-op-e2e-ws.log"
    log_info "Op-E2E WebSocket test log: $test_log"
    
    log_info "Running Op-E2E WebSocket tests..."
    
    local test_start
    test_start=$(date +%s)
    
    # Run WebSocket tests
    set +e  # Temporarily disable exit on error
    (cd "$REPO_DIR/op-e2e" && make test-ws) 2>&1 | tee "$test_log"
    local test_exit_code=$?
    set -e  # Re-enable exit on error
    
    local test_end
    test_end=$(date +%s)
    local duration=$((test_end - test_start))
    
    if [[ $test_exit_code -eq 0 ]]; then
        log_success "All Op-E2E WebSocket tests passed"
        log_success "Test duration: $((duration / 60))m $((duration % 60))s"
        echo "success" > "$LOG_DIR/op_e2e_ws_test_status.txt"
        echo "$duration" > "$LOG_DIR/op_e2e_ws_test_duration.txt"
    else
        log_error "Some Op-E2E WebSocket tests failed"
        log_error "Test duration: $((duration / 60))m $((duration % 60))s"
        echo "failed" > "$LOG_DIR/op_e2e_ws_test_status.txt"
        echo "$duration" > "$LOG_DIR/op_e2e_ws_test_duration.txt"
        log_error "Full output: $test_log"
        
        # Don't exit immediately - let the script continue to generate summary
        return 1
    fi
}

# =============================================================================
# Phase 13: Run Op-E2E HTTP Tests
# =============================================================================

run_op_e2e_http_tests() {
    log_section "Phase 13: Run Op-E2E HTTP Tests"
    
    local test_log="$LOG_DIR/test-op-e2e-http.log"
    log_info "Op-E2E HTTP test log: $test_log"
    
    log_info "Running Op-E2E HTTP tests..."
    
    local test_start
    test_start=$(date +%s)
    
    # Run HTTP tests
    set +e  # Temporarily disable exit on error
    (cd "$REPO_DIR/op-e2e" && make test-http) 2>&1 | tee "$test_log"
    local test_exit_code=$?
    set -e  # Re-enable exit on error
    
    local test_end
    test_end=$(date +%s)
    local duration=$((test_end - test_start))
    
    if [[ $test_exit_code -eq 0 ]]; then
        log_success "All Op-E2E HTTP tests passed"
        log_success "Test duration: $((duration / 60))m $((duration % 60))s"
        echo "success" > "$LOG_DIR/op_e2e_http_test_status.txt"
        echo "$duration" > "$LOG_DIR/op_e2e_http_test_duration.txt"
    else
        log_error "Some Op-E2E HTTP tests failed"
        log_error "Test duration: $((duration / 60))m $((duration % 60))s"
        echo "failed" > "$LOG_DIR/op_e2e_http_test_status.txt"
        echo "$duration" > "$LOG_DIR/op_e2e_http_test_duration.txt"
        log_error "Full output: $test_log"
        
        # Don't exit immediately - let the script continue to generate summary
        return 1
    fi
}

# =============================================================================
# Phase 14: Run Cannon VM Tests
# =============================================================================

run_cannon_tests() {
    log_section "Phase 14: Run Cannon VM Tests"
    
    local test_log="$LOG_DIR/test-cannon.log"
    log_info "Cannon VM test log: $test_log"
    
    log_info "Running Cannon VM tests..."
    
    local test_start
    test_start=$(date +%s)
    
    # Run Cannon tests
    set +e  # Temporarily disable exit on error
    (cd "$REPO_DIR/cannon" && make test) 2>&1 | tee "$test_log"
    local test_exit_code=$?
    set -e  # Re-enable exit on error
    
    local test_end
    test_end=$(date +%s)
    local duration=$((test_end - test_start))
    
    if [[ $test_exit_code -eq 0 ]]; then
        log_success "All Cannon VM tests passed"
        log_success "Test duration: $((duration / 60))m $((duration % 60))s"
        echo "success" > "$LOG_DIR/cannon_test_status.txt"
        echo "$duration" > "$LOG_DIR/cannon_test_duration.txt"
    else
        log_error "Some Cannon VM tests failed"
        log_error "Test duration: $((duration / 60))m $((duration % 60))s"
        echo "failed" > "$LOG_DIR/cannon_test_status.txt"
        echo "$duration" > "$LOG_DIR/cannon_test_duration.txt"
        log_error "Full output: $test_log"
        
        # Don't exit immediately - let the script continue to generate summary
        return 1
    fi
}

# =============================================================================
# Phase 15: Generate Summary
# =============================================================================

generate_summary() {
    log_section "Phase 15: Summary"
    
    local summary_file="$LOG_DIR/summary.txt"
    
    {
        echo "═══════════════════════════════════════════════════════════════"
        if [ "$DEV_MODE" = "true" ]; then
            echo "  X Layer Optimism CI Summary - DEV MODE"
            echo "  (Quick checks: linting + unit tests only)"
        else
            echo "  X Layer Optimism CI Summary - FULL MODE"
        fi
        echo "═══════════════════════════════════════════════════════════════"
        echo ""
        echo "Mode: $([ "$DEV_MODE" = "true" ] && echo "DEVELOPMENT" || echo "FULL")"
        echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Repository: $REPO_DIR"
        echo "Branch: $(git branch --show-current)"
        echo "Commit: $(git rev-parse HEAD)"
        echo "Log Directory: $LOG_DIR"
        echo ""
        echo "─────────────────────────────────────────────────────────────"
        echo "Phase Results:"
        echo "─────────────────────────────────────────────────────────────"
        
        # Upstream sync
        echo "✅ Upstream Sync: SUCCESS"
        
        # Code Quality Checks
        display_phase_result "Go Linting" "lint_go"
        display_result_with_dev_mode "Semgrep Scan" "semgrep"
        display_result_with_dev_mode "ShellCheck" "shellcheck"
        display_result_with_dev_mode "Build Contracts" "build"
        
        # Get status values for later use (needed for overall status check and failure details)
        local lint_go_status=$(get_test_status "lint_go")
        local semgrep_status=$([ "$DEV_MODE" = "true" ] && echo "skipped" || get_test_status "semgrep")
        local shellcheck_status=$([ "$DEV_MODE" = "true" ] && echo "skipped" || get_test_status "shellcheck")
        local build_status=$([ "$DEV_MODE" = "true" ] && echo "skipped" || get_test_status "build")
        
        # Unit Tests (with special handling for failure details)
        local unit_test_status=$(get_test_status "unit_test")
        local unit_test_duration=$(get_test_duration "unit_test")
        
        case "$unit_test_status" in
            success)
                echo "✅ Unit Tests: SUCCESS ($((unit_test_duration / 60))m $((unit_test_duration % 60))s)"
                ;;
            failed)
                echo "❌ Unit Tests: FAILED ($((unit_test_duration / 60))m $((unit_test_duration % 60))s)"
                # Show failed test count
                if [[ -f "$LOG_DIR/test-failures-summary.txt" ]]; then
                    local failed_count=$(wc -l < "$LOG_DIR/test-failures-summary.txt" 2>/dev/null || echo "0")
                    if [[ $failed_count -gt 0 ]]; then
                        echo ""
                        echo "   Failed Tests ($failed_count):"
                        head -20 "$LOG_DIR/test-failures-summary.txt" | while read -r test; do
                            echo "     • $test"
                        done
                        if [[ $failed_count -gt 20 ]]; then
                            echo "     ... and $((failed_count - 20)) more"
                        fi
                    fi
                fi
                ;;
            *)
                echo "❓ Unit Tests: UNKNOWN"
                ;;
        esac
        
        # Other test suites (using helper function for consistency)
        display_test_with_duration "Contract Tests" "contract_test"
        display_test_with_duration "Fraud Proof Tests" "fraud_proof_test"
        display_test_with_duration "Op-E2E Actions Tests" "op_e2e_actions_test"
        display_test_with_duration "Contracts Static Checks" "contracts_static_test"
        display_test_with_duration "Op-E2E WebSocket Tests" "op_e2e_ws_test"
        display_test_with_duration "Op-E2E HTTP Tests" "op_e2e_http_test"
        display_test_with_duration "Cannon VM Tests" "cannon_test"
        
        echo ""
        echo "─────────────────────────────────────────────────────────────"
        echo "Overall Status:"
        echo "─────────────────────────────────────────────────────────────"
        
        local ci_passed=true
        
        if [ "$DEV_MODE" = "true" ]; then
            # Dev mode: only check linting and unit tests
            test_passed "lint_go" false || ci_passed=false
            test_passed "unit_test" false || ci_passed=false
            
            if [ "$ci_passed" = "true" ]; then
                echo "✅ DEV MODE CI PASSED (linting + unit tests)"
            else
                echo "❌ DEV MODE CI FAILED"
            fi
        else
            # Full mode: check all tests (optional tests don't fail CI)
            test_passed "lint_go" false || ci_passed=false
            test_passed "unit_test" false || ci_passed=false
            [[ "$build_status" == "failed" ]] && ci_passed=false
            test_passed "contract_test" true || ci_passed=false
            test_passed "fraud_proof_test" true || ci_passed=false
            test_passed "op_e2e_actions_test" true || ci_passed=false
            test_passed "contracts_static_test" true || ci_passed=false
            test_passed "op_e2e_ws_test" true || ci_passed=false
            test_passed "op_e2e_http_test" true || ci_passed=false
            test_passed "cannon_test" true || ci_passed=false
            
            if [ "$ci_passed" = "true" ]; then
                echo "✅ CI PASSED"
            else
                echo "❌ CI FAILED"
            fi
        fi
        
        # Show failure details if CI failed
        if [ "$ci_passed" = "false" ]; then
            show_failure_logs "Go Linting" "lint_go" "$LOG_DIR/lint-go.log"
            show_failure_logs "Semgrep Scan" "semgrep" "$LOG_DIR/semgrep-scan.log"
            show_failure_logs "ShellCheck" "shellcheck" "$LOG_DIR/shellcheck.log"
            show_failure_logs "Unit Tests" "unit_test" "$LOG_DIR/test-unit.log"
            show_failure_logs "Contract Tests" "contract_test" "$LOG_DIR/test-contracts.log"
            show_failure_logs "Fraud Proof Tests" "fraud_proof_test" "$LOG_DIR/test-fraud-proofs.log"
            show_failure_logs "Op-E2E Actions Tests" "op_e2e_actions_test" "$LOG_DIR/test-op-e2e-actions.log"
            show_failure_logs "Contracts Static Checks" "contracts_static_test" "$LOG_DIR/test-contracts-static.log"
            show_failure_logs "Op-E2E WebSocket Tests" "op_e2e_ws_test" "$LOG_DIR/test-op-e2e-ws.log"
            show_failure_logs "Op-E2E HTTP Tests" "op_e2e_http_test" "$LOG_DIR/test-op-e2e-http.log"
            show_failure_logs "Cannon VM Tests" "cannon_test" "$LOG_DIR/test-cannon.log"
        fi
        
        echo ""
        echo "═══════════════════════════════════════════════════════════════"
    } | tee "$summary_file"
    
    log_success "Summary saved to: $summary_file"
}

# =============================================================================
# Phase 10: Send Lark Notification
# =============================================================================

send_lark_notification() {
    log_section "Phase 16: Sending Lark Notification"
    
    # Check if LARK_WEBHOOK_URL is configured
    if [ -z "${LARK_WEBHOOK_URL:-}" ]; then
        log_warning "LARK_WEBHOOK_URL not configured. Skipping notification."
        echo ""
        echo "To enable Lark notifications, set the LARK_WEBHOOK_URL environment variable:"
        echo "  export LARK_WEBHOOK_URL='your-webhook-url'"
        return 0
    fi
    
    # Read status from files/variables
    local sync_status="success"  # If we reached here, sync was successful (otherwise script would have exited)
    
    local lint_go_status
    lint_go_status=$(cat "$LOG_DIR/lint_go_status.txt" 2>/dev/null || echo "unknown")
    
    local semgrep_status
    semgrep_status=$(cat "$LOG_DIR/semgrep_status.txt" 2>/dev/null || echo "unknown")
    # Treat skipped/warning as success for overall status
    if [[ "$semgrep_status" == "skipped" || "$semgrep_status" == "warning" ]]; then
        semgrep_status="success"
    fi
    
    local shellcheck_status
    shellcheck_status=$(cat "$LOG_DIR/shellcheck_status.txt" 2>/dev/null || echo "unknown")
    # Treat skipped/warning as success for overall status
    if [[ "$shellcheck_status" == "skipped" || "$shellcheck_status" == "warning" ]]; then
        shellcheck_status="success"
    fi
    
    local build_status
    build_status=$(cat "$LOG_DIR/build_status.txt" 2>/dev/null || echo "unknown")
    # Map build status
    if [[ "$build_status" == "skipped" || "$build_status" == "reused" ]]; then
        build_status="success"  # Treat skipped/reused as success for notification
    fi
    
    # Read all test statuses using helper function
    local unit_test_status=$(get_test_status "unit_test")
    local contract_test_status=$(get_test_status "contract_test")
    local fraud_proof_test_status=$(get_test_status "fraud_proof_test")
    local op_e2e_actions_test_status=$(get_test_status "op_e2e_actions_test")
    local contracts_static_test_status=$(get_test_status "contracts_static_test")
    local op_e2e_ws_test_status=$(get_test_status "op_e2e_ws_test")
    local op_e2e_http_test_status=$(get_test_status "op_e2e_http_test")
    local cannon_test_status=$(get_test_status "cannon_test")
    
    # Determine overall status and color using helper functions
    local all_passed=true
    test_passed "sync" false || all_passed=false
    test_passed "lint_go" false || all_passed=false
    test_passed "semgrep" false || all_passed=false
    test_passed "shellcheck" false || all_passed=false
    test_passed "build" false || all_passed=false
    test_passed "unit_test" true || all_passed=false
    test_passed "contract_test" true || all_passed=false
    test_passed "fraud_proof_test" true || all_passed=false
    test_passed "op_e2e_actions_test" true || all_passed=false
    test_passed "contracts_static_test" true || all_passed=false
    test_passed "op_e2e_ws_test" true || all_passed=false
    test_passed "op_e2e_http_test" true || all_passed=false
    test_passed "cannon_test" true || all_passed=false
    
    if [ "$all_passed" = "true" ]; then
      CARD_COLOR="green"
      STATUS_TEXT="✅ All tasks succeeded"
      STATUS_EMOJI="✅"
    else
      CARD_COLOR="red"
      STATUS_TEXT="❌ Some tasks failed"
      STATUS_EMOJI="❌"
    fi
    
    # Get current time in Beijing timezone
    CURRENT_TIME=$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S')
    COMMIT_SHORT=$(git rev-parse --short HEAD)
    BRANCH_NAME=$(git branch --show-current)
    
    # Build status for each check
    get_status_icon() {
      if [[ "$1" == "success" ]]; then
        echo "✅"
      elif [[ "$1" == "unknown" ]]; then
        echo "⏭️"
      else
        echo "❌"
      fi
    }
    
    SYNC_ICON=$(get_status_icon "$sync_status")
    LINT_GO_ICON=$(get_status_icon "$lint_go_status")
    SEMGREP_ICON=$(get_status_icon "$semgrep_status")
    SHELLCHECK_ICON=$(get_status_icon "$shellcheck_status")
    BUILD_ICON=$(get_status_icon "$build_status")
    TEST_ICON=$(get_status_icon "$unit_test_status")
    CONTRACT_TEST_ICON=$(get_status_icon "$contract_test_status")
    FRAUD_PROOF_TEST_ICON=$(get_status_icon "$fraud_proof_test_status")
    OP_E2E_ACTIONS_TEST_ICON=$(get_status_icon "$op_e2e_actions_test_status")
    CONTRACTS_STATIC_TEST_ICON=$(get_status_icon "$contracts_static_test_status")
    OP_E2E_WS_TEST_ICON=$(get_status_icon "$op_e2e_ws_test_status")
    OP_E2E_HTTP_TEST_ICON=$(get_status_icon "$op_e2e_http_test_status")
    CANNON_TEST_ICON=$(get_status_icon "$cannon_test_status")
    
    # Build Lark Card JSON
    cat > "$LOG_DIR/lark_card.json" <<EOF
{
  "msg_type": "interactive",
  "card": {
    "header": {
      "title": {
        "tag": "plain_text",
        "content": "${STATUS_EMOJI} X Layer Optimism Local CI Report"
      },
      "template": "${CARD_COLOR}"
    },
    "elements": [
      {
        "tag": "div",
        "fields": [
          {
            "is_short": true,
            "text": {
              "tag": "lark_md",
              "content": "**📅 Run Time**\\n${CURRENT_TIME}"
            }
          },
          {
            "is_short": true,
            "text": {
              "tag": "lark_md",
              "content": "**🔀 Branch**\\n${BRANCH_NAME}"
            }
          },
          {
            "is_short": true,
            "text": {
              "tag": "lark_md",
              "content": "**📝 Commit**\\n${COMMIT_SHORT}"
            }
          },
          {
            "is_short": true,
            "text": {
              "tag": "lark_md",
              "content": "**💻 Host**\\n$(hostname)"
            }
          }
        ]
      },
      {
        "tag": "hr"
      },
      {
        "tag": "div",
        "text": {
          "tag": "lark_md",
          "content": "**Code Quality Checks**"
        }
      },
      {
        "tag": "div",
        "fields": [
          {
            "is_short": true,
            "text": {
              "tag": "lark_md",
              "content": "${SYNC_ICON} Upstream Sync"
            }
          },
          {
            "is_short": true,
            "text": {
              "tag": "lark_md",
              "content": "${LINT_GO_ICON} Go Linting"
            }
          },
          {
            "is_short": true,
            "text": {
              "tag": "lark_md",
              "content": "${SEMGREP_ICON} Semgrep Scan"
            }
          },
          {
            "is_short": true,
            "text": {
              "tag": "lark_md",
              "content": "${SHELLCHECK_ICON} ShellCheck"
            }
          },
          {
            "is_short": true,
            "text": {
              "tag": "lark_md",
              "content": "${BUILD_ICON} Build Contracts"
            }
          },
          {
            "is_short": true,
            "text": {
              "tag": "lark_md",
              "content": "${CONTRACTS_STATIC_TEST_ICON} Contracts Static"
            }
          }
        ]
      },
      {
        "tag": "hr"
      },
      {
        "tag": "div",
        "text": {
          "tag": "lark_md",
          "content": "**Test Suites**"
        }
      },
      {
        "tag": "div",
        "fields": [
          {
            "is_short": true,
            "text": {
              "tag": "lark_md",
              "content": "${TEST_ICON} Unit Tests"
            }
          },
          {
            "is_short": true,
            "text": {
              "tag": "lark_md",
              "content": "${CONTRACT_TEST_ICON} Contract Tests"
            }
          },
          {
            "is_short": true,
            "text": {
              "tag": "lark_md",
              "content": "${FRAUD_PROOF_TEST_ICON} Fraud Proof Tests"
            }
          },
          {
            "is_short": true,
            "text": {
              "tag": "lark_md",
              "content": "${CANNON_TEST_ICON} Cannon VM Tests"
            }
          },
          {
            "is_short": true,
            "text": {
              "tag": "lark_md",
              "content": "${OP_E2E_ACTIONS_TEST_ICON} Op-E2E Actions"
            }
          },
          {
            "is_short": true,
            "text": {
              "tag": "lark_md",
              "content": "${OP_E2E_WS_TEST_ICON} Op-E2E WebSocket"
            }
          },
          {
            "is_short": true,
            "text": {
              "tag": "lark_md",
              "content": "${OP_E2E_HTTP_TEST_ICON} Op-E2E HTTP"
            }
          }
        ]
      },
      {
        "tag": "hr"
      },
      {
        "tag": "div",
        "text": {
          "tag": "lark_md",
          "content": "**${STATUS_TEXT}**"
        }
      }
    ]
  }
}
EOF
    
    # Send to Lark/Feishu
    log_info "Sending card notification to Lark..."
    
    response=$(curl -s -w "\n%{http_code}" -X POST "$LARK_WEBHOOK_URL" \
      -H 'Content-Type: application/json' \
      -d @"$LOG_DIR/lark_card.json")
    
    http_code=$(echo "$response" | tail -n1)
    response_body=$(echo "$response" | head -n-1)
    
    if [ "$http_code" -eq 200 ]; then
      log_success "Lark notification sent successfully"
    else
      log_error "Failed to send Lark notification"
      log_error "HTTP Code: $http_code"
    fi
}

# =============================================================================
# Main Execution
# =============================================================================

main() {
    local start_time
    start_time=$(date +%s)
    
    echo -e "${GREEN}"
    echo "═══════════════════════════════════════════════════════════════"
    if [ "$DEV_MODE" = "true" ]; then
        echo "  X Layer Optimism Local CI - DEV MODE"
        echo "  (Quick checks: linting + unit tests only)"
    else
        echo "  X Layer Optimism Local CI - FULL MODE"
    fi
    echo "═══════════════════════════════════════════════════════════════"
    echo -e "${NC}"
    
    # Setup logging first (before changing directories)
    setup_logging
    
    # Then setup and validate the repository
    setup_environment
    sync_upstream
    
    # Run code quality checks
    local lint_result=0
    run_go_linting || lint_result=$?
    
    # Initialize test result variables
    local test_result=0
    local contract_test_result=0
    local fraud_proof_test_result=0
    local op_e2e_actions_test_result=0
    local contracts_static_test_result=0
    local op_e2e_ws_test_result=0
    local op_e2e_http_test_result=0
    local cannon_test_result=0
    local unit_test_result=0
    
    if [ "$DEV_MODE" = "true" ]; then
        log_info "DEV MODE: Running essential checks only"
        
        # Run unit tests in dev mode
        # run_unit_tests || unit_test_result=$?
        
        log_info "DEV MODE: Skipping semgrep, shellcheck, contracts, and other test suites"
    else
        log_info "FULL MODE: Running all checks and tests"
        
        # Run additional code quality checks
        run_semgrep_scan  
        run_shellcheck   
        
        # Check and build contracts if needed
        if check_contract_changes; then
            build_contracts
        else
            log_info "Skipping contract build"
            echo "skipped" > "$LOG_DIR/build_status.txt"
        fi
        
        # Run unit tests
        run_unit_tests || unit_test_result=$?

        # Optional: Run additional test suites (uncomment as needed)
        # run_contract_tests || contract_test_result=$?
        # run_fraud_proof_tests || fraud_proof_test_result=$?
        # run_op_e2e_actions_tests || op_e2e_actions_test_result=$?
        # run_contracts_static_checks || contracts_static_test_result=$?
        # run_op_e2e_ws_tests || op_e2e_ws_test_result=$?
        # run_op_e2e_http_tests || op_e2e_http_test_result=$?
        # run_cannon_tests || cannon_test_result=$?
    fi
    
    # Always generate summary regardless of test outcome
    generate_summary
    
    # Send Lark notification (skip in dev mode)
    if [ "$DEV_MODE" = "true" ]; then
        log_info "DEV MODE: Skipping Lark notification"
    else
        send_lark_notification
    fi
    
    local end_time
    end_time=$(date +%s)
    local total_duration=$((end_time - start_time))
    
    echo ""
    # Check results based on mode
    if [ "$DEV_MODE" = "true" ]; then
        # In dev mode, only check linting and unit tests
        if [[ $lint_result -eq 0 ]] && [[ $unit_test_result -eq 0 ]]; then
            log_success "DEV MODE: CI completed successfully in $((total_duration / 60))m $((total_duration % 60))s"
            log_info "All logs available in: $LOG_DIR"
            exit 0
        else
            log_error "DEV MODE: CI completed with failures in $((total_duration / 60))m $((total_duration % 60))s"
            log_info "All logs available in: $LOG_DIR"
            exit 1
        fi
    else
        # In full mode, check all tests
        if [[ $lint_result -eq 0 ]] && \
           [[ $unit_test_result -eq 0 ]] && \
           [[ $contract_test_result -eq 0 ]] && \
           [[ $fraud_proof_test_result -eq 0 ]] && \
           [[ $op_e2e_actions_test_result -eq 0 ]] && \
           [[ $contracts_static_test_result -eq 0 ]] && \
           [[ $op_e2e_ws_test_result -eq 0 ]] && \
           [[ $op_e2e_http_test_result -eq 0 ]] && \
           [[ $cannon_test_result -eq 0 ]]; then
            log_success "FULL MODE: CI completed successfully in $((total_duration / 60))m $((total_duration % 60))s"
            log_info "All logs available in: $LOG_DIR"
            exit 0
        else
            log_error "FULL MODE: CI completed with failures in $((total_duration / 60))m $((total_duration % 60))s"
            log_info "All logs available in: $LOG_DIR"
            exit 1
        fi
    fi
}

# Run main function
main "$@"

