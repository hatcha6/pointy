const http=require('http'),fs=require('fs'),path=require('path'),{execFileSync}=require('child_process');
// Capture helpers: static server per harness build, screenshots, CDP screencast -> mp4.
const {chromium}=require('playwright');
// Everything generated lives under WORK (gitignored): harness builds, footage, raw captures.
const WORK=process.env.CAPTURE_WORK||path.join(__dirname,'.work');
const OUT=process.env.OUT||path.join(WORK,'captures');
fs.mkdirSync(OUT,{recursive:true});
const MIME={'.html':'text/html','.js':'text/javascript','.mjs':'text/javascript','.json':'application/json','.wasm':'application/wasm','.png':'image/png','.ttf':'font/ttf','.otf':'font/otf','.woff2':'font/woff2','.css':'text/css','.svg':'image/svg+xml','.jpg':'image/jpeg','.frag':'text/plain','.bin':'application/octet-stream'};
const servers={};
function serve(h){
  if(servers[h]) return servers[h];
  const root=path.join(WORK,'web',h);
  servers[h]=new Promise(res=>{
    const srv=http.createServer((q,r)=>{
      let p=decodeURIComponent(q.url.split('?')[0]); if(p.endsWith('/')) p+='index.html';
      let f=path.join(root,p); if(!fs.existsSync(f)) f=path.join(root,'index.html');
      r.writeHead(200,{'content-type':MIME[path.extname(f)]||'application/octet-stream'}); fs.createReadStream(f).pipe(r);
    }).listen(0,'127.0.0.1',()=>res(`http://127.0.0.1:${srv.address().port}`));
  });
  return servers[h];
}
let browser;
async function launch(){ browser=browser||await chromium.launch({headless:true,channel:'chromium',args:['--force-device-scale-factor=2','--force-color-profile=srgb','--font-render-hinting=none']}); return browser; }
async function open(h,query,{w=1440,h:hh=900,dpr=2,mobile=false}={}){
  const b=await launch();
  const ctx=await b.newContext({viewport:{width:w,height:hh},deviceScaleFactor:dpr,isMobile:mobile,hasTouch:mobile,locale:'ar'});
  const page=await ctx.newPage();
  // A soft touch indicator so recorded taps read on video (pointer-events: none, never hit-tested).
  await page.addInitScript(()=>{ addEventListener('DOMContentLoaded',()=>{
    const st=document.createElement('style'); st.textContent=`#tdot{position:fixed;z-index:2147483647;width:34px;height:34px;margin:-17px 0 0 -17px;border-radius:50%;background:rgba(15,118,110,.18);border:2px solid rgba(15,118,110,.55);pointer-events:none;transition:transform .15s ease,opacity .3s;opacity:0;left:-99px;top:-99px}#tdot.down{transform:scale(.7);background:rgba(15,118,110,.38)}`;
    document.head.appendChild(st); const d=document.createElement('div'); d.id='tdot'; document.body.appendChild(d);
    const mv=e=>{d.style.left=e.clientX+'px'; d.style.top=e.clientY+'px'; d.style.opacity=window.__touches?1:0};
    addEventListener('pointermove',mv,true); addEventListener('pointerdown',e=>{mv(e);d.classList.add('down')},true); addEventListener('pointerup',()=>d.classList.remove('down'),true);
  });});
  page.on('pageerror',e=>console.log('  pageerror',e.message.slice(0,200)));
  const base=await serve(h);
  await page.goto(`${base}/${query||''}`,{waitUntil:'load'});
  await page.waitForSelector('flutter-view, flt-glass-pane',{timeout:60000});
  await page.waitForTimeout(2500);
  // first paint can render button labels as tofu until a relayout
  await page.setViewportSize({width:w+1,height:hh}); await page.waitForTimeout(200);
  await page.setViewportSize({width:w,height:hh}); await page.waitForTimeout(900);
  return {page,ctx,base,w,h:hh};
}
async function shot(page,name){ const f=`${OUT}/${name}.png`; await page.screenshot({path:f}); console.log('  shot',name); return f; }
async function record(page,name,fn,{fps=30,quality=90}={}){
  const cdp=await page.context().newCDPSession(page);
  const vp=page.viewportSize(); const frames=[];
  cdp.on('Page.screencastFrame',async ev=>{ frames.push({t:ev.metadata.timestamp,d:Buffer.from(ev.data,'base64')}); try{await cdp.send('Page.screencastFrameAck',{sessionId:ev.sessionId});}catch{} });
  await cdp.send('Page.startScreencast',{format:'jpeg',quality,maxWidth:vp.width*2,maxHeight:vp.height*2,everyNthFrame:1});
  const t0=Date.now()/1000;
  await fn();
  const t1=Date.now()/1000;
  await cdp.send('Page.stopScreencast');
  const dir=`${OUT}/.frames-${name}`; fs.rmSync(dir,{recursive:true,force:true}); fs.mkdirSync(dir,{recursive:true});
  let list='ffconcat version 1.0\n';
  frames.forEach((f,i)=>{ const fn=`${dir}/${String(i).padStart(5,'0')}.jpg`; fs.writeFileSync(fn,f.d);
    const next=i+1<frames.length?frames[i+1].t:Math.max(f.t+0.5,t1); list+=`file '${fn}'\nduration ${Math.max(0.001,next-f.t).toFixed(4)}\n`; });
  if(frames.length){ list+=`file '${dir}/${String(frames.length-1).padStart(5,'0')}.jpg'\n`; }
  fs.writeFileSync(`${dir}/list.txt`,list);
  const out=`${OUT}/${name}.mp4`;
  execFileSync('ffmpeg',['-loglevel','error','-y','-f','concat','-safe','0','-i',`${dir}/list.txt`,'-vf',`fps=${fps},scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p`,'-c:v','libx264','-crf','18','-preset','slow',out]);
  fs.rmSync(dir,{recursive:true,force:true});
  console.log('  video',name,frames.length,'frames',(t1-t0).toFixed(1)+'s');
  return out;
}
// Human-ish typing and moves
async function type(page,text,delay=70){ for(const ch of text){ await page.keyboard.type(ch); await page.waitForTimeout(delay+Math.random()*40);} }
async function smoothScroll(page,dy,steps=40,x,y){ if(x!==undefined) await page.mouse.move(x,y); for(let i=0;i<steps;i++){ await page.mouse.wheel(0,dy/steps); await page.waitForTimeout(16);} }
async function done(){ if(browser) await browser.close(); process.exit(0); }
module.exports={open,shot,record,type,smoothScroll,done,OUT,WORK,serve};
