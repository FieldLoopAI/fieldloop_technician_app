// The customer's change-order page (SMS link): only a 'pending', unvoided
// change order can be answered; ?decision= only shows a confirmation, the
// change needs &confirm=1; the conditional update's result is checked
// (lock trigger, other errors, zero rows); approved_at is set on approve
// and cleared on decline, as before; every value in the HTML is escaped.
// Run with: node --test "test/*.test.js" (from approve-change-order/).
// Offline: Supabase is stubbed (the fake is generate-invoice-pdf's test
// double).
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { fakeSupabase } = require('../../generate-invoice-pdf/test/fake_supabase');

const dir = path.join(__dirname, '..');
let currentDb = null;

function stub(file, exports) {
  const resolved = require.resolve(path.join(dir, 'shared', file));
  require.cache[resolved] = { id: resolved, filename: resolved, loaded: true, exports };
}
stub('supabaseClient.js', { getSupabaseClient: async () => currentDb });

const { handler } = require('../index');

const CO_ID = 'co-1';

function changeOrder(overrides = {}) {
  return {
    id: CO_ID, job_id: 'job-1', status: 'pending', voided_at: null, approved_at: null,
    description: 'Replace the valve', additional_amount: 120,
    ...overrides,
  };
}

function db(row = changeOrder()) {
  return fakeSupabase({ change_orders: [row] });
}

/** A db whose change_orders update resolves to [result] instead of running. */
function withUpdateResult(base, result) {
  return {
    ...base,
    from(table) {
      const b = base.from(table);
      if (table === 'change_orders') {
        b.update = () => {
          const chain = { eq: () => chain, is: () => chain, select: () => chain };
          chain.then = (resolve, reject) => Promise.resolve(result).then(resolve, reject);
          return chain;
        };
      }
      return b;
    },
  };
}

async function open(database, query) {
  currentDb = database;
  return handler({ pathParameters: { id: CO_ID }, queryStringParameters: query ?? null });
}

const updates = database => database.calls.filter(c => c.op === 'update');

test('old link (GET, no decision) shows the change order with Approve/Decline, and changes nothing', async () => {
  const d = db();
  const res = await open(d);
  assert.equal(res.statusCode, 200);
  assert.match(res.body, /<h2>Change Order Approval<\/h2>/);
  assert.match(res.body, /Replace the valve/);
  assert.match(res.body, /\$120\.00/);
  assert.match(res.body, /href="\?decision=approve"/);
  assert.match(res.body, /href="\?decision=decline"/);
  assert.equal(updates(d).length, 0);
});

test('?decision= without confirm only shows a confirmation form', async () => {
  for (const decision of ['approve', 'decline']) {
    const d = db();
    const res = await open(d, { decision });
    assert.equal(res.statusCode, 200);
    const verb = decision === 'approve' ? 'Approve' : 'Decline';
    assert.match(res.body, new RegExp(`<h2>${verb} this change order of \\$120\\.00\\?</h2>`));
    assert.match(res.body, /Replace the valve/);
    assert.match(res.body, /<form method="get"/);
    assert.match(res.body, new RegExp(`name="decision" value="${decision}"`));
    assert.match(res.body, /name="confirm" value="1"/);
    assert.match(res.body, /href="\?">Go back/);
    assert.doesNotMatch(res.body, /Approved ✓/);
    assert.equal(updates(d).length, 0);
    assert.equal(d.tables.change_orders[0].status, 'pending');
  }
});

test('confirmed approve: approved with approved_at set', async () => {
  const d = db();
  const res = await open(d, { decision: 'approve', confirm: '1' });
  assert.equal(res.statusCode, 200);
  assert.match(res.body, /<h2>Approved ✓<\/h2>/);
  const row = d.tables.change_orders[0];
  assert.equal(row.status, 'approved');
  assert.ok(!Number.isNaN(Date.parse(row.approved_at)));
});

test('confirmed decline: declined with approved_at null', async () => {
  const d = db();
  const res = await open(d, { decision: 'decline', confirm: '1' });
  assert.equal(res.statusCode, 200);
  assert.match(res.body, /<h2>Declined<\/h2>/);
  const row = d.tables.change_orders[0];
  assert.equal(row.status, 'declined');
  assert.equal(row.approved_at, null);
  assert.deepEqual(updates(d)[0].payload, { status: 'declined', approved_at: null });
});

test('already approved / declined: "already answered", never changed', async () => {
  for (const status of ['approved', 'declined']) {
    for (const decision of ['approve', 'decline']) {
      const d = db(changeOrder({ status, approved_at: status === 'approved' ? '2026-10-20T00:00:00Z' : null }));
      const res = await open(d, { decision, confirm: '1' });
      assert.equal(res.statusCode, 409);
      assert.match(res.body, /<h2>This change order was already answered<\/h2>/);
      assert.match(res.body, new RegExp(`It was ${status}`));
      assert.doesNotMatch(res.body, /Approved ✓/);
      assert.equal(updates(d).length, 0);
      assert.equal(d.tables.change_orders[0].status, status);
    }
  }
});

