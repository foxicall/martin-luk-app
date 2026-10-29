import {cached} from './provider.js';
// Current exchange directories. No bundled fallback is presented as a live universe.
const DIRECTORY_SOURCES = {
 US:[{id:'nasdaq',name:'Nasdaq',url:'https://www.nasdaqtrader.com/dynamic/SymDir/nasdaqlisted.txt'}, {id:'other',name:'NYSE / NYSE American / Arca / Cboe / IEX / TXSE',url:'https://www.nasdaqtrader.com/dynamic/SymDir/otherlisted.txt'}],
 TW:[{id:'listed',name:'台灣上市（含創新板）',url:'https://isin.twse.com.tw/isin/C_public.jsp?strMode=2',fallbackUrl:'https://openapi.twse.com.tw/v1/opendata/t187ap03_L'}, {id:'otc',name:'台灣上櫃',url:'https://isin.twse.com.tw/isin/C_public.jsp?strMode=4',fallbackUrl:'https://www.tpex.org.tw/openapi/v1/mopsfin_t187ap03_O'}]
};
export function parseUSDirectory(text, source) {
 const lines=text.trim().split(/\r?\n/),header=lines.shift().replace(/^\uFEFF/,'').split('|');
 const key=source==='nasdaq'?'Symbol':'ACT Symbol';
 for(const field of [key,'Security Name','ETF','Test Issue',...(source==='other'?['Exchange']:[])])if(!header.includes(field))throw new Error('美股名錄欄位不完整');
 const stats={records:0,excluded:0,unmapped:0,byExchange:{}},rows=[],seen=new Set();let fileDate=null;
 for(const line of lines){if(!line.trim())continue;if(line.startsWith('File Creation Time:')){if(fileDate)throw new Error('名錄結尾重複');fileDate=line.split('|')[0].slice(19).trim();continue;}if(fileDate)throw new Error('名錄結尾後有異常資料');
 const values=line.split('|');if(values.length!==header.length)throw new Error('名錄資料列遭截斷');const r=Object.fromEntries(header.map((h,i)=>[h,values[i].trim()]));stats.records++;
 // Include ordinary equity AND ADR/ADS; do not require an English common-stock phrase.
 // Exclude explicitly labelled funds and non-equity instruments, with counts disclosed.
 const name=r['Security Name'];if(r.ETF!=='N'||r['Test Issue']!=='N'||/\b(?:preferred|preference|warrants?|rights?|units?|ETN|funds?|notes?|bonds?)\b|exchange[- ]traded|shares? of beneficial interest/i.test(name)){stats.excluded++;continue;}
 const original=r[key],symbol=original.replaceAll('.','-');if(!/^[A-Z][A-Z0-9-]{0,18}$/.test(symbol)){stats.unmapped++;continue;}
 if(seen.has(symbol))continue;seen.add(symbol);const exchange=source==='nasdaq'?'NASDAQ':({N:'NYSE',A:'NYSE American',P:'NYSE Arca',Z:'Cboe',V:'IEX',F:'TXSE'}[r.Exchange]||r.Exchange);
 rows.push({symbol,name,market:'US',exchange,listingSymbol:original});stats.byExchange[exchange]=(stats.byExchange[exchange]||0)+1;
 }
 if(!fileDate||!rows.length)throw new Error('美股名錄缺少完整結尾或沒有股票');return {rows,stats,fileDate};
}
function plainCell(s){return s.replace(/<[^>]*>/g,' ').replace(/&nbsp;|&#160;/gi,' ').replace(/&amp;/gi,'&').replace(/&#(\d+);/g,(_,n)=>String.fromCodePoint(Number(n))).replace(/\s+/g,' ').trim();}
export function parseTWDirectory(text, source){
 const rows=[],seen=new Set(),stats={records:0,excluded:0,unmapped:0};const allowed=source==='listed'?['上市','上市臺灣創新板']:['上櫃'];
 if(!/<\/table>\s*<font[^>]*>\s*<center>掛牌日以正式公告為準<\/center>/i.test(text))throw new Error('台股名錄可能遭截斷');
 for(const tr of text.matchAll(/<tr\b[^>]*>([\s\S]*?)<\/tr>/gi)){const cells=[...tr[1].matchAll(/<t[dh]\b[^>]*>([\s\S]*?)<\/t[dh]>/gi)].map(m=>plainCell(m[1]));if(cells.length<6)continue;const code=cells[0].match(/^(\d{4})\s+(.+)$/);if(!code)continue;stats.records++;if(!allowed.includes(cells[3])||!cells[5].startsWith('ES')){stats.excluded++;continue;}const symbol=code[1]+(source==='listed'?'.TW':'.TWO');if(seen.has(symbol))continue;seen.add(symbol);rows.push({symbol,name:code[2],market:'TW',exchange:cells[3],sector:cells[4]});}
 if(!rows.length)throw new Error('台股名錄沒有可辨識的普通股');const fileDate=text.match(/(?:更新日期|最近更新日期)[^\d]{0,30}([\d/.-]+)/)?.[1]||null;return {rows,stats,fileDate};
}
export const TW_DIRECTORY_TIMEOUT_MS=10000;
const FALLBACK_NOTE='官方公司清單備援；依代碼與公司分類篩選，未逐檔 CFI 核驗。可掃描日線，RS 僅作樣本參考，不作全市場百分位通過依據。';
function sourceDate(value,now){
 const m=String(value??'').match(/^(\d{3})(\d{2})(\d{2})$/);if(!m)throw new Error('官方公司清單缺少有效出表日期');
 const date=`${Number(m[1])+1911}-${m[2]}-${m[3]}`,time=Date.parse(date+'T00:00:00Z'),today=Math.floor((now+8*3600000)/86400000)*86400000;
 if(!Number.isFinite(time)||new Date(time).toISOString().slice(0,10)!==date||time>today||today-time>7*86400000)throw new Error('官方公司清單日期過期或異常');return date;
}
export function parseTWCompanyDirectory(text,source,{now=Date.now()}={}){
 let data;try{data=JSON.parse(text);}catch{throw new Error('官方公司清單未回傳 JSON');}
 // A sanity floor detects error/truncated payloads; it is NOT proof of a complete market denominator.
 if(!Array.isArray(data)||data.length<500)throw new Error('官方公司清單筆數異常，拒絕部分名單');
 const rows=[],seen=new Set(),dates=new Set(),stats={records:data.length,excluded:0,unmapped:0};
 for(const r of data){
  if(!r||typeof r!=='object')throw new Error('官方公司清單資料列異常');
  const code=String(r['公司代號']??r.SecuritiesCompanyCode??'').trim(),name=String(r['公司簡稱']??r.CompanyAbbreviation??r['公司名稱']??r.CompanyName??'').trim(),industry=String(r['產業別']??r.IndustryCategory??'').trim(),shares=String(r['已發行普通股數或TDR原股發行股數']??r.IssueShares??'').replaceAll(',','');
  dates.add(sourceDate(r['出表日期']??r.Date,now));
  if(!/^\d{4,6}$/.test(code)||!name||seen.has(code)||!shares.trim()||!Number.isFinite(Number(shares))||Number(shares)<=0)throw new Error('官方公司清單缺欄位、代碼重複或股數異常');seen.add(code);
  if(!/^[1-9]\d{3}$/.test(code)||code.startsWith('91')||industry==='91'||/TDR|存託憑證|特別股|受益憑證|ETF/i.test(name)){stats.excluded++;continue;}
  rows.push({symbol:code+(source==='listed'?'.TW':'.TWO'),name,market:'TW',exchange:source==='listed'?'上市（公司清單）':'上櫃',sector:industry});
 }
 if(dates.size!==1||rows.length<500)throw new Error('官方公司清單日期不一致或有效筆數異常');
 return {rows,stats,fileDate:[...dates][0],rankEligible:false,method:'official-company-directory',notice:FALLBACK_NOTE};
}
function directoryError(e){return e?.name==='TimeoutError'||e?.name==='AbortError'?'來源連線逾時':String(e?.message||'來源無法連線').slice(0,220);}
export async function readUniverse(market,{fetcher=fetch,now=Date.now()}={}){
 if(!DIRECTORY_SOURCES[market])throw new Error('不支援的市場');
 const sources=await Promise.all(DIRECTORY_SOURCES[market].map(async source=>{
  const attempts=[];for(const [index,url] of [source.url,source.fallbackUrl].filter(Boolean).entries()){
   try{
    const response=await fetcher(url,{headers:{'User-Agent':'Mozilla/5.0'},signal:AbortSignal.timeout(market==='TW'?TW_DIRECTORY_TIMEOUT_MS:30000)});
    if(!response.ok)throw new Error(response.status===522?'來源連線逾時（HTTP 522）':`HTTP ${response.status}`);
    const text=new TextDecoder(market==='TW'&&index===0?'big5':'utf-8').decode(await response.arrayBuffer());
    const parsed=market!=='TW'?parseUSDirectory(text,source.id):index===0?parseTWDirectory(text,source.id):parseTWCompanyDirectory(text,source.id,{now});
    return {...source,...parsed,url,primaryUrl:source.url,fallback:index>0,attempts,rankEligible:parsed.rankEligible!==false,ok:true,fetchedAt:new Date(now).toISOString()};
   }catch(e){attempts.push({url,error:directoryError(e)});}
  }
  return {...source,ok:false,rankEligible:false,attempts,error:attempts.map((a,i)=>(i?'官方備援：':'主來源：')+a.error).join('；')+'。稍後可重試，未將缺資料當作合格。',rows:[]};
 }));
 const rows=[...new Map(sources.flatMap(s=>s.rows).map(r=>[r.symbol,r])).values()].sort((a,b)=>a.symbol.localeCompare(b.symbol)),complete=sources.every(s=>s.ok);
 return {market,complete,rankEligible:complete&&sources.every(s=>s.rankEligible!==false),asOf:new Date(now).toISOString(),total:rows.length,rows,sources:sources.map(({rows,...s})=>({...s,count:rows.length})),scope:market==='TW'?'上市與上櫃（含創新板）；ISIN 依 CFI 篩普通股。官方公司清單備援另標示分類限制，不含興櫃；排除 ETF、特別股、權證與 TDR。':'NasdaqTrader 全部掛牌交易所股票名錄，含 ADR / ADS；排除明示 ETF、基金、特別股、債券、權證、權利及單位，不含 OTC。名稱分類非交易所 CFI 認證；排除與代碼無法映射數另列。'};
}
export async function loadUniverse(market){return cached('universe-v2:'+market,1800,()=>readUniverse(market));}
