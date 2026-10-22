import {createHash, randomBytes} from 'node:crypto';
import {BridgeError} from './http.mjs';

const ORIGIN = 'https://apis.spectrum.net';
const CLIENT_ID = 'stva-ovp';
const MAX_AUTH_BYTES = 256 * 1024;
export const authText = value => typeof value === 'string' && value.length > 0 && value.length <= 65536 && !/[\r\n\0]/.test(value);
const signIn = () => new BridgeError('sign_in_required', 401);
const hasVerifier = auth => authText(auth.deviceVerifier);
const clientHeaders = auth => ({'x-client-id': CLIENT_ID, 'x-client-device-id': auth.deviceId});

function parse(response) {
  // A transport outage or malformed success response is not evidence that an
  // account was signed out. Never return provider bodies or tokens in errors.
  if (response.status >= 500 || response.status === 429) throw new BridgeError();
  let value;
  try { value = JSON.parse(response.body); } catch { throw new BridgeError(); }
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new BridgeError();
  return value;
}

function requireSuccess(response, value) {
  if (response.status === 200) return;
  if ([401,403].includes(response.status) || (response.status === 400 && ['invalid_grant','invalid_token'].includes(value.error))) throw signIn();
  throw new BridgeError();
}

async function post(path, fields, auth, request, extraHeaders = {}) {
  const body = Buffer.from(new URLSearchParams(fields).toString());
  const response = await request({url: ORIGIN + path, method: 'POST',
    headers: {...clientHeaders(auth), 'Content-Type': 'application/x-www-form-urlencoded', 'Content-Length': body.length, ...extraHeaders},
    body, maxBytes: MAX_AUTH_BYTES});
  // Authentication status remains meaningful when a gateway omits its JSON
  // error body. Let the caller validate the saved session once in that case.
  if ([401,403].includes(response.status)) throw signIn();
  const value = parse(response);
  requireSuccess(response, value);
  return value;
}

function tokenResult(value, current, now, {nonce, verifier} = {}) {
  const ttl = Number(value.expires_in);
  if (!authText(value.access_token) || !authText(value.refresh_token) || !Number.isFinite(ttl) || ttl <= 0 || !Number.isSafeInteger(Math.ceil(now() + ttl * 1000))) throw new BridgeError();
  const next = {...current, accessToken: value.access_token, refreshToken: value.refresh_token, expiresAt: now() + ttl * 1000};
  let claims;
  if (value.id_token !== undefined) {
    if (!authText(value.id_token)) throw new BridgeError();
    const parts = value.id_token.split('.');
    if (parts.length !== 3 || !/^[A-Za-z0-9_-]+$/.test(parts[1])) throw new BridgeError();
    try { claims = JSON.parse(Buffer.from(parts[1], 'base64url')); } catch { throw new BridgeError(); }
    if (!claims || typeof claims !== 'object' || Array.isArray(claims)) throw new BridgeError();
  }
  // This token response comes directly from the fixed, TLS-verified provider
  // endpoint. Bind the authorization-code exchange to our fresh request nonce.
  if (nonce !== undefined && claims?.nonce !== nonce) throw new BridgeError();
  if (claims?.context_token !== undefined) {
    if (!authText(claims.context_token)) throw new BridgeError();
    next.contextToken = claims.context_token;
  }
  const rotatedVerifier = value.deviceVerifier ?? value.xoauth_device_verifier ?? verifier;
  if (rotatedVerifier !== undefined) {
    if (!authText(rotatedVerifier)) throw new BridgeError();
    next.deviceVerifier = rotatedVerifier;
  }
  return next;
}

async function refreshToken(auth, request, now) {
  return tokenResult(await post('/auth/oauth/v2/token', {client_id: CLIENT_ID, grant_type: 'refresh_token', refresh_token: auth.refreshToken}, auth, request), auth, now);
}

async function verifierAuth(auth, request, now) {
  if (!hasVerifier(auth)) throw signIn();
  const verifier = randomBytes(96).toString('base64url');
  const nonce = randomBytes(24).toString('base64url');
  const headers = {Authorization: `Bearer ${auth.deviceVerifier}`};
  if (authText(auth.contextToken)) headers['x-context-token'] = auth.contextToken;
  const authorization = await post('/auth/oauth/v2/consumer/video/deviceverifier/auth', {
    client_id: CLIENT_ID, response_type: 'code', state: 'state', client_device_id: auth.deviceId,
    nonce, supportSMB: 'false', supportMDUBulk: 'false',
    code_challenge: createHash('sha256').update(verifier).digest('base64url'), code_challenge_method: 'S256',
  }, auth, request, headers);
  if (!authText(authorization.authCode)) throw new BridgeError();
  const value = await post('/auth/oauth/v2/token', {
    client_id: CLIENT_ID, grant_type: 'authorization_code', code: authorization.authCode,
    client_device_id: auth.deviceId, code_verifier: verifier,
  }, auth, request);
  return tokenResult(value, auth, now, {nonce, verifier: authorization.deviceVerifier ?? authorization.xoauth_device_verifier});
}

async function validate(auth, request, now, allowRefresh) {
  const headers = {...clientHeaders(auth), 'x-access-token': auth.accessToken,
    'x-refresh-token': auth.refreshToken, 'x-device-verifier': auth.deviceVerifier};
  if (authText(auth.contextToken)) headers['x-context-token'] = auth.contextToken;
  const response = await request({url: ORIGIN + '/auth/oauth/v2/validateSession?getLocation=false', headers, maxBytes: MAX_AUTH_BYTES});
  let value;
  try { value = parse(response); }
  catch (error) { if ([401,403].includes(response.status)) throw signIn(); throw error; }
  if (![200,401,403].includes(response.status)) { requireSuccess(response, value); throw new BridgeError(); }
  if (response.status === 200 && value.isValidSession === true) {
    const ttl = Number(value.accessTokenTTL);
    if (!Number.isFinite(ttl) || ttl <= 0 || !Number.isSafeInteger(Math.ceil(now() + ttl * 1000))) throw new BridgeError();
    return {...auth, expiresAt: now() + ttl * 1000};
  }
  // Only an explicit provider direction can authorize saved-device renewal.
  // STANDARD_AUTH, COUNTERMEASURES, or any unknown/missing action require login.
  if (response.status !== 403 && value.nextAction === 'DEVICEVERIFIER_AUTH') return verifierAuth(auth, request, now);
  if (response.status !== 403 && value.nextAction === 'REFRESH_AUTH' && allowRefresh) return refreshToken(auth, request, now);
  throw signIn();
}

export async function renewAuth(current, {request, now = Date.now}) {
  if (hasVerifier(current) && Number(current.expiresAt) <= now()) return validate(current, request, now, true);
  try { return await refreshToken(current, request, now); }
  catch (error) {
    if (error instanceof BridgeError && error.code === 'sign_in_required' && hasVerifier(current)) return validate(current, request, now, false);
    throw error;
  }
}
