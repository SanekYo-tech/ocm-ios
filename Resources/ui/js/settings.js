(function(){
const O=window.OCM,h=O.h,S=O.S,api=O.api,bus=O.bus;
const CFG='/root/.config/opencode';
const cfg={read(){const t=O.native.cfgRead();if(!t.trim())return{obj:{},raw:''};try{return{obj:O.parseJsonc(t),raw:t}}catch(e){return{obj:null,raw:t,err:e.message}}},
  write(o){return O.native.cfgWrite(typeof o==='string'?o:JSON.stringify(o,null,2))}};
const restartBar=()=>h('button',{class:'btn wide',style:{marginTop:'12px'},onclick:()=>{OC.restartServer();O.toast('Перезапуск сервера...');O.back()}},O.icon('refresh'),'Перезапустить сервер для применения');
const sub=(t,b,o)=>O.sheet(t,b,Object.assign({full:true},o));

// ---- main ----
O.openSettings=()=>{
  const st=O.native.state(),fl=st.flags||{};
  const body=h('div');const s=O.sheet('Настройки',body);
  // профиль: у каждого гостя — свой случайный ник и пароль (никогда общий аккаунт)
  const prof=h('div',{class:'card',style:{display:'flex',alignItems:'center',gap:'10px'}},
    O.icon('user'),
    h('div',{class:'grow'},
      h('b',null,st.name||'Гость'),
      h('div',{class:'mut s'},st.guest?('Гостевой профиль · ник создан случайно'):(st.user?('Профиль: '+st.user):'Профиль не выбран')),
      st.guest&&st.pw?h('div',{class:'mut s',style:{display:'flex',alignItems:'center',gap:'6px'}},h('span',{class:'mono'},'Пароль профиля: '+st.pw),h('button',{class:'ibtn s',onclick:()=>O.native.copy(st.pw)},O.icon('copy'))):null),
    h('button',{class:'btn sm',onclick:async()=>{if(await O.confirm('Сменить профиль?','Чаты и файлы останутся на телефоне и будут доступны при повторном входе.','Сменить'))OC.signOut()}},O.icon('out'),'Сменить'));
  body.append(prof);
  const g=t=>body.append(h('div',{class:'grp'},t)),r=(i,t,sb,fn)=>body.append(O.listRow(i,t,sb,O.icon('chevR'),fn));
  g('Аккаунт opencode');
  const accRow=O.listRow('user','Аккаунт opencode','проверяем...',O.icon('chevR'),()=>O.openAccount());body.append(accRow);
  const accSub=()=>{const sp=accRow.querySelector('.t span');if(!sp)return;
    sp.textContent=S.account&&S.account.email?('Вход выполнен: '+S.account.email):(S.account&&S.account.checked?'Не выполнен — квота Zen общая':'проверяем...')};
  accSub();O.checkAccount().then(accSub);
  g('Модели');r('key','Подключить провайдера','OpenCode Zen, OpenAI, Anthropic, GitHub Copilot, Google и другие',()=>O.openConnect());
  r('cpu','Модель',S.model?S.model.providerID+'/'+S.model.modelID:'не выбрана',()=>O.openModels());
  g('Оформление');r('palette','Тема и размер текста',({opencode:'OpenCode',light:'Светлая',tokyonight:'Tokyo Night',gruvbox:'Gruvbox'})[S.opts.theme]||S.opts.theme+', '+S.opts.fs+'px',()=>O.openThemes());
  body.append(O.toggleRow('bulb','Показывать размышления','Блоки размышлений в ответах',S.opts.thinking,v=>{S.opts.thinking=v;O.saveOpts();O.chat.renderAll()}));
  body.append(O.toggleRow('code','Раскрытие деталей инструментов','Нажмите на карточку инструмента, чтобы увидеть команды, вывод и изменения',S.opts.details,v=>{S.opts.details=v;O.saveOpts();O.chat.renderAll()}));
  g('Звуки и уведомления');
  [['snd_done','Задача завершена','Агент закончил работу','done'],['snd_action','Требуется действие','Ожидается разрешение или вопрос','action'],['snd_quota','Квота исчерпана','Превышен лимит модели или запросов','quota']].forEach(([k,t,d,kind])=>
    body.append(h('div',{style:{display:'flex',alignItems:'center'}},h('div',{class:'grow'},O.toggleRow('bell',t,d,fl[k]!==false,v=>OC.setFlag(k,v))),h('button',{class:'ibtn',onclick:()=>OC.testSound(kind)},O.icon('play')))));
  g('Агенты');r('doc','Агенты и правила','Загрузите AGENTS.md, агентов и команды',()=>openAgents());
  r('server','Серверы MCP','Добавить, изменить, подключить',()=>O.openMcp());r('plug','Плагины','npm-пакеты и локальные файлы',()=>O.openPlugins());
  r('code','Файл конфигурации','Редактировать opencode.json напрямую',()=>openConfig());
  g('Приложение');r('down','Обновления','Приложение и ядро OpenCode (1.x)',()=>openUpdates());r('shield','Разрешения','Файлы, уведомления, фон, установка',()=>openPerms());
  r('bat','Совместимость и логи','Безопасный режим, перезапуск сервера',()=>openCompat());r('info','О приложении','',()=>openAbout());
  r('globe','OpenCode CLI-агент (Warp)','docs.warp.dev/agents/cli-agents/opencode',()=>O.openUrl('https://docs.warp.dev/agents/cli-agents/opencode/'));
  r('tg','Сообщество','t.me/OpenCodeMob',()=>O.openUrl('https://t.me/OpenCodeMob'))};

// ---- agents / rules upload ----
function openAgents(){const list=h('div');
  const up=(t,sbt,kind,dir)=>O.listRow('up',t,sbt,null,()=>OC.pickFile(kind,dir||''));
  const s=sub('Агенты и правила',h('div',null,
    up('Глобальные правила (AGENTS.md)','Выберите файл — действует для всех проектов','rules'),
    O.listRow('edit','Написать глобальные правила','Редактировать AGENTS.md здесь',null,()=>editFile(CFG+'/AGENTS.md','Глобальный AGENTS.md')),
    up('Правила проекта (AGENTS.md)','Сохраняются в текущую папку','project',S.dir),
    up('Файл агента (.md)','Добавляется в список ваших агентов','agent'),up('Файл команды (.md)','Добавляет /команду','command'),list));
  const draw=()=>{list.textContent='';[['agents','Агенты'],['commands','Команды']].forEach(([d,t])=>{const r=O.native.ls(CFG+'/'+d);if(r.items&&r.items.length){list.append(h('div',{class:'grp'},t));
    r.items.filter(x=>!x.dir).forEach(x=>list.append(O.listRow('doc',x.name,'',h('button',{class:'ibtn s',onclick:async e=>{e.stopPropagation();if(await O.confirm('Удалить '+x.name+'?','','Удалить',true)){O.native.fs('delete',CFG+'/'+d+'/'+x.name);draw();O.loadMeta()}}},O.icon('trash')),()=>editFile(CFG+'/'+d+'/'+x.name,x.name))))}})};
  draw();O.on('picked',()=>{if(s.root.isConnected)draw()})}
function editFile(path,title){const r=O.native.readText(path);const ta=h('textarea',{class:'mono',rows:18});ta.value=r.ok?r.text:'';
  const s=O.sheet(title,h('div',null,ta,h('button',{class:'btn pri wide',style:{marginTop:'8px'},onclick:()=>{const w=O.native.fs('mkdir',O.dirname(path));const x=O.native.writeText(path,ta.value);if(x.ok){O.toast('Сохранено',1200);s.close();O.loadMeta()}else O.toast(x.err||'Не удалось')}},'Сохранить')),{full:true})}

// ---- MCP ----
O.openMcp=async()=>{const body=h('div');const s=sub('Серверы MCP',body,{actions:h('button',{class:'ibtn',onclick:()=>edit(null)},O.icon('plus'))});
  const draw=async()=>{body.textContent='';const c=cfg.read();if(!c.obj){body.append(h('div',{class:'errbox'},'Ошибки в opencode.json: '+c.err));return}
    let live={};try{live=await api('GET','/mcp')}catch{}const m=c.obj.mcp||{};const ks=Object.keys(m);
    if(!ks.length)body.append(h('div',{class:'mut',style:{padding:'12px'}},'Серверов MCP пока нет. Нажмите + чтобы добавить.'));
    ks.forEach(k=>{const e=m[k],l=live[k],stt=l?l.status:(e.enabled===false?'disabled':'unknown');
      body.append(O.listRow('server',k,(e.type==='remote'?e.url:(e.command||[]).join(' '))+'  ('+stt+')',h('span',{class:'dot '+(stt==='connected'?'ok':stt==='failed'?'err':stt==='disabled'?'':'warn')}),
        ()=>O.actions(k,[{label:'Изменить',icon:'edit',fn:()=>edit(k)},
          {label:e.enabled===false?'Включить':'Отключить',icon:'play',fn:()=>{const cc=cfg.read();cc.obj.mcp[k].enabled=e.enabled===false;cfg.write(cc.obj);api('POST','/mcp/'+encodeURIComponent(k)+(e.enabled===false?'/connect':'/disconnect'),{}).catch(()=>{});draw()}},
          {label:'Удалить',icon:'trash',danger:true,fn:()=>{const cc=cfg.read();delete cc.obj.mcp[k];cfg.write(cc.obj);api('POST','/mcp/'+encodeURIComponent(k)+'/disconnect',{}).catch(()=>{});draw()}}])))});
    body.append(restartBar())};
  const edit=name=>{const c=cfg.read();if(!c.obj)return O.toast('Сначала исправьте opencode.json');const e=(name&&c.obj.mcp&&c.obj.mcp[name])||{type:'local',enabled:true};
    const nm=h('input',{placeholder:'имя, напр. context7'});nm.value=name||'';nm.disabled=!!name;
    let type=e.type||'local';const cmd=h('input',{class:'mono',placeholder:'npx -y @upstash/context7-mcp'});cmd.value=(e.command||[]).join(' ');
    const env=h('textarea',{class:'mono',rows:3,placeholder:'КЛЮЧ=значение (по одному на строку)'});env.value=Object.entries(e.environment||{}).map(([k,v])=>k+'='+v).join('\n');
    const url=h('input',{class:'mono',placeholder:'https://mcp.example.com/mcp'});url.value=e.url||'';
    const hd=h('textarea',{class:'mono',rows:3,placeholder:'Заголовок: значение (по одному на строку)'});hd.value=Object.entries(e.headers||{}).map(([k,v])=>k+': '+v).join('\n');
    const lo=h('div',null,h('div',{class:'field'},h('label',null,'Команда'),cmd),h('div',{class:'field'},h('label',null,'Переменные окружения'),env));
    const re=h('div',null,h('div',{class:'field'},h('label',null,'URL'),url),h('div',{class:'field'},h('label',null,'Заголовки'),hd));
    const seg=h('div',{class:'seg'},[['local','Локальный'],['remote','Удалённый']].map(([t,l])=>h('button',{class:t===type?'on':'',onclick:ev=>{type=t;seg.querySelectorAll('button').forEach(b=>b.classList.toggle('on',b===ev.currentTarget));show()}},l)));
    const show=()=>{lo.classList.toggle('hide',type!=='local');re.classList.toggle('hide',type!=='remote')};show();
    const sh=O.sheet(name?'Изменение '+name:'Добавить сервер MCP',h('div',null,h('div',{class:'field'},h('label',null,'Имя'),nm),seg,lo,re,
      h('button',{class:'btn pri wide',style:{marginTop:'10px'},onclick:async()=>{const n=nm.value.trim();if(!n)return O.toast('Введите имя');
        const o={type,enabled:e.enabled!==false};
        if(type==='local'){o.command=O.splitArgs(cmd.value);if(!o.command.length)return O.toast('Введите команду');const ev={};env.value.split('\n').forEach(l=>{const i=l.indexOf('=');if(i>0)ev[l.slice(0,i).trim()]=l.slice(i+1).trim()});if(Object.keys(ev).length)o.environment=ev}
        else{if(!url.value.trim())return O.toast('Введите URL');o.url=url.value.trim();const hv={};hd.value.split('\n').forEach(l=>{const i=l.indexOf(':');if(i>0)hv[l.slice(0,i).trim()]=l.slice(i+1).trim()});if(Object.keys(hv).length)o.headers=hv}
        const cc=cfg.read();cc.obj.mcp=cc.obj.mcp||{};cc.obj.mcp[n]=o;const w=cfg.write(cc.obj);if(!w.ok)return O.toast(w.err||'Не удаётся записать конфиг');
        api('POST','/mcp',{name:n,config:o}).catch(()=>{});sh.close();draw()}},'Сохранить')),{full:true})};
  draw()};

// ---- plugins ----
O.openPlugins=()=>{const body=h('div');const s=sub('Плагины',body);
  const draw=()=>{body.textContent='';const c=cfg.read();if(!c.obj){body.append(h('div',{class:'errbox'},'Ошибки в opencode.json: '+c.err));return}
    const pl=c.obj.plugin||[];
    const inp=h('input',{class:'mono',placeholder:'npm-пакет, напр. opencode-gemini-auth',autocapitalize:'off',autocorrect:'off'});
    body.append(h('div',{class:'grp'},'Установленные (npm)'));
    if(!pl.length)body.append(h('div',{class:'mut',style:{padding:'8px'}},'Нет'));
    pl.forEach((p,i)=>body.append(O.listRow('plug',Array.isArray(p)?p[0]:p,'',h('button',{class:'ibtn s',onclick:e=>{e.stopPropagation();const cc=cfg.read();cc.obj.plugin.splice(i,1);cfg.write(cc.obj);draw()}},O.icon('trash')))));
    body.append(h('div',{style:{display:'flex',gap:'6px',marginTop:'8px'}},inp,h('button',{class:'btn pri',onclick:()=>{const v=inp.value.trim();if(!v)return;const cc=cfg.read();cc.obj.plugin=(cc.obj.plugin||[]).concat([v]);cfg.write(cc.obj);draw()}},'Добавить')));
    body.append(h('div',{class:'grp'},'Локальные файлы'));const r=O.native.ls(CFG+'/plugins');
    (r.items||[]).filter(x=>!x.dir).forEach(x=>body.append(O.listRow('code',x.name,'',h('button',{class:'ibtn s',onclick:e=>{e.stopPropagation();O.native.fs('delete',CFG+'/plugins/'+x.name);draw()}},O.icon('trash')))));
    body.append(h('button',{class:'btn wide',style:{marginTop:'8px'},onclick:()=>OC.pickFile('plugin','')},O.icon('up'),'Загрузить файл плагина (.js / .ts)'),
      h('div',{class:'note',style:{marginTop:'10px'}},'npm-плагины установятся автоматически при следующем запуске сервера.'),restartBar())};
  draw();O.on('picked',()=>{if(s.root.isConnected)draw()})};

// ---- raw config ----
function openConfig(){const c=cfg.read();const ta=h('textarea',{class:'mono',rows:20,spellcheck:'false'});ta.value=c.raw||'{\n}\n';
  sub('opencode.json',h('div',null,c.err?h('div',{class:'errbox'},c.err):null,ta,h('button',{class:'btn pri wide',style:{marginTop:'8px'},onclick:()=>{try{O.parseJsonc(ta.value||'{}')}catch(e){return O.toast('Неверный JSON: '+e.message,4000)}
    const w=cfg.write(ta.value);w.ok?O.toast('Сохранено',1200):O.toast(w.err||'Не удалось')}},'Сохранить'),restartBar()))}

// ---- updates ----
let updUI=null;
function openUpdates(){const st=O.native.state();const bar=h('i');const info=h('div',{class:'mut s',style:{margin:'8px 0'}},'');
  const app=h('div'),core=h('div');
  const row=(t,sb,btn)=>h('div',{class:'li'},O.icon('down'),h('div',{class:'t'},h('b',null,t),h('span',null,sb)),btn||null);
  const draw=u=>{app.textContent='';core.textContent='';
    app.append(row('Приложение OpenCode '+st.version,u&&u.app?'Новая версия '+u.app.name:'Актуальная версия',u&&u.app?h('button',{class:'btn pri sm',onclick:()=>OC.applyAppUpdate()},'Установить'):null));
    core.append(row('Ядро OpenCode '+(st.core||''),u&&u.core?'Новый релиз '+u.core:'ветка 1.x',u&&u.core?h('button',{class:'btn pri sm',onclick:()=>OC.applyCoreUpdate()},'Обновить'):null))};
  draw(null);
  const s=sub('Обновления',h('div',null,app,core,h('button',{class:'btn wide',onclick:()=>{info.textContent='Проверка...';OC.checkUpdates()}},O.icon('refresh'),'Проверить обновления'),info,h('div',{class:'bar',style:{marginTop:'8px'}},bar),
    h('div',{class:'note',style:{marginTop:'12px'}},'Обновления ядра идут только по ветке 1.x и применяются без переустановки приложения.')),{onClose:()=>{updUI=null}});
  updUI={draw,bar,info,s}}
O.on('update',d=>{if(!updUI)return;
  if(d.error){updUI.info.textContent=d.error;updUI.bar.style.width='0'}
  else if(d.pct!=null){updUI.bar.style.width=d.pct+'%';updUI.info.textContent=(d.what==='core'?'Загрузка ядра ':'Загрузка приложения ')+d.pct+'%'}
  else if(d.coreDone){updUI.bar.style.width='0';updUI.info.textContent='Ядро обновлено до '+d.coreDone+'. Перезапуск сервера...'}
  else{updUI.draw(d);updUI.info.textContent=(d.app||d.core)?'Доступны обновления':'Всё актуально'}});

// ---- permissions ----
const PERMS=[['notifications','bell','Уведомления','Звуки и оповещения о завершении задач'],['files','folder','Доступ ко всем файлам','Работа с /storage/emulated/0 и Download'],['battery','bat','Работа в фоне','Игнорирование оптимизации батареи, чтобы сервер не отключался'],['install','down','Установка обновлений','Разрешить OTA-обновлениям устанавливать новый APK']];
let permUI=null;
O.permRows=()=>{const p=O.native.state().perms||{};return PERMS.map(([k,i,t,d])=>h('div',{class:'li'},O.icon(i),h('div',{class:'t'},h('b',null,t),h('span',null,d)),p[k]?h('span',{class:'ok s'},'Дано'):h('button',{class:'btn sm',onclick:()=>OC.grant(k)},'Разрешить')))};
function openPerms(){const box=h('div',null,O.permRows());const s=sub('Разрешения',box,{onClose:()=>{permUI=null}});permUI=()=>{box.textContent='';box.append(O.permRows())}}
O.on('perms',()=>{if(permUI)permUI()});

// ---- compatibility / about ----
function openCompat(){const fl=O.native.state().flags||{};
  sub('Совместимость и логи',h('div',null,O.toggleRow('shield','Безопасный режим (без seccomp)','Медленнее, но помогает, если сервер не запускается на некоторых телефонах',fl.noseccomp,v=>OC.setFlag('noseccomp',v)),
    h('button',{class:'btn wide',style:{marginTop:'10px'},onclick:()=>{OC.restartServer();O.toast('Перезапуск сервера...')}},O.icon('refresh'),'Перезапустить сервер'),
    h('button',{class:'btn wide',style:{marginTop:'8px'},onclick:()=>{const t=OC.readLog();sub('Лог сервера',h('pre',{class:'term-pre',style:{maxHeight:'none'}},t||'(пусто)'))}},O.icon('terminal'),'Смотреть лог сервера')))}
function openAbout(){const st=O.native.state();
  sub('О приложении',h('div',null,h('div',{class:'center',style:{minHeight:0,padding:'16px 0'}},O.logo(40),h('b',{style:{fontSize:'20px'}},'OpenCode'),h('div',{class:'mut'},'Версия '+st.version),h('div',{class:'mut s'},'Ядро '+(st.core||'неизвестно')+' (1.x)')),
    h('div',{class:'note'},'OpenCode Mobile упаковывает CLI OpenCode 1.x (лицензия MIT) в Android-приложение. Оно создано не командой OpenCode и никак с ней не связано.'),
    h('div',{class:'note',style:{marginTop:'10px'}},'OpenCode как CLI-агент есть и у Warp — документация: docs.warp.dev/agents/cli-agents/opencode.'),
    h('button',{class:'btn wide',style:{marginTop:'12px'},onclick:()=>O.openUrl('https://docs.warp.dev/agents/cli-agents/opencode/')},O.icon('globe'),'OpenCode CLI-агент (Warp)'),
    h('button',{class:'btn wide',style:{marginTop:'8px'},onclick:()=>O.openUrl('https://t.me/OpenCodeMob')},O.icon('tg'),'t.me/OpenCodeMob')))}
O.on('signedout',()=>location.reload());

// ---- аккаунт opencode: вход через Google/GitHub (device flow) ----
O.consoleOrgs=async()=>{try{const r=await api('GET','/experimental/console/orgs',null,{timeout:10000});return r.orgs||[]}catch{return null}};
O.openAccount=()=>{
  const body=h('div');const s=sub('Аккаунт opencode',body,{full:true,onClose:()=>{try{OC.authCancel()}catch{}}});
  let busy=false;
  const drawIdle=async()=>{body.textContent='';
    const orgs=await O.consoleOrgs();
    // remember the state: hints in chat and «Подключить провайдера» больше не предлагают войти, если уже вошли
    const em=orgs&&orgs.length?[...new Set(orgs.map(o=>o.accountEmail))][0]:null;
    S.account={email:em||null,checked:true};
    if(orgs===null){
      body.append(h('div',{class:'errbox'},'Не удалось связаться с сервером opencode. Убедитесь, что он запущен, и попробуйте ещё раз.'),
        h('button',{class:'btn wide',style:{marginTop:'10px'},onclick:()=>drawIdle()},O.icon('refresh'),'Повторить'));
      return}
    const emails=[...new Set(orgs.map(o=>o.accountEmail))];
    if(!emails.length){
      body.append(h('div',{class:'card',style:{display:'flex',alignItems:'center',gap:'10px'}},O.icon('user'),h('div',{class:'grow'},h('b',null,'Вход не выполнен'),h('div',{class:'mut s'},'Сейчас квота OpenCode Zen анонимная и быстро исчерпывается'))));
      body.append(h('div',{class:'note'},'Войдите через Google или GitHub — как в opencode на компьютере. Откроется страница opencode.ai: выберите Google или GitHub и подтвердите вход. После этого квота Zen привяжется к вашему аккаунту.'));
      body.append(h('button',{class:'btn pri wide',style:{marginTop:'8px'},onclick:startLogin},O.icon('user'),'Войти через Google / GitHub'));
      body.append(h('div',{class:'mut s',style:{marginTop:'10px'}},'Альтернатива — свой ключ провайдера: Настройки → Модели → Подключить провайдера.'));
      return}
    emails.forEach(e=>body.append(O.listRow('user',e,'Аккаунт opencode',O.icon('check','ok'),null)));
    const act=orgs.find(o=>o.active);
    if(act)body.append(O.listRow('key',act.orgName,'Активная организация',null,null));
    body.append(h('div',{class:'note'},'Вход выполнен: квота OpenCode Zen привязана к вашему аккаунту. Если ошибка квоты ещё появляется — перезапустите сервер и подождите минуту.'));
    emails.forEach(e=>body.append(h('button',{class:'btn wide',style:{marginTop:'10px'},onclick:async()=>{
      if(!await O.confirm('Выйти из аккаунта opencode?','Квота Zen снова станет анонимной. Локальные чаты не удалятся.','Выйти',true))return;
      busy=true;O.toast('Выходим из аккаунта...');OC.authLogout(e)}},O.icon('out'),'Выйти из '+e)));
  };
  const startLogin=()=>{if(busy)return;busy=true;body.textContent='';
    const box=h('div',null,h('div',{style:{display:'flex',gap:'8px',alignItems:'center',padding:'6px 0'}},h('span',{class:'spin'}),h('span',{class:'mut'},'Готовим код входа... Это займёт несколько секунд')));
    body.append(box);
    let url=null,code=null,fin=false;
    const cancel=()=>{if(!fin){fin=true;busy=false;try{OC.authCancel()}catch{};drawIdle()}};
    O.on('authlogin',d=>{if(!box.isConnected)return;
      if(d.stage==='url'){url=d.url;code=d.code;
        box.textContent='';
        box.append(h('div',{class:'note'},'Открываем страницу opencode.ai. На ней нажмите «Continue with Google» или «Continue with GitHub» и подтвердите разрешение — код уже вписан автоматически.'),
          h('div',{class:'card',style:{textAlign:'center',padding:'14px',marginTop:'10px'}},h('div',{class:'mut s'},'Код входа (если понадобится вручную)'),h('b',{class:'mono',style:{fontSize:'22px',letterSpacing:'2px'}},code),h('button',{class:'btn sm',style:{marginTop:'8px'},onclick:()=>O.native.copy(code)},O.icon('copy'),'Скопировать код')),
          h('button',{class:'btn pri wide',style:{marginTop:'10px'},onclick:()=>O.openUrl(url)},O.icon('ext'),'Открыть страницу входа ещё раз'),
          h('div',{style:{display:'flex',gap:'8px',alignItems:'center',margin:'14px 0'}},h('span',{class:'spin'}),h('span',{class:'mut'},'Ожидаем подтверждение в браузере...')),
          h('button',{class:'btn wide',onclick:cancel},'Отменить вход'));
        O.openUrl(url);
      }else if(d.stage==='done'){fin=true;busy=false;
        box.textContent='';
        box.append(h('div',{class:'card',style:{display:'flex',alignItems:'center',gap:'10px'}},O.icon('check'),h('div',{class:'grow'},h('b',null,'Вошли как '+d.email),h('div',{class:'mut s'},'Перезапускаем сервер, чтобы применить аккаунт...'))));
        if(d.synced===false)box.append(h('div',{class:'errbox',style:{marginTop:'10px'}},'Аккаунт сохранён, но автоматически привязать его к моделям не удалось. После перезапуска откройте Настройки → Аккаунт opencode и проверьте статус входа.'));
        S.account={email:d.email,checked:true};bus.emit('meta');
        O.toast('Вошли как '+d.email,4000);
        setTimeout(()=>{s.close();OC.restartServer();O.toast('Перезапуск сервера...')},1500);
      }else if(d.stage==='error'){fin=true;busy=false;
        box.textContent='';
        box.append(h('div',{class:'errbox'},d.error||'Не удалось войти'),
          h('button',{class:'btn wide',style:{marginTop:'10px'},onclick:startLogin},O.icon('refresh'),'Повторить вход'),
          h('button',{class:'btn wide',style:{marginTop:'8px'},onclick:drawIdle},'Назад'))}});
    try{OC.authLogin()}catch(e){fin=true;busy=false;box.textContent='';box.append(h('div',{class:'errbox'},e.message||'Не удалось запустить вход'))}
  };
  drawIdle()};
O.on('authlogout',d=>{
  if(d.ok){S.account={email:null,checked:true};bus.emit('meta');O.toast('Вы вышли из аккаунта opencode. Перезапускаем сервер...',3500);try{OC.restartServer()}catch{}}
  else O.toast(d.error||'Не удалось выйти',4000)});
})();
