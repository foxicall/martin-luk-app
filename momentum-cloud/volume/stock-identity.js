/** @typedef {{symbol:string,code:string,market:'US'|'TW',currency:'USD'|'TWD',exchange:string|null,kind:'stock'|'index',canonical:boolean}} StockIdentity */
const identityText=value=>String(value??'').normalize('NFKC').trim().toUpperCase();
/** Classify the market without guessing a Taiwan listing exchange. */
export function stockIdentity(input){
 const row=typeof input==='object'&&input!==null?input:{symbol:input},symbol=identityText(row.symbol);
 const tw=/^\d{4,6}(?:\.(TW|TWO))?$/.exec(symbol),twIndex=['^TWII','^TWOII'].includes(symbol);
 const us=!twIndex&&(/^[A-Z][A-Z0-9.-]{0,18}$/.test(symbol)&&!symbol.endsWith('.TW')&&!symbol.endsWith('.TWO')||/^\^[A-Z][A-Z0-9]{1,10}$/.test(symbol));
 const market=tw||twIndex?'TW':us?'US':null;if(!market)return null;
 if(row.market!=null&&row.market!==market||row.currency!=null&&row.currency!==(market==='TW'?'TWD':'USD'))return null;
 const exchange=tw?.[1]||null;
 return {symbol,code:tw?symbol.split('.')[0]:symbol,market,currency:market==='TW'?'TWD':'USD',exchange,kind:symbol.startsWith('^')?'index':'stock',canonical:!tw||!!exchange};
}
export function validMarketSymbol(symbol,market){if(!['US','TW'].includes(market))return false;const identity=stockIdentity({symbol,market});return !!identity?.canonical&&identity.symbol===symbol;}
export function preferredSearchMarket(query){const text=identityText(query);return /^\d/.test(text)?'TW':/^[A-Z^]/.test(text)?'US':null;}
export function matchesMarket(row,filter='all'){const market=stockIdentity(row)?.market;return !!market&&(filter==='all'||market===filter);}
