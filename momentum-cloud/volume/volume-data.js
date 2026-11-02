import {parseSessionTWCalendar} from './market-session.js';
import {evaluateVolumeBreakout} from './volume-breakout.js';
const VB_CACHE=new Map(),VB_PENDING=new Map();
export async function vbCached(key,seconds,loader){
 const old=VB_CACHE.get(key);if(old&&Date.now()-old.at<seconds*1000)return old.data;
 if(VB_PENDING.has(key))return VB_PENDING.get(key);
 const task=(async()=>{const data=await loader();if(VB_CACHE.size>150)VB_CACHE.delete(VB_CACHE.keys().next().value);VB_CACHE.set(key,{at:Date.now(),data});return data;})();VB_PENDING.set(key,task);
 try{return await task;}finally{VB_PENDING.delete(key);}
}
export async function vbYahoo(symbol,{fetcher=(...args)=>fetch(...args),range='6mo'}={}){
 for(const host of ['query1.finance.yahoo.com','query2.finance.yahoo.com'])try{
  const response=await fetcher(`https://${host}/v8/finance/chart/${encodeURIComponent(symbol)}?interval=1d&range=${range}&includePrePost=false&events=div%2Csplits`,{headers:{'User-Agent':'Mozilla/5.0'},signal:AbortSignal.timeout(8000)});
  if(!response.ok)continue;const j=await response.json(),data=j?.chart?.result?.[0];
  if(j.chart.error||data?.meta?.symbol!==symbol||!Array.isArray(data.timestamp))continue;return {...data,_vbFetchedAt:Date.now()/1000};
 }catch{/* Try the second fixed upstream; never an arbitrary user-supplied URL. */}
 throw new Error('行情來源暫時無法連線，請稍後重試');
}
export function vbDate(time,market){return new Date(time*1000).toLocaleDateString('en-CA',{timeZone:market==='TW'?'Asia/Taipei':'America/New_York'});}
export function vbDaily(data,market,now=Date.now()/1000){
 const times=data?.timestamp,q=data?.indicators?.quote?.[0],adj=data?.indicators?.adjclose?.[0]?.adjclose??data?.indicators?.adjClose?.[0]?.adjClose,issues=[],bars=[];
 if(!Array.isArray(times)||!q)return {bars,adjusted:false,issues:['來源未提供日線陣列']};
 const arrays=Object.fromEntries(['open','high','low','close','volume'].map(k=>[k,q[k]??q[k[0].toUpperCase()+k.slice(1)]]));
 const quoteTime=data.meta?.regularMarketTime,regular=data.meta?.currentTradingPeriod?.regular;
 const localHour=Number(new Intl.DateTimeFormat('en-GB',{timeZone:market==='TW'?'Asia/Taipei':'America/New_York',hour:'2-digit',hourCycle:'h23'}).format(new Date(now*1000)));
 const currentSessionComplete=regular&&now>=regular.end+900&&(market!=='US'||localHour>=17);
 let omitted=0;
 for(let i=0;i<times.length;i++){
  const time=times[i];if(!Number.isFinite(time)){bars.push({time:null});continue;}
  const date=vbDate(time,market),sameAsNow=date===vbDate(now,market),quoteDate=Number.isFinite(quoteTime)?vbDate(quoteTime,market):null;
  // A live session is never treated as a completed daily signal. Future placeholder rows are excluded explicitly.
  if(time>now||quoteDate&&date>quoteDate||sameAsNow&&(!regular||vbDate(regular.start,market)!==date||!currentSessionComplete)){omitted++;continue;}
  const values=Object.fromEntries(Object.entries(arrays).map(([k,a])=>[k,Array.isArray(a)?a[i]:null]));
  const adjustedClose=adj?.[i],ratio=typeof adjustedClose==='number'&&adjustedClose>0&&typeof values.close==='number'&&values.close>0?adjustedClose/values.close:null;
  bars.push({time,date,...values,rawClose:values.close,...Object.fromEntries(['open','high','low','close'].map(k=>[k,typeof values[k]==='number'&&ratio?values[k]*ratio:null])),completed:true});
 }
 const tail=bars.slice(-31),last=tail.at(-1);
 if(!Number.isFinite(quoteTime)||!last)issues.push('缺少最後成交時間或完整交易日');
 else if(vbDate(quoteTime,market)>last.date&&(vbDate(quoteTime,market)<vbDate(now,market)||currentSessionComplete))issues.push('缺少最後已完成成交日的日線；不把較早訊號視為最新');
 else if(now-quoteTime>7*86400)issues.push('最後成交超過 7 日；停止產生當前訊號');
 if(tail.some(b=>b.close===null))issues.push('還原 OHLC 或 adjclose 缺漏');
 if(tail.some((b,i)=>i>0&&b.time-tail[i-1].time>14*86400))issues.push('最近基底存在超過 14 日的停牌／日線缺口，請核對連續交易日');
 return {bars,adjusted:tail.length>0&&tail.every(b=>b.close!==null),issues,omitted};
}
export function vbQuote(data,symbol,market,now=Date.now()/1000){
 const m=data?.meta||{};if(m.symbol!==symbol||m.currency!==(market==='TW'?'TWD':'USD')||!Number.isFinite(m.regularMarketPrice)||m.regularMarketPrice<=0||!Number.isFinite(m.regularMarketTime)||m.regularMarketTime>now+60)throw new Error('報價識別、幣別或時間不符');
 const regular=m.currentTradingPeriod?.regular,regularSession=Number.isFinite(regular?.start)&&Number.isFinite(regular?.end)&&regular.end>regular.start?{start:regular.start,end:regular.end}:null;
 const fetchedAt=Number.isFinite(data._vbFetchedAt)&&data._vbFetchedAt>0&&data._vbFetchedAt<=now+60?data._vbFetchedAt:now;
 return {regularSession,marketCalendar:data.marketCalendar??null,symbol,market,currency:m.currency,name:m.shortName||m.longName||symbol,price:m.regularMarketPrice,time:m.regularMarketTime,fetchedAt,source:'Yahoo Finance · 延遲行情',session:'一般交易時段最後成交；休市保留最後報價'};
}
export async function vbHistory(symbol){return vbCached('history:'+symbol,300,()=>vbYahoo(symbol));}
export async function vbSessionCalendar(market){if(market!=='TW')return null;try{return await vbCached('tw-session-calendar',3600,async()=>{const r=await fetch('https://openapi.twse.com.tw/v1/holidaySchedule/holidaySchedule',{signal:AbortSignal.timeout(6000)});if(!r.ok)throw new Error('calendar unavailable');return parseSessionTWCalendar(await r.json());});}catch{return null;}}
export async function fetchVBQuote(symbol,market){const [data,marketCalendar]=await Promise.all([vbHistory(symbol),vbSessionCalendar(market)]);return vbQuote({...data,marketCalendar},symbol,market);}
export async function fetchVBAssessment(symbol,market,scope=null){
 const [data,marketCalendar,resolvedScope]=await Promise.all([vbHistory(symbol),vbSessionCalendar(market),scope]),daily=vbDaily(data,market),quote=vbQuote({...data,marketCalendar},symbol,market);
 return {...evaluateVolumeBreakout(daily.bars,{symbol,market,scope:resolvedScope,adjusted:daily.adjusted,issues:daily.issues,source:quote.source,fetchedAt:quote.fetchedAt}),quote,omittedOpenBars:daily.omitted};
}
