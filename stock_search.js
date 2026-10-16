/* Offline metadata search. This exact file is embedded in both HTML previews.
 * No dependencies, request, quote generation, or market-data substitution.
 * Browser: new StockSearch.StockSearchIndex(rows).searchStock('台積電')
 * Node: const {StockSearchIndex} = require('./stock_search.js');
 */
(function (root, factory) {
  'use strict';
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.StockSearch = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';
  const TEXT_FIELDS = ['name_zh', 'name_full_zh', 'name_en', 'abbr_en'];
  const MAX_CACHE = 128;

  // Full-width ASCII is folded explicitly so Dart and JS use the same rules.
  // Chinese characters remain intact; punctuation, spaces and share-class
  // separators are removed: 2330.TW -> 2330tw, BRK.B/BRK-B -> brkb.
  function normalizeStockQuery(value) {
    if (typeof value !== 'string') return '';
    return value.replace(/[\uff01-\uff5e]/g, c => String.fromCharCode(c.charCodeAt(0) - 0xfee0))
      .toLowerCase().replace(/[^a-z0-9\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]/g, '');
  }

  function cleanRecord(raw, row) {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw new TypeError(`Invalid stock row ${row}`);
    if (raw.market !== 'TW' && raw.market !== 'US') throw new TypeError(`Invalid market at row ${row}`);
    if (typeof raw.symbol !== 'string' || typeof raw.code !== 'string') throw new TypeError(`Missing symbol/code at row ${row}`);
    const symbol = raw.symbol.trim().toUpperCase(), code = raw.code.trim().toUpperCase();
    if (raw.market === 'TW' ? !/^\d{4}\.(?:TW|TWO)$/.test(symbol) || code !== symbol.split('.')[0]
      : !/^[A-Z][A-Z0-9]{0,14}(?:-[A-Z])?$/.test(symbol) || code !== symbol) {
      throw new TypeError(`Invalid canonical symbol ${symbol}`);
    }
    const result = {market: raw.market, symbol, code};
    for (const key of TEXT_FIELDS) {
      if (typeof raw[key] !== 'string') throw new TypeError(`Invalid ${key} at row ${row}`);
      result[key] = raw[key];
    }
    for (const key of ['aliases', 'short_codes']) {
      if (!Array.isArray(raw[key]) || raw[key].some(value => typeof value !== 'string')) {
        throw new TypeError(`Invalid ${key} at row ${row}`);
      }
      result[key] = Object.freeze([...new Set(raw[key].filter(value => value.trim()))]);
    }
    return Object.freeze(result);
  }

  // Bounded ordinary Levenshtein, used only after exact/prefix/substring rules.
  // A length bound and early row exit keep typo matching inexpensive.
  function boundedDistance(left, right, limit) {
    if (Math.abs(left.length - right.length) > limit) return limit + 1;
    let previous = Array.from({length: right.length + 1}, (_, index) => index);
    for (let i = 1; i <= left.length; i++) {
      const current = [i];
      let minimum = i;
      for (let j = 1; j <= right.length; j++) {
        current[j] = Math.min(previous[j] + 1, current[j - 1] + 1,
          previous[j - 1] + (left[i - 1] === right[j - 1] ? 0 : 1));
        minimum = Math.min(minimum, current[j]);
      }
      if (minimum > limit) return limit + 1;
      previous = current;
    }
    return previous[right.length];
  }

  function prepare(stock) {
    const rawText = TEXT_FIELDS.map(key => stock[key]).concat(stock.aliases, stock.short_codes);
    const identifiers = [...new Set([stock.symbol, stock.code].map(normalizeStockQuery))];
    const text = [...new Set(rawText.map(normalizeStockQuery).filter(Boolean))];
    // English words make 'nvdia' match Nvidia even when the legal name is long.
    const words = rawText.flatMap(value => value.split(/[^a-zA-Z0-9\uff01-\uff5e]+/)).map(normalizeStockQuery);
    const fuzzy = [...new Set(identifiers.concat(text, words).filter(value => value.length >= 3 && value.length <= 32))];
    return {stock, identifiers, text, fuzzy};
  }

  function score(entry, query) {
    if (entry.identifiers.includes(query)) return 10000;
    if (entry.text.includes(query)) return 9000;
    if (entry.identifiers.some(value => value.startsWith(query))) return 8000;
    if (entry.text.some(value => value.startsWith(query))) return 7000;
    if (entry.identifiers.some(value => value.includes(query))) return 6000;
    if (entry.text.some(value => value.includes(query))) return 5000;
    if (query.length >= 3 && entry.identifiers.concat(entry.text).some(value => value.length >= 3 && query.includes(value))) return 3000;
    if (query.length < 3 || query.length > 32) return 0;
    const limit = query.length < 6 ? 1 : 2;
    let distance = limit + 1;
    for (const value of entry.fuzzy) distance = Math.min(distance, boundedDistance(query, value, limit));
    return distance <= limit ? 1000 - distance * 100 : 0;
  }

  class StockSearchIndex {
    constructor(records) {
      if (!Array.isArray(records)) throw new TypeError('stocks_master must be an array');
      const keys = new Set();
      this._entries = records.map((raw, row) => {
        const stock = cleanRecord(raw, row), key = stock.market + ':' + stock.symbol;
        if (keys.has(key)) throw new TypeError(`Duplicate stock ${key}`);
        keys.add(key);
        return prepare(stock);
      });
      this._cache = new Map();
      this.size = this._entries.length;
    }

    /** Return standard metadata objects, highest score first (default 8 rows).
     *  Optional market is 'TW' or 'US'; omitted searches both account markets.
     */
    searchStock(query, options = {}) {
      const normalized = normalizeStockQuery(query);
      if (!normalized || normalized.length > 128) return [];
      const market = options.market || null;
      if (market !== null && market !== 'TW' && market !== 'US') throw new TypeError('market must be TW or US');
      const limit = options.limit === undefined ? 8 : options.limit;
      if (!Number.isInteger(limit) || limit < 0 || limit > 50) throw new RangeError('limit must be an integer from 0 to 50');
      if (limit === 0) return [];
      const key = JSON.stringify([normalized, market, limit]);
      if (this._cache.has(key)) {
        const cached = this._cache.get(key);
        this._cache.delete(key); this._cache.set(key, cached);
        return cached.slice();
      }
      const ranked = [];
      for (const entry of this._entries) {
        if (market !== null && entry.stock.market !== market) continue;
        const rank = score(entry, normalized);
        if (rank > 0) ranked.push({stock: entry.stock, score: rank});
      }
      const compareText = (left, right) => left < right ? -1 : left > right ? 1 : 0;
      ranked.sort((a, b) => b.score - a.score || compareText(a.stock.symbol, b.stock.symbol) || compareText(a.stock.market, b.stock.market));
      const result = ranked.slice(0, limit).map(item => item.stock);
      this._cache.set(key, result);
      if (this._cache.size > MAX_CACHE) this._cache.delete(this._cache.keys().next().value);
      return result.slice();
    }
  }

  let defaultIndex = null;
  function setStocksMaster(records) { defaultIndex = new StockSearchIndex(records); return defaultIndex; }
  function searchStock(query, options) { return defaultIndex ? defaultIndex.searchStock(query, options) : []; }
  return Object.freeze({StockSearchIndex, normalizeStockQuery, setStocksMaster, searchStock});
});
