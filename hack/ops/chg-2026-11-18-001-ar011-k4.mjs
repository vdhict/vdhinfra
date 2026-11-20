// chg-2026-11-18-001 (tsk-2026-11-19-964, wq-015): ar-011 D1. The build app atlas-devtenant-build removes its own Microsoft
// Graph application roles down to the K4 keeper set (Argus re-review 20261120T091726Z, Q3), dev tenant 7m5b27gbc ONLY.
//   K4 = AppRoleAssignment.ReadWrite.All, Application.Read.All, RoleManagement.Read.Directory, Organization.Read.All
// Runs INSIDE the devtenant image (passkey-point-devtenant a79ede4f) as a devtenant-build Job with the build key mounted.
//
//   node /work/k4.mjs plan                      GETs only: roles, state sha vs 7d850ff5, the 20 to remove, the 4 kept, planSha
//   node /work/k4.mjs cut --expect <planSha>    fresh plan must give the same planSha; DELETE the 20; read back to K4;
//                                               then a FRESH token whose roles claim is exactly K4
//   node /work/k4.mjs readback                  GETs only: Graph roles == K4, state sha == the K4 state sha
//
// Sign-in: the image's appSignIn() demands roles == the image manifest (24) exactly, so it refuses a K4 token by design.
// This script therefore does its own client-credentials sign-in with the image's clientAssertion() and repeats every
// ADR-027 self-check except the manifest comparison, which it replaces by: roles == FULL24 (the 7d850ff5 set) or == K4,
// nothing in between and nothing else. tid/appid pinned, app-only (idtyp app, no scp), wids absent/[]/[0997a1d0...],
// F3 oid == build SP, F2a no directory role, F2b no group. Token and key stay in memory and are never printed.
//
// Safety: a K4 role is never removed (checked in the pure plan AND again before every DELETE). AppRoleAssignment.
// ReadWrite.All is in K4, so it is never removed at all. Only assignments on the Microsoft Graph SP with principal ==
// the build SP are ever touched; any non-Graph assignment refuses. A partial cut is NOT rolled back automatically:
// re-granting write roles is the wake path (docs/runbooks/passkey-point-wake.md), which needs a reviewed plan sha.
//
// Exit: 0 ok | 2 refused before any write | 3 readback: not K4 (nothing written) | 6 failed after a write (state in RESULT
// lines). Every result line is one JSON object prefixed "RESULT ". K4_NO_MAIN=1 is set only by the local unit test.
import { createHash } from 'node:crypto';

export const TENANT_ID = '95cf7dac-b898-4b02-a22a-1379e2fde497';
export const INITIAL_DOMAIN = '7m5b27gbc.onmicrosoft.com';
export const BUILD_APP_ID = '9d98adaf-499f-49b2-ba94-cab1a5e42514';
export const BUILD_SP_ID = '8ac9ffda-2f92-42e1-b2d9-c8db041eff41';
export const BUILD_NAME = 'atlas-devtenant-build';
export const GRAPH_APP_ID = '00000003-0000-0000-c000-000000000000';
export const APP_ONLY_WIDS = '0997a1d0-0d1d-4acb-b408-d5ca73121e90';
// Rollback snapshot (31-cleanup-app-20261120t075246z buildStateSha256; names = 01-dry graphBefore).
export const FULL_STATE_SHA = '7d850ff573678d1cd7c5c0cc50bc2fd844bf784474a0c03a31ac57d76d51abef';
export const K4 = Object.freeze(['AppRoleAssignment.ReadWrite.All', 'Application.Read.All', 'Organization.Read.All', 'RoleManagement.Read.Directory']);
export const FULL24 = Object.freeze(['AdministrativeUnit.ReadWrite.All', 'AppRoleAssignment.ReadWrite.All', 'Application.Read.All',
  'Application.ReadWrite.All', 'DelegatedPermissionGrant.ReadWrite.All', 'Group.Read.All', 'Group.ReadWrite.All', 'Organization.Read.All',
  'Policy.Read.All', 'Policy.ReadWrite.AuthenticationMethod', 'Policy.ReadWrite.ConditionalAccess', 'Policy.ReadWrite.CrossTenantAccess',
  'Policy.ReadWrite.DeviceConfiguration', 'PrivilegedAssignmentSchedule.ReadWrite.AzureADGroup', 'PrivilegedEligibilitySchedule.ReadWrite.AzureADGroup',
  'RoleEligibilitySchedule.ReadWrite.Directory', 'RoleManagement.Read.Directory', 'RoleManagement.ReadWrite.Directory',
  'RoleManagementPolicy.ReadWrite.Directory', 'User.DeleteRestore.All', 'User.Read.All', 'User.ReadWrite.All', 'UserAuthMethod-TAP.ReadWrite.All',
  'UserAuthenticationMethod.Read.All']);
