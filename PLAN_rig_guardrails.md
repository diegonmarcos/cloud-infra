# AI Guardrails for rig-agentic

## Context

rig-core already structurally restricts the LLM to only calling registered MCP tools — no bash, no filesystem, no network. The guardrails we add are:
1. **Audit logging** — log every tool call (name, args, result summary)
2. **Rate limiting** — high limit for now (20 tools per turn, 15 max turns already set)
3. **MCP denylist** — empty for now, but infrastructure ready to block tools by name

## Files to Modify

### `src/src/guardrails.rs` (NEW)
- `InfraGuardrail` struct implementing `rig::agent::PromptHook`
- Fields: `max_tools_per_turn: usize`, `denied_tools: HashSet<String>`
- `on_tool_call()`: log tool call, check denylist → Skip if denied
- `on_tool_result()`: log result summary, increment counter, check rate limit
- If rate limit violated: `HookAction::Terminate` + log reason
- Configurable via env vars

### `src/src/agent.rs` (MODIFY lines 175-179, 233-237)
- Add `.hook(InfraGuardrail::from_config(config))` to both agent builders
- Both `execute_agent_loop()` and `run_agent_chat()` get the hook

### `src/src/config.rs` (MODIFY)
- Add `guardrail_max_tools_per_turn: usize` (env `GUARDRAIL_MAX_TOOLS=20`)
- Add `guardrail_denied_tools: Vec<String>` (env `GUARDRAIL_DENIED_TOOLS=""`)

### `src/src/main.rs` (MODIFY)
- Add `mod guardrails;`

### `src/flake.nix` (MODIFY)
- Add env vars: `GUARDRAIL_MAX_TOOLS = "20"`, `GUARDRAIL_DENIED_TOOLS = ""`

## Execution Order

1. Create `guardrails.rs` with `InfraGuardrail` + `PromptHook` impl
2. Add config fields to `config.rs`
3. Wire hook into `agent.rs` (both agent builders)
4. Add `mod guardrails` to `main.rs`
5. Add env vars to `flake.nix`
6. Commit, push, GHA deploys

## Verification

1. Check container logs for `TOOL_CALL:` audit entries after any agent interaction
2. Verify rate limit by asking agent to "check health of every VM one by one" (should work under 20/turn)
3. Test denylist by temporarily adding a tool name to `GUARDRAIL_DENIED_TOOLS` env var
