import {cached} from './provider.js';
// Current exchange directories. No bundled fallback is presented as a live universe.
const DIRECTORY_SOURCES = {
 US:[{id:'nasdaq',name:'Nasdaq',url:'https://www.nasdaqtrader.com/dynamic/SymDir/nasdaqlisted.txt'}, {id:'other',name:'NYSE / NYSE American / Arca / Cboe / IEX / TXSE',url:'https://www.nasdaqtrader.com/dynamic/SymDir/otherlisted.txt'}],
 TW:[{id:'listed',name:'台灣上市（含創新板）',url:'https://isin.twse.com.tw/isin/C_public.jsp?strMode=2'}, {id:'otc',name:'台灣上櫃',url:'https://isin.twse.com.tw/isin/C_public.jsp?strMode=4'}]
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
export async function loadUniverse(market){
 return cached('universe:'+market,1800,async()=>{const sources=await Promise.all(DIRECTORY_SOURCES[market].map(async source=>{try{const response=await fetch(source.url,{headers:{'User-Agent':'Mozilla/5.0'},signal:AbortSignal.timeout(market==='TW'?240000:30000)});if(!response.ok)throw new Error(`HTTP ${response.status}`);const bytes=await response.arrayBuffer();const text=new TextDecoder(market==='TW'?'big5':'utf-8').decode(bytes);const parsed=market==='TW'?parseTWDirectory(text,source.id):parseUSDirectory(text,source.id);return {...source,...parsed,ok:true,fetchedAt:new Date().toISOString()};}catch(e){return {...source,ok:false,error:e.message,rows:[]};}}));
 const rows=[...new Map(sources.flatMap(s=>s.rows).map(r=>[r.symbol,r])).values()].sort((a,b)=>a.symbol.localeCompare(b.symbol));return {market,complete:sources.every(s=>s.ok),asOf:new Date().toISOString(),total:rows.length,rows,sources:sources.map(({rows,...s})=>({...s,count:rows.length})),scope:market==='TW'?'上市與上櫃普通股（含創新板）；不含興櫃、ETF、特別股與權證。':'NasdaqTrader 全部掛牌交易所股票名錄，含 ADR / ADS；排除明示 ETF、基金、特別股、債券、權證、權利及單位，不含 OTC。名稱分類非交易所 CFI 認證；排除與代碼無法映射數另列。'};});
}
