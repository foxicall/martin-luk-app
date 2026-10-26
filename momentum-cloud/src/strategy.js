// Hybrid v1.3.0: evidence gates are separate from price-pattern observations.
export const STRATEGY_VERSION='1.3.0';
export const APP_VERSION='5.0.6';
export const POLICY=Object.freeze({version:STRATEGY_VERSION,adr:5,adrTW:3.5,capUSD:1e8,dollarUSD:5e7,emaSpread:2,supportDistance:1.5,stopMax:5});
export const finite = x => typeof x === 'number' && Number.isFinite(x);
export const mean = a => a.length ? a.reduce((s,x)=>s+x,0)/a.length : null;
export const pct = (a,b) => finite(a)&&finite(b)&&b>0 ? (a/b-1)*100 : null;
export function ema(values, period) {if(values.length<period)return [];const out=Array(period-1).fill(null);let e=mean(values.slice(0,period));out.push(e);for(const v of values.slice(period)){e=v*2/(period+1)+e*(1-2/(period+1));out.push(e);}return out;}
export function validBars(bars) {if(!Array.isArray(bars))return [];return bars.filter(b=>b&&['open','high','low','close','volume','time'].every(k=>finite(b[k]))&&b.low>0&&b.volume>=0&&b.high>=Math.max(b.open,b.close,b.low)&&b.low<=Math.min(b.open,b.close)).sort((a,b)=>a.time-b.time).filter((b,i,a)=>!i||b.time!==a[i-1].time);}
const last=a=>a.at(-1);
const day=t=>new Date(t*1000).toISOString().slice(0,10);
export function relativeReturn(bars, benchmark, n){if(bars.length<n+1||!benchmark?.length)return null;const start=bars.at(-n-1),end=last(bars),index=new Map(benchmark.map(b=>[day(b.time),b.close]));const a=index.get(day(start.time)),b=index.get(day(end.time));if(!(a>0&&b>0))return null;return ((end.close/start.close)/(b/a)-1)*100;}
export function anchoredVWAP(bars, manualAnchor){
 let index=-1,label='';
 if(manualAnchor){index=bars.findIndex(b=>day(b.time)===manualAnchor);label='指定錨點';}
 else for(let i=Math.max(20,bars.length-60);i<bars.length;i++) {const b=bars[i],prior=bars.slice(i-20,i);if(b.volume>=mean(prior.map(x=>x.volume))*1.5&&(pct(b.open,bars[i-1].close)>=10||b.close>Math.max(...prior.map(x=>x.high)))){index=i;label=pct(b.open,bars[i-1].close)>=10?'放量跳空日':'放量基底突破';}}
 if(index<0)return null;const subset=bars.slice(index),volume=subset.reduce((s,b)=>s+b.volume,0);return volume>0?{value:subset.reduce((s,b)=>s+(b.high+b.low+b.close)/3*b.volume,0)/volume,date:day(bars[index].time),label}:null;
}
export function accountRisk(account={}) {
 const equity=Number(account.equity),peak=Number(account.peak),losses=Number(account.losses??0);
 if(!(equity>0)||!finite(equity)||!(peak>=equity)||!finite(peak)||!Number.isInteger(losses)||losses<0)return {valid:false,paused:true,rate:0,reason:'請核對淨值、高水位及連虧筆數'};
 if(losses>=5||account.paused===true)return {valid:true,equity,peak,paused:true,rate:0,reason:'暫停新倉；須完成檢討與恢復計畫'};
 if(account.riskConfirmed!==true)return {valid:false,paused:false,rate:0,reason:'帳戶狀態未確認：正常 0.5%／回撤 0.25%，不預選較高股數'};
 const drawdown=(1-equity/peak)*100,reduced=equity<peak;
 return {valid:true,equity,peak,drawdown,paused:false,rate:reduced?.0025:.005,reason:(reduced?'已確認回撤：0.25%':'已確認正常：0.5%')+(losses>=3?'；連虧 3 筆，先檢討':'')};
}
// Decimal fractions avoid allocating one extra share at floating-point boundaries.
function fraction(v){const s=String(v).toLowerCase(),[m,e='0']=s.split('e'),[a,b='']=m.split('.');let n=BigInt(a+b),d=10n**BigInt(b.length),power=Number(e);if(power>=0)n*=10n**BigInt(power);else d*=10n**BigInt(-power);return [n,d];}
function mul(a,b){return [a[0]*b[0],a[1]*b[1]];}function sub(a,b){return [a[0]*b[1]-b[0]*a[1],a[1]*b[1]];}function floorDiv(a,b){return a[0]*b[1]/(a[1]*b[0]);}
export function trimQuantity(original,remaining=original){if(!Number.isSafeInteger(original)||original<0||!Number.isSafeInteger(remaining)||remaining<0)return null;return Math.min(remaining,Number((BigInt(original)*15n+50n)/100n));}
export function positionPlan(entry,stop,account,large=false,lot=1){
 const risk=accountRisk(account);if(!risk.valid||risk.paused)return {valid:false,reason:risk.reason};
 if(!finite(entry)||!finite(stop)||!(entry>stop&&stop>0)||!Number.isSafeInteger(lot)||lot<1)return {valid:false,reason:'進場價必須大於有效停損價'};
 if(account.cash===''||account.cash==null||!finite(Number(account.cash))||Number(account.cash)<0||account.costReserve===''||account.costReserve==null||!finite(Number(account.costReserve))||Number(account.costReserve)<0)return {valid:false,reason:'請填可用現金與費用／滑價預留（可明確填 0）'};
 const e=fraction(entry),d=sub(e,fraction(stop)),equity=fraction(risk.equity),cost=fraction(Number(account.costReserve)),budget=sub(mul(equity,fraction(risk.rate)),cost),cash=sub(fraction(Number(account.cash)),cost),cap=large?.35:.25;
 if(budget[0]<=0n||cash[0]<=0n)return {valid:false,reason:'現金或風險預算不足預留費用'};
 const limits=[floorDiv(budget,d),floorDiv(mul(equity,fraction(cap)),e),floorDiv(cash,e)];const count=limits.reduce((a,b)=>a<b?a:b)/BigInt(lot)*BigInt(lot),shares=Number(count);
 if(!Number.isSafeInteger(shares)||shares<lot)return {valid:false,reason:'風險、現金或曝險不足一個交易單位'};
 const distance=Number(d[0])/Number(d[1]),trimShares=trimQuantity(shares);return {valid:true,strategyVersion:STRATEGY_VERSION,entry,stop,shares,risk:shares*distance+Number(account.costReserve),riskBudget:risk.equity*risk.rate,notional:shares*entry,cap,stopPct:distance/entry*100,r:distance,breakeven:entry+1.5*distance,targets:[3,5,10].map(r=>({r,price:entry+r*distance})),trimShares,remainingShares:shares-2*trimShares};
}
function greater(a,b){return a[0]*b[1]>b[0]*a[1];}
function riskAbove(entry,stop,percent){return greater(mul(sub(fraction(entry),fraction(stop)),fraction(100)),mul(fraction(entry),fraction(percent)));}
function adrAtLeast(bars,percent,strict=false){let total=[0n,1n];for(const b of bars){const delta=sub(fraction(b.high),fraction(b.low)),low=fraction(b.low),v=[delta[0]*low[1],delta[1]*low[0]];total=[total[0]*v[1]+v[0]*total[1],total[1]*v[1]];}const target=mul(fraction(percent),fraction(bars.length)),left=mul(total,fraction(100));return strict?greater(left,target):!greater(target,left);}
export function chooseStop(entry,dayLow,fiveLow){if(![entry,dayLow].every(finite)||!(entry>dayLow&&dayLow>0))return null;const alternate=riskAbove(entry,dayLow,3.5),stop=alternate?fiveLow:dayLow;if(!(stop>0&&stop<entry)||alternate&&!(stop>dayLow)||riskAbove(entry,stop,5))return null;return {price:stop,source:alternate?'觸發時已知 5M 棒低點':'觸發時已知當日低點',threshold:3.5};}
export function fourDeclines(values){return Array.isArray(values)&&values.length>=5&&values.slice(-5).every((v,i,a)=>finite(v)&&v>=0&&(i===0||a[i-1]>v));}
function evidence(raw,key,now){const e=raw.hybrid?.[key];if(!e||!['pass','fail'].includes(e.state)||!e.source||!e.method||!finite(e.asOf)||now-e.asOf<0||now-e.asOf>900)return null;return e.state==='pass';}
function knownCheck(result,name,value,detail){const state=value===null?'missing':value?'pass':'fail';result.checks.push({name,value,state,detail});if(state==='missing')result.missing.push(name);}
function setupObservations(raw,bars,m,now){
 const intra=validBars(raw.intraday).filter(b=>b.time<=now&&(!raw.sessionOpen||b.time>=raw.sessionOpen)),current=last(intra),prev=intra.at(-2),prior=last(bars),live=!!current&&now-current.time>=0&&now-current.time<=600&&raw.session==='regular';
 const avwap=anchoredVWAP(bars,raw.anchorDate),spread=pct(Math.max(m.ema9,m.ema21,m.ema50),Math.min(m.ema9,m.ema21,m.ema50)),inside=prior.high<=bars.at(-2).high&&prior.low>=bars.at(-2).low,base=bars.slice(-10),tight=base.length===10&&pct(Math.max(...base.map(b=>b.high)),Math.min(...base.map(b=>b.low)))<=m.adr*.7;
 const first=intra[0],low=intra.length?Math.min(...intra.map(b=>b.low)):null,pdh=prior.high,five=validBars(raw.intraday5).filter(b=>b.time<=now&&b.time+300>current?.time).at(-1),pdhStop=chooseStop(pdh,low,five?.low);
 const pdhReady=spread<=POLICY.emaSpread&&(inside||tight),pdhCross=pdhReady&&first?.open>=prior.low+.8*(prior.high-prior.low)&&prev?.close<=pdh&&current?.close>pdh;
 // Opening interval is chosen before the session; default is the first complete 5M.
 const minutes=raw.openingMinutes===1?1:5,open=raw.sessionOpen,opening=intra.filter(b=>finite(open)&&b.time>=open&&b.time<open+60*minutes),complete=opening.length===minutes&&opening.every((b,i)=>b.time===open+i*60)&&now>=open+minutes*60;
 const orh=complete?Math.max(...opening.map(b=>b.high)):null,orl=complete?Math.min(...opening.map(b=>b.low)):null,pre=raw.premarket,ep=raw.market==='US'&&pre?.gap>4&&pre.volume>0&&pre.volumeRatio>1&&pre.sameTimeSamples===20&&finite(pre.time)&&now-pre.time>=0&&now-pre.time<=900&&raw.catalyst===true&&evidence(raw,'catalyst',now)===true;
 const orCross=ep&&complete&&prev?.close<=orh&&current?.close>orh,orStop=orh>orl&&orl>0&&(orh-orl)/orh*100<=5?orl:null;
 const micro=raw.microInterval==='30s'?validBars(raw.microBars).filter(b=>b.time<=now):intra,seconds=raw.microInterval==='30s'?30:60,mc=last(micro),mp=micro.at(-2),samples=micro.slice(-6,-1),support=[m.ema9,m.ema21,avwap?.value].filter(v=>finite(v)&&v>0),supportReady=!!mp&&support.some(v=>Math.abs(pct(mp.low,v))<=POLICY.supportDistance),exhaustion=samples.length===5&&samples.every((b,i,a)=>b.time+seconds<=now&&(!i||b.low<a[i-1].low&&b.time===a[i-1].time+seconds))&&fourDeclines(samples.map(b=>b.volume));
 const pullCross=supportReady&&exhaustion&&mp.time+seconds<=now&&mc?.close>mc.open&&mc.close>mp.high,tick=raw.tickSize,pullStop=finite(tick)&&tick>0&&samples.length===5?Math.min(...samples.map(b=>b.low))-tick:null;
 const mk=(id,label,ready,cross,entry,stop,source,reason)=>({id,label,ready:!!ready,priceTriggered:!!(cross&&live&&entry>stop&&stop>0&&!riskAbove(entry,stop,5)),triggered:false,entry:finite(entry)?entry:null,stop:stop>0?stop:null,stopSource:source,reason});
 return {avwap,live,items:[mk('pdh','A · PDH 均線密集突破',pdhReady,pdhCross,pdh,pdhStop?.price,pdhStop?.source,'價格型態觀察；另需放量、Bid/Ask、集群與 Delta 驗證'),mk('orh','B · ORH / EP',ep,orCross,orh,orStop,'第一個完整開盤區間 ORL','盤前 >4%、同時段放量、催化劑與買方大單；價格突破不等於完整通過'),mk('pullback','C · EMA / AVWAP 衰竭',supportReady,pullCross,mp?.high,pullStop,'衰竭微觀低點下 1 Tick','9EMA、21EMA 或 AVWAP 支撐；1M/30S 四次量縮及反轉，另需訂單流'),mk('reentry','日內二次突破（觀察）',false,false,null,null,null,'保留觀察細則；必須重新符合 A／B／C，不作獨立 Hybrid 訊號')]};
}
export function analyze(raw,options={}){
 const now=options.now??Date.now()/1000,bars=validBars(raw.daily).filter(b=>b.complete!==false),market=raw.market==='TW'?'TW':'US',r={strategyVersion:STRATEGY_VERSION,symbol:String(raw.symbol||''),name:String(raw.name||raw.symbol||''),market,sector:raw.sector||'未分類',source:raw.source||'使用者匯入',bars,checks:[],missing:[],raw,metrics:{},scanners:[],status:'missing',setup:null,rankSample:0};
 if(bars.length<50){knownCheck(r,'完整日線',null,`至少 50 根供 EMA50；60 日報酬另需 61 根，目前 ${bars.length}`);return r;}
 const close=bars.map(b=>b.close),b=last(bars),prior=bars.at(-2),tail=bars.slice(-20),m={price:b.close,asOf:day(b.time),adr:mean(tail.map(b=>(b.high-b.low)/b.low*100)),ema9:last(ema(close,9)),ema21:last(ema(close,21)),ema50:last(ema(close,50)),ema150:last(ema(close,150)),capUSD:raw.currency==='USD'&&raw.marketCap>0?raw.marketCap:null,dollarUSD:raw.currency==='USD'?mean(tail.map(b=>b.close*b.volume)):null,dollarLocal:mean(tail.map(b=>b.close*b.volume)),gain:pct(b.close,prior.close),relativeVolume:mean(bars.slice(-21,-1).map(b=>b.volume))>0?b.volume/mean(bars.slice(-21,-1).map(b=>b.volume)):null,rsWeek:relativeReturn(bars,raw.benchmark,5),rsMonth:pct(b.close,bars.at(-21).close),rsQuarter:pct(b.close,bars.at(-61)?.close),percentile:null};r.metrics=m;
 knownCheck(r,'ADR(20)',adrAtLeast(tail,market==='US'?5:3.5,market==='TW'),market==='US'?'≥5%；20 日平均 (High−Low)/Low，非 ATR':'台股適配：嚴格 >3.5%');
 knownCheck(r,'掛牌市場',raw.exchange? (market==='US'?['NYSE','NASDAQ','NYQ','NMS','NGM','NCM'].includes(String(raw.exchange).toUpperCase()):['TWSE','TPEX','TAI','TWO'].includes(String(raw.exchange).toUpperCase())):null,market==='US'?'NYSE／Nasdaq；其他名錄股票保留但不符合本協定':'TWSE／TPEx 適配');
 if(market==='US'){knownCheck(r,'市值',m.capUSD===null?null:m.capUSD>=1e8,'≥US$100M；缺值不推估');knownCheck(r,'20 日平均成交額',m.dollarUSD===null?null:m.dollarUSD>=Math.max(5e7,options.dollarUSD||5e7),'20 日平均 close×volume 估算，≥US$50M（含等號）');}
 else knownCheck(r,'台股流動性與交易限制',evidence(raw,'twLiquidity',now),'列 TWD 成交額、價差與交易限制；不套用美元門檻');
 knownCheck(r,'收盤在 EMA21 上方',m.price>m.ema21,'完整日線 close > EMA21');knownCheck(r,'多頭排列',m.ema9>m.ema21&&m.ema21>m.ema50,'9 > 21 > 50；150 EMA 非硬門檻');
 knownCheck(r,'資料時效',now-b.time>=0&&now-b.time<=7*86400?true:null,`最近完整日 ${m.asOf}；日曆／延遲須核對`);
 for(const [key,name,detail] of [['calendar','時段與公司事件','交易日、調整價格口徑、財報時點'],['macro','大盤／板塊／支柱股','美股 QQQ/SPY、板塊及 AAPL/MSFT/NVDA；台股加權/櫃買適配'],['structure','Daily／1H 結構與 5R 空間','Profile POC/VAH/VAL、預定波段及上方阻力'],['orderFlow','Footprint／Delta','逐價成交、主動買賣分類、集群、空心棒與正 Delta 陷阱'],['volume','同時段突破量能','實際同時間窗基準；全日量不替代盤中量']]){const official=market==='TW'&&raw.mops;let explanation=detail+'；缺來源／方法／時間不通過';if(official){const available=['company','revenue','financials','announcements'].filter(k=>official[k]?.state==='available');if(key==='calendar')explanation=available.length?'已取得下列官方公司資料；交易日日曆、價格調整口徑與未來財報時點仍待核驗':'官方公司資料尚未取得；下方列來源狀態';else if(key==='macro')explanation+='；公司產業分類不等於板塊走勢';else explanation+='；公開資訊觀測站的公司申報資料不提供此項';knownCheck(r,name,evidence(raw,key,now),explanation);if(key==='calendar'&&available.length&&r.checks.at(-1).state==='missing')r.checks.at(-1).coverage='partial';}else{if(market==='US'&&raw.sec){if(key==='calendar')explanation=raw.sec.state==='available'?'已取得 SEC 公司申報索引；交易日日曆、復權口徑及未來財報時點仍待核驗':'SEC 公司申報尚未取得；下方列來源狀態';else explanation+='；SEC 申報文件不提供此項行情／訂單流證據';}knownCheck(r,name,evidence(raw,key,now),explanation);if(key==='calendar'&&market==='US'&&raw.sec?.state==='available'&&r.checks.at(-1).state==='missing')r.checks.at(-1).coverage='partial';}}
 const pre=raw.premarket;if(market==='US'&&pre?.gap>=4&&pre.volume>0&&pre.volumeRatio>1&&pre.sameTimeSamples===20&&finite(pre.time)&&now-pre.time>=0&&now-pre.time<=900&&raw.catalyst===true&&evidence(raw,'catalyst',now)===true)r.scanners.push('premarket');
 const setups=setupObservations(raw,bars,m,now);r.setups=setups.items;r.avwap=setups.avwap;r.freshIntraday=setups.live;r.setup=r.setups.find(s=>s.priceTriggered)||r.setups.find(s=>s.ready)||r.setups[0];
 const triggerKey=r.setup.id==='pdh'?'bidAsk':r.setup.id==='orh'?'bigTrades':'exhaustion';knownCheck(r,'型態專屬微觀證據',evidence(raw,triggerKey,now),triggerKey+'；須有預先定義及真實來源');
 r.largeLiquid=market==='US'&&m.capUSD>=1e10&&m.dollarUSD>=1e8;r.scannerVerified=r.scanners.length>0;return finalize(r);
}
function finalize(r){r.checks=r.checks.filter(c=>c.name!=='三重掃描背景');knownCheck(r,'三重掃描背景',r.scanners.length?true:null,'任一掃描器成立；百分位需完整同日分母');r.missing=r.checks.filter(c=>c.state==='missing').map(c=>c.name);const fail=r.checks.some(c=>c.state==='fail'),complete=!fail&&!r.missing.length;r.status=fail?'rejected':r.missing.length?'missing':r.setup?.priceTriggered?'triggered':'watch';for(const s of r.setups||[])s.triggered=!!(complete&&s.id===r.setup?.id&&s.priceTriggered);return r;}
// Old cloud summaries lack raw bars/evidence: retain them as observations only.
export function currentResult(row){if(row.strategyVersion===STRATEGY_VERSION)return row;return {...row,sourceMissing:row.sourceMissing||[...(row.missing||[])],status:'missing',strategyVersion:'legacy',scanners:[],rankSample:0,metrics:{...row.metrics,percentile:null},missing:[...new Set([...(row.missing||[]),'策略版本未驗證'])],checks:[...(row.checks||[]).filter(c=>c.name!=='策略版本未驗證'),{name:'策略版本未驗證',state:'missing',value:null,detail:'舊版摘要保留供參考；須重新取得原始資料並按 v1.3.0 評估'}],setup:row.setup?{...row.setup,triggered:false}:null,setups:row.setups?.map(s=>({...s,triggered:false})),freshIntraday:false};}
// Directory completeness and quote completeness are separate. Never infer a denominator from filtered rows.
export function snapshotCoverage(snapshot){
 const out={},directories=snapshot?.directories;
 if(!Array.isArray(directories)||!Number.isSafeInteger(snapshot.total)||directories.reduce((n,d)=>n+(Number.isSafeInteger(d.total)?d.total:0),0)!==snapshot.total)return out;
 const seen=new Set();for(const d of directories){if(!['TW','US'].includes(d.market)||seen.has(d.market)||d.complete!==true||!Number.isSafeInteger(d.total)||d.total<=0)return {};seen.add(d.market);out[d.market]={total:d.total,complete:snapshot.status==='completed'&&snapshot.processed===snapshot.total,scope:'full-market'};}
 return out;
}
export function rankReadiness(rows,coverage={}){
 const total=Number.isSafeInteger(coverage.total)&&coverage.total>0?coverage.total:null,current=rows.filter(r=>r.strategyVersion===STRATEGY_VERSION),legacy=rows.length-current.length;
 const missing20=current.filter(r=>!finite(r.metrics?.rsMonth)).length,missing60=current.filter(r=>!finite(r.metrics?.rsQuarter)).length,missingGain=current.filter(r=>!finite(r.metrics?.gain)).length;
 const dates=[...new Set(current.map(r=>r.metrics?.asOf).filter(Boolean))],unique=new Set(rows.map(r=>r.symbol)).size;
 let reason='';if(!rows.length)reason='尚無掃描結果';else if(legacy)reason=`${legacy} 檔為舊版摘要，需重新產出 20／60 日報酬`;else if(missing20||missing60||missingGain)reason=`缺 20 日報酬 ${missing20} 檔、60 日報酬 ${missing60} 檔、日漲幅 ${missingGain} 檔`;
 else if(dates.length!==1||current.some(r=>!/^\d{4}-\d{2}-\d{2}$/.test(r.metrics?.asOf||'')))reason='行情日期不一致，不能混合排名';
 else if(unique!==rows.length)reason='代碼重複，完整名單待核對';else if(!total||coverage.scope!=='full-market')reason='缺全市場名單分母';else if(coverage.complete!==true||rows.length!==total)reason=`全市場資料尚未齊備（${rows.length}／${total} 檔）`;
 return {ready:!reason,reason,total,received:rows.length,legacy,missing20,missing60,missingGain,dates,eligible:current.filter(r=>[r.metrics?.rsMonth,r.metrics?.rsQuarter,r.metrics?.gain].every(finite)).length};
}
export function rankResults(rows,coverage={}){
 const results=rows.map(currentResult).map(r=>({...r,metrics:{...r.metrics},checks:[...(r.checks||[])],missing:[...(r.missing||[])]})),groups=new Map();for(const r of results){r.scanners=(r.scanners||[]).filter(s=>s==='premarket');r.metrics.percentile=null;r.metrics.rank20=null;r.metrics.rank60=null;r.rankSample=0;r.rankMethod=null;r.rsReference=null;if(r.strategyVersion!==STRATEGY_VERSION)continue;const key=r.market+':'+r.metrics.asOf;if(!groups.has(key))groups.set(key,[]);groups.get(key).push(r);}
 for(const list of groups.values()){
  const sample=list.filter(r=>/^\d{4}-\d{2}-\d{2}$/.test(r.metrics.asOf||'')&&!r.raw?.error&&[r.metrics.rsMonth,r.metrics.rsQuarter].every(finite));
  if(sample.length>=2){const month=new Map(sample.map(r=>r.metrics.rsMonth).sort((a,b)=>b-a).map((v,i)=>[v,i+1])),quarter=new Map(sample.map(r=>r.metrics.rsQuarter).sort((a,b)=>b-a).map((v,i)=>[v,i+1]));for(const r of sample)r.rsReference={percentile:100*(1-Math.max(month.get(r.metrics.rsMonth),quarter.get(r.metrics.rsQuarter))/sample.length),sample:sample.length,total:coverage[r.market]?.total||null,asOf:r.metrics.asOf,method:'20/60 日報酬樣本參考；並列取較差名次；不供全市場門檻驗證'};}
  const c=coverage[list[0].market],total=c?.total;const complete=c?.complete===true&&c.scope==='full-market'&&Number.isSafeInteger(total)&&total>0&&list.length===total&&new Set(list.map(r=>r.symbol)).size===total&&list.every(r=>/^\d{4}-\d{2}-\d{2}$/.test(r.metrics.asOf||'')&&[r.metrics.rsMonth,r.metrics.rsQuarter,r.metrics.gain].every(finite));
  if(!complete)continue;
  const ranks={};for(const metric of ['rsMonth','rsQuarter','gain']){const sorted=list.map(r=>r.metrics[metric]).sort((a,b)=>b-a);ranks[metric]=new Map(sorted.map((v,i)=>[v,i+1]));}
  for(const r of list){const rank=metric=>ranks[metric].get(r.metrics[metric]);const month=rank('rsMonth'),quarter=rank('rsQuarter');r.rankSample=total;r.metrics.rank20=month;r.metrics.rank60=quarter;r.metrics.percentile=100*(1-Math.max(month,quarter)/total);r.rankMethod='20/60 日報酬代理；同市場、同日期、完整名單，並列取較差名次';if(month/total<=.05&&quarter/total<=.05)r.scanners.push('leader');if(rank('gain')/total<=.03&&r.metrics.relativeVolume>1)r.scanners.push('potent');}
 }
 for(const r of results){r.rankReason=r.rankSample?'':r.strategyVersion!==STRATEGY_VERSION?'舊版待重算':!finite(r.metrics.rsMonth)||!finite(r.metrics.rsQuarter)?'缺20／60日報酬':'全市場待齊';if(r.strategyVersion===STRATEGY_VERSION)finalize(r);}
 return results.sort((a,b)=>({triggered:0,watch:1,missing:2,rejected:3}[a.status]-{triggered:0,watch:1,missing:2,rejected:3}[b.status]||(b.metrics.percentile||0)-(a.metrics.percentile||0)));
}
function legacyExitPlan(position,quote){const {entry,initialStop,shares,heldDays=0,trim3=false,trim5=false,trail=9,strongTrend=false}=position;if(!(entry>initialStop&&initialStop>0&&shares>0&&quote.price>0))return {action:'資料不足',reason:'需要原始進場／初始停損與有效報價'};const r=entry-initialStop,multiple=(quote.price-entry)/r,stop=Math.max(initialStop,position.stop||initialStop,heldDays>=2&&quote.ema9>entry&&quote.price>entry?entry:initialStop);const period=strongTrend&&[21,50].includes(Number(trail))?Number(trail):9;const emaValue=quote['ema'+period];if(quote.price<=stop)return {action:'硬停損',reason:`價格已達停損 ${stop}`,multiple,stop};if(quote.closeConfirmed&&quote.close<emaValue)return {action:'全數出場',reason:`已確認日收盤跌破 EMA${period}`,multiple,stop};if((multiple>=3&&!trim3)||(multiple>=5&&!trim5)||pct(quote.price,quote.ema9)>=15||quote.weight>.35)return {action:'分批 10–15%',reason:'達 R 倍數／延伸或曝險上限；需自行確認已執行的批次',multiple,stop};return {action:'續抱觀察',reason:stop===entry?'停損可上移保本':'追蹤已確認日收盤與均線',multiple,stop};}
export function exitPlan(position,quote){
 if(position.strategyVersion!==STRATEGY_VERSION)return legacyExitPlan(position,quote);
 const {entry,initialStop,shares}=position;if(!(entry>initialStop&&initialStop>0&&shares>0&&quote.price>0))return {action:'資料不足',reason:'需要固定初始 R 與有效報價'};
 const r=entry-initialStop,multiple=(quote.price-entry)/r,stop=Math.max(initialStop,position.stop||initialStop),period=position.strongTrend&&position.preagreedTrail===21?21:9;
 const fee=Number(position.costPerShare),suggestedStop=multiple>=1.5&&finite(fee)&&fee>=0?Math.max(stop,entry+fee):stop,base={multiple,stop,suggestedStop,breakevenTrigger:entry+1.5*r};
 if(quote.price<=stop)return {...base,action:'硬停損',reason:'已觸及已確認硬停損；不等收盤'};
 if(quote.closeConfirmed&&quote.close<quote['ema'+period])return {...base,action:'次日開盤退出餘股',reason:`一次確認收盤低於 EMA${period}；硬停損優先`};
 if(multiple>=3&&!position.trim3||multiple>=5&&!position.trim5||pct(quote.price,quote.ema9)>=15)return {...base,action:'分批計畫待確認',trimShares:trimQuantity(position.originalShares,shares),reason:'3R／5R 各原始股數 15%，四捨五入；乖離 ≥15% 另記批次'};
 if(multiple>=1.5)return {...base,action:'1.5R 保本待確認',reason:finite(fee)&&fee>=0?'建議上移至成本加估算費用；未自動改寫實際停損':'先補費用與合法 Tick，再確認保本停損'};
 return {...base,action:'續抱觀察',reason:'固定初始 R；只依預定規則管理'};
}

