#!/usr/bin/env bash

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/test_gen_configs_paths_cover_documented_sources.sh
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# Test: every file a vm-pilot nix module DOCUMENTS as an override source must
# match a `paths:` pattern of the workflow that regenerates the artifact the
# module actually reads (_cloud-data-consolidated.json <- ship-gen-configs).
#
# Regression (#656, fixed 90822649): load-shedder.nix documented
# b_infra/nixhm-sudo-<alias>/build.json .protection as its per-VM override
# source but read the consolidated artifact, and ship-gen-configs paths: had no
# b_infra/**/build.json — every .protection edit shipped byte-identical.
#
# Placeholders (<alias>, <vm>, <name>) are instantiated with every real
# b_infra/nixhm-sudo-* directory, so the check runs against real paths.
# Patterns use GitHub glob semantics: ** crosses /, * and ? do not.
set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(_d="$SCRIPT_DIR"; while [ "$_d" != "/" ] && [ ! -e "$_d/.git" ]; do _d="$(dirname "$_d")"; done; printf '%s' "$_d")"
WF="${GEN_CONFIGS_WF:-$REPO_ROOT/.github/workflows/ship-gen-configs.yml}"
MODS="$REPO_ROOT/b_infra/_shared/vm-pilot/src/modules"
echo "═══ test_gen_configs_paths_cover_documented_sources ═══"
python3 - "$REPO_ROOT" "$WF" "$MODS" <<'PY'
import os, re, sys, glob
root, wf, mods = sys.argv[1:4]
# --- paths: under on.push of the workflow
pats, inpush, inpaths = [], False, False
for line in open(wf):
    if re.match(r'^  push:', line): inpush = True; continue
    if inpush and re.match(r'^  \S', line): break
    if inpush and re.match(r'^    paths:', line): inpaths = True; continue
    if inpaths:
        m = re.match(r'^\s+- ["\']?([^"\'#]+?)["\']?\s*(#.*)?$', line)
        if m: pats.append(m.group(1)); continue
        if re.match(r'^    \S', line): inpaths = False
def g2re(p):
    out, i = '', 0
    while i < len(p):
        if p.startswith('**/', i): out += '(?:.*/)?'; i += 3
        elif p.startswith('**', i): out += '.*'; i += 2
        elif p[i] == '*': out += '[^/]*'; i += 1
        elif p[i] == '?': out += '[^/]'; i += 1
        else: out += re.escape(p[i]); i += 1
    return re.compile('^' + out + '$')
rx = [g2re(p) for p in pats]
if not pats: print("  ✗ no push.paths parsed from", wf, file=sys.stderr); sys.exit(1)
aliases = sorted(os.path.basename(d)[len('nixhm-sudo-'):] for d in glob.glob(root + '/b_infra/nixhm-sudo-*') if os.path.isdir(d))
src_re = re.compile(r'((?:config\.json)|(?:b_infra/[A-Za-z0-9_<>.\-/]+?\.json))')
fail = checked = 0
for f in sorted(glob.glob(mods + '/**/*.nix', recursive=True)):
    txt = open(f).read()
    if '_cloud-data-consolidated.json' not in txt: continue
    rel = os.path.relpath(f, root)
    for decl in sorted(set(src_re.findall(txt))):
        if '_cloud-data-consolidated' in decl: continue
        insts = [decl.replace('nixhm-sudo-<alias>', 'nixhm-sudo-' + a).replace('nixhm-sudo-<vm>', 'nixhm-sudo-' + a) for a in aliases] if '<' in decl else [decl]
        insts = sorted(set(i for i in insts if '<' not in i))
        for inst in insts:
            checked += 1
            if not any(r.match(inst) for r in rx):
                fail += 1
                print(f"  ✗ {rel} documents '{decl}' as a source; '{inst}' matches NO ship-gen-configs push.paths pattern — edits to it are inert", file=sys.stderr)
print(f"  {checked} documented-source instances checked against {len(pats)} patterns, {fail} orphaned")
sys.exit(1 if fail else 0)
PY
