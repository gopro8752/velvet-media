import {createHash, randomBytes} from 'node:crypto';
import {BridgeError} from './http.mjs';

const ORIGIN = 'https://apis.spectrum.net';
const CLIENT_ID = 'stva-ovp';
const MAX_AUTH_BYTES = 256 * 1024;
export const authText = value => typeof value === 'string' && value.length > 0 && value.length <= 65536 && !/[\r\n\0]/.test(value);
export const authFailure = (reason = 'authentication_rejected', step = null) => {
  const error = new BridgeError('sign_in_required', 401);
  error.authReason = reason; error.authStep = step; return error;
};
const signIn = authFailure;
const suspiciousCodes = new Set([1300,1301,1302,1303,1304,1305,1306]);
function rejection(response, value, step) {
  // Spectrum's web client stops on these account/security decisions rather than
  // attempting another credential. Inspect only known fields; never retain a body.
  const action = value?.nextAction;
  const providerCode = Number(value?.resultCode ?? value?.errorCode ?? value?.code ?? response.headers?.['x-pi-auth-failure']);
  if (action === 'COUNTERMEASURES' || suspiciousCodes.has(providerCode)) return signIn('provider_challenge', step);
  if (action === 'STANDARD_AUTH') return signIn('interactive_sign_in_required', step);
  if (response.status === 403) return signIn('authentication_forbidden', step);
  if (response.status === 401 || (response.status === 400 && ['invalid_grant','invalid_token'].includes(value?.error))) return signIn('authentication_rejected', step);
  return null;
}
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

async function post(path, fields, auth, request, extraHeaders = {}, step) {
  const body = Buffer.from(new URLSearchParams(fields).toString());
  let response;
  try {
    response = await request({url: ORIGIN + path, method: 'POST',
      headers: {...clientHeaders(auth), 'Content-Type': 'application/x-www-form-urlencoded', 'Content-Length': body.length, ...extraHeaders},
      body, maxBytes: MAX_AUTH_BYTES});
    let value;
    try { value = parse(response); }
    catch (error) {
      if ([401,403].includes(response.status)) throw rejection(response, null, step);
      throw error;
    }
    const denied = rejection(response, value, step);
    if (denied) throw denied;
    if (response.status !== 200) throw new BridgeError();
    return value;
  } catch (error) {
    if (error instanceof BridgeError) {error.authStep = step; throw error;}
    const safe = new BridgeError(); safe.authStep = step; throw safe;
  }
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
  return tokenResult(await post('/auth/oauth/v2/token', {client_id: CLIENT_ID, grant_type: 'refresh_token', refresh_token: auth.refreshToken}, auth, request, {}, 'refresh_token'), auth, now);
}

async function verifierAuth(auth, request, now) {
  if (!hasVerifier(auth)) throw signIn();
  const verifier = randomBytes(96).toString('base64url');
  const nonce = randomBytes(24).toString('base64url');
  const headers = {Authorization: `Bearer ${auth.deviceVerifier}`};
  // Automatic verifier renewal starts a new authorization. Like the web
  // client's autoRefreshToken path, do not attach an expired session context.
  const authorization = await post('/auth/oauth/v2/consumer/video/deviceverifier/auth', {
    client_id: CLIENT_ID, response_type: 'code', state: 'state', client_device_id: auth.deviceId,
    nonce, supportSMB: 'false', supportMDUBulk: 'false',
    code_challenge: createHash('sha256').update(verifier).digest('base64url'), code_challenge_method: 'S256',
  }, auth, request, headers, 'device_verifier');
  if (!authText(authorization.authCode)) throw new BridgeError();
  const value = await post('/auth/oauth/v2/token', {
    client_id: CLIENT_ID, grant_type: 'authorization_code', code: authorization.authCode,
    client_device_id: auth.deviceId, code_verifier: verifier,
  }, auth, request, {}, 'authorization_code');
  return tokenResult(value, auth, now, {nonce, verifier: authorization.deviceVerifier ?? authorization.xoauth_device_verifier});
}

export async function renewAuth(current, {request, now = Date.now, method = 'automatic', onMethod = () => {}}) {
  // This is the provider web client's automatic lifecycle, not resumeAuth's
  // validateSession path. A validation response can demand STANDARD_AUTH for an
  // expired access session even when its independent saved-device credential works.
  const expired = Number.isFinite(Number(current.expiresAt)) && Number(current.expiresAt) <= now();
  if (method === 'device_verifier' || (expired && hasVerifier(current))) {
    onMethod('device_verifier');
    return verifierAuth(current, request, now);
  }
  onMethod('refresh_token');
  try { return await refreshToken(current, request, now); }
  catch (error) {
    // Outages/malformed responses are retried later. Only an ordinary invalid
    // refresh credential can fall back; account challenges and forbidden access
    // require the provider's interactive sign-in flow.
    if (error instanceof BridgeError && error.authReason === 'authentication_rejected' && hasVerifier(current)) {
      onMethod('device_verifier');
      return verifierAuth(current, request, now);
    }
    throw error;
  }
}
