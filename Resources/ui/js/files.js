(function(){
const O=window.OCM,h=O.h,S=O.S,api=O.api,bus=O.bus;
let treeEl,titleEl,exp=new Set(),cache=new Map(),gst={};
const sortN=a=>a.sort((x,y)=>(x.type===y.type?0:x.type==='directory'?-1:1)||x.name.localeCompare(y.name));
const absOf=n=>n.absolute||(S.dir+'/'+n.path);
O.filesInit=root=>{
  titleEl=h('b',{class:'grow',style:{overflow:'hidden',textOverflow:'ellipsis',whiteSpace:'nowrap'}},'Файлы');
  treeEl=h('div',{id:'tree'});
  root.append(h('div',{class:'pane-h'},O.icon('folder'),titleEl,
    h('button',{class:'ibtn s',onclick:()=>newEntry('',false)},O.icon('plus')),h('button',{class:'ibtn s',onclick:()=>O.refreshFiles(true)},O.icon('refresh'))),treeEl);
  bus.on('files',O.debounce(()=>O.refreshFiles(false),600));bus.on('dir',()=>{exp.clear();cache.clear();treeEl.textContent='';titleEl.textContent=O.basename(S.dir)||'/'});
  bus.on('idle',()=>O.refreshFiles(false))};
async function list(p){
  const tries=p==='.'?['.','']:[p];
  for(const t of tries){try{const n=await api('GET','/file?path='+encodeURIComponent(t));cache.set(p,sortN(n));O.kv.set('files:'+S.dir+':'+p,n);return}catch(e){}}
  const c=await O.kv.get('files:'+S.dir+':'+p);if(c)cache.set(p,sortN(c))}
O.refreshFiles=async force=>{titleEl.textContent=O.basename(S.dir)||'/';
  if(force)cache.clear();
  await list('.');for(const p of exp)if(!cache.has(p)||force)await list(p);
  try{const st=await api('GET','/file/status');gst={};(st||[]).forEach(f=>gst[f.path]=f.status);S.gstatus=gst}catch{}
  draw()};
function draw(){const fr=document.createDocumentFragment();const walk=(p,depth)=>{(cache.get(p)||[]).forEach(n=>{
    const isDir=n.type==='directory',isOpen=isDir&&exp.has(n.path),st=gst[n.path];
    const row=h('div',{class:'tn'+(n.ignored?' ign':'')+(st==='modified'?' m':st==='added'?' a':''),style:{paddingLeft:(10+depth*14)+'px'}},
      isDir?O.icon(isOpen?'chevD':'chevR'):h('span',{style:{width:'20px',flex:'none'}}),O.fileIcon(n.name,isDir,isOpen),h('span',{class:'nm grow'},n.name),st?h('span',{class:'s'},st==='added'?'A':st==='deleted'?'D':'M'):null);
    let lp=null,fired=false;
    row.addEventListener('pointerdown',()=>{fired=false;lp=setTimeout(()=>{fired=true;nodeActions(n)},480)});
    ['pointerup','pointerleave','pointermove','pointercancel'].forEach(ev=>row.addEventListener(ev,()=>clearTimeout(lp)));
    row.addEventListener('click',async()=>{if(fired)return;
      if(isDir){if(exp.has(n.path))exp.delete(n.path);else{exp.add(n.path);if(!cache.has(n.path))await list(n.path)}draw()}else O.openFile(n)});
    fr.append(row);if(isOpen)walk(n.path,depth+1)})};
  walk('.',0);treeEl.textContent='';treeEl.append(fr);
  if(!treeEl.firstChild)treeEl.append(h('div',{class:'mut',style:{padding:'20px',textAlign:'center'}},'Файлов пока нет'))}
function nodeActions(n){const isDir=n.type==='directory',abs=absOf(n);
  O.actions(n.name,[
    {label:'Спросить агента об этом',icon:'at',fn:()=>O.addMention(abs,isDir)},
    isDir?{label:'Новый файл здесь',icon:'plus',fn:()=>newEntry(n.path,false)}:null,
    isDir?{label:'Новая папка здесь',icon:'folder',fn:()=>newEntry(n.path,true)}:null,
    {label:'Переименовать',icon:'edit',fn:async()=>{const v=await O.ask('Переименование',null,n.name);if(!v||v===n.name)return;const r=O.native.fs('rename',abs,v);r.ok?O.refreshFiles(true):O.toast(r.err||'Не удалось')}},
    {label:'Копировать путь',icon:'copy',fn:()=>O.native.copy(abs)},
    {label:'Удалить',icon:'trash',danger:true,fn:async()=>{if(await O.confirm('Удалить '+n.name+'?','Это действие нельзя отменить.','Удалить',true)){const r=O.native.fs('delete',abs);r.ok?O.refreshFiles(true):O.toast(r.err||'Не удалось')}}}])}
async function newEntry(dirRel,isDir){const name=await O.ask(isDir?'Новая папка':'Новый файл','Название');if(!name)return;
  const base=dirRel&&dirRel!=='.'?S.dir+'/'+dirRel:S.dir;const r=O.native.fs(isDir?'mkdir':'create',base+'/'+name);
  if(!r.ok)return O.toast(r.err||'Не удалось');if(dirRel)exp.add(dirRel);O.refreshFiles(true)}

// ---- viewer / editor ----
O.openFile=async n=>{const rel=typeof n==='string'?n:n.path,abs=typeof n==='string'?(n.startsWith('/')?n:S.dir+'/'+n):absOf(n);
  const body=h('div',{style:{display:'flex',flexDirection:'column',height:'100%',margin:'-10px -12px -16px'}},h('div',{class:'mut',style:{padding:'20px'}},'Загрузка...'));
  let text=null,editing=false,img=null;
  const actions=h('span',{style:{display:'flex'}});
  const s=O.sheet(O.basename(abs),body,{full:true,actions});
  const paint=()=>{body.textContent='';actions.textContent='';
    if(text==null){body.append(img?h('div',{style:{padding:'12px',overflow:'auto'}},h('img',{src:img,style:{maxWidth:'100%'}})):h('div',{class:'mut',style:{padding:'20px'}},'Бинарный файл — не отображается'));return}
    actions.append(h('button',{class:'ibtn',onclick:()=>O.addMention(abs,false)||s.close()},O.icon('at')),h('button',{class:'ibtn',onclick:()=>O.native.copy(text)},O.icon('copy')),
      h('button',{class:'ibtn',onclick:()=>{editing=!editing;paint()}},O.icon(editing?'check':'edit')));
    if(editing){const ta=h('textarea',{class:'editor',spellcheck:'false'});ta.value=text;body.append(ta,h('div',{class:'cmdline'},h('button',{class:'btn grow',onclick:()=>{editing=false;paint()}},'Отмена'),h('button',{class:'btn pri grow',onclick:()=>{const r=O.native.writeText(abs,ta.value);if(r.ok){text=ta.value;editing=false;O.toast('Сохранено',1200);paint();O.refreshFiles(false)}else O.toast(r.err||'Не удалось сохранить')}},'Сохранить')))}
    else body.append(O.codeView(text,abs))};
  try{const r=await api('GET','/file/content?path='+encodeURIComponent(rel));
    if(r.type==='text'||typeof r.content==='string'&&r.encoding!=='base64')text=r.content;else if(r.encoding==='base64'&&(r.mimeType||'').startsWith('image/'))img='data:'+r.mimeType+';base64,'+r.content}
  catch(e){const r=O.native.readText(abs);if(r.ok)text=r.text;else body.textContent='Не удаётся открыть файл: '+(e.message||'')}
  paint()};

// ---- changes ----
let chEl,chMode='session',chList;
O.changesInit=root=>{
  chList=h('div',{style:{flex:1,overflow:'auto',padding:'6px 8px'}});
  const seg=h('div',{class:'seg',style:{margin:'8px 10px'}},h('button',{class:'on',onclick:e=>{chMode='session';mark(e.target);O.refreshChanges()}},'Эта сессия'),h('button',{onclick:e=>{chMode='git';mark(e.target);O.refreshChanges()}},'Статус Git'));
  const mark=b=>{seg.querySelectorAll('button').forEach(x=>x.classList.toggle('on',x===b))};
  root.append(seg,chList);
  bus.on('diff',sid=>{if(sid===S.sid)O.refreshChanges(true)});bus.on('open',()=>O.refreshChanges(true));bus.on('files',O.debounce(()=>O.refreshChanges(false),800))};
O.changesCount=()=>(S.diffs[S.sid]||[]).length;
O.refreshChanges=async local=>{chList.textContent='';
  if(chMode==='session'){const d=S.diffs[S.sid]||[];
    if(!d.length)chList.append(h('div',{class:'mut',style:{padding:'24px',textAlign:'center'}},'В этой сессии пока нет изменений'));
    d.forEach(f=>chList.append(h('button',{class:'li',onclick:()=>showDiff(f)},O.fileIcon(O.basename(f.file)),h('div',{class:'t'},h('b',null,O.basename(f.file)),h('span',null,O.dirname(f.file)==='.'?'':O.dirname(f.file))),
      h('span',{class:'s ok'},'+'+(f.additions||0)),h('span',{class:'s err'},'-'+(f.deletions||0)))))}
  else{let st=[];try{st=await api('GET','/file/status')}catch{}
    if(!st.length)chList.append(h('div',{class:'mut',style:{padding:'24px',textAlign:'center'}},'Рабочее дерево чистое'));
    st.forEach(f=>chList.append(h('button',{class:'li',onclick:()=>showGit(f)},O.fileIcon(O.basename(f.path)),h('div',{class:'t'},h('b',null,O.basename(f.path)),h('span',null,f.status+'  '+O.dirname(f.path))),
      h('span',{class:'s ok'},'+'+(f.added||0)),h('span',{class:'s err'},'-'+(f.removed||0)))))}
  O.updateBadges&&O.updateBadges()};
function showDiff(f){const b=h('div');
  if(typeof f.before==='string'||typeof f.after==='string')b.append(O.diffEl(O.diffOps(f.before||'',f.after||''),3));
  else if(typeof f.diff==='string'||typeof f.patch==='string')b.append(O.unifiedEl(f.diff||f.patch));
  else b.append(h('div',{class:'mut'},'Diff недоступен'));
  O.sheet(f.file,b,{full:true})}
async function showGit(f){const b=h('div',null,h('div',{class:'mut'},'Загрузка...'));O.sheet(f.path,b,{full:true});
  try{const r=await api('GET','/file/content?path='+encodeURIComponent(f.path));b.textContent='';
    if(typeof r.diff==='string'&&r.diff)b.append(O.unifiedEl(r.diff));
    else if(r.patch&&r.patch.hunks)b.append(O.unifiedEl(r.patch.hunks.map(x=>'@@ -'+x.oldStart+','+x.oldLines+' +'+x.newStart+','+x.newLines+' @@\n'+x.lines.join('\n')).join('\n')));
    else b.append(O.codeView(r.content||'',f.path))}catch(e){b.textContent=e.message}}
})();
