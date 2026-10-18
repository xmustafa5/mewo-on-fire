// Tests for the console's pure logic: the <script id="mewo-core"> block in index.html.
// Run: node --test pc/dashboard/core.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const html = readFileSync(new URL('./index.html', import.meta.url), 'utf8');
const block = html.match(/<script id="mewo-core">([\s\S]*?)<\/script>/);
assert.ok(block, 'index.html has a <script id="mewo-core"> block');
// Same realm on purpose: a vm context would make deepStrictEqual fail on its objects.
const root = {};
new Function('window', block[1])(root);
const C = root.MewoCore;

const NOW = new Date(2026, 9, 14, 15, 0, 0).getTime();
const MIN = 60e3, H = 3600e3, DAY = 24 * H;
const S = (id, o = {}) => ({ id, state: 'idle', project: 'mobile', pc_id: 'me', last_ts: NOW - H, title: id, ...o });
const E = (id, o = {}) => ({ id, ts: NOW - H, kind: 'stop', project: 'mobile', pc_id: 'me', session_id: 'a', message: 'done', ...o });
const F = (o = {}) => ({ ...C.defaultFilters(), ...o });
const ids = (list) => list.map((x) => x.id);
const passing = (list, f, ignore = false) => ids(list.filter((s) => C.sessionPasses(s, f, NOW, ignore)));

// ---------- prefs ----------

test('constants', () => {
  assert.deepEqual(C.STATES, ['working', 'waiting', 'idle', 'ended']);
  assert.equal(C.ALPHA_MIN, 0.001);
});

test('defaultFilters and defaultPrefs are fresh objects every call', () => {
  assert.deepEqual(C.defaultFilters(), { status: [], projects: [], pcs: [], range: 'all', q: '' });
  assert.deepEqual(C.defaultPrefs(), { v: 1, hidden: {}, feed_cleared_at: 0, filters: { status: [], projects: [], pcs: [], range: 'all' } });
  const a = C.defaultPrefs(); a.hidden.x = 1; a.filters.status.push('idle');
  assert.deepEqual(C.defaultPrefs().hidden, {});
  assert.deepEqual(C.defaultPrefs().filters.status, []);
  const f = C.defaultFilters(); f.pcs.push('me');
  assert.deepEqual(C.defaultFilters().pcs, []);
});

test('normPrefs: missing or non-object input gives the defaults', () => {
  for (const p of [undefined, null, 'x', 42, [1, 2], {}]) assert.deepEqual(C.normPrefs(p), C.defaultPrefs(), JSON.stringify(p));
});

test('normPrefs keeps a valid document as it is', () => {
  const p = { v: 1, hidden: { a: NOW - H, b: 0 }, feed_cleared_at: NOW - DAY, filters: { status: ['idle', 'ended'], projects: ['mobile'], pcs: ['me', 'peer'], range: '7d' } };
  assert.deepEqual(C.normPrefs(structuredClone(p)), p);
});

test('normPrefs drops bad fields one by one', () => {
  const p = C.normPrefs({
    v: 7, extra: true,
    hidden: { a: NOW, b: 'yesterday', c: null, d: NaN },
    feed_cleared_at: 'soon',
    filters: { status: ['idle', 'sleeping', 3], projects: 'mobile', pcs: ['me', 5], range: 'forever', q: 'not saved' },
  });
  assert.deepEqual(p, { v: 1, hidden: { a: NOW }, feed_cleared_at: 0, filters: { status: ['idle'], projects: [], pcs: ['me'], range: 'all' } });
  assert.deepEqual(C.normPrefs({ hidden: [1], filters: 'x', feed_cleared_at: -5 }), C.defaultPrefs());
});

test('normPrefs output does not share arrays with its input', () => {
  const input = { filters: { status: ['idle'], projects: ['mobile'], pcs: [], range: '1h' } };
  const p = C.normPrefs(input);
  p.filters.status.push('ended');
  assert.deepEqual(input.filters.status, ['idle']);
});

