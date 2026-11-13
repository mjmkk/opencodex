'use strict';

// Linear 当前拓扑决定 Goal；只有 Goal 的正式 Registry 决定 Master。
// 这是只读展示投影，绝不改 Work 成员或历史 CALL，不用 Related、标题或历史 return_target 猜当前归属。
const { pathToFileURL } = require('node:url');
const OWNER_MODULE = '/opt/spirit/spirit-agent/current/runtime/owning_goal.mjs';
const identity = m => JSON.stringify([m.kind, m.host_id || null, m.id]);

async function projectHarness({ groups, issueNodes, topologyObservedAt, topologyUnavailable = false }) {
  const { resolveOwningGoal } = await import(pathToFileURL(OWNER_MODULE).href);
  const records = new Map(groups.map(g => [g.issue_id, g]));
  const issues = new Map();
  for (const i of Object.values(issueNodes)) {
    issues.set(i.identifier, i); issues.set(i.id, i);
  }
  const result = new Map();
  for (const work of groups.filter(g => g.members.some(m => m.role === 'master' || m.role === 'worker'))) {
    let ownership, reason;
    try {
      if (topologyUnavailable) throw new Error('topology_unavailable');
      const issue = issues.get(work.issue_id);
      if (!issue) throw new Error('issue_unavailable');
      ownership = await resolveOwningGoal({ issue, getIssue: async ({ id }) => issues.get(id) });
    } catch (e) { reason = e.reason || e.message || 'topology_unavailable'; }
    const owner = ownership?.owner;
    const id = owner?.identifier || work.issue_id;
    let g = result.get(id);
    if (!g) {
      const formal = owner ? records.get(id) : null;
      const masters = formal?.members.filter(m => m.role === 'master') || [];
      const registryMaster = formal?.registry?.master;
      const validMaster = masters.length === 1 && (!formal.registry ||
        (registryMaster?.thread_id === masters[0].id &&
         (!registryMaster.host_id || registryMaster.host_id === masters[0].host_id) &&
         (!registryMaster.kind || registryMaster.kind === masters[0].kind)));
      const status = !owner ? (reason ? 'unavailable' : 'unassigned') : validMaster ? 'verified' : 'master_missing';
      g = { issue_id: id, title: owner?.title || issueNodes[id]?.title || work.title || id,
        updated_at: formal?.updated_at || work.updated_at, ownership_status: status,
        ownership_reason: reason || (!owner ? 'owning_goal_missing' : !validMaster ? 'goal_master_not_registered' : null),
        topology_observed_at: topologyObservedAt || null, members: [], works: [], _members: new Map() };
      // 先放 Goal 本身的成员，确保正式 Goal Master 的名称/身份不被 Work 的旧登记盖掉。
      if (formal) addMembers(g, formal, id);
      result.set(id, g);
    }
    g.works.push({ issue_id: work.issue_id, title: issueNodes[work.issue_id]?.title || work.title || work.issue_id,
      parent_chain: ownership?.chain.map(x => x.issue_id) || [],
      owner_issue_id: owner?.identifier || null });
    addMembers(g, { ...work, title: issueNodes[work.issue_id]?.title || work.title }, owner?.identifier || null);
  }
  return [...result.values()].map(g => {
    delete g._members;
    // 索引与正式 Master 记录不一致时保留线程入口，但不向手机冒充已验证 Master。
    if (g.ownership_status === 'master_missing') {
      for (const member of g.members) if (member.role === 'master') member.role = 'worker';
    }
    g.work_count = g.works.filter(w => w.issue_id !== g.issue_id).length;
    return g;
  });
}

function addMembers(goal, work, ownerID) {
  for (const original of work.members) {
    const key = identity(original);
    let m = goal._members.get(key);
    if (!m) {
      m = { ...original, role: ownerID && original.role === 'master' && work.issue_id !== ownerID ? 'worker' : original.role,
        work_issues: [] };
      goal._members.set(key, m); goal.members.push(m);
    } else if (original.role === 'master' && work.issue_id === ownerID) {
      m.role = 'master';
    }
    if (!m.work_issues.some(w => w.issue_id === work.issue_id)) {
      m.work_issues.push({ issue_id: work.issue_id, title: work.title || work.issue_id, role: original.role });
    }
  }
}
module.exports = { projectHarness, identity };
