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
