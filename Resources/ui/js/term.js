(function(){
const O=window.OCM,h=O.h,S=O.S,api=O.api,bus=O.bus;
let logEl,xwrap,xhost,keys,term,fit,pty=null,wsid=null,ctrl=false,sub='agent',subBtns={},aPane,sPane,ctrlBtn;
const logEls=new Map();
O.termInit=root=>{
  logEl=h('div',{id:'agentlog',class:'sel'});
  const inp=h('input',{class:'mono',placeholder:'команда (видна агенту)',autocapitalize:'off',autocorrect:'off',spellcheck:'false',onkeydown:e=>{if(e.key==='Enter')run()}});
  const run=async()=>{const c=inp.value.trim();if(!c)return;if(!S.model){O.toast('Сначала подключите провайдера');return}inp.value='';
    if(/^opencode(\s+tui)?\s*$/i.test(c)){O.toast('Приложение уже является интерфейсом OpenCode. Интерактивный TUI запускайте во вкладке «Shell», для работы с агентом — вкладка «Чат»',6000);return}
    try{const sid=await O.chat.sess();api('POST','/session/'+sid+'/shell',{agent:S.agent,model:S.model,command:c},{timeout:3600000}).catch(e=>O.toast(e.message))}catch(e){O.toast(e.message)}};
  aPane=h('div',{style:{display:'flex',flexDirection:'column',flex:1,minHeight:0}},logEl,h('div',{class:'cmdline'},inp,h('button',{class:'btn pri',onclick:run},O.icon('play'))));
  xhost=h('div',{id:'xterm'});xwrap=h('div',{id:'xwrap'},xhost);
  const mk=(label,fn,icon,cls)=>h('button',{class:cls||'',onclick:fn},icon?O.icon(icon):label);
  ctrlBtn=mk('Ctrl',()=>{ctrl=!ctrl;ctrlBtn.classList.toggle('on',ctrl)});
  const send=s=>()=>{if(wsid)OC.wsSend(wsid,s);term&&term.focus()};
  const arrow=(seq,rot)=>{const b=mk('',send(seq),'chevD');b.firstChild.style.transform='rotate('+rot+'deg)';return b};
  keys=h('div',{id:'keys'},mk('Esc',send('\x1b')),mk('Tab',send('\t')),ctrlBtn,arrow('\x1b[A',180),arrow('\x1b[B',0),arrow('\x1b[D',90),arrow('\x1b[C',-90),
    mk('|',send('|')),mk('/',send('/')),mk('-',send('-')),mk('~',send('~')),mk('$',send('$')),mk('^C',send('\x03')),mk('^D',send('\x04')),
    h('button',{onclick:()=>{const t=OC.pasteText();if(t&&wsid)OC.wsSend(wsid,t)}},O.icon('copy')));
  sPane=h('div',{style:{display:'none',flexDirection:'column',flex:1,minHeight:0}},xwrap,keys);
  const tabs=h('div',{class:'tsub'},subBtns.agent=h('button',{class:'on',onclick:()=>setSub('agent')},'Агент'),subBtns.shell=h('button',{onclick:()=>setSub('shell')},'Shell'),h('span',{class:'grow'}),
    h('button',{class:'ibtn s',onclick:restart},O.icon('refresh')));
  root.append(tabs,aPane,sPane);
  bus.on('open',rebuildLog);bus.on('part',(sid,m,p)=>{if(sid===S.sid&&p&&p.type==='tool'&&p.tool==='bash')upsertEntry(p)});
  O.on('ws',onWs);
  new ResizeObserver(O.debounce(()=>{if(sub==='shell')doFit()},120)).observe(xhost)};
function setSub(s){sub=s;subBtns.agent.classList.toggle('on',s==='agent');subBtns.shell.classList.toggle('on',s==='shell');
  aPane.style.display=s==='agent'?'flex':'none';sPane.style.display=s==='shell'?'flex':'none';if(s==='shell')startPty()}
O.termShown=()=>{if(sub==='shell')setTimeout(doFit,60)};
function rebuildLog(){logEl.textContent='';logEls.clear();if(!S.sid)return;
  for(const m of O.visibleMsgs(S.sid))for(const p of m.parts)if(p.type==='tool'&&p.tool==='bash')upsertEntry(p,true)}
function upsertEntry(p,quiet){const st=p.state||{},i=st.input||{},md=st.metadata||{};
  const out=O.stripAnsi(st.output!=null?st.output:(md.output||''));
  let e=logEls.get(p.id);const near=logEl.scrollHeight-logEl.scrollTop-logEl.clientHeight<80;
  if(!e){e={cmd:h('div',{class:'cmd'}),out:h('div',{class:'out'}),meta:h('div',{class:'meta'})};logEls.set(p.id,e);logEl.append(e.cmd,e.out,e.meta)}
  e.cmd.textContent='$ '+(i.command||'');if(e.out._t!==out){e.out._t=out;e.out.textContent=out.length>20000?out.slice(-20000):out}
  e.meta.textContent=st.status==='running'?'выполняется...':(md.exit!=null?'код '+md.exit:'')+(st.status==='error'?' ошибка':'');
  if(near&&!quiet)logEl.scrollTop=logEl.scrollHeight}
function theme(){const c=getComputedStyle(document.documentElement),g=n=>c.getPropertyValue(n).trim();return{background:g('--code'),foreground:g('--fg'),cursor:g('--acc'),selectionBackground:g('--bg3')}}
function doFit(){if(!fit||!term||!xhost.offsetParent)return;try{fit.fit()}catch{}
  if(pty)api('PUT','/pty/'+pty.id,{size:{cols:term.cols,rows:term.rows}}).catch(()=>{})}
async function startPty(){
  if(!term){term=new Terminal({fontSize:13,fontFamily:'ui-monospace,Menlo,Consolas,monospace',cursorBlink:true,scrollback:5000,theme:theme(),allowProposedApi:true});
    fit=new FitAddon.FitAddon();term.loadAddon(fit);term.open(xhost);
    term.onData(d=>{if(!wsid)return;if(ctrl&&d.length===1){d=String.fromCharCode(d.toUpperCase().charCodeAt(0)&31);ctrl=false;ctrlBtn.classList.remove('on')}OC.wsSend(wsid,d)});
    term.onResize(()=>{if(pty)api('PUT','/pty/'+pty.id,{size:{cols:term.cols,rows:term.rows}}).catch(()=>{})})}
  doFit();if(pty&&wsid)return;
  try{if(!pty)pty=await api('POST','/pty',{cwd:S.dir,title:'shell'});
    wsid='w'+Date.now().toString(36);OC.wsOpen(wsid,'/pty/'+pty.id+'/connect?directory='+encodeURIComponent(S.dir))}
  catch(e){term.write('\r\n\x1b[31mТерминал недоступен: '+(e.message||'ошибка')+'\x1b[0m\r\nИспользуйте вкладку «Агент», чтобы запускать команды.\r\n')}}
function onWs(d){if(d.id!==wsid)return;
  if(d.t==='open'){setTimeout(doFit,50)}
  else if(d.t==='msg')term.write(d.d);
  else if(d.t==='bin'){const bin=atob(d.d),u=new Uint8Array(bin.length);for(let i=0;i<bin.length;i++)u[i]=bin.charCodeAt(i);term.write(u)}
  else if(d.t==='close'||d.t==='err'){term.write('\r\n\x1b[33m[сессия закрыта — нажмите ⟳, чтобы запустить новый shell]\x1b[0m\r\n');wsid=null}}
async function restart(){if(sub==='agent'){rebuildLog();return}
  if(wsid){OC.wsClose(wsid);wsid=null}if(pty){api('DELETE','/pty/'+pty.id).catch(()=>{});pty=null}if(term)term.reset();startPty()}
bus.on('dir',()=>{if(wsid){OC.wsClose(wsid);wsid=null}pty=null;if(term)term.reset()});
})();
