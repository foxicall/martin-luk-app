#!/usr/bin/env node
// Runs the production inline portfolio engine and UI handlers without packages,
// a server, a browser or network. DOM doubles validate handlers, not rendering.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../preview/index.html'), 'utf8');
let checks = 0;
const check = (condition, description) => { assert.ok(condition, description); checks++; };
const equal = (actual, expected, description) => { assert.equal(actual, expected, description); checks++; };
const rejects = (fn, description) => { assert.throws(fn, undefined, description); checks++; };
const block = id => {
  const match = source.match(new RegExp(`<script id="${id}">([\\s\\S]*?)<\\/script>`));
  assert.ok(match, `Missing production script ${id}`);
  return match[1];
};
const engineContext = vm.createContext({console});
for (const id of ['strategy-core', 'portfolio-core']) vm.runInContext(block(id), engineContext, {filename:`${id}.js`});
const engine = engineContext.PortfolioCore;
const holding = overrides => ({market:'us',symbol:'NVDA',entry_price:100,initial_stop:98,shares:100,...overrides});
const quote = overrides => ({market:'us',symbol:'NVDA',name:'NVIDIA',source:'Test fixture',current_price:105,
  ema9:103,ema21:102,ema50:90,last_close:105,close_confirmed:true,is_large_liquid:true,
  quote_timestamp:'2026-10-13T06:00:00Z',close_timestamp:'2026-10-12T20:00:00Z',...overrides});
const diagnose = (h = {}, q = {}, equity = 100000, threshold = 20) => engine.diagnose(holding(h),quote(q),equity,threshold);
const reason = (result, code) => Array.from(result.reason_codes).includes(code);

