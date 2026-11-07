'use strict';
const http = require('http');
const { spawn } = require('child_process');
const crypto = require('crypto');
const secret = process.env.VM_API_TOKEN || '';
if (secret.length < 32) throw new Error('Missing VM_API_TOKEN');
http.createServer((req, res) => {
  const given = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  const a = Buffer.from(given), b = Buffer.from(secret);
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) { res.writeHead(401); return res.end('Unauthorized'); }
  if (req.method !== 'GET' || !['/api/linux/screenshot', '/api/v1/screenshot'].includes(req.url.split('?')[0])) { res.writeHead(404); return res.end(); }
  const args = ['-i', process.env.AIOS_SSH_KEY, '-o','StrictHostKeyChecking=accept-new','-o',`UserKnownHostsFile=${process.env.AIOS_KNOWN_HOSTS}`,'-o','BatchMode=yes','-o','ConnectTimeout=10','-p','22222','aios@127.0.0.1', 'DISPLAY=:99 scrot -o /tmp/aios-screenshot.png && cat /tmp/aios-screenshot.png'];
  const child=spawn('ssh',args,{stdio:['ignore','pipe','pipe']}); let chunks=[], size=0;
  const timer=setTimeout(()=>child.kill(),30000);
  child.stdout.on('data',d=>{size+=d.length;if(size>15*1024*1024)child.kill();else chunks.push(d)});
  child.on('error',()=>{clearTimeout(timer); if (!res.headersSent) {res.writeHead(502);res.end('SSH failure');}});
  child.on('close',code=>{clearTimeout(timer);if(res.writableEnded)return;if(code!==0){res.writeHead(502);return res.end('Screenshot unavailable');}res.writeHead(200,{'Content-Type':'image/png','Cache-Control':'no-store','X-Linux-Daemon':'1'});res.end(Buffer.concat(chunks));});
}).listen(3001,'127.0.0.1',()=>console.log('Screenshot bridge ready'));
