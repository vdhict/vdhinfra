---
description: Query, control, and inspect Home Assistant via the slim ha-cli.sh helper. Use this for any HA-related task instead of inventing curl pipelines.
---

# /hacontrol — Home Assistant operator

You are operating a live Home Assistant instance. Use the **`ha-cli.sh`** wrapper at `~/Code/homelab-migration/ha-cli.sh` for all reads and writes — it returns one line per fact, no JSON pretty-printing, so it costs ~10× fewer tokens than raw `curl … | jq .` patterns.

## When to use which subcommand

| Goal | Command |
|---|---|
| Single entity state | `ha-cli.sh state <entity_id>` |
| Search entities by regex (case-insensitive) | `ha-cli.sh states <regex>` — **online**, hits live API |
| Same search but **without** an API call | `ha-cli.sh find <regex>` — greps `.claude/ha-entities.json` |
| One attribute (or all) | `ha-cli.sh attr <entity_id> [attr_name]` |
| Last-N-hours summary | `ha-cli.sh history <entity_id> [hours=24]` — count + first/last/uniques only |
| Recent logbook events | `ha-cli.sh logbook <entity_id> [hours=12]` |
| Weather forecast aggregate | `ha-cli.sh forecast <weather.entity> [hours=12]` — rain sum + temp range |
| Call any service | `ha-cli.sh call <domain.service> '<json_body>'` |
| Turn on/off / trigger | `ha-cli.sh on <e>` / `ha-cli.sh off <e>` / `ha-cli.sh trigger automation.<id>` |
| Last automation run | `ha-cli.sh trace <automation_numeric_id>` |
| Persistent notifications | `ha-cli.sh persistent` |
| Arbitrary WS command | `ha-cli.sh ws <type> '<json>'` (auto-tunnels through HA pod) |
| Refresh entity catalog | `ha-cli.sh catalog` (only when user says devices were added) |

## Canonical patterns — prefer these

```bash
# Discovery (NO API call — uses local catalog)
ha-cli.sh find "soil|moisture|valve"

# Multiple specific entities — one call, multiple lines
ha-cli.sh states "^(switch\.diivoo|sensor\.0xa4c1)"

# Service call with proper JSON quoting
ha-cli.sh call switch.turn_on '{"entity_id":"switch.diivoo_smart_dual_water_timer_switch_1"}'

# Forecast aggregate (don't dump 48 hourly samples)
ha-cli.sh forecast weather.forecast_thuis 12
```

## Anti-patterns — DO NOT do these

- ❌ `curl /api/states/<id> | jq .` — dumps 25+ lines of full JSON. Use `ha-cli.sh state` (1 line).
- ❌ Loop of N curls for N entities. Use `ha-cli.sh states <regex>` (1 call, N lines).
- ❌ `kubectl logs --since=10m` without `grep -E` for specific keywords first.
- ❌ Dumping `forecast_data['weather.X'].forecast` raw (often 48 entries × 12 fields). Aggregate with `forecast` subcommand or jq sum.
- ❌ `jq .` on trace/config-entry results. Print only `state`, `last_step`, `error`, or specific fields.
- ❌ Refreshing the catalog "just in case." Only run `ha-cli.sh catalog` when the user explicitly mentions adding/removing devices.

## Network notes

- Direct LAN IP `172.16.2.237:8123` — REST works from this dev box; WebSocket usually fails ("No route to host").
- The `ws` and `persistent` and `trace` subcommands automatically tunnel through the HA pod via `kubectl exec`. No action needed from you.
- Token at `~/Code/homelab-migration/config/hasskey`. Never `gh auth login` style flows.

## Sensitive operations

- Opening valves, locks, doors, or anything with real-world side effects → confirm with user before invoking unless they pre-authorized this turn.
- Restarting HA core (`homeassistant.restart`) → confirm first; takes ~60s, breaks all websocket consumers.
- Deleting a config entry, automation, or HACS repo → list what will be affected first, then confirm.

## After editing HA config files

When you change anything under `/config` in the HA pod — `automations.yaml`, `scripts.yaml`, `scenes.yaml`, `configuration.yaml`, `secrets.yaml`, any package under `/config/packages/`, dashboards under `/config/.storage/lovelace.*`, or template/sensor YAML — you **must** finish by reloading or restarting HA so the change actually takes effect. `automation.reload` updates the entity but the user has reported cases where it leaves state inconsistent; the safe default is a full restart.

Default sequence (use this unless the user has pre-authorised a lighter reload):

```bash
~/Code/homelab-migration/ha-cli.sh call homeassistant.restart '{}'
# poll until back up
for i in $(seq 1 30); do
  st=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 3 http://172.16.2.237:8123/api/ 2>&1)
  [ "$st" = "200" ] || [ "$st" = "401" ] && { echo "back after ${i} tries"; break; }
  sleep 3
done
```

Then re-verify the entities you changed actually loaded after restart (e.g. `ha-cli.sh state automation.<new_id>`) — don't assume.

Lighter alternatives, only when the user explicitly opts in:
- `automation.reload` — for `automations.yaml` edits, no downtime, but state may lag.
- `script.reload` / `scene.reload` / `template.reload` — same caveat, only the named domain.
- Lovelace `.storage/lovelace.*` edits — picked up on next page load, no reload needed.
- Hue v2 API edits (powerup, scenes) — go directly to the bridge, independent of HA, no restart needed.
