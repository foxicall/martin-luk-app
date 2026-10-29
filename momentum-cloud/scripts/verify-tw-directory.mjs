// Read-only integration check in the same GitHub runner environment as the scanner.
import {readUniverse} from '../src/universe.js';
const start=Date.now(),d=await readUniverse('TW');
console.log(JSON.stringify({elapsedMs:Date.now()-start,market:d.market,complete:d.complete,rankEligible:d.rankEligible,total:d.total,sources:d.sources.map(({rows,...s})=>s)},null,2));
if(!d.complete||d.total===0)process.exitCode=1;
