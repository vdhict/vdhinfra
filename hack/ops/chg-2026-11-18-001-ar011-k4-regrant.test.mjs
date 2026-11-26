// Unit test for chg-2026-11-18-001-ar011-k4.mjs, regrant mode (tsk-2026-11-17-110, B1 (a)). No network: a fake Graph and a fake image lib.
//   node --test hack/ops/chg-2026-11-18-001-ar011-k4-regrant.test.mjs
//   hack/ops/chg-2026-11-18-001-ar011-k4-regrant-mutation.sh   (every mutation of the guards must turn this test red)
// K4_MODULE points the test at a mutated copy of the script.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { pathToFileURL, fileURLToPath } from 'node:url';
import path from 'node:path';

process.env.K4_NO_MAIN = '1';
process.env.K4_REGRANT = '1';
const here = path.dirname(fileURLToPath(import.meta.url));
const K = await import(pathToFileURL(process.env.K4_MODULE ?? path.join(here, 'chg-2026-11-18-001-ar011-k4.mjs')).href);
K.timing.post = 0; K.timing.poll = 0; K.timing.token = 0;

// The 20 reviewed regrantForWake role ids (public Graph application role ids, ar011 plan 20261120T092236Z).
const IDS20 = {
  "AdministrativeUnit.ReadWrite.All": "5eb59dd3-1da2-4329-8733-9dabdc435916",
  "Application.ReadWrite.All": "1bfefb4e-e0b5-418b-a88f-73c46d2cc8e9",
  "DelegatedPermissionGrant.ReadWrite.All": "8e8e4742-1d95-4f68-9d56-6ee75648c72a",
  "Group.Read.All": "5b567255-7703-4780-807c-7be8301ae99b",
  "Group.ReadWrite.All": "62a82d76-70ea-41e2-9197-370581804d09",
  "Policy.Read.All": "246dd0d5-5bd0-4def-940b-0421030a5b68",
  "Policy.ReadWrite.AuthenticationMethod": "29c18626-4985-4dcd-85c0-193eef327366",
  "Policy.ReadWrite.ConditionalAccess": "01c0a623-fc9b-48e9-b794-0756f8e8f067",
  "Policy.ReadWrite.CrossTenantAccess": "338163d7-f101-4c92-94ba-ca46fe52447c",
  "Policy.ReadWrite.DeviceConfiguration": "230fb2d5-aa21-49c1-bfa7-ae1be179d867",
  "PrivilegedAssignmentSchedule.ReadWrite.AzureADGroup": "41202f2c-f7ab-45be-b001-85c9728b9d69",
  "PrivilegedEligibilitySchedule.ReadWrite.AzureADGroup": "618b6020-bca8-4de6-99f6-ef445fa4d857",
  "RoleEligibilitySchedule.ReadWrite.Directory": "fee28b28-e1f3-4841-818e-2704dc62245f",
  "RoleManagement.ReadWrite.Directory": "9e3f62cf-ca93-4989-b6ce-bf83c28f9fe8",
  "RoleManagementPolicy.ReadWrite.Directory": "31e08e0a-d3f7-4ca2-ac39-7343fb83e8ad",
  "User.DeleteRestore.All": "eccc023d-eccf-4e7b-9683-8813ab36cecc",
  "User.Read.All": "df021288-bdef-4463-88db-98f22de89214",
  "User.ReadWrite.All": "741f803b-c850-494e-b5df-cde7c675a1ca",
  "UserAuthMethod-TAP.ReadWrite.All": "627169a8-8c15-451c-861a-5b80e383de5c",
  "UserAuthenticationMethod.Read.All": "38d9df27-64da-44fd-b7c5-a6fbac20248f"
};
const K4IDS = { 'AppRoleAssignment.ReadWrite.All': 'k4000001-0000-0000-0000-000000000001', 'Application.Read.All': 'k4000002-0000-0000-0000-000000000002',
  'Organization.Read.All': 'k4000003-0000-0000-0000-000000000003', 'RoleManagement.Read.Directory': 'k4000004-0000-0000-0000-000000000004' };