// Daily observation is deliberately independent of complete Hybrid entry approval.
// Legacy summaries can support transparent price/liquidity observations, not trades.
export function dailyAssessment(row,now=Date.now()/1000){
 const m=row.metrics||{},checks=[],missing=[],failed=[],sourceMissing=[...new Set(row.sourceMissing||row.missing||[])];
 const add=(name,available,pass,detail)=>{const state=!available?'missing':pass?'pass':'fail';checks.push({name,state,detail});if(state==='missing')missing.push(name);if(state==='fail')failed.push(name);};
 if(row.raw?.error)return {state:'error',checks:[],missing:['行情下載'],failed:[],sourceMissing,reason:row.raw.error,legacy:row.strategyVersion!==STRATEGY_VERSION};
 add('ADR20',finite(m.adr),row.market==='TW'?m.adr>3.5:m.adr>=5,row.market==='TW'?'台股 >3.5%':'美股 ≥5%');
 add('收盤／EMA21',[m.price,m.ema21].every(v=>finite(v)&&v>0),m.price>m.ema21,'close > EMA21');
 add('9／21／50 EMA',[m.ema9,m.ema21,m.ema50].every(v=>finite(v)&&v>0),m.ema9>m.ema21&&m.ema21>m.ema50,'9 >21 >50，150 EMA 非門檻');
 if(row.market==='US'){add('市值',finite(m.capUSD)&&m.capUSD>0,m.capUSD>=1e8,'≥US$100M');add('20 日成交額',finite(m.dollarUSD)&&m.dollarUSD>=0,m.dollarUSD>=5e7,'≥US$50M；20 日均值');}
 const timestamp=typeof m.asOf==='string'?Date.parse(m.asOf+'T00:00:00Z')/1000:NaN;
 add('日線日期',finite(timestamp)&&timestamp<=now&&now-timestamp<=7*86400,true,m.asOf||'未取得');
 const old=row.strategyVersion!==STRATEGY_VERSION,notes=[];
 if(old)notes.push('依保存指標初篩；開啟個股可按新版重新抓取與計算');
 if(m.lastDollarUSD===0&&finite(row.raw?.quoteTime)&&finite(timestamp)&&row.raw.quoteTime<timestamp)notes.push('來源日線晚於最後成交日且末日量為零，待重新取得日線');
 if(row.market==='TW')notes.push('僅價格初篩；台股流動性及交易限制另待核驗');
 return {state:failed.length?'fail':missing.length?'missing':'pass',checks,missing,failed,sourceMissing,legacy:old,notes,reason:failed.length?failed.slice(0,2).join('、')+'未符':missing.length?'待補 '+missing.slice(0,2).join('、'):'日線條件符合；進場證據另核驗'};
}
export function dataGapSummary(rows,now=Date.now()/1000){
 const summary={total:rows.length,available:0,dailyPass:0,dailyFail:0,dailyMissing:0,downloadFailed:0,entryPending:0,sourceMissing:0,reasons:{}};
 for(const row of rows){const d=dailyAssessment(row,now);if(d.state==='error')summary.downloadFailed++;else{if(d.missing.length)summary.dailyMissing++;else summary.available++;if(d.state==='pass')summary.dailyPass++;if(d.state==='fail')summary.dailyFail++;}
  if(row.status!=='triggered')summary.entryPending++;
  const gaps=(row.sourceMissing||row.missing||[]).filter(x=>!['策略版本未驗證','保存的盤中證據待重評'].includes(x));if(!row.raw?.error&&gaps.length)summary.sourceMissing++;
  for(const key of gaps)summary.reasons[key]=(summary.reasons[key]||0)+1;
 }
 return summary;
}
export function observationState(row,now=Date.now()/1000){const d=dailyAssessment(row,now);return row.status==='triggered'?'triggered':d.state==='pass'?'daily':d.state==='fail'?'rejected':d.state==='error'?'error':'missing';}
export function sortObservations(rows){const order={triggered:0,daily:1,missing:2,error:3,rejected:4};return rows.sort((a,b)=>order[observationState(a)]-order[observationState(b)]||(b.metrics?.adr||0)-(a.metrics?.adr||0)||a.symbol.localeCompare(b.symbol));}