// ---------- filters ----------

test('rangeStart for every range', () => {
  assert.equal(C.rangeStart('1h', NOW), NOW - H);
  assert.equal(C.rangeStart('today', NOW), new Date(2026, 9, 14).getTime());
  assert.equal(C.rangeStart('today', NOW), NOW - 15 * H); // local midnight, 15:00 is NOW
  assert.equal(C.rangeStart('7d', NOW), NOW - 7 * DAY);
  assert.equal(C.rangeStart('all', NOW), 0);
  assert.equal(C.rangeStart('bogus', NOW), 0);
});

test('projectOf falls back to unknown', () => {
  assert.equal(C.projectOf({ project: 'pc' }), 'pc');
  assert.equal(C.projectOf({}), 'unknown');
  assert.equal(C.projectOf({ project: '' }), 'unknown');
});

test('matchesQuery: each field, any case, plain text', () => {
  const s = S('a', { title: 'Fix Login', project: 'Mobile', branch: 'feature/chat', last_text: 'Ran the tests', cwd: '/Users/x/repo-one' });
  for (const q of ['login', 'MOBILE', 'feature/ch', 'the tests', 'repo-one', '  fix  ']) assert.equal(C.matchesQuery(s, q), true, q);
  assert.equal(C.matchesQuery(s, 'nothing like it'), false);
  for (const q of ['', '   ', undefined, null]) assert.equal(C.matchesQuery(s, q), true, String(q));
  assert.equal(C.matchesQuery({ id: 'bare' }, 'x'), false); // missing fields do not throw
});

test('matchesQuery treats regex characters literally', () => {
  assert.equal(C.matchesQuery(S('a', { last_text: 'then call a.b(1)' }), 'a.b('), true);
  assert.equal(C.matchesQuery(S('b', { last_text: 'then call axb(1)' }), 'a.b('), false);
  assert.equal(C.matchesQuery(S('c', { title: 'price $5 [x]' }), '$5 [x'), true);
});

const MIX = [
  S('w', { state: 'working', project: 'mobile', pc_id: 'me' }),
  S('q', { state: 'waiting', project: 'pc', pc_id: 'me' }),
  S('i', { state: 'idle', project: 'web', pc_id: 'peer' }),
  S('e', { state: 'ended', project: 'mobile', pc_id: 'peer' }),
  S('n', { state: 'idle', project: undefined, pc_id: 'me' }),
];

test('sessionPasses: status filter', () => {
  assert.deepEqual(passing(MIX, F()), ['w', 'q', 'i', 'e', 'n']);
  assert.deepEqual(passing(MIX, F({ status: ['working'] })), ['w']);
  assert.deepEqual(passing(MIX, F({ status: ['idle', 'ended'] })), ['i', 'e', 'n']);
});

test('sessionPasses: projects filter, unknown project', () => {
  assert.deepEqual(passing(MIX, F({ projects: ['mobile'] })), ['w', 'e']);
  assert.deepEqual(passing(MIX, F({ projects: ['pc', 'web'] })), ['q', 'i']);
  assert.deepEqual(passing(MIX, F({ projects: ['unknown'] })), ['n']); // a session with no project sits under "unknown"
  assert.deepEqual(passing(MIX, F({ projects: ['no-such-project'] })), []);
});

test('sessionPasses: computers filter', () => {
  assert.deepEqual(passing(MIX, F({ pcs: ['peer'] })), ['i', 'e']);
  assert.deepEqual(passing(MIX, F({ pcs: ['me', 'peer'] })), ['w', 'q', 'i', 'e', 'n']);
  assert.deepEqual(passing(MIX, F({ pcs: ['gone'] })), []);
});

test('sessionPasses: dimensions combine with AND, values within one with OR', () => {
  assert.deepEqual(passing(MIX, F({ status: ['idle', 'ended'], pcs: ['peer'], projects: ['mobile'] })), ['e']);
  assert.deepEqual(passing(MIX, F({ status: ['working'], pcs: ['peer'] })), []);
});

