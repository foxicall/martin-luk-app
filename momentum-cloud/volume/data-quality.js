// Each blocked row has one primary cause so totals reconcile. Missing evidence is never a pass.
export const DATA_CAUSES=Object.freeze({daily_fields:'日線欄位待來源補齊',short_history:'歷史不足 31 日',stale_quote:'久未成交／報價過期',history_gap:'日線時序或欄位異常',unavailable:'行情來源連線失敗',unknown:'其他資料待核對'});
export function dataDiagnosis(row){
 if(row?.error)return {code:'unavailable',retryable:true};
 if(row?.status!=='insufficient_data')return null;
 if(Object.hasOwn(DATA_CAUSES,row.dataQuality?.code))return {code:row.dataQuality.code,retryable:row.dataQuality.retryable===true};
 const text=(row.missing||[]).join('；');
 if(row.availableBars<31||text.includes('需 30 根基底'))return {code:'short_history',retryable:false};
 if(/最後成交超過|過期/.test(text))return {code:'stale_quote',retryable:false};
 if(/adjclose|還原|收盤.*暫缺|缺少最後已完成|未提供日線/.test(text))return {code:'daily_fields',retryable:true};
 if(/缺值|時序|缺口|停牌/.test(text))return {code:'history_gap',retryable:false};
 return {code:'unknown',retryable:false};
}
export function summarizeDataQuality(rows){
 const result={total:rows.length,valid:0,missing:0,failed:0,retryable:0,recovered:0,causes:[],markets:{TW:{valid:0,missing:0,failed:0},US:{valid:0,missing:0,failed:0}}},counts=new Map();
 for(const row of rows){const d=dataDiagnosis(row),kind=row.error?'failed':d?'missing':'valid';result[kind]++;if(result.markets[row.market])result.markets[row.market][kind]++;if(row.historyRecovery?.recovered)result.recovered++;
  if(d){if(d.retryable)result.retryable++;counts.set(d.code,(counts.get(d.code)||0)+1);}
 }
 result.causes=[...counts].map(([code,count])=>({code,label:DATA_CAUSES[code],count})).sort((a,b)=>b.count-a.count||a.code.localeCompare(b.code));return result;
}