test('voided (and an unknown status) is not available and never changed', async () => {
  const voided = db(changeOrder({ status: 'approved', voided_at: '2026-10-21T00:00:00Z' }));
  let res = await open(voided, { decision: 'decline', confirm: '1' });
  assert.equal(res.statusCode, 409);
  assert.match(res.body, /<h2>This change order is no longer available<\/h2>/);
  assert.equal(voided.tables.change_orders[0].status, 'approved');

  const voidedPending = db(changeOrder({ voided_at: '2026-10-21T00:00:00Z' }));
  res = await open(voidedPending, { decision: 'approve', confirm: '1' });
  assert.equal(res.statusCode, 409);
  assert.equal(voidedPending.tables.change_orders[0].status, 'pending');

  const other = db(changeOrder({ status: 'draft' }));
  res = await open(other, { decision: 'approve', confirm: '1' });
  assert.equal(res.statusCode, 409);
  assert.match(res.body, /<h2>This change order is not available<\/h2>/);
  assert.equal(updates(voided).length + updates(voidedPending).length + updates(other).length, 0);
});

test('payment-lock trigger refusal shows "already being paid", never Approved', async () => {
  const d = withUpdateResult(db(), {
    data: null, error: { code: 'P0001', message: 'Payment started - invoice is locked' },
  });
  const res = await open(d, { decision: 'approve', confirm: '1' });
  assert.equal(res.statusCode, 409);
  assert.match(res.body, /<h2>This job is already being paid; contact your technician<\/h2>/);
  assert.doesNotMatch(res.body, /Approved ✓/);
});

test('any other update error shows a failure page, never Approved or the error text', async () => {
  const d = withUpdateResult(db(), { data: null, error: { code: 'XX000', message: 'boom <b>' } });
  const res = await open(d, { decision: 'approve', confirm: '1' });
  assert.equal(res.statusCode, 500);
  assert.match(res.body, /<h2>We couldn't record your answer<\/h2>/);
  assert.doesNotMatch(res.body, /Approved ✓|boom/);
});

test('zero rows changed shows "already answered or no longer available", never Approved', async () => {
  const d = withUpdateResult(db(), { data: [], error: null });
  const res = await open(d, { decision: 'approve', confirm: '1' });
  assert.equal(res.statusCode, 409);
  assert.match(res.body, /<h2>This change order was already answered or is no longer available<\/h2>/);
  assert.doesNotMatch(res.body, /Approved ✓/);
});

test('the update only matches a row still pending: answered in between -> zero rows', async () => {
  const d = db();
  // The customer declines in another tab after this request's read.
  const base = d.from;
  d.from = (table) => {
    const b = base(table);
    const update = b.update;
    b.update = (payload) => {
      d.tables.change_orders[0].status = 'declined';
      return update(payload);
    };
    return b;
  };
  const res = await open(d, { decision: 'approve', confirm: '1' });
  assert.equal(res.statusCode, 409);
  assert.match(res.body, /already answered or is no longer available/);
  assert.equal(d.tables.change_orders[0].status, 'declined');
  assert.equal(d.tables.change_orders[0].approved_at, null);
});

test('every value put in the HTML is escaped', async () => {
  const evil = '<script>alert("x")</script>&\'';
  const escaped = /&lt;script&gt;alert\(&quot;x&quot;\)&lt;\/script&gt;&amp;&#39;/;
  for (const query of [null, { decision: 'approve' }, { decision: 'approve', confirm: '1' }]) {
    const d = db(changeOrder({ description: evil, additional_amount: '<b>5</b>' }));
    const res = await open(d, query);
    assert.doesNotMatch(res.body, /<script>/);
    assert.match(res.body, escaped);
    assert.doesNotMatch(res.body, /<b>5<\/b>/);
  }
  const answered = db(changeOrder({ status: 'approved', description: evil }));
  const res = await open(answered, { decision: 'approve', confirm: '1' });
  assert.doesNotMatch(res.body, /<script>/);
  assert.match(res.body, escaped);
});

test('unexpected error -> generic 500 page without the error text', async () => {
  currentDb = { from() { throw new Error('secret <detail>'); } };
  const res = await handler({ pathParameters: { id: CO_ID }, queryStringParameters: null });
  assert.equal(res.statusCode, 500);
  assert.match(res.body, /<h2>We couldn't record your answer<\/h2>/);
  assert.doesNotMatch(res.body, /secret|detail/);
});

test('unknown change order -> 404; id from a JSON body still works; unknown decision shows the page', async () => {
  let res = await open(fakeSupabase({ change_orders: [] }), { decision: 'approve', confirm: '1' });
  assert.equal(res.statusCode, 404);
  assert.match(res.body, /<h1>Not found<\/h1>/);

  currentDb = db();
  res = await handler({ body: JSON.stringify({ id: CO_ID }), queryStringParameters: null });
  assert.equal(res.statusCode, 200);
  assert.match(res.body, /Change Order Approval/);

  const d = db();
  res = await open(d, { decision: 'yes', confirm: '1' });
  assert.equal(res.statusCode, 200);
  assert.match(res.body, /href="\?decision=approve"/);
  assert.equal(updates(d).length, 0);
});
