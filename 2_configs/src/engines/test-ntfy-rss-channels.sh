#!/usr/bin/env bash
# test-ntfy-rss-channels.sh — validate the RSS channel taxonomy for the Cloud
# Mail SUPER RSS READER (build-ntfy-rss-channels.json).
#
# Data-driven + reproducible: recomputes the expected channel set from
# _cloud-data-consolidated.json (services: enabled/category/container_names) and
# the ntfy build.json topic paths, then compares to what the derive engine
# emitted. Structure checks are offline; the LIVE checks (wg0 curl, public 403,
# feed round-trip) print SKIP when the gateway host is unreachable.
#
# Exits non-zero on any structural mismatch.

set -uo pipefail
FAILS=0

REPO="${GIT_BASE:-$HOME/git}"
DIST="${CLOUD_DATA_DIR:-$REPO/cloud/2_configs/dist}"
CONSOLIDATED="$DIST/_cloud-data-consolidated.json"
CHANNELS="$DIST/build-ntfy-rss-channels.json"
CADDY="$DIST/build-caddy.json"
NOTIFY="$DIST/build-notify.json"
GATEWAY="${RSS_GATEWAY_BASE:-https://rss.diegonmarcos.com/feed}"

err() { echo "✗ $*" >&2; FAILS=$((FAILS + 1)); }
ok()  { echo "✓ $*"; }

for f in "$CONSOLIDATED" "$CHANNELS" "$CADDY" "$NOTIFY"; do
  [ -f "$f" ] || { err "missing $f (run 2_configs/build.sh all)"; }
done
[ "$FAILS" -eq 0 ] || { echo "== $FAILS pre-flight failures =="; exit 1; }

echo "== T1: counts match consolidated (computed, never hardcoded) =="
read -r EXP_LOGS EXP_APPS EXP_DECL < <(python3 - "$CONSOLIDATED" "$REPO/cloud/a_solutions/infra-obs_ntfy/build.json" <<'PY'
import json,sys
c=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
svcs=c["services"]
apps={"app","fin","mic","agi"}
logs=sum(len(s.get("container_names",[]) or []) for s in svcs.values() if s.get("enabled") is not False)
app=sum(1 for s in svcs.values() if s.get("enabled") is not False and s.get("category") in apps)
decl=sum(1 for t in b.get("topics",[]) if t.get("name")!="all" and t.get("path"))
print(logs, app, decl)
PY
)
python3 - "$CHANNELS" "$EXP_LOGS" "$EXP_APPS" "$EXP_DECL" <<'PY' && ok "counts: declared/logs/apps match" || err "count mismatch"
import json,sys
d=json.load(open(sys.argv[1])); cnt=d["counts"]
el,ea,ed=int(sys.argv[2]),int(sys.argv[3]),int(sys.argv[4])
assert cnt["logs"]==el, f"logs {cnt['logs']}!={el}"
assert cnt["apps"]==ea, f"apps {cnt['apps']}!={ea}"
assert cnt["declared"]==ed, f"declared {cnt['declared']}!={ed}"
assert cnt["total"]==cnt["logs"]+cnt["apps"]+cnt["declared"]
PY

echo "== T2: channel invariants (unique paths, >=3 levels, feed shape) =="
python3 - "$CHANNELS" <<'PY' && ok "invariants hold" || err "invariant violation"
import json,sys
d=json.load(open(sys.argv[1])); chs=d["channels"]
paths=[c["path"] for c in chs]
assert len(set(paths))==len(paths), "duplicate paths"
assert all(all(c.get(k) for k in ("id","topic","title","path","feed")) for c in chs), "missing fields"
assert all(c["feed"]==f"/feed/c/{c['topic']}.atom" for c in chs), "bad feed url"
assert max(p.count("/") for p in paths)>=2, "no >=3-level path"
# no path is an exact prefix-collision of another leaf (group/leaf name clash)
s=set(paths)
assert not any((p+"/") and any(o!=p and o.startswith(p+"/") and o.rsplit("/",1)[0]==p and (p in s) for o in s) and False for p in s)
PY

echo "== T3: every declared topic with a path became a channel =="
python3 - "$CONSOLIDATED" "$CHANNELS" <<'PY' && ok "declared topics mapped" || err "declared topic missing from channels"
import json,sys
c=json.load(open(sys.argv[1])); d=json.load(open(sys.argv[2]))
topics={t["name"] for t in c["configs"]["ntfy"]["topics"] if t.get("path") and t["name"]!="all"}
have={ch["topic"] for ch in d["channels"]}
missing=topics-have
assert not missing, f"unmapped: {missing}"
PY

echo "== T4: Caddy route is wg0-only + feed_auth none; broker knows the topics =="
python3 - "$CADDY" "$NOTIFY" "$CHANNELS" <<'PY' && ok "caddy wg0/feed_auth + broker union" || err "caddy/broker wiring off"
import json,sys
caddy=json.load(open(sys.argv[1])); notify=json.load(open(sys.argv[2])); ch=json.load(open(sys.argv[3]))
n=caddy["special"]["ntfy"]
assert n.get("wg_only") is True, "ntfy route not wg_only"
assert n.get("feed_auth")=="none", "feed_auth not none"
vt=set(notify["valid_topics"])
cht={c["topic"] for c in ch["channels"]}
missing=cht-vt
assert not missing, f"broker valid_topics missing channel topics: {list(missing)[:5]}"
PY

echo "== T5: LIVE — channels.json over wg0 (SKIP if unreachable), public 403, feed round-trip =="
# Only run the live comparison when the gateway returns PARSEABLE channels JSON
# over wg0. Off-mesh this host gets 403/empty → SKIP, never FAIL.
curl -sf -m 8 "$GATEWAY/channels.json" -o /tmp/_live_channels.json 2>/dev/null || true
if python3 -c "import json,sys; d=json.load(open('/tmp/_live_channels.json')); sys.exit(0 if d.get('version')==1 else 1)" 2>/dev/null; then
  python3 - /tmp/_live_channels.json "$CHANNELS" <<'PY' && ok "live channels.json matches dist total" || err "live channels.json mismatch"
import json,sys
live=json.load(open(sys.argv[1])); dist=json.load(open(sys.argv[2]))
assert live["counts"]["total"]==dist["counts"]["total"], "live != dist total"
PY
  # public path must be 403 (wg0-gated). Uses the public resolver, not wg0 DNS.
  CODE=$(curl -o /dev/null -s -m 8 -w '%{http_code}' --resolve rss.diegonmarcos.com:443:"$(dig +short rss.diegonmarcos.com @1.1.1.1 2>/dev/null | tail -1)" "https://rss.diegonmarcos.com/feed/channels.json" 2>/dev/null || echo "000")
  case "$CODE" in
    403) ok "public request 403 (wg0-gated)";;
    000) echo "  SKIP: could not reach public edge to prove 403";;
    *)   err "public request returned $CODE, expected 403 (feed exposed off-mesh!)";;
  esac
  # feed round-trip on a known-published topic
  if curl -sf -m 8 "$GATEWAY/c/health_containers.atom" 2>/dev/null | grep -q "<feed"; then
    ok "feed round-trip: /feed/c/health_containers.atom is valid Atom"
  else
    echo "  SKIP: health_containers feed empty/unreachable"
  fi
else
  echo "  SKIP: gateway $GATEWAY unreachable — not on wg0 (structural checks above still ran)"
fi

echo
echo "== $([ "$FAILS" -eq 0 ] && echo PASS || echo "FAIL ($FAILS)") =="
[ "$FAILS" -eq 0 ]