test('sessionPasses: time range by last_ts', () => {
  const list = [
    S('m30', { last_ts: NOW - 30 * MIN }),
    S('h2', { last_ts: NOW - 2 * H }),
    S('today1am', { last_ts: NOW - 14 * H }),
    S('yday11pm', { last_ts: NOW - 16 * H }),
    S('d3', { last_ts: NOW - 3 * DAY }),
    S('d10', { last_ts: NOW - 10 * DAY }),
    S('never', { last_ts: undefined }),
  ];
  assert.deepEqual(passing(list, F({ range: '1h' })), ['m30']);
  assert.deepEqual(passing(list, F({ range: 'today' })), ['m30', 'h2', 'today1am']);
  assert.deepEqual(passing(list, F({ range: '7d' })), ['m30', 'h2', 'today1am', 'yday11pm', 'd3']);
  assert.deepEqual(passing(list, F({ range: 'all' })), ids(list));
});

test('sessionPasses: search', () => {
  const list = [S('a', { title: 'Chat screen' }), S('b', { last_text: 'chat is done' }), S('c', { title: 'Relay' })];
  assert.deepEqual(passing(list, F({ q: 'CHAT' })), ['a', 'b']);
});

test('sessionPasses with ignoreFacets keeps range and search only', () => {
  const f = F({ status: ['working'], projects: ['pc'], pcs: ['peer'], range: '1h', q: 'x' });
  const list = [S('hit-x', { state: 'ended', last_ts: NOW - 5 * MIN }), S('old-x', { last_ts: NOW - 2 * H }), S('new-y', { last_ts: NOW - 5 * MIN, title: 'y' })];
  assert.deepEqual(passing(list, f), []);
  assert.deepEqual(passing(list, f, true), ['hit-x']);
});

// ---------- hiding ----------

test('isHidden: hidden while last_ts <= the stored value, woken after', () => {
  const hidden = { a: NOW - H };
  assert.equal(C.isHidden(S('a'), hidden), true); // equal
  assert.equal(C.isHidden(S('a', { last_ts: NOW - 2 * H }), hidden), true); // older
  assert.equal(C.isHidden(S('a', { last_ts: NOW - H + 1 }), hidden), false); // woke up
  assert.equal(C.isHidden(S('b'), hidden), false);
  assert.equal(C.isHidden(S('z', { last_ts: undefined }), { z: 0 }), true);
  assert.equal(C.isHidden(S('toString'), {}), false); // own keys only
  assert.equal(C.isHidden(S('a'), undefined), false);
});

test('hideIds stores each session last_ts and returns a new map', () => {
  const before = { old: 5 };
  const list = [S('a', { last_ts: NOW - H }), S('b', { last_ts: NOW - 2 * H }), S('c')];
  const after = C.hideIds(before, list, ['a', 'b', 'missing']);
  assert.deepEqual(after, { old: 5, a: NOW - H, b: NOW - 2 * H });
  assert.deepEqual(before, { old: 5 }, 'the old map stays as it was, so Undo can put it back');
  assert.equal(C.isHidden(list[0], after), true);
  assert.equal(C.isHidden(list[2], after), false);
});

test('unhideIds removes ids and returns a new map', () => {
  const before = { a: 1, b: 2, c: 3 };
  assert.deepEqual(C.unhideIds(before, ['a', 'c', 'nope']), { b: 2 });
  assert.deepEqual(before, { a: 1, b: 2, c: 3 });
});

test('pruneHidden drops woken sessions and long-gone ones', () => {
  const hidden = {
    still: NOW - H, // present, still hidden: kept
    woke: NOW - 2 * H, // present, newer activity: dropped
    gone: NOW - 10 * DAY, // missing for now (peer offline?), recent: kept
    ancient: NOW - 31 * DAY, // missing and older than 30 days: dropped
  };
  const sessions = [S('still', { last_ts: NOW - H }), S('woke', { last_ts: NOW - H })];
  assert.deepEqual(C.pruneHidden(hidden, sessions, NOW), { still: NOW - H, gone: NOW - 10 * DAY });
  assert.equal(Object.keys(hidden).length, 4, 'input untouched');
});

