(function(){
const O=window.OCM;
// Synchronous JS -> Swift bridge. WKWebView prompts are answered by WKUIDelegate
// without showing UI, which keeps the original Android bridge semantics intact.
function ocRaw(op,...args){
  try{return window.prompt('__oc__'+JSON.stringify({op,args}))}catch(e){return null}
}
function ocJSON(op,...args){try{return JSON.parse(ocRaw(op,...args)||'null')}catch(e){return null}}
window.OC={
  state:()=>ocRaw('state'),
  http:(id,m,p,b)=>ocRaw('http',id,m,p,b),drop:id=>ocRaw('drop',id),
  sseStart:()=>ocRaw('sseStart'),sseStop:()=>ocRaw('sseStop'),
  wsOpen:(id,p)=>ocRaw('wsOpen',id,p),wsSend:(id,t)=>ocRaw('wsSend',id,t),wsClose:id=>ocRaw('wsClose',id),
  ls:p=>ocRaw('ls',p),fs:(op,p,a)=>ocRaw('fs',op,p,a),readText:p=>ocRaw('readText',p),writeText:(p,t)=>ocRaw('writeText',p,t),
  cfgRead:()=>ocRaw('cfgRead'),cfgWrite:t=>ocRaw('cfgWrite',t),readLog:()=>ocRaw('readLog'),
  pickFile:(k,d)=>ocRaw('pickFile',k,d),copy:t=>ocRaw('copy',t),pasteText:()=>ocRaw('pasteText'),share:t=>ocRaw('share',t),openLink:u=>ocRaw('openLink',u),
  grant:k=>ocRaw('grant',k),setFlag:(k,v)=>ocRaw('setFlag',k,v),testSound:k=>ocRaw('testSound',k),
  signIn:()=>ocRaw('signIn'),signInGuest:f=>ocRaw('signInGuest',f),signInEmail:e=>ocRaw('signInEmail',e),signOut:()=>ocRaw('signOut'),
  authLogin:()=>ocRaw('authLogin'),authCancel:()=>ocRaw('authCancel'),authLogout:e=>ocRaw('authLogout',e),
  install:()=>ocRaw('install'),resetInstall:()=>ocRaw('resetInstall'),start:()=>ocRaw('start'),restartServer:()=>ocRaw('restartServer'),minimize:()=>ocRaw('minimize'),
  checkUpdates:()=>ocRaw('checkUpdates'),applyAppUpdate:()=>ocRaw('applyAppUpdate'),applyCoreUpdate:()=>ocRaw('applyCoreUpdate'),
  connect:(u,p)=>ocRaw('connect',u,p),connectSaved:()=>ocRaw('connectSaved')
};
const pend=new Map();let seq=0;const L={};
O.on=(n,f)=>{(L[n]=L[n]||[]).push(f)};
window.OCEvent=(n,d)=>{if(n==='http'){finishHttp(d);return}(L[n]||[]).forEach(f=>{try{f(d)}catch(e){console.error(n,e)}})};
O.dir='';
// api(method, path, body, {dir:false|string, timeout, raw})
O.api=(method,path,body,opt)=>new Promise((res,rej)=>{opt=opt||{};
  const id='r'+(++seq)+'_'+Date.now().toString(36);let p=path;
  if(opt.dir!==false){const d=typeof opt.dir==='string'?opt.dir:O.dir;if(d)p+=(p.includes('?')?'&':'?')+'directory='+encodeURIComponent(d)}
  pend.set(id,{res,rej,raw:opt.raw});
  try{OC.http(id,method,p,body==null?'':JSON.stringify(body))}catch(e){pend.delete(id);rej(e);return}
  setTimeout(()=>{if(pend.has(id)){pend.delete(id);rej(Object.assign(new Error('timeout'),{net:true}))}},opt.timeout||60000)});
async function finishHttp(d){const p=pend.get(d.id);if(!p)return;pend.delete(d.id);
  if(d.err){p.rej(Object.assign(new Error(d.err),{status:0,net:true}));return}
  let text=d.body||'';
  if(d.file){try{text=await(await fetch('/_resp/'+d.id)).text()}catch(e){p.rej(e);return}finally{try{OC.drop(d.id)}catch{}}}
  let data=text;if(!p.raw&&text&&(d.ct||'').includes('json')){try{data=JSON.parse(text)}catch{}}
  if(d.status>=200&&d.status<300)p.res(data);
  else p.rej(Object.assign(new Error((data&&data.data&&data.data.message)||(data&&data.message)||(typeof data==='string'&&data.slice(0,200))||('HTTP '+d.status)),{status:d.status,data}))}
// native helpers (sync, local)
const j=s=>{try{return JSON.parse(s)}catch{return null}};
O.native={
  ls:p=>j(OC.ls(p))||{err:'ls failed'},
  fs:(op,p,arg)=>j(OC.fs(op,p,arg||''))||{ok:false,err:'fs failed'},
  readText:p=>j(OC.readText(p))||{ok:false},
  writeText:(p,t)=>j(OC.writeText(p,t))||{ok:false},
  cfgRead:()=>OC.cfgRead(),cfgWrite:t=>j(OC.cfgWrite(t))||{ok:false},
  copy:t=>{try{OC.copy(t);O.toast('Скопировано',1200)}catch{}},share:t=>OC.share(t),open:u=>OC.openLink(u),
  state:()=>j(OC.state())||{}
};
O.openUrl=u=>{if(/^https?:\/\//i.test(u)&&!/appassets\.androidplatform\.net/i.test(u))OC.openLink(u)};
document.addEventListener('click',e=>{const a=e.target.closest&&e.target.closest('a[href]');if(!a)return;const u=a.getAttribute('href');e.preventDefault();if(/^https?:\/\//i.test(u))O.openUrl(u)});
document.addEventListener('click',e=>{const b=e.target.closest&&e.target.closest('[data-copy]');if(!b)return;const pre=b.closest('.codeblock');if(pre)O.native.copy(pre.querySelector('pre').innerText)});
})();
