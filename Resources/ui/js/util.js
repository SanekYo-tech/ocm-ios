(function(){
const O=window.OCM=window.OCM||{};
O.$=(s,r)=>(r||document).querySelector(s);
O.$$=(s,r)=>[...(r||document).querySelectorAll(s)];
const h=O.h=function(tag,props,...kids){
  const e=document.createElement(tag);
  if(props)for(const k in props){const v=props[k];if(v==null||v===false)continue;
    if(k==='class')e.className=v;else if(k==='html')e.innerHTML=v;
    else if(k.slice(0,2)==='on')e.addEventListener(k.slice(2),v);
    else if(k==='style'&&typeof v==='object')Object.assign(e.style,v);
    else e.setAttribute(k,v===true?'':v)}
  for(const c of kids.flat(Infinity)){if(c==null||c===false)continue;e.append(c.nodeType?c:document.createTextNode(String(c)))}
  return e};
O.esc=s=>String(s==null?'':s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
O.basename=p=>String(p||'').replace(/\/+$/,'').split('/').pop();
O.dirname=p=>{p=String(p||'').replace(/\/+$/,'');const i=p.lastIndexOf('/');return i<0?'.':i===0?'/':p.slice(0,i)};
O.ext=p=>{const b=O.basename(p).toLowerCase();const i=b.lastIndexOf('.');return i>0?b.slice(i+1):(i===0?b.slice(1):'')};
O.ago=ts=>{if(!ts)return'';const s=Math.max(0,(Date.now()-ts)/1000);if(s<60)return'сейчас';if(s<3600)return Math.floor(s/60)+' мин';if(s<86400)return Math.floor(s/3600)+' ч';if(s<604800)return Math.floor(s/86400)+' д';return new Date(ts).toLocaleDateString()};
O.fmtK=n=>n>=1e6?(n/1e6).toFixed(1)+'M':n>=1e3?(n/1e3).toFixed(n>=1e4?0:1)+'k':String(n||0);
O.stripAnsi=s=>String(s||'')
  .replace(/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?/g,'')
  .replace(/\x1b[P^_][^\x1b]*(?:\x1b\\)?/g,'')
  .replace(/\x1b\[[0-9;?<=>!"' ]*[ -\/]*[@-~]/g,'')
  .replace(/\x1b[@-Z\\-_]/g,'')
  .replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g,'');
O.debounce=(f,ms)=>{let t;return(...a)=>{clearTimeout(t);t=setTimeout(()=>f(...a),ms)}};
O.store={get(k,d){try{const v=localStorage.getItem('ocm.'+k);return v==null?d:JSON.parse(v)}catch{return d}},set(k,v){try{localStorage.setItem('ocm.'+k,JSON.stringify(v))}catch{}}};
let last=0,ctr=0;
O.mid=()=>{const n=Date.now();if(n!==last){last=n;ctr=0}ctr++;
  const hex=(BigInt(n)*0x1000n+BigInt(ctr)).toString(16).padStart(12,'0').slice(-12);
  const a='0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
  let r='';for(const x of crypto.getRandomValues(new Uint8Array(14)))r+=a[x%62];return'msg_'+hex+r};
O.splitArgs=s=>{const out=[];const re=/"([^"]*)"|'([^']*)'|(\S+)/g;let m;while((m=re.exec(s)))out.push(m[1]??m[2]??m[3]);return out};
O.stripJsonc=t=>{let o='',i=0,s=false;while(i<t.length){const c=t[i],n=t[i+1];
  if(s){o+=c;if(c==='\\'){o+=n||'';i+=2;continue}if(c==='"')s=false;i++;continue}
  if(c==='"'){s=true;o+=c;i++;continue}
  if(c==='/'&&n==='/'){while(i<t.length&&t[i]!=='\n')i++;continue}
  if(c==='/'&&n==='*'){i+=2;while(i<t.length&&!(t[i]==='*'&&t[i+1]==='/'))i++;i+=2;continue}
  o+=c;i++}
  return o.replace(/,(\s*[}\]])/g,'$1')};
O.parseJsonc=t=>JSON.parse(O.stripJsonc(t));

// toast
let tt;O.toast=(m,ms)=>{let e=O.$('#toast');if(!e){e=h('div',{id:'toast'});document.body.append(e)}e.textContent=m;e.style.display='block';clearTimeout(tt);tt=setTimeout(()=>e.style.display='none',ms||2600)};

// sheets
const stack=[];O.sheets=stack;
O.sheet=(title,body,opts)=>{opts=opts||{};
  const api={};
  api.close=()=>{if(!api.root.isConnected)return;api.root.remove();const i=stack.indexOf(api);if(i>=0)stack.splice(i,1);opts.onClose&&opts.onClose()};
  const box=h('div',{class:'sheet'+(opts.full?' full':'')+(opts.drawer?' drawer':'')},
    h('div',{class:'sh-h'},h('button',{class:'ibtn',onclick:api.close},O.icon(opts.drawer?'x':'chevL')),h('b',{class:'grow'},title),opts.actions||null),
    h('div',{class:'sh-b'},body));
  api.root=h('div',{class:'sh-root'},h('div',{class:'sh-back',onclick:api.close}),box);
  api.box=box;api.body=box.querySelector('.sh-b');
  document.body.append(api.root);stack.push(api);requestAnimationFrame(()=>api.root.classList.add('on'));return api};
O.confirm=(title,msg,ok,danger)=>new Promise(res=>{let done=false;
  const fin=v=>{if(done)return;done=true;s.close();res(v)};
  const s=O.sheet(title,h('div',null,h('p',{class:'mut'},msg||''),h('div',{style:{display:'flex',gap:'8px',marginTop:'12px'}},
    h('button',{class:'btn grow',onclick:()=>fin(false)},'Отмена'),h('button',{class:'btn grow '+(danger?'dng':'pri'),onclick:()=>fin(true)},ok||'ОК'))),{onClose:()=>{if(!done){done=true;res(false)}}})});
O.ask=(title,label,val,multiline)=>new Promise(res=>{let done=false;
  const inp=multiline?h('textarea',{rows:6,class:'mono'}):h('input',{type:'text'});inp.value=val||'';
  const fin=v=>{if(done)return;done=true;s.close();res(v)};
  const s=O.sheet(title,h('div',null,h('div',{class:'field'},label?h('label',null,label):null,inp),h('div',{style:{display:'flex',gap:'8px'}},
    h('button',{class:'btn grow',onclick:()=>fin(null)},'Отмена'),h('button',{class:'btn pri grow',onclick:()=>fin(inp.value)},'ОК'))),{onClose:()=>{if(!done){done=true;res(null)}}});
  setTimeout(()=>inp.focus(),200)});
O.actions=(title,items)=>{const s=O.sheet(title,h('div',null,items.filter(Boolean).map(it=>h('button',{class:'li',onclick:()=>{s.close();it.fn()}},
  O.icon(it.icon||'dots'),h('div',{class:'t'},h('b',{class:it.danger?'err':''},it.label),it.sub?h('span',null,it.sub):null)))));return s};
O.back=()=>{const s=stack[stack.length-1];if(s){s.close();return true}return false};
O.toggleRow=(icon,title,sub,checked,onchange)=>{const i=h('input',{type:'checkbox',onchange:()=>onchange(i.checked)});i.checked=!!checked;
  return h('label',{class:'li'},O.icon(icon),h('div',{class:'t'},h('b',null,title),sub?h('span',null,sub):null),h('span',{class:'sw'},i,h('s')))};
O.listRow=(icon,title,sub,right,fn)=>h('button',{class:'li',onclick:fn},typeof icon==='string'?O.icon(icon):icon,h('div',{class:'t'},h('b',null,title),sub?h('span',null,sub):null),right||null);
})();
