#!/usr/bin/env node
// Exercises the actual offline HTML scripts. DOM doubles test event handlers,
// not browser painting; no package install, browser, SDK or service is required.
'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const source=fs.readFileSync(path.join(__dirname,'../standalone_preview.html'),'utf8');
let checks=0;
const equal=(a,b,message)=>{assert.equal(a,b,message);checks++};
const check=(a,message)=>{assert.ok(a,message);checks++};
const rejects=(fn,message)=>{assert.throws(fn,undefined,message);checks++};
const block=id=>{let match=source.match(new RegExp(`<script id="${id}"[^>]*>([\\s\\S]*?)<\\/script>`));assert.ok(match,`Missing inline script ${id}`);return match[1]};
check(!/\b(?:fetch|XMLHttpRequest|WebSocket|EventSource|sendBeacon)\b|localhost|127\.0\.0\.1/i.test(source),'No network entry points or loopback addresses');
check(!/<(?:script|img|iframe|link)\b[^>]*\b(?:src|href)=|@import|url\(/i.test(source),'No external HTML/CSS resources');
const context=vm.createContext({console});vm.runInContext(block('standalone-core'),context);
const S=context.Standalone,baseCandidate={entry:100,stop:98,day:98,source:'day_low',type:'PDH',large:true};
const holding=(changes={})=>({market:'us',symbol:'NVDA',name:'NVIDIA',entry:100,stop:98,shares:100,price:105,ema9:103,ema21:102,ema50:90,close:105,confirmed:true,large:true,uptrend:false,ema:9,...changes});
const diagnosis=(changes={},equity=100000,euphoria=20)=>S.diagnose(holding(changes),equity,euphoria);
const p=S.plan(baseCandidate,100000);
equal(p.shares,250,'0.5% equity divided by initial risk produces 250 whole shares');equal(p.amount,25000,'Entry notional uses rounded quantity');equal(p.risk,500,'Risk budget is strictly 0.5%');equal(p.cap,35,'Large-stock cap is 35%');equal(p.sl,2,'Initial stop percentage');
for(const [r,value]of [[3,106],[5,110],[10,120]])equal(p.targets[r],value,`Exact ${r}R entry target`);
const cap=S.plan({...baseCandidate,stop:98.5,day:98.5,large:false},100000);equal(cap.shares,250,'25% nonlarge cap overrides the larger risk-based quantity');equal(cap.cap,25,'Other stocks have 25% cap');equal(cap.exposure,25,'Whole-share exposure stays exactly on cap');
for(const stop of [98.5,97])check(S.plan({...baseCandidate,stop,day:stop},100000).shares>0,'Inclusive 1.5–3% stop bounds');
for(const stop of [98.500001,96.999999,100,0])rejects(()=>S.plan({...baseCandidate,stop,day:stop},100000),'Reject outside stop limits');
rejects(()=>S.plan({...baseCandidate,source:'entry_bar_low',bar:98},100000),'Entry-bar stop requires day low wider than 5%');
check(S.plan({...baseCandidate,source:'entry_bar_low',bar:98,day:94},100000).shares>0,'Actual entry-bar low valid when day risk exceeds 5%');
rejects(()=>S.plan({...baseCandidate,source:'entry_bar_low',bar:97,day:94},100000),'Entry-bar price must match stop');
for(const equity of [0,-1,NaN,Infinity,'100000',true,.001])rejects(()=>S.plan(baseCandidate,equity),'Invalid or insufficient equity cannot produce executable shares');
for(const market of ['tw','us'])for(const c of S.candidates(market)){const result=S.plan(c,market==='tw'?1000000:50000);check(c.adr>=(market==='tw'?3.5:5),'Each fixture meets default ADR');check(c.entry>Math.max(c.ema9,c.ema21,c.ema50),'Fixture is above all EMA values');check((Math.max(c.ema9,c.ema21,c.ema50)-Math.min(c.ema9,c.ema21,c.ema50))/c.entry<.02,'EMA fixture is compressed');check(result.risk<=(market==='tw'?1000000:50000)*.005+1e-8,'Demo size stays within risk cap');check(result.exposure<=result.cap,'Demo size stays within exposure cap');}
equal(S.symbolFor('2330','tw'),'2330.TW','Taiwan suffix normalized');equal(S.symbolFor('brk-b','us'),'BRK-B','US share class normalized');equal(S.symbolFor('brk.b','us'),'BRK-B','Dotted US share class becomes its standard quote symbol');equal(S.symbolFor('6488.TWO','tw'),'6488.TWO','TPEx suffix stays distinct');rejects(()=>S.symbolFor('6488.TWOO','tw'),'Unsupported market suffix rejected');
let d=diagnosis();equal(d.current,2.5,'R uses fixed original risk');equal(d.trail,100,'At least 2R arms breakeven');equal(d.pnl,500,'Unrealized PnL');equal(d.action,'hold','Below 3R holds');
for(const [price,r]of [[106,3],[110,5],[120,10]]){let t=diagnosis({price,close:price,ema9:price-1});equal(t.action,'trim',`${r}R strength advice`);equal(t.trim,15,'15 whole shares meets 10–15% range');check(t.label.includes(`${r}R`),'Reached target label is explicit');}
equal(diagnosis({price:105.999}).action,'hold','Below exact 3R does not trim');equal(diagnosis({price:104}).trail,100,'Exactly 2R arms breakeven');equal(diagnosis({price:103.999}).trail,98,'Below 2R does not arm breakeven');
let pullback=diagnosis({price:103,peak:3,trail:100,close:103,ema9:102});equal(pullback.peak,3,'Observed peak survives pullback');equal(pullback.trail,100,'Trailing stop never decreases');equal(pullback.current,1.5,'Breakeven does not change R denominator');
equal(diagnosis({price:98,close:98,ema9:70},1000).action,'exit','Hard stop wins over extreme exposure and deviation');equal(diagnosis({price:100,peak:3,trail:100,ema9:90,close:100}).action,'exit','Breakeven stop is immediate even with positive EMA comparison');
equal(diagnosis({price:103,close:103,ema9:104}).action,'exit','Confirmed close below 9 EMA exits');equal(diagnosis({price:103,close:null,confirmed:false,ema9:104}).action,'hold','Intraday EMA break does not substitute for completed close');equal(diagnosis({price:103,close:104,ema9:104}).action,'hold','Close exactly on EMA holds');
equal(diagnosis({price:103,close:103,ema9:104,uptrend:true,ema:21,peak:3}).action,'hold','3R main uptrend may use 21 EMA');equal(diagnosis({price:103,close:103,ema9:104,uptrend:true,ema:21,peak:2.99}).ema,9,'Below 3R main uptrend still uses 9 EMA');equal(diagnosis({price:103,close:103,ema9:104,ema50:102,uptrend:true,ema:50,peak:3}).ema,50,'Eligible main uptrend may use 50 EMA');
equal(diagnosis({price:100,close:100,ema9:99,shares:350,stop:95}).action,'hold','Exactly 35% does not trigger growth trim');equal(diagnosis({price:100,close:100,ema9:99,shares:351,stop:95}).action,'trim','Above 35% triggers growth trim');let small=diagnosis({price:100,close:100,ema9:99,shares:260,stop:95,large:false});check(small.over,'Small stock over 25% warns');equal(small.action,'hold','25% cap warning below 35% is not an automatic strength trigger');
equal(diagnosis({entry:110,stop:100,price:120,close:120,ema9:100}).action,'hold','Exactly 20% deviation holds');equal(diagnosis({entry:110,stop:100,price:120.01,close:120.01,ema9:100}).action,'trim','Strictly above configured deviation trims');equal(diagnosis({entry:10.1,stop:10,price:10.4,close:10.4,ema9:10.3,ema21:10.2,ema50:10.1}).current,3,'Decimal inputs preserve exact 3R');equal(diagnosis({price:106,close:106,shares:6}).trim,null,'Tiny holdings do not invent out-of-range whole-share trim');
for(const fields of [{entry:Infinity},{stop:100},{shares:1.5},{shares:0},{ema9:NaN},{confirmed:'true'},{close:null},{peak:-1},{trail:97},{ema:10}])rejects(()=>S.validate(holding(fields)),'Invalid holding values are rejected');
function createUI({denyStorage=false,raw=null}={}){
 const nodes=new Map(),listeners=new Map(),store=new Map(raw?[['martin-luk-standalone-offline-v1',raw]]:[]),timers=new Map();let clock=0,nextTimer=1;
 const clearNode=id=>{const element=nodes.get(id);if(!element)return;for(const child of element.childIds)clearNode(child);nodes.delete(id)};
 class Element{
  constructor(id){this.id=id;this.value='';this.checked=false;this.textContent='';this._html='';this.classList={toggle(){}};this.dataset={};this.attributes={};this.childIds=[]}
  setAttribute(key,value){this.attributes[key]=String(value)}getAttribute(key){return this.attributes[key]??null}removeAttribute(key){delete this.attributes[key]}
  closest(selector){return this.dataset.act&&(selector==='[data-act]'||selector==='[data-act="stock-pick"]'&&this.dataset.act==='stock-pick')?this:null}
  set innerHTML(html){for(const id of this.childIds)clearNode(id);this.childIds=[];this._html=html;for(const tag of html.matchAll(/<(input|select|div|form|p|button)\b([^>]+)>/g)){let match=tag[2].match(/\bid="([^"]+)"/);if(!match)continue;let child=new Element(match[1]);for(const attr of tag[2].matchAll(/([\w-]+)="([^"]*)"/g)){child.setAttribute(attr[1],attr[2]);if(attr[1].startsWith('data-'))child.dataset[attr[1].slice(5)]=attr[2]}child.value=tag[2].match(/\bvalue="([^"]*)"/)?.[1]??'';child.checked=/\bchecked\b/.test(tag[2]);if(tag[1]==='select'){let rest=html.slice(tag.index+tag[0].length),options=rest.slice(0,rest.indexOf('</select>')),all=[...options.matchAll(/<option\b([^>]+)>/g)],selected=all.find(o=>/\bselected\b/.test(o[1]))||all[0];child.value=selected?.[1].match(/\bvalue="([^"]*)"/)?.[1]??''}nodes.set(child.id,child);this.childIds.push(child.id)}}
  get innerHTML(){return this._html}
 }
 for(const id of ['status','market','content','stocks-master'])nodes.set(id,new Element(id));
 nodes.get('stocks-master').textContent=block('stocks-master');
 const nav=['recommend','portfolio','settings'].map(value=>{let element=new Element(value);element.dataset.value=value;return element});
 const document={getElementById(id){return nodes.get(id)||null},querySelectorAll(){return nav},addEventListener(name,fn){listeners.set(name,fn)},body:{classList:{toggle(){}}}};
 const uiContext=vm.createContext({console,document,confirm:()=>true,setTimeout(fn,delay){const id=nextTimer++;timers.set(id,{fn,at:clock+delay});return id},clearTimeout(id){timers.delete(id)},localStorage:{getItem(k){if(denyStorage)throw Error('Denied');return store.get(k)||null},setItem(k,v){if(denyStorage)throw Error('Denied');store.set(k,v)}}});
 vm.runInContext(block('stock-search-core'),uiContext);vm.runInContext(block('standalone-core'),uiContext);vm.runInContext(block('standalone-ui'),uiContext);
 return {nodes,html:()=>nodes.get('content').innerHTML,state:()=>JSON.parse(store.get('martin-luk-standalone-offline-v1')||'null'),click(act,value,extra={}){let target={dataset:{act,value,...extra},closest(){return this}};listeners.get('click')({target})},value(id,value){nodes.get(id).value=String(value)},checked(id,value){nodes.get(id).checked=value},input(id){listeners.get('input')({target:nodes.get(id)})},change(id){listeners.get('change')({target:nodes.get(id)})},key(id,key){let prevented=false;listeners.get('keydown')({target:nodes.get(id),key,preventDefault(){prevented=true}});return prevented},advance(ms){const end=clock+ms;while(true){const entry=[...timers.entries()].filter(([,t])=>t.at<=end).sort((a,b)=>a[1].at-b[1].at)[0];if(!entry)break;timers.delete(entry[0]);clock=entry[1].at;entry[1].fn()}clock=end},submit(id){listeners.get('submit')({target:{id},preventDefault(){}})}};
}
const metadata=JSON.parse(block('stocks-master'));
check(metadata.filter(s=>s.market==='US').length>=100,'At least 100 US identities are embedded for offline search');
check(metadata.filter(s=>s.market==='TW').length>=100,'At least 100 TW identities are embedded for offline search');
const searchUI=createUI();
check(searchUI.html().includes('智慧股票搜尋'),'Recommendation list has a shared cross-market search bar');
searchUI.value('stock-query','nvda');searchUI.input('stock-query');searchUI.advance(199);
equal(searchUI.nodes.get('stock-results').innerHTML,'','Autocomplete does not run before its 200 ms debounce');
searchUI.advance(1);
check(searchUI.nodes.get('stock-results').innerHTML.includes('NVDA'),'Lowercase US symbol resolves offline');
check(searchUI.nodes.get('stock-results').innerHTML.includes('NVIDIA'),'Dropdown includes the English company name');
check(searchUI.nodes.get('stock-results').innerHTML.includes('輝達'),'Dropdown includes the Chinese company name');
equal(searchUI.nodes.get('stock-query').getAttribute('aria-expanded'),'true','Populated suggestions update combobox ARIA');
check(searchUI.key('stock-query','ArrowDown'),'Arrow key prevents page scrolling');
equal(searchUI.nodes.get('stock-query').getAttribute('aria-activedescendant'),'stock-option-0','Keyboard highlights the first suggestion');
check(searchUI.key('stock-query','Enter'),'Enter selects a suggestion without submitting an unrelated form');
check(searchUI.html().includes('NVDA')&&searchUI.html().includes('美股帳戶總資金'),'Cross-market recommendation selection opens the correct US Calculator');
equal(Number(searchUI.nodes.get('capital').value),50000,'US selection automatically uses its independent USD capital');
searchUI.click('nav','recommend');
for(const query of ['台積電','2330','2330.TW','TSMC']){searchUI.value('stock-query',query);searchUI.input('stock-query');searchUI.advance(200);equal(searchUI.nodes.get('stock-option-0').dataset.symbol,'2330.TW',`${query} ranks the standard Taiwan identity first`)}
searchUI.click('stock-pick',null,{market:'TW',symbol:'2330.TW'});
equal(Number(searchUI.nodes.get('capital').value),1000000,'Taiwan selection restores TWD capital, without currency mixing');
searchUI.click('nav','recommend');
for(const query of ['輝達','Nvidia','NVDA','特斯拉']){searchUI.value('stock-query',query);searchUI.input('stock-query');searchUI.advance(200);equal(searchUI.nodes.get('stock-option-0').dataset.symbol,query==='特斯拉'?'TSLA':'NVDA',`${query} resolves through the embedded names and aliases`)}
searchUI.value('stock-query','NV');searchUI.input('stock-query');searchUI.advance(100);searchUI.value('stock-query','特斯拉');searchUI.input('stock-query');searchUI.advance(100);
equal(searchUI.nodes.get('stock-results').innerHTML,'','A later query cancels an earlier debounce');
searchUI.advance(100);equal(searchUI.nodes.get('stock-option-0').dataset.symbol,'TSLA','Only the latest debounce query produces suggestions');
check(searchUI.key('stock-query','Escape'),'Escape closes the list');equal(searchUI.nodes.get('stock-results').innerHTML,'','Escape clears stale suggestions');
equal(searchUI.nodes.get('stock-query').getAttribute('aria-expanded'),'false','Closed list has the correct ARIA state');
searchUI.value('stock-query','a');searchUI.input('stock-query');searchUI.advance(200);
check((searchUI.nodes.get('stock-results').innerHTML.match(/role="option"/g)||[]).length<=8,'Dropdown is capped at eight matches');
searchUI.key('stock-query','ArrowUp');check(searchUI.nodes.get('stock-query').getAttribute('aria-activedescendant'),'Up-arrow wraps to the last available result');
searchUI.value('stock-query','totally-unmatched-999999');searchUI.input('stock-query');searchUI.advance(200);
check(searchUI.nodes.get('stock-results').innerHTML.includes('ALL'),'Reverse substring matching recognizes ALL inside totally');
searchUI.value('stock-query','zxqv999999zxqv');searchUI.input('stock-query');searchUI.advance(200);
check(searchUI.nodes.get('stock-results').innerHTML.includes('找不到'),'Unknown keywords show a clear empty result');
searchUI.value('stock-query','NVDA');searchUI.input('stock-query');searchUI.click('nav','settings');searchUI.advance(500);
check(searchUI.html().includes('離線設定'),'Navigating cancels pending searches without rebuilding a detached dropdown');
searchUI.click('nav','recommend');searchUI.value('stock-query','AAPL');searchUI.input('stock-query');searchUI.advance(200);searchUI.key('stock-query','Enter');
equal(searchUI.nodes.get('h-symbol').value,'AAPL','Identity-only stock selection fills a canonical holding symbol');
equal(searchUI.nodes.get('h-market').value,'us','Identity-only selection fills its actual market');
equal(searchUI.nodes.get('h-price').value,'','An identity never fabricates a mock market price');
equal(searchUI.nodes.get('h-ema9').value,'','An identity never fabricates EMA indicators');
check(searchUI.html().includes('沒有符合門檻的示範推薦'),'Missing quote/signal is explicitly distinguished from identity lookup');
searchUI.value('h-price',100);searchUI.value('h-ema9',99);searchUI.checked('h-confirmed',true);
searchUI.value('h-symbol','台積電');searchUI.input('h-symbol');searchUI.advance(200);searchUI.key('h-symbol','Enter');
equal(searchUI.nodes.get('h-symbol').value,'2330.TW','Holding autocomplete converts a Chinese name to the standard symbol');
equal(searchUI.nodes.get('h-market').value,'tw','Holding autocomplete changes the form to the selected market');
equal(searchUI.nodes.get('h-name').value,'台積電','Holding autocomplete fills the Chinese display name');
equal(searchUI.nodes.get('h-price').value,'','Changing holding identity clears the previous stock quote');
equal(searchUI.nodes.get('h-ema9').value,'','Changing holding identity clears the previous stock EMA');
equal(searchUI.nodes.get('h-confirmed').checked,false,'Changing identity does not reuse another stock confirmed close');
check(searchUI.nodes.get('identity-note').textContent.includes('行情已清空'),'The cleared quote and manual-entry requirement are visible');
for(const [key,value]of Object.entries({entry:100,stop:98,shares:100,price:106,ema9:104,ema21:102,ema50:90}))searchUI.value('h-'+key,value);
searchUI.input('h-price');
check(searchUI.nodes.get('draft').innerHTML.includes('曝險 1.06%'),'Holding diagnosis uses selected Taiwan capital instead of the previous USD account');
searchUI.value('h-symbol','brk.b');searchUI.input('h-symbol');searchUI.advance(200);searchUI.key('h-symbol','Enter');
equal(searchUI.nodes.get('h-symbol').value,'BRK-B','Punctuation-normalized share-class lookup fills the canonical quote symbol');
equal(searchUI.nodes.get('h-market').value,'us','US share-class selection restores the US form market');
const capitalUI=createUI();
capitalUI.click('nav','settings');
equal(Number(capitalUI.nodes.get('s-us').value),50000,'Settings default is US$50,000 USD');
equal(Number(capitalUI.nodes.get('s-tw').value),1000000,'Settings default is NT$1,000,000 TWD');
check(capitalUI.html().includes('美股帳戶總資金')&&capitalUI.html().includes('USD／US$'),'US Capital has an explicit native currency label');
check(capitalUI.html().includes('台股帳戶總資金')&&capitalUI.html().includes('TWD／NT$'),'TW Capital has an explicit native currency label');
capitalUI.click('market','us');capitalUI.click('calc','NVDA');
equal(Number(capitalUI.nodes.get('capital').value),50000,'US Calculator automatically seeds US Capital');
check(capitalUI.nodes.get('calculation').innerHTML.includes('US$250.00 USD'),'US default 0.5% risk budget is USD250');
check(capitalUI.nodes.get('calculation').innerHTML.includes('89 股'),'US default equity produces 89 NVDA whole shares');
capitalUI.value('capital',75000.5);capitalUI.input('capital');
equal(capitalUI.state().us,75000.5,'US Calculator saves cents without rounding');
equal(capitalUI.state().tw,1000000,'Changing US Capital never overwrites TW Capital');
capitalUI.click('market','tw');
check(capitalUI.html().includes('2330.TW')&&capitalUI.html().includes('台股帳戶總資金'),'Switch keeps Calculator open with a native TW stock');
equal(Number(capitalUI.nodes.get('capital').value),1000000,'TW switch automatically restores its own Capital');
check(capitalUI.nodes.get('calculation').innerHTML.includes('NT$5,000.00 TWD'),'TW default 0.5% risk budget is TWD5000');
check(capitalUI.nodes.get('calculation').innerHTML.includes('223 股'),'TW default equity produces 223 TSMC whole shares');
capitalUI.click('market','us');
equal(Number(capitalUI.nodes.get('capital').value),75000.5,'Returning to US restores the edited US Capital');
check(capitalUI.html().includes('NVDA'),'Market switching restores the US calculator stock');
capitalUI.click('nav','settings');capitalUI.value('s-us',120000);capitalUI.value('s-tw',2400000);capitalUI.submit('settings-form');
capitalUI.click('calc','NVDA');
equal(Number(capitalUI.nodes.get('capital').value),120000,'Calculator adopts the newly saved USD setting');
check(capitalUI.nodes.get('calculation').innerHTML.includes('US$600.00 USD'),'New USD setting supplies the matching USD risk budget');
check(capitalUI.nodes.get('calculation').innerHTML.includes('214 股'),'New USD setting changes shares from the proper risk amount');
capitalUI.click('market','tw');
equal(Number(capitalUI.nodes.get('capital').value),2400000,'TW switch adopts the newly saved TWD setting');
check(capitalUI.nodes.get('calculation').innerHTML.includes('NT$12,000.00 TWD'),'New TWD setting supplies the matching TWD risk budget');
check(capitalUI.nodes.get('calculation').innerHTML.includes('535 股'),'New TWD setting changes shares from the proper risk amount');
const capitalReload=createUI({raw:JSON.stringify(capitalUI.state())});
capitalReload.click('calc','2330.TW');
equal(Number(capitalReload.nodes.get('capital').value),2400000,'Reload preserves independent TW Capital');
capitalReload.click('market','us');
equal(Number(capitalReload.nodes.get('capital').value),120000,'Reload preserves independent US Capital');
const ui=createUI();check(ui.html().includes('2330.TW'),'TW recommendation renders on first open');ui.click('market','us');check(ui.html().includes('NVDA'),'US switch renders US fixtures');ui.click('calc','NVDA');check(ui.html().includes('0.5%')||ui.html().includes('風險預算 0.5%'),'Calculator explains risk budget');ui.value('capital',100000);ui.input('capital');check(ui.nodes.get('calculation').innerHTML.includes('178'),'Calculator updates whole shares from new equity');ui.value('capital',0);ui.input('capital');check(ui.nodes.get('calculation').innerHTML.includes('error'),'Invalid equity clears stale calculation');ui.click('nav','portfolio');check(ui.html().includes('NVDA')&&ui.html().includes('TSLA'),'Portfolio shows both US examples');check(ui.html().includes('建議移動停損出場'),'Weakness fixture gives clear exit advice');
ui.click('add');for(const [id,value]of Object.entries({'h-market':'us','h-symbol':'AMD','h-name':'AMD','h-entry':100,'h-stop':98,'h-shares':100,'h-price':106,'h-ema9':104,'h-ema21':102,'h-ema50':90,'h-close':106}))ui.value(id,value);ui.checked('h-confirmed',true);ui.input('h-price');check(ui.nodes.get('draft').innerHTML.includes('達到 3R'),'Manual quote changes show immediate 3R advice');ui.submit('holding-form');let newHolding=ui.state().holdings.find(h=>h.symbol==='AMD');check(newHolding,'CRUD adds an unknown symbol only from supplied manual values');equal(newHolding.peak,3,'Committed observation persists peak R');equal(newHolding.trail,100,'Committed observation persists breakeven');
ui.click('edit','us:AMD');ui.value('h-price',103);ui.value('h-close',103);ui.value('h-ema9',102);ui.input('h-price');check(ui.nodes.get('draft').innerHTML.includes('100.00'),'Pullback preview keeps existing breakeven');ui.submit('holding-form');equal(ui.state().holdings.find(h=>h.symbol==='AMD').peak,3,'Editing quote retains observed peak');
ui.click('edit','us:AMD');ui.value('h-entry',110);ui.value('h-stop',108);ui.value('h-price',111);ui.value('h-close',111);ui.value('h-ema9',110);ui.submit('holding-form');newHolding=ui.state().holdings.find(h=>h.symbol==='AMD');equal(newHolding.peak,.5,'Changed risk basis resets old R history');equal(newHolding.trail,108,'Changed risk basis resets old floating stop');
ui.click('edit','us:AMD');ui.value('h-shares',1.5);ui.submit('holding-form');check(ui.nodes.get('draft').innerHTML.includes('正整數'),'Invalid draft rejects fractional shares');equal(ui.state().holdings.find(h=>h.symbol==='AMD').shares,100,'Invalid edit leaves saved shares unchanged');ui.click('nav','portfolio');ui.click('delete','us:AMD');check(!ui.state().holdings.some(h=>h.symbol==='AMD'),'CRUD deletes holding');
ui.click('nav','settings');ui.value('s-usAdr',9);ui.submit('settings-form');ui.click('nav','recommend');check(ui.html().includes('没有符合')||ui.html().includes('沒有符合'),'ADR setting filters all below-threshold fixtures');ui.click('nav','settings');ui.value('s-us',.01);ui.value('s-usAdr',5);ui.submit('settings-form');ui.click('nav','recommend');ui.value('sort','position');ui.change('sort');check(ui.html().includes('本金不足整股'),'Sorting remains usable with insufficient equity');
ui.click('nav','settings');ui.value('s-us',Number.MIN_VALUE);ui.submit('settings-form');ui.click('nav','portfolio');check(ui.html().includes('數值超出範圍'),'Overflowing finite inputs show per-card diagnostic errors');check(ui.html().includes('新增'),'A diagnostic overflow does not disable portfolio navigation');
for(const options of [{denyStorage:true},{raw:'{not valid JSON'},{raw:JSON.stringify({useMockData:false,apiBaseUrl:'unusable'})}]){const isolated=createUI(options);check(isolated.html().includes('2330.TW'),'Denied, corrupt or legacy API settings still allow offline preview');check(isolated.nodes.get('status').textContent.length>0,'Storage problem is visible');}
console.log(`Standalone offline HTML: ${checks} checks passed (production engine and UI handlers).`);
