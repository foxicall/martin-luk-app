import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {vbDaily,vbQuote,vbHistoryQuality,vbLastCompleteAssessment} from '../volume/volume-data.js';
import {evaluateVolumeBreakout} from '../volume/volume-breakout.js';
import {summarizeDataQuality,confirmedHistory} from '../volume/data-quality.js';
import {scanVolumeQueue} from './volume-runner.mjs';

const now=Date.parse('2026-11-26T03:00:00Z')/1000;
const fixture=name=>JSON.parse(readFileSync(new URL('./fixtures/'+name+'.json',import.meta.url))).chart.result[0];
const rowFor=d=>{const symbol=d.meta.symbol,market='US',daily=vbDaily(d,market,now);return {...evaluateVolumeBreakout(daily.bars,{symbol,market,...daily,fetchedAt:now}),quote:vbQuote(d,symbol,market,now),dataQuality:vbHistoryQuality(d,market,now),lastCompleteAssessment:vbLastCompleteAssessment(daily,{symbol,market,fetchedAt:now})};};
test('captured A, AAPL and MSFT preserve previous complete analysis while latest close remains blocked',()=>{
 for(const name of ['A-6mo','AAPL-1y','MSFT-6mo']){const d=fixture(name),before=structuredClone(d),r=rowFor(d),h=confirmedHistory(r);
 assert.equal(r.dataQuality.code,'latest_session_pending');assert.equal(r.dataQuality.latestDate,'2026-11-25');assert.equal(h.date,'2026-11-24');assert.equal(h.bars,d.timestamp.length-1);assert.equal(r.status,'insufficient_data');assert.equal(r.technicalBreakout,false);assert.equal(r.eligible,false);assert.deepEqual(d,before);}
});
test('internal holes, invalid bounds, insufficient history and long gaps do not become a publishing delay',()=>{
 for(const mutate of [d=>{d.indicators.quote[0].close[10]=null;},d=>{d.indicators.quote[0].low[40]=999999;},d=>{d.timestamp[d.timestamp.length-2]-=20*86400;},d=>{d.indicators.quote[0].volume[d.timestamp.length-1]=null;}]){const d=fixture('AAPL-1y');mutate(d);const r=rowFor(d);assert.notEqual(r.dataQuality.code,'latest_session_pending');assert.equal(confirmedHistory(r),null);}
 const d=fixture('AAPL-1y');d.timestamp=d.timestamp.slice(-31);for(const q of Object.values(d.indicators.quote[0]))q.splice(0,q.length-31);d.indicators.adjclose[0].adjclose=d.indicators.adjclose[0].adjclose.slice(-31);assert.notEqual(rowFor(d).dataQuality.code,'latest_session_pending');
});
test('counts distinguish current completeness, available history and genuinely unusable data',()=>{
 const historical=['A-6mo','AAPL-1y','MSFT-6mo'].map(n=>rowFor(fixture(n))),r=summarizeDataQuality([...historical,{market:'TW',status:'consolidation'},{market:'TW',status:'insufficient_data',availableBars:15,missing:['需 30 根基底']},{market:'US',status:'insufficient_data',error:'outage'}]);
 assert.deepEqual([r.total,r.valid,r.historicalAvailable,r.usable,r.latestPending,r.otherMissing],[6,1,3,4,3,2]);assert.equal(r.valid+r.missing+r.failed,r.total);assert.equal(r.usable+r.otherMissing,r.total);assert.equal(r.recovered,0);assert.equal(r.markets.US.historicalAvailable,3);
});
test('historical evidence must match identity, date and complete prefix; never promotes a previous breakout',()=>{
 const r=rowFor(fixture('AAPL-1y'));r.lastCompleteAssessment.observedStatus='breakout';assert(confirmedHistory(r));assert.equal(r.eligible,false);
 for(const patch of [{symbol:'MSFT'},{market:'TW'},{date:'2026-11-25'},{eligible:true},{technicalBreakout:true},{bars:30},{metrics:{}}])assert.equal(confirmedHistory({...r,lastCompleteAssessment:{...r.lastCompleteAssessment,...patch}}),null);
 assert.equal(confirmedHistory({...r,error:'outage'}),null);assert.equal(confirmedHistory({...r,dataQuality:{...r.dataQuality,latestDate:'2026-12-24'}}),null);
});
test('real complete later response restores current evaluation, without substituting a quote',()=>{
 const d=fixture('AAPL-1y'),q=d.indicators.quote[0];q.close[q.close.length-1]=355.58;d.indicators.adjclose[0].adjclose[q.close.length-1]=355.58;
 const r=rowFor(d);assert.equal(r.dataQuality.code,'complete');assert.equal(r.lastCompleteAssessment,null);assert.equal(r.metrics.date,'2026-11-25');assert.equal(summarizeDataQuality([r]).historicalAvailable,0);
});
test('two hosts confirming a terminal publication delay defer only redundant bulk retries',async()=>{
 const r=rowFor(fixture('AAPL-1y'));r.historyRecovery={attempts:['query1.finance.yahoo.com','query2.finance.yahoo.com'].map(host=>({host,state:'latest_session_pending',latestDate:r.dataQuality.latestDate}))};
 let calls=0;const checkpoints=[];
 const result=await scanVolumeQueue([{symbol:'AAPL',market:'US'}],{pauseMs:0,evaluate:async()=>{calls++;return structuredClone(r);},onCheckpoint:async(rows,status,meta)=>checkpoints.push(meta)});
 assert.equal(calls,1);assert.equal(result.status,'completed');assert.equal(result.results[0].status,'insufficient_data');assert.equal(checkpoints.at(-1).deferredLatest,1);assert.equal(checkpoints.at(-1).recovered,0);assert.equal(checkpoints.at(-1).total,0);
 // A new run still requests fresh data, so a deferral never becomes a persistent cache.
 await scanVolumeQueue([{symbol:'AAPL',market:'US'}],{pauseMs:0,evaluate:async()=>{calls++;return structuredClone(r);}});assert.equal(calls,2);
});
test('one host, duplicate hosts or disagreeing dates never suppress the repair pass',async()=>{
 for(const attempts of [[{host:'query1',latestDate:'2026-11-25'}],[{host:'query1',latestDate:'2026-11-25'},{host:'query1',latestDate:'2026-11-25'}],[{host:'query1',latestDate:'2026-11-25'},{host:'query2',latestDate:'2026-11-24'}]]){
  const r=rowFor(fixture('AAPL-1y'));r.historyRecovery={attempts:attempts.map(a=>({...a,state:'latest_session_pending'}))};let calls=0;
  await scanVolumeQueue([{symbol:'AAPL',market:'US'}],{pauseMs:0,evaluate:async()=>{calls++;return structuredClone(r);}});assert.equal(calls,2);
 }
});
