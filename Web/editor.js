const Editor=(()=>{
let slide=null,sel=new Set(),scale=1,editing=null,slideEl=null,txtTimer=null,lastClip=0;
const root=document.getElementById('root'),ov=document.getElementById('ov');
const nodes=new Map();
const post=m=>{try{webkit.messageHandlers.shekef.postMessage(m)}catch(e){}};
const byId=id=>slide&&slide.elements.find(e=>e.id===id);
const rad=d=>d*Math.PI/180;

function fit(){
  const W=innerWidth-56,H=innerHeight-56;scale=Math.max(.05,Math.min(W/Stage.W,H/Stage.H));
  root.style.transform='scale('+scale+') translate(-50%,-50%)';
  root.style.setProperty('--inv',1/scale);
}
addEventListener('resize',fit);

function load(s,meta,selIds){
  Stage.setDeck(meta);fit();
  if(!slideEl||!slide||slide.id!==s.id){
    if(editing)stopEdit(true);
    if(slideEl)slideEl.remove();nodes.clear();
    slideEl=document.createElement('div');slideEl.className='slide';root.insertBefore(slideEl,ov);
  }
  slide=s;Stage.applySlide(slideEl,s);
  const seen=new Set();
  s.elements.forEach((el,i)=>{
    seen.add(el.id);let n=nodes.get(el.id);
    if(!n){n=Stage.create(el,{name:'edit'});nodes.set(el.id,n);slideEl.appendChild(n)}
    else Stage.apply(n,el,{name:'edit',keep:editing});
    n.style.zIndex=i+1;
  });
  for(const [id,n] of nodes){if(!seen.has(id)){if(editing===id){editing=null;post({type:'editing',id:null})}n.remove();nodes.delete(id)}}
  if(selIds)sel=new Set(selIds.filter(id=>seen.has(id)));
  else sel=new Set([...sel].filter(id=>seen.has(id)));
  drawSel();
}
function select(ids,quiet){sel=new Set(ids);drawSel();if(!quiet)post({type:'select',ids:[...sel]})}

function drawSel(){
  ov.querySelectorAll('.sb').forEach(n=>n.remove());
  for(const id of sel){
    const el=byId(id);if(!el)continue;
    const b=document.createElement('div');b.className='sb'+(editing===id?' ed':'');
    b.style.cssText='left:'+el.x+'px;top:'+el.y+'px;width:'+el.w+'px;height:'+el.h+'px;rotate:'+(el.rot||0)+'deg';
    if(sel.size===1&&editing!==id){
      [['nw',0,0],['n',50,0],['ne',100,0],['e',100,50],['se',100,100],['s',50,100],['sw',0,100],['w',0,50]].forEach(([k,x,y])=>{
        const h=document.createElement('div');h.className='hd';h.dataset.h=k;h.style.left=x+'%';h.style.top=y+'%';
        h.style.cursor={n:'ns',s:'ns',e:'ew',w:'ew',nw:'nwse',se:'nwse',ne:'nesw',sw:'nesw'}[k]+'-resize';b.appendChild(h)});
      const r=document.createElement('div');r.className='hd rot';r.dataset.h='rot';r.style.left='50%';r.style.top='calc(-28px*var(--inv))';b.appendChild(r);
    }
    ov.appendChild(b);
  }
}
function pt(e){const r=root.getBoundingClientRect();return {x:(e.clientX-r.left)/scale,y:(e.clientY-r.top)/scale}}
function geom(ids){post({type:'geom',items:ids.map(id=>{const e=byId(id);return {id,x:e.x,y:e.y,w:e.w,h:e.h,rot:e.rot||0}})})}
function refresh(el){const n=nodes.get(el.id);if(n)Stage.apply(n,el,{name:'edit',keep:editing})}
function guides(list){ov.querySelectorAll('.guide').forEach(n=>n.remove());
  list.forEach(g=>{const d=document.createElement('div');d.className='guide';
    d.style.cssText=g.v!=null?'left:'+g.v+'px;top:0;width:'+(1/scale)+'px;height:100%':'top:'+g.h+'px;left:0;height:'+(1/scale)+'px;width:100%';ov.appendChild(d)})}

function elAt(t){const n=t.closest&&t.closest('.el');return n&&nodes.has(n.dataset.id)?n.dataset.id:null}

document.addEventListener('mousedown',e=>{
  if(e.button!==0||!slide)return;
  const hd=e.target.closest&&e.target.closest('.hd');
  if(hd){e.preventDefault();startResize(e,hd.dataset.h);return}
  const id=elAt(e.target);
  if(editing){if(id===editing)return;stopEdit()}
  if(!id){if(!e.shiftKey)select([]);startMarquee(e);e.preventDefault();return}
  e.preventDefault();window.focus();
  if(e.shiftKey){const s=new Set(sel);s.has(id)?s.delete(id):s.add(id);select([...s])}
  else if(!sel.has(id))select([id]);
  startMove(e);
});
document.addEventListener('dblclick',e=>{const id=elAt(e.target);if(!id)return;const el=byId(id);
  if(el.type==='text')startEdit(id,e)});

function drag(move,up){const mm=e=>{move(e)};const mu=e=>{removeEventListener('mousemove',mm,true);removeEventListener('mouseup',mu,true);up(e)};
  addEventListener('mousemove',mm,true);addEventListener('mouseup',mu,true)}

function startMove(e){
  const p0=pt(e),ids=[...sel],st=ids.map(id=>{const el=byId(id);return {el,x:el.x,y:el.y}});let moved=false;
  drag(ev=>{
    const p=pt(ev);let dx=p.x-p0.x,dy=p.y-p0.y;
    if(!moved&&Math.abs(dx)+Math.abs(dy)<3/scale)return;moved=true;
    const g=[];
    if(st.length===1&&!ev.metaKey){
      const s=st[0],el=s.el,th=7/scale,nx=s.x+dx,ny=s.y+dy;
      const xs=[[0,nx],[Stage.W/2,nx+el.w/2],[Stage.W,nx+el.w]],ys=[[0,ny],[Stage.H/2,ny+el.h/2],[Stage.H,ny+el.h]];
      for(const o of slide.elements){if(o.id===el.id)continue;xs.push([o.x+o.w/2,nx+el.w/2],[o.x,nx],[o.x+o.w,nx+el.w]);ys.push([o.y+o.h/2,ny+el.h/2],[o.y,ny],[o.y+o.h,ny+el.h])}
      for(const [t,v] of xs)if(Math.abs(t-v)<th){dx+=t-v;g.push({v:t});break}
      for(const [t,v] of ys)if(Math.abs(t-v)<th){dy+=t-v;g.push({h:t});break}
    }
    if(ev.shiftKey){Math.abs(dx)>Math.abs(dy)?dy=0:dx=0}
    st.forEach(s=>{s.el.x=Math.round(s.x+dx);s.el.y=Math.round(s.y+dy);refresh(s.el)});
    guides(g);drawSel();
  },()=>{guides([]);if(moved)geom(ids);else if(ids.length===1&&!e.shiftKey){const el=byId(ids[0]);if(el&&el.type==='read')post({type:'read',id:el.id})}});
}
function startResize(e,h){
  const id=[...sel][0],el=byId(id);if(!el)return;
  const p0=pt(e),o={x:el.x,y:el.y,w:el.w,h:el.h,rot:el.rot||0},cx=o.x+o.w/2,cy=o.y+o.h/2;
  const keep=el.type==='image'||el.type==='read';
  drag(ev=>{
    const p=pt(ev);
    if(h==='rot'){let a=Math.atan2(p.y-cy,p.x-cx)*180/Math.PI+90;if(ev.shiftKey)a=Math.round(a/15)*15;
      if(Math.abs(((a%90)+90)%90)<3||Math.abs(((a%90)+90)%90-90)<3)a=Math.round(a/90)*90;el.rot=Math.round(((a%360)+360)%360);refresh(el);drawSel();return}
    const c=Math.cos(rad(-o.rot)),s=Math.sin(rad(-o.rot));
    let dx=(p.x-p0.x)*c-(p.y-p0.y)*s,dy=(p.x-p0.x)*s+(p.y-p0.y)*c;
    let l=0,t=0,r=0,b=0;
    if(h.includes('w'))l=dx;if(h.includes('e'))r=dx;if(h.includes('n'))t=dy;if(h.includes('s'))b=dy;
    let w=Math.max(10,o.w-l+r),hh=Math.max(10,o.h-t+b);
    if((keep!==ev.shiftKey)&&h.length===2){const k=Math.max(w/o.w,hh/o.h);w=o.w*k;hh=o.h*k}
    const dw=w-o.w,dh=hh-o.h;
    const mx=(h.includes('w')?-dw/2:h.includes('e')?dw/2:0),my=(h.includes('n')?-dh/2:h.includes('s')?dh/2:0);
    const c2=Math.cos(rad(o.rot)),s2=Math.sin(rad(o.rot));
    const ncx=cx+mx*c2-my*s2,ncy=cy+mx*s2+my*c2;
    el.w=Math.round(w);el.h=Math.round(hh);el.x=Math.round(ncx-w/2);el.y=Math.round(ncy-hh/2);
    refresh(el);drawSel();
  },()=>geom([id]));
}
function startMarquee(e){
  const p0=pt(e);let m=null;
  drag(ev=>{const p=pt(ev);if(!m){m=document.createElement('div');m.className='mq';ov.appendChild(m)}
    const x=Math.min(p.x,p0.x),y=Math.min(p.y,p0.y),w=Math.abs(p.x-p0.x),h=Math.abs(p.y-p0.y);
    m.style.cssText='left:'+x+'px;top:'+y+'px;width:'+w+'px;height:'+h+'px';m._r={x,y,w,h}},
  ()=>{if(!m)return;const r=m._r;m.remove();
    select(slide.elements.filter(el=>el.x<r.x+r.w&&el.x+el.w>r.x&&el.y<r.y+r.h&&el.y+el.h>r.y).map(el=>el.id))});
}

function startEdit(id,ev){
  if(editing===id)return;if(editing)stopEdit();
  const n=nodes.get(id);if(!n)return;const t=n.querySelector('.txt');
  editing=id;n.classList.add('editing');t.contentEditable='true';t.focus();
  const r=document.createRange();r.selectNodeContents(t);if(ev)r.collapse(false);
  const s=getSelection();s.removeAllRanges();s.addRange(r);
  if(ev&&document.caretRangeFromPoint){const cr=document.caretRangeFromPoint(ev.clientX,ev.clientY);if(cr&&t.contains(cr.startContainer)){s.removeAllRanges();s.addRange(cr)}}
  select([id],true);post({type:'select',ids:[id]});post({type:'editing',id});drawSel();
}
function flushText(){
  clearTimeout(txtTimer);txtTimer=null;if(!editing)return;
  const n=nodes.get(editing),el=byId(editing);if(!n||!el)return;const t=n.querySelector('.txt');
  el.html=t.innerHTML;t.dataset.h=el.html;
  const need=Math.ceil(t.scrollHeight+2*(el.pad==null?12:el.pad));
  if(need>el.h){el.h=need;refresh(el);drawSel()}
  post({type:'text',id:el.id,html:el.html,h:el.h});
}
function stopEdit(silent){
  if(!editing)return;flushText();
  const n=nodes.get(editing);if(n){n.classList.remove('editing');const t=n.querySelector('.txt');t.contentEditable='false';t.blur()}
  getSelection().removeAllRanges();editing=null;if(!silent)post({type:'editing',id:null});drawSel();
}
document.addEventListener('input',()=>{if(!editing)return;clearTimeout(txtTimer);txtTimer=setTimeout(flushText,350);
  const el=byId(editing),n=nodes.get(editing);if(el&&n){const t=n.querySelector('.txt');const need=Math.ceil(t.scrollHeight+2*(el.pad==null?12:el.pad));if(need>el.h){el.h=need;refresh(el);drawSel()}}});
document.addEventListener('paste',e=>{
  if(editing){e.preventDefault();const tx=(e.clipboardData||window.clipboardData).getData('text/plain');document.execCommand('insertText',false,tx);return}
  e.preventDefault();clip('paste')});
document.addEventListener('copy',e=>{if(editing)return;e.preventDefault();clip('copy')});
document.addEventListener('cut',e=>{if(editing)return;e.preventDefault();clip('cut')});
function clip(c){const n=Date.now();if(n-lastClip<250)return;lastClip=n;post({type:'cmd',cmd:c})}

document.addEventListener('keydown',e=>{
  if(editing){if(e.key==='Escape'){e.preventDefault();stopEdit()}return}
  const k=e.key,m=e.metaKey;
  if(m&&!e.shiftKey&&['c','x','v'].includes(k.toLowerCase())){e.preventDefault();clip({c:'copy',x:'cut',v:'paste'}[k.toLowerCase()]);return}
  if(m&&k.toLowerCase()==='a'){e.preventDefault();select(slide.elements.map(x=>x.id));return}
  if(m&&k.toLowerCase()==='d'){e.preventDefault();post({type:'cmd',cmd:'duplicate'});return}
  if(m)return;
  if(k==='Backspace'||k==='Delete'){e.preventDefault();if(sel.size)post({type:'cmd',cmd:'delete'});return}
  if(k==='Escape'){select([]);return}
  if(k==='Enter'&&sel.size===1){const el=byId([...sel][0]);if(el&&el.type==='text'){e.preventDefault();startEdit(el.id)}return}
  if(k==='Tab'&&slide.elements.length){e.preventDefault();const ids=slide.elements.map(x=>x.id);const i=ids.indexOf([...sel][0]);select([ids[(i+(e.shiftKey?-1:1)+ids.length)%ids.length]]);return}
  const d={ArrowLeft:[-1,0],ArrowRight:[1,0],ArrowUp:[0,-1],ArrowDown:[0,1]}[k];
  if(d&&sel.size){e.preventDefault();const s=e.shiftKey?10:1;for(const id of sel){const el=byId(id);el.x+=d[0]*s;el.y+=d[1]*s;refresh(el)}drawSel();
    post({type:'geom',nudge:true,items:[...sel].map(id=>{const x=byId(id);return {id,x:x.x,y:x.y,w:x.w,h:x.h,rot:x.rot||0}})})}
});
function exec(cmd,val){if(!editing)return false;document.execCommand('styleWithCSS',false,true);document.execCommand(cmd,false,val==null?null:val);flushText();return true}
function setSpeaking(id,on){const n=nodes.get(id);if(n)n.classList.toggle('speaking',!!on)}
fit();
return {load,select:(ids)=>select(ids,true),exec,stopEdit,startEdit,setSpeaking,isEditing:()=>!!editing};
})();
post_ready();
function post_ready(){try{webkit.messageHandlers.shekef.postMessage({type:'ready'})}catch(e){}}