const G = 'https://graph.microsoft.com/v1.0';

export const sha = (v) => createHash('sha256').update(JSON.stringify(v)).digest('hex');
const out = (o) => console.log('RESULT ' + JSON.stringify(o));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
export class Refused extends Error {}
const sorted = (a) => [...a].sort();
export const sameSet = (a, b) => a.length === b.length && new Set(a).size === a.length && sorted(a).every((x, i) => x === sorted(b)[i]);
// Same state shape and sort as chg-2026-11-18-001-pilot-app.mjs / build-self-grant.mjs (so 7d850ff5 is comparable).
export const stateOf = (as) => as.map((a) => ({ id: String(a.id), resourceId: String(a.resourceId), appRoleId: String(a.appRoleId) }))
  .sort((x, y) => (x.id < y.id ? -1 : x.id > y.id ? 1 : 0));
export const K4_ROLES_SHA = sha(sorted(K4));
export const FULL24_ROLES_SHA = sha(sorted(FULL24));

/** Pure: from the build SP, the Graph SP and the build SP's appRoleAssignments, what a cut removes and keeps. Refuses on any ambiguity. */
export function planCut(buildSp, graphSp, assignments) {
  if (String(buildSp.appId).toLowerCase() !== BUILD_APP_ID) throw new Refused(`SP appId ${buildSp.appId} != ${BUILD_APP_ID}`);
  if (String(buildSp.id).toLowerCase() !== BUILD_SP_ID) throw new Refused(`SP id ${buildSp.id} != ${BUILD_SP_ID}`);
  if (buildSp.displayName !== BUILD_NAME) throw new Refused(`SP displayName "${buildSp.displayName}" != "${BUILD_NAME}"`);
  if (String(graphSp.appId).toLowerCase() !== GRAPH_APP_ID) throw new Refused(`Graph SP appId ${graphSp.appId} is not Microsoft Graph`);
  const appRoles = (graphSp.appRoles ?? []).filter((r) => (r.allowedMemberTypes ?? []).includes('Application'));
  const roleId = {};
  for (const v of FULL24) {
    const m = appRoles.filter((r) => r.value === v);
    if (m.length !== 1) throw new Refused(`Graph has ${m.length} application roles named ${v}, need exactly 1`);
    roleId[v] = String(m[0].id);
  }
  const name = (id) => appRoles.find((r) => String(r.id) === String(id))?.value ?? null;
  for (const a of assignments) {
    if (String(a.principalId) !== String(buildSp.id)) throw new Refused(`assignment ${a.id} principalId is not the build SP`);
    if (String(a.resourceId) !== String(graphSp.id)) throw new Refused(`assignment ${a.id} is on resource ${a.resourceId}, not Microsoft Graph: not part of K4, refused`);
    if (!name(a.appRoleId)) throw new Refused(`assignment ${a.id} has an appRoleId Graph does not name`);
    if (!/^[A-Za-z0-9_-]{8,}$/.test(String(a.id ?? ''))) throw new Refused(`assignment id ${a.id} has an unexpected shape`);
  }
  const roles = assignments.map((a) => name(a.appRoleId));
  if (new Set(roles).size !== roles.length) throw new Refused('duplicate Graph role assignments on the build SP');
  const unknown = roles.filter((r) => !FULL24.includes(r));
  if (unknown.length) throw new Refused(`roles outside the 7d850ff5 set: ${unknown.join(', ')}`);
  const missingK4 = K4.filter((r) => !roles.includes(r));
  if (missingK4.length) throw new Refused(`K4 roles already absent: ${missingK4.join(', ')}; not a state this script handles`);
  const keep = assignments.filter((a) => K4.includes(name(a.appRoleId)))
    .map((a) => ({ role: name(a.appRoleId), appRoleId: String(a.appRoleId), assignmentId: String(a.id) }))
    .sort((x, y) => (x.role < y.role ? -1 : 1));
  const remove = assignments.filter((a) => !K4.includes(name(a.appRoleId)))
    .map((a) => ({ role: name(a.appRoleId), appRoleId: String(a.appRoleId), assignmentId: String(a.id) }))
    .sort((x, y) => (x.role < y.role ? -1 : 1));
  if (remove.some((x) => K4.includes(x.role))) throw new Refused('internal: a K4 role in the removal list');
  if (keep.length !== 4) throw new Refused(`keep list has ${keep.length} entries, need 4`);
  const before = stateOf(assignments);
  const after = stateOf(assignments.filter((a) => K4.includes(name(a.appRoleId))));
  return {
    buildSpId: String(buildSp.id), graphSpId: String(graphSp.id), roleId,
    rolesBefore: sorted(roles), rolesBeforeSha256: sha(sorted(roles)),
    stateSha256: sha(before), stateIsFull: sha(before) === FULL_STATE_SHA,
    keep, remove, planSha256: sha(remove),
    k4StateSha256: sha(after), k4RolesSha256: K4_ROLES_SHA,
    // Wake: the reverse plan re-grants exactly these (resourceId = Graph SP, principalId = build SP).
    regrant: remove.map((x) => ({ role: x.role, appRoleId: x.appRoleId })),
  };
}

