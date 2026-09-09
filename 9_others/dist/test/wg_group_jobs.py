#!/usr/bin/env python3

# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : 9_others/src/../test/wg_group_jobs.py
# ║   Engine : 1_cicd/src/scripts/cloud-ship-repo-workflow-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

"""Resolve every job that ends up inside a GitHub Actions concurrency group.

Grepping for the group name finds declarations, not jobs, and the two differ in
the way that caused the 2026-09-09 outage: cgc-db.yml declared the group ONCE at
workflow level, which silently enrolled every job of the reusable workflow it
calls -- including an index matrix under a 330-minute ceiling that never touches
the mesh the group exists to serialise.

So resolution follows the same rules GitHub does:
  * a workflow-level `concurrency` puts EVERY job of the run in the group,
    and a run includes the jobs of any reusable workflow it calls, so
    `uses: ./.github/workflows/X` is followed into X;
  * otherwise only the jobs carrying their own job-level `concurrency` are in.

Emits one line per job: "<workflow> <job> <timeout-or-none>". A job with no
timeout-minutes reports "none" rather than being skipped -- GitHub's default is
360 minutes, which is worse than any ceiling a caller would test for, so a
missing declaration must never read as compliant.

Usage: wg_group_jobs.py <workflows-dir> <group-name>
"""
import os
import sys

import yaml


def group_of(node):
    """The concurrency group of a workflow or job, however it is written.

    `concurrency` accepts either a bare string or a mapping with `group`.
    """
    c = (node or {}).get("concurrency")
    if isinstance(c, str):
        return c
    if isinstance(c, dict):
        return c.get("group")
    return None


def local_callee(job):
    """The reusable workflow this job calls, if it is a local one."""
    uses = job.get("uses")
    if isinstance(uses, str) and uses.startswith("./.github/workflows/"):
        return os.path.basename(uses)
    return None


def main():
    wf_dir, group = sys.argv[1], sys.argv[2]

    docs = {}
    for name in sorted(os.listdir(wf_dir)):
        if not name.endswith((".yml", ".yaml")):
            continue
        with open(os.path.join(wf_dir, name)) as fh:
            doc = yaml.safe_load(fh)
        if isinstance(doc, dict):
            docs[name] = doc

    out = []

    def emit(origin, wf_name, seen):
        """Every job of wf_name, transitively through local reusable calls."""
        if wf_name in seen or wf_name not in docs:
            return
        seen = seen | {wf_name}
        for job_name, job in (docs[wf_name].get("jobs") or {}).items():
            job = job or {}
            callee = local_callee(job)
            if callee:
                emit(origin, callee, seen)
                continue
            out.append((origin, job_name, job.get("timeout-minutes", "none")))

    for name, doc in docs.items():
        if group_of(doc) == group:
            # Workflow-level: the whole run is in the group.
            emit(name, name, set())
            continue
        for job_name, job in (doc.get("jobs") or {}).items():
            job = job or {}
            if group_of(job) != group:
                continue
            callee = local_callee(job)
            if callee:
                # A `uses:` job holding the group enrols the callee's jobs.
                emit(name, callee, set())
            else:
                out.append((name, job_name, job.get("timeout-minutes", "none")))

    for origin, job_name, timeout in out:
        print(f"{origin} {job_name} {timeout}")


if __name__ == "__main__":
    main()
