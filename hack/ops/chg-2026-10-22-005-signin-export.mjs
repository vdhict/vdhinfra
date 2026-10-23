// chg-2026-10-22-005 (Larry 22-10, tsk-2026-10-22-002, KQL "MFA method per app"): READ-ONLY export of the dev tenant's
// sign-in log for the synthetic test personas (UPN prefix tp-), interactive (v1.0) and non-interactive (beta), mapped to
// the Log Analytics SigninLogs / AADNonInteractiveUserSignInLogs column names, so the KQL can be run on it in a Kusto
// emulator. The dev tenant has no Log Analytics workspace that we can reach.
//
// Runs in the passkey-point-e2e image as the E2E runner identity "PP E2E runner v0.1 (dev)" (certificate from the
// passkey-point-e2e Secret, runner.key/runner.crt only; AuditLog.Read.All is one of its four ADR-026 roles). GET only,
// /auditLogs/signIns only. The token stays in memory and is never printed.
//
//   node /work/signin-export.mjs <days> [upn-prefix]   (prefix '' lists UPN counts only, no rows)
//   node /work/signin-export.mjs <days> id:<user-object-id> [since-iso]   (point 5, C1/C13: times + results only, no UPN)
//   node /work/signin-export.mjs <days> p5:<upn-prefix> [since-iso]   (point 5, C13: per sign-in acrs, CA results, methods)
//
// Output: "ROW <json>" per sign-in, "RESULT <json>" summary lines. Exit 0 ok | 2 refused (self-check) | 1 error.
import { createHash, createPrivateKey, createSign, randomUUID, X509Certificate } from 'node:crypto';
import { readFileSync } from 'node:fs';

const TENANT_ID = '95cf7dac-b898-4b02-a22a-1379e2fde497';
const RUNNER_APP_ID = 'dca464ef-5b97-4d32-b80d-d98532b26652';
const GRAPH = 'https://graph.microsoft.com';
const ARG = process.argv[3] ?? 'tp-';
const BYID = /^id:[0-9a-f-]{36}$/.test(ARG) ? ARG.slice(3) : null;
const P5 = /^p5:pp-e2e-tp-catest-20\d{6}$/.test(ARG) ? ARG.slice(3) : null;
const PREFIX = BYID ? 'byid' : (P5 ?? ARG).toLowerCase(); // '' = every user (UPN counts only, no rows)
const SINCE = process.argv[4] && /^20\d\d-\d\d-\d\dT\d\d:\d\d:\d\dZ$/.test(process.argv[4]) ? process.argv[4] : null;
const MAX_ROWS = 20000;
const out = (o) => console.log('RESULT ' + JSON.stringify(o));
const b64url = (b) => Buffer.from(b).toString('base64url');

function assertion(keyPem, certPem) {
  const x5t = createHash('sha256').update(new X509Certificate(certPem).raw).digest('base64url');
  const now = Math.floor(Date.now() / 1000);
  const head = b64url(JSON.stringify({ alg: 'PS256', typ: 'JWT', 'x5t#S256': x5t }));
  const body = b64url(JSON.stringify({ aud: `https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token`, iss: RUNNER_APP_ID, sub: RUNNER_APP_ID, jti: randomUUID(), nbf: now, exp: now + 300 }));
  const s = createSign('RSA-SHA256'); s.update(`${head}.${body}`);
  return `${head}.${body}.${s.sign({ key: createPrivateKey(keyPem), padding: 6, saltLength: 32 }).toString('base64url')}`;
}

