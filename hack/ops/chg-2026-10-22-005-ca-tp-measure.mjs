// chg-2026-10-22-005 (Larry 22-10, tsk-2026-10-22-002; AGR-087 dev tenant): READ-ONLY measurement of the CA-TP
// authentication strength and of what governs passkey / Windows Hello registration in the dev tenant.
// Answers what configuration and sign-in logs can answer; the device steps (WHfB provisioning, a passkey in the
// Authenticator app, a synced passkey) need a real Windows device / phone and are not attempted here.
//
// Runs INSIDE the devtenant image (passkey-point-devtenant a79ede4f) as a devtenant-build Job, with the image's own
// sign-in (lib/app-auth.ts appSignIn: tenant pin + self-check) as atlas-devtenant-build. GET only: the call helper
// refuses any other method. The token stays in memory and is never printed. No user names or UPNs are printed.
//
//   node /work/ca-tp-measure.mjs
//
// Exit: 0 ok | 2 refused (tenant pin). A GET that fails is reported as {status} and the run goes on.
const TENANT_ID = '95cf7dac-b898-4b02-a22a-1379e2fde497';
const INITIAL_DOMAIN = '7m5b27gbc.onmicrosoft.com';
const V1 = 'https://graph.microsoft.com/v1.0';
const BETA = 'https://graph.microsoft.com/beta';
const out = (k, v) => console.log('RESULT ' + JSON.stringify({ [k]: v }));

