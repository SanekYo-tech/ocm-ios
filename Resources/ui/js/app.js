(function(){
const O=window.OCM,h=O.h,S=O.S,api=O.api,bus=O.bus;
let built=false,tab='chat',sideTab='term',T={},P={},TB={},SB={},SP={};
const wide=()=>innerWidth>=820;
function build(){if(built)return;built=true;const app=O.$('#app');
  T.menu=h('button',{class:'ibtn',onclick:()=>O.openSessions()},O.icon('menu'));
  T.t=h('b',null,'OpenCode');T.s=h('span',null,'');
  T.ttl=h('button',{class:'ttl grow',style:{textAlign:'left'},onclick:()=>O.openProjects()},T.t,T.s);
  T.dot=h('span',{class:'dot',style:{position:'absolute',top:'8px',right:'7px',width:'7px',height:'7px'}});
  T.status=h('button',{class:'ibtn',style:{position:'relative'},onclick:()=>O.openStatus()},O.icon('server'),T.dot);
  T.set=h('button',{class:'ibtn',onclick:()=>O.openSettings()},O.icon('sliders'));
  const top=h('div',{id:'top'},T.menu,T.ttl,T.status,T.set);
  T.banner=h('div',{id:'banner',class:'hide'});
  P.files=h('div',{id:'pane-files',class:'pane'});P.chat=h('div',{id:'pane-chat',class:'pane'});P.side=h('div',{id:'pane-side',class:'pane'});
  SP.term=h('div',{class:'side-pane'});SP.changes=h('div',{class:'side-pane'});
  SB.term=h('button',{onclick:()=>O.setTab('term')},'Терминал');SB.changes=h('button',{onclick:()=>O.setTab('changes')},'Изменения');
  P.side.append(h('div',{id:'side-tabs'},SB.term,SB.changes),SP.term,SP.changes);
  const main=h('div',{id:'main'},P.files,P.chat,P.side);
  const tb=(k,ic,l)=>{TB[k]=h('button',{onclick:()=>O.setTab(k)},O.icon(ic),h('span',null,l));return TB[k]};
  const bar=h('div',{id:'tabbar'},tb('chat','chat','Чат'),tb('files','folder','Файлы'),tb('term','terminal','Терминал'),tb('changes','branch','Изменения'));
  app.append(top,T.banner,main,bar);
  O.filesInit(P.files);O.chatInit(P.chat);O.termInit(SP.term);O.changesInit(SP.changes);
  addEventListener('resize',O.debounce(layout,100));
  ['open','session','sessions','msg','vcs','dir','meta','diff'].forEach(e=>bus.on(e,O.debounce(updateTop,120)));
  bus.on('conn',updateBanner);bus.on('statuspanel',refreshStatus);
  layout();updateTop()}
function layout(){const app=O.$('#app');app.dataset.mode=wide()?'wide':'narrow';
  const w=wide();
  P.files.classList.toggle('show',!w&&tab==='files');P.chat.classList.toggle('show',!w&&tab==='chat');P.side.classList.toggle('show',!w&&(tab==='term'||tab==='changes'));
  SP.term.classList.toggle('show',sideTab==='term');SP.changes.classList.toggle('show',sideTab==='changes');
  SB.term.classList.toggle('on',sideTab==='term');SB.changes.classList.toggle('on',sideTab==='changes');
  Object.keys(TB).forEach(k=>TB[k].classList.toggle('on',k===tab));
  O.termShown&&O.termShown()}
O.setTab=t=>{tab=t;if(t==='term'||t==='changes')sideTab=t;
  if(wide()&&(t==='term'||t==='changes')){}
  layout();if(t==='files')O.refreshFiles(false);if(t==='changes')O.refreshChanges()};
function updateTop(){if(!built)return;const s=S.sessions.find(x=>x.id===S.sid)||O.child(S.sid);
  T.t.textContent=s?O.sessionTitle(s):'Новая сессия';const u=S.sid&&O.contextUsage(S.sid);
  T.s.textContent=[O.basename(S.dir)||'/',S.branch,u?O.fmtK(u.tot)+' ток'+(u.pct!=null?' ('+u.pct+'%)':''):''].filter(Boolean).join('  /  ');
  O.updateBadges()}
O.updateBadges=()=>{if(!built)return;const set=(k,n)=>{let b=TB[k].querySelector('.badge');if(!n){if(b)b.remove();return}if(!b){b=h('span',{class:'badge'});TB[k].append(b)}b.textContent=n};
  set('chat',S.perms.length+S.questions.length);set('changes',O.changesCount())};
function updateBanner(){if(!built)return;const t=S.offline?'Офлайн — показаны кэшированные чаты':(!S.up?'Подключение к локальному серверу...':'');
  T.banner.textContent=t;T.banner.classList.toggle('hide',!t)}
async function refreshStatus(){try{const m=await api('GET','/mcp');S.mcp=m;const v=Object.values(m);
  T.dot.className='dot '+(v.some(x=>x.status==='failed'||x.status==='needs_auth')?'warn':v.some(x=>x.status==='connected')?'ok':'')}catch{}}
O.enter=async opt=>{build();O.saveOpts();S.offline=!!(opt&&opt.offline);S.up=false;updateBanner();OC.sseStart();
  if(O.checkAccount)O.checkAccount();
  let dir=O.store.get('dir','');
  try{const p=await api('GET','/project/current',null,{dir:false});if(p&&p.worktree)dir=p.worktree}catch{}
  if(!dir)dir='/';
  await O.setDir(dir);updateBanner();updateTop();refreshStatus();O.iconsReady.then(()=>{O.refreshFiles(false)})};
O.reconnect=async()=>{if(!built)return;S.offline=false;await O.setDir(S.dir||O.store.get('dir','/root'));updateBanner();refreshStatus()};
O.on('server',d=>{if(!built)return;if(!d.ready){S.up=false;updateBanner()}});
const baseBack=O.back;O.back=()=>{if(baseBack())return true;if(built&&!wide()&&tab!=='chat'){O.setTab('chat');return true}return false};
addEventListener('unhandledrejection',e=>console.error(e.reason));
document.addEventListener('DOMContentLoaded',()=>{O.saveOpts();O.bootRun()});
})();
