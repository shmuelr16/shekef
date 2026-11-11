// רץ בתוך דף HTML זר ומפרק אותו לשקפים ואלמנטים. מחזיר אובייקט JSON.
return await (async()=>{
try{await Promise.race([document.fonts.ready,new Promise(r=>setTimeout(r,1500))])}catch(e){}
const abs=u=>{try{return new URL(u,document.baseURI).href}catch(e){return u}};
const rgba=c=>{const m=(c||'').match(/[\d.]+/g);if(!m)return null;return {r:+m[0],g:+m[1],b:+m[2],a:m[3]==null?1:+m[3]}};
const vis=c=>{const x=rgba(c);return x&&x.a>0.02};
let cands=[...document.querySelectorAll('.reveal .slides > section')];
if(!cands.length)cands=[...document.querySelectorAll('section')].filter(s=>!s.parentElement.closest('section'));
if(cands.length<1)cands=[...document.querySelectorAll('.slide,[data-slide]')].filter(s=>!s.parentElement.closest('.slide,[data-slide]'));
const whole=!cands.length;if(whole)cands=[document.body];
const fonts=[];
for(const ss of document.styleSheets){let rules;try{rules=ss.cssRules}catch(e){continue}
  for(const r of rules){if(r.type===5){const src=r.style.getPropertyValue('src')||'';const m=src.match(/url\(["']?([^"')]+)["']?\)/);
    if(m)fonts.push({family:r.style.getPropertyValue('font-family').replace(/['"]/g,'').trim(),weight:r.style.getPropertyValue('font-weight')||'400',style:r.style.getPropertyValue('font-style')||'normal',url:new URL(m[1],ss.href||document.baseURI).href})}}}
const slides=[];let ratio=1080/1920;
for(const sec of cands){
  const prev=sec.getAttribute('style');
  if(getComputedStyle(sec).display==='none')sec.style.display='block';
  let R=sec.getBoundingClientRect();
  if(whole)R={left:0,top:0,width:innerWidth,height:innerHeight};
  if(R.width<10||R.height<10){if(prev==null)sec.removeAttribute('style');else sec.setAttribute('style',prev);continue}
  const k=1920/R.width;if(!slides.length)ratio=R.height/R.width;
  const els=[];const scs=getComputedStyle(sec);
  let bg=scs.backgroundImage&&scs.backgroundImage!=='none'&&/gradient/.test(scs.backgroundImage)?scs.backgroundImage:(vis(scs.backgroundColor)?scs.backgroundColor:null);
  let bgImage=null;const bm=scs.backgroundImage.match(/url\(["']?([^"')]+)["']?\)/);if(bm)bgImage=abs(bm[1]);
  if(!bg){const b=getComputedStyle(document.body).backgroundColor;bg=vis(b)?b:'#ffffff'}
  const box=(e)=>{const r=e.getBoundingClientRect();return {x:(r.left-R.left)*k,y:(r.top-R.top)*k,w:r.width*k,h:r.height*k}};
  const inside=b=>b.w>1&&b.h>1&&b.x<1920&&b.y<R.height*k&&b.x+b.w>0&&b.y+b.h>0;
  const hasText=e=>[...e.childNodes].some(c=>c.nodeType===3&&c.nodeValue.trim());
  const inlineStyles=(src,dst,root)=>{const rc=getComputedStyle(root);
    const a=[...src.children],b=[...dst.children];
    a.forEach((c,i)=>{const d=b[i];if(!d)return;const cs=getComputedStyle(c);let st='';
      if(cs.color!==rc.color)st+='color:'+cs.color+';';
      if(cs.fontWeight!==rc.fontWeight)st+='font-weight:'+cs.fontWeight+';';
      if(cs.fontStyle!==rc.fontStyle)st+='font-style:'+cs.fontStyle+';';
      if(cs.fontSize!==rc.fontSize)st+='font-size:'+(parseFloat(cs.fontSize)*k).toFixed(1)+'px;';
      if(cs.fontFamily!==rc.fontFamily)st+='font-family:'+cs.fontFamily.replace(/"/g,"'")+';';
      if(/underline/.test(cs.textDecorationLine))st+='text-decoration:underline;';
      if(vis(cs.backgroundColor)&&cs.display.startsWith('inline'))st+='background:'+cs.backgroundColor+';';
      [...d.attributes].forEach(at=>d.removeAttribute(at.name));if(st)d.setAttribute('style',st);
      inlineStyles(c,d,root)})};
  const visit=(e,op)=>{
    const cs=getComputedStyle(e);
    if(cs.display==='none'||cs.visibility==='hidden')return;
    const o=op*parseFloat(cs.opacity||1);if(o<0.02)return;
    const tag=e.tagName.toLowerCase();if(['script','style','link','meta','noscript','template'].includes(tag))return;
    const b=box(e);const rot=0;
    if(tag==='img'){if(inside(b)&&e.currentSrc)els.push({type:'image',...b,url:abs(e.currentSrc||e.src),fit:cs.objectFit==='cover'?'cover':cs.objectFit==='contain'?'contain':'fill',opacity:o,radius:parseFloat(cs.borderTopLeftRadius)*k||0});return}
    if(tag==='svg'){if(inside(b)){const c=e.cloneNode(true);c.setAttribute('xmlns','http://www.w3.org/2000/svg');c.setAttribute('width',b.w/k);c.setAttribute('height',b.h/k);
        c.style.color=cs.color;if(cs.fill&&!c.getAttribute('fill'))c.style.fill=cs.fill;
        els.push({type:'image',...b,svg:new XMLSerializer().serializeToString(c),fit:'fill',opacity:o})}return}
    if(tag==='canvas'){if(inside(b)){try{els.push({type:'image',...b,url:e.toDataURL('image/png'),fit:'fill',opacity:o})}catch(x){}}return}
    if(tag==='video'||tag==='iframe'||tag==='audio')return;
    if(e!==sec&&inside(b)){
      const bw=parseFloat(cs.borderTopWidth)||0,grad=cs.backgroundImage!=='none'&&/gradient/.test(cs.backgroundImage);
      const um=cs.backgroundImage.match(/url\(["']?([^"')]+)["']?\)/);
      if(um)els.push({type:'image',...b,url:abs(um[1]),fit:cs.backgroundSize==='contain'?'contain':'cover',opacity:o,radius:parseFloat(cs.borderTopLeftRadius)*k||0});
      else if(grad||vis(cs.backgroundColor)||(bw>0&&vis(cs.borderTopColor)&&cs.borderTopStyle!=='none')){
        const r=parseFloat(cs.borderTopLeftRadius)||0,round=cs.borderTopLeftRadius.includes('%')&&r>=50;
        els.push({type:'shape',shape:round?'ellipse':'rect',...b,fill:grad?cs.backgroundImage:(vis(cs.backgroundColor)?cs.backgroundColor:null),
          stroke:bw>0?cs.borderTopColor:null,strokeW:bw>0&&cs.borderTopStyle!=='none'?bw*k:null,radius:round?null:Math.min(r*k,Math.min(b.w,b.h)/2),shadow:cs.boxShadow!=='none',opacity:o});
      }
    }
    if(hasText(e)&&e!==sec&&e!==document.body){
      if(!inside(b))return;
      const c=e.cloneNode(true);inlineStyles(e,c,e);
      c.querySelectorAll('script,style').forEach(x=>x.remove());
      const pl=parseFloat(cs.paddingLeft)||0,pr=parseFloat(cs.paddingRight)||0,pt=parseFloat(cs.paddingTop)||0,pb=parseFloat(cs.paddingBottom)||0;
      const lh=parseFloat(cs.lineHeight),fs=parseFloat(cs.fontSize);
      let al=cs.textAlign;const rtl=cs.direction==='rtl';if(al==='start')al=rtl?'right':'left';if(al==='end')al=rtl?'left':'right';if(al==='-webkit-center')al='center';
      els.push({type:'text',x:b.x+pl*k-2,y:b.y+pt*k,w:b.w-(pl+pr)*k+6,h:b.h-(pt+pb)*k,html:c.innerHTML.replace(/\s*\n\s*/g,' ').trim(),
        font:cs.fontFamily.split(',')[0].replace(/['"]/g,'').trim(),size:+(fs*k).toFixed(1),color:cs.color,align:al,dir:cs.direction,
        bold:parseInt(cs.fontWeight)>=600,weight:cs.fontWeight,italic:cs.fontStyle==='italic',lineHeight:isNaN(lh)?1.25:+(lh/fs).toFixed(3),pad:0,opacity:o,
        spacing:cs.letterSpacing!=='normal'?parseFloat(cs.letterSpacing)*k:null});
      return;
    }
    for(const c of e.children)visit(c,o);
  };
  visit(sec,1);
  slides.push({bg,bgImage,elements:els});
  if(prev==null)sec.removeAttribute('style');else sec.setAttribute('style',prev);
}
return JSON.stringify({ratio,slides,fonts,title:document.title});
})();