test('eventPasses: cleared feed, range, hidden session', () => {
  const f = F();
  assert.equal(C.eventPasses(E('1'), f, NOW, new Set(), 0), true);
  assert.equal(C.eventPasses(E('1'), f, NOW, null, 0), true);
  assert.equal(C.eventPasses(E('1', { ts: NOW - H }), f, NOW, new Set(), NOW - H), false, 'at the clear time');
  assert.equal(C.eventPasses(E('1', { ts: NOW - H + 1 }), f, NOW, new Set(), NOW - H), true, 'after it');
  assert.equal(C.eventPasses(E('1', { ts: NOW - 2 * H }), F({ range: '1h' }), NOW, new Set(), 0), false);
  assert.equal(C.eventPasses(E('1', { ts: NOW - 2 * H }), F({ range: 'today' }), NOW, new Set(), 0), true);
  assert.equal(C.eventPasses(E('1', { session_id: 'a' }), f, NOW, new Set(['a']), 0), false);
  assert.equal(C.eventPasses(E('1', { session_id: undefined }), f, NOW, new Set(['a']), 0), true);
});

test('eventPasses: project, computer and search; status does not apply', () => {
  assert.equal(C.eventPasses(E('1'), F({ projects: ['mobile'] }), NOW, null, 0), true);
  assert.equal(C.eventPasses(E('1'), F({ projects: ['pc'] }), NOW, null, 0), false);
  assert.equal(C.eventPasses(E('1', { project: undefined }), F({ projects: ['unknown'] }), NOW, null, 0), true);
  assert.equal(C.eventPasses(E('1'), F({ pcs: ['peer'] }), NOW, null, 0), false);
  assert.equal(C.eventPasses(E('1', { pc_id: 'peer' }), F({ pcs: ['peer'] }), NOW, null, 0), true);
  assert.equal(C.eventPasses(E('1'), F({ status: ['working'] }), NOW, null, 0), true);
  assert.equal(C.eventPasses(E('1', { message: 'Build a.b( passed' }), F({ q: 'A.B(' }), NOW, null, 0), true);
  assert.equal(C.eventPasses(E('1', { message: '', detail: 'Tests green' }), F({ q: 'green' }), NOW, null, 0), true);
  assert.equal(C.eventPasses(E('1'), F({ q: 'MOB' }), NOW, null, 0), true);
  assert.equal(C.eventPasses(E('1'), F({ q: 'nowhere' }), NOW, null, 0), false);
});

test('facetCounts ignore the facets themselves, skip hidden, keep range and search', () => {
  const list = [
    S('a', { state: 'working', project: 'mobile', pc_id: 'me' }),
    S('b', { state: 'idle', project: 'mobile', pc_id: 'peer' }),
    S('c', { state: 'idle', project: 'web', pc_id: 'me' }),
    S('hid', { state: 'ended', project: 'web', pc_id: 'me' }),
    S('old', { state: 'idle', project: 'pc', pc_id: 'me', last_ts: NOW - 3 * DAY }),
  ];
  const hidden = { hid: NOW - H };
  const f = F({ status: ['working'], projects: ['mobile'], pcs: ['me'], range: '7d' });
  assert.deepEqual(C.facetCounts(list, f, NOW, hidden), {
    status: { working: 1, idle: 3 },
    projects: { mobile: 2, web: 1, pc: 1 },
    pcs: { me: 3, peer: 1 },
  });
  assert.deepEqual(C.facetCounts(list, F({ range: 'today' }), NOW, hidden), {
    status: { working: 1, idle: 2 },
    projects: { mobile: 2, web: 1 },
    pcs: { me: 2, peer: 1 },
  });
  assert.deepEqual(C.facetCounts(list, F({ q: 'nothing matches' }), NOW, hidden), { status: {}, projects: {}, pcs: {} });
  assert.deepEqual(C.facetCounts(list, F({ q: 'old' }), NOW, {}).pcs, { me: 1 });
});