/** Pure: the role-name set a token's roles claim may carry: exactly FULL24 or exactly K4, nothing in between. */
export function tokenRolesKind(roles) {
  if (sameSet(roles, [...K4])) return 'K4';
  if (sameSet(roles, [...FULL24])) return 'FULL24';
  return null;
}

let wrote = false;

/** Own client-credentials sign-in + the ADR-027 self-check, with roles accepted as FULL24 or K4 (see header). */
async function signIn(lib, want) {
  const { clientAssertion, mountedKeySource, PINNED_APP_IDS, DEV_TENANT, assertDevTenant } = lib;
  if (DEV_TENANT.id !== TENANT_ID || DEV_TENANT.domain !== INITIAL_DOMAIN) throw new Refused('image DEV_TENANT mismatch');
  if (String(PINNED_APP_IDS.build).toLowerCase() !== BUILD_APP_ID) throw new Refused('image build app id mismatch');
  const rec = { app: BUILD_NAME, tid: null, appid: null, oid: null, wids: null, roles: null, rolesKind: null, roleAssignments: null, transitiveMemberOf: null, requests: [] };
  try {
    let key = await mountedKeySource().load('build');
    const tokenUrl = `https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token`;
    const r = await fetch(tokenUrl, { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ grant_type: 'client_credentials', client_id: BUILD_APP_ID, scope: 'https://graph.microsoft.com/.default',
        client_assertion_type: 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer', client_assertion: clientAssertion(BUILD_APP_ID, key, new Date()) }).toString() });
    key = null;
    let j = null; try { j = JSON.parse(await r.text()); } catch { j = null; }
    rec.requests.push({ method: 'POST', url: tokenUrl, status: r.status });
    if (r.status !== 200 || typeof j?.access_token !== 'string') throw new Refused(`token refused (${r.status} ${String(j?.error ?? '')})`);
    const token = j.access_token; j = null;
    const claims = JSON.parse(Buffer.from(token.split('.')[1] ?? '', 'base64url').toString('utf8'));
    const has = (k) => Object.prototype.hasOwnProperty.call(claims, k);
    rec.tid = claims.tid ?? null; rec.appid = claims.appid ?? claims.azp ?? null; rec.oid = claims.oid ?? null;
    rec.wids = has('wids') ? claims.wids : null;
    const roles = Array.isArray(claims.roles) ? claims.roles.map(String) : [];
    rec.roles = roles.length; rec.rolesKind = tokenRolesKind(roles);
    assertDevTenant(`${BUILD_NAME} token`, claims.tid);
    if (String(claims.tid).toLowerCase() !== TENANT_ID) throw new Refused('token tid mismatch');
    if (String(rec.appid).toLowerCase() !== BUILD_APP_ID) throw new Refused('token appid mismatch');
    if (claims.idtyp !== undefined && claims.idtyp !== 'app') throw new Refused('not an app-only token');
    if (has('scp')) throw new Refused('token carries scp');
    const w = claims.wids;
    if (has('wids') && !(Array.isArray(w) && (w.length === 0 || (w.length === 1 && String(w[0]).toLowerCase() === APP_ONLY_WIDS)))) throw new Refused(`unexpected wids ${JSON.stringify(w)}`);
    if (!rec.rolesKind) throw new Refused(`token roles (${roles.length}) are neither exactly the 7d850ff5 set nor exactly K4`);
    if (want && !want.includes(rec.rolesKind)) throw new Refused(`token roles are ${rec.rolesKind}, this step needs ${want.join(' or ')}`);
    if (String(claims.oid).toLowerCase() !== BUILD_SP_ID) throw new Refused('token oid is not the build SP');
    const get = async (url) => {
      const g = await fetch(url, { headers: { authorization: `Bearer ${token}` } });
      rec.requests.push({ method: 'GET', url, status: g.status });
      let b = null; try { b = JSON.parse(await g.text()); } catch { b = null; }
      return { status: g.status, json: b };
    };
    const empty = (x) => x.status === 200 && Array.isArray(x.json?.value) && x.json.value.length === 0 && !('@odata.nextLink' in x.json);
    const c = await get(`${G}/servicePrincipals(appId='${BUILD_APP_ID}')?$select=id,appId`);
    if (c.status !== 200 || String(c.json?.id).toLowerCase() !== BUILD_SP_ID) throw new Refused('F3: oid is not the build SP');
    const a = await get(`${G}/roleManagement/directory/roleAssignments?$filter=${encodeURIComponent(`principalId eq '${BUILD_SP_ID}'`)}`);
    rec.roleAssignments = Array.isArray(a.json?.value) ? a.json.value.length : null;
    if (!empty(a)) throw new Refused('F2a: directory role assignments not provably empty');
    const b = await get(`${G}/servicePrincipals/${BUILD_SP_ID}/transitiveMemberOf`);
    rec.transitiveMemberOf = Array.isArray(b.json?.value) ? b.json.value.length : null;
    if (!empty(b)) throw new Refused('F2b: group memberships not provably empty');
    rec.result = 'pass';
    console.log('self-check ' + JSON.stringify(rec));
    return { token, roles: sorted(roles), kind: rec.rolesKind };
  } catch (e) {
    rec.result = 'refuse';
    console.log('self-check ' + JSON.stringify(rec));
    throw e;
  }
}

function client(tok) {
  const call = async (method, path) => {
    const url = path.startsWith(G + '/') ? path : G + path;
    if (!url.startsWith(G + '/')) throw new Refused('URL outside Graph v1.0');
    if (method !== 'GET') {
      // The only write this script ever makes: DELETE of one appRoleAssignment of the build SP.
      if (method !== 'DELETE' || !new RegExp(`^${G}/servicePrincipals/${BUILD_SP_ID}/appRoleAssignments/[A-Za-z0-9_-]+$`).test(url)) throw new Refused(`write not allowed: ${method} ${url}`);
      wrote = true;
    }
    const r = await fetch(url, { method, headers: { authorization: `Bearer ${tok}` } });
    const text = await r.text();
    let json = null; try { json = text ? JSON.parse(text) : null; } catch { json = null; }
    return { status: r.status, json, code: json?.error?.code ?? null };
  };
  const list = async (path) => {
    const all = []; let next = path;
    for (let n = 0; next; n++) {
      if (n > 20) throw new Refused(`${path}: more than 20 pages`);
      const r = await call('GET', next);
      if (r.status !== 200 || !Array.isArray(r.json?.value)) throw new Refused(`GET ${String(next).split('?')[0]} -> ${r.status} ${r.code ?? ''}`);
      all.push(...r.json.value);
      next = r.json['@odata.nextLink'] ?? null;
      if (next && !next.startsWith(G + '/')) throw new Refused('nextLink outside Graph v1.0');
    }
    return all;
  };
  return { call, list };
}

async function context(lib, c, tokenRoles) {
  const org = await c.call('GET', '/organization?$select=id,verifiedDomains');
  const o = org.json?.value?.[0];
  lib.assertDevTenant('organization', TENANT_ID, o);
  const initial = (o?.verifiedDomains ?? []).find((d) => d.isInitial)?.name ?? null;
  if (String(o?.id).toLowerCase() !== TENANT_ID || String(initial).toLowerCase() !== INITIAL_DOMAIN) throw new Refused(`tenant check: org ${o?.id}, initial ${initial}`);
  const sps = await c.list(`/servicePrincipals?$filter=appId eq '${BUILD_APP_ID}'&$select=id,appId,displayName,accountEnabled`);
  if (sps.length !== 1) throw new Refused(`${sps.length} service principals with appId ${BUILD_APP_ID}, need exactly 1`);
  const graphs = await c.list(`/servicePrincipals?$filter=appId eq '${GRAPH_APP_ID}'&$select=id,appId,displayName,appRoles`);
  if (graphs.length !== 1) throw new Refused(`${graphs.length} Microsoft Graph service principals, need exactly 1`);
  out({ step: 'tenant', tid: TENANT_ID, organizationId: o.id, initialDomain: initial, signedInAs: BUILD_NAME, tokenRoles });
  const buildSp = sps[0], graphSp = graphs[0];
  const read = () => c.list(`/servicePrincipals/${buildSp.id}/appRoleAssignments`);
  return { buildSp, graphSp, read };
}

const planLine = (mode, p) => out({ step: 'plan', mode, buildSpId: p.buildSpId, graphSpId: p.graphSpId, rolesBefore: p.rolesBefore,
  rolesBeforeCount: p.rolesBefore.length, stateSha256: p.stateSha256, stateIsFull7d850ff5: p.stateIsFull,
  keep: p.keep, remove: p.remove, removeCount: p.remove.length, planSha256: p.planSha256,
  k4StateSha256: p.k4StateSha256, k4RolesSha256: p.k4RolesSha256, regrantForWake: p.regrant });

async function main(argv) {
  const mode = argv[0];
  if (!['plan', 'cut', 'readback'].includes(mode)) { out({ refused: 'usage: plan | cut --expect <planSha256> | readback' }); return 2; }
  let expect = null;
  for (let i = 1; i < argv.length; i++) {
    if (argv[i] !== '--expect' || !/^[0-9a-f]{64}$/.test(argv[i + 1] ?? '') || expect) { out({ refused: `unknown argument ${argv[i]}` }); return 2; }
    expect = argv[++i];
  }
  if (mode === 'cut' && !expect) { out({ refused: 'cut needs --expect <planSha256 from plan>' }); return 2; }
  if (mode !== 'cut' && expect) { out({ refused: `${mode} takes no --expect` }); return 2; }

  const auth = await import('/app/infra/devtenant/lib/app-auth.ts');
  const { assertDevTenant } = await import('/app/infra/devtenant/lib/tenant-pin.ts');
  const lib = { ...auth, assertDevTenant };

  if (mode === 'readback') {
    const s = await signIn(lib, null);
    const c = client(s.token);
    const { graphSp, read } = await context(lib, c, s.kind);
    const cur = await read();
    const appRoles = (graphSp.appRoles ?? []);
    const roles = sorted(cur.map((a) => appRoles.find((r) => String(r.id) === String(a.appRoleId))?.value ?? `unknown:${a.appRoleId}`));
    const nonGraph = cur.filter((a) => String(a.resourceId) !== String(graphSp.id)).length;
    const ok = nonGraph === 0 && sameSet(roles, [...K4]) && s.kind === 'K4';
    out({ step: 'readback', roles, rolesSha256: sha(roles), k4RolesSha256: K4_ROLES_SHA, stateSha256: sha(stateOf(cur)), nonGraph, tokenRolesKind: s.kind, ok });
    out({ step: 'done', mode, written: 0 });
    return ok ? 0 : 3;
  }

  const s = await signIn(lib, ['FULL24']);
  const c = client(s.token);
  const { buildSp, graphSp, read } = await context(lib, c, s.kind);
  const p = planCut(buildSp, graphSp, await read());
  planLine(mode, p);
  if (mode === 'plan') { out({ step: 'done', mode, written: 0, note: 'plan: GETs only, nothing written' }); return 0; }

  // cut
  if (!p.stateIsFull) throw new Refused(`state sha ${p.stateSha256} != 7d850ff5 (the reviewed rollback snapshot); nothing written`);
  if (p.remove.length !== 20) throw new Refused(`removal list has ${p.remove.length} entries, the reviewed plan has 20; nothing written`);
  if (expect !== p.planSha256) throw new Refused(`planSha ${p.planSha256} != --expect ${expect}; nothing written`);

  const appRoles = (graphSp.appRoles ?? []);
  const nameOf = (id) => appRoles.find((r) => String(r.id) === String(id))?.value ?? null;
  const removed = [];
  for (const x of p.remove) {
    // Belt and braces before every write: never a K4 role, and the id still names the same role on the build SP.
    if (K4.includes(x.role) || K4.includes(nameOf(x.appRoleId))) throw new Refused(`refusing to remove K4 role ${x.role}`);
    let st = null, code = null, done = false;
    for (let i = 0; i < 3 && !done; i++) {
      if (i) await sleep(5000);
      const w = await c.call('DELETE', `/servicePrincipals/${p.buildSpId}/appRoleAssignments/${x.assignmentId}`);
      st = w.status; code = w.code;
      // A 404 is never proof of delete on its own: count it only when the id is also absent from the list.
      if (st === 204) done = true;
      else if (st === 404) done = !(await read()).some((a) => String(a.id) === x.assignmentId);
    }
    out({ step: 'write', method: 'DELETE', role: x.role, assignmentId: x.assignmentId, status: st, code, confirmed: done });
    if (!done) throw new Refused(`DELETE ${x.role} -> ${st} ${code ?? ''}; stopped after ${removed.length} of ${p.remove.length}`);
    removed.push(x.role);
  }

  // Read back: K4 role set, the expected K4 state sha, and every removed id answering 404, three reads in a row.
  let good = 0, cur = [], gone = 0;
  for (let i = 0; i < 24 && good < 3; i++) {
    if (i) await sleep(10000);
    cur = await read();
    const roles = cur.map((a) => nameOf(a.appRoleId));
    gone = 0;
    for (const x of p.remove) { const g = await c.call('GET', `/servicePrincipals/${p.buildSpId}/appRoleAssignments/${x.assignmentId}`); if (g.status === 404) gone++; }
    const ok = sameSet(roles, [...K4]) && sha(stateOf(cur)) === p.k4StateSha256 && gone === p.remove.length;
    good = ok ? good + 1 : 0;
  }
  const rolesNow = sorted(cur.map((a) => nameOf(a.appRoleId)));
  out({ step: 'read-back', roles: rolesNow, stateSha256: sha(stateOf(cur)), k4StateSha256: p.k4StateSha256, removedIds404: gone, goodReadsInARow: good, ok: good >= 3 });
  if (good < 3) { out({ failed: 'read-back did not converge on K4', wrote: true, removed: removed.length }); return 6; }

  // Fresh token: roles claim exactly K4 (token issuance may lag the directory; retry spaced).
  let fresh = null, lastErr = null;
  for (let i = 0; i < 20 && !fresh; i++) {
    if (i) await sleep(30000);
    try { fresh = await signIn(lib, ['K4']); } catch (e) { lastErr = e?.message ?? String(e); }
  }
  out({ step: 'fresh-token', rolesKind: fresh?.kind ?? null, roles: fresh?.roles ?? null, rolesSha256: fresh ? sha(fresh.roles) : null, k4RolesSha256: K4_ROLES_SHA, ok: fresh?.kind === 'K4', lastError: fresh ? null : lastErr });
  if (!fresh) { out({ failed: 'fresh token did not show K4', wrote: true }); return 6; }
  out({ step: 'done', mode, written: removed.length, rc: 0 });
  return 0;
}

if (process.env.K4_NO_MAIN !== '1') {
  main(process.argv.slice(2)).then((rc) => process.exit(rc), (e) => {
    out({ [wrote ? 'failed' : 'refused']: e instanceof Refused ? e.message : `error: ${e?.message ?? e}`, wrote });
    process.exit(wrote ? 6 : 2);
  });
}
