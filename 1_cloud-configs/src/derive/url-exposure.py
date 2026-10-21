#!/usr/bin/env python3
"""url-exposure.py -- the single reader of the three-tier URL exposure policy.

Policy (owner, 2026-10-16), declared ONCE in cloud-u-containers
infra-sec_caddy/build.json  caddy_config.edge_auth  and carried by the derive
into build-caddy.json / build-caddy-edge.json. Every URL is exactly one of:

  a) private           mesh / WireGuard only. Not served by the public edge;
                       the hub answers 403 to any non-mesh source.
  b) public-protected  DEFAULT for anything public: `import edge_auth` -- fleet
                       Bearer (introspect-proxy) OR Authelia session cookie.
  c) public-open       anonymous allowed; ONLY what edge_auth.public_open and
                       edge_auth.technical declare, each with a reason.

This script reads the RENDERED Caddyfiles (the committed dist/configs/Caddyfile
of infra-sec_caddy and infra-sec_caddy-public) plus the two build-caddy*.json,
and offers three verbs:

  check          fail (exit 1) if any site is in no tier / two tiers, a private
                 site is served by the edge, an open site is not declared, an
                 exemption path is rendered but undeclared (or declared but not
                 rendered), or a site-level `redir` would run before the gate.
  table          write the human-readable markdown table (a0_docs/url-exposure.md).
  probe-list     print `kind<TAB>host<TAB>path<TAB>expect` lines for
                 9_others/test/edge-auth-probe.sh.

Stdlib only; reads files, never the network.
"""
import fnmatch
import json
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
A = os.environ.get("A_SOLUTIONS", os.path.join(ROOT, "a_solutions"))
HUB_CADDYFILE = os.environ.get("HUB_CADDYFILE", os.path.join(A, "infra-sec_caddy/dist/configs/Caddyfile"))
EDGE_CADDYFILE = os.environ.get("EDGE_CADDYFILE", os.path.join(A, "infra-sec_caddy-public/dist/configs/Caddyfile"))
HUB_JSON = os.environ.get("HUB_JSON", os.path.join(ROOT, "1_cloud-configs/dist/build-caddy.json"))
EDGE_JSON = os.environ.get("EDGE_JSON", os.path.join(ROOT, "1_cloud-configs/dist/build-caddy-edge.json"))
TABLE_PATH = os.environ.get("EXPOSURE_TABLE", os.path.join(ROOT, "a0_docs/url-exposure.md"))

ACME = "/.well-known/acme-challenge/*"
GATES = ("edge_auth", "edge_auth_offmesh", "edge_auth_ws")
MESH_PREFIXES = ("10.0.0.", "127.", "::1", "fd0c:")


# ───────────────────────── Caddyfile parsing ─────────────────────────
def _count(line):
    line = re.sub(r"`[^`]*`", "``", line)
    line = re.sub(r'"[^"]*"', '""', line)
    return line.count("{") - line.count("}")


def parse_sites(text):
    """Return (global_lines, [site]) where site = dict(addrs, lines[(depth,text)])."""
    sites, glob = [], []
    cur, depth, in_global = None, 0, False
    for raw in text.split("\n"):
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        d_before = depth
        delta = _count(s)
        if depth == 0:
            if s == "{":
                in_global = True
                depth += delta
                continue
            if s.endswith("{") and not s.startswith("("):
                addr = s[:-1].strip()
                cur = {"addrs": [a.strip() for a in re.split(r",\s*|\s+", addr) if a.strip()],
                       "raw_addr": addr, "lines": []}
            elif s.startswith("(") and s.endswith("{"):
                cur = {"snippet": s, "lines": []}
        elif cur is not None:
            cur["lines"].append((d_before, s))
        elif in_global:
            glob.append(s)
        depth += delta
        if depth == 0:
            if cur is not None and "addrs" in cur:
                sites.append(cur)
            cur = None
            in_global = False
        if depth < 0:
            depth = 0
    return glob, sites


def host_of(addr):
    a = re.sub(r"^https?://", "", addr)
    return a.split("/")[0].split(":")[0] if not a.startswith(":") else a


