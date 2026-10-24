// The customer's estimate page (SMS link): only a 'sent', unvoided estimate
// can be answered; ?decision= only shows a confirmation, the change needs
// &confirm=1; the conditional update's result is checked (lock trigger,
// other errors, zero rows); every value in the HTML is escaped.
// Run with: node --test "test/*.test.js" (from approve-estimate/).
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

const EST_ID = 'est-1';

function estimate(overrides = {}) {
  return {
    id: EST_ID, job_id: 'job-1', status: 'sent', voided_at: null, total_amount: 230,
    line_items: [{ description: 'Valve', amount: 150 }, { description: 'Labor', amount: 80 }],
    ...overrides,
  };
}

function db(row = estimate()) {
  return fakeSupabase({ job_estimates: [row] });
}

/** A db whose job_estimates update resolves to [result] instead of running. */
function withUpdateResult(base, result) {
  return {
    ...base,
    from(table) {
      const b = base.from(table);
      if (table === 'job_estimates') {
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
  return handler({ pathParameters: { id: EST_ID }, queryStringParameters: query ?? null });
}

const updates = database => database.calls.filter(c => c.op === 'update');

test('the link with no decision shows the estimate with Approve/Decline, and changes nothing', async () => {
  const d = db();
  const res = await open(d);
  assert.equal(res.statusCode, 200);
  assert.match(res.body, /href="\?decision=approve"/);
  assert.match(res.body, /href="\?decision=decline"/);
  assert.match(res.body, /Total: \$230\.00/);
  assert.equal(updates(d).length, 0);
});

test('?decision=approve without confirm only shows a confirmation form', async () => {
  for (const decision of ['approve', 'decline']) {
    const d = db();
    const res = await open(d, { decision });
    assert.equal(res.statusCode, 200);
    assert.match(res.body, /<form method="get"/);
    assert.match(res.body, new RegExp(`name="decision" value="${decision}"`));
    assert.match(res.body, /name="confirm" value="1"/);
    assert.doesNotMatch(res.body, /Approved ✓/);
    assert.equal(updates(d).length, 0);
    assert.equal(d.tables.job_estimates[0].status, 'sent');
  }
});

test('confirmed approve and decline change a sent estimate', async () => {
  let d = db();
  let res = await open(d, { decision: 'approve', confirm: '1' });
  assert.equal(res.statusCode, 200);
  assert.match(res.body, /Approved ✓/);
  assert.equal(d.tables.job_estimates[0].status, 'approved');

  d = db();
  res = await open(d, { decision: 'decline', confirm: '1' });
  assert.equal(res.statusCode, 200);
  assert.match(res.body, /<h2>Declined<\/h2>/);
  assert.equal(d.tables.job_estimates[0].status, 'declined');
});

test('approved / declined estimates are never changed: "already answered"', async () => {
  for (const status of ['approved', 'declined']) {
    for (const decision of ['approve', 'decline']) {
      const d = db(estimate({ status }));
      const res = await open(d, { decision, confirm: '1' });
      assert.equal(res.statusCode, 409);
      assert.match(res.body, /This estimate was already answered/);
      assert.match(res.body, new RegExp(`It was ${status}`));
      assert.doesNotMatch(res.body, /Approved ✓/);
      assert.equal(updates(d).length, 0);
      assert.equal(d.tables.job_estimates[0].status, status);
    }
  }
});

test('voided and draft estimates are not available and never changed', async () => {
  const voided = db(estimate({ status: 'approved', voided_at: '2026-10-20T00:00:00Z' }));
  let res = await open(voided, { decision: 'decline', confirm: '1' });
  assert.equal(res.statusCode, 409);
  assert.match(res.body, /no longer available/);
  assert.equal(voided.tables.job_estimates[0].status, 'approved');

  const voidedSent = db(estimate({ voided_at: '2026-10-20T00:00:00Z' }));
  res = await open(voidedSent, { decision: 'approve', confirm: '1' });
  assert.equal(res.statusCode, 409);
  assert.equal(voidedSent.tables.job_estimates[0].status, 'sent');

  const draft = db(estimate({ status: 'draft' }));
  res = await open(draft, { decision: 'approve', confirm: '1' });
  assert.equal(res.statusCode, 409);
  assert.match(res.body, /not available/);
  assert.equal(draft.tables.job_estimates[0].status, 'draft');
  assert.equal(updates(voided).length + updates(voidedSent).length + updates(draft).length, 0);
});

test('payment-lock trigger refusal shows "already being paid", never Approved', async () => {
  const d = withUpdateResult(db(), {
    data: null, error: { code: 'P0001', message: 'Payment started - invoice is locked' },
  });
  const res = await open(d, { decision: 'approve', confirm: '1' });
  assert.equal(res.statusCode, 409);
  assert.match(res.body, /This job is already being paid; contact your technician/);
  assert.doesNotMatch(res.body, /Approved ✓/);
});

test('any other update error shows a failure page, never Approved', async () => {
  const d = withUpdateResult(db(), { data: null, error: { code: 'XX000', message: 'boom <b>' } });
  const res = await open(d, { decision: 'approve', confirm: '1' });
  assert.equal(res.statusCode, 500);
  assert.match(res.body, /We couldn't record your answer/);
  assert.doesNotMatch(res.body, /Approved ✓|boom/);
});

test('zero rows changed (answered in between) shows "already answered", never Approved', async () => {
  const d = withUpdateResult(db(), { data: [], error: null });
  const res = await open(d, { decision: 'approve', confirm: '1' });
  assert.equal(res.statusCode, 409);
  assert.match(res.body, /already answered or is no longer available/);
  assert.doesNotMatch(res.body, /Approved ✓/);
});

test('the update is conditional on status sent and not voided', async () => {
  const d = db();
  // The customer declines in another tab after this request's read: the
  // real (fake) conditional update must then match nothing.
  const base = d.from;
  d.from = (table) => {
    const b = base(table);
    const update = b.update;
    b.update = (payload) => {
      d.tables.job_estimates[0].status = 'declined';
      return update(payload);
    };
    return b;
  };
  const res = await open(d, { decision: 'approve', confirm: '1' });
  assert.equal(res.statusCode, 409);
  assert.match(res.body, /already answered or is no longer available/);
  assert.equal(d.tables.job_estimates[0].status, 'declined');
  assert.equal(updates(d).length, 1);
});

test('every value put in the HTML is escaped', async () => {
  const evil = '<script>alert("x")</script>&\'';
  const d = db(estimate({ line_items: [{ description: evil, amount: 5 }], total_amount: '<b>5</b>' }));
  for (const query of [null, { decision: 'approve' }]) {
    const res = await open(d, query);
    assert.doesNotMatch(res.body, /<script>/);
    assert.match(res.body, /&lt;script&gt;alert\(&quot;x&quot;\)&lt;\/script&gt;&amp;&#39;/);
    assert.doesNotMatch(res.body, /<b>5<\/b>/);
  }
  const answered = db(estimate({ status: 'approved', line_items: [{ description: evil, amount: 5 }] }));
  const res = await open(answered, { decision: 'approve', confirm: '1' });
  assert.doesNotMatch(res.body, /<script>/);
});

test('unknown estimate -> 404; an unknown decision just shows the estimate', async () => {
  let res = await open(fakeSupabase({ job_estimates: [] }), { decision: 'approve', confirm: '1' });
  assert.equal(res.statusCode, 404);
  const d = db();
  res = await open(d, { decision: 'yes', confirm: '1' });
  assert.equal(res.statusCode, 200);
  assert.match(res.body, /href="\?decision=approve"/);
  assert.equal(updates(d).length, 0);
});