test('cleanupTargets', () => {
  const list = [
    S('w', { state: 'working', last_ts: NOW - 3 * DAY }),
    S('q', { state: 'waiting', last_ts: NOW - 3 * DAY }),
    S('i', { state: 'idle' }),
    S('e', { state: 'ended' }),
    S('i-old', { state: 'idle', last_ts: NOW - DAY - 1 }),
    S('e-old', { state: 'ended', last_ts: NOW - 2 * DAY }),
  ];
  assert.deepEqual(ids(C.cleanupTargets('finished', list, NOW)), ['i', 'i-old']);
  assert.deepEqual(ids(C.cleanupTargets('closed', list, NOW)), ['e', 'e-old']);
  assert.deepEqual(ids(C.cleanupTargets('stale', list, NOW)), ['i-old', 'e-old']);
  assert.deepEqual(C.cleanupTargets('everything', list, NOW), []);
});

// ---------- graph model ----------

const PCS = [{ pc_id: 'me', name: 'Studio' }, { pc_id: 'peer', name: 'Laptop' }, { pc_id: 'idle-peer', name: 'Spare' }];
const node = (g, id) => g.nodes.find((n) => n.id === id);
const linksOf = (g, a, b) => g.links.filter((l) => l.source === a && l.target === b);

test('buildGraph: a project shared by two computers is one node, linked to each once', () => {
  const list = [S('a'), S('b'), S('c', { pc_id: 'peer' }), S('d', { pc_id: 'peer' })];
  const g = C.buildGraph(list, PCS, 'me', (k) => k);
  assert.deepEqual(g.nodes.filter((n) => n.kind === 'project').map((n) => n.id), ['p:mobile']);
  assert.equal(linksOf(g, 'p:mobile', 'pc:me').length, 1);
  assert.equal(linksOf(g, 'p:mobile', 'pc:peer').length, 1);
  assert.equal(linksOf(g, 'p:mobile', 'pc:me')[0].len, 110);
  for (const id of ['a', 'b', 'c', 'd']) assert.deepEqual(linksOf(g, 's:' + id, 'p:mobile').map((l) => l.len), [60]);
  assert.equal(g.links.length, 6);
  const pc = node(g, 'pc:peer');
  assert.equal(pc.kind, 'pc'); assert.equal(pc.label, 'Laptop'); assert.equal(pc.r, 12); assert.equal(pc.ref, PCS[1]); assert.equal(pc.faded, false);
  const s = node(g, 's:a');
  assert.equal(s.kind, 'session'); assert.equal(s.label, 'a'); assert.equal(s.r, 5); assert.equal(s.ref, list[0]);
  assert.equal(node(g, 'p:mobile').label, 'mobile');
});

test('buildGraph: this computer is always there, other computers only with sessions', () => {
  const g = C.buildGraph([S('a', { pc_id: 'peer' })], PCS, 'me', null);
  assert.ok(node(g, 'pc:me'), 'self with no sessions');
  assert.equal(node(g, 'pc:me').label, 'Studio');
  assert.ok(node(g, 'pc:peer'));
  assert.equal(node(g, 'pc:idle-peer'), undefined);
  const empty = C.buildGraph([], PCS, 'me', null);
  assert.deepEqual(empty.nodes.map((n) => n.id), ['pc:me']);
  assert.deepEqual(empty.links, []);
  // A computer missing from the list still gets a node, named from its sessions.
  const g2 = C.buildGraph([S('x', { pc_id: 'other', pc_name: 'Other Mac' })], PCS, 'me', null);
  assert.equal(node(g2, 'pc:other').label, 'Other Mac');
});