def analyse(site):
    """Extract tier-relevant features from a parsed site block."""
    kids = [t for d, t in site["lines"] if d == 1]
    binds = []
    for t in kids:
        if t.startswith("bind "):
            binds += t.split()[1:]
    mesh_bound = bool(binds) and all(b.startswith(MESH_PREFIXES) for b in binds)
    gate = None
    gate_paths = []
    for t in kids:
        p = t.split()
        if len(p) >= 2 and p[0] == "import" and p[1] in GATES:
            gate = p[1]
            gate_paths = p[2:]
    # WG / mesh guard: a matcher naming `not remote_ip` answered by `respond ... 403` or `error ... 403` (the latter reaches the shared handle_errors fallback redirect)
    guard, exempt = None, []
    lines = site["lines"]
    for i, (d, t) in enumerate(lines):
        if d == 1 and re.match(r"@(not_wg|not_mesh)\b", t):
            name = t.split()[0]
            if "not remote_ip" in t:
                guard = name
            elif t.endswith("{"):
                j = i + 1
                body = []
                while j < len(lines) and lines[j][0] > 1:
                    body.append(lines[j][1]); j += 1
                if any(b.startswith("not remote_ip") for b in body):
                    guard = name
                for b in body:
                    if b.startswith("not path"):
                        exempt += b.split()[2:]
    responds = any(d == 1 and re.match(r"(respond|error) " + re.escape(guard or "@@") + r"\b", t) and "403" in t for d, t in lines) if guard else False
    if guard and not responds:
        guard = None
    bare_redir = [t for t in kids if t.startswith("redir ")]
    bare_serving = [t for t in kids if re.match(r"(reverse_proxy|file_server|respond)\b", t) and not t.startswith("respond @ea_pre")
                    and not (guard and t.startswith("respond " + guard))]
    return {"binds": binds, "mesh_bound": mesh_bound, "gate": gate, "gate_paths": gate_paths,
            "guard": guard, "wg_exempt_paths": exempt, "bare_redir": bare_redir}


# ───────────────────────── policy ─────────────────────────
def load_policy(hub_json):
    ea = hub_json.get("edge_auth") or {}
    open_hosts = {e["host"] for e in ea.get("public_open", []) if e.get("scope", "host") == "host"}
    # multi-SSO (#1066): when the flag is on, the sign-in hosts are the IdP vhost (tier c, like auth.).
    ms = ea.get("multi_sso") or {}
    if ms.get("enabled"):
        open_hosts |= set(ms.get("hosts", []))
    path_open = {}
    ws_hosts = set()
    for e in ea.get("public_open", []):
        if e.get("scope") == "paths":
            path_open.setdefault(e["host"], []).extend(e.get("paths", []))
        if e.get("scope") == "websocket":
            ws_hosts.add(e["host"])
    tech_hosts = set()
    for e in ea.get("technical", []):
        tech_hosts.update(e.get("hosts", []))
    return ea, open_hosts, path_open, ws_hosts, tech_hosts


def held_hosts(ea):
    return {e["host"] for e in ea.get("held", [])}


def classify(where, site, open_hosts, path_open, ws_hosts, held=frozenset()):
    """-> (tier, why, problems[]) for one site block."""
    f = analyse(site)
    hosts = [host_of(a) for a in site["addrs"]]
    probs = []
    if hosts and all(h in held for h in hosts):
        if f["gate"]:
            probs.append("declared HELD (gate deferred) but the gate is rendered -- drop the held entry")
        return "h", "HELD: gate deferred (edge_auth.held)", probs, f
    all_open = all(h in open_hosts for h in hosts)
    any_open = any(h in open_hosts for h in hosts)
    if f["gate"]:
        # tier b -- the exemptions must be exactly acme + the host's declared paths
        want = {ACME}
        for h in hosts:
            want.update(path_open.get(h, []))
        got = set(f["gate_paths"])
        if got - want:
            probs.append("undeclared exemption path(s) rendered: " + " ".join(sorted(got - want)))
        if want - got:
            probs.append("declared exemption path(s) not rendered: " + " ".join(sorted(want - got)))
        ws_want = any(h in ws_hosts for h in hosts)
        if ws_want and f["gate"] != "edge_auth_ws":
            probs.append("websocket exemption declared but gate is " + f["gate"])
        if not ws_want and f["gate"] == "edge_auth_ws":
            probs.append("edge_auth_ws used without a declared websocket exemption")
        if any_open:
            probs.append("in TWO tiers: declared public-open (host) but carries the auth gate")
        if f["gate"] == "edge_auth_offmesh" and not (f["guard"] or any(h.startswith("mcp.") for h in hosts)):
            probs.append("edge_auth_offmesh without a mesh guard (a public host would trust mesh sources unauthenticated)")
        if f["bare_redir"]:
            probs.append("site-level `redir` runs BEFORE the gate (wrap in handle {}): " + "; ".join(f["bare_redir"]))
        return "b", ("offmesh" if f["gate"] == "edge_auth_offmesh" else f["gate"]), probs, f
    if f["mesh_bound"]:
        if any_open:
            probs.append("in TWO tiers: declared public-open but bound to the mesh only")
        return "a", "mesh-bound listener (" + " ".join(f["binds"]) + ")", probs, f
    if all_open:
        if f["guard"]:
            probs.append("in TWO tiers: declared public-open but carries a mesh-only guard")
        return "c", "declared public-open", probs, f
    if f["guard"]:
        if f["wg_exempt_paths"]:
            probs.append("private site exposes off-mesh path(s) " + " ".join(f["wg_exempt_paths"]) + " without `import edge_auth_offmesh`")
        if f["bare_redir"]:
            probs.append("site-level `redir` runs before the mesh guard: " + "; ".join(f["bare_redir"]))
        return "a", "mesh guard " + f["guard"], probs, f
    probs.append("IN NO TIER: public site with no gate, no mesh guard, and not declared public-open")
    return None, "", probs, f


