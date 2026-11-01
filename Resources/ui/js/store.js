(function(){
const O=window.OCM,api=O.api;
const bus=O.bus={h:{},on(n,f){(this.h[n]=this.h[n]||[]).push(f)},emit(n,...a){(this.h[n]||[]).forEach(f=>{try{f(...a)}catch(e){console.error(n,e)}})}};
const S=O.S={dir:'',sessions:[],sid:null,status:{},perms:[],questions:[],todos:{},diffs:{},
  providers:[],agents:[],commands:[],cfg:{},agent:'build',model:null,variant:null,mcp:{},lsp:[],branch:'',
  offline:false,up:false,gstatus:{},account:{email:null,checked:false},opts:Object.assign({thinking:true,details:true,theme:'opencode',fs:14},O.store.get('opts',{}))};
O.saveOpts=()=>{O.store.set('opts',S.opts);document.documentElement.dataset.theme=S.opts.theme;document.documentElement.style.setProperty('--fs',S.opts.fs+'px')};

// ---- IndexedDB key/value cache (offline reading) ----
let dbp;const db=()=>dbp||(dbp=new Promise((res,rej)=>{const r=indexedDB.open('ocm',1);r.onupgradeneeded=()=>r.result.createObjectStore('kv');r.onsuccess=()=>res(r.result);r.onerror=()=>rej(r.error)}));
O.kv={async get(k){try{const d=await db();return await new Promise(res=>{const q=d.transaction('kv').objectStore('kv').get(k);q.onsuccess=()=>res(q.result);q.onerror=()=>res(undefined)})}catch{return undefined}},
  async set(k,v){try{const d=await db();await new Promise(res=>{const t=d.transaction('kv','readwrite');t.objectStore('kv').put(v,k);t.oncomplete=res;t.onerror=res;t.onabort=res})}catch{}}};

// ---- message store ----
const M=new Map();
O.msgs=sid=>{let x=M.get(sid);if(!x){x={list:[],idx:new Map()};M.set(sid,x)}return x};
const cmp=(a,b)=>a.info.id<b.info.id?-1:a.info.id>b.info.id?1:0;
O.upsertMsg=info=>{const s=O.msgs(info.sessionID);let m=s.idx.get(info.id);
  if(m)m.info=info;else{m={info,parts:[]};s.idx.set(info.id,m);s.list.push(m);if(s.list.length>1&&cmp(s.list[s.list.length-2],m)>0)s.list.sort(cmp)}return m};
O.upsertPart=part=>{const s=O.msgs(part.sessionID);let m=s.idx.get(part.messageID);
  if(!m)m=O.upsertMsg({id:part.messageID,sessionID:part.sessionID,role:'assistant',time:{created:Date.now()}});
  if(m.local){m.parts=[];m.local=false}
  const i=m.parts.findIndex(p=>p.id===part.id);
  if(i>=0)m.parts[i]=part;else{m.parts.push(part);if(m.parts.length>1&&m.parts[m.parts.length-2].id>part.id)m.parts.sort((a,b)=>a.id<b.id?-1:1)}return m};
O.visibleMsgs=sid=>{const s=O.msgs(sid),ses=S.sessions.find(x=>x.id===sid)||O.child(sid),rv=ses&&ses.revert&&ses.revert.messageID;
  return rv?s.list.filter(m=>m.info.id<rv):s.list};
O.child=sid=>S.childSessions&&S.childSessions[sid];
const saveMsgs=O.debounce(sid=>{const l=O.msgs(sid).list.slice(-400).map(m=>({info:m.info,parts:m.parts}));O.kv.set('msgs:'+sid,l)},1200);

// ---- server events ----
O.onServerEvent=raw=>{let o;try{o=JSON.parse(raw)}catch{return}
  const ev=o.payload||o,p=ev.properties||{};
  if(o.directory&&o.directory!=='global'&&S.dir&&o.directory!==S.dir&&!/^(permission|question)\./.test(ev.type))return;
  switch(ev.type){
  case'server.connected':S.up=true;bus.emit('conn');break;
  case'session.created':case'session.updated':{const i=p.info;if(!i)break;
    if(i.parentID){(S.childSessions=S.childSessions||{})[i.id]=i;break}
    const k=S.sessions.findIndex(x=>x.id===i.id);if(k>=0)S.sessions[k]=i;else S.sessions.unshift(i);
    S.sessions.sort((a,b)=>b.time.updated-a.time.updated);bus.emit('sessions');if(i.id===S.sid)bus.emit('session');break}
  case'session.deleted':S.sessions=S.sessions.filter(x=>x.id!==(p.info&&p.info.id));bus.emit('sessions');if(p.info&&p.info.id===S.sid){S.sid=null;bus.emit('open',null)}break;
  case'session.status':S.status[p.sessionID]=p.status;bus.emit('status',p.sessionID);break;
  case'session.idle':S.status[p.sessionID]={type:'idle'};bus.emit('status',p.sessionID);bus.emit('idle',p.sessionID);break;
  case'session.error':bus.emit('serror',p);break;
  case'session.diff':S.diffs[p.sessionID]=p.diff||[];bus.emit('diff',p.sessionID);break;
  case'message.updated':{const m=O.upsertMsg(p.info);bus.emit('msg',p.info.sessionID,m);saveMsgs(p.info.sessionID);break}
  case'message.removed':{const s=O.msgs(p.sessionID);s.list=s.list.filter(m=>m.info.id!==p.messageID);s.idx.delete(p.messageID);bus.emit('msg-removed',p.sessionID,p.messageID);break}
  case'message.part.updated':{const m=O.upsertPart(p.part);bus.emit('part',p.part.sessionID,m,p.part);saveMsgs(p.part.sessionID);break}
  case'message.part.delta':{const s=O.msgs(p.sessionID),m=s.idx.get(p.messageID);if(!m)break;const pt=m.parts.find(x=>x.id===p.partID);if(!pt)break;
    pt[p.field||'text']=(pt[p.field||'text']||'')+p.delta;bus.emit('part',p.sessionID,m,pt);break}
  case'message.part.removed':{const m=O.msgs(p.sessionID).idx.get(p.messageID);if(m){m.parts=m.parts.filter(x=>x.id!==p.partID);bus.emit('part-removed',p.sessionID,m,p.partID)}break}
  case'permission.updated':case'permission.asked':{const q=normPerm(p);if(!S.perms.some(x=>x.id===q.id))S.perms.push(q);bus.emit('perm');break}
  case'permission.replied':{const id=p.permissionID||p.requestID||p.id;S.perms=S.perms.filter(x=>x.id!==id);bus.emit('perm');break}
  case'question.asked':{if(!S.questions.some(x=>x.id===p.id))S.questions.push(p);bus.emit('perm');break}
  case'question.replied':case'question.rejected':{const id=p.requestID||p.id;S.questions=S.questions.filter(x=>x.id!==id);bus.emit('perm');break}
  case'todo.updated':S.todos[p.sessionID]=p.todos||[];bus.emit('todo',p.sessionID);break;
  case'file.edited':case'file.watcher.updated':bus.emit('files');break;
  case'vcs.branch.updated':S.branch=p.branch||'';bus.emit('vcs');break;
  case'mcp.tools.changed':case'lsp.updated':bus.emit('statuspanel');break;
  case'pty.exited':case'pty.deleted':bus.emit('pty',p);break}};
const normPerm=p=>({id:p.id,sessionID:p.sessionID,title:p.title||p.permission||p.type||'Разрешение',patterns:[].concat(p.patterns||p.pattern||[]),metadata:p.metadata||{},tool:p.tool,raw:p});

// Brief SSE drops (app frozen in background for a second) must not flash the reconnect banner:
// delay it, cancel when the stream comes back.
let upT=null;
O.on('sse',d=>{if(d.t==='data')O.onServerEvent(d.d);else if(d.t==='open'){if(upT){clearTimeout(upT);upT=null}S.up=true;bus.emit('conn')}
  else if(d.t==='close'){S.up=false;if(!upT)upT=setTimeout(()=>{upT=null;if(!S.up)bus.emit('conn')},5000)}});
document.addEventListener('visibilitychange',()=>{if(!document.hidden&&!S.up){try{OC.sseStart()}catch(e){}}});

// ---- opencode account (Zen) status: known once checked, so hints never nag after a login ----
O.checkAccount=async()=>{try{const r=await api('GET','/experimental/console/orgs',null,{timeout:10000});
  const em=r&&r.orgs&&r.orgs.length?[...new Set(r.orgs.map(o=>o.accountEmail))][0]:null;
  S.account={email:em||null,checked:true};bus.emit('meta')}catch{S.account.checked=true}};

// ---- loaders (network first, IndexedDB fallback) ----
O.loadMeta=async()=>{
  const [cp,ag,cm,cf,pr,br]=await Promise.allSettled([api('GET','/config/providers'),api('GET','/agent'),api('GET','/command'),api('GET','/config'),api('GET','/project',null,{dir:false}),api('GET','/vcs')]);
  if(cp.status==='fulfilled'){S.providers=cp.value.providers||[];S.defaults=cp.value.default||{};O.kv.set('providers',cp.value)}
  else{const c=await O.kv.get('providers');if(c){S.providers=c.providers||[];S.defaults=c.default||{}}}
  if(ag.status==='fulfilled'){S.agents=ag.value;O.kv.set('agents',ag.value)}else S.agents=(await O.kv.get('agents'))||[];
  if(cm.status==='fulfilled'){S.commands=cm.value;O.kv.set('commands',cm.value)}else S.commands=(await O.kv.get('commands'))||[];
  if(cf.status==='fulfilled'){S.cfg=cf.value;O.kv.set('cfg',cf.value)}else S.cfg=(await O.kv.get('cfg'))||{};
  S.projects=pr.status==='fulfilled'?pr.value:((await O.kv.get('projects'))||[]);
  if(pr.status==='fulfilled')O.kv.set('projects',pr.value);
  if(br.status==='fulfilled')S.branch=br.value&&br.value.branch||'';
  O.pickDefaults();bus.emit('meta')};
O.primaryAgents=()=>S.agents.filter(a=>a.mode!=='subagent'&&!a.hidden);
O.modelInfo=(pid,mid)=>{const p=S.providers.find(x=>x.id===pid);return p&&p.models&&p.models[mid]};
O.allModels=()=>S.providers.flatMap(p=>Object.values(p.models||{}).map(m=>({pid:p.id,pname:p.name,mid:m.id,name:m.name||m.id,m})));
O.pickDefaults=()=>{
  const prim=O.primaryAgents();if(!prim.some(a=>a.name===S.agent))S.agent=(prim[0]&&prim[0].name)||'build';
  const saved=O.store.get('model.'+S.agent);
  const ok=m=>m&&O.modelInfo(m.providerID,m.modelID);
  let m=ok(saved)?saved:null;
  const ag=S.agents.find(a=>a.name===S.agent);
  if(!m&&ag&&ag.model&&ok(ag.model))m=ag.model;
  if(!m&&typeof S.cfg.model==='string'&&S.cfg.model.includes('/')){const[i,...r]=S.cfg.model.split('/');const c={providerID:i,modelID:r.join('/')};if(ok(c))m=c}
  if(!m){const all=O.allModels();const d=all.find(x=>S.defaults[x.pid]===x.mid)||all[0];if(d)m={providerID:d.pid,modelID:d.mid}}
  S.model=m||null;
  const v=O.store.get('variant.'+(m?m.providerID+'/'+m.modelID:''));S.variant=v&&m&&O.modelInfo(m.providerID,m.modelID)&&O.modelInfo(m.providerID,m.modelID).variants&&O.modelInfo(m.providerID,m.modelID).variants[v]?v:null};
O.setModel=(pid,mid)=>{S.model={providerID:pid,modelID:mid};O.store.set('model.'+S.agent,S.model);O.pickDefaults();bus.emit('meta')};
O.setAgent=n=>{S.agent=n;O.pickDefaults();bus.emit('meta')};
O.setVariant=v=>{S.variant=v;if(S.model)O.store.set('variant.'+S.model.providerID+'/'+S.model.modelID,v);bus.emit('meta')};

O.loadSessions=async()=>{
  try{const l=await api('GET','/session');S.sessions=l.filter(s=>!s.parentID).sort((a,b)=>b.time.updated-a.time.updated);S.offline=false;O.kv.set('sessions:'+S.dir,S.sessions)}
  catch(e){const c=await O.kv.get('sessions:'+S.dir);if(c)S.sessions=c;S.offline=true}
  try{const st=await api('GET','/session/status');for(const k in st)S.status[k]=st[k]}catch{}
  bus.emit('sessions')};
O.loadPending=async()=>{
  try{const p=await api('GET','/permission');S.perms=(p||[]).map(normPerm)}catch{}
  try{const q=await api('GET','/question');S.questions=q||[]}catch{}
  bus.emit('perm')};
O.openSession=async(sid,fresh)=>{
  S.sid=sid;O.store.set('sid.'+S.dir,sid);
  if(!sid){bus.emit('open',null);return}
  const s=O.msgs(sid);
  if(!s.list.length){const c=await O.kv.get('msgs:'+sid);if(c)c.forEach(m=>{s.list.push(m);s.idx.set(m.info.id,m)})}
  bus.emit('open',sid);
  if(fresh)return;
  try{const arr=await api('GET','/session/'+sid+'/message',null,{timeout:120000});
    s.list=[];s.idx=new Map();for(const m of arr){const x={info:m.info,parts:m.parts};s.list.push(x);s.idx.set(m.info.id,x)}
    S.offline=false;bus.emit('open',sid);saveMsgs(sid)}catch(e){S.offline=true;bus.emit('conn')}
  api('GET','/session/'+sid+'/todo').then(t=>{S.todos[sid]=t;bus.emit('todo',sid)}).catch(()=>{});
  api('GET','/session/'+sid+'/diff').then(d=>{S.diffs[sid]=d;bus.emit('diff',sid)}).catch(()=>{});
  O.loadPending()};
O.newSession=async()=>{const s=await api('POST','/session',{});if(!S.sessions.some(x=>x.id===s.id))S.sessions.unshift(s);bus.emit('sessions');await O.openSession(s.id,true);return s};
O.setDir=async(dir)=>{
  S.dir=dir;O.dir=dir;O.store.set('dir',dir);
  const rec=O.store.get('recent',[]).filter(x=>x!==dir);rec.unshift(dir);O.store.set('recent',rec.slice(0,12));
  S.sessions=[];S.sid=null;S.perms=[];S.questions=[];S.diffs={};S.todos={};bus.emit('dir');
  await Promise.all([O.loadMeta(),O.loadSessions()]);
  const last=O.store.get('sid.'+dir);const pick=S.sessions.find(x=>x.id===last)||S.sessions[0];
  await O.openSession(pick?pick.id:null);bus.emit('files')};
O.sessionTitle=s=>s?(s.title&&!/^(New session|Child session|Новая сессия) - /.test(s.title)?s.title:'Новая сессия'):'OpenCode';
O.contextUsage=sid=>{const l=O.visibleMsgs(sid);for(let i=l.length-1;i>=0;i--){const x=l[i].info;if(x.role==='assistant'&&x.tokens&&(x.tokens.input||x.tokens.output)){
  const t=x.tokens,tot=(t.input||0)+(t.output||0)+(t.reasoning||0)+((t.cache&&t.cache.read)||0)+((t.cache&&t.cache.write)||0);
  const mi=O.modelInfo(x.providerID,x.modelID),lim=mi&&mi.limit&&mi.limit.context;return{tot,pct:lim?Math.round(tot*100/lim):null}}}return null};
O.replyPermission=async(p,r)=>{
  const tries=[()=>api('POST','/permission/'+p.id+'/reply',{reply:r}),()=>api('POST','/session/'+p.sessionID+'/permissions/'+p.id,{response:r}),()=>api('POST','/api/session/'+p.sessionID+'/permission/'+p.id+'/reply',{reply:r})];
  for(const t of tries){try{await t();S.perms=S.perms.filter(x=>x.id!==p.id);bus.emit('perm');return}catch(e){if(e.status!==404&&e.status!==405&&e.status!==400)throw e}}
  throw new Error('Ответ на разрешение не поддерживается этой версией сервера')};
})();
