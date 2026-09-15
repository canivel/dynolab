import {PGlite} from '@electric-sql/pglite';
import {writeFileSync} from 'node:fs';
import assert from 'node:assert/strict';
const db = new PGlite();
const version = (await db.query('select version()')).rows[0].version;
await db.exec(`CREATE TABLE sample (a int, b int, payload text);
INSERT INTO sample SELECT i % 1000, i, repeat('x', 40) FROM generate_series(1,100000) AS i;
CREATE INDEX sample_ab ON sample(a,b); ANALYZE sample;`);
const queries = [
  'SELECT * FROM sample WHERE a = 42 AND b = 42042',
  'SELECT * FROM sample WHERE b = 42042 AND a = 42',
];
const runs = [];
for (const query of queries) {
 const plan = (await db.query('EXPLAIN (FORMAT JSON) '+query)).rows[0]['QUERY PLAN'];
 const rows = (await db.query(query)).rows;
 runs.push({query,plan,rows});
}
assert.deepEqual(runs[0].rows, runs[1].rows);
assert.deepEqual(runs[0].plan, runs[1].plan);
assert.equal(runs[0].plan[0].Plan['Index Name'],'sample_ab');
const result={version,engine:'PGlite 0.5.8 (PostgreSQL WASM)',date:new Date().toISOString(),row_count:100000,forced_index:false,identical_plans:true,identical_results:true,runs,note:'A controlled planner counterexample, not a reproduction of the fictional ten-million-row workload or its claimed speedup.'};
writeFileSync(new URL('./result.json',import.meta.url),JSON.stringify(result,null,2));
console.log(JSON.stringify(result,null,2));
await db.close();