def load():
    hub_text = open(HUB_CADDYFILE).read()
    edge_text = open(EDGE_CADDYFILE).read()
    hub_json = json.load(open(HUB_JSON))
    edge_json = json.load(open(EDGE_JSON))
    return hub_text, edge_text, hub_json, edge_json


def evaluate():
    hub_text, edge_text, hub_json, edge_json = load()
    ea, open_hosts, path_open, ws_hosts, tech_hosts = load_policy(hub_json)
    problems, rows = [], []
    res = {"hub": [], "edge": []}
    for where, text in (("hub", hub_text), ("edge", edge_text)):
        glob, sites = parse_sites(text)
        for s in sites:
            if s["raw_addr"] in (":2020",):
                s["addrs"] = [":2020"]
            tier, why, probs, f = classify(where, s, open_hosts, path_open, ws_hosts, held_hosts(ea))
            for p in probs:
                problems.append(f"[{where}] {s['raw_addr']}: {p}")
            res[where].append({"addr": s["raw_addr"], "hosts": [host_of(a) for a in s["addrs"]],
                               "tier": tier, "why": why, "feat": f})
        res[where + "_global"] = glob
    # the gate snippets must accept the fleet token in X-Fleet-Authorization (clients whose
    # Authorization carries a mailbox credential: jmap./mails.) and strip it before proxying
    for where, text in (("hub", hub_text), ("edge", edge_text)):
        for snip in ("edge_auth", "edge_auth_offmesh", "edge_auth_ws"):
            m = re.search(r"^\s*\(" + snip + r"\) \{\n(.*?)^  \}\n", text, re.S | re.M)
            body = m.group(1) if m else ""
            for need in ("header X-Fleet-Authorization Bearer*",
                         "header_up Authorization {http.request.header.X-Fleet-Authorization}",
                         "request_header -X-Fleet-Authorization"):
                if need not in body:
                    problems.append(f"[{where}] ({snip}) snippet lacks `{need}` (X-Fleet-Authorization path)")
    # the edge must not serve a private site
    hub_private = {h for r in res["hub"] if r["tier"] == "a" for h in r["hosts"]}
    for r in res["edge"]:
        for h in r["hosts"]:
            if h in hub_private:
                problems.append(f"[edge] {h}: a PRIVATE (tier a) host is served by the public edge")
    for rt in edge_json.get("public_routes", []):
        if rt.get("wg_only") is True:
            problems.append(f"[edge-json] public_routes carries wg_only host {rt.get('domain')}")
    # every declared public-open host / exemption must exist somewhere, else the list is stale
    rendered_hosts = {h for w in ("hub", "edge") for r in res[w] for h in r["hosts"]}
    for h in sorted(open_hosts | set(path_open) | ws_hosts | held_hosts(ea)):
        if h not in rendered_hosts:
            problems.append(f"[policy] declared public-open host {h} has no site block in either Caddyfile")
    # L4 passthrough (non-HTTP): every mail SNI must be declared
    snis = set()
    for rt in (edge_json.get("mail_l4_routes") or []) + (hub_json.get("l4_routes") or []):
        if rt.get("sni"):
            snis.add(rt["sni"])
    for sni in sorted(snis - tech_hosts):
        problems.append(f"[l4] {sni} is forwarded as raw TLS but is not declared in edge_auth.technical (mail-protocol-l4)")
    # the policy block must be identical in both build jsons
    if (hub_json.get("edge_auth") or {}) != (edge_json.get("edge_auth") or {}):
        problems.append("[policy] edge_auth differs between build-caddy.json and build-caddy-edge.json")
    if not hub_json.get("edge_auth"):
        problems.append("[policy] build-caddy.json carries no edge_auth block")
    for e in ea.get("public_open", []):
        if not e.get("reason"):
            problems.append(f"[policy] public_open entry {e.get('host')} has no reason")
    for e in ea.get("held", []):
        if not e.get("reason"):
            problems.append(f"[policy] held entry {e.get('host')} has no reason")
    for e in ea.get("technical", []):
        if not e.get("reason"):
            problems.append(f"[policy] technical entry {e.get('id')} has no reason")
    return res, problems, (ea, open_hosts, path_open, ws_hosts, tech_hosts), hub_json, edge_json


