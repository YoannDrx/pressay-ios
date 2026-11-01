#!/usr/bin/env node
// A local stand-in for Pressay Cloud and its OAuth issuer, for walking through the account screens
// in the simulator without any real account. Keys and data live in memory and die with the process.
//
//   node scripts/fake-cloud.mjs [port]
//   xcrun simctl launch <simulator> fr.yodev.pressay \
//     -PressayCloudURL http://127.0.0.1:8787 -PressayEntitlementKey <printed key> \
//     -PressayEntitlementKeyID fake-key
//
// Change its behaviour during a walkthrough:
//   curl -X POST 'http://127.0.0.1:8787/__control?deviceLimit=1'    next sign-ins find three devices
//   curl -X POST 'http://127.0.0.1:8787/__control?revoked=1'        this iPhone was removed
//   curl -X POST 'http://127.0.0.1:8787/__control?appleActive=1'    deletion finds an App Store subscription
//   curl -X POST 'http://127.0.0.1:8787/__control?source=stripe'    Pro from the website
//   curl -X POST 'http://127.0.0.1:8787/__control?sandbox=refuse'   refuse Sandbox purchases
//   curl -X POST 'http://127.0.0.1:8787/__control?expiresIn=5'      signed rights expire in 5 s
//   curl 'http://127.0.0.1:8787/__state'                            what the server recorded

import { createHash, generateKeyPairSync, randomUUID, sign } from 'node:crypto';
import { createServer } from 'node:http';

const port = Number(process.argv[2] ?? 8787);
const origin = `http://127.0.0.1:${port}`;
const { publicKey, privateKey } = generateKeyPairSync('ed25519');
const publicRaw = publicKey.export({ format: 'jwk' }).x;
const keyId = 'fake-key';

const accountId = randomUUID();
const state = {
  tier: 'free',
  source: 'none',
  deviceId: randomUUID(),
  otherDevices: [],
  revokedDevices: [],
  revoked: false,
  appleActive: false,
  sandbox: 'accept',
  expiresIn: 72 * 3600,
  deleted: false,
  bootstraps: [],
  restores: [],
  sync: { changes: [], envelope: null, sequence: 1 },
};

const iso = (seconds = 0) => new Date(Date.now() + seconds * 1000).toISOString();
const base64url = (value) => Buffer.from(value).toString('base64url');
const device = (id, displayName, platform) => ({
  id,
  displayName,
  platform,
  appVariant: platform === 'ios' ? 'app_store_ios' : 'mas',
  appVersion: '1.0.0',
  approved: true,
  lastSeenAt: iso(-3600),
  createdAt: iso(-86400),
});

function entitlementToken() {
  const now = Math.floor(Date.now() / 1000);
  const expiry = now + state.expiresIn;
  const encode = (value) => base64url(JSON.stringify(value));
  const head = encode({ alg: 'EdDSA', kid: keyId, typ: 'JWT' });
  const body = encode({
    tier: state.tier,
    source: state.source,
    revision: 1,
    device_id: state.deviceId,
    online_valid_until: state.tier === 'pro' ? expiry : undefined,
    offline_grace_until: state.tier === 'pro' ? expiry : undefined,
    usage: {},
    iss: 'https://api.press-say.app',
    aud: ['app.pressay.desktop', 'fr.yodev.pressay'],
    sub: accountId,
    iat: now,
    exp: expiry,
  });
  const signature = sign(null, Buffer.from(`${head}.${body}`), privateKey);
  return `${head}.${body}.${signature.toString('base64url')}`;
}

const failure = (response, status, code) => reply(response, status, { error: { code, message: 'fake' } });

function reply(response, status, body) {
  response.writeHead(status, { 'Content-Type': 'application/json' });
  response.end(body === undefined ? '' : JSON.stringify(body));
}

async function readBody(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  return Buffer.concat(chunks).toString('utf8');
}

