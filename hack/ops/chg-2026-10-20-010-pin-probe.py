"""chg-2026-10-20-010 pinned-runtime probe (Argus C3, 25-10): runs INSIDE the hermes-profiel-3 app container.

    kubectl exec <p3> -c app -- env PYTHONDONTWRITEBYTECODE=1 /opt/hermes/.venv/bin/python \
        -c "$(cat hack/ops/chg-2026-10-20-010-pin-probe.py)" [<plugin __init__.py>] [<hermes root>]

The 25-10 11:46Z go went RED because the probe imported a hard-coded module set while the v0.22.5 port added
gateway.run_turn_runner to PINNED_MODULES. This probe reads PINNED_MODULES from the plugin source itself (ast,
literal only, before any plugin code runs), imports exactly those modules, refuses with a reason if one cannot
be imported or is not loaded, then loads the plugin, refuses unless the loaded PINNED_MODULES equals that literal
(Argus K2), and asks runtime_pinned(). It also reports the go-time
readback fields (pins, HERMES_INSTALL_ROOT / HERMES_PLUGIN_HOST_PROCESS unset, HERMES_IMAGE == PINNED_IMAGE).
Prints one JSON line (module names, counts, booleans, reason; never file content). Exit 0 only when all hold.
Test-only: C010_PROBE_SKIP=<module> leaves that module out of the import loop (it can only make the probe fail).
"""
import ast, hashlib, importlib, importlib.util, json, os, sys

args = [a for a in sys.argv[1:] if a != "-c"]
plugin = args[0] if len(args) > 0 else "/opt/data/plugins/model-providers/family-cloud/__init__.py"
root = args[1] if len(args) > 1 else "/opt/hermes"
out = {"ok": False, "reason": None}


def done(reason=None):
    out["reason"] = reason
    print(json.dumps(out, sort_keys=True))
    sys.exit(0 if out["ok"] else 1)


try:
    tree = ast.parse(open(plugin).read())
except Exception as e:
    done("cannot read plugin %s (%s)" % (plugin, type(e).__name__))
names = None
for node in tree.body:
    if isinstance(node, ast.Assign) and any(getattr(t, "id", None) == "PINNED_MODULES" for t in node.targets):
        try:
            names = ast.literal_eval(node.value)
        except Exception:
            names = None
if not isinstance(names, dict) or not names or not all(isinstance(k, str) for k in names):
    done("plugin has no literal PINNED_MODULES dict")
out["modules"] = sorted(names)
os.chdir(root)
sys.path.insert(0, root)
skip = os.environ.get("C010_PROBE_SKIP", "")
for m in sorted(names):
    if m == skip:
        continue
    try:
        importlib.import_module(m)
    except Exception as e:
        done("cannot import pinned module %s (%s)" % (m, type(e).__name__))
missing = [m for m in sorted(names) if m not in sys.modules]
if missing:
    done("pinned modules not loaded in the probe: %s" % ", ".join(missing))
out["imported"] = len(names)
try:
    spec = importlib.util.spec_from_file_location("c010_pin_probe_plugin", plugin)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
except Exception as e:
    done("plugin failed to load (%s)" % type(e).__name__)
# Argus K2: the loaded plugin must hold exactly the module list the probe imported (no later mutation / rebinding)
if getattr(mod, "PINNED_MODULES", None) != names:
    done("plugin PINNED_MODULES after load differs from its source literal")
sources = getattr(mod, "PINNED_SOURCES", {}) or {}
pins_ok = 0
for rel, digest in sources.items():
    try:
        pins_ok += hashlib.sha256(open(os.path.join(root, rel), "rb").read()).hexdigest() == digest
    except Exception:
        pass
out.update({
    "runtime_pinned": mod.runtime_pinned() is True,
    "pins_ok": pins_ok, "pins_total": len(sources),
    "install_root_unset": "HERMES_INSTALL_ROOT" not in os.environ,
    "plugin_host_unset": os.environ.get("HERMES_PLUGIN_HOST_PROCESS") != "1" and "HERMES_PLUGIN_HOST_PROCESS" not in os.environ,
    "image_env_is_pin": os.environ.get("HERMES_IMAGE") == getattr(mod, "PINNED_IMAGE", None),
})
bad = [k for k in ("runtime_pinned", "install_root_unset", "plugin_host_unset", "image_env_is_pin") if not out[k]]
if pins_ok != len(sources) or not sources:
    bad.append("pins %d/%d" % (pins_ok, len(sources)))
out["ok"] = not bad
done(None if out["ok"] else "not pinned: " + ", ".join(bad))