# ───────────────────────── table ─────────────────────────
BEARER_OR_COOKIE = "Bearer (fleet token, introspect-proxy; `Authorization` or `X-Fleet-Authorization`) OR Authelia session"


def md_escape(s):
    return str(s).replace("|", "\\|")


def build_table():
    res, problems, pol, hub_json, edge_json = evaluate()
    ea, open_hosts, path_open, ws_hosts, tech_hosts = pol
    L = []
    L.append("# URL exposure -- every public host and route, by tier\n")
    L.append("<!-- GENERATED by 1_cloud-configs/src/derive/url-exposure.py table -- do not edit. "
             "Source of truth: cloud-u-containers infra-sec_caddy/build.json caddy_config.edge_auth "
             "(+ the wg_only flags in each service build.json). Guard: 9_others/test/edge-auth-gate.test.sh -->\n")
    L.append("Owner rule (2026-10-16): **PUBLIC URL = fleet Bearer OR Authelia session cookie.** "
             "Every route is in exactly one tier:\n")
    L.append("| Tier | Meaning | Access |\n|---|---|---|")
    L.append("| a) private | mesh / WireGuard only; never served by the public edge | 403 to any non-mesh source |")
    L.append(f"| b) public-protected | **default** for anything public; `import edge_auth` | {BEARER_OR_COOKIE}; else 401 (API) / 302 to auth. (browser) |")
    L.append("| c) public-open | anonymous; ONLY what is listed below, each with a reason | none |\n")

    L.append("## Tier c: public-open (the complete list)\n")
    L.append("| Host | Scope | Reason |\n|---|---|---|")
    for e in ea.get("public_open", []):
        sc = e.get("scope", "host")
        scope = "whole host" if sc == "host" else ("paths: " + " ".join(f"`{p}`" for p in e.get("paths", []))
                                                   if sc == "paths" else "WebSocket upgrade requests only (`Upgrade: websocket`)")
        L.append(f"| {e['host']} | {md_escape(scope)} | {md_escape(e.get('reason',''))} |")
    for e in ea.get("technical", []):
        host = "every host" if not e.get("hosts") else ", ".join(e["hosts"])
        L.append(f"| {host} | {md_escape(e.get('id',''))}: `{md_escape(e.get('match','non-HTTP listener'))}` | {md_escape(e.get('reason',''))} |")
    L.append("")

    if ea.get("held"):
        L.append("## HELD: temporarily not behind the gate\n")
        L.append("| Host | Reason |\n|---|---|")
        for e in ea["held"]:
            L.append(f"| {e['host']} | {md_escape(e.get('reason',''))} |")
        L.append("")

    for where, title in (("edge", "Public edge (caddy-public, oci-analytics)"), ("hub", "Hub (caddy, gcp-proxy)")):
        L.append(f"## {title}: sites\n")
        L.append("| Host | Tier | Current auth | Exempt (tier c) paths |\n|---|---|---|---|")
        rows = res[where]
        mesh_groups = {}
        for r in sorted(rows, key=lambda r: (r["tier"] or "z", r["addr"])):
            if r["addr"] in (":2020",) or r["addr"].startswith("http://"):
                tier_desc = "a (loopback / mesh-bound listener)"
                L.append(f"| `{r['addr']}` | {tier_desc} | not reachable off-mesh | - |")
                continue
            h = ", ".join(r["hosts"])
            if r["tier"] == "a" and r["feat"]["mesh_bound"] is False and re.search(r"\.(app|db)$", r["hosts"][0]):
                mesh_groups.setdefault(r["hosts"][0].rsplit(".", 1)[1], []).append(r["hosts"][0])
                continue
            f = r["feat"]
            if r["tier"] == "b":
                auth = BEARER_OR_COOKIE
                if f["gate"] == "edge_auth_offmesh":
                    auth += " -- enforced for non-mesh sources; mesh peers keep WG trust"
                if f["gate"] == "edge_auth_ws":
                    auth += " -- except `Upgrade: websocket`"
                if f["guard"]:
                    auth += "; plus mesh guard on the rest"
                ex = [p for p in f["gate_paths"] if p != ACME]
                tier = "b"
            elif r["tier"] == "a":
                auth = "mesh only (403 off-mesh)"
                ex = []
                tier = "a"
            elif r["tier"] == "h":
                auth = "**HELD: not gated yet** (wg_only vhost exposing JMAP discovery off-mesh; Stalwart password only) -- temporary, see edge_auth.held"
                ex = []
                tier = "h"
            elif r["tier"] == "c":
                auth = "none (anonymous)"
                ex = ["whole host"]
                tier = "c"
            else:
                auth, ex, tier = "**NONE -- violation**", [], "?"
            L.append(f"| {h} | {tier} | {md_escape(auth)} | {md_escape(' '.join('`'+p+'`' for p in ex)) or '-'} |")
        for sfx, names in sorted(mesh_groups.items()):
            L.append(f"| {len(names)} x `*.{sfx}` names | a | mesh only (`@not_mesh` 403; edge L4 forwards the SNI but the hub refuses non-mesh sources) | - |")
        L.append("")

    L.append("## Routes inside a host\n")
    L.append("A tier-b host's gate runs before any of these; the inner column is the *additional* per-route restriction.\n")
    L.append("| Host | Route | Tier | Inner restriction |\n|---|---|---|---|")
    for g in hub_json.get("path_routes", []):
        for p in g.get("paths", []):
            inner = "mesh only (wg_only)" if p.get("wg_only") else "Bearer OR Authelia (mkProtected)"
            L.append(f"| {g['parent_domain']} | `{p['base_path']}/*` | b | {inner} |")
            for pp in p.get("public_paths", []) or []:
                L.append(f"| {g['parent_domain']} | `{pp}` | b | formerly anonymous (public_paths); now behind the gate |")
    for g in hub_json.get("mcp_routes", []):
        for e in g.get("endpoints", []):
            inner = "Bearer (introspect)" if e.get("bearer_auth") else ("mesh only" if e.get("wg_only") else "none (bare proxy)")
            L.append(f"| {g['parent_domain']} | `{e['base_path']}/*` | b | {inner}; mesh peers pass the WG branch |")
    for h, paths in sorted(path_open.items()):
        for p in paths:
            L.append(f"| {h} | `{p}` | c | declared public-open |")
    for h in sorted(ws_hosts):
        L.append(f"| {h} | `Upgrade: websocket` | c | declared public-open (wstunnel enforces its own secret path prefix) |")
    L.append(f"| every host | `{ACME}` | c | ACME http-01 |")
    L.append("| every host | `OPTIONS` + `Access-Control-Request-Method` | c | CORS preflight, answered 204 by the gate, never proxied |")
    L.append("")
    L.append("## Non-HTTP listeners (not subject to the HTTP gate)\n")
    L.append("| Listener | Auth |\n|---|---|")
    snis = sorted({rt['sni'] for rt in (edge_json.get('mail_l4_routes') or []) + (hub_json.get('l4_routes') or []) if rt.get('sni')})
    for s in snis:
        L.append(f"| {s} (raw TLS via caddy-l4 on :443) | Stalwart mail login (IMAPS / SMTPS) |")
    L.append("")
    if problems:
        L.append("## GUARD FAILURES at generation time\n")
        for p in problems:
            L.append(f"- {md_escape(p)}")
        L.append("")
    return "\n".join(L) + "\n"