test('buildGraph: feature node and links', () => {
  const list = [S('a', { feature: 'chat' }), S('b', { feature: 'chat', pc_id: 'peer', project: 'pc' }), S('c')];
  const g = C.buildGraph(list, PCS, 'me', (k) => 'Feature ' + k);
  const f = node(g, 'f:chat');
  assert.equal(f.kind, 'feature'); assert.equal(f.label, 'Feature chat'); assert.equal(f.r, 7); assert.equal(f.ref, 'chat');
  assert.deepEqual(linksOf(g, 's:a', 'f:chat').map((l) => l.len), [70]);
  assert.deepEqual(linksOf(g, 's:b', 'f:chat').map((l) => l.len), [70]);
  assert.equal(g.links.filter((l) => l.target === 'f:chat').length, 2);
  assert.equal(C.buildGraph([S('c')], PCS, 'me', null).nodes.some((n) => n.kind === 'feature'), false);
  assert.equal(C.buildGraph([S('a', { feature: 'chat' })], PCS, 'me', null).nodes.find((n) => n.kind === 'feature').label, 'chat');
});

test('buildGraph: hidden sessions shown faded', () => {
  const g = C.buildGraph([S('a', { _hidden: true }), S('b')], PCS, 'me', null);
  assert.equal(node(g, 's:a').faded, true);
  assert.equal(node(g, 's:b').faded, false);
});

test('buildGraph: project radius grows with its sessions, capped at 14', () => {
  const many = (n, project) => Array.from({ length: n }, (_, i) => S(project + i, { project }));
  const g = C.buildGraph([...many(1, 'one'), ...many(4, 'four'), ...many(100, 'lots')], PCS, 'me', null);
  assert.ok(Math.abs(node(g, 'p:one').r - 7.2) < 1e-9);
  assert.ok(Math.abs(node(g, 'p:four').r - 8.4) < 1e-9);
  assert.equal(node(g, 'p:lots').r, 14);
  assert.equal(node(g, 'p:lots').kind, 'project');
});

// ---------- physics ----------

// Two computers, three projects, twelve sessions, one feature across both computers.
function bigGraph(extra = []) {
  const list = [
    S('m1', { state: 'working', feature: 'chat' }), S('m2', { feature: 'chat' }), S('m3', { state: 'ended' }),
    S('p1', { project: 'pc', state: 'waiting' }), S('p2', { project: 'pc' }),
    S('w1', { project: 'web' }), S('w2', { project: 'web', state: 'ended' }),
    S('m4', { pc_id: 'peer', feature: 'chat' }), S('m5', { pc_id: 'peer' }),
    S('w3', { pc_id: 'peer', project: 'web' }), S('w4', { pc_id: 'peer', project: 'web', state: 'working' }), S('w5', { pc_id: 'peer', project: 'web' }),
    ...extra,
  ];
  return C.buildGraph(list, PCS, 'me', (k) => k);
}
const snap = (sim) => JSON.stringify([...sim.pos].sort((a, b) => (a[0] < b[0] ? -1 : 1)));
const dist = (a, b) => Math.hypot(a.p.x - b.p.x, a.p.y - b.p.y);

test('sim: settles without overlaps and with links near their length', () => {
  const g = bigGraph(), sim = C.createSim();
  assert.equal(g.nodes.length, 2 + 3 + 12 + 1);
  sim.setGraph(g.nodes, g.links);
  sim.settle(1000);
  const byId = new Map(g.nodes.map((n) => [n.id, n]));
  for (const n of g.nodes) assert.ok(Number.isFinite(n.p.x) && Number.isFinite(n.p.y), n.id);
  for (let i = 0; i < g.nodes.length; i++) {
    for (let j = i + 1; j < g.nodes.length; j++) {
      const a = g.nodes[i], b = g.nodes[j];
      assert.ok(dist(a, b) >= a.r + b.r, `${a.id} and ${b.id} overlap: ${dist(a, b).toFixed(1)} < ${a.r + b.r}`);
    }
  }
  for (const l of g.links) {
    const d = dist(byId.get(l.source), byId.get(l.target));
    assert.ok(d < 3 * l.len, `${l.source}>${l.target} is ${d.toFixed(0)} px, len ${l.len}`);
  }
});