function engineChecks() {
  equal(engine.symbolFor(' 2330 ', 'tw'),'2330.TW','Taiwan ordinary stock suffix normalized');
  equal(engine.symbolFor('brk-b','us'),'BRK-B','Yahoo US share-class symbol normalized');
  for (const symbol of ['2330.TWO','ABC.TW','9101-DR','../../2330']) rejects(()=>engine.symbolFor(symbol,'tw'),'Reject invalid or wrong-market Taiwan symbol');
  const initial = diagnose();
  equal(initial.current_r,2.5,'Known price 105, entry 100, stop 98 gives exactly 2.5R');
  equal(initial.unrealized_pnl,500,'100 shares times known gain 5 gives PnL 500');
  equal(initial.position_value,10500,'Position valuation uses current price');
  equal(initial.exposure_pct,10.5,'Exposure uses market-specific account equity');
  equal(initial.trailing_stop,100,'Observing 2R raises floating stop to cost');
  equal(initial.action,'hold','Below 3R with ordinary exposure holds');
  for (const [r,target] of [[1,102],[2,104],[3,106],[5,110],[10,120]]) equal(initial.targets[r],target,`Fixed initial-risk ${r}R target`);
  const after = diagnose({peak_r:2.5,trailing_stop:100},{current_price:103,last_close:103,ema9:102});
  equal(after.current_r,1.5,'Breakeven does not change initial 1R denominator');
  equal(after.peak_r,2.5,'Observed peak survives a pullback');
  equal(after.trailing_stop,100,'Pullback cannot move the floating stop down');
  equal(diagnose({}, {current_price:104,last_close:104}).trailing_stop,100,'Exactly 2R arms breakeven');
  equal(diagnose({}, {current_price:103.999,last_close:103.999}).trailing_stop,98,'Below 2R does not arm breakeven');
  for (const [price,code] of [[106,'target_3r'],[110,'target_5r'],[120,'target_10r']]) {
    const result = diagnose({}, {current_price:price,last_close:price,ema9:price-1});
    equal(result.action,'trim',`Exactly ${code} triggers strength trim`);
    check(reason(result,code),`Highest attained ${code} is reported`);
    equal(result.trim_shares,15,'100 shares trims 15 whole shares');
  }
  equal(diagnose({}, {current_price:105.999,last_close:105.999}).action,'hold','Below 3R is not a target trim');
  const euphoriaHolding = {entry_price:110,initial_stop:100};
  const euphoriaQuote = {current_price:120,last_close:120,ema9:100,ema21:95,ema50:90};
  equal(diagnose(euphoriaHolding,euphoriaQuote).action,'hold','Exactly 20% positive EMA deviation is not euphoria');
  const euphoric = diagnose(euphoriaHolding,{...euphoriaQuote,current_price:120.01,last_close:120.01});
  equal(euphoric.action,'trim','Strictly above 20% EMA deviation trims without R/exposure triggers');
  check(reason(euphoric,'euphoria'),'Euphoria reason is explicit');
  equal(diagnose(euphoriaHolding,{...euphoriaQuote,current_price:115,last_close:115},100000,15).action,'hold','Exactly custom 15% euphoria boundary holds');
  equal(diagnose(euphoriaHolding,{...euphoriaQuote,current_price:115.01,last_close:115.01},100000,15).action,'trim','Custom euphoria threshold is respected');
  const exposureQuote = {current_price:100,last_close:100,ema9:99,ema21:97};
  equal(diagnose({shares:350,initial_stop:95},exposureQuote).action,'hold','Exactly 35% exposure does not trigger growth trim');
  equal(diagnose({shares:351,initial_stop:95},exposureQuote).action,'trim','Above 35% exposure triggers growth trim');
  const small = diagnose({shares:260,initial_stop:95},{...exposureQuote,is_large_liquid:false});
  equal(small.exposure_cap_pct,25,'Other stocks have 25% exposure cap');
  check(small.over_exposure,'26% small-stock exposure is a cap warning');
  equal(small.action,'hold','A cap warning below 35% does not alone imply strength trim');
  check(!diagnose({shares:250,initial_stop:95},{...exposureQuote,is_large_liquid:false}).over_exposure,'Exactly 25% other-stock cap is accepted');
  const hard = diagnose({}, {current_price:98,last_close:98,ema9:80,ema21:79,ema50:78},1000);
  equal(hard.action,'exit','Hard stop takes precedence over euphoria and extreme exposure');
  check(reason(hard,'hard_stop')&&!reason(hard,'euphoria'),'Hard-stop advice does not mix in strength reasons');
  const be = diagnose({peak_r:4,trailing_stop:100}, {current_price:100,last_close:100,ema9:80,ema21:79,ema50:78},1000);
  equal(be.action,'exit','Price at armed breakeven stop exits');
  check(reason(be,'breakeven_stop'),'Breakeven stop reason is distinguished');
  const emaQuote = {current_price:103,last_close:103,ema9:104,ema21:102,ema50:90};
  equal(diagnose({},emaQuote).action,'exit','Confirmed close below 9 EMA exits');
  equal(diagnose({}, {...emaQuote,close_confirmed:false,last_close:null,close_timestamp:null}).action,'hold','Intraday EMA break is not a confirmed-close exit');
  equal(diagnose({}, {...emaQuote,last_close:104}).action,'hold','Close exactly on EMA does not trigger strict below rule');
  const trend = diagnose({main_uptrend:true,trailing_ema:21,peak_r:3},emaQuote);
  equal(trend.effective_trailing_ema,21,'Main uptrend and observed peak 3R unlock 21 EMA');
  equal(trend.action,'hold','Confirmed close above eligible 21 EMA holds despite 9 EMA break');
  equal(diagnose({main_uptrend:true,trailing_ema:50,peak_r:3},{...emaQuote,ema21:104,ema50:102}).effective_trailing_ema,50,'Eligible main uptrend can use 50 EMA');
  equal(diagnose({main_uptrend:true,trailing_ema:21,peak_r:2.99},emaQuote).effective_trailing_ema,9,'Main uptrend below 3R remains on 9 EMA');
  equal(diagnose({main_uptrend:false,trailing_ema:50,peak_r:3},emaQuote).effective_trailing_ema,9,'High peak alone does not unlock slower EMA');
  for (const shares of [7,20,101,999]) {
    const result = diagnose({shares},{current_price:106,last_close:106});
    check(Number.isSafeInteger(result.trim_shares)&&result.trim_shares/shares>=.1&&result.trim_shares/shares<=.15,'Whole-share trim remains in 10–15% range');
  }
  equal(diagnose({shares:6},{current_price:106,last_close:106}).trim_shares,null,'Tiny position with no valid whole-share trim remains advisory only');
  equal(diagnose({entry_price:10.1,initial_stop:10},{current_price:10.4,last_close:10.4,ema9:10.3,ema21:10.2,ema50:10.1}).current_r,3,'Decimal inputs preserve exact 3R boundary');
  const invalidHolding = [null,[],{shares:1.5},{shares:'100'},{shares:0},{shares:true},{shares:Number.MAX_SAFE_INTEGER+1},
    {entry_price:'100'},{entry_price:Infinity},{entry_price:NaN},{initial_stop:100},{initial_stop:0},
    {peak_r:-1},{peak_r:'2'},{trailing_stop:97},{trailing_ema:10},{main_uptrend:1},{id:''},{name:1}];
  for (const fields of invalidHolding) rejects(()=>engine.validateHolding(fields===null||Array.isArray(fields)?fields:holding(fields)),'Strict holding input validation');
  rejects(()=>engine.validateHoldings([holding(),holding({shares:5})]),'Duplicate market/symbol holdings rejected');
  rejects(()=>engine.validateHoldings([holding({id:'same'}),holding({symbol:'TSLA',id:'same'})]),'Duplicate holding IDs rejected');
  for (const fields of [{market:'tw'},{symbol:'nvda'},{current_price:'105'},{current_price:0},{ema9:NaN},{ema21:-1},
    {is_large_liquid:1},{close_confirmed:'false'},{last_close:null},{close_timestamp:null},{name:''},{source:''},
    {quote_timestamp:'2026-10-13T06:00:00'},{quote_timestamp:'2026-02-30T06:00:00Z'},
    {quote_timestamp:'2026-10-13T06:00:00+25:00'},{close_timestamp:'2026-10-13T07:00:00Z'}])
    rejects(()=>engine.validateQuote(quote(fields),'us'),'Strict quote values, timestamps and chronology validation');
  check(engine.validateQuote(quote({close_confirmed:false,last_close:null,close_timestamp:null}),'us').last_close===null,'Unconfirmed close may be absent');
  check(engine.validateQuote(quote({quote_timestamp:'2026-10-13T14:00:00+08:00'}),'us'),'Timezone-aware quote timestamp accepted');
  for (const equity of [0,-1,NaN,Infinity,'100000',true]) rejects(()=>engine.diagnose(holding(),quote(),equity),'Invalid account equity rejected');
  for (const threshold of [14.99,20.01,'20',null]) rejects(()=>diagnose({}, {},100000,threshold),'Invalid euphoria setting rejected');
  rejects(()=>diagnose({}, {symbol:'TSLA'}),'Wrong-symbol quote cannot diagnose holding');
  equal(engine.mockQuote('AAPL','us'),null,'Unknown symbol never receives invented mock prices');
  const snapshot = overrides => ({market:'us',source:'Fixture API',generated_at:'2026-10-13T06:00:00Z',quotes:[quote()],errors:{TSLA:'temporarily unavailable'},...overrides});
  check(engine.validateQuoteSnapshot(snapshot(),'us',['NVDA','TSLA']),'Partial API quotes with explicit errors accepted');
  for (const overrides of [{quotes:[quote(),quote()]},{errors:{NVDA:'conflict'}},{errors:{}},{errors:{TSLA:2}},
    {errors:{TSLA:''}},{generated_at:'2026-10-13T06:00:00'},{market:'tw'},{quotes:[quote({symbol:'AMD'})]}])
    rejects(()=>engine.validateQuoteSnapshot(snapshot(overrides),'us',['NVDA','TSLA']),'Malformed, incomplete or conflicting quote snapshot rejected');
  rejects(()=>engine.validateQuoteSnapshot(snapshot(),'us',['NVDA','NVDA']),'Duplicate requested quotes rejected');
}

