#!/bin/bash

#######################################
# Run internal test suite for Ralph
# Returns: 0 if all tests pass, 1 otherwise
#######################################
run_internal_tests() {
    log_info "Starting Ralph Internal Test Suite"
    local passed=0
    local failed=0
    
    # Test OS Detection
    log_info "Testing OS Detection..."
    if [[ "$OS_TYPE" != "unknown" ]]; then
        log_success "OS detected: $OS_TYPE"
        ((passed += 1))
    else
        log_error "OS detection failed"
        ((failed += 1))
    fi
    
    # Test MD5 Command
    log_info "Testing MD5 Utilities..."
    if detect_md5_command; then
        log_success "MD5 command found: $MD5_COMMAND"
        local test_file
        test_file=$(create_temp_file)
        echo "test" > "$test_file"
        local hash
        hash=$(md5sum_wrapper "$test_file" | awk '{print $1}')
        if [[ -n "$hash" ]]; then
            log_success "MD5 hash computation works: $hash"
            ((passed += 1))
        else
            log_error "MD5 hash computation failed"
            ((failed += 1))
        fi
    else
        log_error "No MD5 command found"
        ((failed += 1))
    fi
    
    # Test Token Estimation
    log_info "Testing Token Estimation..."
    local sample_text="The quick brown fox jumps over the lazy dog."
    local tokens
    tokens=$(estimate_tokens "$sample_text" "advanced")
    if [[ "$tokens" -gt 0 ]]; then
        log_success "Token estimation works: $tokens tokens"
        ((passed += 1))
    else
        log_error "Token estimation failed"
        ((failed += 1))
    fi
    
    # Test Git Diff Exclusions
    log_info "Testing Git Diff Exclusions..."
    local exclude_file
    exclude_file=$(create_temp_file)
    echo "node_modules/*" > "$exclude_file"
    echo "*.log" >> "$exclude_file"
    
    export GITDIFF_EXCLUDE="$exclude_file"
    local exclude_args
    exclude_args=$(build_gitdiff_exclude_args)
    if [[ "$exclude_args" == *"(exclude)node_modules/*"* ]]; then
        log_success "Git diff exclusion parsing works"
        ((passed += 1))
    else
        log_error "Git diff exclusion parsing failed"
        ((failed += 1))
    fi
    
    # Summary
    log_info "----------------------------------"
    log_info "Test Summary: $passed passed, $failed failed"
    log_info "----------------------------------"
    
    if [[ $failed -eq 0 ]]; then
        log_success "All internal tests passed! 🎉"
        return 0
    else
        log_error "Some tests failed. Please check the logs."
        return 1
    fi
}