test('sim: settle ends within ~300 ticks, then tick() is false', () => {
  const g = bigGraph(), sim = C.createSim();
  assert.equal(sim.setGraph(g.nodes, g.links), true);
  assert.equal(sim.alpha, 1, 'the first graph starts hot');
  assert.equal(sim.tick(), true);
  const n = 1 + sim.settle(1000);
  assert.ok(n >= 290 && n <= 310, `took ${n} ticks`);
  assert.ok(sim.alpha < C.ALPHA_MIN);
  assert.equal(sim.tick(), false);
  // settle() with its default cap leaves a cold sim too.
  const sim2 = C.createSim();
  sim2.setGraph(g.nodes, g.links);
  assert.ok(sim2.settle() <= 300);
  assert.equal(sim2.tick(), false);
});

test('sim: the same graph again changes nothing', () => {
  const g = bigGraph(), sim = C.createSim();
  sim.setGraph(g.nodes, g.links); sim.settle(1000);
  const before = snap(sim), alpha = sim.alpha;
  const g2 = bigGraph(); // fresh objects, as every state update builds them
  assert.equal(sim.setGraph(g2.nodes, g2.links), false);
  assert.equal(snap(sim), before);
  assert.equal(sim.alpha, alpha, 'no reheat');
  for (const n of g2.nodes) assert.equal(n.p, sim.pos.get(n.id), 'n.p is the kept position object');
  assert.equal(sim.nodes(), g2.nodes);
  assert.equal(sim.links(), g2.links);
  // Sessions in another order are still the same graph.
  const g3 = C.buildGraph([...g2.nodes.filter((n) => n.kind === 'session').map((n) => n.ref)].reverse(), PCS, 'me', (k) => k);
  assert.equal(sim.setGraph(g3.nodes, g3.links), false);
});

test('sim: an added node leaves the others alone until the next tick', () => {
  const g = bigGraph(), sim = C.createSim();
  sim.setGraph(g.nodes, g.links); sim.settle(1000);
  const before = new Map([...sim.pos].map(([id, p]) => [id, { ...p }]));
  const g2 = bigGraph([S('new'), S('fresh', { project: 'brand-new' })]);
  assert.equal(sim.setGraph(g2.nodes, g2.links), true);
  assert.equal(sim.alpha, 0.3, 'a change reheats to 0.3, not 1');
  for (const [id, p] of before) assert.deepEqual({ ...sim.pos.get(id) }, p, id);
  const at = (id) => sim.pos.get(id);
  const gap = (a, b) => Math.hypot(at(a).x - at(b).x, at(a).y - at(b).y);
  assert.ok(Math.abs(gap('s:new', 'p:mobile') - 24) < 1e-9, 'next to its project');
  assert.ok(Math.abs(gap('p:brand-new', 'pc:me') - 24) < 1e-9, 'a new project next to its computer');
  assert.ok(Math.abs(gap('s:fresh', 'p:brand-new') - 24) < 1e-9, 'then its session next to it');
  // A removed node is a change as well, and its position is forgotten.
  const g3 = bigGraph();
  assert.equal(sim.setGraph(g3.nodes, g3.links), true);
  assert.equal(sim.pos.has('s:new'), false);
});

test('sim: a node with no placed neighbour starts near the origin', () => {
  const sim = C.createSim();
  sim.setGraph([{ id: 'pc:me', kind: 'pc', r: 12 }, { id: 'lonely', kind: 'session', r: 5 }], []);
  for (const p of sim.pos.values()) assert.ok(Math.hypot(p.x, p.y) <= 40);
});

