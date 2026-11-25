#!/usr/bin/env python3
"""Tests for cluster-wires-pin-guard.py (chg-2026-11-13-002 P3).

Run: python3 hack/ops/pin-guard/tests/test_pin_guard.py   (needs PyYAML)
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import pathlib
import tempfile
import textwrap
import unittest

HERE = pathlib.Path(__file__).resolve().parent
GUARD = HERE.parent / "cluster-wires-pin-guard.py"
REPO_ROOT = HERE.parents[3]
spec = importlib.util.spec_from_file_location("pin_guard", GUARD)
pg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pg)

SHA = "73c860ad758651c29efd63eb69a8dbbdb9654667"
URL = "ssh://git@forgejo-ssh.devtools.svc.cluster.local:22/VDHICT/cluster-wires.git"


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
        return pg.check_repo(self.root)

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
            self.assertEqual(pg.main(["--root", str(self.root)]), 0)
            self.write(pg.PRIMARY, gitrepo(ref={"branch": "main"}))
            self.assertEqual(pg.main(["--root", str(self.root)]), 1)
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


class RealRepo(unittest.TestCase):
    def test_this_checkout_is_green(self):
        self.assertEqual(pg.check_repo(REPO_ROOT), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
