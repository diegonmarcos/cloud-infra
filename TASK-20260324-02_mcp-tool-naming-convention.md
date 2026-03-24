# TASK: Standardize MCP Tool Naming Convention

> Created: 2026-03-24

## Naming Rules

### c3-infra-mcp (EXEC tools) — `{pillar}-{name}`
Pillars: `ops`, `delivery`, `notify`, `security`, `mail`, `cloud`, `mm` (mattermost)

Examples:
- `ops-ssh_exec`, `ops-docker_ps`, `ops-docker_logs`, `ops-vm_start`
- `delivery-build_service`, `delivery-build_ship`, `delivery-backup_trigger`
- `notify-send`, `notify-health_down`, `notify-cert_expiring`
- `security-scan`, `security-docker`, `security-ssh_keys`
- `mail-up`, `mail-full`, `mail-send_test`
- `cloud-up`, `cloud-full`
- `mm-post`, `mm-read`, `mm-react`, `mm-reply`

### c3-services-mcp (service gateway) — `{service}-{category}-{action}`
Categories: `read`, `write`, `config`, `health`

Examples:
- `matomo-analytics-visits`, `matomo-analytics-sites`
- `syncthing-sync-status`, `syncthing-sync-config`
- `ntfy-notify-publish`, `ntfy-notify-health`
- `ollama-ai-models`, `ollama-ai-chat`, `ollama-ai-generate`
- `radicale-cal-calendars`, `radicale-cal-events`
- `registry-meta-list`, `registry-meta-spec`

### code-graph-context (READ knowledge) — `{section}-{name}`
Sections: `octocode`, `cloud-spec`, `cloud-docs`, `cloud-data`, `front-spec`, `front-docs`, `front-data`, `codegraph`

Examples:
- `octocode-search`, `octocode-memory`, `octocode-index`
- `cloud-spec-topology`, `cloud-spec-configs`, `cloud-spec-deps`
- `cloud-docs-readme`, `cloud-docs-service`, `cloud-docs-overview`
- `cloud-data-vms`, `cloud-data-services`, `cloud-data-health`
- `front-spec-projects`, `front-spec-deps`
- `codegraph-trace`, `codegraph-impact`, `codegraph-deps`

## Scope
- c3-infra-mcp: ~61 tools to rename
- c3-services-mcp: ~31 tools to rename
- code-graph-context: ~81 tools to rename (17 existing + 58 moved + 6 new)

## Implementation
1. Create mapping table: old name → new name
2. Update tool registrations in each .ts file
3. Update any tool name references in shared code
4. Test all 3 MCP servers
5. Update CLAUDE.md tool tables (via unix flake source)