async function main() {
  const { appSignIn, signInIo, mountedKeySource, PINNED_APP_IDS, DEV_TENANT } = await import('/app/infra/devtenant/lib/app-auth.ts');
  if (DEV_TENANT.id !== TENANT_ID || DEV_TENANT.domain !== INITIAL_DOMAIN) { out('refused', 'image DEV_TENANT mismatch'); return 2; }
  let key = await mountedKeySource().load('build');
  const io = signInIo((u, init) => fetch(u, init), (l) => console.log(l));
  const s = await appSignIn(io, 'build', PINNED_APP_IDS.build, key, new Date());
  key = null;
  const tok = s.token;
  const get = async (url) => {
    if (!url.startsWith(V1 + '/') && !url.startsWith(BETA + '/')) throw new Error('outside Graph');
    const r = await fetch(url, { method: 'GET', headers: { authorization: `Bearer ${tok}` } });
    const text = await r.text();
    let json = null; try { json = text ? JSON.parse(text) : null; } catch { json = null; }
    return { status: r.status, json };
  };
  const list = async (url, maxPages = 5) => {
    const all = []; let next = url;
    for (let n = 0; next && n < maxPages; n++) {
      const r = await get(next);
      if (r.status !== 200) return { status: r.status, error: r.json?.error?.code ?? null };
      all.push(...(r.json?.value ?? []));
      next = r.json['@odata.nextLink'] ?? null;
    }
    return { status: 200, value: all };
  };

  const org = await get(`${V1}/organization?$select=id,verifiedDomains`);
  const o = org.json?.value?.[0];
  if (String(o?.id) !== TENANT_ID || !(o?.verifiedDomains ?? []).some((d) => d.isInitial && d.name === INITIAL_DOMAIN)) { out('refused', 'organization is not the dev tenant'); return 2; }
  out('tenant', { id: TENANT_ID, initialDomain: INITIAL_DOMAIN });

  // 4. Authentication strengths (custom + built-in) with FIDO2 combination configurations (AAGUIDs).
  const strengths = await list(`${BETA}/identity/conditionalAccess/authenticationStrength/policies`);
  if (strengths.status !== 200) out('strengths', strengths);
  for (const p of strengths.value ?? []) {
    if (p.policyType === 'builtIn' && !['Phishing-resistant MFA', 'Passwordless MFA'].includes(p.displayName)) continue;
    const cc = await list(`${BETA}/identity/conditionalAccess/authenticationStrength/policies/${p.id}/combinationConfigurations`);
    out('strength', {
      id: p.id, displayName: p.displayName, policyType: p.policyType, requirementsSatisfied: p.requirementsSatisfied,
      allowedCombinations: p.allowedCombinations,
      combinationConfigurations: (cc.value ?? []).map((c) => ({ type: c['@odata.type'], appliesTo: c.appliesToCombinations, allowedAAGUIDs: c.allowedAAGUIDs, allowedPasskeyProfiles: c.allowedPasskeyProfiles, allowedIssuers: c.allowedIssuers })),
      combinationConfigurationsStatus: cc.status,
    });
  }

  // Authentication contexts (c1 = CA-TP).
  const acrs = await list(`${V1}/identity/conditionalAccess/authenticationContextClassReferences`);
  out('authContexts', acrs.status === 200 ? acrs.value.map((a) => ({ id: a.id, displayName: a.displayName, isAvailable: a.isAvailable })) : acrs);

  // CA policies: what targets c1, and the user actions "register security info" / "register or join devices".
  const pols = await list(`${BETA}/identity/conditionalAccess/policies`);
  if (pols.status !== 200) out('caPolicies', pols);
  for (const p of pols.value ?? []) {
    const a = p.conditions?.applications ?? {};
    const u = p.conditions?.users ?? {};
    out('caPolicy', {
      id: p.id, displayName: p.displayName, state: p.state,
      includeApplications: a.includeApplications, excludeApplicationsCount: (a.excludeApplications ?? []).length,
      includeUserActions: a.includeUserActions, includeAuthenticationContextClassReferences: a.includeAuthenticationContextClassReferences,
      users: { includeUsers: u.includeUsers, includeGroupsCount: (u.includeGroups ?? []).length, includeRoles: (u.includeRoles ?? []).length, excludeUsersCount: (u.excludeUsers ?? []).length, excludeGroupsCount: (u.excludeGroups ?? []).length },
      clientAppTypes: p.conditions?.clientAppTypes, platforms: p.conditions?.platforms ?? null, locations: p.conditions?.locations ? { include: p.conditions.locations.includeLocations, excludeCount: (p.conditions.locations.excludeLocations ?? []).length } : null,
      grantControls: p.grantControls ? { operator: p.grantControls.operator, builtInControls: p.grantControls.builtInControls, authenticationStrength: p.grantControls.authenticationStrength ? { id: p.grantControls.authenticationStrength.id, displayName: p.grantControls.authenticationStrength.displayName } : null } : null,
      sessionControls: p.sessionControls ? Object.keys(p.sessionControls).filter((k) => p.sessionControls[k]) : null,
    });
  }

  // 2. Method settings: FIDO2/passkey (self-service registration, attestation, key restrictions, passkey profiles),
  // Authenticator, TAP, registration campaign.
  const amp = await get(`${BETA}/policies/authenticationMethodsPolicy`);
  out('authMethodsPolicy', amp.status === 200 ? { policyMigrationState: amp.json.policyMigrationState, registrationEnforcement: amp.json.registrationEnforcement, reportSuspiciousActivitySettings: amp.json.reportSuspiciousActivitySettings?.state } : { status: amp.status });
  for (const m of ['Fido2', 'MicrosoftAuthenticator', 'TemporaryAccessPass', 'Sms', 'SoftwareOath', 'X509Certificate', 'Email', 'Voice']) {
    const r = await get(`${BETA}/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/${m}`);
    if (r.status !== 200) { out('method', { method: m, status: r.status }); continue; }
    const j = { ...r.json }; delete j['@odata.context'];
    j.includeTargets = (j.includeTargets ?? []).map((t) => { const x = { ...t }; delete x['@odata.type']; return x; });
    delete j['includeTargets@odata.context'];
    j.excludeTargets = (j.excludeTargets ?? []).length;
    out('method', { method: m, config: j });
  }
  // Names of the groups the method settings target (group names are dev-tenant test groups).
  for (const m of ['Fido2', 'TemporaryAccessPass']) {
    const r = await get(`${BETA}/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/${m}`);
    for (const t of r.json?.includeTargets ?? []) if (t.id !== 'all_users') { const g = await get(`${V1}/groups/${t.id}?$select=id,displayName`); out('targetGroup', { method: m, id: t.id, displayName: g.json?.displayName ?? null, status: g.status }); }
  }

  // 1. Device registration (WHfB provisioning needs a registered/joined device): MFA requirement and who may join.
  const drp = await get(`${BETA}/policies/deviceRegistrationPolicy`);
  out('deviceRegistrationPolicy', drp.status === 200 ? { multiFactorAuthConfiguration: drp.json.multiFactorAuthConfiguration, azureADJoinAllowedToJoin: drp.json.azureADJoin?.allowedToJoin?.['@odata.type'], azureADJoinEnabled: drp.json.azureADJoin?.isAdminConfigurable, azureADRegistration: drp.json.azureADRegistration?.allowedToRegister?.['@odata.type'], userDeviceQuota: drp.json.userDeviceQuota } : { status: drp.status });
  // Intune WHfB tenant-wide setting (needs DeviceManagementServiceConfig.Read.All; may be 403).
  const whfb = await list(`${BETA}/deviceManagement/deviceEnrollmentConfigurations?$filter=isof('microsoft.graph.windowsHelloForBusinessSettings')`, 1);
  out('intuneWhfb', whfb.status === 200 ? whfb.value.map((w) => ({ state: w.state, securityDeviceRequired: w.securityDeviceRequired, enhancedSignInSecurity: w.enhancedSignInSecurity })) : whfb);
  // Devices: how many Entra-joined/registered Windows devices exist at all (counts only).
  const dev = await list(`${V1}/devices?$select=operatingSystem,trustType&$top=999`, 2);
  if (dev.status === 200) { const c = {}; for (const d of dev.value) { const k = `${d.operatingSystem}/${d.trustType}`; c[k] = (c[k] ?? 0) + 1; } out('devices', c); } else out('devices', dev);

  // 3 + sign-in log: methods that satisfied CA in the last 7 days, aggregated; no users printed.
  const since = new Date(Date.now() - 7 * 86400e3).toISOString();
  const si = await list(`${BETA}/auditLogs/signIns?$filter=createdDateTime ge ${since}&$top=500`, 4);
  if (si.status !== 200) out('signIns', si);
  else {
    const agg = {};
    for (const e of si.value) {
      const methods = [...new Set((e.authenticationDetails ?? []).filter((d) => d.succeeded).map((d) => d.authenticationMethod))].sort().join('+') || '-';
      const strength = (e.appliedConditionalAccessPolicies ?? []).filter((p) => p.result && p.result !== 'notApplied' && p.authenticationStrength).map((p) => `${p.displayName}:${p.result}`).sort().join(',') || '-';
      const k = JSON.stringify({ app: e.appDisplayName, req: e.authenticationRequirement, acrs: (e.authenticationContextClassReferences ?? []).map((a) => `${a.id}:${a.detail}`).join(','), methods, strengthPolicies: strength, ok: e.status?.errorCode === 0 ? 'ok' : String(e.status?.errorCode) });
      agg[k] = (agg[k] ?? 0) + 1;
    }
    out('signInsTotal', si.value.length);
    for (const [k, n] of Object.entries(agg).sort((a, b) => b[1] - a[1])) out('signInGroup', { ...JSON.parse(k), count: n });
  }
  return 0;
}

main().then((c) => process.exit(c)).catch((e) => { out('error', String(e?.message ?? e).slice(0, 200)); process.exit(1); });
