import https from 'node:https';
import { isIP } from 'node:net';

export class BridgeError extends Error {
  constructor(code = 'source_unavailable', status = 503) { super(code); this.code = code; this.status = status; }
}
export const MESSAGES = Object.freeze({
  sign_in_required: 'Sign in to Spectrum again in server settings.',
  channel_not_entitled: 'This channel is not included in the Spectrum subscription.',
  home_network_required: 'Spectrum requires its home internet connection for this channel.',
  location_restricted: 'Spectrum does not make this channel available at the server’s current location.',
  concurrency_limit: 'Spectrum’s simultaneous stream limit has been reached. Close another stream and retry.',
  native_update_required: 'Update Velvet to use native Spectrum playback.',
  drm_unavailable: 'The device could not obtain permission to play this protected stream.',
  source_unavailable: 'Spectrum could not start this channel. Try again shortly.',
  session_ended: 'This live session ended. Choose the channel again.',
  invalid_request: 'Invalid live playback request.',
});
export function providerError(status, body) {
  let value; try { value = JSON.parse(body.toString('utf8')); } catch { value = null; }
  const flags = new Set();
  const visit = (item, depth = 0) => {
    if (!item || typeof item !== 'object' || depth > 5) return;
    for (const [key, child] of Object.entries(item).slice(0, 100)) {
      if (child === true) flags.add(key);
      if (typeof child === 'string' && child.length < 80 && ['code','errorCode','error_code'].includes(key)) flags.add(child);
      if (typeof child === 'object') visit(child, depth + 1);
    }
  };
  visit(value);
  if (status === 401) return new BridgeError('sign_in_required', 401);
  if (status === 429 || flags.has('concurrencyLimit')) return new BridgeError('concurrency_limit', 429);
  if (flags.has('blockedOOH')) return new BridgeError('home_network_required', 403);
  if (flags.has('unentitled')) return new BridgeError('channel_not_entitled', 403);
  if (flags.has('dmaMismatch') || flags.has('InUSAOnly')) return new BridgeError('location_restricted', 403);
  if (flags.has('blockedDRM')) return new BridgeError('drm_unavailable', 503);
  return new BridgeError();
}
export function boundedRequest({ url, method = 'GET', headers = {}, body, maxBytes = 2 * 1024 * 1024, timeoutMs = 15000 }) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    if (u.protocol !== 'https:' || u.username || u.password || u.hash || (u.port && u.port !== '443')) return reject(new BridgeError());
    let finished = false, timer;
    const fail = () => {
      if (finished) return;
      finished = true; clearTimeout(timer); request.destroy(); reject(new BridgeError());
    };
    const request = https.request(u, {method, headers, maxHeaderSize: 128 * 1024}, response => {
      let size = 0; const chunks = [];
      if (Number(response.headers['content-length']) > maxBytes) return fail();
      response.on('data', chunk => { size += chunk.length; if (size > maxBytes) return fail(); chunks.push(chunk); });
      response.on('error', fail);
      response.on('end', () => {
        if (finished) return;
        finished = true; clearTimeout(timer);
        resolve({status: response.statusCode, headers: response.headers, body: Buffer.concat(chunks), url: u.href});
      });
    });
    timer = setTimeout(fail, timeoutMs);
    request.on('error', fail);
    if (body) request.write(body);
    request.end();
  });
}
const CDN_HOSTS = ['edge-mm.spectrum.net', '*.edge-mm.spectrum.com', '*.stvacdn.spectrum.com'];
export function cdnUrl(value, extraHosts = []) {
  let u; try { u = new URL(value); } catch { throw new BridgeError(); }
  if (u.protocol !== 'https:' || u.username || u.password || u.hash || (u.port && u.port !== '443') || isIP(u.hostname.replace(/^\[|\]$/g,'')) ||
      ![...CDN_HOSTS, ...extraHosts].some(host => host.startsWith('*.') ? u.hostname.endsWith(host.slice(1)) && u.hostname !== host.slice(2) : u.hostname === host)) throw new BridgeError();
  return u;
}
export async function fetchCdn(url, {request = boundedRequest, maxBytes = 2 * 1024 * 1024, headers = {}, extraHosts = []} = {}) {
  let u = cdnUrl(url, extraHosts); const deadline = Date.now() + 20000;
  const forwarded = {};
  if (headers.Range && /^bytes=\d{1,20}-\d{0,20}$/.test(headers.Range)) forwarded.Range = headers.Range;
  for (let redirect = 0; redirect <= 3; redirect++) {
    if (Date.now() >= deadline) throw new BridgeError();
    // Provider access tokens, ASTs, cookies and backend bearer tokens never reach a CDN.
    const response = await request({url: u, headers: forwarded, maxBytes, timeoutMs: deadline - Date.now()});
    if ([301,302,303,307,308].includes(response.status)) {
      if (redirect === 3 || typeof response.headers.location !== 'string') throw new BridgeError();
      u = cdnUrl(new URL(response.headers.location, u), extraHosts); continue;
    }
    if (response.status !== 200 && response.status !== 206) throw providerError(response.status, response.body);
    return {...response, url: u.href};
  }
  throw new BridgeError();
}
