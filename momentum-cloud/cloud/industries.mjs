import {readFileSync} from 'node:fs';

// Load once per scan process. Snapshot data annotates results, never gates RS.
const rows = JSON.parse(readFileSync(new URL('../../assets/data/stock_industries.json', import.meta.url), 'utf8'));
export function industryMetadata(symbol, market) {
  const normalized = String(symbol).trim().toUpperCase();
  const key = market === 'TW' ? normalized.replace(/\.(TW|TWO)$/, '') : normalized;
  const row = rows[key];
  if (!row || row.market !== market || row.symbol !== normalized) {
    return {sector:'Unknown', industry:'', themes:[], classificationStatus:'unavailable'};
  }
  return {sector:row.sector, industry:row.industry, themes:[...row.themes],
    classificationStatus:row.sector_status, classificationSource:row.sector_provider,
    classificationUpdatedAt:row.sector_updated_at};
}
