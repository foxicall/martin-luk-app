// Unattended public-market work. This process never receives browser/user state.
import {readFile,writeFile,mkdir,readdir,rm} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {resolve} from 'node:path';
import {spawnSync} from 'node:child_process';
import {readUniverse} from '../volume/universe.js';
import {fetchVBAssessment} from '../volume/volume-data.js';
import {fetchVBScope,vbScopeFor} from '../volume/volume-scope.js';
import {VB_VERSION,evaluateVolumeBreakout} from '../volume/volume-breakout.js';
const hash=s=>createHash('sha256').update(s).digest('hex');
const wait=ms=>new Promise(r=>setTimeout(r,ms));
const iso=()=>new Date().toISOString();
const safeListing=r=>r&&['US','TW'].includes(r.market)&&typeof r.symbol==='string'&&(r.market==='TW'?/^\d{4,6}\.(TW|TWO)$/:/^[A-Z][A-Z0-9-]{0,18}$/).test(r.symbol);
export function reconcileUniverse(directories,previous=[]){
 const rows=[],notices=[];
 for(const market of ['TW','US']){
  const d=directories.find(d=>d.market===market),current=(d?.rows||[]).filter(safeListing),old=previous.filter(r=>r.market===market&&safeListing(r));
  rows.push(...new Map([...(d?.complete?[]:old),...current].map(r=>[r.symbol,{symbol:r.symbol,market:r.market,name:r.name||r.symbol}])).values());
  if(!d?.complete)notices.push(`${market} 最新名錄缺漏；合併已保存名單，完整性待核對`);
 }
 return {rows,notice:notices.join('；'),complete:directories.length===2&&directories.every(d=>d.complete)};
}
export async function scanVolumeQueue(queue,{evaluate=fetchVBAssessment,onCheckpoint=async()=>{},seed=[],batchSize=4,pauseMs=150,checkpointEvery=60000,clock=Date.now,stop=()=>false,scope=null}={}){
 const targets=new Set(queue.map(r=>r.symbol));
 const results=new Map(seed.filter(r=>targets.has(r.symbol)&&r.strategyVersion===VB_VERSION&&!r.error).map(r=>[r.symbol,r]));
 const remaining=queue.filter(r=>!results.has(r.symbol));let last=0,failedBatches=0;
 for(let i=0;i<remaining.length;i+=batchSize){
  if(stop())return {results:[...results.values()],status:'interrupted'};
  const batch=remaining.slice(i,i+batchSize);
  await Promise.all(batch.map(async r=>{
   let value;for(let attempt=0;attempt<2;attempt++){
    try{value={...await evaluate(r.symbol,r.market,vbScopeFor(scope,r.symbol,r.market)),name:r.name};if(value.strategyVersion!==VB_VERSION||value.symbol!==r.symbol||value.market!==r.market)throw Error('策略或股票識別不符');break;}
    catch{value={...evaluateVolumeBreakout([],{symbol:r.symbol,market:r.market,fetchedAt:clock()/1000}),name:r.name,error:'行情來源暫時無法取得'};if(!attempt&&pauseMs)await wait(pauseMs*4);}
   }
   results.set(r.symbol,value);
  }));
  failedBatches=batch.every(r=>results.get(r.symbol).error)?failedBatches+1:0;
  const complete=i+batchSize>=remaining.length,paused=failedBatches>=3;
  if(clock()-last>=checkpointEvery||complete||paused){await onCheckpoint([...results.values()],complete?'completed':paused?'paused':'running');last=clock();}
  if(paused&&!complete)return {results:[...results.values()],status:'paused'};
  if(!complete&&pauseMs)await wait(pauseMs);
 }
 return {results:[...results.values()],status:'completed'};
}
export async function writeVolumeSnapshot(directory,manifest,results){
 const pages=[];const runDir=`volume-runs/${manifest.runId}`;await mkdir(resolve(directory,runDir),{recursive:true});
 for(let i=0;i<results.length;i+=250){
  const data=JSON.stringify({version:2,strategyVersion:VB_VERSION,runId:manifest.runId,results:results.slice(i,i+250)}),digest=hash(data),path=`${runDir}/page-${i/250}-${digest.slice(0,20)}.json`;
  await writeFile(resolve(directory,path),data);pages.push({path,sha256:digest,count:Math.min(250,results.length-i)});
 }
 const failed=results.filter(r=>r.error).length,missing=results.filter(r=>!r.error&&r.status==='insufficient_data').length;
 const next={...manifest,version:2,strategyVersion:VB_VERSION,updatedAt:iso(),processed:results.length,failed,missing,valid:results.length-failed-missing,breakouts:results.filter(r=>!r.error&&r.technicalBreakout).length,remaining:Math.max(0,manifest.total-results.length),pages};
 await writeFile(resolve(directory,'volume-latest.json'),JSON.stringify(next));return next;
}
function git(directory,args){const r=spawnSync('git',['-C',directory,...args],{encoding:'utf8',maxBuffer:2e6,timeout:60000});if(r.status!==0)throw Error(`Git ${args[0]} failed (${r.status}); checkpoint preserved locally`);return r.stdout.trim();}
async function previousRows(directory,previous){
 const rows=[];for(const page of previous?.pages||[]){
  if(!/^(volume-runs|runs)\/[\d-]+\/page-\d+-[a-f0-9]{20}\.json$/.test(page.path))throw Error('Invalid checkpoint path');
  const bytes=await readFile(resolve(directory,page.path),'utf8');if(hash(bytes)!==page.sha256)throw Error('Checkpoint checksum mismatch');rows.push(...JSON.parse(bytes).results);
 }return rows;
}
async function main(){
 const directory=process.env.SCAN_DATA_DIR;if(!directory)throw Error('SCAN_DATA_DIR required');
 if((await readFile(resolve(directory,'.momentum-generated'),'utf8')).trim()!=='public-market-data-only')throw Error('Not the dedicated public data worktree');
 let previous=null,legacy=null;try{previous=JSON.parse(await readFile(resolve(directory,'volume-latest.json'),'utf8'));}catch{}try{legacy=JSON.parse(await readFile(resolve(directory,'latest.json'),'utf8'));}catch{}
 const oldRows=await previousRows(directory,previous||legacy); // Legacy rows supply LISTING IDENTITIES only, never evaluations.
 let known;try{known=JSON.parse(await readFile(resolve(directory,'volume-universe.json'),'utf8')).rows;}catch{known=oldRows;}
 let stopping=false;const deadline=Date.now()+160*60000;process.on('SIGTERM',()=>{stopping=true;});process.on('SIGINT',()=>{stopping=true;});
 const runId=`${process.env.GITHUB_RUN_ID||Date.now()}-${process.env.GITHUB_RUN_ATTEMPT||1}`;
 if(!/^\d+-\d+$/.test(runId))throw Error('Invalid run ID');
 const manifest={version:2,strategyVersion:VB_VERSION,runId,status:'loading',startedAt:iso(),total:0,sourceCommit:process.env.GITHUB_SHA||null,runUrl:`https://github.com/foxicall/martin-luk-app/actions/runs/${process.env.GITHUB_RUN_ID||''}`,schedule:'週一至五 UTC 07:17、22:17（台北 15:17、翌日 06:17）；排程可能延後',directories:[]};
 const publish=async()=>{
  git(directory,['add','.momentum-generated','volume-latest.json','volume-runs']);
  try{await readFile(resolve(directory,'volume-universe.json'));git(directory,['add','volume-universe.json']);}catch{}
  if(!git(directory,['diff','--cached','--name-only']))return;
  git(directory,['commit','-m',`Volume Breakout public scan ${runId}`]);
  // Linear push only. Never rewrite other jobs' commits or any source branch.
  for(let attempt=0;attempt<2;attempt++){try{git(directory,['push','origin','HEAD:refs/heads/momentum-scan-data']);return;}catch(e){const remote=git(directory,['ls-remote','origin','refs/heads/momentum-scan-data']).split(/\s+/)[0];if(remote===git(directory,['rev-parse','HEAD']))return;if(attempt)throw e;await wait(2000);}}
 };
 let results=[];
 try{
  // Keep this and the previous run so an app loading a manifest can finish its pages.
  for(const name of await readdir(resolve(directory,'volume-runs')).catch(()=>[]))if(/^\d+-\d+$/.test(name)&&name!==previous?.runId&&name!==runId)await rm(resolve(directory,'volume-runs',name),{recursive:true,force:true});
  await writeVolumeSnapshot(directory,manifest,results);await publish();
  const directories=await Promise.all(['TW','US'].map(async market=>{try{return await readUniverse(market);}catch{return {market,complete:false,rows:[],sources:[]};}}));
  const universe=reconcileUniverse(directories,known);if(!universe.rows.length)throw Error('All market directories unavailable');
  await writeFile(resolve(directory,'volume-universe.json'),JSON.stringify(universe));
  Object.assign(manifest,{total:universe.rows.length,universeComplete:universe.complete,notice:universe.notice,directories:directories.map(({rows,...d})=>d),fingerprint:hash(JSON.stringify(universe.rows.map(r=>r.symbol))),status:'running'});
  if(previous?.strategyVersion===VB_VERSION&&previous.fingerprint===manifest.fingerprint&&previous.sourceCommit===manifest.sourceCommit&&previous.startedAt.slice(0,10)===manifest.startedAt.slice(0,10)&&['paused','running','interrupted'].includes(previous.status))results=oldRows.filter(r=>!r.error);
  const scope=await fetchVBScope().catch(()=>null);
  await writeVolumeSnapshot(directory,manifest,results);await publish();
  const outcome=await scanVolumeQueue(universe.rows,{seed:results,scope,stop:()=>stopping||Date.now()>deadline,onCheckpoint:async(rows,status)=>{results=rows;manifest.status=status;const m=await writeVolumeSnapshot(directory,manifest,results);await publish();console.log(JSON.stringify({status,processed:m.processed,total:m.total,valid:m.valid,missing:m.missing,failed:m.failed,updatedAt:m.updatedAt}));}});
  results=outcome.results;manifest.status=outcome.status;manifest.completedAt=outcome.status==='completed'?iso():null;
  await writeVolumeSnapshot(directory,manifest,results);await publish();if(outcome.status!=='completed')process.exitCode=1;
 }catch(e){manifest.status='failed';manifest.error='雲端本輪中斷，已保留成功結果；請查看執行紀錄';try{await writeVolumeSnapshot(directory,manifest,results);await publish();}catch{}throw e;}
}
if(process.argv[1]&&resolve(process.argv[1])===resolve(new URL(import.meta.url).pathname))await main();
