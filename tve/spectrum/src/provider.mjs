import {readFile, writeFile, rename, unlink} from 'node:fs/promises';
import {randomBytes} from 'node:crypto';
import {BridgeError, boundedRequest, providerError} from './http.mjs';
import {authText, renewAuth} from './auth.mjs';

const API = 'https://apis-vid.spectrum.net';
const LOCATION = 'https://apis.spectrum.net/pinxt/customer/location/v1';
const LOCATION_TTL = 15 * 60 * 1000;
const LOCATION_FIELDS = ['behindOwnModem','inMarket','stateAbbr','behindTheRouter'];
const AUTH_FIELDS = ['accessToken','refreshToken','deviceId'];
const AUTH_RENEW_EARLY = 10 * 60 * 1000;
const AUTH_RETRY_MIN = 60 * 1000;
const AUTH_RETRY_MAX = 15 * 60 * 1000;
const tokenText = authText;
function locationValue(value) {
  if (!value || typeof value!=='object' || Array.isArray(value) || typeof value.behindOwnModem!=='boolean' || typeof value.inMarket!=='boolean') throw new BridgeError();
  const location = {behindOwnModem:value.behindOwnModem,inMarket:value.inMarket};
  if (value.stateAbbr!==undefined && value.stateAbbr!==null && value.stateAbbr!=='') {
    if (typeof value.stateAbbr!=='string' || !/^[A-Z]{2}$/.test(value.stateAbbr)) throw new BridgeError();
    location.stateAbbr=value.stateAbbr;
  }
  if (value.behindTheRouter!==undefined && value.behindTheRouter!==null) {
    if (typeof value.behindTheRouter!=='boolean') throw new BridgeError();
    location.behindTheRouter=value.behindTheRouter;
  }
  return Object.freeze(location);
}
export class SpectrumProvider {
  constructor(config, {request = boundedRequest, now = Date.now} = {}) {
    this.config = config; this.request = request; this.now = now;
    this.auth = null; this.pendingAuth = null; this.refreshing = null; this.cached = null; this.loading = null;
    this.locationCache = null; this.locationLoading = null;
    this.authMaintenance = null;
  }
  startAuthMaintenance({onError=()=>{},setTimer=setTimeout,clearTimer=clearTimeout}={}) {
    if (this.authMaintenance) return this.authMaintenance.stop;
    const state={stopped:false,timer:null,work:Promise.resolve(),retry:AUTH_RETRY_MIN};
    const schedule=delay=>{
      if(state.stopped)return;
      state.timer=setTimer(()=>{state.timer=null;state.work=run();return state.work;},delay);
      state.timer.unref?.();
    };
    const run=async()=>{
      if(state.stopped)return;
      try {
        const auth=await this.loadAuth();
        if(state.stopped)return;
        const expiry=Number(auth.expiresAt);
        // Renew while idle, before the saved refresh token expires. Reuse the
        // same singleflight and atomic persistence as foreground requests.
        if(this.pendingAuth||!Number.isFinite(expiry)||expiry<=this.now()+AUTH_RENEW_EARLY)await this.refresh();
        state.retry=AUTH_RETRY_MIN;
        const next=Number(this.auth?.expiresAt)-this.now()-AUTH_RENEW_EARLY;
        // Short/invalid provider lifetimes cannot create a tight refresh loop.
        schedule(Math.max(AUTH_RETRY_MIN,Math.min(Number.isFinite(next)?next:AUTH_RETRY_MIN,3600000)));
      } catch(error) {
        try{onError(error);}catch{}
        if(error instanceof BridgeError&&error.code==='sign_in_required') {
          // Respect explicit login/countermeasure decisions. A newly provisioned
          // session is loaded on service restart; never keep retrying a denial.
          state.stopped=true;
        } else {
          schedule(state.retry);
          state.retry=Math.min(state.retry*2,AUTH_RETRY_MAX);
        }
      }
    };
    const stop=async()=>{
      state.stopped=true;
      if(state.timer!==null){clearTimer(state.timer);state.timer=null;}
      // Let a token rotation finish and persist; cancelling between the provider
      // response and rename could otherwise discard its only valid refresh token.
      await state.work.catch(()=>{});
      await this.refreshing?.catch(()=>{});
    };
    this.authMaintenance={stop};schedule(0);return stop;
  }
  async loadAuth() {
    if (this.auth) return this.auth;
    let auth; try { auth = JSON.parse(await readFile(this.config.authFile, 'utf8')); } catch { throw new BridgeError('sign_in_required', 401); }
    if (!auth || typeof auth !== 'object' || AUTH_FIELDS.some(key => !tokenText(auth[key]))) throw new BridgeError('sign_in_required', 401);
    this.auth = auth; return auth;
  }
  async refresh() {
    if (this.refreshing) return this.refreshing;
    this.refreshing = (async () => {
      const current = await this.loadAuth();
      // Retain an already rotated credential while retrying a failed disk write;
      // never consume its previous refresh token a second time.
      const next = this.pendingAuth ?? await renewAuth(current, {request:this.request, now:this.now});
      this.pendingAuth = next;
      const temporary = this.config.authFile + '.' + randomBytes(8).toString('hex') + '.tmp';
      try {
        await writeFile(temporary, JSON.stringify(next), {mode:0o600,flag:'wx'});
        await rename(temporary, this.config.authFile);
      } catch {
        await unlink(temporary).catch(()=>{});
        throw new BridgeError();
      }
      this.auth = next; this.pendingAuth = null; return next;
    })().finally(() => { this.refreshing = null; });
    return this.refreshing;
  }
  async token() {
    const auth = await this.loadAuth();
    return Number(auth.expiresAt) && Number(auth.expiresAt) < this.now()+120000 ? this.refresh() : auth;
  }
  async api(path, {method = 'GET', query = {}, data, retry = true, timeoutMs = 15000} = {}) {
    if (typeof path!=='string' || !path.startsWith('/') || path.startsWith('//') || /[\\?#\r\n\0]/.test(path)) throw new BridgeError();
    const u = new URL(path, API);
    if (u.origin !== API) throw new BridgeError();
    for (const [key,value] of Object.entries(query)) if (value !== undefined && value !== null) u.searchParams.set(key, String(value));
    return this.#json(u,{method,data,retry,timeoutMs});
  }
  async #json(u, {method = 'GET', data, retry = true, timeoutMs = 15000, maxBytes = 4*1024*1024} = {}) {
    const auth = await this.token();
    const body = data === undefined ? undefined : Buffer.from(JSON.stringify(data));
    const headers = {Authorization:`Bearer ${auth.accessToken}`,device_id:auth.deviceId};
    if (body) Object.assign(headers, {'Content-Type':'application/json','Content-Length':body.length});
    const response = await this.request({url:u, method, headers, body, maxBytes,timeoutMs});
    if (response.status === 401 && retry) {
      if(this.auth?.accessToken===auth.accessToken)await this.refresh();
      return this.#json(u,{method,data,retry:false,timeoutMs,maxBytes});
    }
    if (response.status < 200 || response.status >= 300) throw providerError(response.status,response.body);
    let value = null; if (response.body.length) { try { value=JSON.parse(response.body); } catch { throw new BridgeError(); } }
    return {value,headers:response.headers};
  }
  async location(force = false) {
    if (this.locationLoading) return this.locationLoading;
    if (!force && this.locationCache && this.now()-this.locationCache.at>=0 && this.now()-this.locationCache.at<LOCATION_TTL) return this.locationCache.value;
    // A failed refresh must not resurrect captured or expired home-network flags.
    this.locationCache = null;
    this.locationLoading = (async () => {
      const {value} = await this.#json(new URL(LOCATION),{maxBytes:256*1024});
      const location = locationValue(value);
      this.locationCache = {at:this.now(),value:location};
      return location;
    })().finally(() => {this.locationLoading=null;});
    return this.locationLoading;
  }
  async channels(force = false) {
    if (!force && this.cached && this.now()-this.cached.at<60000) return this.cached.items;
    if (this.loading) return this.loading;
    this.loading = (async () => {
      const {value} = await this.api('/lantern/lrs/api/smarttv/channels/v3',{query:{streamVersion:5}});
      if (!Array.isArray(value) || value.length > 2000) throw new BridgeError();
      const aliases = new Map((this.config.channelAliases || []).map(alias => [String(alias.entitlementId),alias]));
      const seen = new Set(), ids = new Set(), items = [];
      for (const entry of value) {
        const service = String(entry.entitlementId ?? '');
        if (entry.online !== true || entry.onlineEntitled !== true || !/^[A-Za-z0-9_-]{1,128}$/.test(service) || seen.has(service)) continue;
        const alias = aliases.get(service), id = alias?.id || `spectrum-${service}`;
        if (!/^[A-Za-z0-9_-]{1,120}$/.test(id)||ids.has(id)) throw new BridgeError();
        ids.add(id);
        seen.add(service);
        const name = String(alias?.name || entry.networkName || entry.callSign || 'Spectrum channel').trim().slice(0,160);
        let logoUrl = null;
        try {
          if(typeof entry.logoUri==='string'&&entry.logoUri){
            const u = new URL(entry.logoUri,'https://cdnimg.spectrum.net');
            if(u.protocol==='https:'&&!u.username&&!u.password&&!u.hash)logoUrl=u.href;
          }
        } catch {}
        const numbers = Array.isArray(entry.channelNumbers) ? entry.channelNumbers : [];
        const number = numbers.find(n => typeof n==='string' || typeof n==='number');
        items.push({service,guideId:String(entry.tmsGuideId??''),channel:{id,name,number:number===undefined?null:String(number),logoUrl,group:'Spectrum'}});
      }
      if (!items.length) throw new BridgeError('channel_not_entitled',403);
      this.cached = {at:this.now(),items}; return items;
    })().finally(() => {this.loading=null;});
    return this.loading;
  }
  async tune(entry, format) {
    const location = this.config.refreshLocation===true ? await this.location() : undefined;
    const auth = await this.token();
    const query = {...this.config.tuneQuery,adID:auth.deviceId};
    for (const key of ['aegis','sessionId','streamSessionId']) delete query[key];
    if (location) {
      for (const key of LOCATION_FIELDS) delete query[key];
      Object.assign(query,location);
    }
    const deviceCapabilities = {packaging:format==='fairplay'?'hls':'dash',drm:format==='fairplay'?'fairplay':'cenc',videoCodecs:['avc'],audioCodecs:format==='fairplay'?['aac']:['aac','ac3','eac3']};
    const result = await this.api(`/lantern/foc-ipvs/api/smarttv/stream/live/v6/${entry.service}`,{method:'POST',query,data:{deviceCapabilities}});
    // Keep the exact GET-derived state used for this tune. A provider-observed
    // change invalidates future tunes instead of claiming a new location locally.
    const initial = result.value?.initLocation;
    if (location && initial && this.locationCache?.value===location && ['behindOwnModem','inMarket','stateAbbr','behindTheRouter'].some(key=>
      Object.hasOwn(location,key) && typeof initial[key]===typeof location[key] && initial[key]!==location[key])) this.locationCache=null;
    return {...result,location};
  }
  async stop(aegis) { if (aegis) await this.api('/ipvs/api/smarttv/aegis/v1',{method:'DELETE',query:{aegis},timeoutMs:5000}); }
  async renew(aegis) { return (await this.api('/ipvs/api/smarttv/aegis/v1/refresh',{query:{aegis}})).value; }
  async ast(service, feed) {
    if (!/^[A-Za-z0-9._-]{1,128}$/.test(service) || !/^[A-Za-z0-9._-]{1,256}$/.test(feed)) throw new BridgeError();
    return (await this.api(`/lantern/foc-ipvs/api/smarttv/ast/live/v2/${service}/${feed}`)).headers['x-set-ast'];
  }
  async license(format, session, challenge, originalKeyQuery) {
    const auth = await this.token();
    const endpoint = format==='fairplay'?'getckc':'widevine';
    const u = new URL(`https://apis-drm.spectrum.net/drm/licenseServer/${endpoint}/v2`);
    u.searchParams.set('contentType','LINEAR');u.searchParams.set('streamSessionId',session.playerId);
    // Original key query comes only from this owned session's provider manifest.
    if (format==='fairplay') {
      if (typeof originalKeyQuery!=='string' || originalKeyQuery.length>8192 || /[\r\n#]/.test(originalKeyQuery)) throw new BridgeError('invalid_request',400);
      for (const [key] of new URLSearchParams(originalKeyQuery)) {
        if (['contenttype','streamsessionid'].includes(key.toLowerCase())) throw new BridgeError();
      }
      // Keep provider encoding byte-for-byte: ContentId is a raw identifier.
      u.search += '&' + originalKeyQuery;
    }
    const response = await this.request({url:u,method:'POST',headers:{Authorization:`Bearer ${auth.accessToken}`,'AST-Authorization':session.ast,'Content-Length':challenge.length},body:challenge,maxBytes:1024*1024});
    if (response.status!==200) throw providerError(response.status,response.body);
    if (!response.body.length) throw new BridgeError('drm_unavailable',503);
    return response.body;
  }
}