function createUI({storageFailure=false,initialStorage={}} = {}) {
  const nodes = new Map(), listeners = new Map(), storage = new Map(Object.entries(initialStorage)), calls = [], classes = new Set();
  let responder = async () => {throw new TypeError('Fixture API unavailable');};
  let clock=0,nextTimer=1;const timers=new Map();
  const advanceTime=milliseconds=>{const end=clock+milliseconds;while(true){const due=[...timers].filter(([,t])=>t.at<=end).sort((a,b)=>a[1].at-b[1].at||a[0]-b[0])[0];if(!due)break;clock=due[1].at;timers.delete(due[0]);due[1].callback();}clock=end;};
  class Element {
    constructor(id) {this.id=id;this.value='';this.checked=false;this.textContent='';this.scrollTop=0;this.handlers=new Map();this._html='';this.attributes=new Map();this.hidden=false;}
    set innerHTML(value) {
      this._html=value;
      for (const tag of value.matchAll(/<(input|div|form|p|select|button)\b([^>]+)>/g)) {
        const id=tag[2].match(/\bid="([^"]+)"/);if(!id)continue;
        const child=new Element(id[1]);child.value=tag[2].match(/\bvalue="([^"]*)"/)?.[1]??'';child.checked=/\bchecked\b/.test(tag[2]);
        if(tag[1]==='select') {
          const rest=value.slice(tag.index+tag[0].length), options=rest.slice(0,rest.indexOf('</select>'));
          const selected=[...options.matchAll(/<option\b([^>]+)>/g)].find(m=>/\bselected\b/.test(m[1])) || [...options.matchAll(/<option\b([^>]+)>/g)][0];
          child.value=selected?.[1].match(/\bvalue="([^"]*)"/)?.[1]??'';
        }
        nodes.set(child.id,child);
      }
    }
    get innerHTML(){return this._html;}
    addEventListener(name,handler){this.handlers.set(name,handler);}
    setAttribute(name,value){this.attributes.set(name,String(value));}
    removeAttribute(name){this.attributes.delete(name);}
    getAttribute(name){return this.attributes.get(name)??null;}
  }
  for(const id of ['header','content','nav','scroll','force-mock','toast'])nodes.set(id,new Element(id));
  const metadata=new Element('stocks-master');metadata.textContent=source.match(/<script id="stocks-master" type="application\/json">([\s\S]*?)<\/script>/)[1];nodes.set(metadata.id,metadata);
  const document={querySelector(selector){const node=nodes.get(selector.slice(1));if(!node)throw new Error(`Absent DOM element ${selector}`);return node;},
    addEventListener(name,handler){listeners.set(name,handler);},body:{classList:{toggle(name,on){if(on)classes.add(name);else classes.delete(name);}}}};
  const context=vm.createContext({document,console,URL,URLSearchParams,AbortController,location:{search:''},
    localStorage:{getItem(key){if(storageFailure)throw new Error('Storage denied');return storage.get(key)??null;},setItem(key,value){if(storageFailure)throw new Error('Storage denied');storage.set(key,value);}},
    setTimeout:(callback,delay=0)=>{const id=nextTimer++;timers.set(id,{callback,at:clock+Number(delay)});return id;},clearTimeout:id=>timers.delete(id),fetch:async(url,options)=>{calls.push({url,options});return responder(url,options);}});
  for(const id of ['strategy-core','portfolio-core','stock-search-core','preview-ui'])vm.runInContext(block(id),context,{filename:`${id}.js`});
  const tick=()=>new Promise(resolve=>setImmediate(resolve));
  return {nodes,listeners,storage,calls,context,advanceTime,setResponder(fn){responder=fn;},html:()=>nodes.get('content').innerHTML,
    cards:()=>nodes.get('portfolio-cards')?.innerHTML??'',value(id,value){nodes.get(id).value=String(value);},checked(id,value){nodes.get(id).checked=value;},
    savedStore:()=>JSON.parse(storage.get('martin-luk-portfolio-v1')||'[]'),
    savedHoldings:()=>{const value=JSON.parse(storage.get('martin-luk-portfolio-v1')||'[]');return Array.isArray(value)?value:value.positions;},
    async click(action,id,value,owner){const target={disabled:false,dataset:{action,id,value,owner},closest:()=>target};listeners.get('click')({target});await tick();},
    async submit(id){await nodes.get(id).handlers.get('submit')({preventDefault(){}});await tick();},
    async input(id,event='input'){await nodes.get(id).handlers.get(event)();await tick();}};
}

