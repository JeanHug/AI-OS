'use strict';
const {execFileSync}=require('child_process');
const repo=process.env.GITHUB_REPOSITORY; const token=process.env.GH_TOKEN;
const origin=process.env.AIOS_TUNNEL;
if(!repo || !token || !/^https:\/\/[a-z0-9-]+\.trycloudflare\.com$/.test(origin||''))throw Error('Missing publish settings');
async function api(path,init={}) {const r=await fetch(`https://api.github.com/repos/${repo}${path}`,{...init,headers:{Authorization:`Bearer ${token}`,Accept:'application/vnd.github+json','Content-Type':'application/json',...(init.headers||{})}});let j=await r.json().catch(()=>({}));if(!r.ok)throw Error(`GitHub HTTP ${r.status}: ${j.message||''}`);return j;}
(async()=>{try {
 let ref; try{ref=await api('/git/ref/heads/tunnel-url')}catch(e){if(!e.message.includes('404'))throw e;const m=await api('/git/ref/heads/main');await api('/git/refs',{method:'POST',body:JSON.stringify({ref:'refs/heads/tunnel-url',sha:m.object.sha})});}
 let sha; try{const old=await api('/contents/tunnels-linux.json?ref=tunnel-url');sha=old.sha}catch(e){if(!e.message.includes('404'))throw e;}
 let body={message:'Update temporary QEMU tunnel',branch:'tunnel-url',content:Buffer.from(JSON.stringify({name:'AI OS QEMU',primary:origin,cloudflare:origin,status:'online',updated_at:new Date().toISOString()})).toString('base64')};if(sha)body.sha=sha;
 await api('/contents/tunnels-linux.json',{method:'PUT',body:JSON.stringify(body)});console.log('Tunnel publié.');
}catch(e){console.error('Publication tunnel échouée:',e.message);process.exitCode=1}})();
