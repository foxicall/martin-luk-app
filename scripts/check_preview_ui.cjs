#!/usr/bin/env node
// Executes the actual preview UI handlers with a small DOM test double.
// No browser, Flutter, server, npm packages, or network is required.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../preview/index.html'), 'utf8');
const nodes = new Map();
const listeners = new Map();
const classes = new Set();
const storage = new Map();
let networkCalls = 0;
let checks = 0;
let clock = 0, nextTimer = 1;
const timers = new Map();
function advanceTime(milliseconds) {
  const end = clock + milliseconds;
  while (true) {
    const due = [...timers].filter(([, timer]) => timer.at <= end).sort((a,b) => a[1].at-b[1].at || a[0]-b[0])[0];
    if (!due) break;
    clock = due[1].at; timers.delete(due[0]); due[1].callback();
  }
  clock = end;
}
let responseHandler = async () => { throw new TypeError('Test API unavailable'); };

class Element {
  constructor(id) {
    this.id = id;
    this.value = '';
    this.checked = false;
    this.textContent = '';
    this.scrollTop = 0;
    this.handlers = new Map();
    this._html = '';
    this.attributes = new Map();
    this.hidden = false;
  }
  set innerHTML(value) {
    this._html = value;
    for (const tag of value.matchAll(/<(?:input|div|form|p|select|button)\b([^>]+)>/g)) {
      const id = tag[1].match(/\bid="([^"]+)"/);
      if (!id) continue;
      const child = new Element(id[1]);
      child.value = tag[1].match(/\bvalue="([^"]*)"/)?.[1] ?? '';
      child.checked = /\bchecked\b/.test(tag[1]);
      if (tag[0].startsWith('<select')) {
        const rest = value.slice(tag.index + tag[0].length);
        const options = [...rest.slice(0,rest.indexOf('</select>')).matchAll(/<option\b([^>]+)>/g)];
        const chosen = options.find(option => /\bselected\b/.test(option[1])) || options[0];
        child.value = chosen?.[1].match(/\bvalue="([^"]*)"/)?.[1] ?? '';
      }
      nodes.set(child.id, child);
    }
  }
  get innerHTML() { return this._html; }
  addEventListener(name, handler) { this.handlers.set(name, handler); }
  setAttribute(name, value) {this.attributes.set(name, String(value));}
  removeAttribute(name) {this.attributes.delete(name);}
  getAttribute(name) {return this.attributes.get(name) ?? null;}
}

const document = {
  querySelector(selector) {
    const result = nodes.get(selector.slice(1));
    if (!result) throw new Error(`UI queried an absent element: ${selector}`);
    return result;
  },
  addEventListener(name, handler) { listeners.set(name, handler); },
  body: {classList: {toggle(name, enabled) {
    if (enabled) classes.add(name); else classes.delete(name);
  }}},
};
function bootPreview() {
  nodes.clear(); listeners.clear(); classes.clear(); timers.clear(); clock=0; nextTimer=1;
  for (const id of ['header', 'content', 'nav', 'scroll', 'force-mock', 'toast']) {
    nodes.set(id, new Element(id));
  }
  const metadata = new Element('stocks-master');
  metadata.textContent = source.match(/<script id="stocks-master" type="application\/json">([\s\S]*?)<\/script>/)[1];
  nodes.set(metadata.id, metadata);
  const context = vm.createContext({
  document, console, URL, URLSearchParams, AbortController,
  location: {search: '?preview=mock'},
  localStorage: {getItem: key => storage.get(key) ?? null,
    setItem: (key, value) => storage.set(key, value)},
  setTimeout: (callback, delay=0) => {const id=nextTimer++;timers.set(id,{callback,at:clock+Number(delay)});return id;},
  clearTimeout: id => timers.delete(id),
  fetch: async (...args) => { networkCalls++; return responseHandler(...args); },
  });
  for (const id of ['strategy-core', 'portfolio-core', 'stock-search-core', 'preview-ui']) {
  const match = source.match(new RegExp(`<script id="${id}">([\\s\\S]*?)<\\/script>`));
  assert.ok(match, `Missing script ${id}`);
    vm.runInContext(match[1], context, {filename: `${id}.js`});
  }
  return context;
}
bootPreview();
const html = () => nodes.get('content').innerHTML;
const countCards = () => (html().match(/class="stockcard"/g) ?? []).length;
function check(condition, description) {
  assert.ok(condition, description);
  checks++;
}
async function click(action, value, id, owner) {
  const target = {disabled: false, dataset: {action, value, id, owner}, closest: () => target};
  listeners.get('click')({target});
  await new Promise(resolve => setImmediate(resolve));
}

