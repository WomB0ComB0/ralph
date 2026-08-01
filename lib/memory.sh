#!/bin/bash
# lib/memory.sh — ralph memory ↔ Synapse bridge.
# Ingests verified skills + mined failure themes into Synapse as idempotent
# documents, and retrieves them back into fix-agent prompts. Fail-open: no Synapse
# error ever blocks a caller. Depends on: synapse.sh (_synapse_ingest_doc,
# synapse_ping, synapse_ground), skills.sh (skill files), mine.sh (_mine_scan,
# _mine_action), signals.sh (record_signal), utils.sh (_signal_sha1).

# Retrieve a prompt-injectable <synapse_context> block for a query. Always rc 0.
memory_ground() {
    local query="${1:-}"
    [[ -n "$query" ]] || return 0
    declare -F synapse_ground >/dev/null || return 0
    synapse_ground "$query" 2>/dev/null || return 0
    return 0
}
