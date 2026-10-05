// The site's clips, recorded from the real harnesses. Usage: node videos.js [v-pos v-ai v-cam v-ops v-phone-dash]
const L=require('./lib'); const fsrv=require('./footage-server');
const sleep=(p,ms)=>p.waitForTimeout(ms);
const tapper=page=>async(x,y,wait=650)=>{ await page.mouse.move(x,y,{steps:18}); await sleep(page,120); await page.mouse.down(); await sleep(page,90); await page.mouse.up(); await sleep(page,wait); };
const scenes={
 async 'v-pos'(){ const {page,ctx}=await L.open('pos_preview','?screen=pos',{w:1440,h:900,dpr:2}); const tap=tapper(page);
  await page.mouse.click(56,112); await sleep(page,500); await page.mouse.click(612,520); await sleep(page,900);
  await page.evaluate(()=>window.__touches=true); await page.mouse.move(1200,500);
  await L.record(page,'v-pos',async()=>{ await sleep(page,600);
   await tap(920,160,300); await L.type(page,'قهوة',120); await sleep(page,600);
   await tap(1062,390,500); await tap(1062,390,700); await tap(698,158,500); await tap(888,218,700);
   await tap(1062,390,700); await tap(1067,218,700); await tap(830,390,900);
   await tap(230,848,1400); await tap(960,432,900); await tap(310,744,2400); });
  await ctx.close(); },
 async 'v-ai'(){ const {page,ctx}=await L.open('ai_chat_preview','?screen=ui-live',{w:1440,h:900,dpr:2}); const tap=tapper(page);
  await page.evaluate(()=>window.__touches=true); await page.mouse.move(700,600);
  await L.record(page,'v-ai',async()=>{ await sleep(page,500); await tap(620,830,300);
   await L.type(page,'كيف كانت مبيعات الشهر؟',95); await sleep(page,400); await page.keyboard.press('Enter');
   await sleep(page,5000); await L.smoothScroll(page,-1400,90,700,450); await sleep(page,1800); await L.smoothScroll(page,700,90,700,450); await sleep(page,1600); await L.smoothScroll(page,900,90,700,450); await sleep(page,2000); });
  await ctx.close(); },
 async 'v-cam'(){ const rig=await fsrv(); const {page,ctx}=await L.open('cameras_preview',`?screen=invoice&source=rig-clean&rig=${encodeURIComponent(rig)}`,{w:390,h:844,dpr:2}); const tap=tapper(page);
  await page.evaluate(()=>window.__touches=true); await page.mouse.move(200,600);
  await L.record(page,'v-cam',async()=>{ await sleep(page,800); await tap(195,274,7000); await tap(150,152,4500); });
  await L.shot(page,'v-cam-end'); await ctx.close(); },
 async 'v-ops'(){ const {page,ctx}=await L.open('operations_preview','?screen=board',{w:1440,h:900,dpr:2}); const tap=tapper(page);
  await page.evaluate(()=>window.__touches=true); await page.mouse.move(900,760);
  await L.record(page,'v-ops',async()=>{ await sleep(page,900);
   // REP-104: received -> diagnosing -> waiting for approval -> repairing,
   // entering the price the customer agreed on the way through approval
   await tap(1030,694,1700); await tap(695,696,1700); await tap(350,694,1100);
   await L.type(page,'185',160); await sleep(page,500); await tap(633,543,1900);
   // slide the board to the later columns and back
   await page.mouse.move(700,640,{steps:12});
   for(let i=0;i<45;i++){ await page.mouse.wheel(-20,0); await sleep(page,16);} await sleep(page,1500);
   for(let i=0;i<45;i++){ await page.mouse.wheel(20,0); await sleep(page,16);} await sleep(page,1200); });
  await ctx.close(); },
 async 'v-phone-dash'(){ const {page,ctx}=await L.open('dashboard_preview','?screen=dashboard',{w:390,h:844,dpr:2});
  await L.record(page,'v-phone-dash',async()=>{ await sleep(page,900); for(let i=0;i<4;i++){ await L.smoothScroll(page,520,50,200,500); await sleep(page,1100);} await L.smoothScroll(page,-2080,70,200,500); await sleep(page,900); });
  await ctx.close(); },
 async 'v-phone-pos'(){ const {page,ctx}=await L.open('pos_preview','?screen=pos',{w:390,h:844,dpr:2});
  await L.shot(page,'v-phone-pos-start'); await ctx.close(); },
};
(async()=>{ const only=process.argv.slice(2); for(const [k,f] of Object.entries(scenes)){ if(only.length&&!only.includes(k)) continue; try{ await f(); }catch(e){console.log('ERR',k,e.message.slice(0,200));} } await L.done(); })();
