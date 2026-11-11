const Player=(()=>{
let deck=null,idx=0,step=0,steps=[],cur=null,busy=false,scale=1;
const vp=document.getElementById('vp');
const native=!!(window.webkit&&webkit.messageHandlers&&webkit.messageHandlers.shekef);
let webAudio=null,webRead=null;
function post(m){
  if(native){webkit.messageHandlers.shekef.postMessage(m);return}
  // גיבוי לדפדפן (ייצוא HTML)
  if(m.type==='sfx'){const u=Stage.mediaURL('sfx/'+m.name+'.wav');try{new Audio(u).play()}catch(e){}}
  else if(m.type==='stop'){stopWeb()}
  else if(m.type==='audio'){stopWeb();webAudio=new Audio(Stage.mediaURL(m.src));webAudio.play().catch(()=>{})}
  else if(m.type==='read'){
    const s=deck.slides[idx],el=s.elements.find(e=>e.id===m.id);if(!el)return;
    if(webRead===el.id){stopWeb();return}
    stopWeb();webRead=el.id;setSpeaking(el.id,true);
    const done=()=>{if(webRead===el.id){webRead=null;setSpeaking(el.id,false)}};
    if(el.src){webAudio=new Audio(Stage.mediaURL(el.src));webAudio.onended=done;webAudio.play().catch(done)}
    else{const t=s.elements.find(e=>e.id===el.target);const u=new SpeechSynthesisUtterance(Stage.plain(t?t.html:''));u.lang='he-IL';u.rate=.9;u.onend=done;u.onerror=done;speechSynthesis.speak(u)}
  }
}
function stopWeb(){if(webAudio){webAudio.pause();webAudio=null}if(window.speechSynthesis)speechSynthesis.cancel();if(webRead){setSpeaking(webRead,false);webRead=null}}
function fit(){scale=Math.min(innerWidth/Stage.W,innerHeight/Stage.H);vp.style.width=Stage.W+'px';vp.style.height=Stage.H+'px';
  vp.style.transform='translate(-50%,-50%) scale('+scale+')'}
addEventListener('resize',fit);
function computeSteps(s){const auto=[],st=[];let last=null;
  const an=s.elements.map((e,i)=>({e,i})).filter(o=>o.e.anim&&o.e.anim!=='none').sort((a,b)=>((a.e.step==null?1e6:a.e.step)-(b.e.step==null?1e6:b.e.step))||a.i-b.i);
  an.forEach(({e})=>{if(e.step===0){auto.push(e);return}
    if(e.step!=null){if(e.step!==last){st.push([]);last=e.step}st[st.length-1].push(e)}
    else{if(e.animWith&&st.length)st[st.length-1].push(e);else st.push([e]);last=null}});
  return {auto,st}}
function startLoops(n,e){(e.loops||[]).forEach(l=>{
  const o={duration:l.dur||3000,delay:l.delay||0,easing:'ease-in-out',iterations:l.once?1:Infinity,direction:l.once?'normal':'alternate',fill:l.once?'forwards':'none'};
  if(l.k==='move')n.animate([{translate:'0 0'},{translate:(l.dx||0)+'px '+(l.dy||0)+'px'}],Object.assign({composite:'add'},o));
  else if(l.k==='scale')n.animate([{scale:1},{scale:l.by||1.05}],o);
  else if(l.k==='spin'){const r=e.rot||0;n.animate([{rotate:r+'deg'},{rotate:(r+(l.deg||0))+'deg'}],o)}})}
function node(layer,id){return layer.querySelector('.el[data-id="'+id+'"]')}
const KF={fade:[{opacity:0},{}],up:[{opacity:0,translate:'0 70px'},{translate:'0 0'}],down:[{opacity:0,translate:'0 -70px'},{translate:'0 0'}],
  right:[{opacity:0,translate:'90px 0'},{translate:'0 0'}],left:[{opacity:0,translate:'-90px 0'},{translate:'0 0'}],
  zoom:[{opacity:0,scale:.6},{scale:1}],wipe:[{clipPath:'inset(0 0 0 100%)',opacity:.2},{clipPath:'inset(0 0 0 0)',opacity:1}],pop:[{opacity:0,scale:.2},{scale:1.12,offset:.7},{scale:1}]};
function reveal(layer,e,animate){const n=node(layer,e.id);if(!n)return;
  const run=()=>{if(animate&&cur!==layer)return;n.style.visibility='visible';
    if(animate){n.animate(KF[e.anim]||KF.fade,{duration:Math.min(1500,e.dur||(e.anim==='pop'?520:480)),easing:'cubic-bezier(.2,.8,.2,1)'});if(e.aSound)post({type:'sfx',name:e.aSound})}
    embedMsg(n,{type:'shekef',event:'reveal'})};
  if(animate&&e.delay)setTimeout(run,e.delay);else run()}
function embedMsg(n,m){const f=n.querySelector&&n.querySelector('iframe');if(f&&f.contentWindow)try{f.contentWindow.postMessage(m,'*')}catch(e){}}
function build(i,atEnd){
  const s=deck.slides[i],layer=Stage.renderSlide(s,{name:'play'});
  const c=computeSteps(s);
  c.st.concat([c.auto]).forEach(g=>g.forEach(e=>{const n=node(layer,e.id);if(n&&!atEnd)n.style.visibility='hidden'}));
  s.elements.forEach(e=>{if(e.loops){const n=node(layer,e.id);if(n)startLoops(n,e)}});
  return {layer,st:c.st,auto:c.auto};
}
function go(i,dir,atEnd){
  if(busy||i<0||i>=deck.slides.length)return;
  post({type:'stop'});
  const s=deck.slides[i],old=cur,b=build(i,atEnd),nw=b.layer;
  let tr=dir>0?(s.transition||'fade'):(deck.slides[idx].transition||'fade');
  if(!old)tr='none';
  vp.appendChild(nw);cur=nw;idx=i;steps=b.st;step=atEnd?steps.length:0;
  post({type:'slide',index:i});
  if(!atEnd)setTimeout(()=>{if(cur===nw)b.auto.forEach(e=>reveal(nw,e,true))},old?350:100);
  if(dir>0&&s.tSound&&old)post({type:'sfx',name:s.tSound});
  if(s.audio&&s.audioAuto!==false)setTimeout(()=>{if(idx===i)post({type:'audio',src:s.audio})},tr==='none'?50:650);
  const done=()=>{if(old)old.remove();busy=false};
  if(tr==='none'||!old){done();return}
  busy=true;const D=600,E='cubic-bezier(.4,0,.2,1)';
  if(tr==='push'){const k=dir>0?-1:1;
    nw.animate([{translate:(k*100)+'% 0'},{translate:'0 0'}],{duration:D,easing:E});
    old.animate([{translate:'0 0'},{translate:(-k*100)+'% 0'}],{duration:D,easing:E}).onfinish=done}
  else if(tr==='zoom'){
    nw.animate([{opacity:0,scale:.82},{opacity:1,scale:1}],{duration:D,easing:E});
    old.animate([{opacity:1,scale:1},{opacity:0,scale:1.15}],{duration:D,easing:E,fill:'forwards'}).onfinish=done}
  else if(tr==='morph'){morph(old,nw,deck.slides[i],done)}
  else{nw.animate([{opacity:0},{opacity:1}],{duration:D,easing:'ease'}).onfinish=done}
}
function morph(old,nw,s,done){
  const D=1100,E='cubic-bezier(.45,0,.2,1)';
  const olds=new Map();old.querySelectorAll('.el').forEach(n=>{if(n.dataset.m)olds.set(n.dataset.m,n)});
  const bg=document.createElement('div');bg.style.cssText='position:absolute;inset:0;z-index:0';bg.style.background=nw.style.background;
  nw.style.background='transparent';nw.insertBefore(bg,nw.firstChild);
  bg.animate([{opacity:0},{opacity:1}],{duration:D,easing:'ease'});
  nw.querySelectorAll('.el').forEach(n=>{
    const o=n.dataset.m&&olds.get(n.dataset.m);
    if(o&&n.style.visibility!=='hidden'){
      const ox=parseFloat(o.style.left),oy=parseFloat(o.style.top),ow=parseFloat(o.style.width),oh=parseFloat(o.style.height);
      const x=parseFloat(n.style.left),y=parseFloat(n.style.top),w=parseFloat(n.style.width),h=parseFloat(n.style.height);
      n.style.transformOrigin='0 0';
      n.animate([{transform:'translate('+(ox-x)+'px,'+(oy-y)+'px) scale('+(ow/w)+','+(oh/h)+')',rotate:o.style.rotate,opacity:o.style.opacity},
                 {transform:'none',rotate:n.style.rotate,opacity:n.style.opacity}],{duration:D,easing:E}).onfinish=()=>{n.style.transformOrigin=''};
      o.style.visibility='hidden';
    }else n.animate([{opacity:0},{opacity:n.style.opacity||1}],{duration:D,easing:'ease'});
  });
  old.style.background='transparent';
  old.animate([{opacity:1},{opacity:0}],{duration:D*.7,easing:'ease',fill:'forwards'});
  setTimeout(()=>{nw.style.background=bg.style.background;bg.remove();Stage.applySlide(nw,s);done()},D+20);
}
function next(){
  if(busy)return;
  if(step<steps.length){steps[step].forEach(e=>reveal(cur,e,true));step++;return}
  if(idx<deck.slides.length-1)go(idx+1,1,false);
}
function prev(){
  if(busy)return;
  if(step>0){step--;steps[step].forEach(e=>{const n=node(cur,e.id);if(n)n.style.visibility='hidden'});return}
  if(idx>0)go(idx-1,-1,true);
}
function setSpeaking(id,on){const n=cur&&node(cur,id);if(n)n.classList.toggle('speaking',!!on)}
document.addEventListener('keydown',e=>{
  const k=e.key;
  if(['ArrowRight','ArrowDown',' ','Enter','PageDown','n'].includes(k)){e.preventDefault();next()}
  else if(['ArrowLeft','ArrowUp','PageUp','Backspace','p'].includes(k)){e.preventDefault();prev()}
  else if(k==='Home'){go(0,-1,false)}else if(k==='End'){go(deck.slides.length-1,1,false)}
  else if(k==='Escape'){post({type:'exit',index:idx})}
});
document.addEventListener('click',e=>{
  const r=e.target.closest&&e.target.closest('.el-read');
  if(r){e.stopPropagation();post({type:'read',id:r.dataset.id,slide:idx});return}
  next();
});
document.addEventListener('contextmenu',e=>{e.preventDefault();prev()});
function start(d,i){deck=d;Stage.setDeck(d);fit();
  const orig=Stage.create.bind(Stage);
  Stage.create=function(el,mode){const n=orig(el,mode);n.dataset.m=el.morph||el.id;return n};
  go(Math.max(0,Math.min(i||0,d.slides.length-1)),1,false)}
return {start,next,prev,setSpeaking};
})();
