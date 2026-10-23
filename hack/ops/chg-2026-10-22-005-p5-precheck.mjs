// chg-2026-10-22-005 point 5, Argus 23-10 conditions C1, C2 and the C7 baseline: READ-ONLY pre-check before any write
// to CA policy d63ae654 ("PP-DEV CA-TP", auth context c2).
//   C1: the include/exclude targets of d63ae654; for each include group its type (dynamic, role-assignable, nested
//       groups) and every transitive member, classified. Test personas pp-e2e-tp-* are printed by alias; any other
//       member only as a count per type plus its object id (no names), so a non-test member stops the test.
//   C2: every CA policy that names auth context c2 (only d63ae654 may).
//   C7: sha256 of the canonical fields (state, conditions, grantControls, sessionControls) of every CA policy, and of
//       the include group's sorted member ids. Written once by the operator from this output.
//
// Runs INSIDE the devtenant image (a79ede4f) as a devtenant-build Job, signed in as atlas-devtenant-build through the
// image's appSignIn (tenant pin + self-check). GET only; the token is never printed.
//   node /work/p5-precheck.mjs
// Exit: 0 measured (verdict in RESULT c1/c2) | 2 refused (tenant pin) | 1 error.
import { createHash } from 'node:crypto';

const TENANT_ID = '95cf7dac-b898-4b02-a22a-1379e2fde497';
const INITIAL_DOMAIN = '7m5b27gbc.onmicrosoft.com';
const TARGET = 'd63ae654';
const BETA = 'https://graph.microsoft.com/beta';
const V1 = 'https://graph.microsoft.com/v1.0';
const out = (k, v) => console.log('RESULT ' + JSON.stringify({ [k]: v }));
const canon = (v) => (Array.isArray(v) ? v.map(canon) : v && typeof v === 'object' ? Object.fromEntries(Object.keys(v).sort().map((k) => [k, canon(v[k])])) : v);
const sha = (v) => createHash('sha256').update(JSON.stringify(canon(v))).digest('hex');

async function main() {
  const { appSignIn, signInIo, mountedKeySource, PINNED_APP_IDS, DEV_TENANT } = await import('/app/infra/devtenant/lib/app-auth.ts');
  if (DEV_TENANT.id !== TENANT_ID || DEV_TENANT.domain !== INITIAL_DOMAIN) { out('refused', 'image DEV_TENANT mismatch'); return 2; }
  let key = await mountedKeySource().load('build');
  const s = await appSignIn(signInIo((u, init) => fetch(u, init), (l) => console.log(l)), 'build', PINNED_APP_IDS.build, key, new Date());
  key = null;
  const get = async (url) => {
    if (!url.startsWith(V1 + '/') && !url.startsWith(BETA + '/')) throw new Error('outside Graph');
    const r = await fetch(url, { method: 'GET', headers: { authorization: `Bearer ${s.token}` } });
    let json = null; try { json = await r.json(); } catch { json = null; }
    return { status: r.status, json };
  };
  const list = async (url, maxPages = 20) => {
    const all = []; let next = url;
    for (let n = 0; next && n < maxPages; n++) {
      const r = await get(next);
      if (r.status !== 200) throw new Error(`GET ${url.split('?')[0].replace(/[0-9a-f-]{36}/g, '{id}')} -> ${r.status} ${r.json?.error?.code ?? ''}`);
      all.push(...(r.json?.value ?? [])); next = r.json['@odata.nextLink'] ?? null;
    }
    if (next) throw new Error('too many pages');
    return all;
  };

  const policies = await list(`${BETA}/identity/conditionalAccess/policies`);
  const hashes = policies.map((p) => ({ id: p.id.slice(0, 8), state: p.state, sha256: sha({ state: p.state, conditions: p.conditions, grantControls: p.grantControls, sessionControls: p.sessionControls }) })).sort((a, b) => a.id.localeCompare(b.id));
  out('policyHashes', hashes);
  const c2 = policies.filter((p) => (p.conditions?.applications?.includeAuthenticationContextClassReferences ?? []).includes('c2'));
  const c2ids = c2.map((p) => p.id.slice(0, 8));
  out('c2', { policies: c2ids, ok: c2ids.length === 1 && c2ids[0] === TARGET });

  const t = policies.find((p) => p.id.startsWith(TARGET));
  if (!t) { out('c1', { ok: false, reason: 'target policy not found' }); return 0; }
  const u = t.conditions?.users ?? {};
  out('target', { id: t.id, state: t.state, includeUsers: u.includeUsers ?? [], excludeUsers: u.excludeUsers ?? [], includeGroups: u.includeGroups ?? [], excludeGroups: u.excludeGroups ?? [], includeRoles: u.includeRoles ?? [], excludeRoles: u.excludeRoles ?? [], includeGuestsOrExternalUsers: Boolean(u.includeGuestsOrExternalUsers), apps: t.conditions?.applications?.includeApplications ?? [], acr: t.conditions?.applications?.includeAuthenticationContextClassReferences ?? [], grant: t.grantControls ?? null });
  const problems = [];
  if ((u.includeUsers ?? []).length) problems.push('includeUsers not empty');
  if ((u.includeRoles ?? []).length) problems.push('includeRoles not empty');
  if (u.includeGuestsOrExternalUsers) problems.push('guests included');
  const memberIds = [];
  for (const gid of u.includeGroups ?? []) {
    const g = await get(`${V1}/groups/${gid}?$select=id,groupTypes,membershipRule,isAssignableToRole,securityEnabled`);
    const dynamic = (g.json?.groupTypes ?? []).includes('DynamicMembership');
    const direct = await list(`${V1}/groups/${gid}/members?$select=id&$top=999`);
    const nested = direct.filter((m) => m['@odata.type'] !== '#microsoft.graph.user').length;
    const trans = await list(`${V1}/groups/${gid}/transitiveMembers/microsoft.graph.user?$select=id,userPrincipalName&$top=999`);
    const personas = [], others = [];
    for (const m of trans) {
      memberIds.push(m.id);
      const upn = String(m.userPrincipalName ?? '').toLowerCase();
      if (upn.startsWith('pp-e2e-tp-') && upn.endsWith('@' + INITIAL_DOMAIN)) personas.push(upn.split('@')[0].slice('pp-e2e-'.length));
      else others.push(m.id);
    }
    out('group', { id: gid, status: g.status, dynamic, isAssignableToRole: g.json?.isAssignableToRole ?? null, directMembers: direct.length, nestedNonUser: nested, personas: personas.sort(), otherUserIds: others });
    if (g.status !== 200) problems.push(`group ${gid.slice(0, 8)} unreadable`);
    if (dynamic) problems.push(`group ${gid.slice(0, 8)} dynamic`);
    if (nested) problems.push(`group ${gid.slice(0, 8)} has ${nested} non-user members`);
    if (others.length) problems.push(`group ${gid.slice(0, 8)} has ${others.length} non-persona users`);
  }
  out('memberHash', { count: memberIds.length, sha256: sha(memberIds.sort()) });
  out('c1', { ok: problems.length === 0, problems });
  return 0;
}
main().then((x) => process.exit(x)).catch((e) => { out('error', String(e?.message ?? e).slice(0, 200)); process.exit(1); });
