(function(){
const O=window.OCM,h=O.h;let el=null,entered=false;
function screen(...k){if(!el){el=h('div',{id:'boot'});document.body.append(el)}el.textContent='';el.append(h('div',{class:'center'},...k.flat()));return el}
O.bootHide=()=>{if(el){el.remove();el=null}};
const logo=()=>[O.logo(46),h('b',{style:{fontSize:'22px'}},'OpenCode')];

function start(){
  O.store.set('iosStarted',true);
  O.bootHide();
  if(!entered){entered=true;try{O.enter()}catch(e){console.error(e);O.toast(e.message||'Не удалось открыть интерфейс',5000)}}
}
function enterThen(fn){
  start();
  setTimeout(()=>{try{fn()}catch(e){console.error(e)}},700);
}
function welcome(msg){
  const st=O.native.state()||{};
  const signed=st.user&&st.user!==''&&st.name==='OpenCode iPhone'?st.user:'';
  screen(logo(),
    h('b',{style:{fontSize:'20px'}},'OpenCode на iPhone'),
    h('p',{class:'mut'},'Полностью на устройстве: файлы, терминал и AI-агент. Компьютер не нужен.'),
    h('div',{class:'note'},'Рабочая папка — OpenCode. Она видна в приложении «Файлы» → «На iPhone» → «OpenCode». Агент читает и меняет эти файлы, а встроенный терминал выполняет настоящие Unix-команды.'),
    signed?h('div',{class:'card',style:{display:'flex',alignItems:'center',gap:'10px',width:'100%'}},O.icon('user'),h('div',{class:'grow'},h('b',null,'Аккаунт OpenCode'),h('div',{class:'mut s'},signed))):null,
    msg?h('p',{class:'err'},msg):null,
    h('button',{class:'btn pri wide',onclick:start},O.icon('chat'),'Начать'),
    h('button',{class:'btn wide',style:{marginTop:'8px'},onclick:()=>enterThen(()=>O.openAccount())},O.icon('user'),'Войти в аккаунт OpenCode'),
    h('button',{class:'btn wide',style:{marginTop:'8px'},onclick:()=>enterThen(()=>O.openConnect())},O.icon('key'),'У меня есть API-ключ'),
    h('div',{class:'note',style:{marginTop:'10px'}},'Без входа доступны бесплатные модели OpenCode Zen (если квота не исчерпана). Вход через Google/GitHub открывает личную квоту. Ключ OpenCode Console нужен, если вы хотите платные модели.'),
    h('span',{class:'mut s',style:{marginTop:'8px'}},'v'+st.version+' · iOS'));
}
O.bootRun=()=>{
  const st=O.native.state()||{};
  if(st.ready&&O.store.get('iosStarted')){start();return}
  welcome('');
};
})();