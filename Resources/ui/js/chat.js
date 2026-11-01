(function(){
const O=window.OCM,h=O.h,S=O.S,api=O.api,bus=O.bus;
let msgsEl,dockEl,popEl,ta,sendBtn,agentChip,modelChip,varChip,attsEl,jumpEl,statusEl,todoEl,revEl,fileIn,nokeyEl,comp;
const msgEls=new Map(),partEls=new Map(),open=new Set(),timers=new Map();
let atts=[],mentions=[],stick=true,revKey='',trail=[];
O.rel=p=>{p=String(p||'');return S.dir&&p.startsWith(S.dir+'/')?p.slice(S.dir.length+1):p};
const cur=()=>S.sessions.find(x=>x.id===S.sid)||O.child(S.sid);
const modelStr=()=>S.model?S.model.providerID+'/'+S.model.modelID:undefined;
const busy=()=>{const s=S.status[S.sid];return !!s&&s.type!=='idle'};

O.chatInit=root=>{
  msgsEl=h('div',{id:'msgs',class:'sel',onscroll:()=>{stick=nearBottom();jumpEl.classList.toggle('hide',stick)}});
  jumpEl=h('button',{id:'jump',class:'btn sm hide',onclick:()=>scrollEnd(true)},O.icon('chevD'));
  revEl=h('div',{class:'hide',style:{padding:'0 10px 6px'}});
  todoEl=h('div',{class:'hide',style:{padding:'0 10px 6px'}});
  dockEl=h('div',{id:'dock'});statusEl=h('div',{class:'status-line hide'});
  popEl=h('div',{id:'pop',class:'hide'});attsEl=h('div',{class:'atts hide'});
  nokeyEl=h('div',{class:'nokey hide'},h('span',{class:'grow'},'Модели не подключены — бесплатные недоступны.'),h('button',{class:'btn sm',onclick:()=>O.openConnect()},O.icon('key'),'Подключить'));
  ta=h('textarea',{rows:1,placeholder:'Спросите что угодно, / команды, @ файлы',oninput:onInput,onclick:onInput,onkeyup:e=>{if(e.key.length>1)onInput()}});
  fileIn=h('input',{type:'file',multiple:true,class:'hide',accept:'image/*,application/pdf,text/*',onchange:onFiles});
  agentChip=h('button',{class:'chip agent',onclick:()=>O.openAgents()},O.icon('bot'),h('span'));
  modelChip=h('button',{class:'chip model',onclick:()=>O.openModels()},O.icon('cpu'),h('span'));
  varChip=h('button',{class:'chip keep',onclick:cycleVariant},O.icon('bulb'),h('span'));
  sendBtn=h('button',{id:'send',onclick:onSend},O.icon('send'));
  const cbar=h('div',{class:'cbar grow'},h('button',{class:'ibtn s',onclick:()=>fileIn.click()},O.icon('paperclip')),agentChip,modelChip,varChip);
  comp=h('div',{id:'composer'},popEl,h('div',{class:'cbox'},nokeyEl,attsEl,ta,h('div',{style:{display:'flex',alignItems:'center',gap:'6px',marginTop:'4px'}},cbar,sendBtn)),fileIn);
  const wrap=h('div',{style:{position:'relative',flex:1,minHeight:0,display:'flex',flexDirection:'column'}},msgsEl,jumpEl);
  root.append(wrap,revEl,todoEl,statusEl,dockEl,comp);
  bus.on('open',()=>{renderAll()});
  bus.on('msg',(sid,m)=>{if(sid!==S.sid)return;const was=stick;ensureMsg(m);if(was)scrollEnd()});
  bus.on('part',(sid,m)=>{if(sid!==S.sid)return;const was=stick;ensureMsg(m);if(was)scrollEnd()});
  bus.on('msg-removed',(sid,id)=>{const e=msgEls.get(id);if(e){e.remove();msgEls.delete(id)}});
  bus.on('part-removed',(sid,m,pid)=>{const e=partEls.get(pid);if(e){e.remove();partEls.delete(pid)}});
  bus.on('status',sid=>{if(sid===S.sid){renderStatus();updateSend()}});
  bus.on('perm',renderDock);bus.on('todo',sid=>{if(sid===S.sid)renderTodos()});
  bus.on('session',()=>{const k=revisionKey();if(k!==revKey)renderAll();else renderRevert()});
  bus.on('sessions',()=>{renderRevert()});
  bus.on('meta',updateChips);bus.on('conn',updateChips);
  bus.on('serror',p=>{if(p&&(!p.sessionID||p.sessionID===S.sid)){const e=p.error;const t=e&&(e.data&&e.data.message||e.name);if(t&&e.name!=='MessageAbortedError'){
    if(/quota|usage.?limit|rate.?limit|limit\s+reached|insufficient|exceeded|credit|\b429\b/i.test(String(t)))O.toast(quotaHint(),8000);
    else O.toast(t,4000)}}});
  updateChips();renderAll();
};
const nearBottom=()=>msgsEl.scrollHeight-msgsEl.scrollTop-msgsEl.clientHeight<140;
const scrollEnd=f=>{requestAnimationFrame(()=>{msgsEl.scrollTop=msgsEl.scrollHeight;if(f){stick=true;jumpEl.classList.add('hide')}})};
const revisionKey=()=>{const s=cur();return s&&s.revert?s.revert.messageID:''};

function renderAll(){
  msgsEl.innerHTML='';msgEls.clear();partEls.clear();revKey=revisionKey();
  const list=S.sid?O.visibleMsgs(S.sid):[];
  if(!list.length)showEmpty();else{const fr=document.createDocumentFragment();list.forEach(m=>{const e=buildMsg(m);fr.append(e)});msgsEl.append(fr)}
  scrollEnd(true);renderDock();renderStatus();renderRevert();renderTodos();updateSend();updateChips()}
function showEmpty(){msgsEl.append(h('div',{class:'empty'},O.logo(40),h('b',{style:{color:'var(--fg)',fontSize:'17px'}},'OpenCode'),h('span',{class:'mono s'},S.dir||''),
  h('span',null,'Опишите задачу, введите / для команд или @ для упоминания файла.')))}
function ensureMsg(m){
  const rv=revisionKey();if(rv&&m.info.id>=rv)return;
  let el=msgEls.get(m.info.id);
  if(!el){const e=msgsEl.querySelector('.empty');if(e)e.remove();el=buildMsg(m);
    let before=null;for(const c of msgsEl.children){if(c.dataset.id&&c.dataset.id>m.info.id){before=c;break}}
    msgsEl.insertBefore(el,before)}
  else{syncParts(el,m);metaUpdate(el,m)}}
function buildMsg(m){
  const el=h('div',{class:'msg '+m.info.role,'data-id':m.info.id},h('div',{class:'m-body'}),h('div',{class:'m-meta'}));
  msgEls.set(m.info.id,el);syncParts(el,m);metaUpdate(el,m);return el}
function showPart(m,p){
  if(m.info.role==='user')return(p.type==='text'&&!p.synthetic&&!p.ignored)||p.type==='file'||p.type==='agent';
  switch(p.type){case'text':return true;case'reasoning':return S.opts.thinking&&String(p.text||'').trim()!=='';case'tool':case'patch':case'retry':case'compaction':return true}return false}
function syncParts(el,m){
  const body=el.firstChild;const keep=new Set();let prev=null;
  for(const p of m.parts){if(!showPart(m,p))continue;keep.add(p.id);
    let pe=partEls.get(p.id);const fresh=!pe;
    if(fresh){pe=h('div',{class:'part','data-pid':p.id});partEls.set(p.id,pe)}
    const want=prev?prev.nextSibling:body.firstChild;
    if(pe.parentNode!==body||want!==pe)body.insertBefore(pe,want);
    fillPart(pe,p,m,fresh);prev=pe}
  for(const c of [...body.children]){if(!keep.has(c.dataset.pid)){partEls.delete(c.dataset.pid);c.remove()}}}
function fillPart(el,p,m,fresh){
  el._p=p;
  switch(p.type){
  case'text':
    if(m.info.role==='user'){el.className='part p-user';if(el._t!==p.text){el._t=p.text;el.textContent=p.text}}
    else{el.className='part p-text';if(fresh)render(el);else sched(p.id,()=>render(el))}break;
  case'reasoning':{el.className='part think';
    if(!el._d){el._d=h('details',null,h('summary',null,'Размышления'),h('div',{class:'p-text'}));el.append(el._d)}
    const b=el._d.lastChild;if(fresh)renderR(el,b);else sched(p.id,()=>renderR(el,b));break}
  case'tool':{const st=p.state||{};if(st.status==='running'&&p.tool==='bash'&&!el._auto){el._auto=1;open.add(p.id)}else if(st.status!=='running'&&el._auto===1){el._auto=2;open.delete(p.id)}
    if(fresh)fillTool(el,p);else sched(p.id,()=>fillTool(el,el._p));break}
  case'file':el.className='part fchips';el.textContent='';
    if((p.mime||'').startsWith('image/')&&p.url)el.append(h('img',{class:'thumb',src:p.url}));
    else el.append(h('span',{class:'chip'},O.fileIcon(p.filename||'file'),h('span',null,p.filename||'file')));break;
  case'agent':el.className='part fchips';el.textContent='';el.append(h('span',{class:'chip'},O.icon('bot'),h('span',null,'@'+p.name)));break;
  case'patch':el.className='part';el.textContent='';el.append(h('span',{class:'chip'},O.icon('edit'),h('span',null,'Изменено файлов: '+((p.files||[]).length))));break;
  case'retry':el.className='part warn s';el.textContent='Повтор: '+((p.error&&p.error.data&&p.error.data.message)||'запрос не удался');break;
  case'compaction':el.className='part sep';el.textContent='Контекст сжат';break}}
function render(el){const p=el._p;if(el._t===p.text)return;el._t=p.text;O.mdInto(el,p.text)}
function renderR(el,b){const p=el._p;if(b._t===p.text)return;b._t=p.text;O.mdInto(b,p.text);
  const run=!(p.time&&p.time.end);el._d.firstChild.textContent=run?'Думает…':'Размышления'}
function sched(id,fn){if(timers.has(id))return;timers.set(id,setTimeout(()=>{timers.delete(id);fn();if(stick)scrollEnd()},100))}

function metaUpdate(el,m){
  const meta=el.lastChild;const i=m.info;meta.textContent='';
  if(i.role==='assistant'){
    const t=[];if(i.modelID)t.push(i.modelID);
    if(i.time&&i.time.completed&&i.time.created)t.push(((i.time.completed-i.time.created)/1000).toFixed(1)+'s');
    if(i.tokens&&(i.tokens.output||i.tokens.input))t.push(O.fmtK((i.tokens.input||0)+(i.tokens.output||0))+' tok');
    if(i.cost)t.push('$'+i.cost.toFixed(4));
    meta.append(h('span',null,t.join('  ')));
    if(i.error&&i.error.name!=='MessageAbortedError'){const old=el.firstChild.querySelector('.errbox');if(old)old.remove();
      let em=(i.error.data&&i.error.data.message)||i.error.name||'Ошибка';
      if(/quota|usage.?limit|rate.?limit|limit\s+reached|insufficient|exceeded|credit|\b429\b/i.test(String(em)))em+='\n\n'+quotaHint();
      el.firstChild.append(h('div',{class:'errbox'},em))}
    else if(i.error)meta.append(h('span',{class:'warn'},'прервано'))}
  meta.append(h('span',{class:'grow'}),h('button',{class:'ibtn s',onclick:()=>msgActions(m)},O.icon('dots')))}
function msgText(m){return m.parts.filter(p=>p.type==='text'&&!p.synthetic).map(p=>p.text).join('\n')}
function msgActions(m){O.actions(m.info.role==='user'?'Сообщение':'Ответ',[
  {label:'Копировать текст',icon:'copy',fn:()=>O.native.copy(msgText(m))},
  m.info.role==='user'?{label:'Отменить отсюда',sub:'Откатить это сообщение и всё после него',icon:'undo',fn:()=>revertTo(m)}:null,
  {label:'Форк сессии отсюда',icon:'branch',fn:()=>forkAt(m)}])}
async function revertTo(m){try{await api('POST','/session/'+S.sid+'/revert',{messageID:m.info.id});if(m.info.role==='user'){ta.value=msgText(m);onInput()}}catch(e){O.toast(e.message)}}
async function forkAt(m){try{const s=await api('POST','/session/'+S.sid+'/fork',{messageID:m.info.id});await O.loadSessions();await O.openSession(s.id)}catch(e){O.toast(e.message)}}

// ---- tools ----
function toolMeta(p){const st=p.state||{},i=st.input||{},r=O.rel;
  switch(p.tool){
  case'bash':return{ic:'terminal',t:i.description||'Команда',s:String(i.command||'').split('\n')[0]};
  case'read':return{ic:'file',t:'Чтение',s:r(i.filePath)};
  case'edit':return{ic:'edit',t:'Правка',s:r(i.filePath)};
  case'write':return{ic:'edit',t:'Запись',s:r(i.filePath)};
  case'patch':case'apply_patch':return{ic:'edit',t:'Патч',s:''};
  case'glob':return{ic:'search',t:'Glob',s:i.pattern};
  case'grep':return{ic:'search',t:'Grep',s:i.pattern};
  case'list':return{ic:'folder',t:'Список',s:r(i.path||'.')};
  case'webfetch':return{ic:'globe',t:'Загрузка',s:i.url};
  case'websearch':case'codesearch':return{ic:'globe',t:'Поиск',s:i.query};
  case'task':return{ic:'bot',t:i.description||'Субагент',s:i.subagent_type};
  case'todowrite':case'todoread':return{ic:'list',t:'Задачи',s:(i.todos||[]).length?(i.todos.length+' шт.'):''};
  case'skill':return{ic:'bulb',t:'Навык',s:i.name};
  default:return{ic:'code',t:st.title||p.tool,s:''}}}
function toolBody(p){const st=p.state||{},i=st.input||{},md=st.metadata||{};
  const out=O.stripAnsi(st.output!=null?st.output:(md.output||''));const b=h('div');
  const pre=(t,c)=>h('pre',{class:c||'term-pre'},t);
  switch(p.tool){
  case'bash':b.append(pre('$ '+(i.command||'')+(out?'\n'+out:'')));if(md.exit!=null&&md.exit!==0)b.append(h('div',{class:'mut s'},'код '+md.exit));break;
  case'edit':if(typeof md.diff==='string'&&md.diff)b.append(O.unifiedEl(md.diff));else if(i.oldString!=null)b.append(O.diffEl(O.diffOps(String(i.oldString),String(i.newString||'')),2));break;
  case'write':b.append(pre(String(i.content||'').split('\n').slice(0,80).join('\n'),'code-pre'));break;
  case'read':b.append(pre(out.split('\n').slice(0,60).join('\n'),'code-pre'));break;
  case'todowrite':(i.todos||[]).forEach(t=>b.append(h('div',{class:'todo-i'+(t.status==='completed'?' done':'')},O.icon(t.status==='completed'?'check':'chevR'),t.content)));break;
  case'task':{const sid=md.sessionId||md.sessionID;if(i.prompt)b.append(h('div',{class:'mut s'},String(i.prompt).slice(0,500)));
    if(sid)b.append(h('button',{class:'btn sm',style:{marginTop:'8px'},onclick:()=>openChild(sid)},'Открыть сессию субагента'));if(out)b.append(pre(out.slice(0,3000),'code-pre'));break}
  default:if(Object.keys(i).length)b.append(pre(JSON.stringify(i,null,2).slice(0,3000),'code-pre'));if(out)b.append(pre(out.slice(0,6000),'code-pre'))}
  if(st.status==='error'&&st.error)b.append(h('div',{class:'errbox'},String(st.error)));return b}
function fillTool(el,p){const st=p.state||{},m=toolMeta(p),isOpen=S.opts.details&&open.has(p.id);
  el.className='part tool '+(st.status||'pending')+(isOpen?' open':'');el.textContent='';el._p=p;
  const stat=st.status==='running'||st.status==='pending'?h('span',{class:'spin'}):st.status==='error'?O.icon('alert','err'):O.icon('check','ok');
  el.append(h('button',{class:'tool-h',onclick:()=>{if(!S.opts.details)return;el._auto=2;open.has(p.id)?open.delete(p.id):open.add(p.id);fillTool(el,el._p)}},
    O.icon(m.ic),h('span',{class:'t'},m.t),h('span',{class:'sub grow'},m.s||''),stat,S.opts.details?O.icon('chevR','chev'):null));
  if(isOpen)el.append(h('div',{class:'tool-b'},toolBody(p)))}
async function openChild(sid){try{if(!O.child(sid)){const s=await api('GET','/session/'+sid);(S.childSessions=S.childSessions||{})[sid]=s}}catch{}trail.push(S.sid);await O.openSession(sid);bus.emit('session')}

// ---- banners / dock ----
function renderRevert(){const s=cur();revEl.textContent='';
  if(trail.length&&S.sid&&O.child(S.sid)){revEl.classList.remove('hide');revEl.append(h('div',{class:'card warn',style:{display:'flex',alignItems:'center',gap:'8px'}},h('span',{class:'grow'},'Сессия субагента'),h('button',{class:'btn sm',onclick:()=>{const p=trail.pop();O.openSession(p)}},'Назад')));return}
  if(s&&s.revert){revEl.classList.remove('hide');revEl.append(h('div',{class:'card warn',style:{display:'flex',alignItems:'center',gap:'8px'}},h('span',{class:'grow'},'Изменения отменены'),h('button',{class:'btn sm',onclick:doRedo},O.icon('redo'),'Вернуть')))}
  else revEl.classList.add('hide')}
function renderTodos(){const t=(S.todos[S.sid]||[]);todoEl.textContent='';
  if(!t.length||t.every(x=>x.status==='completed')){todoEl.classList.add('hide');return}
  todoEl.classList.remove('hide');const done=t.filter(x=>x.status==='completed').length;
  const list=h('div',{class:'hide',style:{marginTop:'6px'}},t.map(x=>h('div',{class:'todo-i'+(x.status==='completed'?' done':'')},O.icon(x.status==='completed'?'check':'chevR'),x.content)));
  todoEl.append(h('div',{class:'card',style:{padding:'8px 12px'}},h('button',{style:{display:'flex',alignItems:'center',gap:'8px',width:'100%'},onclick:()=>list.classList.toggle('hide')},O.icon('list'),h('b',{class:'grow',style:{textAlign:'left'}},'Задачи '+done+'/'+t.length),O.icon('chevD')),list))}
function renderStatus(){const s=S.status[S.sid];statusEl.textContent='';
  if(!s||s.type==='idle'){statusEl.classList.add('hide');return}
  statusEl.classList.remove('hide');statusEl.append(h('span',{class:'spin'}),h('span',null,s.type==='retry'?('Повтор (попытка '+s.attempt+')'+(s.message?': '+s.message:'')):'Выполняется'))}
function renderDock(){dockEl.textContent='';
  S.perms.filter(p=>p.sessionID===S.sid).forEach(p=>dockEl.append(permCard(p)));
  S.questions.filter(q=>q.sessionID===S.sid).forEach(q=>dockEl.append(questionCard(q)));
  const other=S.perms.filter(p=>p.sessionID!==S.sid)[0]||S.questions.filter(q=>q.sessionID!==S.sid)[0];
  if(other)dockEl.append(h('button',{class:'card warn',style:{textAlign:'left'},onclick:()=>O.openSession(other.sessionID)},O.icon('alert','warn'),'Другая сессия ждёт вас'));
  O.updateBadges&&O.updateBadges()}
function permCard(p){const btns=[];
  const reply=async r=>{btns.forEach(b=>b.disabled=true);try{await O.replyPermission(p,r)}catch(e){btns.forEach(b=>b.disabled=false);O.toast(e.message)}};
  btns.push(h('button',{class:'btn dng',onclick:()=>reply('reject')},'Отклонить'),h('button',{class:'btn',onclick:()=>reply('once')},'Разрешить раз'),h('button',{class:'btn pri',onclick:()=>reply('always')},'Всегда'));
  const diff=p.metadata&&typeof p.metadata.diff==='string'?p.metadata.diff:'';
  return h('div',{class:'card warn'},h('div',{style:{display:'flex',gap:'8px',alignItems:'center'}},O.icon('shield','warn'),h('b',null,'Разрешение: '+p.title)),
    p.patterns.length?h('div',{class:'mono s mut',style:{marginTop:'4px',wordBreak:'break-all'}},p.patterns.join('\n')):null,
    diff?h('details',{style:{marginTop:'6px'}},h('summary',{class:'s'},'Показать изменения'),O.unifiedEl(diff)):null,h('div',{class:'row'},btns))}
function questionCard(q){const qs=q.questions||[];const sel=qs.map(()=>new Set());const custom=qs.map(()=>'');
  const send=async()=>{try{await api('POST','/question/'+q.id+'/reply',{answers:qs.map((_,i)=>[...sel[i],...(custom[i]?[custom[i]]:[])])});S.questions=S.questions.filter(x=>x.id!==q.id);renderDock()}catch(e){O.toast(e.message)}};
  const rej=async()=>{try{await api('POST','/question/'+q.id+'/reject',{});S.questions=S.questions.filter(x=>x.id!==q.id);renderDock()}catch(e){O.toast(e.message)}};
  const body=qs.map((x,i)=>{const opts=h('div',{style:{display:'flex',flexDirection:'column',gap:'6px',marginTop:'6px'}},(x.options||[]).map(o=>{
      const b=h('button',{class:'li',style:{border:'1px solid var(--line)',padding:'8px 10px'},onclick:()=>{if(x.multiple){sel[i].has(o.label)?sel[i].delete(o.label):sel[i].add(o.label)}else{sel[i].clear();sel[i].add(o.label)}opts.querySelectorAll('button').forEach((bb,k)=>bb.classList.toggle('on',sel[i].has(x.options[k].label)))}},
        h('div',{class:'t'},h('b',null,o.label),o.description?h('span',null,o.description):null));return b}));
    return h('div',{style:{marginTop:'6px'}},x.header?h('b',null,x.header):null,h('div',null,x.question),opts,x.custom===false?null:h('input',{placeholder:'Свой вариант ответа',style:{marginTop:'6px'},oninput:e=>{custom[i]=e.target.value}}))});
  return h('div',{class:'card warn'},h('div',{style:{display:'flex',gap:'8px',alignItems:'center'}},O.icon('info','warn'),h('b',null,'OpenCode спрашивает')),body,h('div',{class:'row'},h('button',{class:'btn',onclick:rej},'Пропустить'),h('button',{class:'btn pri',onclick:send},'Отправить')))}

// ---- composer ----
const quotaHint=()=>S.account&&S.account.email
  ?'Квота этой модели исчерпана. Перезапустите сервер (Настройки → Совместимость), выберите другую модель или подключите свой ключ: Настройки → Модели → Подключить провайдера'
  :'Квота исчерпана. Войдите в аккаунт opencode (Google/GitHub): Настройки → Аккаунт opencode — или подключите свой ключ: Настройки → Модели → Подключить провайдера';
function updateChips(){const m=S.model,mi=m&&O.modelInfo(m.providerID,m.modelID);
  agentChip.lastChild.textContent=S.agent;modelChip.lastChild.textContent=mi?(mi.name||m.modelID):'Выберите модель';
  const vs=mi&&mi.variants?Object.keys(mi.variants):[];varChip.classList.toggle('hide',!vs.length);varChip.lastChild.textContent=S.variant||'по умолчанию';
  const nokey=!m&&!S.offline&&S.up;nokeyEl.classList.toggle('hide',!nokey);if(nokey)ta.placeholder='Спросите что угодно, / команды, @ файлы';
  ta.disabled=!!S.offline&&!S.up;ta.placeholder=ta.disabled?'Офлайн — чтение кэшированных чатов':'Спросите что угодно, / команды, @ файлы';updateSend()}
function cycleVariant(){const mi=O.modelInfo(S.model.providerID,S.model.modelID),vs=[null,...Object.keys(mi.variants||{})];O.setVariant(vs[(vs.indexOf(S.variant)+1)%vs.length])}
function updateSend(){const b=busy(),has=ta.value.trim()||atts.length;sendBtn.classList.toggle('stop',b&&!has);sendBtn.textContent='';sendBtn.append(O.icon(b&&!has?'stop':'send'));sendBtn.disabled=!b&&!has}
function autosize(){ta.style.height='auto';ta.style.height=Math.min(ta.scrollHeight,160)+'px'}
const BUILTINS=[
 {n:'new',d:'Начать новую сессию',i:'plus',run:()=>O.newSession()},
 {n:'sessions',d:'Переключить сессию',i:'list',run:()=>O.openSessions()},
 {n:'models',d:'Выбрать модель',i:'cpu',run:()=>O.openModels()},
 {n:'agents',d:'Выбрать агента',i:'bot',run:()=>O.openAgents()},
 {n:'connect',d:'Подключить провайдера (OpenCode Zen, OpenAI, ...)',i:'key',run:()=>O.openConnect()},
 {n:'init',d:'Создать или обновить AGENTS.md',i:'doc',run:()=>doInit()},
 {n:'undo',d:'Отменить последнее сообщение и его изменения файлов',i:'undo',run:()=>doUndo()},
 {n:'redo',d:'Вернуть отменённые изменения',i:'redo',run:()=>doRedo()},
 {n:'compact',d:'Сжать сессию, чтобы освободить контекст',i:'refresh',run:()=>doCompact()},
 {n:'share',d:'Поделиться сессией',i:'share',run:()=>doShare()},
 {n:'unshare',d:'Отключить шаринг',i:'share',run:()=>doUnshare()},
 {n:'export',d:'Экспорт диалога в Markdown',i:'down',run:()=>doExport()},
 {n:'themes',d:'Сменить тему',i:'palette',run:()=>O.openThemes()},
 {n:'thinking',d:'Показать или скрыть размышления',i:'bulb',run:()=>{S.opts.thinking=!S.opts.thinking;O.saveOpts();renderAll()}},
 {n:'details',d:'Раскрыть или закрепить детали инструментов',i:'code',run:()=>{S.opts.details=!S.opts.details;O.saveOpts();renderAll()}},
 {n:'status',d:'Серверы MCP, LSP и плагины',i:'server',run:()=>O.openStatus()},
 {n:'files',d:'Файлы проекта',i:'folder',run:()=>O.setTab('files')},
 {n:'terminal',d:'Терминал',i:'terminal',run:()=>O.setTab('term')},
 {n:'settings',d:'Настройки приложения',i:'sliders',run:()=>O.openSettings()},
 {n:'help',d:'Что я умею',i:'info',run:()=>O.openHelp()},
 {n:'exit',d:'Свернуть приложение (сервер продолжает работать)',i:'out',run:()=>OC.minimize()}];
async function sess(){if(S.sid)return S.sid;const s=await O.newSession();return s.id}
async function doInit(){if(!S.model)return O.openConnect();try{const sid=await sess();api('POST','/session/'+sid+'/init',{messageID:O.mid(),providerID:S.model.providerID,modelID:S.model.modelID},{timeout:3600000}).catch(e=>O.toast(e.message))}catch(e){O.toast(e.message)}}
async function doUndo(){const l=O.visibleMsgs(S.sid||'').filter(m=>m.info.role==='user');if(!l.length)return O.toast('Нечего отменять');revertTo(l[l.length-1])}
async function doRedo(){try{await api('POST','/session/'+S.sid+'/unrevert',{})}catch(e){O.toast(e.message)}}
async function doCompact(){if(!S.sid||!S.model)return;try{await api('POST','/session/'+S.sid+'/summarize',{providerID:S.model.providerID,modelID:S.model.modelID},{timeout:600000});O.toast('Сессия сжата')}catch(e){O.toast(e.message)}}
async function doShare(){try{const s=await api('POST','/session/'+S.sid+'/share',{});const u=s.share&&s.share.url;if(u){O.native.copy(u);O.native.share(u)}}catch(e){O.toast(e.message)}}
async function doUnshare(){try{await api('DELETE','/session/'+S.sid+'/share');O.toast('Шаринг остановлен')}catch(e){O.toast(e.message)}}
function doExport(){if(!S.sid)return;const md=O.visibleMsgs(S.sid).map(m=>'## '+(m.info.role==='user'?'Пользователь':'Ассистент')+'\n\n'+m.parts.filter(p=>p.type==='text'&&!p.synthetic).map(p=>p.text).join('\n\n')).join('\n\n');O.native.share(md)}
O.builtins=BUILTINS;
function hidePop(){popEl.classList.add('hide');popEl.textContent=''}
function showPop(items){popEl.textContent='';if(!items.length){hidePop();return}popEl.classList.remove('hide');
  items.slice(0,40).forEach(it=>popEl.append(h('button',{class:'it',style:{width:'100%',textAlign:'left'},onclick:it.pick},it.icon?it.icon:null,h('b',null,it.t),h('span',{class:'d grow'},it.d||''))))}
let atTimer;
function onInput(){autosize();updateSend();const v=ta.value,pos=ta.selectionStart||0,before=v.slice(0,pos);
  const sm=/^\/(\S*)$/.exec(before);
  if(sm){const q=sm[1].toLowerCase();
    const srv=(S.commands||[]).filter(c=>!BUILTINS.some(b=>b.n===c.name)).map(c=>({t:'/'+c.name,d:c.description||'Пользовательская команда',icon:O.icon('slash'),f:c.name,pick:()=>{ta.value='/'+c.name+' ';ta.focus();onInput()}}));
    const bi=BUILTINS.map(b=>({t:'/'+b.n,d:b.d,icon:O.icon(b.i),f:b.n,pick:()=>{ta.value='';autosize();hidePop();updateSend();b.run()}}));
    showPop([...bi,...srv].filter(x=>x.f.startsWith(q)||(q.length>1&&x.f.includes(q))));return}
  const am=/(?:^|\s)@(\S*)$/.exec(before);
  if(am){const q=am[1];clearTimeout(atTimer);atTimer=setTimeout(async()=>{
    const ags=O.subagents().filter(a=>a.name.startsWith(q)).map(a=>({t:'@'+a.name,d:a.description||'Субагент',icon:O.icon('bot'),pick:()=>insertMention('@'+a.name,{type:'agent',name:a.name},pos-q.length-1,pos)}));
    let files=[];try{files=await api('GET','/find/file?query='+encodeURIComponent(q)+'&limit=30')}catch{}
    const fi=(files||[]).map(f=>{const dir=f.endsWith('/');return{t:O.basename(f),d:f,icon:O.fileIcon(O.basename(f),dir),pick:()=>insertMention('@'+f,{type:'file',mime:dir?'application/x-directory':'text/plain',url:'file://'+S.dir+'/'+f.replace(/\/$/,''),filename:O.basename(f),source:{type:'file',path:S.dir+'/'+f.replace(/\/$/,''),text:{value:'@'+f,start:0,end:0}}},pos-q.length-1,pos)}});
    if(ta.value.slice(0,pos)===before)showPop([...ags,...fi])},160);return}
  hidePop()}
O.subagents=()=>(S.agents||[]).filter(a=>a.mode==='subagent'||a.mode==='all');
function insertMention(tok,part,from,to){ta.value=ta.value.slice(0,from)+tok+' '+ta.value.slice(to);const p=from+tok.length+1;ta.setSelectionRange(p,p);mentions.push({tok,part});hidePop();ta.focus();onInput()}
O.addMention=(path,isDir)=>{const rel=O.rel(path);const tok='@'+rel;const abs=path.startsWith('/')?path:S.dir+'/'+path;
  ta.value=(ta.value?ta.value+' ':'')+tok+' ';mentions.push({tok,part:{type:'file',mime:isDir?'application/x-directory':'text/plain',url:'file://'+abs,filename:O.basename(path),source:{type:'file',path:abs,text:{value:tok,start:0,end:0}}}});O.setTab('chat');ta.focus();onInput()};
O.insertText=t=>{ta.value=t;onInput();ta.focus()};
function onFiles(){const files=[...fileIn.files];fileIn.value='';for(const f of files){
  const mi=S.model&&O.modelInfo(S.model.providerID,S.model.modelID);
  if(!(f.type||'').startsWith('text/')&&mi&&mi.attachment===false){O.toast('Эта модель не принимает вложения');continue}
  if(f.size>8e6){O.toast(f.name+' слишком большой (макс. 8 МБ)');continue}
  const r=new FileReader();r.onload=()=>{atts.push({type:'file',mime:f.type||'application/octet-stream',filename:f.name,url:r.result});renderAtts()};r.readAsDataURL(f)}}
function renderAtts(){attsEl.textContent='';attsEl.classList.toggle('hide',!atts.length);
  atts.forEach((a,i)=>attsEl.append(h('span',{class:'chip'},a.mime.startsWith('image/')?h('img',{src:a.url,style:{height:'22px',borderRadius:'4px'}}):O.fileIcon(a.filename),h('span',null,a.filename),h('button',{onclick:()=>{atts.splice(i,1);renderAtts();updateSend()}},O.icon('x')))));updateSend()}
async function onSend(){
  if(busy()&&!ta.value.trim()&&!atts.length){try{await api('POST','/session/'+S.sid+'/abort',{})}catch(e){O.toast(e.message)}return}
  const text=ta.value.trim();if(!text&&!atts.length)return;
  const cm=/^\/(\S+)(?:\s+([\s\S]*))?$/.exec(text);
  if(cm){const b=BUILTINS.find(x=>x.n===cm[1]);if(b){clear();b.run();return}
    const sc=(S.commands||[]).find(c=>c.name===cm[1]);
    if(sc){if(!S.model)return O.openConnect();clear();try{const sid=await sess();api('POST','/session/'+sid+'/command',{command:sc.name,arguments:cm[2]||'',agent:S.agent,model:modelStr()},{timeout:3600000}).catch(e=>O.toast(e.message))}catch(e){O.toast(e.message)}return}}
  if(!S.model){O.toast('Подключите провайдера, чтобы выбрать модель');O.openConnect();return}
  if(text.startsWith('!')){const cmd=text.slice(1).trim();
    if(/^opencode(\s+tui)?\s*$/i.test(cmd)){O.toast('Приложение уже является интерфейсом OpenCode. TUI — во вкладке «Терминал» → Shell, агент — во вкладке «Чат»',6000);clear();return}
    clear();try{const sid=await sess();api('POST','/session/'+sid+'/shell',{agent:S.agent,model:S.model,command:cmd},{timeout:3600000}).catch(e=>O.toast(e.message))}catch(e){O.toast(e.message)}return}
  const parts=[];if(text)parts.push({type:'text',text});
  mentions.filter(m=>text.includes(m.tok)).forEach(m=>{const p=JSON.parse(JSON.stringify(m.part));if(p.source&&p.source.text){p.source.text.start=text.indexOf(m.tok);p.source.text.end=p.source.text.start+m.tok.length}parts.push(p)});
  atts.forEach(a=>parts.push(a));
  const mid=O.mid();clear();
  try{const sid=await sess();
    const m=O.upsertMsg({id:mid,sessionID:sid,role:'user',time:{created:Date.now()},agent:S.agent,model:S.model});m.local=true;
    m.parts=parts.map((p,i)=>Object.assign({id:'prt_local'+i,sessionID:sid,messageID:mid},p));bus.emit('msg',sid,m);scrollEnd(true);
    await api('POST','/session/'+sid+'/prompt_async',{messageID:mid,agent:S.agent,model:S.model,variant:S.variant||undefined,parts},{timeout:30000});
  }catch(e){const s=O.msgs(S.sid);s.list=s.list.filter(x=>x.info.id!==mid);s.idx.delete(mid);const el=msgEls.get(mid);if(el){el.remove();msgEls.delete(mid)}O.toast(e.message,4000);ta.value=text;onInput()}}
function clear(){ta.value='';atts=[];mentions=[];renderAtts();autosize();hidePop();updateSend()}
O.chat={renderAll,sess,focus:()=>ta&&ta.focus()};
})();
