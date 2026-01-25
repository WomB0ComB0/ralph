# Ralph Wiggum Agent Architecture

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
        PRD[prd.json<br/>Goals & Requirements]
        Plan[ralph_plan.md<br/>Execution Checklist]
        Diagram[ralph_architecture.md<br/>Mermaid Diagrams]
        Progress[progress.txt<br/>Run Metadata]
        Checkpoint[.ralph_checkpoint<br/>Resume Point]
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
        AMP[amp - Anthropic MCP]
        Claude[claude-cli]
        OpenCode[opencode]
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
    Deps --> AMP
    Deps --> Claude
    Deps --> OpenCode
    
    Validate --> Loop
    
    Loop --> Context
    Context --> PRD
    Context --> Plan
    Context --> Diagram
    Context --> Git
    
    Context --> Prompt
    Prompt --> AITool
    
    AITool --> AMP
    AITool --> Claude
    AITool --> OpenCode
    
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
    style Plan fill:#e1f5ff
    style Diagram fill:#e1f5ff
    style Loop fill:#fff4e1
    style AITool fill:#f0e1ff
    style Trigger fill:#ffe1e1
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
    participant Files

    User->>CLI: ./ralph.sh --tool opencode
    CLI->>Setup: Load config & validate
    Setup->>State: Check for resume checkpoint
    State-->>Setup: Last iteration (if any)
    
    Setup->>MainLoop: Start main loop
    
    rect rgb(13, 17, 23)
        Note over MainLoop,Files: Iteration Loop (1 to MAX_ITERATIONS)
        
        MainLoop->>Context: Build context window
        Context->>Files: Read PRD, Plan, Diagram
        Files-->>Context: Current state
        Context->>Files: Read git diff (optional)
        Files-->>Context: Recent changes
        
        Context->>Context: Generate system prompt
        Context->>State: Hash project state (before)
        
        MainLoop->>AI: Execute tool with prompt
        AI-->>MainLoop: Agent response
        
        MainLoop->>Validator: Validate artifacts
        Validator->>Files: Check PRD JSON validity
        Validator->>Files: Check Mermaid syntax
        Validator->>Files: Check Plan checkboxes
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
        
        MainLoop->>State: Save checkpoint
        MainLoop->>Files: Update metrics log
        
        alt Completion signal detected
            MainLoop-->>User: Task complete!
        else Continue iteration
            MainLoop->>MainLoop: Next iteration
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
    
    SavingCheckpoint --> CheckingCompletion: Checkpoint saved
    
    CheckingCompletion --> Completed: <promise>COMPLETE</promise>
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
    InstallCore --> MD5[Install md5sum]
    
    MD5 --> PromptAI{Which AI Tools?}
    
    PromptAI -->|amp| InstallAMP[Install amp via npm]
    PromptAI -->|claude-cli| InstallClaude[Install claude-cli via npm]
    PromptAI -->|opencode| InstallOpenCode[Install opencode via curl]
    PromptAI -->|All| InstallAll[Install all tools]
    PromptAI -->|Skip| Complete
    
    InstallAMP --> Complete([Setup Complete])
    InstallClaude --> Complete
    InstallOpenCode --> Complete
    InstallAll --> Complete
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
    end
    
    subgraph "Branch Detection"
        Check{Branch Changed?}
    end
    
    subgraph "Archive Structure"
        ArchiveDir[archive/]
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

This diagram system shows:

1. **System Overview**: The complete architecture with all major components and their relationships
2. **Data Flow Sequence**: How information flows through the system during execution
3. **State Tracking**: The state machine showing how Ralph detects and responds to stalls and loops
4. **Dependency Installation**: The setup process for different operating systems
5. **File Management**: How archiving and branch tracking work

The architecture implements a sophisticated "Grounded Architecture" pattern where the agent maintains consistency across three key artifacts (PRD, Plan, Diagram) while using reflexion techniques to detect and break out of unproductive loops.
