(function(){
const POLY={triangle:'50,0 100,100 0,100',diamond:'50,0 100,50 50,100 0,50',
  star:'50,0 61,35 98,35 68,57 79,91 50,70 21,91 32,57 2,35 39,35',
  arrow:'100,30 40,30 40,5 0,50 40,95 40,70 100,70'};
const SPK='<svg viewBox="0 0 24 24" fill="currentColor"><path d="M3 9v6h4l5 5V4L7 9H3z"/><path d="M14 8.5a4.5 4.5 0 010 7M16.5 5.5a8.5 8.5 0 010 13" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>';
const Stage={W:1920,H:1080,_fontEl:null,
  mediaURL(name){
    if(!name)return '';
    if(/^(data:|https?:|blob:|file:)/.test(name))return name;
    if(window.MEDIA&&window.MEDIA[name])return window.MEDIA[name];
    return (window.MEDIA_BASE||'shekef://media/')+name.split('/').map(encodeURIComponent).join('/');
  },
  setDeck(m){
    this.H=(m&&m.height)||1080;
    let css='';
    ((m&&m.fonts)||[]).forEach(f=>{css+="@font-face{font-family:'"+f.family+"';src:url('"+this.mediaURL(f.src)+"');font-weight:"+(f.weight||'400')+";font-style:"+(f.style||'normal')+";}\n"});
    if(!this._fontEl){this._fontEl=document.createElement('style');document.head.appendChild(this._fontEl)}
    if(this._fontEl.textContent!==css)this._fontEl.textContent=css;
    document.documentElement.style.setProperty('--H',this.H+'px');
  },
  create(el,mode){
    const n=document.createElement('div');n.className='el el-'+el.type;n.dataset.id=el.id;
    const box=document.createElement('div');box.className='box';n.appendChild(box);
    if(el.type==='text'){const t=document.createElement('div');t.className='txt';t.innerHTML=el.html||'';box.appendChild(t)}
    else if(el.type==='image'){const i=document.createElement('img');i.draggable=false;box.appendChild(i)}
    else if(el.type==='embed'){const f=document.createElement('iframe');f.setAttribute('scrolling','no');box.appendChild(f)}
    else if(el.type==='read'){const b=document.createElement('div');b.className='readbtn';b.innerHTML=SPK+'<span class="lbl"></span>';box.appendChild(b)}
    this.apply(n,el,mode);return n;
  },
  apply(n,el,mode){
    mode=mode||{};
    const s=n.style;s.left=el.x+'px';s.top=el.y+'px';s.width=el.w+'px';s.height=el.h+'px';
    s.rotate=(el.rot||0)+'deg';s.opacity=el.opacity==null?1:el.opacity;
    const box=n.firstChild,b=box.style;
    const css=el.type!=='shape'||!POLY[el.shape]&&el.shape!=='line';
    b.background=css&&el.type!=='image'&&el.type!=='embed'?(el.fill||'transparent'):'transparent';
    b.border=css&&el.strokeW?(el.strokeW+'px solid '+(el.stroke||'#000')):'none';
    let rad=el.radius||0;
    if(el.type==='shape'){if(el.shape==='ellipse')rad='50%';else if(el.shape==='round')rad=(el.radius||28)}
    b.borderRadius=typeof rad==='number'?rad+'px':rad;
    b.boxShadow=el.shadow&&css?'0 14px 36px rgba(0,0,0,.28)':'none';
    if(el.type==='text'){
      const t=box.firstChild,ts=t.style;
      b.justifyContent={middle:'center',bottom:'flex-end'}[el.valign]||'flex-start';
      b.padding=(el.pad==null?12:el.pad)+'px';
      ts.fontFamily="'"+(el.font||'Arial Hebrew')+"','Arial Hebrew','Arial',sans-serif";
      ts.fontSize=(el.size||48)+'px';ts.color=el.color||'#1b2540';
      ts.direction=el.dir||'rtl';ts.textAlign=el.align||'right';
      ts.fontWeight=el.bold?'700':'400';ts.fontStyle=el.italic?'italic':'normal';
      ts.lineHeight=el.lineHeight||1.3;
      if(mode.keep!==el.id&&t.dataset.h!==(el.html||'')){t.innerHTML=el.html||'';t.dataset.h=el.html||''}
    }else if(el.type==='image'){
      const i=box.firstChild,u=this.mediaURL(el.src);
      if(i.dataset.u!==u){i.dataset.u=u;i.src=u}
      i.style.objectFit=el.fit||'contain';
    }else if(el.type==='shape'){
      const key=[el.shape,el.fill,el.stroke,el.strokeW].join('|');
      if(box.dataset.k!==key){box.dataset.k=key;
        if(POLY[el.shape])box.innerHTML='<svg class="shp" viewBox="0 0 100 100" preserveAspectRatio="none"><polygon points="'+POLY[el.shape]+'" fill="'+(el.fill||'none')+'" stroke="'+(el.strokeW?(el.stroke||'#000'):'none')+'" stroke-width="'+(el.strokeW||0)+'" vector-effect="non-scaling-stroke" stroke-linejoin="round"/></svg>';
        else if(el.shape==='line')box.innerHTML='<div class="ln" style="border-top:'+(el.strokeW||6)+'px solid '+(el.stroke||el.fill||'#1b2540')+';margin-top:-'+((el.strokeW||6)/2)+'px"></div>';
        else box.innerHTML='';
      }
    }else if(el.type==='embed'){
      const f=box.firstChild;
      const u=this.mediaURL(el.src)+'?'+(el.params?el.params+'&':'')+'mode='+(mode.name||'edit');
      if(f.dataset.u!==u){f.dataset.u=u;f.src=u}
    }else if(el.type==='read'){
      const r=box.firstChild;r.querySelector('.lbl').textContent=el.label==null?'הקראה':el.label;
      r.style.color=el.color||'#fff';r.style.fontSize=Math.max(10,el.h*0.42)+'px';
      if(!el.fill)b.background='#1f6feb';
      if(el.radius==null)b.borderRadius=(el.h/2)+'px';
    }
  },
  renderSlide(slide,mode){
    const d=document.createElement('div');d.className='slide';d.dataset.id=slide.id;
    this.applySlide(d,slide);
    slide.elements.forEach((el,i)=>{const n=this.create(el,mode);n.style.zIndex=i+1;d.appendChild(n)});
    return d;
  },
  applySlide(d,slide){
    d.style.background=slide.bg||'#ffffff';
    if(slide.bgImage){d.style.backgroundImage="url('"+this.mediaURL(slide.bgImage)+"')";d.style.backgroundSize='cover';d.style.backgroundPosition='center'}
  },
  plain(html){const d=document.createElement('div');d.innerHTML=(html||'').replace(/<br\s*\/?>/gi,'\n').replace(/<\/(div|p|li)>/gi,'\n');return d.textContent.trim()}
};
window.Stage=Stage;
})();
