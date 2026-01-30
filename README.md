# Ralph Wiggum Agent Architecture

Ralph is a sophisticated autonomous AI agent system that uses "Grounded Architecture" principles to maintain consistency across three key artifacts (PRD, Plan, Diagram) while employing reflexion techniques to detect and break out of unproductive loops.

## System Overview

```mermaid
graph TB
    subgraph "Entry Point"
        CLI[Command Line Interface]
        Config[Configuration Loading]
    end
    
    subgraph "Setup & Validation"
        Setup[Setup Mode]
        Deps[Dependency Installer]
        Validate[Config Validator]
    end
    
    subgraph "Core State Management"
        PRD[prd.jsonGoals & Requirements]
        BeadsDB[.beads/Task Database]
        Plan[ralph_plan.mdHuman-Readable Tasks]
        Diagram[ralph_architecture.mdMermaid Diagrams]
        Progress[progress.txtRun Metadata]
        Checkpoint[.ralph_checkpointResume Point]
    end
    
    subgraph "Iteration Engine"
        Loop[Main Loop Controller]
        Context[Context Builder]
        Prompt[System Prompt Generator]
        AITool[AI Tool Executor]
        Validator[Artifact Validator]
        Analysis[Post-Execution Analysis]
    end
    
    subgraph "AI Tool Integration"
        OpenCode[opencode - Primary]
        AMP[amp - Anthropic MCP]
        Claude[claude-cli]
        Copilot[GitHub Copilot]
    end
    
    subgraph "Task Management"
        Beads[Beads CLI - bd]
        Dolt[Dolt - Time Travel]
        SQLite[SQLite Backend]
    end
    
    subgraph "State Detection"
        HashBefore[Pre-Hash Calculator]
        HashAfter[Post-Hash Calculator]
        LoopDetect[Loop Detection]
        LazyDetect[Lazy Detection]
    end
    
    subgraph "Reflexion System"
        Trigger[Reflexion Trigger]
        Correction[Error Correction]
        Steering[User Steering]
    end
    
    subgraph "Memory & Coordination"
        GenMemory[Genetic Memory~/.config/ralph/memory]
        WarRoom[War Room EventsReal-time coordination]
    end
    
    subgraph "Utilities"
        Git[Git Operations]
        Archive[Archive Manager]
        Logger[Logging System]
        Metrics[Metrics Tracker]
    end
    
    CLI --> Config
    Config --> Setup
    Config --> Validate
    
    Setup --> Deps
    Deps --> OpenCode
    Deps --> AMP
    Deps --> Claude
    Deps --> Copilot
    Deps --> Beads
    Deps --> Dolt
    
    Validate --> Loop
    
    Loop --> Context
    Context --> PRD
    Context --> BeadsDB
    Context --> Plan
    Context --> Diagram
    Context --> Git
    Context --> GenMemory
    Context --> WarRoom
    
    Context --> Prompt
    Prompt --> AITool
    
    AITool --> OpenCode
    AITool --> AMP
    AITool --> Claude
    AITool --> Copilot
    
    BeadsDB --> Dolt
    BeadsDB --> SQLite
    Beads --> BeadsDB
    
    AITool --> Validator
    Validator --> PRD
    Validator --> Plan
    Validator --> Diagram
    
    Validator --> Analysis
    
    Analysis --> HashBefore
    Analysis --> HashAfter
    HashAfter --> LazyDetect
    HashAfter --> LoopDetect
    
    LazyDetect --> Trigger
    LoopDetect --> Trigger
    Validator --> Correction
    
    Trigger --> Loop
    Correction --> Loop
    Steering --> Loop
    
    Loop --> Checkpoint
    Loop --> Progress
    Loop --> Metrics
    Loop --> Logger
    
    Archive --> PRD
    Archive --> Plan
    Archive --> Progress

    style PRD fill:#e1f5ff
    style BeadsDB fill:#e1f5ff
    style Plan fill:#e1f5ff
    style Diagram fill:#e1f5ff
    style Loop fill:#fff4e1
    style AITool fill:#f0e1ff
    style Trigger fill:#ffe1e1
    style Beads fill:#e1ffe1
    style GenMemory fill:#ffe1f0
```