async function uiChecks() {
  const ui=createUI();
  check(ui.nodes.get('nav').innerHTML.includes('data-action="portfolio"')&&((ui.nodes.get('nav').innerHTML.match(/<button/g)||[]).length===3),'Three bottom navigation destinations include Portfolio');
  equal(ui.calls.length,0,'Default initialization performs no network request');
  await ui.click('portfolio');await ui.click('holding-new');
  const stockInput=ui.nodes.get('holding-symbol');
  stockInput.value='輝達';await ui.input('holding-symbol');ui.advanceTime(199);
  equal(ui.nodes.get('holding-stock-results').innerHTML,'','Holding autocomplete waits for debounce');
  ui.advanceTime(1);
  check(ui.nodes.get('holding-stock-results').innerHTML.includes('NVDA')&&ui.nodes.get('holding-stock-results').innerHTML.includes('NVIDIA'),'Holding form suggests Chinese and English US identity');
  let keepHoldingFocus=false;
  const holdingOption={closest:selector=>selector==='[data-action="stock-select"]'?holdingOption:null};
  ui.listeners.get('mousedown')({target:holdingOption,preventDefault(){keepHoldingFocus=true;}});
  if(!keepHoldingFocus)stockInput.handlers.get('blur')();
  ui.advanceTime(250);
  check(keepHoldingFocus&&ui.nodes.get('holding-stock-results').innerHTML.includes('NVDA'),
    'Holding suggestion remains clickable during a long mouse press');
  await ui.click('stock-select',undefined,'0','holding-symbol');
  equal(ui.nodes.get('holding-symbol').value,'NVDA','Holding selection fills canonical symbol');
  equal(ui.nodes.get('holding-market').value,'us','Holding selection automatically fills corresponding market');
  equal(ui.nodes.get('holding-name').value,'輝達','Holding selection fills display name');
  equal(ui.nodes.get('holding-entry').value,'','Stock identity never invents cost price');
  stockInput.value='TSMC';await ui.input('holding-symbol');ui.advanceTime(200);
  await ui.click('stock-select',undefined,'0','holding-symbol');
  equal(ui.nodes.get('holding-symbol').value,'2330.TW','English TW abbreviation fills .TW symbol');
  equal(ui.nodes.get('holding-market').value,'tw','English TW abbreviation corrects market dropdown');
  stockInput.value='NVDA';await ui.input('holding-symbol');ui.advanceTime(200);
  stockInput.handlers.get('keydown')({key:'Escape',preventDefault(){}});
  check(ui.nodes.get('holding-stock-results').hidden&&stockInput.getAttribute('aria-expanded')==='false','Escape closes accessible holding suggestions');
  stockInput.value='zzzzzzzzzz';await ui.input('holding-symbol');ui.advanceTime(200);
  check(ui.nodes.get('holding-stock-results').innerHTML.includes('未找到'),'Unknown metadata input explains no result without API request');
  equal(ui.calls.length,0,'Holding autocomplete does not contact a network');
  await ui.click('portfolio');
  await ui.click('portfolio');
  check(ui.cards().includes('2330.TW')&&ui.cards().includes('3017.TW'),'Taiwan demo holdings display');
  check(ui.cards().includes('達到 3R')&&ui.cards().includes('全數平倉'),'Initial TW fixture demonstrates trim and exit');
  for(const r of [1,2,3,5,10])check(ui.cards().includes(`<b>${r}R</b>`),`UI displays ${r}R target price`);
  let saved=ui.savedHoldings().find(h=>h.symbol==='2330.TW');
  equal(saved.peak_r,3,'Viewing current TW price persists observed 3R peak');
  equal(saved.trailing_stop,1060,'Viewing current TW price persists breakeven stop');
  await ui.click('holding-edit','tw:2330.TW');ui.value('holding-shares',121);await ui.submit('holding-form');
  saved=ui.savedHoldings().find(h=>h.symbol==='2330.TW');
  equal(saved.shares,121,'Share-only edit is saved');equal(saved.peak_r,3,'Share-only edit retains peak');equal(saved.trailing_stop,1060,'Share-only edit retains stop');
  await ui.click('holding-edit','tw:2330.TW');ui.value('holding-entry',1110);ui.value('holding-stop',1090);await ui.submit('holding-form');
  saved=ui.savedHoldings().find(h=>h.symbol==='2330.TW');
  equal(saved.peak_r,.5,'Changing cost resets peak before re-observing current price');equal(saved.trailing_stop,1090,'Changed cost/stop resets floating stop to new basis');
  await ui.click('holding-edit','tw:2330.TW');ui.value('holding-entry',1060);ui.value('holding-stop',1040);await ui.submit('holding-form');
  saved=ui.savedHoldings().find(h=>h.symbol==='2330.TW');equal(saved.peak_r,3,'Revised basis can immediately observe a fresh 3R');equal(saved.trailing_stop,1060,'Fresh observed 3R re-arms breakeven');
  await ui.click('holding-new');ui.value('holding-symbol','2330');ui.value('holding-entry',1060);ui.value('holding-shares',10);ui.value('holding-stop',1040);await ui.submit('holding-form');
  check(ui.nodes.get('holding-error').textContent.length>0,'Duplicate holding submission is blocked');equal(ui.savedHoldings().length,4,'Duplicate did not mutate holdings');
  await ui.click('portfolio');await ui.click('holding-new');ui.value('holding-symbol','9999');ui.value('holding-entry',100);ui.value('holding-shares',50);ui.value('holding-stop',98);await ui.submit('holding-form');
  check(ui.cards().includes('9999.TW')&&ui.cards().includes('沒有固定假資料'),'Unknown holding is saved without invented quote');
  await ui.click('holding-edit','tw:9999.TW');ui.value('holding-market','us');ui.value('holding-symbol','aapl');ui.value('holding-entry',200);ui.value('holding-stop',196);ui.value('holding-shares',15);await ui.submit('holding-form');
  saved=ui.savedHoldings().find(h=>h.symbol==='AAPL');check(saved&&saved.market==='us'&&saved.entry_price===200&&saved.initial_stop===196&&saved.shares===15,'Symbol, market, cost, shares and stop edit saved');
  check(!ui.savedHoldings().some(h=>h.symbol==='9999.TW'),'Symbol edit removes preceding stock row');
  check(ui.cards().includes('NVDA')&&ui.cards().includes('TSLA')&&ui.cards().includes('AAPL'),'US tab displays own saved and fixture holdings');
  await ui.click('holding-delete-confirm','us:AAPL');check(ui.savedHoldings().some(h=>h.symbol==='AAPL'),'Delete-confirm without pending request cannot delete');
  await ui.click('holding-delete','us:AAPL');check(ui.cards().includes('確定刪除')&&ui.savedHoldings().some(h=>h.symbol==='AAPL'),'First delete click requests confirmation');
  await ui.click('holding-delete-cancel');check(ui.savedHoldings().some(h=>h.symbol==='AAPL'),'Delete cancellation keeps holding');
  await ui.click('holding-delete','us:AAPL');await ui.click('holding-delete-confirm','us:AAPL');check(!ui.savedHoldings().some(h=>h.symbol==='AAPL'),'Second confirmed deletion persists removal');
  await ui.click('market',undefined,'tw');await ui.click('quote-edit','tw:2330.TW');
  ui.value('quote-price',1080);ui.value('quote-close',1080);ui.value('quote-ema9',1090);ui.value('quote-ema21',1070);ui.value('quote-ema50',1000);ui.checked('quote-confirmed',false);await ui.input('quote-form');
  check(ui.nodes.get('quote-diagnosis').innerHTML.includes('持有')&&!ui.nodes.get('quote-diagnosis').innerHTML.includes('建議全數平倉'),'Live price editing below 9 EMA with unconfirmed close holds');
  ui.checked('quote-confirmed',true);await ui.input('quote-form');check(ui.nodes.get('quote-diagnosis').innerHTML.includes('收盤跌破 9 EMA'),'Confirming same close produces immediate EMA exit');
  ui.value('quote-price',0);await ui.input('quote-form');equal(ui.nodes.get('quote-diagnosis').innerHTML,'','Invalid quote clears last successful advice');check(ui.nodes.get('quote-error').textContent.length>0,'Invalid quote explains validation problem');
  ui.value('quote-price',1080);ui.checked('quote-confirmed',false);await ui.submit('quote-form');
  equal(JSON.parse(ui.storage.get('martin-luk-mock-quotes-v1'))['tw:2330.TW'].current_price,1080,'Manual mock price is persisted');
  check(ui.cards().includes('1,080.00'),'Saved fake price appears on holding card');
  ui.value('portfolio-equity',0);await ui.input('portfolio-equity');equal(ui.cards(),'','Invalid portfolio equity suspends previous diagnosis');
  ui.value('portfolio-equity',1000000);await ui.input('portfolio-equity');check(ui.cards().includes('2330.TW'),'Valid equity restores portfolio advice');
  equal(ui.calls.length,0,'All mock CRUD, edits, calculations and tab changes remain network-free');

  // Explicit API mode is the only case in which the production handlers fetch.
  await ui.click('settings');ui.checked('setting-mock',false);ui.value('setting-api','http://localhost:8000');await ui.submit('settings-form');
  await ui.click('portfolio');
  check(ui.calls.some(call=>new URL(call.url).pathname==='/v1/quotes'),'Portfolio API mode fetches /v1/quotes');
  const call=ui.calls.find(call=>new URL(call.url).pathname==='/v1/quotes');
  equal(call.options.headers.Accept,'application/json','Quote API requests JSON');
  equal(new URL(call.url).searchParams.get('market'),'tw','Quote API request includes current market');
  equal(new URL(call.url).searchParams.get('symbols').split(',').sort().join(','),'2330.TW,3017.TW','Quote request contains precisely current holdings');
  check(ui.html().includes('沒有以假資料取代 API'),'API error explains no mock fallback');
  check(!ui.cards().includes('exitbadge'),'API failure never shows prior mock diagnostics');
  saved=ui.savedHoldings().find(h=>h.symbol==='2330.TW');
  equal(saved.peak_r,0,'Entering live mode does not copy mock 3R observation');
  equal(saved.trailing_stop,1040,'Entering live mode does not copy mock breakeven stop');
  equal(ui.savedStore().schema,2,'Portfolio source histories have a versioned schema');
  ui.setResponder(async()=>({ok:true,status:200,json:async()=>({market:'tw',source:'API test fixture',generated_at:'2026-10-13T06:00:00Z',
    quotes:[{...quote({symbol:'2330.TW',market:'tw',current_price:1080,last_close:1080,ema9:1070,ema21:1060,ema50:1040,source:'API fixture'}),close_timestamp:'2026-10-13T05:30:00Z'}],errors:{'3017.TW':'provider data unavailable'}})}));
  await ui.click('portfolio-refresh');
  check(ui.cards().includes('1,080.00')&&ui.cards().includes('API fixture'),'Valid API quote drives corresponding diagnosis');
  check(ui.cards().includes('provider data unavailable'),'Partial API result displays explicit per-stock error');
  equal((ui.cards().match(/class="exitbadge/g)||[]).length,1,'Only successfully quoted holding receives diagnosis');
  saved=ui.savedHoldings().find(h=>h.symbol==='2330.TW');equal(saved.peak_r,1,'Live observations measure actual API price independently');equal(saved.trailing_stop,1040,'Live observation below 2R retains initial stop');
  ui.setResponder(async()=>({ok:true,status:200,json:async()=>({market:'tw',source:'API fixture',generated_at:'2026-10-13T06:00:00Z',quotes:[],errors:{}})}));
  await ui.click('portfolio-refresh');check(!ui.cards().includes('exitbadge')&&ui.html().includes('未完整回覆'),'Missing requested quotes invalidate snapshot and clear previous diagnostics');
  let resolvePending;
  ui.setResponder(()=>new Promise(resolve=>{resolvePending=resolve;}));
  await ui.click('portfolio-refresh');check(typeof resolvePending==='function','Quote request can remain pending during source switch');
  await ui.click('reset-mock');await ui.click('portfolio');
  saved=ui.savedHoldings().find(h=>h.symbol==='2330.TW');equal(saved.peak_r,3,'Returning to mock restores mock observed peak');equal(saved.trailing_stop,1060,'Returning to mock restores mock floating stop');
  resolvePending({ok:true,status:200,json:async()=>({market:'tw',source:'Stale API request',generated_at:'2026-10-13T06:00:00Z',
    quotes:[quote({market:'tw',symbol:'2330.TW',current_price:2000,last_close:2000,ema9:1900,ema21:1800,ema50:1700,source:'Stale API request'})],errors:{'3017.TW':'old request'}})});
  await new Promise(resolve=>setImmediate(resolve));
  check(ui.cards().includes('1,080.00')&&!ui.cards().includes('Stale API request'),'Late live request cannot overwrite mock cards');
  equal(ui.savedHoldings().find(h=>h.symbol==='2330.TW').peak_r,3,'Late live response cannot contaminate mock risk history');
  ui.setResponder(async()=>{throw new TypeError('New API unavailable');});
  await ui.click('settings');ui.checked('setting-mock',false);ui.value('setting-api','https://new.example.test');await ui.submit('settings-form');await ui.click('portfolio');
  saved=ui.savedHoldings().find(h=>h.symbol==='2330.TW');equal(saved.peak_r,0,'A different API base URL starts a distinct observation history');equal(saved.trailing_stop,1040,'A different API base URL does not reuse either prior source stop');
  await ui.click('settings');ui.value('setting-api','http://localhost:8000');await ui.submit('settings-form');await ui.click('portfolio');
  saved=ui.savedHoldings().find(h=>h.symbol==='2330.TW');equal(saved.peak_r,1,'Returning to original API source restores that source observed peak');equal(saved.trailing_stop,1040,'Original API stop remains independent from mock breakeven');
  await ui.click('reset-mock');await ui.click('portfolio');await ui.click('holding-edit','tw:2330.TW');ui.value('holding-entry',1110);ui.value('holding-stop',1090);await ui.submit('holding-form');
  await ui.click('settings');ui.checked('setting-mock',false);await ui.submit('settings-form');await ui.click('portfolio');
  saved=ui.savedHoldings().find(h=>h.symbol==='2330.TW');equal(saved.peak_r,0,'Changing cost invalidates stale observation basis across all sources');equal(saved.trailing_stop,1090,'Changed risk basis uses new stop in other sources');
  // Exercise the API's 50-symbol limit with actual production batching. Legacy
  // observed peaks are simulation history and cannot migrate into live history.
  const batchHoldings=Array.from({length:52},(_,index)=>holding({market:'tw',symbol:`${1000+index}.TW`,peak_r:5,trailing_stop:100}));
  const batched=createUI({initialStorage:{'martin-luk-html-preview-v1':JSON.stringify({useMockData:false}),
    'martin-luk-portfolio-v1':JSON.stringify(batchHoldings)}});
  batched.setResponder(async url=>{
    const requested=new URL(url),symbols=requested.searchParams.get('symbols').split(',');
    return {ok:true,status:200,json:async()=>({market:'tw',source:'test-live',generated_at:'2026-10-13T06:00:00Z',
      quotes:symbols.map(symbol=>quote({market:'tw',symbol,source:'test-live'})),errors:{}})};
  });
  await batched.click('portfolio');
  const batchCalls=batched.calls.filter(call=>new URL(call.url).pathname==='/v1/quotes');
  equal(batchCalls.length,2,'52 holdings produce two quote API requests');
  equal(new URL(batchCalls[0].url).searchParams.get('symbols').split(',').length,50,'First request respects 50-symbol limit');
  equal(new URL(batchCalls[1].url).searchParams.get('symbols').split(',').length,2,'Second request contains remaining holdings');
  equal((batched.cards().match(/class="exitbadge/g)||[]).length,52,'Both valid batches merge into 52 portfolio diagnoses');
  check(batched.savedHoldings().every(h=>h.peak_r===2.5),'Legacy mock 5R peaks never become live observed peaks');
  await batched.click('reset-mock');await batched.click('portfolio');
  check(batched.savedHoldings().every(h=>h.peak_r===5),'Legacy mock history remains available when returning to mock');
  await batched.click('settings');batched.checked('setting-mock',false);await batched.submit('settings-form');
  batched.setResponder(async url=>({ok:true,status:200,json:async()=>({market:'tw',source:'offline mock',generated_at:'2026-10-13T06:00:00Z',
    quotes:new URL(url).searchParams.get('symbols').split(',').map(symbol=>quote({market:'tw',symbol,source:'test-live'})),errors:{}})}));
  await batched.click('portfolio');
  check(batched.html().includes('收到示範行情')&&!batched.cards().includes('exitbadge'),'Live mode rejects explicitly labeled mock API snapshots');
  const denied=createUI({storageFailure:true});await denied.click('portfolio');
  check(denied.cards().includes('2330.TW')&&(/儲存庫存|本機庫存未能讀取/.test(denied.html())),'Storage restrictions keep demo usable and explain persistence limits');
  await denied.click('holding-edit','tw:2330.TW');denied.value('holding-shares',125);await denied.submit('holding-form');
  check(denied.cards().includes('125 股'),'Storage write restriction still permits session edits');equal(denied.calls.length,0,'Storage restrictions do not cause network fallback');
}

(async()=>{
  engineChecks();await uiChecks();
  console.log(`${checks} portfolio checks passed: exact risk math, stop priority, R targets, exposure, confirmed-close EMA, strict input/API validation, holdings CRUD, live mock edits, offline autocomplete and storage.`);
})().catch(error=>{console.error(error);process.exitCode=1;});
