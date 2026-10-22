const test = require('node:test');
const assert = require('node:assert/strict');
const m = require('../shared/payment_math');

test('demo invoice: $3,619.00 at 0.0195 -> fee 7057, net 354843', () => {
  const { totalCents, feeCents, netCents } = m.invoiceCents(3619, 0.0195);
  assert.equal(totalCents, 361900);
  assert.equal(feeCents, 7057);
  assert.equal(netCents, 354843);
  assert.equal(feeCents + netCents, totalCents);
});

test('numeric strings from Postgres convert the same', () => {
  assert.deepEqual(m.invoiceCents('3619.00', '0.0195'), { totalCents: 361900, feeCents: 7057, netCents: 354843 });
});

test('no float drift on sums like 0.1 + 0.2', () => {
  assert.equal(m.toCents(0.1 + 0.2), 30);
  assert.equal(m.toCents(1.15), 115);
  assert.equal(m.toCents(4.35), 435);
  assert.equal(m.toCents(1234.56 + 0.07), 123463);
  assert.equal(m.toCents(19.99 * 3), 5997);
  const { totalCents, feeCents, netCents } = m.invoiceCents(0.1 + 0.2, 0.0195);
  assert.equal(totalCents, 30);
  assert.equal(feeCents + netCents, 30);
});

test('fee and net are always integers that sum to the total', () => {
  for (const total of [0.01, 9.99, 100, 2500.5, 3619, 98765.43]) {
    const { totalCents, feeCents, netCents } = m.invoiceCents(total, 0.0195);
    assert.ok(Number.isInteger(feeCents) && Number.isInteger(netCents));
    assert.equal(feeCents + netCents, totalCents);
  }
});

test('missing, zero, negative or non-numeric fee rate throws (no 2% fallback)', () => {
  for (const bad of [null, undefined, '', 0, '0', -0.01, 'abc', NaN]) {
    assert.throws(() => m.requireFeeRate(bad), /Platform fee rate is not configured/);
    assert.throws(() => m.invoiceCents(3619, bad), /Platform fee rate is not configured/);
  }
});

test('toCents rejects non-numbers', () => {
  for (const bad of [null, undefined, '', 'x', NaN, Infinity]) {
    assert.throws(() => m.toCents(bad), /not a number/);
  }
});

test('storedFeeMatches allows 1 cent, refuses 2', () => {
  assert.equal(m.storedFeeMatches(361900, 70.57, 0.0195), true);
  assert.equal(m.storedFeeMatches(361900, 70.58, 0.0195), true);
  assert.equal(m.storedFeeMatches(361900, 70.59, 0.0195), false);
  assert.equal(m.storedFeeMatches(361900, 72.38, 0.0195), false); // the old 2% value
});

test('freeze statuses', () => {
  assert.equal(m.isPaymentFrozen('pending'), true);
  assert.equal(m.isPaymentFrozen('paid'), true);
  assert.equal(m.isPaymentFrozen('unpaid'), false);
  assert.equal(m.isPaymentFrozen(undefined), false);
});

test('ownership guard', () => {
  assert.throws(() => m.assertJobOwner(null, { id: 't1' }), err => err.statusCode === 404);
  assert.throws(() => m.assertJobOwner({ lead_technician_id: 't2' }, { id: 't1' }), err => err.statusCode === 403);
  assert.doesNotThrow(() => m.assertJobOwner({ lead_technician_id: 't1' }, { id: 't1' }));
});

test('tail6 logs only the last 6 characters', () => {
  assert.equal(m.tail6('cs_test_abcdef123456'), '123456');
  assert.equal(m.tail6(null), 'none');
});
