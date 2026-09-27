"""family-ai searxng settings render (chg-2026-09-26-001, land-12g).

Init container. Copies the ConfigMap settings (/opt/family-ai-tmpl/settings.yml)
to /etc/searxng/settings.yml (memory-only emptyDir) and fills the braveapi
engine's api_key from env BRAVE_SEARCH_API_KEY (Secret family-ai-searxng-brave,
optional). No key, or an implausible one -> braveapi is rendered inactive, so
bing + wikipedia keep working. The key is never printed.
"""
import os
import re
import sys

import yaml

SRC, DST = "/opt/family-ai-tmpl/settings.yml", "/etc/searxng/settings.yml"
PLACEHOLDER = "@@BRAVE_SEARCH_API_KEY@@"

with open(SRC, encoding="utf-8") as f:
    cfg = yaml.safe_load(f)

key = os.environ.get("BRAVE_SEARCH_API_KEY", "").strip()
ok = bool(re.fullmatch(r"[A-Za-z0-9_-]{20,64}", key))
found = 0
for eng in cfg.get("engines", []):
    if eng.get("name") == "braveapi":
        found += 1
        if eng.get("api_key") != PLACEHOLDER:
            sys.exit("searxng-render: braveapi api_key is not the placeholder - refusing")
        eng["api_key"] = key if ok else ""
        eng["inactive"] = not ok
if found != 1:
    sys.exit(f"searxng-render: expected 1 braveapi engine, found {found}")

fd = os.open(DST, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o400)
with os.fdopen(fd, "w", encoding="utf-8") as f:
    yaml.safe_dump(cfg, f, sort_keys=False, allow_unicode=True)
print("searxng-render: braveapi " + ("enabled" if ok else "INACTIVE (no or implausible key)"))