createServer(async (request, response) => {
  const url = new URL(request.url, origin);
  const route = `${request.method} ${url.pathname}`;
  const raw = await readBody(request);
  const body = request.headers['content-type']?.includes('json') && raw ? JSON.parse(raw) : {};
  console.log(route);

  if (route === 'POST /__control') {
    const value = (name) => url.searchParams.get(name);
    if (value('deviceLimit')) {
      state.otherDevices = [
        device(randomUUID(), 'Pressay Mac', 'macos'),
        device(randomUUID(), 'Pressay Mac', 'macos'),
        device(randomUUID(), 'Pressay PC', 'windows'),
      ];
    }
    if (value('revoked')) state.revoked = true;
    if (value('appleActive')) state.appleActive = value('appleActive') === '1';
    if (value('source')) {
      state.source = value('source');
      state.tier = state.source === 'none' ? 'free' : 'pro';
    }
    if (value('sandbox')) state.sandbox = value('sandbox');
    if (value('expiresIn')) state.expiresIn = Number(value('expiresIn'));
    return reply(response, 200, state);
  }
  if (route === 'GET /__state') return reply(response, 200, { ...state, sync: { changes: state.sync.changes.length } });

  // The OAuth issuer.
  if (route === 'GET /.well-known/oauth-authorization-server') {
    return reply(response, 200, {
      authorization_endpoint: `${origin}/authorize`,
      token_endpoint: `${origin}/token`,
      revocation_endpoint: `${origin}/revoke`,
    });
  }
  if (route === 'GET /authorize') {
    const callback = `pressay://oauth/callback?code=fake-code&state=${encodeURIComponent(url.searchParams.get('state'))}`;
    response.writeHead(302, { Location: callback });
    return response.end();
  }
  if (route === 'POST /token') {
    return reply(response, 200, {
      access_token: `fake-access-${randomUUID()}`,
      refresh_token: `fake-refresh-${randomUUID()}`,
      expires_in: 3600,
    });
  }
  if (route === 'POST /revoke') return reply(response, 200, {});

  // The API.
  if (state.deleted) return failure(response, 403, 'account_not_active');
  if (route === 'POST /v1/accounts/bootstrap') {
    state.bootstraps.push(body);
    if (body.platform !== 'ios' || body.appVariant !== 'app_store_ios') return failure(response, 422, 'invalid_request');
    if (state.revoked) return failure(response, 403, 'device_revoked');
    if (state.otherDevices.length >= 3) return failure(response, 409, 'device_limit_reached');
    return reply(response, 200, { accountId, created: false, device: { id: state.deviceId }, entitlement: {} });
  }
  if (route === 'GET /v1/me') {
    if (state.revoked) return failure(response, 403, 'device_revoked');
    return reply(response, 200, { accountId, email: 'testeur@example.test', status: 'active' });
  }
  if (route === 'GET /v1/entitlements') {
    if (state.revoked) return failure(response, 403, 'device_revoked');
    return reply(response, 200, { signedSnapshot: { token: entitlementToken(), keyId, expiresAt: iso(state.expiresIn) } });
  }
  if (route === 'GET /v1/devices') {
    const devices = [...state.otherDevices];
    if (!state.revoked && state.otherDevices.length < 3) devices.unshift(device(state.deviceId, 'Pressay iPhone', 'ios'));
    const revoked = state.revoked ? [{ ...device(state.deviceId, 'Pressay iPhone', 'ios'), revokedAt: iso(-60) }] : [];
    return reply(response, 200, { devices, limit: 3, revokedDevices: url.searchParams.get('include') === 'revoked' ? revoked : undefined });
  }
  const restore = /^POST \/v1\/devices\/([^/]+)\/restore$/.exec(route);
  if (restore) {
    if (state.otherDevices.length >= 3) return failure(response, 409, 'device_limit_reached');
    state.revoked = false;
    return reply(response, 200, {});
  }
  if (/^DELETE \/v1\/devices\//.test(route)) {
    state.otherDevices = state.otherDevices.filter((candidate) => !url.pathname.endsWith(candidate.id));
    return reply(response, 204);
  }
  if (route === 'POST /v1/billing/restore-app-store') {
    const [, payload] = String(body.signedTransaction).split('.');
    const transaction = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
    state.restores.push({
      idempotencyKey: request.headers['idempotency-key'],
      link: body.linkToCurrentAccount === true,
      productId: transaction.productId,
      appAccountToken: transaction.appAccountToken,
    });
    if (state.sandbox === 'refuse') return failure(response, 403, 'app_store_sandbox_not_allowed');
    if (state.restores.at(-1).appAccountToken !== accountId && !state.restores.at(-1).link) {
      return failure(response, 403, transaction.appAccountToken ? 'app_store_account_mismatch' : 'app_store_account_token_missing');
    }
    state.tier = 'pro';
    state.source = 'app_store';
    state.appleActive = true;
    return reply(response, 200, { restored: true });
  }
  if (route === 'GET /v1/billing/status') {
    const pro = state.tier === 'pro';
    return reply(response, 200, {
      provider: pro && state.source === 'app_store' ? 'app_store' : pro ? 'stripe' : null,
      interval: pro ? 'year' : null,
      status: pro ? 'trialing' : null,
      currentPeriodEndsAt: pro ? iso(7 * 86400) : null,
      cancelAtPeriodEnd: false,
    });
  }
  if (route === 'DELETE /v1/me') {
    if (state.appleActive && url.searchParams.get('acknowledgeAppleSubscription') !== 'true') {
      return failure(response, 409, 'apple_subscription_active');
    }
    state.deleted = true;
    return reply(response, 202);
  }

  // Encrypted sync: opaque envelopes, as on the real server.
  if (route === 'POST /v1/sync/devices/enroll') {
    state.sync.envelope ??= body.encryptedAccountKey ?? null;
    return reply(response, 201, { status: 'approved' });
  }
  if (route === 'GET /v1/sync/devices') {
    return reply(response, 200, {
      devices: [{
        id: state.deviceId,
        displayName: 'Pressay iPhone',
        publicKey: Buffer.alloc(32, 9).toString('base64'),
        status: 'approved',
      }],
    });
  }
  if (/^GET \/v1\/sync\/devices\/[^/]+\/envelope$/.test(route)) {
    return reply(response, 200, { encryptedAccountKey: state.sync.envelope });
  }
  if (route === 'POST /v1/sync/changes') {
    for (const change of body.changes) {
      state.sync.changes.push({
        ...change,
        sequenceId: state.sync.sequence++,
        sourceDeviceId: body.deviceId,
        createdAt: iso(),
        conflict: false,
      });
    }
    return reply(response, 201, { accepted: body.changes.length, conflicts: 0, cursor: state.sync.sequence - 1 });
  }
  if (route === 'GET /v1/sync/changes') {
    const after = Number(url.searchParams.get('after') ?? 0);
    return reply(response, 200, {
      changes: state.sync.changes.filter((change) => change.sequenceId > after),
      nextCursor: state.sync.sequence - 1,
      hasMore: false,
    });
  }
  if (route === 'PUT /v1/sync/recovery') return reply(response, 204);

  return failure(response, 404, 'cloud_not_found');
}).listen(port, '127.0.0.1', () => {
  console.log(`fake cloud on ${origin}`);
  console.log(`-PressayCloudURL ${origin} -PressayEntitlementKey ${publicRaw} -PressayEntitlementKeyID ${keyId}`);
  console.log(`account ${createHash('sha256').update(accountId).digest('hex').slice(0, 8)} (test data only)`);
});