test('sim: the layout is deterministic', () => {
  const run = () => { const g = bigGraph(), sim = C.createSim(); sim.setGraph(g.nodes, g.links); sim.settle(1000); return snap(sim); };
  assert.equal(run(), run());
});

test('sim: a pinned node holds still, unpinned it moves again', () => {
  const g = bigGraph(), sim = C.createSim();
  sim.setGraph(g.nodes, g.links); sim.settle(1000);
  sim.pin('s:m1', 300, -200);
  sim.reheat(0.3);
  assert.equal(sim.alpha, 0.3);
  sim.settle(1000);
  const p = sim.pos.get('s:m1');
  assert.deepEqual([p.x, p.y, p.vx, p.vy, p.fx, p.fy], [300, -200, 0, 0, 300, -200]);
  sim.unpin('s:m1');
  assert.equal(p.fx, null); assert.equal(p.fy, null);
  sim.reheat(0.3); sim.settle(1000);
  assert.ok(Math.hypot(p.x - 300, p.y + 200) > 50, 'pulled back toward its project');
});

test('sim: reheat never cools', () => {
  const g = bigGraph(), sim = C.createSim();
  sim.setGraph(g.nodes, g.links);
  sim.reheat(0.3);
  assert.equal(sim.alpha, 1);
});

test('sim: collision opens an overlap in one tick, even when nearly cold', () => {
  const a = { id: 'a', r: 5 }, b = { id: 'b', r: 5 }, sim = C.createSim();
  sim.setGraph([a, b], []); sim.settle(1000);
  // Pinned a, free b: b takes the whole push.
  sim.pin('a', 0, 0); sim.pin('b', 3, 0); sim.unpin('b');
  sim.reheat(0.002); sim.tick();
  assert.deepEqual([a.p.x, a.p.y], [0, 0]);
  assert.ok(dist(a, b) >= 16 - 1e-9 && dist(a, b) < 16.5, `gap ${dist(a, b)}`); // r + r + 6
  // Both free: each moves half, so the midpoint stays put.
  sim.pin('a', 0, 0); sim.pin('b', 4, 0); sim.unpin('a'); sim.unpin('b');
  sim.reheat(0.002); sim.tick();
  assert.ok(dist(a, b) >= 16 - 1e-9 && dist(a, b) < 16.5, `gap ${dist(a, b)}`);
  assert.ok(Math.abs((a.p.x + b.p.x) / 2 - 2) < 0.1 && Math.abs(a.p.y + b.p.y) < 0.1, 'midpoint kept');
});

test('sim: nodes on the same spot are pushed apart', () => {
  const ns = [{ id: 'a', r: 5 }, { id: 'b', r: 5 }, { id: 'c', r: 7 }];
  const sim = C.createSim();
  sim.setGraph(ns, []);
  for (const n of ns) sim.pin(n.id, 10, 10);
  sim.tick();
  for (const n of ns) sim.unpin(n.id);
  sim.reheat(1); sim.settle(1000);
  for (let i = 0; i < ns.length; i++) for (let j = i + 1; j < ns.length; j++) assert.ok(dist(ns[i], ns[j]) >= ns[i].r + ns[j].r, `${ns[i].id}/${ns[j].id}`);
});

// ---------- the twelve steps ----------

test('stepState: done before the step, now at it, ahead after it, carried where the work moved past open items', () => {
  const f = { step: 9, released: false, carried: [{ step: 2 }, { step: 5 }, { step: 7 }] };
  assert.deepEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12].map((n) => C.stepState(f, n)), ['done', 'carried', 'done', 'done', 'carried', 'done', 'carried', 'done', 'now', '', '']);
  assert.equal(C.stepState({ step: 3 }, 3), 'now');
  assert.equal(C.stepState({ step: 12, released: true, carried: [{ step: 11 }] }, 12), 'done');
  assert.equal(C.stepState({ step: 12, released: true, carried: [{ step: 11 }] }, 11), 'carried');
});
