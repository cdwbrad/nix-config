#!/usr/bin/env bash
# lint-go.sh - Go-specific linting functions for Claude Code smart-lint
#
# This file is sourced by smart-lint.sh to provide Go linting capabilities.
# It follows the same pattern as other language-specific linters.

# ============================================================================
# GO LINTING
# ============================================================================

lint_go() {
    if [[ "${CLAUDE_HOOKS_GO_ENABLED:-true}" != "true" ]]; then
        log_debug "Go linting disabled"
        return 0
    fi
    
    log_info "Running Go formatting and linting..."
    
    # Check if Makefile exists with fmt and lint targets
    if [[ -f "Makefile" ]]; then
        local has_fmt=$(grep -E "^fmt:" Makefile 2>/dev/null || echo "")
        local has_lint=$(grep -E "^lint:" Makefile 2>/dev/null || echo "")
        
        if [[ -n "$has_fmt" && -n "$has_lint" ]]; then
            log_info "Using Makefile targets"
            
            local fmt_output
            if ! fmt_output=$(make fmt 2>&1); then
                add_error "Go formatting failed (make fmt)"
                echo "$fmt_output" >&2
            fi
            
            local lint_output
            if ! lint_output=$(make lint 2>&1); then
                add_error "Go linting failed (make lint)"
                echo "$lint_output" >&2
            fi
        else
            # Fallback to direct commands
            run_go_direct_lint
        fi
    else
        # No Makefile, use direct commands
        run_go_direct_lint
    fi
}

# Run Go linting tools directly (when no Makefile targets)
run_go_direct_lint() {
    log_info "Using direct Go tools"
    
    # Check for forbidden patterns first
    check_go_forbidden_patterns
    
    # Format check - filter files through should_skip_file
    local unformatted_files=$(gofmt -l . 2>/dev/null | grep -v vendor/ | while read -r file; do
        if ! should_skip_file "$file"; then
            echo "$file"
        fi
    done || true)
    
    if [[ -n "$unformatted_files" ]]; then
        local fmt_output
        if ! fmt_output=$(gofmt -w . 2>&1); then
            add_error "Go formatting failed"
            echo "$fmt_output" >&2
        fi
    fi
    
    # Linting - build exclude args from .claude-hooks-ignore
    if command_exists golangci-lint; then
        local exclude_args=""
        if [[ -f ".claude-hooks-ignore" ]]; then
            # Convert ignore patterns to golangci-lint skip-files patterns
            while IFS= read -r pattern; do
                [[ -z "$pattern" || "$pattern" =~ ^[[:space:]]*# ]] && continue
                # Remove quotes and adjust pattern for golangci-lint
                pattern="${pattern//\'/}"
                pattern="${pattern//\"/}"
                exclude_args="${exclude_args} --skip-files=${pattern}"
            done < ".claude-hooks-ignore"
        fi
        
        local lint_output
        local lint_cmd="golangci-lint run --timeout=2m${exclude_args}"
        log_debug "Running: $lint_cmd"
        if ! lint_output=$($lint_cmd 2>&1); then
            add_error "golangci-lint found issues"
            echo "$lint_output" >&2
        fi
    elif command_exists go; then
        local vet_output
        if ! vet_output=$(go vet ./... 2>&1); then
            add_error "go vet found issues"
            echo "$vet_output" >&2
        fi
    else
        log_error "No Go linting tools available - install golangci-lint or go"
    fi
}

# Check for forbidden Go patterns
check_go_forbidden_patterns() {
    log_info "Checking for forbidden Go patterns..."
    
    # Find all Go files and filter them through should_skip_file
    local go_files=$(find . -name "*.go" -type f | grep -v -E "(vendor/|\.git/)" | while read -r file; do
        if ! should_skip_file "$file"; then
            echo "$file"
        fi
    done | head -100)
    
    if [[ -z "$go_files" ]]; then
        log_debug "No Go files found to check"
        return 0
    fi
    
    # Filter out files that should be skipped
    local filtered_files=""
    for file in $go_files; do
        if ! should_skip_file "$file"; then
            filtered_files="$filtered_files$file "
        fi
    done
    
    go_files="$filtered_files"
    if [[ -z "$go_files" ]]; then
        log_debug "All Go files were skipped by .claude-hooks-ignore"
        return 0
    fi
    
    local found_issues=false
    
    # Check for time.Sleep
    local sleep_files=$(echo "$go_files" | xargs grep -l "time\.Sleep" 2>/dev/null || true)
    if [[ -n "$sleep_files" ]]; then
        add_error "FORBIDDEN PATTERN: time.Sleep() found - use channels for synchronization"
        echo "Files containing time.Sleep:" >&2
        echo "$sleep_files" | sed 's/^/  /' >&2
        found_issues=true
    fi
    
    # Check for panic() calls (outside of test files)
    local panic_files=$(echo "$go_files" | grep -v "_test\.go$" | xargs grep -l "panic(" 2>/dev/null || true)
    if [[ -n "$panic_files" ]]; then
        add_error "FORBIDDEN PATTERN: panic() found in non-test files"
        echo "Files containing panic:" >&2
        echo "$panic_files" | sed 's/^/  /' >&2
        found_issues=true
    fi
    
    # Check for interface{} or any
    local interface_files=$(echo "$go_files" | xargs grep -l -E "(interface\{\}|any\s+)" 2>/dev/null || true)
    if [[ -n "$interface_files" ]]; then
        add_error "FORBIDDEN PATTERN: interface{} or any found - use concrete types"
        echo "Files containing interface{} or any:" >&2
        echo "$interface_files" | sed 's/^/  /' >&2
        found_issues=true
    fi
    
    # Check for TODO comments
    local todo_files=$(echo "$go_files" | xargs grep -l "TODO" 2>/dev/null || true)
    if [[ -n "$todo_files" ]]; then
        add_error "FORBIDDEN PATTERN: TODO comments found"
        echo "Files containing TODOs:" >&2
        echo "$todo_files" | sed 's/^/  /' >&2
        found_issues=true
    fi
    
    if [[ "$found_issues" == "true" ]]; then
        echo -e "\n${YELLOW}See CLAUDE.md for Go coding standards${NC}" >&2
    fi
}