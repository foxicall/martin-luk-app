// Each blocked row has one primary cause so totals reconcile. Missing evidence is never a pass.
export const DATA_CAUSES=Object.freeze({latest_session_pending:'最新日收盤待齊 · 可看前日分析',daily_fields:'日線欄位待來源補齊',short_history:'歷史不足 31 日',stale_quote:'久未成交／報價過期',history_gap:'日線時序或欄位異常',unavailable:'行情來源連線失敗',unknown:'其他資料待核對'});
export function confirmedHistory(row){
 const h=row?.lastCompleteAssessment,q=row?.dataQuality;
 if(row?.error||row?.status!=='insufficient_data'||q?.code!=='latest_session_pending'||q.latestSessionPending!==true||!h||h.historical!==true||h.technicalBreakout!==false||h.eligible!==false||h.symbol!==row.symbol||h.market!==row.market||h.date!==q.confirmedThrough||h.metrics?.date!==h.date||!Number.isInteger(h.bars)||h.bars<31||h.bars!==q.availableBars-1||q.validBars!==h.bars)return null;
 const gap=(Date.parse(q.latestDate)-Date.parse(h.date))/86400000;
 return gap>0&&gap<=7&&['close','pivot','volumeRatio','ema21'].every(k=>Number.isFinite(h.metrics[k]))&&h.metrics.close>0&&h.metrics.pivot>0&&Array.isArray(h.checks)&&h.checks.length===4?h:null;
}
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
 const result={total:rows.length,valid:0,missing:0,failed:0,retryable:0,recovered:0,historicalAvailable:0,usable:0,latestPending:0,otherMissing:0,causes:[],markets:{TW:{valid:0,missing:0,failed:0,historicalAvailable:0},US:{valid:0,missing:0,failed:0,historicalAvailable:0}}},counts=new Map();
 for(const row of rows){const d=dataDiagnosis(row),kind=row.error?'failed':d?'missing':'valid';result[kind]++;if(result.markets[row.market])result.markets[row.market][kind]++;if(row.historyRecovery?.recovered)result.recovered++;
  if(d){if(d.retryable)result.retryable++;counts.set(d.code,(counts.get(d.code)||0)+1);if(d.code==='latest_session_pending')result.latestPending++;}
  if(confirmedHistory(row)){result.historicalAvailable++;if(result.markets[row.market])result.markets[row.market].historicalAvailable++;}
 }
 result.usable=result.valid+result.historicalAvailable;result.otherMissing=result.missing+result.failed-result.historicalAvailable;
 result.causes=[...counts].map(([code,count])=>({code,label:DATA_CAUSES[code],count})).sort((a,b)=>b.count-a.count||a.code.localeCompare(b.code));return result;
}