## Data Flow Sequence

```mermaid
sequenceDiagram
    participant User
    participant CLI
    participant Setup
    participant MainLoop
    participant Context
    participant AI
    participant Validator
    participant State
    participant Beads
    participant Files

    User->>CLI: ./ralph.sh [--tool opencode]
    CLI->>Setup: Load config & validate
    Setup->>State: Check for resume checkpoint
    State-->>Setup: Last iteration (if any)
    
    Setup->>MainLoop: Start main loop
    Setup->>Beads: Initialize task engine
    
    rect rgb(13, 17, 23)
        Note over MainLoop,Files: Iteration Loop (1 to MAX_ITERATIONS)
        
        MainLoop->>Context: Build context window
        Context->>Files: Read PRD, Plan, Diagram
        Context->>Beads: Read task status (bd ready)
        Files-->>Context: Current state
        Context->>Files: Read git diff (optional)
        Files-->>Context: Recent changes
        
        Context->>Context: Generate system prompt
        Context->>State: Hash project state (before)
        
        MainLoop->>AI: Execute tool with prompt
        Note over AI: Model automatically routedbased on role (planner/engineer/tester)
        AI-->>MainLoop: Agent response
        
        MainLoop->>Validator: Validate artifacts
        Validator->>Files: Check PRD JSON validity
        Validator->>Files: Check Mermaid syntax
        Validator->>Files: Check Plan checkboxes
        Validator->>Beads: Verify task states
        Validator-->>MainLoop: Errors (if any)
        
        MainLoop->>State: Hash project state (after)
        State->>State: Compare hashes
        
        alt No changes detected
            State->>State: Increment lazy streak
            State->>MainLoop: Inject reflexion trigger
        else Changes detected
            State->>State: Reset lazy streak
        end
        
        alt Loop detected
            State->>MainLoop: Inject loop-breaking trigger
        end
        
        MainLoop->>Beads: Sync task state to plan file
        MainLoop->>Beads: Commit task state (Dolt)
        MainLoop->>State: Save checkpoint
        MainLoop->>Files: Update metrics log
        
        alt Completion signal detected AND all tasks closed
            MainLoop-->>User: Task complete!
        else Tasks remain
            MainLoop->>MainLoop: Continue iteration
        end
    end
    
    MainLoop-->>User: Max iterations reached
```

## State Tracking & Reflexion

```mermaid
stateDiagram-v2
    [*] --> Initializing
    Initializing --> LoadingContext: Config valid
    
    LoadingContext --> ExecutingAI: Prompt ready
    
    ExecutingAI --> ValidatingArtifacts: AI response received
    
    ValidatingArtifacts --> AnalyzingChanges: Artifacts valid
    ValidatingArtifacts --> InjectingCorrection: Artifacts invalid
    
    InjectingCorrection --> LoadingContext: Correction queued
    
    AnalyzingChanges --> DetectingProgress: Hash comparison done
    
    DetectingProgress --> ProgressMade: Files changed
    DetectingProgress --> NoProgress: No changes
    
    NoProgress --> CheckingLazyStreak: Increment streak
    ProgressMade --> ResetStreak: Reset streak
    
    CheckingLazyStreak --> InjectingReflexion: Streak >= 2
    CheckingLazyStreak --> CheckingLoop: Streak < 2
    
    ResetStreak --> CheckingLoop
    
    CheckingLoop --> InjectingLoopBreaker: Loop detected
    CheckingLoop --> SavingCheckpoint: No loop
    
    InjectingReflexion --> SavingCheckpoint
    InjectingLoopBreaker --> SavingCheckpoint
    
    SavingCheckpoint --> SyncingBeads: Checkpoint saved
    
    SyncingBeads --> CheckingCompletion: Plan synced
    
    CheckingCompletion --> Completed: COMPLETE AND all tasks closed
    CheckingCompletion --> LoadingContext: Continue iteration
    CheckingCompletion --> MaxIterations: Iteration limit reached
    
    Completed --> [*]
    MaxIterations --> [*]
```

## Dependency Installation Flow