(async () => {
  check(countCards() === 6 && html().includes('2330.TW'), 'Initial TW first page');
  check(networkCalls === 0, 'Mock initialization must not contact API');
  check(nodes.has('dashboard-stock-search'), 'Dashboard exposes offline stock autocomplete');
  let search = nodes.get('dashboard-stock-search');
  search.value = 'n'; search.handlers.get('input')(); advanceTime(100);
  search.value = 'nv'; search.handlers.get('input')(); advanceTime(199);
  check(nodes.get('dashboard-stock-results').innerHTML === '', 'Typing restarts the 200ms debounce');
  advanceTime(1);
  check(nodes.get('dashboard-stock-results').innerHTML.includes('NVDA'), 'Debounced prefix returns standard US symbol');
  for (const [query,symbol] of [['台積電','2330.TW'],['2330','2330.TW'],['2330.TW','2330.TW'],['TSMC','2330.TW'],['NVDA','NVDA'],['輝達','NVDA'],['特斯拉','TSLA']]) {
    search.value=query; search.handlers.get('input')(); advanceTime(200);
    check(nodes.get('dashboard-stock-results').innerHTML.includes(symbol), `Offline metadata alias ${query} matches ${symbol}`);
  }
  search.value='輝達';search.handlers.get('input')();advanceTime(200);
  check(nodes.get('dashboard-stock-results').innerHTML.includes('NVIDIA') &&
    nodes.get('dashboard-stock-results').innerHTML.includes('stock-market'), 'Suggestion shows market, Chinese name and English full name');
  let preventedOptionFocus=false;
  const option={closest:selector=>selector==='[data-action="stock-select"]'?option:null};
  listeners.get('mousedown')({target:option,preventDefault(){preventedOptionFocus=true;}});
  // Model the browser's default focus change: an unprevented press blurs the
  // input, causing its 120ms close timer to remove the option before mouseup.
  if(!preventedOptionFocus)search.handlers.get('blur')();
  advanceTime(250);
  check(preventedOptionFocus&&nodes.get('dashboard-stock-results').innerHTML.includes('NVDA'),
    'A held suggestion press retains combobox focus and survives the blur deadline');
  let preventedOrdinaryFocus=false;
  listeners.get('mousedown')({target:{closest:()=>null},preventDefault(){preventedOrdinaryFocus=true;}});
  check(!preventedOrdinaryFocus,'Suggestion focus guard preserves ordinary controls');
  search.handlers.get('keydown')({key:'ArrowDown',preventDefault(){}});
  check(search.getAttribute('aria-activedescendant') === 'dashboard-stock-results-0', 'Keyboard arrow exposes active descendant');
  search.handlers.get('keydown')({key:'Enter',preventDefault(){}});
  await new Promise(resolve=>setImmediate(resolve));
  check(html().includes('NVDA') && nodes.get('equity-input').value === '50000', 'Cross-market selection opens NVDA calculator using USD Capital');
  await click('back');search=nodes.get('dashboard-stock-search');
  search.value='台積電';search.handlers.get('input')();advanceTime(200);
  await click('stock-select','0',undefined,'dashboard-stock-search');
  check(html().includes('2330.TW') && nodes.get('equity-input').value === '1000000', 'Chinese selection switches back to TW calculator using TWD Capital');
  await click('back');search=nodes.get('dashboard-stock-search');
  search.value='Apple';search.handlers.get('input')();advanceTime(200);
  await click('stock-select','0',undefined,'dashboard-stock-search');
  check(nodes.get('holding-symbol').value === 'AAPL' && nodes.get('holding-market').value === 'us', 'Metadata-only stock opens prefilled standard-symbol holding form');
  check(nodes.get('holding-entry').value === '' && nodes.get('holding-stop').value === '' &&
    nodes.get('holding-shares').value === '' && html().includes('沒有此股的已確認策略訊號'), 'Metadata selection creates no fabricated quote, stop or executable recommendation');
  await click('back');await click('market','tw');
  search=nodes.get('dashboard-stock-search');search.value='TSMC';search.handlers.get('input')();
  await click('settings');advanceTime(200);
  check(html().includes('settings-form') && !html().includes('stock-option'), 'A pending autocomplete cannot paint a later screen');
  await click('back');
  check(networkCalls === 0, 'All autocomplete searches and mock selections remain network-free');
  await click('market', 'us');
  check(html().includes('NVDA') && !html().includes('2330.TW'), 'US switch replaces TW quotes');
  await click('detail', undefined, 'us:NVDA');
  check(nodes.get('equity-input').value === '50000' && html().includes('美股帳戶總資金（Capital） · USD'),
    'US Calculator starts with independent USD50000 Capital');
  check(nodes.get('calc-result').innerHTML.includes('US$250.00 USD') &&
    nodes.get('calc-result').innerHTML.includes('89 股'), 'Default US risk budget is USD250, sizing NVDA in USD');
  await click('market', 'tw');
  check(html().includes('2330.TW') && !html().includes('NVDA') && nodes.get('equity-input').value === '1000000',
    'Market switch keeps Calculator with a TW candidate and its TWD1000000 Capital');
  check(nodes.get('calc-result').innerHTML.includes('NT$5,000.00 TWD') &&
    nodes.get('calc-result').innerHTML.includes('223 股'), 'Default TW risk budget is TWD5000, sizing TW shares');
  await click('market', 'us');
  check(html().includes('NVDA') && nodes.get('equity-input').value === '50000',
    'Returning to US restores its candidate and independent USD Capital');
  const equity = nodes.get('equity-input');
  equity.value = '100000';
  equity.handlers.get('input')();
  check(nodes.get('calc-result').innerHTML.includes('500.00'), '0.5% of USD100000 is USD500');
  check(JSON.parse(storage.get('martin-luk-html-preview-v1')).twEquity === 1000000,
    'Editing US Calculator Capital never overwrites TW Capital');
  equity.value = '0';
  equity.handlers.get('input')();
  check(nodes.get('calc-result').innerHTML === '' && nodes.get('calc-error').textContent.length,
    'Invalid equity clears preceding successful order');
  await click('back');
  await click('detail', undefined, 'us:AMD');
  check(nodes.get('calc-result').innerHTML.includes('等待進場確認') &&
    !nodes.get('calc-result').innerHTML.includes('position-result'), 'Watchlist has no executable order');
  await click('back');
  await click('market', 'tw');
  await click('detail', undefined, 'tw:2330.TW');
  check(nodes.get('equity-input').value === '1000000', 'TW Capital stays independent after US changes');
  await click('market', 'us');
  check(nodes.get('equity-input').value === '100000' && html().includes('AMD'),
    'US retains its changed Capital and last selected US watchlist');
  await click('back');
  await click('market', 'tw');
  await click('page', '1');
  check(countCards() === 2, 'Last page contains remaining two stocks');
  await click('sort', 'adr');
  check(countCards() === 6 && html().includes('1519.TW'), 'Sorting resets pagination');
  await click('settings');
  check(html().includes('美股帳戶總資金（Capital） · USD') &&
    html().includes('台股帳戶總資金（Capital） · TWD') &&
    html().includes('預設 US$50,000 USD') && html().includes('預設 NT$1,000,000 TWD'),
    'Settings explicitly labels both separate Capital fields and their defaults');
  nodes.get('setting-usEquity').value = '75000';
  nodes.get('setting-twEquity').value = '2000000';
  await nodes.get('settings-form').handlers.get('submit')({preventDefault() {}});
  await click('detail', undefined, 'tw:2330.TW');
  check(nodes.get('equity-input').value === '2000000' &&
    nodes.get('calc-result').innerHTML.includes('NT$10,000.00 TWD'),
    'TW Calculator automatically seeds independent Settings Capital and TWD risk');
  await click('market', 'us');
  check(nodes.get('equity-input').value === '75000',
    'Market switch seeds US Settings Capital even for a remembered watchlist candidate');
  await click('back');
  await click('detail', undefined, 'us:NVDA');
  check(nodes.get('equity-input').value === '75000' &&
    nodes.get('calc-result').innerHTML.includes('US$375.00 USD'),
    'US Calculator automatically seeds independent Settings Capital and USD risk');
  bootPreview();
  await click('detail', undefined, 'tw:2330.TW');
  check(nodes.get('equity-input').value === '2000000', 'Reload preserves independently saved TW Capital');
  await click('market', 'us');
  check(nodes.get('equity-input').value === '75000', 'Reload preserves independently saved US Capital');
  await click('back');
  await click('market', 'tw');
  await click('settings');
  nodes.get('setting-mock').checked = false;
  nodes.get('setting-api').value = 'http://localhost:8000';
  await nodes.get('settings-form').handlers.get('submit')({preventDefault() {}});
  check(networkCalls === 1 && countCards() === 0 && html().includes('資料更新失敗'),
    'Explicit API failure must not silently display mock quotes');
  await click('reset-mock');
  check(countCards() === 6 && html().includes('OFFLINE MOCK'), 'Explicit recovery returns offline results');
  await click('settings');
  nodes.get('setting-twAdr').value = '7.2';
  nodes.get('setting-dark').checked = false;
  await nodes.get('settings-form').handlers.get('submit')({preventDefault() {}});
  check(countCards() === 1 && html().includes('1519.TW'), 'ADR equality boundary and settings update');
  check(classes.has('light'), 'Light theme preference applies');
  const saved = JSON.parse(storage.get('martin-luk-html-preview-v1'));
  storage.set('martin-luk-html-preview-v1', JSON.stringify({...saved,twAdr:3.5,useMockData:true}));
  const context = bootPreview();
  const apiResponse = requestedMarket => ({ok:true,json:async () => ({
    market:requestedMarket,source:'Test validated API',universe_count:8,stale:false,warnings:[],
    generated_at:context.PreviewStrategy.demoTime,candidates:context.PreviewStrategy.mockCandidates(requestedMarket),
  })});
  responseHandler = async url => apiResponse(new URL(url).searchParams.get('market'));
  await click('settings');
  nodes.get('setting-mock').checked = false;
  await nodes.get('settings-form').handlers.get('submit')({preventDefault() {}});
  await click('detail', undefined, 'tw:2330.TW');
  const pending = [];
  responseHandler = url => new Promise(resolve => pending.push({market:new URL(url).searchParams.get('market'),resolve}));
  await click('market', 'us');
  check(!html().includes('部位計算機') && !html().includes('2330.TW'),
    'While a new market loads, old candidate prices are removed instead of relabeled');
  await click('market', 'tw');
  check(pending.length === 2 && pending[0].market === 'us' && pending[1].market === 'tw',
    'Rapid Calculator market changes initiate matching market requests');
  pending[1].resolve(apiResponse('tw'));
  await new Promise(resolve => setImmediate(resolve));
  check(html().includes('2330.TW') && nodes.get('equity-input').value === '2000000' &&
    nodes.get('calc-result').innerHTML.includes('NT$10,000.00 TWD'),
    'Latest API result restores only its matching market Calculator and Capital');
  pending[0].resolve(apiResponse('us'));
  await new Promise(resolve => setImmediate(resolve));
  check(html().includes('2330.TW') && !html().includes('NVDA') && nodes.get('equity-input').value === '2000000',
    'Late previous-market API response cannot overwrite candidate or Capital');
  responseHandler = async url => ({ok:true,json:async () => ({
    market:new URL(url).searchParams.get('market'),source:'Empty API',universe_count:0,stale:false,
    warnings:[],generated_at:context.PreviewStrategy.demoTime,candidates:[],
  })});
  await click('market', 'us');
  check(countCards() === 0 && !html().includes('部位計算機') && !html().includes('2330.TW'),
    'Empty new-market results return Dashboard without an old-market Calculator');
  const stockPending=[];
  responseHandler=url=>new Promise(resolve=>stockPending.push({market:new URL(url).searchParams.get('market'),resolve}));
  search=nodes.get('dashboard-stock-search');search.value='台積電';search.handlers.get('input')();advanceTime(200);
  await click('stock-select','0',undefined,'dashboard-stock-search');
  check(stockPending.length===1&&stockPending[0].market==='tw','Cross-market metadata selection requests matching API market');
  await click('settings');stockPending[0].resolve(apiResponse('tw'));await new Promise(resolve=>setImmediate(resolve));
  check(html().includes('settings-form')&&!html().includes('部位計算機'),'Late selected-stock API scan cannot override user navigation');
  console.log(`${checks} UI handler checks passed: independent USD/TWD Capital, market Calculator switching, autocomplete debounce/aliases/ARIA, metadata-only holdings, stale request protection, persistence, watchlist, paging, API failure, recovery, ADR and theme.`);
})().catch(error => { console.error(error); process.exitCode = 1; });