async function main() {
  const days = Number(process.argv[2] ?? 30);
  if (!(days >= 1 && days <= 30)) { out({ refused: 'days 1..30' }); return 2; }
  const res = await fetch(`https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token`, {
    method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ client_id: RUNNER_APP_ID, scope: `${GRAPH}/.default`, grant_type: 'client_credentials', client_assertion_type: 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer', client_assertion: assertion(readFileSync('/secrets/runner.key', 'utf8'), readFileSync('/secrets/runner.crt', 'utf8')) }),
  });
  const j = await res.json().catch(() => ({}));
  if (!res.ok || !j.access_token) { out({ refused: `token ${res.status} ${j.error ?? ''}` }); return 2; }
  const tok = j.access_token;
  const c = JSON.parse(Buffer.from(tok.split('.')[1], 'base64url').toString());
  if (c.tid !== TENANT_ID || c.appid !== RUNNER_APP_ID || !(c.roles ?? []).includes('AuditLog.Read.All')) { out({ refused: 'self-check: tenant, app or AuditLog.Read.All' }); return 2; }
  out({ selfCheck: { tid: c.tid, appid: c.appid, roles: (c.roles ?? []).length, auditLogRead: true } });

  const since = SINCE ?? new Date(Date.now() - days * 86400e3).toISOString().replace(/\.\d+Z$/, 'Z');
  const who = BYID ? `and userId eq '${BYID}' ` : PREFIX ? `and startswith(userPrincipalName,'${PREFIX}') ` : '';
  const sources = [
    { table: 'SigninLogs', url: `${GRAPH}/beta/auditLogs/signIns?$filter=createdDateTime ge ${since} ${who}and signInEventTypes/any(t: t eq 'interactiveUser')&$top=500` },
    { table: 'AADNonInteractiveUserSignInLogs', url: `${GRAPH}/beta/auditLogs/signIns?$filter=createdDateTime ge ${since} ${who}and signInEventTypes/any(t: t eq 'nonInteractiveUser')&$top=500` },
  ];
  let total = 0; const keysSeen = new Set(); const upns = {};
  for (const src of sources) {
    let next = src.url, n = 0, pages = 0;
    while (next && total < MAX_ROWS) {
      if (!next.startsWith(GRAPH + '/beta/auditLogs/signIns?')) { out({ refused: 'nextLink outside signIns' }); return 2; }
      const r = await fetch(next, { headers: { authorization: `Bearer ${tok}`, accept: 'application/json' } });
      if (r.status === 429 || (r.status >= 500 && (src.retries = (src.retries ?? 0) + 1) <= 4)) { await new Promise((x) => setTimeout(x, 8000)); continue; }
      if (!r.ok) { out({ table: src.table, status: r.status, error: (await r.json().catch(() => ({})))?.error?.code ?? null }); break; }
      const p = await r.json(); pages++;
      for (const e of p.value ?? []) {
        const upn = String(e.userPrincipalName ?? '').toLowerCase();
        if (!PREFIX) { const k = `${src.table}:${upn.split('@')[0]}`; upns[k] = (upns[k] ?? 0) + 1; total++; continue; }
        if (BYID) { if (e.userId === BYID) { console.log('BYID ' + JSON.stringify({ table: src.table, at: e.createdDateTime, app: e.appDisplayName, errorCode: e.status?.errorCode ?? null })); n++; total++; } continue; }
        if (P5) {
          if (!upn.startsWith(P5)) continue;
          console.log('P5 ' + JSON.stringify({ table: src.table, at: e.createdDateTime, app: e.appDisplayName, resource: e.resourceDisplayName, errorCode: e.status?.errorCode ?? null, failureReason: (e.status?.failureReason ?? '').slice(0, 120),
            acrs: e.authenticationContextClassReferences ?? [], requirement: e.authenticationRequirement, methods: (e.authenticationDetails ?? []).map((d) => [d.authenticationMethod, d.succeeded, d.authenticationStepResultDetail]),
            ca: (e.appliedConditionalAccessPolicies ?? []).filter((c) => c.result !== 'notApplied' && c.result !== 'notEnabled').map((c) => ({ id: String(c.id).slice(0, 8), result: c.result, strength: c.authenticationStrength?.displayName ?? null, acr: c.includeRulesSatisfied?.map?.((r) => r.ruleSatisfied) ?? null })), caD63: (e.appliedConditionalAccessPolicies ?? []).filter((c) => String(c.id).startsWith('d63ae654')).map((c) => c.result) }));
          n++; total++; continue;
        }
        if (!upn.startsWith(PREFIX)) continue;
        for (const k of Object.keys(e)) if (/session|correlation|token|clientApp|userAgent/i.test(k)) keysSeen.add(`${k}:${e[k] === null || e[k] === '' ? 'empty' : typeof e[k]}`);
        console.log('ROW ' + JSON.stringify({
          Table: src.table, TimeGenerated: e.createdDateTime, UserPrincipalName: e.userPrincipalName,
          AppDisplayName: e.appDisplayName, AppId: e.appId, ResourceDisplayName: e.resourceDisplayName, ResourceIdentity: e.resourceId,
          SessionId: e.sessionId ?? '', CorrelationId: e.correlationId, IsInteractive: e.isInteractive,
          ResultType: String(e.status?.errorCode ?? ''), ClientAppUsed: e.clientAppUsed ?? '', UserAgent: e.userAgent ?? '', UniqueTokenIdentifier: e.uniqueTokenIdentifier ?? '', AuthenticationRequirement: e.authenticationRequirement,
          AuthenticationDetails: JSON.stringify(e.authenticationDetails ?? []),
          AuthenticationContextClassReferences: JSON.stringify(e.authenticationContextClassReferences ?? []),
        }));
        n++; total++;
      }
      next = p['@odata.nextLink'] ?? null;
    }
    out({ table: src.table, rows: n, pages });
  }
  if (!PREFIX) out({ upnCounts: upns });
  out({ total, days, since, graphKeysSeen: [...keysSeen].sort() });
  return 0;
}
main().then((x) => process.exit(x)).catch((e) => { out({ error: String(e?.message ?? e).slice(0, 200) }); process.exit(1); });