```mermaid
flowchart TD
    Start([Setup Mode]) --> DetectOS{Detect OS & Arch}
    
    DetectOS -->|Linux| CheckPkgMgr
    DetectOS -->|macOS| CheckPkgMgr
    DetectOS -->|Windows| CheckPkgMgr
    
    CheckPkgMgr{Package Manager?}
    CheckPkgMgr -->|Found| InstallCore
    CheckPkgMgr -->|Missing| InstallPkgMgr[Install Package Manager]
    
    InstallPkgMgr --> InstallCore
    
    InstallCore[Install Core Dependencies]
    InstallCore --> Git[Install Git]
    InstallCore --> JQ[Install jq]
    InstallCore --> BC[Install bc]
    InstallCore --> SQLite[Install sqlite3]
    InstallCore --> Python[Install Python3]
    InstallCore --> Bun[Install Bun]
    
    Bun --> PromptAI
    
    PromptAI{Auto-Install AI Tools}
    
    PromptAI --> InstallOpenCode[Install opencode]
    PromptAI --> InstallBeads[Install beads - bd]
    PromptAI --> InstallDolt[Install dolt]
    PromptAI --> InstallPython[Install tiktoken & ruff]
    PromptAI --> InstallNode[Install claude-code & ast-grep]
    
    InstallOpenCode --> Complete([Setup Complete])
    InstallBeads --> Complete
    InstallDolt --> Complete
    InstallPython --> Complete
    InstallNode --> Complete
```

## File Management & Archiving

```mermaid
graph LR
    subgraph "Active Run"
        PRD1[prd.json]
        Plan1[ralph_plan.md]
        Diagram1[ralph_architecture.md]
        Progress1[progress.txt]
        Log1[ralph.log]
        Branch1[.last-branch]
        Beads1[.beads/]
    end
    
    subgraph "Branch Detection"
        Check{Branch Changed?}
    end
    
    subgraph "Archive Structure"
        ArchiveDir[archives/]
        Date1[2026-01-25_14-30-00-feature-auth/]
        Date2[2026-01-24_09-15-30-bugfix-login/]
    end
    
    Branch1 --> Check
    PRD1 --> Check
    
    Check -->|Yes| Archive[Archive Previous Run]
    Check -->|No| Continue[Continue Current Run]
    
    Archive --> Date1
    PRD1 -.copy.-> Date1
    Plan1 -.copy.-> Date1
    Progress1 -.copy.-> Date1
    Log1 -.copy.-> Date1
    
    Continue --> PRD1

    style Check fill:#fff4e1
    style Archive fill:#ffe1e1
```

## Task Management with Beads

```mermaid
graph TD
    subgraph "Beads Task Database"
        BeadsRoot[.beads/]
        DB[tasks.dbSQLite or Dolt]
    end
    
    subgraph "Task Operations"
        Create[bd create]
        List[bd ready]
        Close[bd close]
        Status[bd count]
        VC[bd vc - Time Travel]
    end
    
    subgraph "Task States"
        Open[Open]
        InProgress[In Progress]
        Blocked[Blocked]
        Closed[Closed]
    end
    
    subgraph "Sync to Human-Readable"
        PlanFile[ralph_plan.md]
    end
    
    BeadsRoot --> DB
    
    Create --> DB
    List --> DB
    Close --> DB
    Status --> DB
    VC --> DB
    
    DB --> Open
    DB --> InProgress
    DB --> Blocked
    DB --> Closed
    
    DB --> PlanFile
    
    style DB fill:#e1ffe1
    style PlanFile fill:#e1f5ff
    style VC fill:#ffe1f0
```

## Intelligent Model Routing

