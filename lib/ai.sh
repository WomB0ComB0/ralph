#!/bin/bash

#######################################
# Estimate token count for text content
# Uses multiple heuristics for better accuracy
# Arguments:
#   $1 - Content to estimate
#   $2 - (Optional) Estimation method: "simple", "advanced", or "tiktoken"
# Returns: Estimated token count
#######################################
estimate_tokens() {
    local content="$1"
    local method="${2:-advanced}"
    
    case "$method" in
        simple)
            # Simple heuristic: characters / 4
            local char_count=${#content}
            echo $((char_count / 4))
            ;;
            
        advanced)
            # More accurate multi-factor estimation
            local char_count word_count line_count code_count
            
            char_count=${#content}
            word_count=$(echo "$content" | wc -w | xargs)
            line_count=$(echo "$content" | wc -l | xargs)
            
            # Detect code content (has common programming patterns)
            code_count=$(echo "$content" | grep -cE '^\s*(function|def|class|import|const|let|var|if|for|while|\{|\}|;)' || true)
            
            # Adjust estimation based on content type
            if [[ "$code_count" -gt $((line_count / 4)) ]]; then
                # Code-heavy content: chars/3.5 (code is more token-dense)
                echo $(( (char_count * 10) / 35 ))
            else
                # Natural language: weighted average of char/4 and word*1.3
                echo $(( (char_count / 4 + word_count * 13 / 10) / 2 ))
            fi
            ;;
            
        tiktoken)
            # Use tiktoken if available (Python required)
            if command_exists python3 && python3 -c "import tiktoken" 2>/dev/null; then
                export TOKEN_CONTENT="$content"
                python3 <<EOF
import tiktoken
import sys
import os

content = os.environ.get('TOKEN_CONTENT', '')
model = os.environ.get('SELECTED_MODEL', 'gpt-4')

try:
    # Try to get encoding for the specific model
    try:
        encoding = tiktoken.encoding_for_model(model)
    except:
        # Fallback to cl100k_base (used by GPT-4 and many modern models)
        encoding = tiktoken.get_encoding("cl100k_base")
    
    tokens = encoding.encode(content)
    print(len(tokens))
except Exception as e:
    # Final fallback if anything goes wrong
    print(len(content) // 4)
EOF
            else
                log_debug "tiktoken not available, falling back to advanced estimation"
                estimate_tokens "$content" "advanced"
            fi
            ;;
            
        *)
            log_warning "Unknown token estimation method: $method, using advanced"
            estimate_tokens "$content" "advanced"
            ;;
    esac
}

#######################################
# Get latest high-performance model from opencode
# Prioritizes: Gemini/GLM/Claude with flash/pro > Other preferred > Qwen > Any
# Returns: Model identifier
#######################################
get_latest_opencode_model() {
    local all_models
    
    # Get available models
    if ! all_models=$(opencode models 2>/dev/null); then
        log_warning "Failed to get opencode models list"
        echo "google/gemini-2.0-flash-exp"
        return 1
    fi
    
    if [[ -z "$all_models" ]]; then
        log_warning "No models available from opencode"
        echo "google/gemini-2.0-flash-exp"
        return 1
    fi
    
    log_debug "Available models from opencode:"
    log_debug "$all_models"
    
    # Filter out non-text models
    local text_models
    text_models=$(echo "$all_models" | grep -vE "audio|tts|embedding|image|vision|whisper|dall-e|live" || echo "")
    
    # Priority 1: Preferred families (Gemini, GLM, Claude) with flash/pro capabilities
    local high_perf_preferred
    high_perf_preferred=$(echo "$text_models" | grep -iE "gemini|glm|claude" | grep -iE "flash|pro|thinking|exp" | sort -V -r | head -n 1)
    
    if [[ -n "$high_perf_preferred" ]]; then
        log_debug "Selected high-performance preferred model: $high_perf_preferred"
        echo "$high_perf_preferred"
        return 0
    fi
    
    # Priority 2: Any preferred family model (even non-flash/pro)
    local any_preferred
    any_preferred=$(echo "$text_models" | grep -iE "gemini|glm|claude" | sort -V -r | head -n 1)
    
    if [[ -n "$any_preferred" ]]; then
        log_debug "Selected preferred family model: $any_preferred"
        echo "$any_preferred"
        return 0
    fi
    
    # Priority 3: Qwen models (good code performance)
    local qwen_model
    qwen_model=$(echo "$text_models" | grep -iE "qwen" | grep -iE "coder|2\.5" | sort -V -r | head -n 1)
    
    if [[ -n "$qwen_model" ]]; then
        log_debug "Selected Qwen model: $qwen_model"
        echo "$qwen_model"
        return 0
    fi
    
    # Priority 4: Any Qwen model
    qwen_model=$(echo "$text_models" | grep -iE "qwen" | sort -V -r | head -n 1)
    
    if [[ -n "$qwen_model" ]]; then
        log_debug "Selected fallback Qwen model: $qwen_model"
        echo "$qwen_model"
        return 0
    fi
    
    # Priority 5: Other capable models (DeepSeek, Mistral, etc.)
    local other_capable
    other_capable=$(echo "$text_models" | grep -iE "deepseek|mistral|llama-3|codestral" | sort -V -r | head -n 1)
    
    if [[ -n "$other_capable" ]]; then
        log_debug "Selected capable alternative model: $other_capable"
        echo "$other_capable"
        return 0
    fi
    
    # Priority 6: First available text model
    local first_model
    first_model=$(echo "$text_models" | head -n 1)
    
    if [[ -n "$first_model" ]]; then
        log_warning "Using first available model: $first_model"
        echo "$first_model"
        return 0
    fi
    
    # Final fallback - default to known working model
    log_error "No suitable models found, using hardcoded fallback"
    echo "google/gemini-2.0-flash-exp"
    return 1
}

