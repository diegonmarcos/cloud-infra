# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 1_cicd/src/scripts/cloud-ship-container-step-wrangler-logs.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Step: Query Cloudflare Worker observability logs
# Sourced by cloud-ship-container-engine.sh after step-wrangler.sh
# (depends on _load_cf_credentials helper defined there)
#
# Data sources (declarative, no hardcoding):
#   - $SRC_DIR/wrangler.toml      name, account_id
#   - cloudflare.env in vault     CF_API_KEY, CF_API_EMAIL
#
# Args (positional, all optional):
#   $1  since   how far back to look — Ns|Nm|Nh|Nd (default: 15m)
#   $2  limit   max events to return (default: 100)
#   $3  format  pretty|json (default: pretty)

step_wrangler_logs() {
    CURRENT_STEP="wrangler-logs"

    _wlog_toml="$SRC_DIR/wrangler.toml"
    if [ ! -f "$_wlog_toml" ]; then
        log_error "wrangler.toml not found at $_wlog_toml"
        return 1
    fi

    _wlog_name=$(grep -E '^[[:space:]]*name[[:space:]]*=' "$_wlog_toml" | head -1 | cut -d'"' -f2)
    _wlog_account=$(grep -E '^[[:space:]]*account_id[[:space:]]*=' "$_wlog_toml" | head -1 | cut -d'"' -f2)
    if [ -z "$_wlog_name" ] || [ -z "$_wlog_account" ]; then
        log_error "wrangler.toml missing name or account_id"
        return 1
    fi

    if ! _load_cf_credentials; then
        log_error "CLOUDFLARE_API_KEY not found (checked vault + environment)"
        return 1
    fi

    _wlog_since="${1:-15m}"
    _wlog_limit="${2:-100}"
    _wlog_format="${3:-pretty}"

    # Translate "15m" / "2h" / "1d" / "30s" → seconds
    _wlog_n="${_wlog_since%[smhd]}"
    case "$_wlog_since" in
        *s) _wlog_secs="$_wlog_n" ;;
        *m) _wlog_secs=$((_wlog_n * 60)) ;;
        *h) _wlog_secs=$((_wlog_n * 3600)) ;;
        *d) _wlog_secs=$((_wlog_n * 86400)) ;;
        *) log_error "Invalid --since '$_wlog_since' (use Ns|Nm|Nh|Nd)"; return 1 ;;
    esac

    _wlog_now_ms=$(($(date +%s) * 1000))
    _wlog_from_ms=$((_wlog_now_ms - _wlog_secs * 1000))

    log "Querying Workers logs: $_wlog_name (since ${_wlog_since}, limit ${_wlog_limit})"

    _wlog_url="https://api.cloudflare.com/client/v4/accounts/${_wlog_account}/workers/observability/telemetry/query"
    _wlog_body=$(cat <<EOF
{
  "queryId": "build-sh-logs",
  "timeframe": {"from": ${_wlog_from_ms}, "to": ${_wlog_now_ms}},
  "parameters": {
    "datasets": ["cloudflare-workers"],
    "filters": [{"key": "\$metadata.service", "type": "string", "operation": "eq", "value": "${_wlog_name}"}]
  },
  "view": "events",
  "limit": ${_wlog_limit}
}
EOF
)

    _wlog_out=$(mktemp)
    curl -fsS -X POST "$_wlog_url" \
        -H "X-Auth-Email: $CLOUDFLARE_EMAIL" \
        -H "X-Auth-Key: $CLOUDFLARE_API_KEY" \
        -H "Content-Type: application/json" \
        --data "$_wlog_body" > "$_wlog_out" || {
            log_error "Cloudflare API call failed"
            rm -f "$_wlog_out"; return 1
        }

    if [ "$_wlog_format" = "json" ]; then
        cat "$_wlog_out"
        rm -f "$_wlog_out"
        return 0
    fi

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$_wlog_out" <<'PY'
import json, sys, datetime
d = json.load(open(sys.argv[1]))
if not d.get('success'):
    print('API error:', d.get('errors'))
    sys.exit(1)
events = d['result']['events']['events']
print(f'─ {len(events)} events ─')
for e in sorted(events, key=lambda x: x['timestamp']):
    ts = datetime.datetime.fromtimestamp(e['timestamp']/1000).strftime('%H:%M:%S')
    s = e.get('source', {}) or {}
    lvl = s.get('level', 'info')
    msg = s.get('message', '?')
    w = e.get('$workers', {}) or {}
    sv = ((w.get('scriptVersion') or {}).get('id') or '????????')[:8]
    print(f'[{ts}][{sv}][{lvl:5}] {msg}')
PY
    else
        log_error "python3 required for pretty output (use 'json' format)"
        rm -f "$_wlog_out"; return 1
    fi
    rm -f "$_wlog_out"
}
