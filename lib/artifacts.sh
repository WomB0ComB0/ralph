#!/bin/bash

#######################################
# Validate key Ralph artifacts
# Checks PRD, architecture diagram, and execution plan
# Returns: Validation instructions/warnings for the AI agent
#######################################
validate_artifacts() {
    local instructions=""
    local errors=0
    local warnings=0
    
    log_debug "Validating Ralph artifacts..."
    
    # Validate PRD (Product Requirements Document)
    if ! validate_prd; then
        ((errors++))
        instructions+=$'\n'"<priority_interrupt>CRITICAL: PRD validation failed. See errors above and fix immediately before proceeding.</priority_interrupt>"
    fi
    
    # Validate Architecture Diagram
    if ! validate_architecture_diagram "warn"; then
        ((warnings++))
        instructions+=$'\n'"<priority_interrupt>WARNING: Architecture diagram validation failed. Consider updating '$DIAGRAM_FILE' with valid Mermaid syntax.</priority_interrupt>"
    fi
    
    # Validate Execution Plan
    if ! validate_execution_plan "warn"; then
        ((warnings++))
        instructions+=$'\n'"<priority_interrupt>WARNING: Execution plan validation failed. Update '$PLAN_FILE' to use proper checkbox format (- [ ] or - [x]).</priority_interrupt>"
    fi
    
    # Log summary
    if [[ $errors -gt 0 ]] || [[ $warnings -gt 0 ]]; then
        log_warning "Artifact validation completed: $errors error(s), $warnings warning(s)"
    else
        log_debug "All artifacts validated successfully"
    fi
    
    echo "$instructions"
}

#######################################
# Validate PRD JSON file
# Returns: 0 if valid, 1 if invalid or missing
#######################################
validate_prd() {
    local prd_file="${PRD_FILE:-prd.json}"
    
    if [[ ! -f "$prd_file" ]]; then
        log_debug "PRD file not found: $prd_file (will be created)"
        return 0
    fi
    
    # Check if jq is available
    if ! command_exists jq; then
        log_warning "jq not installed, cannot validate PRD JSON structure"
        return 0  # Don't fail if jq is missing
    fi
    
    # Validate JSON syntax
    if ! jq empty "$prd_file" >/dev/null 2>&1; then
        log_error "PRD contains invalid JSON: $prd_file"
        
        # Try to show the error
        local json_error
        json_error=$(jq empty "$prd_file" 2>&1)
        log_debug "JSON error: $json_error"
        
        return 1
    fi
    
    # Validate expected structure
    local has_required_fields=true
    local missing_fields=()
    
    # Check for key fields (adjust based on your PRD schema)
    local required_fields=("projectName" "goals")
    
    for field in "${required_fields[@]}"; do
        if ! jq -e ".$field" "$prd_file" >/dev/null 2>&1; then
            missing_fields+=("$field")
            has_required_fields=false
        fi
    done
    
    if ! $has_required_fields; then
        log_warning "PRD is missing recommended fields: ${missing_fields[*]}"
        log_info "Consider adding these fields for better context"
    fi
    
    # Validate specific field types
    if jq -e '.branchName' "$prd_file" >/dev/null 2>&1; then
        local branch_name
        branch_name=$(jq -r '.branchName // empty' "$prd_file")
        
        if [[ -n "$branch_name" ]]; then
            log_debug "PRD branch: $branch_name"
        fi
    fi
    
    log_success "PRD validation passed: $prd_file"
    return 0
}

#######################################
# Validate architecture diagram (Mermaid)
# Arguments:
#   $1 - Severity level: "error" or "warn" (default: warn)
# Returns: 0 if valid, 1 if invalid
#######################################
validate_architecture_diagram() {
    local severity="${1:-warn}"
    local diagram_file="${DIAGRAM_FILE:-ralph_architecture.md}"
    
    if [[ ! -f "$diagram_file" ]]; then
        log_debug "Architecture diagram not found: $diagram_file (will be created)"
        return 0
    fi
    
    # Check file is not empty
    if [[ ! -s "$diagram_file" ]]; then
        if [[ "$severity" == "error" ]]; then
            log_error "Architecture diagram is empty: $diagram_file"
        else
            log_warning "Architecture diagram is empty: $diagram_file"
        fi
        return 1
    fi
    
    # Valid Mermaid diagram types
    local mermaid_keywords=(
        "graph"
        "flowchart"
        "sequenceDiagram"
        "classDiagram"
        "stateDiagram"
        "erDiagram"
        "gantt"
        "pie"
        "journey"
        "gitGraph"
        "mindmap"
        "timeline"
        "quadrantChart"
    )
    
    # Check for Mermaid code blocks
    local has_mermaid_block=false
    if grep -qE '```mermaid|~~~mermaid' "$diagram_file"; then
        has_mermaid_block=true
        log_debug "Found Mermaid code block in diagram"
    fi
    
    # Check for Mermaid diagram keywords
    local has_mermaid_syntax=false
    for keyword in "${mermaid_keywords[@]}"; do
        if grep -qE "^[[:space:]]*${keyword}[[:space:]]" "$diagram_file"; then
            has_mermaid_syntax=true
            log_debug "Found Mermaid keyword: $keyword"
            break
        fi
    done
    
    if ! $has_mermaid_syntax; then
        if [[ "$severity" == "error" ]]; then
            log_error "Architecture diagram missing valid Mermaid syntax: $diagram_file"
        else
            log_warning "Architecture diagram may be missing Mermaid syntax: $diagram_file"
        fi
        log_info "Expected keywords: ${mermaid_keywords[*]}"
        return 1
    fi
    
    if ! $has_mermaid_block; then
        log_warning "Architecture diagram missing Mermaid code block markers (\`\`\`mermaid)"
        log_info "Consider wrapping diagram in proper markdown code blocks"
    fi
    
    log_success "Architecture diagram validation passed: $diagram_file"
    return 0
}

