import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createHash} from 'node:crypto';
import {scanVolumeQueue,reconcileUniverse,writeVolumeSnapshot} from './volume-runner.mjs';
import {VB_VERSION,evaluateVolumeBreakout} from '../volume/volume-breakout.js';
const quote=(symbol,market)=>evaluateVolumeBreakout([],{symbol,market});
test('all 7,597 targets execute independent of browser pagination',async()=>{
 const rows=Array.from({length:7597},(_,i)=>({symbol:'S'+i,market:'US'})),seen=new Set();
 const r=await scanVolumeQueue(rows,{pauseMs:0,evaluate:async(s,m)=>{assert(!seen.has(s));seen.add(s);return quote(s,m);}});
 assert.equal(r.status,'completed');assert.equal(r.results.length,7597);assert.equal(seen.size,7597);
});
test('partial exchange directory retains saved missing market, complete directory replaces it',()=>{
 const previous=[{symbol:'2330.TW',market:'TW'},{symbol:'6488.TWO',market:'TW'},{symbol:'OLD',market:'US'}];
 const r=reconcileUniverse([{market:'TW',complete:false,rows:[previous[0]]},{market:'US',complete:true,rows:[{symbol:'AAPL',market:'US'}]}],previous);
 assert.deepEqual(r.rows.map(r=>r.symbol),['2330.TW','6488.TWO','AAPL']);assert.equal(r.complete,false);assert.match(r.notice,/TW/);
});
test('failures pause, successes resume, failed entries retry and old strategy never seeds',async()=>{
 const rows=Array.from({length:30},(_,i)=>({symbol:'S'+i,market:'US'}));
 const failed=await scanVolumeQueue(rows,{pauseMs:0,evaluate:async()=>{throw Error('outage');}});
 assert.equal(failed.status,'paused');assert.equal(failed.results.length,12);
 const restored=await scanVolumeQueue(rows,{pauseMs:0,seed:[...failed.results,{...quote('S29','US'),strategyVersion:'1.3.0'}],evaluate:async(s,m)=>quote(s,m)});
 assert.equal(restored.results.length,30);assert(restored.results.every(r=>r.strategyVersion===VB_VERSION&&!r.error));
});
test('manifest pages are coherent, checksummed and distinguish missing data from failed requests',async()=>{
 const dir=await mkdtemp(join(tmpdir(),'volume-cloud-'));try{
 const rows=Array.from({length:501},(_,i)=>({...quote('S'+i,'US'),...(i===0?{error:'unavailable'}:{})}));
 const m=await writeVolumeSnapshot(dir,{runId:'123-1',total:7000,status:'running'},rows);
 assert.equal(m.failed,1);assert.equal(m.missing,500);assert.equal(m.valid,0);assert.equal(m.remaining,6499);assert.equal(m.pages.length,3);
 for(const p of m.pages){const bytes=await readFile(join(dir,p.path),'utf8');assert.equal(createHash('sha256').update(bytes).digest('hex'),p.sha256);assert.equal(JSON.parse(bytes).results.length,p.count);}
 assert.deepEqual(JSON.parse(await readFile(join(dir,'volume-latest.json'),'utf8')),m);
 }finally{await rm(dir,{recursive:true,force:true});}
});
test('successful but incomplete bodies receive one forced second pass; short IPOs do not',async()=>{
 const calls=new Map(),stages=[],queue=['AAPL','IPO','STILL'].map(symbol=>({symbol,market:'US'}));
 const r=await scanVolumeQueue(queue,{pauseMs:0,onCheckpoint:async(rows,status,meta)=>stages.push({status,...meta}),evaluate:async(s,m,scope,opts)=>{
  calls.set(s,(calls.get(s)||0)+1);const row={...quote(s,m),availableBars:s==='IPO'?15:128,missing:s==='IPO'?['需 30 根基底']:['還原 OHLC 或 adjclose 缺漏']};
  if(s==='AAPL'&&calls.get(s)===2){assert.equal(opts.forceHistory,true);return {...row,status:'consolidation',missing:[]};}return row;
 }});
 assert.equal(r.status,'completed');assert.equal(calls.get('AAPL'),2);assert.equal(calls.get('IPO'),1);assert.equal(calls.get('STILL'),2);
 assert.equal(r.results[0].status,'consolidation');assert.equal(r.results[0].historyRecovery.recovered,true);assert.equal(r.results[2].status,'insufficient_data');
 assert.equal(stages.at(-1).recovered,1);assert.equal(stages.at(-1).status,'completed');assert(stages.slice(0,-1).every(s=>s.status!=='completed'));
});
test('repair failure retains acquired public data and cancellation preserves a resumable checkpoint',async()=>{
 const seed=[{...quote('AAPL','US'),availableBars:128,quote:{price:100},missing:['還原 OHLC 或 adjclose 缺漏']}],queue=[{symbol:'AAPL',market:'US'}];
 const r=await scanVolumeQueue(queue,{seed,pauseMs:0,evaluate:async()=>{throw Error('outage');}});
 assert.equal(r.results[0].quote.price,100);assert.equal(r.results[0].historyRecovery.repairPass,1);assert.equal(r.results[0].error,undefined);
 const stopped=await scanVolumeQueue(queue,{seed,pauseMs:0,stop:()=>true,evaluate:async()=>{throw Error('not called');}});assert.equal(stopped.status,'interrupted');assert.equal(stopped.results.length,1);
});
