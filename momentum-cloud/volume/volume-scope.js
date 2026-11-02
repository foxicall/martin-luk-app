import {vbCached} from './volume-data.js';
export function vbROC(value){const s=String(value||'');if(!/^\d{7}$/.test(s))return null;const d=`${Number(s.slice(0,3))+1911}-${s.slice(3,5)}-${s.slice(5)}`;return Number.isFinite(Date.parse(d))&&new Date(d).toISOString().slice(0,10)===d?d:null;}
export function vbScopeTable(companies,prices,now=Date.now()){
 if(!Array.isArray(companies)||companies.length<500||!Array.isArray(prices)||prices.length<500)throw new Error('官方名錄筆數異常');
 const p=new Map(),dates=new Set(),companyDates=new Set(),rows=[],missing=[],seen=new Set();
 for(const r of prices){if(p.has(r.Code))throw new Error('行情代碼重複');p.set(r.Code,r);dates.add(vbROC(r.Date));}
 for(const c of companies){const code=String(c['公司代號']||''),date=vbROC(c['出表日期']);companyDates.add(date);if(!/^[1-9]\d{3}$/.test(code)||code.startsWith('91'))continue;if(seen.has(code))throw new Error('公司名錄代碼重複');seen.add(code);
  const shares=Number(String(c['已發行普通股數或TDR原股發行股數']||'').replaceAll(',','')),price=Number(String(p.get(code)?.ClosingPrice||'').replaceAll(',',''));
  if(!(shares>0&&price>0)){missing.push(code+'.TW');continue;}
  rows.push({symbol:code+'.TW',market:'TW',name:c['公司簡稱']||code,marketCapTWD:shares*price,shares,price});
 }
 const date=[...dates][0],companyDate=[...companyDates][0];
 if(dates.size!==1||!date||companyDates.size!==1||!companyDate||now-Date.parse(date)>7*86400000||Date.parse(date)>now+86400000||now-Date.parse(companyDate)>7*86400000||Date.parse(companyDate)>now+86400000)throw new Error('名錄或收盤日期過期／不一致');
 rows.sort((a,b)=>b.marketCapTWD-a.marketCapTWD||a.symbol.localeCompare(b.symbol));rows.forEach((r,i)=>r.rank=i+1);
 return {date,companyDate,verified:missing.length===0,covered:rows.length,total:seen.size,missing,rows,method:'官方已發行普通股數 × 收盤價；未使用匯率或資本額推算',source:'TWSE t187ap03_L + STOCK_DAY_ALL'};
}
export async function fetchVBScope(){return vbCached('top100',900,async()=>{
 const data=await Promise.all(['https://openapi.twse.com.tw/v1/opendata/t187ap03_L','https://openapi.twse.com.tw/v1/exchangeReport/STOCK_DAY_ALL'].map(async url=>{const r=await fetch(url,{signal:AbortSignal.timeout(10000)});if(!r.ok)throw new Error('官方市值資料暫時無法取得');return r.json();}));return vbScopeTable(...data);
 });}
export function vbScopeFor(table,symbol,market){
 if(market==='US')return {verified:false,inTop100:false,adaptation:true,label:'美股延伸套用；非附件台灣 TOP100 原始範圍'};
 if(symbol.endsWith('.TWO'))return {verified:false,inTop100:false,label:'上櫃：附件台灣上市 TOP100 範圍外'};
 const row=table?.rows?.find(r=>r.symbol===symbol);
 return {verified:table?.verified===true,inTop100:row?row.rank<=100:false,rank:row?.rank??null,date:table?.date??null,covered:table?.covered??0,total:table?.total??null,label:table?.verified?(row?.rank<=100?'已核對上市市值前 100 大':'非上市市值前 100 大'):`上市市值範圍待核；${table?.covered??0}／${table?.total??'未知'} 檔有資料`};
}
