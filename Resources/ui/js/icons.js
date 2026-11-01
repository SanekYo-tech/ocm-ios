(function(){
const O=window.OCM;
const I={
menu:'<path d="M3 6h18M3 12h18M3 18h18"/>',plus:'<path d="M12 5v14M5 12h14"/>',x:'<path d="M18 6L6 18M6 6l12 12"/>',
chat:'<path d="M21 15a2 2 0 01-2 2H7l-4 4V5a2 2 0 012-2h14a2 2 0 012 2z"/>',
folder:'<path d="M3 7a2 2 0 012-2h4l2 2h8a2 2 0 012 2v8a2 2 0 01-2 2H5a2 2 0 01-2-2z"/>',
file:'<path d="M14 3H7a2 2 0 00-2 2v14a2 2 0 002 2h10a2 2 0 002-2V8zM14 3v5h5"/>',
terminal:'<path d="M4 17l6-6-6-6M12 19h8"/>',
branch:'<circle cx="6" cy="18" r="3"/><circle cx="18" cy="6" r="3"/><path d="M6 3v12M18 9a9 9 0 01-9 9"/>',
sliders:'<path d="M4 7h9M17 7h3M4 12h3M11 12h9M4 17h11M19 17h1"/><circle cx="15" cy="7" r="2"/><circle cx="9" cy="12" r="2"/><circle cx="17" cy="17" r="2"/>',
send:'<path d="M12 19V5M5 12l7-7 7 7"/>',stop:'<rect x="6" y="6" width="12" height="12" rx="2" fill="currentColor"/>',
chevD:'<path d="M6 9l6 6 6-6"/>',chevR:'<path d="M9 18l6-6-6-6"/>',chevL:'<path d="M15 18l-6-6 6-6"/>',
check:'<path d="M20 6L9 17l-5-5"/>',copy:'<rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 01-2-2V4a2 2 0 012-2h9a2 2 0 012 2v1"/>',
trash:'<path d="M3 6h18M8 6V4a2 2 0 012-2h4a2 2 0 012 2v2M19 6l-1 14a2 2 0 01-2 2H8a2 2 0 01-2-2L5 6"/>',
edit:'<path d="M12 20h9M16.5 3.5a2.1 2.1 0 013 3L7 19l-4 1 1-4z"/>',
search:'<circle cx="11" cy="11" r="7"/><path d="M21 21l-4.3-4.3"/>',refresh:'<path d="M21 12a9 9 0 11-3-6.7M21 4v5h-5"/>',
bell:'<path d="M18 8a6 6 0 10-12 0c0 7-3 9-3 9h18s-3-2-3-9M13.7 21a2 2 0 01-3.4 0"/>',
down:'<path d="M12 3v12M7 10l5 5 5-5M5 21h14"/>',up:'<path d="M12 15V3M7 8l5-5 5 5M5 21h14"/>',
bat:'<rect x="2" y="7" width="17" height="10" rx="2"/><path d="M22 11v2M6 11v2"/>',
user:'<path d="M20 21v-2a4 4 0 00-4-4H8a4 4 0 00-4 4v2M12 11a4 4 0 100-8 4 4 0 000 8z"/>',
doc:'<path d="M14 3H7a2 2 0 00-2 2v14a2 2 0 002 2h10a2 2 0 002-2V8zM14 3v5h5M9 13h6M9 17h6"/>',
tg:'<path d="M22 2L11 13M22 2l-7 20-4-9-9-4z"/>',out:'<path d="M9 21H5a2 2 0 01-2-2V5a2 2 0 012-2h4M16 17l5-5-5-5M21 12H9"/>',
cpu:'<rect x="6" y="6" width="12" height="12" rx="2"/><path d="M9 2v4M15 2v4M9 18v4M15 18v4M2 9h4M2 15h4M18 9h4M18 15h4"/>',
bot:'<rect x="4" y="8" width="16" height="12" rx="3"/><path d="M12 8V4M8.5 14h.01M15.5 14h.01"/>',
plug:'<path d="M9 2v6M15 2v6M7 8h10v4a5 5 0 01-10 0zM12 17v5"/>',
server:'<rect x="3" y="3" width="18" height="7" rx="2"/><rect x="3" y="14" width="18" height="7" rx="2"/><path d="M7 6.5h.01M7 17.5h.01"/>',
globe:'<circle cx="12" cy="12" r="10"/><path d="M2 12h20M12 2a15 15 0 010 20M12 2a15 15 0 000 20"/>',
list:'<path d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"/>',
bulb:'<path d="M9 18h6M10 22h4M12 2a7 7 0 00-4 12.7V17h8v-2.3A7 7 0 0012 2z"/>',
undo:'<path d="M3 7v6h6M3 13a9 9 0 109-9 9 9 0 00-6.7 3"/>',redo:'<path d="M21 7v6h-6M21 13a9 9 0 11-9-9 9 9 0 016.7 3"/>',
share:'<circle cx="18" cy="5" r="3"/><circle cx="6" cy="12" r="3"/><circle cx="18" cy="19" r="3"/><path d="M8.6 13.5l6.8 4M15.4 6.5l-6.8 4"/>',
ext:'<path d="M18 13v6a2 2 0 01-2 2H5a2 2 0 01-2-2V8a2 2 0 012-2h6M15 3h6v6M10 14L21 3"/>',
alert:'<circle cx="12" cy="12" r="10"/><path d="M12 8v4M12 16h.01"/>',
key:'<circle cx="7.5" cy="15.5" r="4.5"/><path d="M10.7 12.3L21 2M16 7l3 3"/>',
image:'<rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8.5" cy="8.5" r="1.5"/><path d="M21 15l-5-5L5 21"/>',
at:'<circle cx="12" cy="12" r="4"/><path d="M16 8v5a3 3 0 006 0v-1a10 10 0 10-3.9 7.9"/>',
slash:'<path d="M7 21L17 3"/>',dots:'<path d="M5 12h.01M12 12h.01M19 12h.01"/>',
paperclip:'<path d="M21.4 11.6l-9.2 9.2a6 6 0 01-8.5-8.5l9.2-9.2a4 4 0 015.7 5.7l-9.2 9.2a2 2 0 01-2.8-2.8l8.5-8.5"/>',
palette:'<path d="M12 2.7l5.7 5.7a8 8 0 11-11.4 0z"/>',
code:'<path d="M16 18l6-6-6-6M8 6l-6 6 6 6"/>',
shield:'<path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/>',
info:'<circle cx="12" cy="12" r="10"/><path d="M12 16v-4M12 8h.01"/>',
cloud:'<path d="M18 10h-1.3A8 8 0 109 18h9a4 4 0 000-8z"/>',
play:'<path d="M6 4l14 8-14 8z" fill="currentColor"/>',
logo:'<path d="M5 3h14v18H5zM9 7h6v10H9z" fill="currentColor" fill-rule="evenodd" stroke="none"/>'
};
O.icon=(n,c)=>{const s=document.createElement('span');s.className='ic'+(c?' '+c:'');
  s.innerHTML='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">'+(I[n]||I.file)+'</svg>';return s};
O.logo=(w)=>{const s=document.createElementNS('http://www.w3.org/2000/svg','svg');s.setAttribute('viewBox','0 0 48 60');s.setAttribute('class','logo');s.style.width=(w||42)+'px';s.style.height=((w||42)*1.25)+'px';
  s.innerHTML='<path fill="currentColor" fill-rule="evenodd" d="M0 0h48v60H0zM12 12h24v36H12z"/>';return s};
})();
