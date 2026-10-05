// Retina stills of every surface the site shows. Usage: node stills.js [name ...]
const L=require('./lib');
const D={w:1440,h:900}, P={w:390,h:844}, T={w:1180,h:820};
const shots=[
 ['d-pos','pos_preview','?screen=pos',D],['d-pos-dark','pos_preview','?screen=pos&theme=dark',D],
 ['d-dashboard','dashboard_preview','?screen=dashboard',D],['d-dashboard-dark','dashboard_preview','?screen=dark',D],
 ['d-ai-ui','ai_chat_preview','?screen=ui',D],['d-ai-actions','ai_chat_preview','?screen=actions',D],['d-ai-po','ai_chat_preview','?screen=po',D],
 ['d-ops-board','operations_preview','?screen=board',D],['d-ops-details','operations_preview','?screen=details',D],
 ['d-palette','command_palette_preview','',D],['d-palette-dark','command_palette_preview','?theme=dark',D],
 ['d-report-profit','reports_preview','?screen=result&report=profit_costs',{w:1180,h:820}],
 ['d-report-aging','reports_preview','?screen=result&report=unit_aging',{w:1180,h:820}],
 ['d-purchase','pos_preview','?screen=purchase',D],
 ['t-kiosk','price_checker_kiosk_preview','?state=found',T],
 ['t-migration','migration_preview','?screen=review',T],
 ['p-dashboard','dashboard_preview','?screen=dashboard',P],['p-dashboard-dark','dashboard_preview','?screen=dark',P],
 ['p-pos','pos_preview','?screen=pos',P],['p-ai','ai_chat_preview','?screen=ui',P],
 ['p-sms','messaging_preview','?screen=active',P],['p-sms-prepaid','messaging_preview','?screen=prepaid',P],
 ['p-campaign','campaigns_preview','?screen=cost',P],['p-conversation','conversations_preview','?screen=active',P],
 ['p-remote','subscription_preview','?screen=active',P],['p-remote-guide','learning_preview','?screen=remote',P],
 ['p-treasury','treasury_preview','?screen=position',P],['p-po','purchasing_preview','?screen=po-received-due',P],
 ['p-count','stock_count_preview','?screen=counting-item',P],['p-recon','stock_count_preview','?screen=recon',P],
 ['p-serial','product_form_preview','?screen=tracked-details',P],['p-tracking','product_form_preview','?screen=tracking-settings',P],
 ['p-asset','operations_preview','?screen=asset-details',P],['p-job','operations_preview','?screen=details',P],['p-ops-board','operations_preview','?screen=board',P],
 ['p-ftp','cameras_preview','?screen=ftp-connection&state=receiving',P],
 ['p-loan','employee_loans_preview','?screen=new',P],['p-invoice-ai','ai_ui_preview','?screen=invoice',P,{clipTop:56}],
 ['p-zreport','register_session_preview','',P],['p-customer','balances_preview','?screen=customer',P],
 ['p-login','login_preview','',P],['p-setup','shop_setup_preview','',P],['p-fx','dashboard_preview','?screen=fx',P],
 // dev/marketing_preview.dart surfaces
  ['d-pos-serial','marketing_preview','?screen=pos-serial',D],['d-payroll','marketing_preview','?screen=payroll',D],['d-attendance','marketing_preview','?screen=attendance',D],['d-exchange-rates','marketing_preview','?screen=exchange-rates',D],
  ['p-updates','marketing_preview','?screen=updates',P],['p-updates-downloading','marketing_preview','?screen=updates-downloading',P],['p-updates-current','marketing_preview','?screen=updates-current',P],
  ['p-attendance','marketing_preview','?screen=attendance',P],['p-attendance-device','marketing_preview','?screen=attendance-device',P],['p-payroll','marketing_preview','?screen=payroll',P],
  ['p-product-fx','marketing_preview','?screen=product-fx',P],['p-exchange-rates','marketing_preview','?screen=exchange-rates',P],['p-pos-serial','marketing_preview','?screen=pos-serial',P],
];
(async()=>{ const only=process.argv.slice(2);
 const todo=shots.filter(s=>!only.length||only.includes(s[0]));
 const N=4; let k=0;
 await Promise.all(Array.from({length:N},async()=>{ while(k<todo.length){ const [name,h,q,v,opt={}]=todo[k++];
   try{ const {page,ctx}=await L.open(h,q,{w:v.w,h:v.h,dpr:2}); await page.waitForTimeout(h==='marketing_preview'?2500:1800);
     if(opt.clipTop){ await page.screenshot({path:`${L.OUT}/${name}.png`,clip:{x:0,y:opt.clipTop,width:v.w,height:v.h-opt.clipTop}}); console.log('  shot',name); } else await L.shot(page,name); await ctx.close(); }catch(e){console.log('ERR',name,e.message.slice(0,150));} } }));
 await L.done(); })();
