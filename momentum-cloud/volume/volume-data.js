import {buildHoldingDaily} from './holding-daily.js';
import {marketSession,sessionLocal,parseSessionTWCalendar} from './market-session.js';
import {evaluateVolumeBreakout} from './volume-breakout.js';
const VB_CACHE=new Map(),VB_PENDING=new Map();
export async function vbCached(key,seconds,loader){
 const old=VB_CACHE.get(key);if(old&&Date.now()-old.at<(typeof seconds==='function'?seconds(old.data):seconds)*1000)return old.data;
 if(VB_PENDING.has(key))return VB_PENDING.get(key);
 const task=(async()=>{const data=await loader();if(VB_CACHE.size>150)VB_CACHE.delete(VB_CACHE.keys().next().value);VB_CACHE.set(key,{at:Date.now(),data});return data;})();VB_PENDING.set(key,task);
 try{return await task;}finally{VB_PENDING.delete(key);}
}
export async function vbYahoo(symbol,{fetcher=(...args)=>fetch(...args),range='6mo',market=/[.](TW|TWO)$/.test(symbol)?'TW':'US',now=()=>Date.now()/1000}={}){
 const attempts=[],blocked=new Set();let best=null,bestQuality=null,latestQuoteDate='';
 // Inspect full bodies, not just HTTP 200. Never splice OHLC or adjustment factors across responses.
 const requests=[['query1.finance.yahoo.com',range],['query2.finance.yahoo.com',range],['query2.finance.yahoo.com','1y']];
 for(const [i,[host,period]] of requests.entries()){
  if(i===2&&(!bestQuality?.retryable||blocked.has(host)||range==='1y'))break;
  try{
   const response=await fetcher(`https://${host}/v8/finance/chart/${encodeURIComponent(symbol)}?interval=1d&range=${period}&includePrePost=false&events=div%2Csplits&includeAdjustedClose=true`,{headers:{'User-Agent':'Mozilla/5.0'},signal:AbortSignal.timeout(8000)});
   if(!response.ok){if(response.status===429)blocked.add(host);attempts.push({host,range:period,state:'http_error',status:response.status});continue;}
   const j=await response.json(),data=j?.chart?.result?.[0];
   if(j.chart?.error||data?.meta?.symbol!==symbol||data.meta.currency!==(market==='TW'?'TWD':'USD')||!Array.isArray(data.timestamp))throw Error('invalid chart identity');
   const received=now();vbQuote(data,symbol,market,received);const q=vbHistoryQuality(data,market,received),quoteDate=Number.isFinite(data.meta.regularMarketTime)?vbDate(data.meta.regularMarketTime,market):'';
   latestQuoteDate=quoteDate>latestQuoteDate?quoteDate:latestQuoteDate;
   attempts.push({host,range:period,state:q.complete?'complete':q.code,availableBars:q.availableBars,missingFields:q.missingFields});
   const bestDate=best? vbDate(best.meta.regularMarketTime,market):'';
   if(!best||quoteDate>bestDate||quoteDate===bestDate&&(q.complete&&!bestQuality.complete||q.complete===bestQuality.complete&&q.validBars>bestQuality.validBars)){best={...data,_vbFetchedAt:received};bestQuality=q;}
   if(q.complete&&quoteDate===latestQuoteDate||!q.retryable&&i===0)break;
  }catch(e){attempts.push({host,range:period,state:e?.name==='TimeoutError'||e?.name==='AbortError'?'timeout':'invalid_response'});}
 }
 if(!best)throw Error('行情來源暫時無法連線，請稍後重試');
 return {...best,_historyRecovery:{attempts,recovered:bestQuality.complete&&attempts.length>1}};
}
export function vbDate(time,market){return new Date(time*1000).toLocaleDateString('en-CA',{timeZone:market==='TW'?'Asia/Taipei':'America/New_York'});}
export function vbDaily(data,market,now=Date.now()/1000){
 const times=data?.timestamp,q=data?.indicators?.quote?.[0],adj=data?.indicators?.adjclose?.[0]?.adjclose??data?.indicators?.adjClose?.[0]?.adjClose,issues=[],bars=[];
 if(!Array.isArray(times)||!q)return {bars,adjusted:false,issues:['來源未提供日線陣列']};
 const arrays=Object.fromEntries(['open','high','low','close','volume'].map(k=>[k,q[k]??q[k[0].toUpperCase()+k.slice(1)]]));
 const quoteTime=data.meta?.regularMarketTime,regular=data.meta?.currentTradingPeriod?.regular;
 const localHour=Number(new Intl.DateTimeFormat('en-GB',{timeZone:market==='TW'?'Asia/Taipei':'America/New_York',hour:'2-digit',hourCycle:'h23'}).format(new Date(now*1000)));
 const session=marketSession(market,now,{regular,calendar:data.marketCalendar}),local=sessionLocal(now,market);
 const currentSessionComplete=session?.phase==='post'&&local.minute>=session.closeMinute+15&&(market!=='US'||localHour>=17);
 let omitted=0;
 for(let i=0;i<times.length;i++){
  const time=times[i];if(!Number.isFinite(time)){bars.push({time:null});continue;}
  const date=vbDate(time,market),sameAsNow=date===vbDate(now,market),quoteDate=Number.isFinite(quoteTime)?vbDate(quoteTime,market):null;
  // A live session is never treated as a completed daily signal. Future placeholder rows are excluded explicitly.
  if(time>now||quoteDate&&date>quoteDate||sameAsNow&&!currentSessionComplete){omitted++;continue;}
  const values=Object.fromEntries(Object.entries(arrays).map(([k,a])=>[k,Array.isArray(a)?a[i]:null]));
  const adjustedClose=adj?.[i],ratio=typeof adjustedClose==='number'&&adjustedClose>0&&typeof values.close==='number'&&values.close>0?adjustedClose/values.close:null;
  bars.push({time,date,...values,rawClose:values.close,...Object.fromEntries(['open','high','low','close'].map(k=>[k,typeof values[k]==='number'&&ratio?values[k]*ratio:null])),completed:true});
 }
 const tail=bars.slice(-31),last=tail.at(-1);
 if(!Number.isFinite(quoteTime)||!last)issues.push('缺少最後成交時間或完整交易日');
 else if(vbDate(quoteTime,market)>last.date&&(vbDate(quoteTime,market)<vbDate(now,market)||currentSessionComplete))issues.push('缺少最後已完成成交日的日線；不把較早訊號視為最新');
 else if(now-quoteTime>7*86400)issues.push('最後成交超過 7 日；停止產生當前訊號');
 if(tail.some(b=>b.close===null))issues.push(last?.rawClose===null?`${last.date} 日 K 收盤與還原收盤暫缺（報價可能已更新）`:'還原 OHLC 或 adjclose 缺漏');
 if(tail.some((b,i)=>i>0&&b.time-tail[i-1].time>14*86400))issues.push('最近基底存在超過 14 日的停牌／日線缺口，請核對連續交易日');
 return {bars,adjusted:tail.length>0&&tail.every(b=>b.close!==null),issues,omitted};
}
export function vbQuote(data,symbol,market,now=Date.now()/1000){
 const m=data?.meta||{};if(m.symbol!==symbol||m.currency!==(market==='TW'?'TWD':'USD')||!Number.isFinite(m.regularMarketPrice)||m.regularMarketPrice<=0||!Number.isFinite(m.regularMarketTime)||m.regularMarketTime>now+60)throw new Error('報價識別、幣別或時間不符');
 const regular=m.currentTradingPeriod?.regular,regularSession=Number.isFinite(regular?.start)&&Number.isFinite(regular?.end)&&regular.end>regular.start?{start:regular.start,end:regular.end}:null;
 const fetchedAt=Number.isFinite(data._vbFetchedAt)&&data._vbFetchedAt>0&&data._vbFetchedAt<=now+60?data._vbFetchedAt:now;
 return {regularSession,marketCalendar:data.marketCalendar??null,symbol,market,currency:m.currency,name:m.shortName||m.longName||symbol,price:m.regularMarketPrice,time:m.regularMarketTime,fetchedAt,source:'Yahoo Finance · 延遲行情',session:'一般交易時段最後成交；休市保留最後報價'};
}
export function vbHistoryQuality(data,market,now=Date.now()/1000){
 const daily=vbDaily(data,market,now),r=evaluateVolumeBreakout(daily.bars,{...daily}),q=data?.indicators?.quote?.[0]||{},a=data?.indicators?.adjclose?.[0]?.adjclose??data?.indicators?.adjClose?.[0]?.adjClose;
 const missingFields=new Set();for(const b of daily.bars.slice(-31)){
  const i=data.timestamp?.indexOf(b.time);for(const field of ['open','high','low','close','volume']){const n=(q[field]??q[field[0].toUpperCase()+field.slice(1)])?.[i];if(!Number.isFinite(n)||n<0||field!=='volume'&&n===0)missingFields.add(field);}
  if(!Number.isFinite(a?.[i])||a[i]<=0)missingFields.add('adjclose');
 }
 const complete=r.status!=='insufficient_data';let code='complete',retryable=false;
 if(!complete){if(r.missing.some(s=>s.includes('最後成交超過')))code='stale_quote';else if(missingFields.size||!daily.bars.length||r.missing.some(s=>/缺少最後已完成|未提供日線/.test(s))){code='daily_fields';retryable=true;}else if(daily.bars.length<31)code='short_history';else code='history_gap';}
 return {complete,code,retryable,availableBars:daily.bars.length,validBars:daily.bars.filter(b=>['open','high','low','close','volume'].every(k=>Number.isFinite(b[k]))).length,missingFields:[...missingFields],latestDate:daily.bars.at(-1)?.date||null};
}
export function vbHistoryTTL(data){const q=vbHistoryQuality(data,/[.](TW|TWO)$/.test(data.meta?.symbol)?'TW':'US');return q.retryable||q.missingFields.length?30:300;}
export async function vbHistory(symbol,{force=false}={}){if(force)VB_CACHE.delete('history:'+symbol);return vbCached('history:'+symbol,vbHistoryTTL,()=>vbYahoo(symbol));}
export async function vbSessionCalendar(market){if(market!=='TW')return null;try{return await vbCached('tw-session-calendar',3600,async()=>{const r=await fetch('https://openapi.twse.com.tw/v1/holidaySchedule/holidaySchedule',{signal:AbortSignal.timeout(6000)});if(!r.ok)throw new Error('calendar unavailable');return parseSessionTWCalendar(await r.json());});}catch{return null;}}
export async function fetchVBQuote(symbol,market){const [data,marketCalendar]=await Promise.all([vbHistory(symbol),vbSessionCalendar(market)]);return vbQuote({...data,marketCalendar},symbol,market);}
export async function fetchVBAssessment(symbol,market,scope=null,{forceHistory=false}={}){
 const [data,marketCalendar,resolvedScope]=await Promise.all([vbHistory(symbol,{force:forceHistory}),vbSessionCalendar(market),scope]),daily=vbDaily({...data,marketCalendar},market),quote=vbQuote({...data,marketCalendar},symbol,market);
 return {...evaluateVolumeBreakout(daily.bars,{symbol,market,scope:resolvedScope,adjusted:daily.adjusted,issues:daily.issues,source:quote.source,fetchedAt:quote.fetchedAt}),quote,dataQuality:vbHistoryQuality({...data,marketCalendar},market),historyRecovery:data._historyRecovery||null,holdingDaily:buildHoldingDaily(data,daily,quote),omittedOpenBars:daily.omitted};
}