const ALL = { ...IDS20, ...K4IDS };
const GRAPH_SP = 'aaaaaaaa-1111-2222-3333-444444444444';
const appRoles = Object.entries(ALL).map(([value, id]) => ({ value, id, allowedMemberTypes: ['Application'] }));
const nameOf = (id) => Object.entries(ALL).find(([, v]) => v === id)?.[0];

function world({ start = 'K4', postFail = null, tokenLagForever = false, ghost = null } = {}) {
  const w = { as: [], posts: [], deletes: [], seq: 0, tokenCalls: 0 };
  const add = (role) => w.as.push({ id: `asg-${String(++w.seq).padStart(6, '0')}-xyz`, principalId: K.BUILD_SP_ID, resourceId: GRAPH_SP, appRoleId: ALL[role] });
  for (const r of start === 'K4' ? K.K4 : K.FULL24) add(r);
  const jwt = (roles) => 'h.' + Buffer.from(JSON.stringify({ tid: K.TENANT_ID, appid: K.BUILD_APP_ID, oid: K.BUILD_SP_ID, idtyp: 'app', roles })).toString('base64url') + '.s';
  const res = (status, json) => ({ status, text: async () => (json === undefined ? '' : JSON.stringify(json)) });
  w.fetch = async (url, opt = {}) => {
    const m = opt.method ?? 'GET'; url = String(url);
    if (url.includes('/oauth2/v2.0/token')) {
      w.tokenCalls++;
      const roles = tokenLagForever ? [...K.K4] : w.as.map((a) => nameOf(a.appRoleId));
      return res(200, { access_token: jwt(roles) });
    }
    if (url.includes('/organization')) return res(200, { value: [{ id: K.TENANT_ID, verifiedDomains: [{ name: K.INITIAL_DOMAIN, isInitial: true }] }] });
    if (url.includes(`appId eq '${K.BUILD_APP_ID}'`)) return res(200, { value: [{ id: K.BUILD_SP_ID, appId: K.BUILD_APP_ID, displayName: K.BUILD_NAME }] });
    if (url.includes(`appId eq '${K.GRAPH_APP_ID}'`)) return res(200, { value: [{ id: GRAPH_SP, appId: K.GRAPH_APP_ID, displayName: 'Microsoft Graph', appRoles }] });
    if (url.includes(`servicePrincipals(appId='${K.BUILD_APP_ID}')`)) return res(200, { id: K.BUILD_SP_ID, appId: K.BUILD_APP_ID });
    if (url.includes('/roleManagement/directory/roleAssignments') || url.includes('/transitiveMemberOf')) return res(200, { value: [] });
    if (url.endsWith(`/servicePrincipals/${K.BUILD_SP_ID}/appRoleAssignments`)) {
      if (m === 'POST') {
        const b = JSON.parse(opt.body); w.posts.push(b);
        if (postFail && w.posts.length >= postFail) return res(403, { error: { code: 'Authorization_RequestDenied' } });
        if (nameOf(b.appRoleId) !== ghost) add(nameOf(b.appRoleId)); // ghost: 201 but never persisted
        return res(201, { id: 'x' });
      }
      return res(200, { value: w.as });
    }
    const one = url.match(/appRoleAssignments\/([A-Za-z0-9_-]+)$/);
    if (one) {
      const i = w.as.findIndex((a) => a.id === one[1]);
      if (m === 'DELETE') { w.deletes.push(one[1]); if (i >= 0) w.as.splice(i, 1); return res(i >= 0 ? 204 : 404); }
      return i >= 0 ? res(200, w.as[i]) : res(404, { error: { code: 'Request_ResourceNotFound' } });
    }
    return res(500, { error: { code: 'unexpected ' + m + ' ' + url } });
  };
  return w;
}
const lib = { clientAssertion: () => 'a', mountedKeySource: () => ({ load: async () => 'k' }), PINNED_APP_IDS: { build: K.BUILD_APP_ID },
  DEV_TENANT: { id: K.TENANT_ID, domain: K.INITIAL_DOMAIN }, assertDevTenant: () => {} };