#######################################
# Get default model for specific tool
# Arguments:
#   $1 - Tool name (amp, claude, opencode)
# Returns: Default model identifier
#######################################
get_default_model_for_tool() {
    local tool="$1"
    
    case "$tool" in
        amp)
            echo "claude-3-5-sonnet-20241022"
            ;;
        claude)
            echo "claude-3-5-sonnet-20241022"
            ;;
        opencode)
            echo "google/gemini-2.0-flash-exp"
            ;;
        *)
            log_warning "Unknown tool: $tool, using generic default"
            echo "claude-3-5-sonnet-20241022"
            ;;
    esac
}

#######################################
# Determine which model to use
# Respects SELECTED_MODEL override, otherwise auto-selects
# Sets global SELECTED_MODEL variable
# Returns: 0 on success, 1 on failure
#######################################
determine_model() {
    # If model explicitly specified, use it
    if [[ -n "${SELECTED_MODEL:-}" ]]; then
        log_info "Using user-specified model: ${GREEN}$SELECTED_MODEL${NC}"
        return 0
    fi
    
    local auto_selected_model
    
    # Auto-select based on tool
    case "$TOOL" in
        opencode)
            log_info "Auto-selecting model for opencode..."
            auto_selected_model=$(get_latest_opencode_model)
            
            if [[ $? -ne 0 ]] || [[ -z "$auto_selected_model" ]]; then
                log_warning "Failed to auto-select model, using default"
                auto_selected_model=$(get_default_model_for_tool "opencode")
            fi
            ;;
            
        amp|claude)
            log_debug "Using default model for $TOOL"
            auto_selected_model=$(get_default_model_for_tool "$TOOL")
            ;;
            
        *)
            log_error "Unknown tool: $TOOL"
            return 1
            ;;
    esac
    
    # Validate we got a model
    if [[ -z "$auto_selected_model" ]]; then
        log_error "Failed to determine model"
        return 1
    fi
    
    SELECTED_MODEL="$auto_selected_model"
    export SELECTED_MODEL
    
    log_success "Auto-selected model: $SELECTED_MODEL"
    return 0
}

#######################################
# Validate model availability
# Arguments:
#   $1 - Model identifier
#   $2 - Tool name (optional, for tool-specific validation)
# Returns: 0 if available, 1 if not
#######################################
validate_model_availability() {
    local model="$1"
    local tool="${2:-$TOOL}"
    
    case "$tool" in
        opencode)
            if ! command_exists opencode; then
                log_error "opencode not installed, cannot validate model"
                return 1
            fi
            
            local available_models
            available_models=$(opencode models 2>/dev/null || echo "")
            
            if echo "$available_models" | grep -qF "$model"; then
                log_debug "Model validated: $model"
                return 0
            else
                log_warning "Model not found in opencode: $model"
                return 1
            fi
            ;;
            
        amp|claude)
            # For Anthropic models, we can't easily validate without API call
            # Just check if it looks like a valid model identifier
            if [[ "$model" =~ ^claude-[0-9]+-[a-z]+-[0-9]+ ]]; then
                log_debug "Model format looks valid: $model"
                return 0
            else
                log_warning "Model format may be invalid: $model"
                return 1
            fi
            ;;
            
        *)
            log_debug "Cannot validate model for unknown tool: $tool"
            return 0
            ;;
    esac
}

#######################################
# Display model information
#######################################
show_model_info() {
    echo ""
    log_info "Model Configuration:"
    log_info "  Tool:  ${MAGENTA}$TOOL${NC}"
    log_info "  Model: ${GREEN}$SELECTED_MODEL${NC}"
    
    # Show if model was auto-selected or user-specified
    if [[ -n "${SELECTED_MODEL_SOURCE:-}" ]]; then
        log_info "  Source: $SELECTED_MODEL_SOURCE"
    fi
    
    # Validate if possible
    if validate_model_availability "$SELECTED_MODEL" "$TOOL"; then
        log_success "  Status: ✓ Available"
    else
        log_warning "  Status: ⚠ Could not verify availability"
    fi
    
    echo ""
}
