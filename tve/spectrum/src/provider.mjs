import {readFile, writeFile, rename, unlink, stat} from 'node:fs/promises';
import {randomBytes, createHash} from 'node:crypto';
import {BridgeError, boundedRequest, providerError} from './http.mjs';
import {authText, renewAuth, authFailure} from './auth.mjs';

const API = 'https://apis-vid.spectrum.net';
const LOCATION = 'https://apis.spectrum.net/pinxt/customer/location/v1';
const LOCATION_TTL = 15 * 60 * 1000;
const LOCATION_FIELDS = ['behindOwnModem','inMarket','stateAbbr','behindTheRouter'];
const AUTH_FIELDS = ['accessToken','refreshToken','deviceId'];
const AUTH_RENEW_EARLY = 10 * 60 * 1000;
const AUTH_RETRY_MIN = 60 * 1000;
const AUTH_RETRY_MAX = 15 * 60 * 1000;
const tokenText = authText;
const AUTH_REASONS=new Set(['authentication_rejected','authentication_forbidden','interactive_sign_in_required','provider_challenge','missing_session','provider_unavailable','credential_persistence_failed']);
const AUTH_STEPS=new Set(['refresh_token','device_verifier','authorization_code']);
const validTime=value=>Number.isSafeInteger(Number(value))&&Number(value)>0?Number(value):null;
const fingerprint=auth=>createHash('sha256').update(JSON.stringify(auth)).digest('hex');
async function boundedFile(path,limit){const info=await stat(path);if(!info.isFile()||info.size>limit)throw new BridgeError();const value=await readFile(path,'utf8');if(Buffer.byteLength(value)>limit)throw new BridgeError();return value;}
async function readAuth(path){
  try {
    const auth=JSON.parse(await boundedFile(path,512*1024));
    if(!auth||typeof auth!=='object'||Array.isArray(auth)||AUTH_FIELDS.some(key=>!tokenText(auth[key])))throw new Error();
    for(const key of ['deviceVerifier','contextToken'])if(auth[key]!==undefined&&!tokenText(auth[key]))throw new Error();
    return {auth,fingerprint:fingerprint(auth),modifiedAt:(await stat(path)).mtimeMs};
  }catch{throw authFailure('missing_session');}
}
async function atomicJson(path,value){
  const temporary=path+'.'+randomBytes(8).toString('hex')+'.tmp';
  try{await writeFile(temporary,value,{mode:0o600,flag:'wx',flush:true});await rename(temporary,path);}
  catch(error){await unlink(temporary).catch(()=>{});throw error;}
}
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
    this.authMaintenance = null; this.importingAuth = null; this.authLoading = null; this.authFingerprint = null; this.deniedFingerprint = null;
    this.pendingBasis = null; this.statusLoaded = false; this.statusWrites = Promise.resolve();
    this.authStatus = {version:1,phase:'starting',updatedAt:this.now(),expiresAt:null,lastAttemptAt:null,lastSuccessAt:null,
      lastMethod:null,nextRenewalAt:null,lastFailureAt:null,lastFailureReason:null,lastFailureStep:null,consecutiveFailures:0,failureReason:null,failureStep:null,sessionModifiedAt:null};
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
        if(this.deniedFingerprint===this.authFingerprint) {schedule(AUTH_RETRY_MIN);return;}
        if(this.pendingAuth||!Number.isFinite(expiry)||expiry<=this.now()+AUTH_RENEW_EARLY)await this.refresh();
        state.retry=AUTH_RETRY_MIN;
        const next=Number(this.auth?.expiresAt)-this.now()-AUTH_RENEW_EARLY;
        // Short/invalid provider lifetimes cannot create a tight refresh loop.
        const delay=Math.max(AUTH_RETRY_MIN,Math.min(Number.isFinite(next)?next:AUTH_RETRY_MIN,3600000));
        await this.saveAuthStatus({nextRenewalAt:this.now()+delay});schedule(delay);
      } catch(error) {
        try{onError(error);}catch{}
        if(error instanceof BridgeError&&error.code==='sign_in_required') {
          // Poll only the private session file after a denial. A fresh sign-in
          // resumes maintenance without a restart or repeated authentication calls.
          schedule(AUTH_RETRY_MIN);
        } else {
          await this.saveAuthStatus({nextRenewalAt:this.now()+state.retry});
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
      await this.statusWrites;
    };
    this.authMaintenance={stop};schedule(0);return stop;
  }
  async saveAuthStatus(patch) {
    Object.assign(this.authStatus,patch,{updatedAt:this.now()});
    const snapshot=JSON.stringify(this.authStatus);
    this.statusWrites=this.statusWrites.then(()=>atomicJson(this.config.authFile+'.status.json',snapshot))
      .catch(()=>{this.authStatus.statusPersistenceFailed=true;});
    await this.statusWrites;
  }
  async loadAuth() {
    if(this.authLoading)return this.authLoading;
    this.authLoading=(async()=>{
      // Only this process promotes pending sessions. Installers atomically write
      // auth.pending.json, never race the owner by overwriting auth.json.
      if(!this.refreshing)await this.importPendingAuth();
      const snapshot=await readAuth(this.config.authFile);
      if(!this.statusLoaded){
        this.statusLoaded=true;
        try {
          const saved=JSON.parse(await boundedFile(this.config.authFile+'.status.json',8192));
          for(const key of ['lastAttemptAt','lastSuccessAt','lastFailureAt'])if(Number.isSafeInteger(saved[key])&&saved[key]>0)this.authStatus[key]=saved[key];
          if(['refresh_token','device_verifier'].includes(saved.lastMethod))this.authStatus.lastMethod=saved.lastMethod;
          if(AUTH_REASONS.has(saved.lastFailureReason))this.authStatus.lastFailureReason=saved.lastFailureReason;
          if(AUTH_STEPS.has(saved.lastFailureStep))this.authStatus.lastFailureStep=saved.lastFailureStep;
          if(saved.sessionModifiedAt===snapshot.modifiedAt && saved.phase==='waiting_for_sign_in'){
            this.deniedFingerprint=snapshot.fingerprint;
            if(AUTH_REASONS.has(saved.failureReason))this.authStatus.failureReason=saved.failureReason;
            if(AUTH_STEPS.has(saved.failureStep))this.authStatus.failureStep=saved.failureStep;
          }
        }catch{}
      }
      if(this.authFingerprint!==snapshot.fingerprint){
        const denied=this.deniedFingerprint===snapshot.fingerprint;
        this.auth=snapshot.auth;this.authFingerprint=snapshot.fingerprint;
        if(!denied)this.deniedFingerprint=null;
        this.cached=null;this.locationCache=null;
        await this.saveAuthStatus({phase:denied?'waiting_for_sign_in':'ready',expiresAt:validTime(snapshot.auth.expiresAt),
          hasDeviceVerifier:tokenText(snapshot.auth.deviceVerifier),sessionModifiedAt:snapshot.modifiedAt,consecutiveFailures:denied?this.authStatus.consecutiveFailures:0,
          failureReason:denied?(this.authStatus.failureReason??'interactive_sign_in_required'):null,failureStep:denied?this.authStatus.failureStep:null,nextRenewalAt:null});
      }
      return this.auth;
    })().catch(async error=>{await this.saveAuthStatus({phase:'waiting_for_sign_in',failureReason:'missing_session',nextRenewalAt:null,lastFailureAt:this.now(),lastFailureReason:'missing_session',lastFailureStep:null});throw error;}).finally(()=>{this.authLoading=null;});
    return this.authLoading;
  }
  async importPendingAuth() {
    if(this.importingAuth)return this.importingAuth;
    this.importingAuth=(async()=>{
      const path=this.config.authFile.replace(/\.json$/,'')+'.pending.json';
      try {await stat(path);}catch(error){if(error.code==='ENOENT')return false;throw new BridgeError();}
      const incoming=await readAuth(path); // Validate before replacing the session.
      await rename(path,this.config.authFile);
      this.pendingAuth=null;this.pendingBasis=null;
      if(incoming.fingerprint!==this.authFingerprint)this.deniedFingerprint=null;
      return true;
    })().finally(()=>{this.importingAuth=null;});
    return this.importingAuth;
  }
  getAuthStatus() {
    return {...this.authStatus,ready:!!this.auth && Number(this.auth.expiresAt)>this.now() && this.deniedFingerprint!==this.authFingerprint};
  }
  async refresh({method='automatic',importOnly=false}={}) {
    if(this.refreshing)return this.refreshing;
    this.refreshing=(async()=>{
      // This is the sole writer, including completed interactive sign-ins.
      await this.importPendingAuth();
      const current=await this.loadAuth();
      if(importOnly)return current;
      if(this.deniedFingerprint===this.authFingerprint)throw authFailure('interactive_sign_in_required');
      const basis=this.authFingerprint;
      await this.saveAuthStatus({phase:'renewing',lastAttemptAt:this.now(),nextRenewalAt:null,failureReason:null,failureStep:null});
      try {
        // Keep a rotated credential on disk failure, and never reuse its spent
        // predecessor. A newly installed session always supersedes this work.
        if(this.pendingBasis!==basis){this.pendingAuth=null;this.pendingBasis=null;}
        const next=this.pendingAuth??await renewAuth(current,{request:this.request,now:this.now,method,
          onMethod:value=>{this.authStatus.lastMethod=value;}});
        this.pendingAuth=next;this.pendingBasis=basis;
        if(await this.importPendingAuth())return this.loadAuth();
        const latest=await readAuth(this.config.authFile).catch(()=>null);
        if(latest&&latest.fingerprint!==basis){this.pendingAuth=null;this.pendingBasis=null;return this.loadAuth();}
        await atomicJson(this.config.authFile,JSON.stringify(next));
        this.auth=next;this.authFingerprint=fingerprint(next);this.pendingAuth=null;this.pendingBasis=null;
        const modifiedAt=(await stat(this.config.authFile)).mtimeMs;
        this.deniedFingerprint=null;
        await this.saveAuthStatus({phase:'ready',expiresAt:validTime(next.expiresAt),sessionModifiedAt:modifiedAt,
          lastSuccessAt:this.now(),consecutiveFailures:0,failureReason:null,failureStep:null,
          nextRenewalAt:Math.max(this.now()+AUTH_RETRY_MIN,Number(next.expiresAt)-AUTH_RENEW_EARLY)});
        return next;
      }catch(error){
        // A login completed during a failed refresh is also usable immediately.
        if(await this.importPendingAuth())return this.loadAuth();
        const latest=await readAuth(this.config.authFile).catch(()=>null);
        if(latest&&latest.fingerprint!==basis)return this.loadAuth();
        const denied=error instanceof BridgeError&&error.code==='sign_in_required';
        // A deliberate saved-device diagnostic can reject an optional verifier
        // while the normal access/refresh pair is still valid. Do not turn that
        // narrow first-leg rejection into an outage. Security/forced-sign-in
        // decisions and expired sessions retain the same fail-closed behavior.
        const diagnosticRejection=method==='device_verifier' && Number(current.expiresAt)>this.now() &&
          error.authReason==='authentication_rejected' && error.authStep==='device_verifier';
        if(denied&&!diagnosticRejection)this.deniedFingerprint=basis;
        const reason=AUTH_REASONS.has(error.authReason)?error.authReason:denied?'interactive_sign_in_required':this.pendingAuth?'credential_persistence_failed':'provider_unavailable';
        const step=AUTH_STEPS.has(error.authStep)?error.authStep:null;
        await this.saveAuthStatus({phase:diagnosticRejection?'ready':denied?'waiting_for_sign_in':'retrying',
          nextRenewalAt:diagnosticRejection?Math.max(this.now()+AUTH_RETRY_MIN,Number(current.expiresAt)-AUTH_RENEW_EARLY):null,
          consecutiveFailures:this.authStatus.consecutiveFailures+1,
          failureReason:diagnosticRejection?null:reason,failureStep:diagnosticRejection?null:step,
          lastFailureAt:this.now(),lastFailureReason:reason,lastFailureStep:step});
        throw error instanceof BridgeError?error:new BridgeError();
      }
    })().finally(()=>{this.refreshing=null;});
    return this.refreshing;
  }
  async operatorAuth({reload=false}={}) {
    // Signals never introduce a second token owner. Wait for a previous rotation
    // before consuming the optional one-shot, private operator command.
    await this.refreshing?.catch(()=>{});
    if(reload)return this.refresh({importOnly:true});
    const path=this.config.authFile+'.command.json';
    let command;
    try {command=JSON.parse(await boundedFile(path,2048));await unlink(path);}
    catch(error){if(error.code!=='ENOENT')throw new BridgeError('invalid_request',400);}
    if(command!==undefined){
      if(!command||Object.keys(command).some(k=>!['action','createdAt'].includes(k))||command.action!=='renew_device'||
        !Number.isSafeInteger(command.createdAt)||this.now()-command.createdAt>60000||command.createdAt-this.now()>5000)throw new BridgeError('invalid_request',400);
      return this.refresh({method:'device_verifier'});
    }
    return this.refresh();
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