```mermaid
flowchart LR
    Start[Agent Role] --> Router{Model Router}
    
    Router -->|planner| Planner[High-Reasoning Models]
    Router -->|engineer| Engineer[High-Speed Models]
    Router -->|tester| Tester[Efficient Models]
    Router -->|thinker| Thinker[Deep Reasoning Models]
    
    Planner --> GeminiPro[Gemini 2.0 Pro/Thinking]
    Engineer --> GeminiFlash[Gemini 2.0 Flash]
    Tester --> GeminiLite[Gemini 2.0 Flash/Lite]
    Thinker --> GeminiThinking[Gemini 2.0 Thinking]
    
    GeminiPro --> Fallback{Model Available?}
    GeminiFlash --> Fallback
    GeminiLite --> Fallback
    GeminiThinking --> Fallback
    
    Fallback -->|No| Alternative[Alternative Models]
    Fallback -->|Yes| Execute[Execute]
    
    Alternative --> Opus[Claude Opus]
    Alternative --> DeepSeek[DeepSeek]
    Alternative --> Mistral[Mistral]
    
    Opus --> Execute
    DeepSeek --> Execute
    Mistral --> Execute
    
    style Router fill:#fff4e1
    style GeminiPro fill:#e1ffe1
    style GeminiFlash fill:#e1ffe1
```

## Key Features

### 1. Grounded Architecture
Ralph maintains synchronized artifacts for consistent execution:
- **prd.json**: Product requirements in JSON format
- **ralph_plan.md**: Human-readable execution plan synced from Beads
- **ralph_architecture.md**: Mermaid diagrams of system architecture
- **agents.md**: Project-specific instructions and conventions (highly effective for agent alignment)

### 2. Time-Travel Task Management
- Uses **Beads** (`bd` CLI) for dependency-aware task tracking
- Optional **Dolt** backend provides git-like version control for tasks
- Full task history and ability to replay states
- Tasks automatically synced to human-readable plan file

### 3. Intelligent Model Routing
- Automatically routes requests to optimal models based on role:
  - **Planner/Thinker**: High-reasoning models (Gemini 2.0 Pro/Thinking)
  - **Engineer**: High-speed implementation (Gemini 2.0 Flash)
  - **Tester**: Efficient verification models
- Dynamic model discovery and caching
- Fallback chains for unavailable models

### 4. Reflexion & Loop Detection
- **Lazy Detection**: Identifies when agent isn't making progress (no file changes)
- **Loop Detection**: Catches repetitive actions via log signature analysis
- **Automatic Correction**: Injects reflexion prompts to break unproductive patterns
- **User Steering**: Interactive mode for mid-iteration guidance

### 5. Genetic Memory
- Persists engineering lessons across projects
- Stored in `~/.config/ralph/memory/global.json`
- Automatically recalls relevant patterns
- Helps avoid repeating mistakes

### 6. Self-Healing Tooling
- Auto-detects missing dependencies (pytest, npm, cargo, etc.)
- Attempts autonomous installation via `ralph setup`
- Graceful degradation when tools unavailable

### 7. War Room Coordination
- Real-time event system for multi-agent coordination
- Message passing between agents
- Task board for swarm orchestration

## Usage

### Basic Usage
```bash
# Run with default tool (opencode)
./ralph.sh

# Specify a tool
./ralph.sh --tool opencode
./ralph.sh --tool amp
./ralph.sh --tool claude

# Specify model
./ralph.sh --model "google/gemini-2.0-flash-001"

# Set max iterations
./ralph.sh --max-iterations 20

# Resume from checkpoint
./ralph.sh --resume

# Interactive mode (pause between iterations)
./ralph.sh --interactive

# Run internal tests
./ralph.sh --test

# Run in Docker sandbox
./ralph.sh --sandbox

# Add context files
./ralph.sh --context docs/api.md --context lib/utils.sh

# Include recent git diffs in context
./ralph.sh --diff-context

# Disable archiving
./ralph.sh --no-archive
```

### Copilot Integration
```bash
# Run an agentic task with Copilot
./ralph.sh copilot run "Refactor the login function"

# Ask for an explanation
./ralph.sh copilot explain "How does the event bus work?"

# Authenticate Copilot
./ralph.sh copilot auth
```

### Setup
```bash
# Auto-install all dependencies
./ralph.sh --setup

# Initialize a new project
./ralph.sh --init
```

### Task Management
```bash
# Create a task
bd create "Implement user authentication" -d "Add JWT-based auth" --deps "tk-001"

# List ready tasks (unblocked)
bd ready

# Close a task
bd close tk-123

# View task history (with Dolt)
bd vc log
```

