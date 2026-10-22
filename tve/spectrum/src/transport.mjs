import http from 'node:http';
import https from 'node:https';
import tls from 'node:tls';
import {BridgeError, boundedRequest} from './http.mjs';

const CONTROL_HOSTS = new Set([
  'apis.spectrum.net', 'apis-vid.spectrum.net', 'apis-drm.spectrum.net', 'pi-lite.spectrum.net',
]);
const MAX_RESPONSE_BYTES = 64 * 1024 * 1024;
const MAX_REQUEST_BYTES = 8 * 1024 * 1024;

function proxySettings(value) {
  try {
    if (typeof value !== 'string' || value.length > 4096 || /[\u0000-\u0020\u007f]/u.test(value)) throw new Error();
    const url = new URL(value);
    if (url.protocol !== 'http:' || !url.hostname || (url.pathname !== '/' && url.pathname !== '') || url.search || url.hash || url.port === '0') throw new Error();
    let authorization;
    if (url.username || url.password) {
      const username = decodeURIComponent(url.username), password = decodeURIComponent(url.password);
      if (!username || username.includes(':') || /[\u0000-\u001f\u007f]/u.test(username + password)) throw new Error();
      authorization = `Basic ${Buffer.from(`${username}:${password}`).toString('base64')}`;
    }
    return {hostname: url.hostname.replace(/^\[|\]$/g, ''), port: Number(url.port || 80), authorization};
  } catch {
    // Never include a private proxy URL, password, or parser exception in logs.
    throw new BridgeError();
  }
}

/**
 * Route only Spectrum control requests through a private HTTP CONNECT proxy.
 * TLS terminates at Spectrum: the proxy sees the destination but not provider
 * credentials or DRM exchanges. Media fetches must retain boundedRequest.
 */
export function createControlRequest(controlProxyUrl) {
  if (controlProxyUrl === undefined || controlProxyUrl === null || controlProxyUrl === '') return boundedRequest;
  const proxy = proxySettings(controlProxyUrl);
  return function controlRequest({url, method = 'GET', headers = {}, body, maxBytes = 2 * 1024 * 1024, timeoutMs = 15000}) {
    return new Promise((resolve, reject) => {
      let target, requestBody;
      try {
        target = new URL(url);
        if (target.protocol !== 'https:' || target.username || target.password || target.hash ||
            (target.port && target.port !== '443') || !CONTROL_HOSTS.has(target.hostname) ||
            !Number.isSafeInteger(maxBytes) || maxBytes < 0 || maxBytes > MAX_RESPONSE_BYTES ||
            !Number.isFinite(timeoutMs) || timeoutMs <= 0 || timeoutMs > 120000) throw new Error();
        if (body !== undefined && body !== null) {
          if (typeof body !== 'string' && !Buffer.isBuffer(body) && !(body instanceof Uint8Array)) throw new Error();
          if ((typeof body === 'string' ? Buffer.byteLength(body) : body.byteLength) > MAX_REQUEST_BYTES) throw new Error();
          requestBody = Buffer.from(body);
        }
      } catch { reject(new BridgeError()); return; }

      let finished = false, connectRequest, tunnel, secureSocket, originRequest, responseStream, agent;
      const destroy = () => {
        responseStream?.destroy(); originRequest?.destroy(); secureSocket?.destroy();
        tunnel?.destroy(); connectRequest?.destroy(); agent?.destroy();
      };
      const fail = () => {
        if (finished) return;
        finished = true; clearTimeout(timer); destroy(); reject(new BridgeError());
      };
      // This deadline covers CONNECT, TLS, request transmission and response body.
      // A failed tunnel never retries over the server's ordinary internet route.
      const timer = setTimeout(fail, timeoutMs);
      try {
        const connectHeaders = {Host: `${target.hostname}:443`};
        if (proxy.authorization) connectHeaders['Proxy-Authorization'] = proxy.authorization;
        connectRequest = http.request({
          hostname: proxy.hostname, port: proxy.port, method: 'CONNECT',
          path: `${target.hostname}:443`, headers: connectHeaders,
          agent: false, maxHeaderSize: 16 * 1024,
        });
        connectRequest.on('error', fail);
        connectRequest.on('response', fail);
        connectRequest.on('connect', (response, socket, head) => {
          tunnel = socket;
          if (finished) { socket.destroy(); return; }
          socket.on('error', fail);
          if (response.statusCode !== 200 || head.length !== 0) { fail(); return; }
          try {
            secureSocket = tls.connect({
              socket, servername: target.hostname, rejectUnauthorized: true,
              ALPNProtocols: ['http/1.1'], minVersion: 'TLSv1.2',
            });
            secureSocket.on('error', fail);
            secureSocket.on('secureConnect', () => {
              if (finished) { secureSocket.destroy(); return; }
              try {
                // A fresh agent owns this one tunnel; neither credentials nor a
                // socket can be reused for a different upstream destination.
                agent = new https.Agent({keepAlive: false, maxSockets: 1});
                agent.createConnection = (_options, callback) => callback(null, secureSocket);
                const originHeaders = Object.fromEntries(Object.entries(headers).filter(([name]) => !['proxy-authorization', 'proxy-connection'].includes(name.toLowerCase())));
                originRequest = https.request(target, {method, headers: originHeaders, agent, maxHeaderSize: 128 * 1024}, response => {
                  responseStream = response;
                  let size = 0; const chunks = [];
                  if (Number(response.headers['content-length']) > maxBytes) { fail(); return; }
                  response.on('data', chunk => {
                    if (finished) return;
                    size += chunk.length;
                    if (size > maxBytes) { fail(); return; }
                    chunks.push(chunk);
                  });
                  response.on('error', fail);
                  response.on('aborted', fail);
                  response.on('end', () => {
                    if (finished) return;
                    finished = true; clearTimeout(timer);
                    const result = {status: response.statusCode, headers: response.headers, body: Buffer.concat(chunks), url: target.href};
                    destroy(); resolve(result);
                  });
                });
                originRequest.on('error', fail);
                if (requestBody) originRequest.write(requestBody);
                originRequest.end();
              } catch { fail(); }
            });
          } catch { fail(); }
        });
        connectRequest.end();
      } catch { fail(); }
    });
  };
}