const realFetch = globalThis.fetch;
const run = async (w, f) => { globalThis.fetch = w.fetch; K._resetWrote(); const lines = []; const log = console.log; console.log = (l) => lines.push(String(l)); try { return await f(); } finally { console.log = log; globalThis.fetch = realFetch; w.lines = lines; } };
const results = (w) => w.lines.filter((l) => l.startsWith('RESULT ')).map((l) => JSON.parse(l.slice(7)));

test('pinned list: the 20 reviewed roles hash to REGRANT_SHA256', () => {
  const full = K.FULL24.filter((r) => !K.K4.includes(r)).map((r) => ({ role: r, appRoleId: IDS20[r] })).sort((x, y) => (x.role < y.role ? -1 : 1));
  assert.equal(full.length, 20);
  assert.equal(K.sha(full), K.REGRANT_SHA256);
});

test('regrant from K4: 20 POSTs, FULL24 read back, fresh FULL24 token, rc 0, state sha printed', async () => {
  const w = world();
  const rc = await run(w, () => K.regrantFlow(lib, K.REGRANT_SHA256));
  assert.equal(rc, 0);
  assert.equal(w.posts.length, 20);
  for (const b of w.posts) { assert.equal(b.principalId, K.BUILD_SP_ID); assert.equal(b.resourceId, GRAPH_SP); assert.equal(Object.keys(b).length, 3); }
  assert.equal(w.as.length, 24);
  const r = results(w);
  assert.equal(r.find((x) => x.step === 'fresh-token').ok, true);
  const done = r.find((x) => x.step === 'done');
  assert.equal(done.fullStateSha256, K.sha(K.stateOf(w.as)));
  assert.equal(w.deletes.length, 0);
});

test('regrant is idempotent: already FULL24 writes nothing', async () => {
  const w = world({ start: 'FULL' });
  const rc = await run(w, () => K.regrantFlow(lib, K.REGRANT_SHA256));
  assert.equal(rc, 0); assert.equal(w.posts.length, 0);
});

test('regrant refuses a wrong --expect before any write', async () => {
  const w = world();
  await assert.rejects(run(w, () => K.regrantFlow(lib, 'f'.repeat(64))), /--expect/);
  assert.equal(w.posts.length, 0);
});

test('regrant refuses without K4_REGRANT=1', async () => {
  const w = world();
  process.env.K4_REGRANT = '0';
  try { await assert.rejects(run(w, () => K.regrantFlow(lib, K.REGRANT_SHA256)), /K4_REGRANT=1/); } finally { process.env.K4_REGRANT = '1'; }
  assert.equal(w.posts.length, 0);
});

test('a refused POST stops the run (fail closed), nothing past it; a second run resumes with only the missing roles', async () => {
  const w = world({ postFail: 6 });
  await assert.rejects(run(w, () => K.regrantFlow(lib, K.REGRANT_SHA256)), /POST .* 403/);
  assert.equal(w.as.length, 4 + 5);
  const posted = w.posts.length;
  assert.ok(posted >= 6 && posted <= 8, `posted ${posted}`);
  const before = w.as.length;
  const resumed = world({ start: 'K4' }); resumed.as.splice(0, resumed.as.length, ...w.as); resumed.seq = 100;
  const rc = await run(resumed, () => K.regrantFlow(lib, K.REGRANT_SHA256));
  assert.equal(rc, 0); assert.equal(resumed.posts.length, 24 - before); assert.equal(resumed.as.length, 24);
});

test('FAIL CLOSED: the fresh token never shows FULL24 -> failed line, no done line, rc 6', async () => {
  const w = world({ tokenLagForever: true });
  const rc = await run(w, () => K.regrantFlow(lib, K.REGRANT_SHA256));
  const r = results(w);
  assert.equal(rc, 6);
  assert.ok(!r.some((x) => x.step === 'done'), 'no done line');
  assert.ok(r.some((x) => x.failed && /refresh job must NOT run/.test(x.failed)));
});

