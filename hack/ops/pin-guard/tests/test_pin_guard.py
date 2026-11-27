#!/usr/bin/env python3
"""Tests for cluster-wires-pin-guard.py (chg-2026-11-13-002 P3).

Run: python3 hack/ops/pin-guard/tests/test_pin_guard.py   (needs PyYAML)
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

HERE = pathlib.Path(__file__).resolve().parent
GUARD = pathlib.Path(os.environ.get("PIN_GUARD_PATH", HERE.parent / "cluster-wires-pin-guard.py"))
REPO_ROOT = pathlib.Path(os.environ.get("PIN_GUARD_REPO_ROOT", HERE.parents[3]))
spec = importlib.util.spec_from_file_location("pin_guard", GUARD)
pg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pg)

SHA = "73c860ad758651c29efd63eb69a8dbbdb9654667"
URL = "ssh://git@forgejo-ssh.devtools.svc.cluster.local:22/VDHICT/cluster-wires.git"


def check_repo(root, render=None):
    """check_repo with the render hook; falls back to the pre-wq-140 signature so the G tests can be run against
    the old guard (PIN_GUARD_PATH=...) to show they are red without the fix."""
    try:
        return pg.check_repo(root, render=render)
    except TypeError:
        return pg.check_repo(root)


def gitrepo(name="cluster-wires", url=URL, ref=None):
    ref = {"branch": "runner/x", "commit": SHA} if ref is None else ref
    ref_yaml = "".join(f"\n    {k}: {v}" for k, v in ref.items()) or " {}"
    return textwrap.dedent(f"""\
        ---
        # comment naming {URL} is fine
        apiVersion: source.toolkit.fluxcd.io/v1
        kind: GitRepository
        metadata:
          name: {name}
        spec:
          interval: 30m
          url: {url}
          ref:""") + ref_yaml + "\n"


class RepoMode(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        self.write(pg.PRIMARY, gitrepo())

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, rel, text):
        p = self.root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)

    def red(self):
        return check_repo(self.root)

    def test_pinned_is_green(self):
        self.assertEqual(self.red(), [])

    def test_commit_removed_is_red(self):
        self.write(pg.PRIMARY, gitrepo(ref={"branch": "main"}))
        self.assertTrue(any(r.startswith("R1") for r in self.red()))
        self.assertTrue(any(r.startswith("R2") for r in self.red()))

    def test_short_commit_is_red(self):
        self.write(pg.PRIMARY, gitrepo(ref={"branch": "main", "commit": SHA[:12]}))
        self.assertTrue(any(r.startswith("R1") for r in self.red()))

    def test_empty_ref_is_red(self):
        self.write(pg.PRIMARY, gitrepo(ref={}))
        self.assertTrue(any(r.startswith("R1") for r in self.red()))

    def test_primary_missing_is_red(self):
        (self.root / pg.PRIMARY).rename(self.root / "moved.yaml")
        self.assertIn(f"R1 {pg.PRIMARY}: file missing", self.red())

    def test_primary_renamed_object_is_red(self):
        self.write(pg.PRIMARY, gitrepo(name="other"))
        self.assertTrue(any("no GitRepository named cluster-wires" in r for r in self.red()))

    def test_primary_url_elsewhere_is_red(self):
        self.write(pg.PRIMARY, gitrepo(url="ssh://git@example.invalid/x/other.git"))
        self.assertTrue(any("does not point at cluster-wires" in r for r in self.red()))

    def test_second_consumer_on_branch_is_red(self):
        self.write("kubernetes/main/apps/other/src.yaml", gitrepo(name="wires-head", ref={"branch": "main"}))
        self.assertTrue(any(r.startswith("R2 kubernetes/main/apps/other/src.yaml") for r in self.red()))

    def test_second_consumer_pinned_is_green(self):
        self.write("kubernetes/main/apps/other/src.yaml", gitrepo(name="wires-2"))
        self.assertEqual(self.red(), [])

    def test_https_consumer_on_tag_is_red(self):
        self.write("kubernetes/main/apps/other/src.yaml",
                   gitrepo(name="w", url="https://forge.example.invalid/VDHICT/cluster-wires", ref={"tag": "v1"}))
        self.assertTrue(any(r.startswith("R2") for r in self.red()))

    def test_unrelated_branch_gitrepo_is_green(self):
        self.write("kubernetes/main/apps/other/src.yaml",
                   gitrepo(name="flux-system", url="ssh://git@github.com/x/vdhinfra", ref={"branch": "main"}))
        self.assertEqual(self.red(), [])

    def test_oci_source_is_red(self):
        self.write("kubernetes/main/apps/other/oci.yaml", textwrap.dedent("""\
            apiVersion: source.toolkit.fluxcd.io/v1
            kind: OCIRepository
            metadata: {name: w}
            spec: {url: oci://registry.example.invalid/cluster-wires, ref: {tag: latest}}
            """))
        self.assertTrue(any(r.startswith("R3") for r in self.red()))

    def test_git_clone_in_job_is_red(self):
        self.write("kubernetes/main/apps/other/job.yaml", textwrap.dedent(f"""\
            apiVersion: batch/v1
            kind: Job
            metadata: {{name: pull}}
            spec:
              template:
                spec:
                  containers:
                    - name: c
                      image: alpine
                      command: ["sh", "-c", "git clone {URL} /w && kubectl apply -f /w/deploy"]
            """))
        self.assertTrue(any(r.startswith("R4 kubernetes/main/apps/other/job.yaml:10") for r in self.red()))

    def test_comment_url_is_green(self):
        self.write("kubernetes/main/apps/other/notes.yaml", f"# see {URL}\nkind: ConfigMap\nmetadata: {{name: n}}\n")
        self.assertEqual(self.red(), [])

    def test_unparseable_mention_fails_closed(self):
        self.write("kubernetes/main/apps/other/bad.yaml", "kind: GitRepository\nspec: {url: cluster-wires\n  : [\n")
        self.assertTrue(any(r.startswith("R0") for r in self.red()))

    def test_unparseable_without_mention_is_ignored(self):
        self.write("kubernetes/main/apps/other/tpl.yaml", "a: {{ .Values.x }\n  : [\n")
        self.assertEqual(self.red(), [])

    def test_flux_substitution_and_sops_parse(self):
        self.write("kubernetes/main/apps/other/s.sops.yaml",
                   "kind: Secret\nmetadata: {name: cluster-wires-pull}\nstringData:\n  t: ENC[AES256_GCM,data:x,type:str]\n"
                   "sops: {age: [{recipient: age1x}]}\n")
        self.write("kubernetes/main/apps/other/v.yaml", "kind: ConfigMap\ndata: {h: '${SECRET_DOMAIN}', w: cluster-wires}\n")
        self.assertEqual(self.red(), [])

    def test_main_exit_codes(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            self.assertEqual(pg.main(["--root", str(self.root), "--no-render"]), 0)
            self.write(pg.PRIMARY, gitrepo(ref={"branch": "main"}))
            self.assertEqual(pg.main(["--root", str(self.root), "--no-render"]), 1)
        self.assertIn("PIN-GUARD GREEN (repo)", buf.getvalue())
        self.assertIn("PIN-GUARD RED (repo)", buf.getvalue())


class LiveMode(unittest.TestCase):
    def item(self, commit=SHA, rev=None, url=URL):
        ref = {"branch": "runner/x"}
        if commit is not None:
            ref["commit"] = commit
        return {"metadata": {"namespace": "flux-system", "name": "cluster-wires"},
                "spec": {"url": url, "ref": ref},
                "status": {"artifact": {"revision": rev if rev is not None else f"runner/x@sha1:{SHA}"}}}

    def test_pinned_and_serving_is_green(self):
        self.assertEqual(pg.check_live({"items": [self.item()]}), [])

    def test_no_wires_object_is_red(self):
        self.assertTrue(pg.check_live({"items": []})[0].startswith("V1"))

    def test_unpinned_is_red(self):
        self.assertTrue(pg.check_live({"items": [self.item(commit=None)]})[0].startswith("V2"))

    def test_artifact_off_pin_is_red(self):
        red = pg.check_live({"items": [self.item(rev="main@sha1:" + "0" * 40)]})
        self.assertTrue(red[0].startswith("V3"))

    def test_live_json_exit_code(self):
        with tempfile.TemporaryDirectory() as d:
            p = pathlib.Path(d) / "live.json"
            p.write_text(json.dumps({"items": [self.item(commit=None)]}))
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(pg.main(["--live-json", str(p)]), 1)
            p.write_text("not json")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(pg.main(["--live-json", str(p)]), 2)


class Hardening(unittest.TestCase):
    """wq-140: Argus wq-103 C3 findings G1-G6 plus the cluster-wires-exchange false positive. Each test is red
    against the pre-wq-140 guard (run with PIN_GUARD_PATH=<old guard>)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        self.write(pg.PRIMARY, gitrepo())

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, rel, text):
        p = self.root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)

    def red(self, render=None):
        return check_repo(self.root, render=render)

    def has(self, prefix):
        return any(r.startswith(prefix) for r in self.red())

    # G1: a kustomize patch removing ref.commit (Argus probe B3), and the Flux Kustomization .spec.patches variant.
    def test_g1_kustomize_json6902_remove_commit_is_red(self):
        self.write(pg.PRIMARY_DIR + "/kustomization.yaml", textwrap.dedent("""\
            apiVersion: kustomize.config.k8s.io/v1beta1
            kind: Kustomization
            resources: [gitrepository.yaml]
            patches:
              - target: {kind: GitRepository, name: cluster-wires}
                patch: |-
                  - op: remove
                    path: /spec/ref/commit
            """))
        self.assertTrue(self.has("R5"), self.red())

    def test_g1_flux_kustomization_patch_is_red(self):
        self.write("kubernetes/main/apps/mypka/wires/install.yaml", textwrap.dedent("""\
            apiVersion: kustomize.toolkit.fluxcd.io/v1
            kind: Kustomization
            metadata: {name: wires-source, namespace: flux-system}
            spec:
              path: ./kubernetes/main/apps/mypka/wires/source
              patches:
                - target: {kind: GitRepository}
                  patch: '[{"op": "replace", "path": "/spec/ref", "value": {"branch": "main"}}]'
            """))
        self.assertTrue(self.has("R5"), self.red())

    def test_g1_kindless_ref_patch_is_red(self):
        self.write("kubernetes/main/apps/other/kustomization.yaml", textwrap.dedent("""\
            kind: Kustomization
            patches:
              - target: {name: cluster-wires}
                patch: '[{"op": "remove", "path": "/spec/ref/commit"}]'
            """))
        self.assertTrue(self.has("R5"), self.red())

    def test_g1_strategic_merge_patch_file_is_red(self):
        self.write("kubernetes/main/apps/other/kustomization.yaml",
                   "kind: Kustomization\npatchesStrategicMerge: [drop-pin.yaml]\n")
        self.write("kubernetes/main/apps/other/drop-pin.yaml", textwrap.dedent("""\
            apiVersion: source.toolkit.fluxcd.io/v1
            kind: GitRepository
            metadata: {name: cluster-wires}
            spec: {ref: {commit: null, branch: main}}
            """))
        self.assertTrue(self.has("R5"), self.red())

    def test_g1_unrelated_patch_is_green(self):
        self.write("kubernetes/main/apps/other/kustomization.yaml", textwrap.dedent("""\
            kind: Kustomization
            patches:
              - target: {kind: HelmRelease}
                patch: '[{"op": "replace", "path": "/spec/chartRef/name", "value": "x"}]'
            """))
        self.assertEqual(self.red(), [])

    def test_g1_rendered_output_without_commit_is_red(self):
        rendered = gitrepo(ref={"branch": "main"})
        red = self.red(render=lambda d: rendered)
        self.assertTrue(any(r.startswith("R6") for r in red), red)

    def test_g1_renderer_missing_fails_closed(self):
        def boom(d):
            raise RuntimeError("no kustomize")
        self.write(pg.PRIMARY_DIR + "/kustomization.yaml", "kind: Kustomization\nresources: [gitrepository.yaml]\n")
        red = self.red(render=boom)
        self.assertTrue(any(r.startswith("R6") and "fail closed" in r for r in red), red)

    @unittest.skipUnless(shutil.which("kustomize") or shutil.which("kubectl"), "no kustomize/kubectl")
    def test_g1_real_render_of_pinned_source_is_green(self):
        self.write(pg.PRIMARY_DIR + "/kustomization.yaml", "kind: Kustomization\nresources: [gitrepository.yaml]\n")
        self.assertEqual(pg.check_repo(self.root), [])

    # G2: URL case variant (Argus probe B1), repo mode and live mode.
    def test_g2_case_variant_url_is_red_repo(self):
        self.write("kubernetes/main/apps/other/src.yaml",
                   gitrepo(name="w", url=URL.replace("cluster-wires", "Cluster-Wires"), ref={"branch": "main"}))
        self.assertTrue(self.has("R2"), self.red())

    def test_g2_case_variant_url_is_red_live(self):
        item = {"metadata": {"namespace": "x", "name": "w"},
                "spec": {"url": URL.upper().replace("SSH://GIT@", "ssh://git@"), "ref": {"branch": "main"}},
                "status": {"artifact": {"revision": "main@sha1:" + SHA}}}
        pinned = {"metadata": {"namespace": "flux-system", "name": "cluster-wires"},
                  "spec": {"url": URL, "ref": {"branch": "runner/x", "commit": SHA}},
                  "status": {"artifact": {"revision": f"runner/x@sha1:{SHA}"}}}
        red = pg.check_live({"items": [pinned, item]})
        self.assertTrue(any(r.startswith("V2") for r in red), red)

    # G3: YAML escape in a double-quoted url (Argus probe B2) and percent-encoding.
    def test_g3_yaml_x2d_escape_is_red(self):
        # Argus probe B2: no literal "cluster-wires" anywhere in the file, only the YAML escape in the url.
        self.write("kubernetes/main/apps/other/src.yaml", textwrap.dedent("""\
            apiVersion: source.toolkit.fluxcd.io/v1
            kind: GitRepository
            metadata: {name: w}
            spec:
              url: "ssh://git@forgejo-ssh.devtools.svc.cluster.local:22/VDHICT/cluster\\x2dwires.git"
              ref: {branch: main}
            """))
        self.assertNotIn("cluster-wires", (self.root / "kubernetes/main/apps/other/src.yaml").read_text())
        self.assertTrue(self.has("R2"), self.red())

    def test_g3_percent_encoded_is_red(self):
        self.write("kubernetes/main/apps/other/src.yaml", gitrepo(
            name="w", url="https://forge.example.invalid/VDHICT/cluster%2Dwires.git", ref={"branch": "main"}))
        self.assertTrue(self.has("R2"), self.red())

    # G4: non-yaml files (Argus probes B6/B7).
    def test_g4_shell_script_clone_is_red(self):
        self.write("kubernetes/main/apps/other/files/pull.sh", f"#!/bin/sh\ngit clone {URL} /w\n")
        self.assertTrue(self.has("R4 kubernetes/main/apps/other/files/pull.sh:2"), self.red())

    def test_g4_json_manifest_on_branch_is_red(self):
        doc = {"apiVersion": "source.toolkit.fluxcd.io/v1", "kind": "GitRepository", "metadata": {"name": "w"},
               "spec": {"url": URL, "ref": {"branch": "main"}}}
        self.write("kubernetes/main/apps/other/src.json", json.dumps(doc))
        self.assertTrue(self.has("R2 kubernetes/main/apps/other/src.json"), self.red())

    def test_g4_scp_url_in_python_is_red(self):
        self.write("kubernetes/main/apps/other/code/sync.py",
                   'REMOTE = "git@forge-ssh.example.invalid:VDHICT/cluster-wires.git"\n')
        self.assertTrue(self.has("R4"), self.red())

    # Exact repository match: VDHICT/cluster-wires-exchange is another repo (main went red on 85065429 for this).
    def test_exchange_repo_is_not_cluster_wires(self):
        self.write("kubernetes/main/apps/ha-zones/cronjob.yaml", textwrap.dedent("""\
            apiVersion: batch/v1
            kind: CronJob
            metadata: {name: z}
            spec:
              jobTemplate:
                spec:
                  template:
                    spec:
                      containers:
                        - name: c
                          env:
                            - {name: EXCHANGE_URL, value: "ssh://git@forgejo-ssh.devtools.svc.cluster.local:22/VDHICT/cluster-wires-exchange.git"}
            """))
        self.assertEqual(self.red(), [])

    # G5: live mode must run where PyYAML is absent (the daily posture scan image), so it can be scheduled there.
    def test_g5_live_mode_runs_without_pyyaml(self):
        with tempfile.TemporaryDirectory() as d:
            p = pathlib.Path(d) / "live.json"
            p.write_text(json.dumps({"items": [{"metadata": {"namespace": "flux-system", "name": "cluster-wires"},
                                                "spec": {"url": URL, "ref": {"commit": SHA}},
                                                "status": {"artifact": {"revision": f"x@sha1:{SHA}"}}}]}))
            r = subprocess.run([sys.executable, "-I", "-S", str(GUARD), "--live-json", str(p)],
                               capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_g5_ci_schedule_and_scan_wiring(self):
        wf = (REPO_ROOT / ".github/workflows/cluster-wires-pin-guard.yml").read_text()
        self.assertIn("schedule:", wf)
        scan = (REPO_ROOT / "kubernetes/main/apps/observability/cluster-health/app/scripts/ops_security_scan.py")
        self.assertIn("cluster-wires-pin-guard.py", scan.read_text())
        self.assertIn('"--live"', scan.read_text())

    # G6: a red result must reach an alert that names the L7 revoke.
    def test_g6_red_output_names_revoke_runbook(self):
        self.write(pg.PRIMARY, gitrepo(ref={"branch": "main"}))
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            pg.main(["--root", str(self.root)])
        self.assertIn("docs/runbooks/forge-deploy-key-revoke.md", buf.getvalue())
        self.assertTrue((REPO_ROOT / "docs/runbooks/forge-deploy-key-revoke.md").is_file())

    def test_g6_ci_failure_opens_alert(self):
        wf = (REPO_ROOT / ".github/workflows/cluster-wires-pin-guard.yml").read_text()
        self.assertIn("failure()", wf)
        self.assertIn("forge-deploy-key-revoke.md", wf)
        self.assertIn("issues: write", wf)


class RealRepo(unittest.TestCase):
    def test_this_checkout_is_green(self):
        self.assertEqual(pg.check_repo(REPO_ROOT), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
