import http from 'node:http';
import {readFile} from 'node:fs/promises';
import {randomBytes,randomUUID} from 'node:crypto';
import {pathToFileURL} from 'node:url';
import {BridgeError,MESSAGES,boundedRequest,fetchCdn,cdnUrl} from './http.mjs';
import {SpectrumProvider} from './provider.mjs';
import {createMediaRegistry} from './manifest.mjs';
import {createGuide} from './guide.mjs';

const CAP = /^[a-f0-9]{48}$/;
const IDLE = 120000;
const MAX_SESSIONS = 24;
const CERTIFICATE = 'https://apis-drm.spectrum.net/drm/licenseServer/getcertificate/v2?applicationId=charter';
function secretText(value) { return typeof value==='string' && value.length>0 && value.length<=65536 && !/[\r\n\0]/.test(value); }
export function validateConfig(input) {
  const config=structuredClone(input);
  if (!config || typeof config.authFile!=='string' || !config.authFile.startsWith('/') || config.authFile.length>4096) throw new BridgeError('sign_in_required',401);
  for (const field of ['tuneQuery','manifestQuery']) {
    if (!config[field] || typeof config[field]!=='object' || Array.isArray(config[field])) throw new BridgeError('sign_in_required',401);
    for (const [key,value] of Object.entries(config[field])) {
      if (!/^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(key) || !['boolean','string','number'].includes(typeof value) || String(value).length>8192 || /[\r\n\0]/.test(String(value)) || ['aegis','sessionId','streamSessionId'].includes(key)) throw new BridgeError('invalid_request',400);
    }
  }
  if (config.channelAliases!==undefined && (!Array.isArray(config.channelAliases) || config.channelAliases.length>2000)) throw new BridgeError('invalid_request',400);
  const aliasIds=new Set(),aliasServices=new Set();
  for(const alias of config.channelAliases||[]){
    if(!alias||!/^[A-Za-z0-9_-]{1,120}$/.test(alias.id)||!/^[A-Za-z0-9_-]{1,128}$/.test(String(alias.entitlementId))||aliasIds.has(alias.id)||aliasServices.has(String(alias.entitlementId)))throw new BridgeError('invalid_request',400);
    aliasIds.add(alias.id);aliasServices.add(String(alias.entitlementId));
  }
  if (config.extraCdnHosts!==undefined && (!Array.isArray(config.extraCdnHosts) || config.extraCdnHosts.length>20 || config.extraCdnHosts.some(v=>typeof v!=='string'||!/^(?:\*\.)?[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$/.test(v)))) throw new BridgeError('invalid_request',400);
  config.sourceName=typeof config.sourceName==='string'?config.sourceName.slice(0,100):'Spectrum';
  return config;
}
export function createBridge(input,{request=boundedRequest,provider,now=Date.now,log=()=>{}}={}) {
  const config=validateConfig(input);
  provider??=new SpectrumProvider(config,{request,now});
  const guide=createGuide(provider,{now});
  const sessions=new Map(),pendingTunes=new Set(),cleanupJobs=new Set(),cleanupSessions=new Map();
  let opening=0,shuttingDown=false,certificate=null,certificateAt=0,certificateWork=null;
  const report=(event,error)=>log({event,code:error instanceof BridgeError?error.code:'source_unavailable'});
  const owned=id=>{
    const session=CAP.test(id)&&sessions.get(id);
    if(!session||session.closed)throw new BridgeError('session_ended',404);
    session.touched=now();return session;
  };
  const cdn=(url,options={})=>fetchCdn(url,{request,extraHosts:config.extraCdnHosts,...options});
  async function closeSession(session) {
    if(session.closing)return session.closing;
    session.closed=true;sessions.delete(session.id);clearTimeout(session.renewTimer);
    if(session.aegis)cleanupSessions.set(session.id,session);
    session.closing=(async()=>{
      await session.leaseWork.catch(()=>{});
      if(session.aegis)await provider.stop(session.aegis);
      session.aegis=null;cleanupSessions.delete(session.id);
    })().catch(error=>{
      session.cleanupAttempts=(session.cleanupAttempts||0)+1;
      session.nextCleanup=now()+Math.min(60000,5000*session.cleanupAttempts);
      report('lease_stop_failed',error);throw error;
    }).finally(()=>{cleanupJobs.delete(session.closing);session.closing=null;});
    cleanupJobs.add(session.closing);return session.closing;
  }
  function renewLater(session,seconds) {
    if(session.closed)return;
    const delay=Number.isFinite(Number(seconds))&&Number(seconds)>0?Math.max(1000,Number(seconds)*1000):30000;
    session.renewTimer=setTimeout(()=>{
      session.leaseWork=(async()=>{
        const value=await provider.renew(session.aegis);
        if(!secretText(value?.aegis?.aegisToken))throw new BridgeError();
        session.aegis=value.aegis.aegisToken;
        renewLater(session,value.aegis.aegisTokenRefreshSeconds);
      })();
      session.leaseWork.catch(error=>{report('lease_renew_failed',error);closeSession(session).catch(()=>{});});
    },Math.min(delay,3600000));session.renewTimer.unref?.();
  }
  async function resource(session,key,range) {
    const target=session.media.resolve(key);
    const manifest=target.kind==='dash'||target.kind==='hls';
    const response=await cdn(target.url,{maxBytes:manifest?2*1024*1024:64*1024*1024,headers:manifest?{}:{Range:range}});
    if(session.closed)throw new BridgeError('session_ended',404);
    const body=manifest?session.media.rewrite(response.body,response.url,target.kind):response.body;
    return {body,status:manifest?200:response.status,type:target.kind==='dash'?'application/dash+xml':target.kind==='hls'?'application/vnd.apple.mpegurl':'application/octet-stream',contentRange:manifest?null:response.headers['content-range']};
  }
  async function performTune(channelId,capabilities,signal) {
    const checkCancelled=()=>{if(shuttingDown||signal?.aborted)throw new BridgeError('session_ended',503);};
    checkCancelled();
    if(typeof channelId!=='string'||!/^[A-Za-z0-9_-]{1,120}$/.test(channelId))throw new BridgeError('invalid_request',400);
    const supports=new Set(String(capabilities).split(',').map(v=>v.trim()));
    const format=supports.has('dash-widevine')?'widevine':supports.has('hls-fairplay')?'fairplay':null;
    if(!format)throw new BridgeError('native_update_required',426);
    if(opening>=3||sessions.size+cleanupSessions.size+opening>=MAX_SESSIONS)throw new BridgeError('concurrency_limit',429);
    opening++;
    const session={id:randomBytes(24).toString('hex'),playerId:randomUUID(),format,touched:now(),created:now(),closed:false,aegis:null,ast:null,astAt:0,leaseWork:Promise.resolve(),licenseTail:Promise.resolve(),licensePending:0};
    try {
      const entries=await provider.channels();const entry=entries.find(e=>e.channel.id===channelId);
      if(!entry)throw new BridgeError('channel_not_entitled',403);
      checkCancelled();
      session.service=entry.service;session.channel=entry.channel;
      const {value,headers}=await provider.tune(entry,format);
      if(secretText(value?.aegis?.aegisToken))session.aegis=value.aegis.aegisToken;
      checkCancelled();
      session.ast=headers['x-set-ast'];session.feed=String(value?.outputFeedId??'');session.astAt=now();
      if(!session.aegis||!secretText(session.ast)||!session.feed||!secretText(value?.streamUrl))throw new BridgeError();
      const url=cdnUrl(value.streamUrl,config.extraCdnHosts);
      for(const [key,val]of Object.entries(config.manifestQuery))url.searchParams.set(key,String(val));
      // Each playback owns its ad/stream identifiers and concurrency lease.
      for(const key of ['pvrn','vprn'])url.searchParams.set(key,String(randomBytes(4).readUInt32BE()));
      url.searchParams.set('streamSessionId',session.playerId);
      if(value.altContent!==undefined&&['boolean','string','number'].includes(typeof value.altContent))url.searchParams.set('altContent',String(value.altContent));
      session.media=createMediaRegistry({id:session.id,format,extraHosts:config.extraCdnHosts,now});
      session.root=session.media.register(url.href,format==='fairplay'?'hls':'dash');
      // Validate the root manifest before handing the player a lease. CDN media
      // remains encrypted and all decryption stays in the device's native CDM.
      await resource(session,session.root);
      checkCancelled();
      sessions.set(session.id,session);renewLater(session,value.aegis.aegisTokenRefreshSeconds);
      return {sessionId:session.id,playbackPath:`/live/streams/${session.id}/${session.root}`,mimeType:format==='fairplay'?'application/vnd.apple.mpegurl':'application/dash+xml',channel:session.channel,canPause:false,canSeek:false,drm:format==='fairplay'?{scheme:'fairplay',licensePath:`/live/drm/${session.id}`,certificatePath:`/live/cert/${session.id}`,contentIdMode:'spectrum-content-id'}:{scheme:'widevine',licensePath:`/live/drm/${session.id}`,multiSession:false}};
    }catch(error){await closeSession(session).catch(()=>{});throw error;}finally{opening--;}
  }
  function tune(channelId,capabilities,signal){
    const work=performTune(channelId,capabilities,signal);
    pendingTunes.add(work);
    work.then(()=>pendingTunes.delete(work),()=>pendingTunes.delete(work));
    return work;
  }
  const reaper=setInterval(()=>{
    for(const session of sessions.values())if(now()-session.touched>IDLE||now()-session.created>24*3600000)closeSession(session).catch(()=>{});
    for(const session of cleanupSessions.values())if(!session.closing&&now()>=session.nextCleanup)closeSession(session).catch(()=>{});
  },15000);reaper.unref?.();
  return {
    async channels(){return {enabled:true,sourceName:config.sourceName,channels:(await provider.channels()).map(e=>e.channel),message:null};},
    async guide(){return guide.snapshot(config.sourceName);},
    tune,
    async media(id,key,range){return resource(owned(id),key,range);},
    async license(id,key,body,signal){
      const session=owned(id);
      if(!Buffer.isBuffer(body)||!body.length||body.length>1024*1024)throw new BridgeError('invalid_request',400);
      if(session.licensePending>=4)throw new BridgeError('source_unavailable',503);
      const protection=session.format==='fairplay'?session.media.key(key):null;
      if(session.format==='fairplay'&&!protection)throw new BridgeError('session_ended',404);
      if(session.format==='widevine'&&key!==null)throw new BridgeError('invalid_request',400);
      // Native players may request distinct audio/video keys or renewal together.
      // Serialize opaque exchanges instead of treating normal overlap as failure.
      session.licensePending++;
      const checkCancelled=()=>{if(session.closed||signal?.aborted)throw new BridgeError('session_ended',404);};
      const work=session.licenseTail.then(async()=>{
        checkCancelled();
        if(now()-session.astAt>=20000){session.ast=await provider.ast(session.service,session.feed);session.astAt=now();if(!secretText(session.ast))throw new BridgeError('drm_unavailable',503);}
        checkCancelled();
        return await provider.license(session.format,session,body,protection?.query);
      }).finally(()=>{session.licensePending--;});
      session.licenseTail=work.catch(()=>{});
      return work;
    },
    async certificate(id){
      if(owned(id).format!=='fairplay')throw new BridgeError('invalid_request',400);
      if(certificateWork)return certificateWork;
      if(!certificate||now()-certificateAt>3600000){
        certificateWork=(async()=>{
        const response=await request({url:CERTIFICATE,maxBytes:64*1024});
        if(response.status!==200||!response.body.length||response.body[0]!==0x30)throw new BridgeError('drm_unavailable',503);
        certificate=response.body;certificateAt=now();
        return certificate;
        })().finally(()=>{certificateWork=null;});
        return certificateWork;
      }return certificate;
    },
    async stop(id){const session=sessions.get(id)||cleanupSessions.get(id);if(session)await closeSession(session);},
    async close(){shuttingDown=true;clearInterval(reaper);await Promise.allSettled([...pendingTunes]);await Promise.allSettled([...new Set([...sessions.values(),...cleanupSessions.values()])].map(closeSession));await Promise.allSettled([...cleanupJobs]);if(cleanupSessions.size)report('shutdown_leases_unconfirmed',new BridgeError());},
    report,
  };
}
async function body(req,limit){let size=0;const chunks=[];for await(const chunk of req){size+=chunk.length;if(size>limit)throw new BridgeError('invalid_request',413);chunks.push(chunk);}return Buffer.concat(chunks);}
export function createHttpServer(bridge,{allowedClients}={}) {
  let activeMedia=0;
  const server=http.createServer(async(req,res)=>{
    const reply=(status,data,type='application/json',extra={})=>{if(!res.destroyed){res.writeHead(status,{'Content-Type':type,'Cache-Control':'no-store, private','X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer',...extra});res.end(data);}};
    try{
      if(allowedClients&&!allowedClients.includes(req.socket.remoteAddress))throw new BridgeError('invalid_request',403);
      if(!req.url.startsWith('/')||req.url.startsWith('//')||req.headers.origin)throw new BridgeError('invalid_request',400);
      const url=new URL(req.url,'http://localhost');let match;
      if(req.method==='GET'&&url.pathname==='/health'&&!url.search)return reply(200,'{"ok":true}');
      if(req.method==='GET'&&url.pathname==='/live/channels'&&!url.search)return reply(200,JSON.stringify(await bridge.channels()));
      if(req.method==='GET'&&url.pathname==='/live/guide'&&!url.search)return reply(200,JSON.stringify(await bridge.guide()));
      if(req.method==='POST'&&url.pathname==='/live/tune'&&!url.search){
        let value;try{value=JSON.parse(await body(req,2048));}catch(error){if(error instanceof BridgeError)throw error;throw new BridgeError('invalid_request',400);}
        if(!value||typeof value!=='object'||Array.isArray(value)||Object.keys(value).some(k=>!['channelId','client'].includes(k))||(value.client!==undefined&&value.client!=='roku'))throw new BridgeError('invalid_request',400);
        const controller=new AbortController();
        const cancel=()=>controller.abort();res.once('close',cancel);
        try{
          const tuned=await bridge.tune(value.channelId,req.headers['x-velvet-playback-capabilities']||'',controller.signal);
          if(res.destroyed){await bridge.stop(tuned.sessionId);return;}return reply(200,JSON.stringify(tuned));
        }finally{res.removeListener('close',cancel);}
      }
      if(req.method==='DELETE'&&!url.search&&(match=url.pathname.match(/^\/live\/sessions\/([a-f0-9]{48})$/))){await bridge.stop(match[1]);return reply(204,'');}
      if(req.method==='GET'&&!url.search&&(match=url.pathname.match(/^\/live\/streams\/([a-f0-9]{48})\/([A-Za-z0-9_.-]{1,240})$/))){
        if(activeMedia>=12)throw new BridgeError();activeMedia++;
        try{const media=await bridge.media(match[1],match[2],req.headers.range);const headers={};if(media.contentRange&&/^bytes \d+-\d+\/\d+$/.test(media.contentRange))headers['Content-Range']=media.contentRange;return reply(media.status,media.body,media.type,headers);}finally{activeMedia--;}
      }
      if(req.method==='GET'&&!url.search&&(match=url.pathname.match(/^\/live\/cert\/([a-f0-9]{48})$/)))return reply(200,await bridge.certificate(match[1]),'application/octet-stream');
      if(req.method==='POST'&&(match=url.pathname.match(/^\/live\/drm\/([a-f0-9]{48})$/))){
        if([...url.searchParams.keys()].some(key=>key!=='key')||url.searchParams.getAll('key').length>1)throw new BridgeError('invalid_request',400);
        const key=url.searchParams.get('key');if(key!==null&&!/^[A-Za-z0-9_-]{16,128}$/.test(key))throw new BridgeError('invalid_request',400);
        const challenge=await body(req,1024*1024),controller=new AbortController();
        const cancel=()=>controller.abort();res.once('close',cancel);
        try{return reply(200,await bridge.license(match[1],key,challenge,controller.signal),'application/octet-stream');}
        finally{res.removeListener('close',cancel);}
      }
      throw new BridgeError('session_ended',404);
    }catch(error){bridge.report('request_failed',error);const safe=error instanceof BridgeError?error:new BridgeError();reply(safe.status,JSON.stringify({code:safe.code,error:MESSAGES[safe.code]||MESSAGES.source_unavailable}));}
  });
  server.requestTimeout=45000;server.headersTimeout=10000;server.keepAliveTimeout=5000;server.maxConnections=64;return server;
}
async function main(){
  if(!process.env.SPECTRUM_CONFIG)throw new BridgeError('sign_in_required',401);
  const config=JSON.parse(await readFile(process.env.SPECTRUM_CONFIG,'utf8'));
  const bridge=createBridge(config,{log:entry=>process.stderr.write(JSON.stringify(entry)+'\n')});
  const server=createHttpServer(bridge);server.listen(8812,'0.0.0.0');
  const close=async()=>{server.close();await bridge.close();server.closeAllConnections();process.exit(0);};process.once('SIGTERM',close);process.once('SIGINT',close);
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href)main().catch(()=>{process.stderr.write('{"event":"startup_failed"}\n');process.exitCode=1;});
