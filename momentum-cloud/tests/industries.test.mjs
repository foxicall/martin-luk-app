import test from 'node:test';
import assert from 'node:assert/strict';
import {industryMetadata} from '../cloud/industries.mjs';
import {compactResult} from '../cloud/runner.mjs';
import {rankResults} from '../src/strategy.js';

test('classification matches market and exchange, retains Unknown and copies themes', () => {
  assert.equal(industryMetadata('2330.TW','TW').sector, '半導體業');
  assert.equal(industryMetadata('NVDA','US').industry, 'Semiconductors');
  assert.equal(industryMetadata('TVC','US').sector, 'Unknown');
  assert.equal(industryMetadata('2330.TWO','TW').classificationStatus, 'unavailable');
  assert.equal(industryMetadata('NVDA','TW').sector, 'Unknown');
  const value = industryMetadata('NVDA','US'); value.themes.push('mutated');
  assert.ok(!industryMetadata('NVDA','US').themes.includes('mutated'));
});

test('cloud Leader Scanner receives classification without granting missing ranking evidence', () => {
  const row = compactResult({symbol:'NVDA',market:'US',daily:[],error:'no prices'}, {name:'Nvidia',sector:'wrong'});
  assert.equal(row.sector, 'Technology');
  assert.equal(row.industry, 'Semiconductors');
  assert.ok(row.classificationSource);
  const ranked = rankResults([JSON.parse(JSON.stringify(row))],{});
  assert.equal(ranked[0].sector, 'Technology');
  assert.ok(!ranked[0].scanners.includes('leader'));
  assert.notEqual(ranked[0].status, 'triggered');
});
