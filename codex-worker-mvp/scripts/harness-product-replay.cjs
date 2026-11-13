'use strict';
// 只重放实际只读快照，不替换服务、不造 Registry、不发送模型请求。
// argv: <真实 tree 快照> <同批 Linear 拓扑快照> <输出路径>
const fs = require('node:fs');
const assert = require('node:assert/strict');
const { projectHarness, identity } = require('../src/harness-topology.cjs');
if (process.argv.length !== 5) {
  console.error('Usage: node scripts/harness-product-replay.cjs <actual-tree.json> <actual-linear.json> <output.json>');
  process.exit(1);
}
(async () => {
  const tree = JSON.parse(fs.readFileSync(process.argv[2]));
  const issueNodes = JSON.parse(fs.readFileSync(process.argv[3]));
  const goals = await projectHarness({ groups: tree.goals, issueNodes, topologyObservedAt: tree.observed_at });
  const goal = id => goals.find(g => g.issue_id === id);
  assert.equal(goals.length, 12);
  assert.equal(goals.filter(g => g.ownership_status === 'verified').length, 9);
  assert.equal(goal('AGT-24').ownership_status, 'master_missing');
  for (const id of ['AGT-6', 'AGT-39']) assert.equal(goal(id).ownership_status, 'unassigned');
  for (const id of ['BOX-166','BOX-169','BOX-167','BOX-173','BOX-62','BOX-133','BOX-45','BOX-28'])
    assert(goal('BOX-159').works.some(w => w.issue_id === id));
  assert(goal('BOX-163').works.some(w => w.issue_id === 'BOX-123'));
  assert(goal('BOX-161').works.some(w => w.issue_id === 'BOX-139'));
  assert(goal('AGT-26').works.some(w => w.issue_id === 'AGT-27'));
  // 迁移线程在 BOX-167/169 都有登记：同一 Goal 下只有一条成员，工作票两个都保留。
  const migration = goal('BOX-159').members.filter(m => m.id === '01a19f43-ec2e-7de0-958a-8ec68009f315');
  assert.equal(migration.length, 1);
  assert.deepEqual(migration[0].work_issues.map(w => w.issue_id).sort(), ['BOX-167','BOX-169']);
  // Work 的 Master 是工作负责人，不冒充父 Goal 的 Master。
  assert.equal(goal('AGT-26').members.filter(m => m.role === 'master').length, 1);
  assert.equal(goal('AGT-26').members.find(m => m.id === '01a1bc84-8d1f-7450-b5f4-9fa8e2377a84').role, 'worker');
  const before = new Set(tree.goals.flatMap(g => g.members.map(identity)));
  const after = new Set(goals.flatMap(g => g.members.map(identity)));
  assert.deepEqual(after, before, '每个原始原生身份都保留，未为了整洁丢线程');
  for (const g of goals) assert.equal(new Set(g.members.map(identity)).size, g.members.length);
  const payload = { ...tree, schema_version: 2, goals };
  fs.writeFileSync(process.argv[4], JSON.stringify(payload, null, 2));
  console.log(JSON.stringify({beforeGroups:tree.goals.length,afterGroups:goals.length,uniqueIdentities:after.size,
    verified:goals.filter(g=>g.ownership_status==='verified').map(g=>g.issue_id),
    exceptions:goals.filter(g=>g.ownership_status!=='verified').map(g=>[g.issue_id,g.ownership_status])}));
})().catch(e => { console.error(e); process.exitCode = 1; });
