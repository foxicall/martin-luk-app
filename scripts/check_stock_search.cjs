#!/usr/bin/env node
// Production engine + canonical dictionary + exact embedded copies. No packages.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.join(__dirname, '..');
const engine = require(path.join(root, 'stock_search.js'));
const records = JSON.parse(fs.readFileSync(path.join(root, 'stocks_master.json'), 'utf8'));
const index = new engine.StockSearchIndex(records);
let checks = 0;
const eq = (actual, expected, message) => {assert.deepEqual(actual, expected, message); checks++;};
const ok = (value, message) => {assert.ok(value, message); checks++;};
const throws = (fn, message) => {assert.throws(fn, undefined, message); checks++;};
const cases = [
  ['2330', '2330.TW'], ['2330.TW', '2330.TW'], [' ２３３０．ｔｗ ', '2330.TW'],
  ['台積電', '2330.TW'], ['台灣積體電路製造', '2330.TW'], ['TSMC', '2330.TW'], ['TJD', '2330.TW'],
  ['2603', '2603.TW'], ['長榮海運', '2603.TW'], ['Evergreen Marine', '2603.TW'],
  ['聯發科', '2454.TW'], ['MediaTek', '2454.TW'], ['LFK', '2454.TW'],
  ['NVDA', 'NVDA'], ['nvda', 'NVDA'], ['nVdA', 'NVDA'], ['輝達', 'NVDA'], ['輝達半導體', 'NVDA'], ['Nvidia', 'NVDA'],
  ['NVIDIA Corporation', 'NVDA'], ['特斯拉', 'TSLA'], ['Tesla, Inc.', 'TSLA'],
  ['蘋果', 'AAPL'], ['Apple Inc.', 'AAPL'], ['微軟', 'MSFT'], ['Microsoft', 'MSFT'],
  ['BRK.B', 'BRK-B'], ['BRK-B', 'BRK-B'], ['Berkshire Hathaway', 'BRK-B'],
];
for (const [query, symbol] of cases) eq(index.searchStock(query)[0]?.symbol, symbol, `Correct canonical match: ${query}`);
eq(engine.normalizeStockQuery('Ｂｒｋ．Ｂ /  台 積 電'), 'brkb台積電', 'Normalization preserves Chinese and folds full-width punctuation');
for (const query of ['', '   ', '.', '--', null, undefined, 2330]) eq(index.searchStock(query), [], 'Empty/nonstring queries safely return no suggestions');
eq(index.searchStock('x'.repeat(129)), [], 'Unbounded pasted input does not start expensive fuzzy matching');
eq(index.searchStock('NVDA', {market:'TW'}), [], 'Market filters do not leak US symbols into TW results');
ok(index.searchStock('台', {market:'TW'}).every(stock => stock.market === 'TW'), 'TW-only filtering');
ok(index.searchStock('a', {limit:8}).length <= 8, 'Dropdown limit');
eq(index.searchStock('AAPL', {limit:0}), [], 'Zero limit');
throws(() => index.searchStock('AAPL', {limit:51}), 'Reject oversized limit');
throws(() => index.searchStock('AAPL', {market:'HK'}), 'Reject unsupported market');
throws(() => new engine.StockSearchIndex([...records, records[0]]), 'Reject duplicate metadata');
throws(() => new engine.StockSearchIndex([{...records[0], aliases:null}]), 'Reject malformed aliases');
throws(() => new engine.StockSearchIndex([{...records[0], symbol:'bad/code'}]), 'Reject malformed symbols');
const sample = (symbol, name, aliases=[]) => ({market:'US', symbol, code:symbol, name_zh:name,
  name_full_zh:'', name_en:name, abbr_en:'', aliases, short_codes:[]});
const ranking = new engine.StockSearchIndex([
  sample('AAA', 'exact-name', ['AB']), sample('AB', 'winner'), sample('ABCD', 'prefix'),
  sample('CAB', 'substring'), sample('XYZ', 'AB name'), sample('ZXY', 'contains AB here'),
]);
eq(ranking.searchStock('ab').map(item => item.symbol), ['AB','AAA','ABCD','XYZ','CAB','ZXY'], 'Exact code > exact alias > symbol prefix > name prefix > symbol substring > text substring');
const deterministic = new engine.StockSearchIndex([sample('ZZZ','Apple'),sample('BBB','Apple'),sample('AAA','Apple')]);
eq(deterministic.searchStock('Apple').map(item=>item.symbol), ['AAA','BBB','ZZZ'], 'Stable tie ordering does not depend on dictionary input order');
eq(index.searchStock('nvdia')[0]?.symbol, 'NVDA', 'Single-edit English typo matching');
eq(index.searchStock('TSMC share price')[0]?.symbol, '2330.TW', 'Reverse substring supports a longer query containing a name');
const returned=index.searchStock('NVDA');returned.splice(0);
eq(index.searchStock('NVDA')[0].symbol,'NVDA','Caller mutation cannot corrupt cached results');
throws(()=>{index.searchStock('NVDA')[0].aliases.push('malicious');},'Cached records are immutable');
engine.setStocksMaster(records);
eq(engine.searchStock('輝達')[0].symbol,'NVDA','Convenience searchStock uses the configured in-memory index');
for (const market of ['US','TW']) ok(records.filter(item=>item.market===market).length>=100, `${market} offline coverage at least 100 genuine records`);
const jsSource = fs.readFileSync(path.join(root,'stock_search.js'),'utf8').trim();
for (const filename of ['standalone_preview.html','preview/index.html']) {
  const html=fs.readFileSync(path.join(root,filename),'utf8');
  const block=id=>{const match=html.match(new RegExp(`<script\\b[^>]*\\bid="${id}"[^>]*>([\\s\\S]*?)<\\/script>`)); assert.ok(match, `Missing ${id} in ${filename}`); return match[1].trim();};
  eq(JSON.parse(block('stocks-master')), records, `${filename} embeds the full canonical dictionary`);
  eq(block('stock-search-core'), jsSource, `${filename} embeds the exact production search engine`);
  const context=vm.createContext({}); vm.runInContext(block('stock-search-core'),context);
  const embeddedIndex=new context.StockSearch.StockSearchIndex(JSON.parse(block('stocks-master')));
  for(const [query,symbol]of cases)eq(embeddedIndex.searchStock(query)[0]?.symbol,symbol,`${filename}: offline ${query}`);
}
const start=performance.now();
for(let i=0;i<2000;i++)index.searchStock(cases[i%cases.length][0]);
const duration=performance.now()-start;
ok(duration<5000,'Repeated in-memory searches are bounded without external I/O');
console.log(`Stock search: ${checks} checks passed; ${records.length} metadata records; 2000 cached searches ${duration.toFixed(1)} ms.`);
