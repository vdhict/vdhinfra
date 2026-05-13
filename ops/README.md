# ops/ — Infrastructure operations state

Event-sourced ITSM state for the homelab. Append-only files; the `./ops` CLI reads them to project current state.

## Files

| File | Schema | Purpose |
|---|---|---|
| `changes.jsonl` | one event per line (see below) | Every planned / executed / closed change |
| `incidents.jsonl` | one event per line | Every incident: open → investigate → resolve → postmortem |
| `cmdb.yaml` | static doc | Component inventory: every "thing" in the infra and its owner-agent |
| `freeze.yaml` | static doc | Active change-freeze windows; the OPS Manager refuses high-risk changes within them |
| `locks/<resource>` | empty file | Held lock on `<resource>` while a change is in flight. Filename is the resource id; file body is `actor pid`/timestamp |

## Change event schema

Append a JSON object per line to `changes.jsonl`:

```json
{
  "chg": "chg-2026-05-13-001",
  "ts": "2026-05-13T07:00:00Z",
  "event": "requested" | "planned" | "qa_passed" | "qa_failed" | "approved" | "rejected" | "executed" | "validated" | "rolled_back" | "closed",
  "actor": "infra-ops" | "ha-engineer" | "udm-engineer" | "k8s-engineer" | "change-qa" | "user",
  "resource": "<cmdb id, e.g. ha.config.automations>",
  "risk": "low" | "medium" | "high",
  "payload": { ... event-specific data ... }
}
```

`chg` IDs are stable across a change's lifetime; events accumulate. The CLI folds them into current state.

### Event payloads

- **requested**: `{ "summary": "...", "reason": "...", "requested_by": "user" }`
- **planned**: `{ "summary": "...", "diff_url": "...", "files": ["..."], "rollback": "...", "validation_plan": "..." }`
- **qa_passed**: `{ "checks": ["yaml_lint", "kubeconform", "ha_config_check"], "notes": "..." }`
- **qa_failed**: `{ "checks_failed": [{"name":"...","reason":"..."}], "remediation_advice": "..." }`
- **approved**: `{ "approved_by": "user", "scope": "this_change_only" }`
- **rejected**: `{ "rejected_by": "user", "reason": "..." }`
- **executed**: `{ "commits": ["sha", ...], "external_actions": ["..."], "duration_ms": 1234 }`
- **validated**: `{ "checks": [...], "status": "pass", "evidence": "..." }`
- **rolled_back**: `{ "reason": "...", "commits_reverted": [...] }`
- **closed**: `{ "outcome": "success" | "failure" | "abandoned" }`

## Incident event schema

```json
{
  "inc": "inc-2026-05-13-001",
  "ts": "2026-05-13T08:00:00Z",
  "event": "opened" | "investigated" | "mitigated" | "resolved" | "postmortem" | "closed",
  "actor": "infra-ops" | "<engineer>" | "user",
  "severity": "sev1" | "sev2" | "sev3",
  "payload": { ... }
}
```

### Severity

- **sev1** — outage affecting the whole household (no internet, no HA, electricity automations broken). Page everyone.
- **sev2** — single critical service degraded (HA dashboard unreachable, cameras offline).
- **sev3** — annoying but workaround available (one entity unavailable, retry loop).

## CMDB schema

`cmdb.yaml` is a flat map of component ids → metadata:

```yaml
components:
  ha.config.automations:
    type: ha-config-file
    owner_agent: ha-engineer
    description: HA automations.yaml in PVC
    depends_on: [ha.pod]
    runbook: docs/runbooks/disaster-recovery.md
```

## Lock discipline

Before any write action on a resource, an engineer agent must:

```sh
./ops lock acquire <resource-id> --by <agent> --reason "<chg-id>"
# ... do the write ...
./ops lock release <resource-id>
```

Acquiring a held lock fails fast; the agent should report back to the OPS Manager which queues or aborts.

## Freeze windows

`freeze.yaml`:

```yaml
freezes:
  - name: christmas_holiday_freeze
    starts: 2026-12-23T00:00:00Z
    ends: 2027-01-02T00:00:00Z
    blocks: [medium, high]   # what risk tiers are blocked
    reason: family at home, no breakage tolerated
```

The OPS Manager refuses any change in `blocks` tiers during an active freeze. Low-risk changes still flow.
