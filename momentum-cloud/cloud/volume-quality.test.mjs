import test from 'node:test';
import assert from 'node:assert/strict';
import {vbYahoo,vbHistoryQuality} from '../volume/volume-data.js';
import {summarizeDataQuality,dataDiagnosis} from '../volume/data-quality.js';
const now=Date.parse('2026-11-19T03:00Z')/1000;
function chart(count=64){
 const ts=[];for(let t=Date.parse('2026-08-01T13:30Z')/1000;t<=Date.parse('2026-11-18T14:30Z')/1000;t+=86400)if(![0,6].includes(new Date(t*1000).getUTCDay()))ts.push(t);
 const times=ts.slice(-count);return {meta:{symbol:'AAPL',currency:'USD',regularMarketPrice:100,regularMarketTime:Date.parse('2026-11-18T21:00Z')/1000},timestamp:times,indicators:{quote:[{open:times.map(()=>100),high:times.map(()=>101),low:times.map(()=>99),close:times.map(()=>100),volume:times.map(()=>10000)}],adjclose:[{adjclose:times.map(()=>100)}]}};
}
async function fetchSequence(rows){let calls=0;const urls=[];const data=await vbYahoo('AAPL',{now:()=>now,fetcher:async url=>{urls.push(url);const r=rows[calls++];assert(r,'unexpected retry');return r instanceof Response?r:Response.json({chart:{result:[r]}});}});return {data,calls,urls};}
const broken=()=>{const d=chart();d.indicators.adjclose[0].adjclose[d.timestamp.length-1]=null;return d;};
test('HTTP 200 incomplete adjusted close recovers from a complete second host, without splicing prices',async()=>{
 const first=broken(),second=chart();second.indicators.adjclose[0].adjclose.fill(50);
 const {data,calls,urls}=await fetchSequence([first,second]);assert.equal(calls,2);assert.match(urls[0],/includeAdjustedClose=true/);assert.match(urls[1],/query2/);assert.equal(data.indicators.adjclose[0].adjclose[0],50);assert(data._historyRecovery.recovered);assert(vbHistoryQuality(data,'US',now).complete);assert.equal(first.indicators.adjclose[0].adjclose.at(-1),null);
});
test('complete primary response avoids redundant requests',async()=>assert.equal((await fetchSequence([chart()])).calls,1));
test('all incomplete responses remain insufficient after bounded 1y fallback',async()=>{const r=await fetchSequence([broken(),broken(),broken()]);assert.equal(r.calls,3);assert.match(r.urls[2],/range=1y/);assert.equal(vbHistoryQuality(r.data,'US',now).complete,false);assert.equal(r.data._historyRecovery.recovered,false);});
test('older complete chart cannot replace a more recent incomplete session',async()=>{const old=chart();old.meta.regularMarketTime-=86400;for(const values of Object.values(old.indicators.quote[0]))values.pop();old.timestamp.pop();old.indicators.adjclose[0].adjclose.pop();const r=await fetchSequence([broken(),old,broken()]);assert.equal(r.data.meta.regularMarketTime,chart().meta.regularMarketTime);assert.equal(vbHistoryQuality(r.data,'US',now).complete,false);});
test('short complete IPO history does not loop retries; stale data cannot become current',async()=>{assert.equal((await fetchSequence([chart(15)])).calls,1);assert.equal(vbHistoryQuality(chart(15),'US',now).code,'short_history');const old=chart();old.meta.regularMarketTime-=20*86400;const r=await fetchSequence([old]);assert.equal(r.calls,1);assert.equal(vbHistoryQuality(old,'US',now).code,'stale_quote');});
test('rate-limited backup host is not called again for expanded history',async()=>{const r=await fetchSequence([broken(),new Response('rate limit',{status:429})]);assert.equal(r.calls,2);assert.equal(r.data._historyRecovery.recovered,false);});
test('invalid quote metadata is rejected and does not poison best-response selection',async()=>{const bad=chart();bad.meta.regularMarketTime=null;const r=await fetchSequence([bad,chart()]);assert.equal(r.calls,2);assert(vbHistoryQuality(r.data,'US',now).complete);});
test('diagnosis counts are exclusive, partition by market, and network errors remain failures',()=>{
 const rows=[{market:'US',status:'consolidation',historyRecovery:{recovered:true}},{market:'US',status:'insufficient_data',availableBars:128,missing:['還原 OHLC 或 adjclose 缺漏']},{market:'TW',status:'insufficient_data',availableBars:15,missing:['需 30 根基底']},{market:'US',error:'outage',status:'insufficient_data'}];
 const r=summarizeDataQuality(rows);assert.deepEqual([r.total,r.valid,r.missing,r.failed,r.retryable,r.recovered],[4,1,2,1,2,1]);assert.equal(r.causes.reduce((n,c)=>n+c.count,0),3);assert.equal(r.markets.TW.missing,1);assert.equal(dataDiagnosis(rows[0]),null);
});
