/** Single strategy: exact four entry predicates in the user's uploaded document. */
export const VB_VERSION='volume-breakout-1.0.0';
export const APP_VERSION='6.0.5';
export const VB_RULES=Object.freeze({baseDays:30,maxBasePct:20,volumeDays:20,minVolumeRatio:1.5,maxChasePct:5,hardStopPct:7,emaExitDays:21});
export const VB_STATES=Object.freeze({pending:'尚未評估',insufficient_data:'資料不足',no_base:'未成型',breakdown:'跌破基底',consolidation:'基底整理中',low_volume:'突破量能不足',extended:'超過追價上限',breakout:'放量突破'});
const vbFinite=n=>typeof n==='number'&&Number.isFinite(n);
const vbMean=a=>a.reduce((s,n)=>s+n,0)/a.length;
const vbLte=(a,b)=>a<=b+Number.EPSILON*16*Math.max(Math.abs(a),Math.abs(b),1);
export function evaluateVolumeBreakout(bars,{symbol='',market='',adjusted=false,issues=[],scope=null,source='',fetchedAt=null}={}) {
 const result={strategyVersion:VB_VERSION,symbol,market,source,fetchedAt,status:'insufficient_data',technicalBreakout:false,eligible:false,scope,availableBars:Array.isArray(bars)?bars.length:0,requiredBars:31,missing:[],checks:[],metrics:null,pattern:'30 日量化基底',exit:{status:'insufficient_data',method:'fixed-7pct-and-ema21',stopPrice:null,hardStopPct:7,reason:'固定停損須輸入實際買入價；21EMA 等待完整日線'}};
 if(!Array.isArray(bars)||bars.length<31)result.missing.push(`需 30 根基底＋1 根訊號日，現有 ${result.availableBars} 根`);
 if(!adjusted)result.missing.push('缺少一致的還原日線價格口徑');
 result.missing.push(...issues);
 if(result.missing.length)return result;
 const relevant=bars.slice(-31);let previous=0;
 for(const b of relevant){
  if(!b||!vbFinite(b.time)||b.time<=previous||b.completed!==true||!['open','high','low','close'].every(k=>vbFinite(b[k])&&b[k]>0)||!vbFinite(b.volume)||b.volume<0||b.low>Math.min(b.open,b.close)||b.high<Math.max(b.open,b.close)||b.low>b.high){result.missing.push('最近 31 根日線有缺值、時序錯誤或尚未收盤；未跳過壞資料拼出訊號');return result;}previous=b.time;
 }
 const today=relevant.at(-1),base=relevant.slice(0,-1),pivot=Math.max(...base.map(b=>b.high)),baseLow=Math.min(...base.map(b=>b.low)),volumeAverage=vbMean(base.slice(-20).map(b=>b.volume));
 if(!(volumeAverage>0)){result.missing.push('前 20 日均量必須大於 0');return result;}
 const baseValid=vbLte(pivot,baseLow*1.20),priceBreakout=today.close>pivot,volumeConfirmed=vbLte(volumeAverage*1.5,today.volume),withinChase=vbLte(today.close,pivot*1.05);
 const early=vbMean(base.slice(-20,-10).map(b=>b.volume)),late=vbMean(base.slice(-10).map(b=>b.volume));
 const ema21=vbEMA(bars.map(b=>b.close),21);
 result.metrics={ema21,emaSeedDate:bars[0].date,emaBars:bars.length,date:today.date,close:today.close,rawClose:today.rawClose??today.close,pivot,baseLow,baseWidthPct:(pivot/baseLow-1)*100,volume:today.volume,volumeAverage,volumeRatio:today.volume/volumeAverage,breakoutPct:(today.close/pivot-1)*100,chaseCeiling:pivot*1.05,volumeContractionRatio:early>0?late/early:null,change5Pct:(today.close/relevant.at(-6).close-1)*100};
 result.checks=[{id:'base',label:'前 30 日基底振幅 ≤20%',pass:baseValid},{id:'price',label:'收盤嚴格突破前 30 日最高價',pass:priceBreakout},{id:'volume',label:'當日量 ≥前 20 日均量 ×1.5',pass:volumeConfirmed},{id:'chase',label:'收盤不超過樞紐價 ×1.05',pass:withinChase}];
 result.status=!baseValid?'no_base':today.close<baseLow?'breakdown':!priceBreakout?'consolidation':!withinChase?'extended':!volumeConfirmed?'low_volume':'breakout';
 result.exit={...volumeBreakoutExit({close:today.close,ema21,date:today.date}),emaSeedDate:bars[0].date,emaBars:bars.length};
 result.execution={entry:'next-trading-bar-open',pendingEntry:result.status==='breakout',filled:false,reason:'收盤確認後，下一有效交易日開盤才是計畫進場；目前沒有實際成交價。'};
 result.technicalBreakout=result.status==='breakout';
 result.eligible=result.technicalBreakout&&market==='TW'&&scope?.verified===true&&scope?.inTop100===true&&scope.date===today.date;
 return result;
}
// Same recursion as pandas ewm(span=21, adjust=False, min_periods=21).
export function vbEMA(closes,days=21){
 if(!Array.isArray(closes)||closes.length<days||closes.some(x=>!vbFinite(x)||x<=0))return null;
 const alpha=2/(days+1);let value=closes[0];for(const close of closes.slice(1))value=alpha*close+(1-alpha)*value;return value;
}
export function volumeBreakoutExit({entryFillPrice=null,close=null,ema21=null,date=null}={}) {
 const stopPrice=vbFinite(entryFillPrice)&&entryFillPrice>0?Number((entryFillPrice*0.93).toPrecision(14)):null;
 const known=vbFinite(close)&&close>0&&vbFinite(ema21)&&ema21>0&&!!date;
 return {method:'fixed-7pct-and-ema21',hardStopPct:7,stopPrice,ema21,date,status:!known?'insufficient_data':close<ema21?'ema_exit_pending':'above_ema',emaExitPending:known&&close<ema21,execution:'next-trading-bar-open',reason:!known?'21EMA 缺完整同口徑日線':close<ema21?'收盤跌破 21EMA；下一有效交易日開盤出場計畫':'收盤未跌破 21EMA；持續核對固定停損'};
}
// A daily OHLC model, never a claim of a live broker fill. Entry stop is fixed.
export function vbDailyExit({entryFillPrice,open,low,pendingEMA=false}={}){
 const stop=volumeBreakoutExit({entryFillPrice}).stopPrice;
 if(!stop||![open,low].every(n=>vbFinite(n)&&n>0)||low>open)return {status:'insufficient_data',price:null};
 if(pendingEMA)return {status:'ema-open-exit',price:open,stop};
 if(open<=stop)return {status:'gap-stop',price:open,stop};
 if(low<=stop)return {status:'intraday-stop',price:stop,stop};
 return {status:'hold',price:null,stop};
}