# ───────────────────────── probe list ─────────────────────────
def probe_list():
    res, problems, pol, hub_json, edge_json = evaluate()
    ea, open_hosts, path_open, ws_hosts, tech_hosts = pol
    out, seen = [], set()

    def add(kind, host, path, expect):
        k = (host, path)
        if k not in seen:
            seen.add(k)
            out.append(f"{kind}\t{host}\t{path}\t{expect}")

    for where in ("edge", "hub"):
        for r in res[where]:
            if r["addr"] in (":2020",) or r["addr"].startswith("http://") or r["tier"] is None:
                continue
            for h in r["hosts"]:
                if h.startswith("*") or ":" in h:
                    continue
                if h.endswith((".app", ".db")):
                    continue            # mesh-only names: edge-auth-probe.sh probes a fixed sample through the edge IP
                if r["tier"] in ("c", "h"):
                    add("open", h, "/", "any")
                elif r["tier"] == "b":
                    add("protected", h, "/", "gated")
                    add("protected", h, "/zz-edge-auth-probe", "gated")
                elif r["tier"] == "a":
                    add("private", h, "/", "refused")
    for g in hub_json.get("path_routes", []):
        for p in g.get("paths", []):
            add("protected", g["parent_domain"], p["base_path"] + "/", "gated")
            for pp in p.get("public_paths", []) or []:
                declared = any(fnmatch.fnmatch(pp, pat) for pat in path_open.get(g["parent_domain"], []))
                add("open" if declared else "protected", g["parent_domain"], pp.replace("*", "x"), "any" if declared else "gated")
    for g in hub_json.get("mcp_routes", []):
        for e in g.get("endpoints", []):
            add("protected", g["parent_domain"], e["base_path"] + "/mcp", "gated")
    for wk in hub_json.get("well_known_routes", []):
        if wk["target_domain"] in held_hosts(ea):
            continue
        add("protected", wk["target_domain"], wk["path"].replace("*", "x"), "gated")
    for h in ("diegonmarcos.com",):
        add("protected", h, "/.well-known/openpgpkey/hu/x", "gated")
    add("protected", "zz-edge-auth-probe-unknown." + "diegonmarcos.com", "/", "gated")   # the *.diegonmarcos.com catch-all
    # tier-c paths: report only (anonymous allowed), plus a sibling that must stay protected
    for h, paths in sorted(path_open.items()):
        for p in paths:
            add("open", h, p.replace("*", "x"), "any")
    # an exempt path must not widen: probe a neighbour of each
    add("protected", "mcp.diegonmarcos.com", "/c3-infra-mcp/mcp", "gated")
    add("protected", "analytics.diegonmarcos.com", "/umami/api/websites", "gated")
    add("protected", "matrix.diegonmarcos.com", "/_matrix/client/versions", "gated")
    add("protected", "vpn.diegonmarcos.com", "/", "gated")
    return out


