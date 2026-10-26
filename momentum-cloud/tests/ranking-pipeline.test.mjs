import test from 'node:test';import assert from 'node:assert/strict';
import {mkdtemp,readFile,rm} from 'node:fs/promises';import {tmpdir} from 'node:os';import {join} from 'node:path';
import {compactResult,writeSnapshot} from '../cloud/runner.mjs';
import {STRATEGY_VERSION,rankResults,snapshotCoverage,rankReadiness} from '../src/strategy.js';
const day=Date.parse('2026-10-23T00:00:00Z')/1000;
function raw(symbol,market='US',step=.015){return {symbol,market,exchange:market==='US'?'NMS':'TAI',currency:market==='US'?'USD':'TWD',marketCap:2e9,source:'synthetic ranking pipeline fixture',daily:Array.from({length:70},(_,i)=>{const close=10*(1+step)**i;return {time:day-(69-i)*86400,open:close,close,low:close*.97,high:close*1.03,volume:2e6};}),benchmark:[]};}
function rows(){return Array.from({length:100},(_,i)=>compactResult(raw('S'+i,'US',.001+i*.0001),{symbol:'S'+i,market:'US'}));}
const manifest={runId:'123456-1',status:'completed',total:100,processed:100,directories:[{market:'US',complete:true,total:100}]};
test('cloud compact rows retain strategy version, 20/60 returns and hard checks, not entry evidence',()=>{
 const r=compactResult(raw('S1'),{name:'example'});assert.equal(r.strategyVersion,STRATEGY_VERSION);assert.equal(r.returnMethod,'close-return-20-60-v1');assert.ok(Math.abs(r.metrics.rsMonth-100*((1.015)**20-1))<1e-9);assert.ok(Math.abs(r.metrics.rsQuarter-100*((1.015)**60-1))<1e-9);assert.ok(r.checks.some(c=>c.name==='Footprint／Delta'&&c.state==='missing'));assert.equal(r.freshIntraday,false);assert.equal(r.setup,null);
});
test('content-addressed cloud serialization round trip supplies the full denominator and preserves ranking on reload',async()=>{
 const dir=await mkdtemp(join(tmpdir(),'rs-pipeline-'));try{const status=await writeSnapshot(dir,manifest,rows());const page=JSON.parse(await readFile(join(dir,status.pages[0].path)));assert.ok((await readFile(join(dir,status.pages[0].path))).length<2e6);const coverage=snapshotCoverage(status);const result=rankResults(page.results,coverage);assert.equal(result.filter(r=>r.scanners.includes('leader')).length,5);assert.ok(result.every(r=>r.rankSample===100&&Number.isFinite(r.metrics.rank20)&&Number.isFinite(r.metrics.rank60)));assert.ok(result.every(r=>r.status!=='triggered'));assert.equal(status.ranking.US.ready,true);assert.equal(status.strategyVersion,STRATEGY_VERSION);
 const again=rankResults(JSON.parse(JSON.stringify(result)),snapshotCoverage(status));assert.deepEqual(again.map(r=>r.metrics.percentile),result.map(r=>r.metrics.percentile));assert.equal(rankReadiness(result,coverage.US).ready,true);
 }finally{await rm(dir,{recursive:true,force:true});}
});
test('rank calculations do not corrupt another snapshot or mutate a caller’s metrics',()=>{
 const original=rows();const first=rankResults(original,snapshotCoverage(manifest));const top=first.find(r=>r.symbol==='S99');assert.equal(top.metrics.rank20,1);const missing=rankResults(first,{});assert.equal(missing[0].metrics.percentile,null);assert.equal(top.metrics.rank20,1);assert.equal(original[0].metrics.percentile,null);
});
test('legacy, missing history, mixed date and incomplete directory remain visibly distinct and cannot rank',()=>{
 const coverage=snapshotCoverage(manifest);for(const change of ['legacy','missing','date','duplicate','partial']){const r=rows();let c=coverage;
 if(change==='legacy')delete r[0].strategyVersion;if(change==='missing')r[0].metrics.rsQuarter=null;if(change==='date')r[0].metrics.asOf='2026-10-22';if(change==='duplicate')r[0].symbol=r[1].symbol;if(change==='partial')c=snapshotCoverage({...manifest,status:'running'});
 assert.ok(rankResults(r,c).every(r=>r.rankSample===0));assert.equal(rankReadiness(r,c.US).ready,false);}
 assert.deepEqual(snapshotCoverage({...manifest,directories:[{market:'US',complete:false,total:100}]}),{});assert.deepEqual(snapshotCoverage({...manifest,total:101}),{});assert.equal(rankReadiness(rows().map(r=>({...r,strategyVersion:'legacy'})),coverage.US).legacy,100);
});
test('new listings with fewer than 61 bars stay missing instead of changing the market denominator',()=>{
 const data=raw('NEW');data.daily=data.daily.slice(-50);const r=compactResult(data,{symbol:'NEW'});assert.equal(r.metrics.rsQuarter,null);assert.ok(Number.isFinite(r.metrics.rsMonth));const result=rankResults([r],{US:{total:1,complete:true,scope:'full-market'}});assert.equal(result[0].rankSample,0);assert.match(result[0].rankReason,/20／60/);
});
test('Taiwan and US directory totals are verified independently',()=>{
 const tw=rows().map(r=>({...r,market:'TW',symbol:r.symbol+'.TW'})),us=rows();const m={...manifest,total:200,processed:200,directories:[{market:'TW',total:100,complete:true},{market:'US',total:100,complete:true}]};const ranked=rankResults([...tw,...us],snapshotCoverage(m));assert.equal(ranked.filter(r=>r.scanners.includes('leader')).length,10);assert.ok(ranked.every(r=>r.rankSample===100));
});
test('partial 20/60 reference ranks are labeled with unchanged full denominator and never qualify a scanner',()=>{
 const input=rows().slice(0,80),c=snapshotCoverage(manifest),ranked=rankResults(input,c);assert.ok(ranked.every(r=>r.rankSample===0&&r.metrics.percentile===null));assert.ok(ranked.every(r=>r.rsReference.sample===80&&r.rsReference.total===100));assert.ok(ranked.every(r=>!r.scanners.includes('leader')&&!r.scanners.includes('potent')&&r.status!=='triggered'));assert.equal(ranked.find(r=>r.symbol==='S79').rsReference.percentile,98.75);
 const mixed=[...rows().slice(0,10),...rows().slice(10,15).map(r=>({...r,metrics:{...r.metrics,asOf:'2026-10-22'}}))];const r=rankResults(mixed,c);assert.equal(r.find(r=>r.symbol==='S0').rsReference.sample,10);assert.equal(r.find(r=>r.symbol==='S10').rsReference.sample,5);
 const old=rankResults(input.map(r=>({...r,strategyVersion:'legacy'})),c);assert.ok(old.every(r=>!r.rsReference));
});
