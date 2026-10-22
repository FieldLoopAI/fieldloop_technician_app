// In-memory stand-in for the supabase-js query builder — just the calls
// the B185 Lambdas use. Select column lists and joins are ignored (whole
// rows come back). `failOn` makes one table+op return an error.
function fakeSupabase(tables, { failOn = [] } = {}) {
  const calls = [];

  function from(table) {
    const st = { table, op: 'select', filters: [], order: null, limit: null, payload: null, single: null };
    const rows = () => (tables[table] = tables[table] || []);

    function run() {
      calls.push({ table, op: st.op, payload: st.payload });
      if (failOn.some(f => f.table === table && f.op === st.op)) {
        return { data: null, error: { code: 'XX000', message: `injected ${st.op} failure on ${table}` } };
      }
      const match = r => st.filters.every(f => f(r));
      if (st.op === 'insert') {
        const items = Array.isArray(st.payload) ? st.payload : [st.payload];
        for (const item of items) {
          if (item.id !== undefined && rows().some(r => r.id === item.id)) {
            return { data: null, error: { code: '23505', message: 'duplicate key value violates unique constraint' } };
          }
        }
        const inserted = items.map(item => ({ id: item.id ?? `row-${rows().length + 1}`, ...item }));
        rows().push(...inserted);
        return finish(inserted);
      }
      if (st.op === 'update') {
        const hit = rows().filter(match);
        hit.forEach(r => Object.assign(r, st.payload));
        return finish(hit);
      }
      if (st.op === 'delete') {
        const keep = rows().filter(r => !match(r));
        const removed = rows().length - keep.length;
        tables[table] = keep;
        return { data: null, error: null, count: removed };
      }
      let out = rows().filter(match);
      if (st.order) {
        const [col, asc] = st.order;
        out = [...out].sort((a, b) => (a[col] < b[col] ? -1 : a[col] > b[col] ? 1 : 0) * (asc ? 1 : -1));
      }
      if (st.limit != null) out = out.slice(0, st.limit);
      return finish(out);
    }

    function finish(list) {
      if (st.single === 'maybe') return { data: list[0] ?? null, error: null };
      if (st.single === 'one') {
        return list.length === 1
          ? { data: list[0], error: null }
          : { data: null, error: { code: 'PGRST116', message: 'not exactly one row' } };
      }
      return { data: list.map(r => ({ ...r })), error: null };
    }

    const b = {
      select() { return b; },
      insert(p) { st.op = 'insert'; st.payload = p; return b; },
      update(p) { st.op = 'update'; st.payload = p; return b; },
      delete() { st.op = 'delete'; return b; },
      eq(c, v) { st.filters.push(r => r[c] === v); return b; },
      neq(c, v) { st.filters.push(r => r[c] !== v); return b; },
      in(c, vs) { st.filters.push(r => vs.includes(r[c])); return b; },
      is(c, v) { st.filters.push(r => (r[c] ?? null) === v); return b; },
      gt(c, v) { st.filters.push(r => r[c] > v); return b; },
      order(c, { ascending = true } = {}) { st.order = [c, ascending]; return b; },
      limit(n) { st.limit = n; return b; },
      maybeSingle() { st.single = 'maybe'; return b; },
      single() { st.single = 'one'; return b; },
      then(resolve, reject) { return Promise.resolve().then(run).then(resolve, reject); },
    };
    return b;
  }

  return { from, calls, tables };
}

module.exports = { fakeSupabase };