### Swarm Commands
```bash
# Spawn a sub-agent
./ralph.sh swarm spawn --role "Frontend Developer" --task "Build UI"

# Send message to agent
./ralph.sh swarm msg --to agent-123 --content "Status update?"

# List all agents
./ralph.sh swarm list
```

## Configuration

### Environment Variables
- `TOOL`: AI tool to use (opencode, amp, claude)
- `SELECTED_MODEL`: Specific model to use
- `MAX_ITERATIONS`: Maximum iterations (default: 10)
- `LOG_FILE`: Path to log file (default: ralph.log)
- `VERBOSE`: Enable debug logging (true/false)

### Configuration File
Ralph supports `.ralphrc` or `ralph.config.json` for persistent settings:

```json
{
  "tool": "opencode",
  "max_iterations": 15,
  "interactive": false,
  "verbose": true
}
```

## Required Dependencies

### Core
- bash (4.0+)
- git
- jq
- curl
- bc
- sqlite3
- python3
- bun (preferred) or npm

### AI Tools (at least one)
- opencode (recommended)
- amp (Anthropic MCP)
- claude-cli

### Task Management
- bd (beads) - installed via `go install`
- dolt (optional) - for time-travel capabilities

### Optional
- docker (for sandbox mode)
- ruff (Python linting)
- ast-grep (code analysis)
- tiktoken (accurate token counting)

## Architecture Principles

### Cognitive Process
Every agent response follows:
1. **Reflect**: Analyze recent changes and context
2. **Plan**: Identify next unblocked task from Beads
3. **Reason**: Determine efficient tool-path
4. **Anticipate**: Identify potential side effects

### Verification Mandatory
- All code changes require tests
- Tasks not closed until tests pass
- Runtime verification for services
- Architectural integrity checks

### Constraints
- **Diagram First**: Update architecture before complex features
- **Valid Artifacts**: Ensure JSON and Mermaid validity
- **No Loops**: Detect and break unproductive cycles
- **Termination**: Only signal completion when all tasks closed

## Project Structure

```
.
├── ralph.sh                  # Main entry point
├── lib/
│   ├── utils.sh             # Utility functions
│   ├── engine.sh            # Core iteration engine
│   └── tools.sh             # Tool integrations
├── prd.json                 # Product requirements
├── agents.md                # Project-specific instructions
├── ralph_plan.md            # Execution plan (synced from Beads)
├── ralph_architecture.md    # System diagrams
├── progress.txt             # Run metadata
├── ralph.log                # Execution log
├── .ralph_checkpoint        # Resume state
├── .last-branch             # Branch tracking
├── .beads/                  # Task database
│   └── tasks.db             # SQLite or Dolt
└── archives/                # Previous runs
    └── 2026-01-28_10-30-00-feature/
```

## Advanced Features

### Context Windowing
Ralph intelligently manages context window size:
- Prioritizes recent and relevant information
- Compresses older context
- Maintains critical artifacts in full

### Token Estimation
Multiple estimation methods:
- Simple (chars/4)
- Advanced (heuristic with code detection)
- tiktoken (accurate, requires Python library)

### Runtime Verification
Automatically identifies and verifies:
- Rust projects (`cargo check`)
- Node.js projects (package.json validation)
- Python projects (`ruff check`)
- Go projects (`go vet`)
- Running services (health checks, benchmarks)

### Performance Monitoring
- Tracks iteration metrics
- Monitors lazy streaks
- Logs token usage
- Detects performance regressions

## Troubleshooting

### Agent Making No Progress
- Check `ralph.log` for errors
- Review lazy streak counter
- Enable `--interactive` mode for steering
- Try different role or model

### Tasks Not Closing
- Verify tests are passing
- Check `bd ready` for blockers
- Review task dependencies

### Model Not Available
- Check `opencode models` for available options
- Specify model explicitly with `--model`
- Fallback chain will try alternatives

### Memory Issues
- Reduce `MAX_ITERATIONS`
- Enable archiving to clear old runs
- Check for large excluded directories

## Contributing

Ralph is designed to be extensible:
- Add new AI tools in `lib/tools.sh`
- Extend validation in `lib/engine.sh`
- Add new roles in `get_role_instructions()`
- Implement new features as skills

## License

See LICENSE file for details.