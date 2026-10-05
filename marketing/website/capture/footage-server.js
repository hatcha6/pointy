// Mimics tools/camera-rig's fake DVR: /<variant>/snapshot.jpg?i=N -> CCTV frame N.
const http=require('http'),fs=require('fs'),path=require('path');
const S=path.join(process.env.CAPTURE_WORK||path.join(__dirname,'.work'),'footage');
module.exports=()=>new Promise(res=>{
  // read on first use, so clips that need no footage don't need footage.py run first
  const frames=fs.readdirSync(S).filter(f=>f.startsWith('counter-')).sort().map(f=>fs.readFileSync(`${S}/${f}`)); const srv=http.createServer((q,r)=>{
  r.setHeader('access-control-allow-origin','*'); if(q.method==='OPTIONS'){r.end();return;}
  const i=+(new URL(q.url,'http://x').searchParams.get('i')||0);
  if(q.url.startsWith('/health')){r.end('{}');return;}
  r.writeHead(200,{'content-type':'image/jpeg'}); r.end(frames[i%frames.length]); }).listen(0,'127.0.0.1',()=>res(`http://127.0.0.1:${srv.address().port}`)); });
