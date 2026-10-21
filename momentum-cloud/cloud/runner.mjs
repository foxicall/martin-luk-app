import {readFile,writeFile,mkdir,readdir,rm} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {resolve} from 'node:path';
import {spawnSync} from 'node:child_process';
import {loadUniverse} from '../src/universe.js';
import {scanMarket} from '../src/provider.js';
import {analyze} from '../src/strategy.js';
const hash=value=>createHash('sha256').update(value).digest('hex');
const iso=()=>new Date().toISOString();
const delay=ms=>new Promise(r=>setTimeout(r,ms));
export function compactResult(raw,listing){const r=analyze({...raw,name:listing.name||raw.name});return {symbol:r.symbol,name:r.name,market:r.market,source:r.source,sector:listing.sector||r.sector,status:r.status,metrics:r.metrics,missing:r.missing,scanners:r.scanners,checks:[],bars:[],setups:[],setup:null,largeLiquid:r.largeLiquid||false,freshIntraday:false,dailyOnly:true,evaluatedAt:raw.evaluatedAt||Date.now()/1000,raw:{error:raw.error||null,notes:raw.notes||[],quoteTime:raw.quoteTime||null}};}
export async function scanQueue(queue,{fetcher=scanMarket,onCheckpoint=async()=>{},batchSize=8,pauseMs=800,checkpointEvery=60000,clock=Date.now,stop=()=>false,seed=[]}={}){
 const results=new Map(seed.map(r=>[r.symbol,r]));let last=0,consecutiveFailures=0;
 const remaining=queue.filter(r=>!results.has(r.symbol));
 for(let offset=0;offset<remaining.length;){if(stop())return {results:[...results.values()],status:'interrupted'};const market=remaining[offset].market,batch=[];while(offset<remaining.length&&batch.length<batchSize&&remaining[offset].market===market)batch.push(remaining[offset++]);
  let pending=batch;for(let attempt=0;attempt<3&&pending.length;attempt++){if(attempt)await delay(pauseMs*(attempt+1));let payload;try{payload=await fetcher(pending.map(r=>r.symbol),market,{dailyOnly:true});}catch(e){payload={results:pending.map(r=>({...r,error:e.message,source:'Yahoo Finance'}))};}
   for(const listing of pending){const raw=payload.results?.find(r=>r.symbol===listing.symbol)||{...listing,error:'來源未回傳此代碼',source:'Yahoo Finance'};results.set(listing.symbol,compactResult(raw,listing));}pending=pending.filter(r=>results.get(r.symbol).raw.error);
  }
  const failed=batch.every(r=>results.get(r.symbol).raw.error);consecutiveFailures=failed?consecutiveFailures+1:0;
  if(clock()-last>=checkpointEvery||offset===remaining.length||consecutiveFailures>=3){await onCheckpoint([...results.values()],offset===remaining.length?'completed':consecutiveFailures>=3?'paused':'running');last=clock();}
  if(consecutiveFailures>=3)return {results:[...results.values()],status:'paused'};
  if(offset<remaining.length)await delay(pauseMs);
 }
 return {results:[...results.values()],status:'completed'};
}
export async function writeSnapshot(directory,manifest,results){
 const pages=[];for(let i=0;i<results.length;i+=250){const payload=JSON.stringify({runId:manifest.runId,results:results.slice(i,i+250)}),digest=hash(payload),path=`runs/${manifest.runId}/page-${i/250}-${digest.slice(0,20)}.json`;await mkdir(resolve(directory,`runs/${manifest.runId}`),{recursive:true});await writeFile(resolve(directory,path),payload);pages.push({path,sha256:digest,count:Math.min(250,results.length-i)});}
 const failed=results.filter(r=>r.raw.error).length,missing=results.filter(r=>!r.raw.error&&r.missing.length).length;
 const next={...manifest,updatedAt:iso(),processed:results.length,failed,missing,valid:results.length-failed-missing,remaining:Math.max(0,(manifest.total||0)-results.length),pages};
 await writeFile(resolve(directory,'latest.json'),JSON.stringify(next));return next;
}
function git(directory,args){const r=spawnSync('git',['-C',directory,...args],{encoding:'utf8',maxBuffer:1e6});if(r.status!==0)throw new Error(`Git ${args[0]} failed (${r.status}); inspect the Actions step.`);return r.stdout.trim();}
async function main(){
 const directory=process.env.SCAN_DATA_DIR;if(!directory)throw new Error('SCAN_DATA_DIR is required');await mkdir(directory,{recursive:true});let lastSHA='';try{lastSHA=git(directory,['rev-parse','HEAD']);}catch{}
 // All commits replace ONLY the dedicated generated-data branch with an exact lease.
 const publish=async()=>{git(directory,['add','.']);if(!git(directory,['status','--porcelain']))return;const args=lastSHA?['commit','--amend','--no-edit']:['commit','-m','Generated public market scan data'];git(directory,args);git(directory,['push','origin','HEAD:refs/heads/momentum-scan-data',`--force-with-lease=refs/heads/momentum-scan-data:${lastSHA}`]);lastSHA=git(directory,['rev-parse','HEAD']);};
 let previous;try{previous=JSON.parse(await readFile(resolve(directory,'latest.json'),'utf8'));}catch{}
 const runId=String(process.env.GITHUB_RUN_ID||Date.now())+'-'+String(process.env.GITHUB_RUN_ATTEMPT||1);const manifest={version:1,runId,status:'loading',startedAt:iso(),updatedAt:iso(),total:0,processed:0,pages:[],sourceCommit:process.env.GITHUB_SHA||null,runUrl:`https://github.com/foxicall/martin-luk-app/actions/runs/${process.env.GITHUB_RUN_ID||''}`,schedule:'工作日 07:17、22:17 UTC（台北 15:17、翌日 06:17）；GitHub 排程可能延後',scope:'TWSE/TPEx ordinary stocks and all NasdaqTrader-listed US equity incl. ADR/ADS; no OTC/ETF',directories:[]};
 // Retain the immediately previous run for recovery; older generated runs are disposable.
 try{for(const name of await readdir(resolve(directory,'runs'))){if(name!==previous?.runId)await rm(resolve(directory,'runs',name),{recursive:true,force:true});}}catch{}
 let results=[],stopping=false;process.on('SIGTERM',()=>{stopping=true;});process.on('SIGINT',()=>{stopping=true;});
 try{
  await writeSnapshot(directory,manifest,results);await publish();
  const directories=[];for(const market of ['TW','US']){const d=await loadUniverse(market);if(!d.complete)throw new Error(d.sources.filter(s=>!s.ok).map(s=>s.name+': '+s.error).join('; '));directories.push(d);}
  const queue=directories.flatMap(d=>d.rows),fingerprint=hash(JSON.stringify(queue.map(r=>r.symbol)));
  manifest.total=queue.length;manifest.directories=directories.map(({rows,...d})=>d);manifest.fingerprint=fingerprint;manifest.status='running';
  // Resume a same-day interrupted run only when code and the entire universe match.
  if(previous&&['running','paused','interrupted'].includes(previous.status)&&previous.fingerprint===fingerprint&&previous.sourceCommit===manifest.sourceCommit&&previous.startedAt?.slice(0,10)===manifest.startedAt.slice(0,10)){
   for(const page of previous.pages||[]){const bytes=await readFile(resolve(directory,page.path),'utf8');if(hash(bytes)!==page.sha256)throw new Error('Checkpoint checksum mismatch');results.push(...JSON.parse(bytes).results);}manifest.resumedFrom=previous.runId;
  }
  await writeSnapshot(directory,manifest,results);await publish();
  const outcome=await scanQueue(queue,{seed:results,stop:()=>stopping,onCheckpoint:async(rows,status)=>{results=rows;manifest.status=status;const checkpoint=await writeSnapshot(directory,manifest,results);await publish();console.log(JSON.stringify({status,processed:checkpoint.processed,total:checkpoint.total,failed:checkpoint.failed,missing:checkpoint.missing,updatedAt:checkpoint.updatedAt}));}});
  results=outcome.results;manifest.status=outcome.status;manifest.completedAt=outcome.status==='completed'?iso():null;await writeSnapshot(directory,manifest,results);await publish();
  if(outcome.status!=='completed')process.exitCode=1;
 }catch(e){manifest.status='failed';manifest.error=e.message;try{await writeSnapshot(directory,manifest,results);await publish();}catch{}throw e;}
}
if(process.argv[1]&&resolve(process.argv[1])===resolve(new URL(import.meta.url).pathname))await main();