test('write guard: a POST with another principal, another role or an extra field is refused', async () => {
  const w = world();
  const okSet = new Set([`${GRAPH_SP}|${IDS20['User.Read.All']}`]);
  const c = K.client('t', okSet);
  globalThis.fetch = w.fetch;
  try {
    const url = `/servicePrincipals/${K.BUILD_SP_ID}/appRoleAssignments`;
    await assert.rejects(c.call('POST', url, { principalId: 'other', resourceId: GRAPH_SP, appRoleId: IDS20['User.Read.All'] }), /write not allowed/);
    await assert.rejects(c.call('POST', url, { principalId: K.BUILD_SP_ID, resourceId: GRAPH_SP, appRoleId: IDS20['Group.ReadWrite.All'] }), /write not allowed/);
    await assert.rejects(c.call('POST', url, { principalId: K.BUILD_SP_ID, resourceId: GRAPH_SP, appRoleId: IDS20['User.Read.All'], x: 1 }), /write not allowed/);
    await assert.rejects(c.call('POST', '/servicePrincipals/other/appRoleAssignments', { principalId: K.BUILD_SP_ID, resourceId: GRAPH_SP, appRoleId: IDS20['User.Read.All'] }), /write not allowed/);
    await assert.rejects(K.client('t').call('POST', url, { principalId: K.BUILD_SP_ID, resourceId: GRAPH_SP, appRoleId: IDS20['User.Read.All'] }), /write not allowed/);
  } finally { globalThis.fetch = realFetch; }
  assert.equal(w.posts.length, 0);
});

test('whole cycle per run: regrant, then plan and cut --state go back to K4; cut without --state refuses after a regrant', async () => {
  const w = world();
  await run(w, () => K.regrantFlow(lib, K.REGRANT_SHA256));
  const state = results(w).find((x) => x.step === 'done').fullStateSha256;
  await run(w, () => K.main(['plan'], lib));
  const planSha = results(w).find((x) => x.step === 'plan').planSha256;
  await assert.rejects(run(w, () => K.main(['cut', '--expect', planSha], lib)), /7d850ff5/);
  assert.equal(w.deletes.length, 0);
  const rc = await run(w, () => K.main(['cut', '--expect', planSha, '--state', state], lib));
  assert.equal(rc, 0); assert.equal(w.deletes.length, 20); assert.equal(w.as.length, 4);
  // and the next run can regrant again
  const rc2 = await run(w, () => K.regrantFlow(lib, K.REGRANT_SHA256));
  assert.equal(rc2, 0); assert.equal(w.as.length, 24);
});

test('argument parsing: --state only on cut, regrant needs --expect', async () => {
  const w = world();
  assert.equal(await run(w, () => K.main(['regrant'], lib)), 2);
  assert.equal(await run(w, () => K.main(['plan', '--state', 'a'.repeat(64)], lib)), 2);
  assert.equal(await run(w, () => K.main(['regrant', '--expect', K.REGRANT_SHA256, '--state', 'a'.repeat(64)], lib)), 2);
});

test('a 201 that never shows in the read-back is not a grant: rc 6 before any token step', async () => {
  const w = world({ ghost: 'User.Read.All' });
  const rc = await run(w, () => K.regrantFlow(lib, K.REGRANT_SHA256));
  const r = results(w);
  assert.equal(rc, 6);
  assert.equal(r.find((x) => x.step === 'read-back').ok, false);
  assert.ok(!r.some((x) => x.step === 'fresh-token'));
});

test('a Graph role id that differs from the reviewed list refuses before any write', () => {
  const sp = { id: K.BUILD_SP_ID, appId: K.BUILD_APP_ID, displayName: K.BUILD_NAME };
  const roles = appRoles.map((r) => (r.value === 'User.Read.All' ? { ...r, id: 'deadbeef-0000-0000-0000-000000000000' } : r));
  const asg = K.K4.map((r, i) => ({ id: `asg-00000${i}-xyz`, principalId: K.BUILD_SP_ID, resourceId: GRAPH_SP, appRoleId: ALL[r] }));
  assert.throws(() => K.planRegrant(sp, { id: GRAPH_SP, appId: K.GRAPH_APP_ID, appRoles: roles }, asg), /reviewed/);
  assert.doesNotThrow(() => K.planRegrant(sp, { id: GRAPH_SP, appId: K.GRAPH_APP_ID, appRoles }, asg));
});