#######################################
# Validate execution plan format
# Arguments:
#   $1 - Severity level: "error" or "warn" (default: warn)
# Returns: 0 if valid, 1 if invalid
#######################################
validate_execution_plan() {
    local severity="${1:-warn}"
    local plan_file="${PLAN_FILE:-ralph_plan.md}"
    
    if [[ ! -f "$plan_file" ]]; then
        log_debug "Execution plan not found: $plan_file (will be created)"
        return 0
    fi
    
    # Check file is not empty
    if [[ ! -s "$plan_file" ]]; then
        if [[ "$severity" == "error" ]]; then
            log_error "Execution plan is empty: $plan_file"
        else
            log_warning "Execution plan is empty: $plan_file"
        fi
        return 1
    fi
    
    # Count checkbox items
    local total_checkboxes unchecked_boxes checked_boxes
    total_checkboxes=$(grep -cE '^\s*[-*+]\s+\[([ x])\]' "$plan_file" 2>/dev/null || true)
    unchecked_boxes=$(grep -cF '[ ]' "$plan_file" 2>/dev/null || true)
    checked_boxes=$(grep -cF '[x]' "$plan_file" 2>/dev/null || true)
    
    if [[ $total_checkboxes -eq 0 ]]; then
        if [[ "$severity" == "error" ]]; then
            log_error "Execution plan has no checkbox items: $plan_file"
        else
            log_warning "Execution plan has no checkbox items: $plan_file"
        fi
        log_info "Expected format: '- [ ] Task description' or '- [x] Completed task'"
        return 1
    fi
    
    # Calculate completion percentage
    local completion_pct=0
    if [[ $total_checkboxes -gt 0 ]]; then
        completion_pct=$((checked_boxes * 100 / total_checkboxes))
    fi
    
    log_debug "Execution plan: $total_checkboxes tasks ($checked_boxes completed, $unchecked_boxes pending) - ${completion_pct}% complete"
    
    # Warn if no progress
    if [[ $checked_boxes -eq 0 ]] && [[ $total_checkboxes -gt 0 ]]; then
        log_info "Execution plan has $total_checkboxes tasks, none completed yet"
    fi
    
    # Warn if everything is checked (might need new tasks)
    if [[ $checked_boxes -eq $total_checkboxes ]] && [[ $total_checkboxes -gt 0 ]]; then
        log_info "All tasks completed! Consider updating plan with new objectives."
    fi
    
    log_success "Execution plan validation passed: $plan_file (${completion_pct}% complete)"
    return 0
}

#######################################
# Validate all artifacts and generate report
# Returns: Detailed validation report as string
#######################################
generate_validation_report() {
    local report=""
    report+="=== Ralph Artifact Validation Report ===\n"
    report+="Generated: $(date '+%Y-%m-%d %H:%M:%S')\n\n"
    
    # PRD validation
    report+="[PRD] Product Requirements Document:\n"
    if [[ -f "${PRD_FILE:-prd.json}" ]]; then
        if validate_prd >/dev/null 2>&1; then
            report+="  ✓ Valid JSON structure\n"
        else
            report+="  ✗ Invalid or malformed JSON\n"
        fi
    else
        report+="  - Not found (will be created)\n"
    fi
    
    # Architecture diagram validation
    report+="\n[ARCH] Architecture Diagram:\n"
    if [[ -f "${DIAGRAM_FILE:-ralph_architecture.md}" ]]; then
        if validate_architecture_diagram "warn" >/dev/null 2>&1; then
            report+="  ✓ Valid Mermaid syntax detected\n"
        else
            report+="  ⚠ Missing or invalid Mermaid syntax\n"
        fi
    else
        report+="  - Not found (will be created)\n"
    fi
    
    # Execution plan validation
    report+="\n[PLAN] Execution Plan:\n"
    if [[ -f "${PLAN_FILE:-ralph_plan.md}" ]]; then
        local plan_file="${PLAN_FILE:-ralph_plan.md}"
        local total checked unchecked pct
        total=$(grep -cE '^\s*[-*+]\s+\[([ x])\]' "$plan_file" 2>/dev/null || true)
        checked=$(grep -cF '[x]' "$plan_file" 2>/dev/null || true)
        unchecked=$(grep -cF '[ ]' "$plan_file" 2>/dev/null || true)
        
        if [[ $total -gt 0 ]]; then
            pct=$((checked * 100 / total))
            report+="  ✓ Valid checklist format\n"
            report+="  Tasks: $total total ($checked done, $unchecked pending)\n"
            report+="  Progress: ${pct}%\n"
        else
            report+="  ⚠ No checkbox items found\n"
        fi
    else
        report+="  - Not found (will be created)\n"
    fi
    
    echo -e "$report"
}  