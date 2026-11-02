// Quote age is measured against the market session, never a flat 24-hour cutoff.
// NYSE recurring holidays/early closes; Taiwan announced closures come from TWSE.
// Unscheduled closures / individual halts are not inferred from missing trades.
const SESSION_ZONES={US:'America/New_York',TW:'Asia/Taipei'};
export function sessionLocal(time,market){
 if(!SESSION_ZONES[market]||!Number.isFinite(time))return null;
 const parts=Object.fromEntries(new Intl.DateTimeFormat('en-CA',{timeZone:SESSION_ZONES[market],year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hourCycle:'h23'}).formatToParts(new Date(time*1000)).map(p=>[p.type,p.value]));
 return {date:`${parts.year}-${parts.month}-${parts.day}`,minute:Number(parts.hour)*60+Number(parts.minute)};
}
const sessionShift=(date,days)=>new Date(Date.parse(date+'T12:00:00Z')+days*86400000).toISOString().slice(0,10);
const sessionWeekday=date=>new Date(date+'T12:00:00Z').getUTCDay();
const sessionDate=(year,month,day)=>`${year}-${String(month).padStart(2,'0')}-${String(day).padStart(2,'0')}`;
function sessionNth(year,month,weekday,n){const first=sessionDate(year,month,1);return sessionShift(first,(weekday-sessionWeekday(first)+7)%7+7*(n-1));}
function sessionObserved(date,{saturday=true}={}){const day=sessionWeekday(date);return day===0?sessionShift(date,1):day===6&&saturday?sessionShift(date,-1):date;}
function sessionGoodFriday(year){
 const a=year%19,b=Math.floor(year/100),c=year%100,d=Math.floor(b/4),e=b%4,f=Math.floor((b+8)/25),g=Math.floor((b-f+1)/3),h=(19*a+b-d-g+15)%30,i=Math.floor(c/4),k=c%4,l=(32+2*e+2*i-h-k)%7,m=Math.floor((a+11*h+22*l)/451),month=Math.floor((h+l-7*m+114)/31),day=(h+l-7*m+114)%31+1;
 return sessionShift(sessionDate(year,month,day),-2);
}
function sessionUSHolidays(year){
 const lastMay=sessionDate(year,5,31);
 const days=[sessionObserved(sessionDate(year,1,1),{saturday:false}),sessionNth(year,1,1,3),sessionNth(year,2,1,3),sessionGoodFriday(year),sessionShift(lastMay,-((sessionWeekday(lastMay)+6)%7)),sessionObserved(sessionDate(year,7,4)),sessionNth(year,9,1,1),sessionNth(year,11,4,4),sessionObserved(sessionDate(year,12,25))];
 if(year>=2022)days.push(sessionObserved(sessionDate(year,6,19)));
 if(year===2025)days.push('2025-01-09'); // Announced national day of mourning.
 return new Set(days);
}
export function sessionTradingDay(date,market,calendar=null){
 const weekday=sessionWeekday(date);if(weekday===0||weekday===6)return false;
 if(market==='US')return !sessionUSHolidays(Number(date.slice(0,4))).has(date);
 return !(calendar?.years?.includes(Number(date.slice(0,4)))&&Array.isArray(calendar.closedDates)&&calendar.closedDates.includes(date));
}
function sessionCloseMinute(date,market,regular){
 // Prefer source-confirmed hours for this exact date, including special closes.
 const a=sessionLocal(regular?.start,market),b=sessionLocal(regular?.end,market);
 if(a?.date===date&&b?.date===date&&a.minute<b.minute&&b.minute-a.minute>=60&&b.minute<=17*60)return b.minute;
 if(market==='TW')return 13*60+30;
 const year=Number(date.slice(0,4)),thanksgiving=sessionNth(year,11,4,4);
 return date===sessionShift(thanksgiving,1)||date.endsWith('-12-24')||date.endsWith('-07-03')?13*60:16*60;
}
export function marketSession(market,now=Date.now()/1000,{regular=null,calendar=null}={}){
 const local=sessionLocal(now,market);if(!local)return null;
 const trading=sessionTradingDay(local.date,market,calendar),start=market==='US'?9*60+30:9*60,end=sessionCloseMinute(local.date,market,regular);
 const phase=!trading?'closed':local.minute<start?'pre':local.minute<end?'regular':'post';
 let expectedDate=local.date;if(!trading||phase==='pre'){for(let i=0;i<15;i++){expectedDate=sessionShift(expectedDate,-1);if(sessionTradingDay(expectedDate,market,calendar))break;}}
 return {phase,date:local.date,expectedDate,closeMinute:sessionCloseMinute(expectedDate,market,regular),zone:SESSION_ZONES[market]};
}
export function quoteSessionStatus(quote,{now=Date.now()/1000,ready=false}={}){
 const bad={usable:false,state:'unavailable',phase:'unknown',title:'報價待更新',label:'保存報價',reason:'未取得可核對的最新行情；保留最後成功報價。',canNotify:false};
 if(!quote||!Number.isFinite(quote.time)||!Number.isFinite(quote.fetchedAt)||quote.time<=0||quote.time>now+60||quote.fetchedAt<=0||quote.fetchedAt>now+60)return bad;
 if(!ready||quote.offlineSnapshot||now-quote.fetchedAt>900)return {...bad,state:'snapshot',title:quote.offlineSnapshot?'離線快照 · 待更新':'來源待更新',label:'保存報價',reason:'目前使用保存報價；重新連線或更新行情後，再核對持倉出場條件。'};
 const session=marketSession(quote.market,now,{regular:quote.regularSession,calendar:quote.marketCalendar}),trade=sessionLocal(quote.time,quote.market);if(!session||!trade)return bad;
 const base={...bad,...session,quoteDate:trade.date,expectedDate:session.expectedDate};
 if(session.phase==='regular'){
  if(trade.date!==session.date||now-quote.time>1200)return {...base,state:'stale',title:'盤中行情待更新',label:'過期報價',reason:'市場已開盤，但尚未取得本交易日 20 分鐘內的成交報價；不沿用前日價格作當前建議。'};
  return {...base,usable:true,state:'regular',label:'現價 · 延遲',reason:'交易時段延遲報價；操作前核對券商行情。',canNotify:true};
 }
 const sourceClose=trade.date===session.expectedDate&&trade.minute>=session.closeMinute-20&&trade.minute<=session.closeMinute+5;
 if(!sourceClose)return {...base,state:'stale',title:'最近收盤資料待補',label:'收盤待核對',reason:`預期最近完整交易日為 ${session.expectedDate}，目前報價為 ${trade.date}，或未接近該日收盤；請更新行情。`};
 const label=session.phase==='pre'?'盤前 · 最近收盤':'休市 · 最近收盤';
 return {...base,usable:true,state:'closed',title:'休市中 · 依最近收盤評估',label,reason:`${session.expectedDate} 最近交易日收盤參考；${session.phase==='pre'?'尚未開盤':'目前休市'}，最後成交超過 24 小時不代表行情失效。`,canNotify:false};
}
export function parseSessionTWCalendar(rows){
 if(!Array.isArray(rows)||!rows.length)throw new Error('官方休市表未提供資料');
 const closedDates=[],years=new Set();for(const r of rows){const d=String(r.Date||''),description=String(r.Name||'')+' '+String(r.Description||'');if(!/^\d{7}$/.test(d))continue;const date=`${Number(d.slice(0,3))+1911}-${d.slice(3,5)}-${d.slice(5)}`;if(!Number.isFinite(Date.parse(date))||new Date(date).toISOString().slice(0,10)!==date)continue;years.add(Number(date.slice(0,4)));if(/休市|放假|補假|市場無交易/.test(description)&&!/開始交易|最後交易/.test(description))closedDates.push(date);}
 if(!closedDates.length)throw new Error('官方休市表無可辨識休市日期');
 return {source:'TWSE holidaySchedule',years:[...years],closedDates:[...new Set(closedDates)].sort()};
}
