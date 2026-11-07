#!/usr/bin/env node
/**
 * deploy-cloudflare-worker.cjs — déploie cloudflare-worker/worker.js sous le
 * Worker « ai-os » via l'API Cloudflare.
 *
 * Variables requises : CLOUDFLARE_ID, CLOUDFLARE_TOKEN.
 * Variables optionnelles : PASS, VM_API_TOKEN — si fournies, elles sont posées
 * (ou remplacées) comme secrets du Worker. Sinon, tous les secrets existants
 * sont conservés (keep_bindings).
 *
 * Option --prune-unused : supprime les secrets du Worker que le code ne lit
 * plus (liste explicite ci-dessous).
 *
 * Ne JAMAIS exécuter avec un scriptName différent de « ai-os ».
 */
'use strict';
const https = require('https');
const fs = require('fs');
const path = require('path');

const accountId = process.env.CLOUDFLARE_ID;
const apiToken = process.env.CLOUDFLARE_TOKEN;
const scriptName = 'ai-os';
const PRUNE_UNUSED = ['GH_TOKEN', 'CLOUDFLARE_TOKEN', 'CLOUDFLARE_ID'];

if (!accountId) { console.error('CLOUDFLARE_ID manquant.'); process.exit(1); }
if (!apiToken) { console.error('CLOUDFLARE_TOKEN manquant.'); process.exit(1); }

const workerFilePath = path.join(__dirname, '..', 'cloudflare-worker', 'worker.js');
if (!fs.existsSync(workerFilePath)) { console.error(`Fichier introuvable : ${workerFilePath}`); process.exit(1); }
const workerContent = fs.readFileSync(workerFilePath, 'utf8');

function apiCall(method, apiPath, bodyBuffer, contentType) {
  return new Promise((resolve, reject) => {
    const req = https.request({
      hostname: 'api.cloudflare.com',
      path: `/client/v4/accounts/${accountId}${apiPath}`,
      method,
      headers: {
        Authorization: 'Bearer ' + apiToken,
        ...(contentType ? { 'Content-Type': contentType } : {}),
        ...(bodyBuffer ? { 'Content-Length': bodyBuffer.length } : {}),
      },
    }, (res) => {
      let data = '';
      res.on('data', (c) => (data += c));
      res.on('end', () => {
        let parsed;
        try { parsed = JSON.parse(data); } catch (e) { parsed = { raw: data }; }
        resolve({ status: res.statusCode, body: parsed });
      });
    });
    req.on('error', reject);
    if (bodyBuffer) req.write(bodyBuffer);
    req.end();
  });
}

async function deploy() {
  console.log(`Déploiement du Worker "${scriptName}"...`);

  // Secrets à poser uniquement si fournis ; les autres sont conservés.
  const bindings = [];
  for (const name of ['PASS', 'VM_API_TOKEN']) {
    const value = process.env[name];
    if (value) {
      bindings.push({ type: 'secret_text', name, text: value });
      console.log(`  secret ${name} : remplacé.`);
    } else {
      console.log(`  secret ${name} : conservé (valeur existante).`);
    }
  }

  const metadata = {
    main_module: 'worker.js',
    keep_bindings: ['secret_text'],
    bindings,
  };

  const boundary = '----CFWorkerBoundary' + Date.now();
  const bodyParts = [
    `--${boundary}\r\nContent-Disposition: form-data; name="metadata"; filename="metadata.json"\r\nContent-Type: application/json\r\n\r\n${JSON.stringify(metadata)}\r\n`,
    `--${boundary}\r\nContent-Disposition: form-data; name="worker.js"; filename="worker.js"\r\nContent-Type: application/javascript+module\r\n\r\n${workerContent}\r\n`,
    `--${boundary}--\r\n`,
  ];
  const bodyBuffer = Buffer.from(bodyParts.join(''));
  const res = await apiCall('PUT', `/workers/scripts/${scriptName}`, bodyBuffer, 'multipart/form-data; boundary=' + boundary);
  if (res.status !== 200 || !res.body?.success) {
    console.error('Échec du déploiement :', JSON.stringify(res.body));
    process.exit(1);
  }
  console.log('Script déployé.');

  if (process.argv.includes('--prune-unused')) {
    for (const name of PRUNE_UNUSED) {
      const r = await apiCall('DELETE', `/workers/scripts/${scriptName}/secrets/${name}`);
      console.log(`  secret inutilisé ${name} : ${r.status === 200 ? 'supprimé' : 'absent/erreur ' + r.status}`);
    }
  }

  const sub = await apiCall('GET', `/workers/subdomain`);
  const subdomain = sub.body?.result?.subdomain;
  console.log(`Worker disponible : https://${scriptName}.${subdomain || '<sous-domaine>'}.workers.dev`);
}

deploy().catch((e) => { console.error('Erreur :', e.message); process.exit(1); });
