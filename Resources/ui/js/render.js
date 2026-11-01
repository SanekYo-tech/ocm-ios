(function(){
const O=window.OCM,h=O.h;
// ---- markdown ----
O.md=t=>{try{return DOMPurify.sanitize(marked.parse(t||'',{gfm:true}),{USE_PROFILES:{html:true},FORBID_TAGS:['style','form','input','button','textarea','select'],FORBID_ATTR:['style','onerror','onload']})}catch{return'<pre>'+O.esc(t)+'</pre>'}};
O.enhance=el=>{el.querySelectorAll('pre').forEach(pre=>{if(pre.dataset.e||pre.closest('.codeblock'))return;pre.dataset.e='1';
  const code=pre.querySelector('code');const lang=((code&&code.className.match(/language-([\w+#-]+)/))||[])[1]||'';
  if(code&&window.hljs){try{hljs.highlightElement(code)}catch{}}
  const wrap=h('div',{class:'codeblock'},h('div',{class:'code-bar'},h('span',null,lang||'текст'),h('button',{class:'ibtn s','data-copy':'1'},O.icon('copy'))));
  pre.replaceWith(wrap);wrap.append(pre)})};
O.mdInto=(el,t)=>{el.innerHTML=O.md(t);O.enhance(el)};

// ---- diff ----
O.diffOps=(a,b)=>{const A=a.split('\n'),B=b.split('\n');let s=0;while(s<A.length&&s<B.length&&A[s]===B[s])s++;
  let ea=A.length,eb=B.length;while(ea>s&&eb>s&&A[ea-1]===B[eb-1]){ea--;eb--}
  const ops=[];for(let i=0;i<s;i++)ops.push([' ',A[i]]);
  const n=ea-s,m=eb-s;
  if(n*m>4e6){for(let i=s;i<ea;i++)ops.push(['-',A[i]]);for(let j=s;j<eb;j++)ops.push(['+',B[j]])}
  else{const W=m+1,L=new Uint32Array((n+1)*W);
    for(let i=n-1;i>=0;i--)for(let j=m-1;j>=0;j--)L[i*W+j]=A[s+i]===B[s+j]?L[(i+1)*W+j+1]+1:Math.max(L[(i+1)*W+j],L[i*W+j+1]);
    let i=0,j=0;while(i<n&&j<m){if(A[s+i]===B[s+j]){ops.push([' ',A[s+i]]);i++;j++}else if(L[(i+1)*W+j]>=L[i*W+j+1]){ops.push(['-',A[s+i]]);i++}else{ops.push(['+',B[s+j]]);j++}}
    while(i<n){ops.push(['-',A[s+i]]);i++}while(j<m){ops.push(['+',B[s+j]]);j++}}
  for(let i=ea;i<A.length;i++)ops.push([' ',A[i]]);return ops};
O.diffEl=(ops,ctx)=>{ctx=ctx==null?3:ctx;const box=h('div',{class:'diff'});const keep=new Array(ops.length).fill(false);
  ops.forEach((o,i)=>{if(o[0]!==' ')for(let k=Math.max(0,i-ctx);k<=Math.min(ops.length-1,i+ctx);k++)keep[k]=true});
  let skipped=0;const flush=()=>{if(skipped){box.append(h('div',{class:'c'},'  … без изменений: '+skipped+' строк'));skipped=0}};
  ops.forEach((o,i)=>{if(!keep[i]){skipped++;return}flush();box.append(h('div',{class:o[0]==='+'?'a':o[0]==='-'?'d':''},o[0]+' '+o[1]))});flush();
  if(!box.childNodes.length)box.append(h('div',{class:'c'},'Нет изменений'));return box};
O.unifiedEl=txt=>{const box=h('div',{class:'diff'});String(txt||'').split('\n').slice(0,2500).forEach(l=>{
  const c=l.startsWith('+')&&!l.startsWith('+++')?'a':l.startsWith('-')&&!l.startsWith('---')?'d':l.startsWith('@@')?'h':(l.startsWith('---')||l.startsWith('+++')||l.startsWith('Index')||l.startsWith('==='))?'c':'';
  box.append(h('div',{class:c},l))});return box};

// ---- file icons (SVGs come from the upstream opencode repo, copied at build time) ----
let idx=new Set();
O.iconsReady=fetch('icons/files/index.json').then(r=>r.json()).then(a=>{idx=new Set(a)}).catch(()=>{});
const EXT={py:'python',pyw:'python',js:'javascript',mjs:'javascript',cjs:'javascript',ts:'typescript',mts:'typescript',tsx:'react_ts',jsx:'react',json:'json',jsonc:'json',md:'markdown',mdx:'markdown',html:'html',htm:'html',css:'css',scss:'sass',sass:'sass',less:'less',go:'go',rs:'rust',java:'java',kt:'kotlin',kts:'kotlin',swift:'swift',c:'c',h:'h',cpp:'cpp',cc:'cpp',cxx:'cpp',hpp:'hpp',cs:'csharp',php:'php',rb:'ruby',lua:'lua',sh:'console',bash:'console',zsh:'console',fish:'console',ps1:'powershell',yml:'yaml',yaml:'yaml',toml:'toml',xml:'xml',svg:'svg',png:'image',jpg:'image',jpeg:'image',gif:'image',webp:'image',ico:'image',bmp:'image',pdf:'pdf',zip:'zip',gz:'zip',tar:'zip',tgz:'zip',rar:'zip','7z':'zip',sql:'database',db:'database',sqlite:'database',lock:'lock',txt:'document',log:'log',env:'tune',vue:'vue',svelte:'svelte',dart:'dart',r:'r',scala:'scala',ex:'elixir',exs:'elixir',erl:'erlang',hs:'haskell',zig:'zig',nim:'nim',tf:'terraform',proto:'proto',gradle:'gradle',csv:'table',ini:'settings',conf:'settings',cfg:'settings',gitignore:'git',apk:'android',jar:'java',wasm:'webassembly',astro:'astro',prisma:'prisma',graphql:'graphql',gql:'graphql',mp3:'audio',wav:'audio',mp4:'video',mov:'video'};
const NAME={'package.json':'nodejs','package-lock.json':'nodejs','tsconfig.json':'tsconfig','dockerfile':'docker','docker-compose.yml':'docker','docker-compose.yaml':'docker','readme.md':'readme','license':'certificate','license.md':'certificate','makefile':'makefile','.gitignore':'git','.gitattributes':'git','.env':'tune','bun.lock':'bun','bun.lockb':'bun','yarn.lock':'yarn','pnpm-lock.yaml':'pnpm','vite.config.ts':'vite','vite.config.js':'vite','agents.md':'markdown','opencode.json':'json','build.gradle':'gradle','build.gradle.kts':'gradle','cargo.toml':'rust','go.mod':'go','requirements.txt':'python'};
const FILE_FB='data:image/svg+xml;utf8,'+encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="#9a9595" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M14 3H7a2 2 0 00-2 2v14a2 2 0 002 2h10a2 2 0 002-2V8zM14 3v5h5"/></svg>');
const DIR_FB='data:image/svg+xml;utf8,'+encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="#9a9595" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7a2 2 0 012-2h4l2 2h8a2 2 0 012 2v8a2 2 0 01-2 2H5a2 2 0 01-2-2z"/></svg>');
O.fileIcon=(name,isDir,open)=>{const light=document.documentElement.dataset.theme==='light';
  const pick=(...c)=>{for(const n of c){if(!n)continue;if(light&&idx.has(n+'_light'))return n+'_light';if(idx.has(n))return n}return null};
  const low=String(name).toLowerCase();let n;
  if(isDir){const k=low.replace(/^\./,'');n=pick(open?'folder-'+k+'-open':null,'folder-'+k,open?'folder-open':'folder')}
  else n=pick(NAME[low],EXT[O.ext(name)],O.ext(name),'document');
  const img=h('img',{class:'fi',alt:'',loading:'lazy'});img.src=n?'icons/files/'+n+'.svg':(isDir?DIR_FB:FILE_FB);
  img.onerror=()=>{img.onerror=null;img.src=isDir?DIR_FB:FILE_FB};return img};
// language for highlight.js
const LANG={py:'python',js:'javascript',mjs:'javascript',cjs:'javascript',ts:'typescript',tsx:'typescript',jsx:'javascript',json:'json',jsonc:'json',md:'markdown',html:'xml',htm:'xml',xml:'xml',svg:'xml',css:'css',scss:'scss',less:'less',go:'go',rs:'rust',java:'java',kt:'kotlin',kts:'kotlin',swift:'swift',c:'c',h:'c',cpp:'cpp',cc:'cpp',hpp:'cpp',cs:'csharp',php:'php',rb:'ruby',lua:'lua',sh:'bash',bash:'bash',zsh:'bash',yml:'yaml',yaml:'yaml',toml:'ini',ini:'ini',sql:'sql',dockerfile:'dockerfile',gradle:'groovy',vue:'xml',diff:'diff',patch:'diff'};
O.langOf=p=>LANG[O.ext(p)]||(O.basename(p).toLowerCase()==='dockerfile'?'dockerfile':null);
// highlighted code split into lines (keeps spans balanced across lines)
O.codeLines=(text,lang)=>{let html;try{html=lang&&hljs.getLanguage(lang)?hljs.highlight(text,{language:lang,ignoreIllegals:true}).value:O.esc(text)}catch{html=O.esc(text)}
  const out=[];let open=[];for(const line of html.split('\n')){let s=open.join('')+line;const re=/<span[^>]*>|<\/span>/g;let m;const st=[...open];
    while((m=re.exec(line))){if(m[0]==='</span>')st.pop();else st.push(m[0])}open=st;out.push(s+'</span>'.repeat(st.length))}return out};
O.codeView=(text,path)=>{const lines=text.split('\n');const big=lines.length>4000;const use=big?lines.slice(0,4000).join('\n'):text;
  const hl=O.codeLines(use,big?null:O.langOf(path));const box=h('div',{class:'code-view'});
  const fr=document.createDocumentFragment();hl.forEach((l,i)=>{const row=h('div',{class:'ln'},h('i',null,i+1),h('span',{html:l||' '}));fr.append(row)});box.append(fr);
  if(big)box.append(h('div',{class:'mut s',style:{padding:'8px 12px'}},'Показаны первые 4000 строк'));return box};
})();
