import {vbEMA} from './volume-breakout.js';
import {quoteSessionStatus,sessionLocal} from './market-session.js';
// Exit evidence is independent of the 31-bar/volume requirements for a new entry.
// A quote-assisted, UNADJUSTED reference is explicitly never a confirmed EMA exit.
export function buildHoldingDaily(data,daily,quote,{now=Date.now()/1000}={}){
 const base={symbol:quote.symbol,market:quote.market,fetchedAt:quote.fetchedAt,confirmed:false,reference:false,close:null,ema21:null,date:null,reason:'完整收盤歷史不足，未估造均線'};
 const bars=daily.bars||[],last=bars.at(-1);if(last)base.date=last.date;
 const validDates=bars.length>=21&&bars.every((b,i)=>b.completed===true&&Number.isFinite(b.time)&&b.time>0&&typeof b.date==='string'&&/^\d{4}-\d{2}-\d{2}$/.test(b.date)&&(!i||b.time>bars[i-1].time&&b.date>bars[i-1].date&&b.time-bars[i-1].time<=14*86400));
 if(!validDates)return base;
 const adjusted=bars.map(b=>b.close),ema=vbEMA(adjusted);
 if(daily.adjusted&&ema!==null&&!daily.issues.length)return {...base,confirmed:true,basis:'adjusted-daily',close:last.close,ema21:ema,bars:bars.length,seedDate:bars[0].date,reason:'使用完整還原收盤日線計算 21EMA'};
 // Only replace a missing terminal raw close, never fill gaps, change old bars,
 // mix adjusted and raw histories, or use an intraday/old/offline price.
 const status=quoteSessionStatus(quote,{now,ready:true}),raw=bars.map(b=>b.rawClose),previous=raw.slice(0,-1);
 const sameClose=status.usable&&status.state==='closed'&&status.expectedDate===last.date&&sessionLocal(quote.time,quote.market)?.date===last.date;
 const i=data.timestamp?.indexOf(last.time),source=data.indicators?.quote?.[0],high=source?.high?.[i]??source?.High?.[i],low=source?.low?.[i]??source?.Low?.[i];
 if(!sameClose||raw.at(-1)!==null||!previous.every(v=>Number.isFinite(v)&&v>0)||!Number.isFinite(high)||!Number.isFinite(low)||low<=0||low>quote.price||high<quote.price)return {...base,reason:'正式日線收盤／還原值缺漏；目前沒有可安全補充的同日收盤報價'};
 const values=[...previous,quote.price],referenceEMA=vbEMA(values);
 return {...base,reference:true,basis:'raw-close-quote-reference',close:quote.price,ema21:referenceEMA,bars:values.length,seedDate:bars[0].date,quoteTime:quote.time,reason:`${last.date} Yahoo 日 K 收盤／還原值暫缺；以同日最近收盤報價接續未還原歷史，僅供參考，非正式策略確認`};
}
