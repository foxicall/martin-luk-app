import test from 'node:test';
import assert from 'node:assert/strict';
import {parseTWCompanyDirectory,readUniverse,TW_DIRECTORY_TIMEOUT_MS} from '../src/universe.js';
import {rankResults,rankReadiness,snapshotCoverage,STRATEGY_VERSION} from '../src/strategy.js';
const now=Date.parse('2026-10-29T01:00:00Z');
const companies=(otc=false)=>Array.from({length:600},(_,i)=>otc?{Date:'1151028',SecuritiesCompanyCode:String(2000+i),CompanyAbbreviation:'Company '+i,IssueShares:'10000'}:{'出表日期':'1151028','公司代號':String(1000+i),'公司簡稱':'Company '+i,'已發行普通股數或TDR原股發行股數':'10000'});
const body=(otc=false)=>JSON.stringify(companies(otc));
const primary=otc=>('<table>最近更新日期:2026/10/28<tr><td>'+(otc?'6488':'2330')+' Company</td><td>ISIN</td><td>1990/01/01</td><td>'+(otc?'上櫃':'上市')+'</td><td>Sector</td><td>ESVUFR</td></tr></table><font><center>掛牌日以正式公告為準</center></font>').replace(/[^\x00-\x7f]/g,c=>'&#'+c.charCodeAt(0)+';').replace(/&#25499;&#29260;&#26085;&#20197;&#27491;&#24335;&#20844;&#21578;&#28858;&#28310;/,'掛牌日以正式公告為準');
// A successful primary parser is covered separately with decoded ISIN HTML; this fetch fixture encodes it as Big5.
const primaryBytes=otc=>{const html=primary(otc);const [a,b]=html.split('掛牌日以正式公告為準');return Buffer.concat([Buffer.from(a),Buffer.from('b1beb550a4e9a548a5bfa6a1a4bda769acb0b7c7','hex'),Buffer.from(b)]);};
test('official TWSE/TPEx feeds use venue suffixes and disclose unverified CFI classification',()=>{
 for(const otc of [false,true]){const p=parseTWCompanyDirectory(body(otc),otc?'otc':'listed',{now});assert.equal(p.rows.length,600);assert.equal(p.fileDate,'2026-10-28');assert.equal(p.rankEligible,false);assert.match(p.notice,/未逐檔 CFI/);assert.equal(p.rows[0].symbol,otc?'2000.TWO':'1000.TW');}
 const extra=companies();for(const code of ['0050','9105','910322'])extra.push({...extra[0],'公司代號':code});extra.push({...extra[0],'公司代號':'8888','公司簡稱':'Company 特別股'});const p=parseTWCompanyDirectory(JSON.stringify(extra),'listed',{now});assert.equal(p.rows.length,600);assert.equal(p.stats.excluded,4);
});
test('fallback rejects HTML, small or malformed payloads, duplicate codes, missing shares and mixed/stale/future dates',()=>{
 for(const text of ['<!DOCTYPE html>', '{}',JSON.stringify(companies().slice(0,10))])assert.throws(()=>parseTWCompanyDirectory(text,'listed',{now}));
 for(const change of [r=>r['公司代號']='1001',r=>delete r['已發行普通股數或TDR原股發行股數'],r=>r['出表日期']='1151027',r=>r['出表日期']='1151030',r=>r['出表日期']='1150231']){const a=companies();change(a[0]);assert.throws(()=>parseTWCompanyDirectory(JSON.stringify(a),'listed',{now}));}
 const old=companies().map(r=>({...r,'出表日期':'1151021'}));assert.throws(()=>parseTWCompanyDirectory(JSON.stringify(old),'listed',{now}),/過期/);
 assert.equal(parseTWCompanyDirectory(body(),'listed',{now:Date.parse('2026-10-28T16:00:00Z')}).rows.length,600);
});
test('HTTP 522 and timeout switch once to official backups, preserving full fetched list and failure provenance',async()=>{
 const seen=[];const d=await readUniverse('TW',{now,fetcher:async(url,options)=>{seen.push(url);assert.ok(options.signal instanceof AbortSignal);if(url.includes('isin.')){if(url.endsWith('4'))throw new DOMException('timeout','TimeoutError');return new Response('timeout',{status:522});}return new Response(body(url.includes('tpex')));}});
 assert.equal(TW_DIRECTORY_TIMEOUT_MS,10000);assert.equal(seen.length,4);assert.equal(d.complete,true);assert.equal(d.total,1200);assert.equal(d.rankEligible,false);assert.ok(d.sources.every(s=>s.fallback&&s.ok&&s.count===600));assert.match(d.sources[0].attempts[0].error,/522/);assert.match(d.sources[1].attempts[0].error,/逾時/);assert.ok(d.sources[1].url.includes('tpex.org.tw'));
});
test('primary recovery avoids fallback; a failed fallback remains incomplete and a later call can retry',async()=>{
 const seen=[];const healthy=await readUniverse('TW',{now,fetcher:async url=>{seen.push(url);return new Response(primaryBytes(url.endsWith('4')));}});
 assert.equal(healthy.complete,true);assert.equal(healthy.rankEligible,true);assert.equal(seen.length,2);assert.ok(healthy.sources.every(s=>!s.fallback));
 const failed=await readUniverse('TW',{now,fetcher:async url=>new Response(url.includes('isin.')?'timeout':'<html>error</html>',{status:url.includes('isin.')?522:200})});
 assert.equal(failed.complete,false);assert.equal(failed.rankEligible,false);assert.equal(failed.total,0);assert.ok(failed.sources.every(s=>s.attempts.length===2&&/官方備援/.test(s.error)));
 const partial=await readUniverse('TW',{now,fetcher:async url=>url.includes('tpex')?new Response(body(true)):new Response('bad',{status:522})});assert.equal(partial.complete,false);assert.equal(partial.total,600);assert.equal(partial.rankEligible,false);
});
test('a successful company backup never qualifies full-market RS even with complete same-day returns',()=>{
 const snapshot={status:'completed',processed:100,total:100,directories:[{market:'TW',complete:true,rankEligible:false,total:100}]};const coverage=snapshotCoverage(snapshot);
 const rows=Array.from({length:100},(_,i)=>({market:'TW',symbol:String(1000+i)+'.TW',strategyVersion:STRATEGY_VERSION,metrics:{asOf:'2026-10-28',rsMonth:i,rsQuarter:i,gain:i,relativeVolume:2},scanners:[],checks:[],missing:[],status:'missing'}));
 assert.equal(coverage.TW.total,100);assert.equal(rankReadiness(rows,coverage.TW).ready,false);assert.match(rankReadiness(rows,coverage.TW).reason,/CFI/);
 const results=rankResults(rows,coverage);assert.ok(results.every(r=>r.rankSample===0&&r.metrics.percentile===null&&r.rsReference.total===100&&!r.scanners.includes('leader')&&!r.scanners.includes('potent')));
});