def main():
    verb = sys.argv[1] if len(sys.argv) > 1 else "check"
    if verb == "check":
        res, problems, *_ = evaluate()
        n = sum(len(res[w]) for w in ("hub", "edge"))
        tiers = {}
        for w in ("hub", "edge"):
            for r in res[w]:
                tiers[r["tier"]] = tiers.get(r["tier"], 0) + 1
        print(f"edge-auth gate: {n} site blocks (hub {len(res['hub'])}, edge {len(res['edge'])}); "
              f"tier a={tiers.get('a',0)} b={tiers.get('b',0)} c={tiers.get('c',0)} none={tiers.get(None,0)} HELD={tiers.get('h',0)}")
        for w in ("hub", "edge"):
            for r in res[w]:
                if r["tier"] == "h":
                    print(f"WARN: {r['addr']} is HELD -- NOT behind the gate yet (temporary, edge_auth.held)")
        if problems:
            print(f"FAIL: {len(problems)} problem(s)")
            for p in problems:
                print("  - " + p)
            return 1
        if os.path.exists(TABLE_PATH):
            if open(TABLE_PATH).read() != build_table():
                print(f"FAIL: {TABLE_PATH} is stale -- run: python3 1_cloud-configs/src/derive/url-exposure.py table")
                return 1
        else:
            print(f"FAIL: {TABLE_PATH} is missing -- run: python3 1_cloud-configs/src/derive/url-exposure.py table")
            return 1
        print("PASS")
        return 0
    if verb == "table":
        t = build_table()
        os.makedirs(os.path.dirname(TABLE_PATH), exist_ok=True)
        open(TABLE_PATH, "w").write(t)
        print("wrote " + TABLE_PATH)
        return 0
    if verb == "probe-list":
        print("\n".join(probe_list()))
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
