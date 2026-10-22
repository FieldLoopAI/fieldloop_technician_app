const { getSupabaseClient } = require('./shared/supabaseClient');
const { getStripe } = require('./shared/stripeClient');
const { tail6 } = require('./shared/payment_math');

// Build 185: POST /stripe/webhook (no auth — the Stripe signature is the
// auth). The only place an invoice becomes 'paid'. jobs.status is never
// touched.

const PAID_EVENTS = ['checkout.session.completed', 'checkout.session.async_payment_succeeded'];

function reply(statusCode, body) {
  return { statusCode, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) };
}

// Header lookup that works for payload v1 (mixed case, maybe
// multiValueHeaders) and v2 (lowercase).
function headerValue(event, name) {
  const wanted = name.toLowerCase();
  for (const [key, value] of Object.entries(event.headers || {})) {
    if (key.toLowerCase() === wanted && value) return value;
  }
  for (const [key, values] of Object.entries(event.multiValueHeaders || {})) {
    if (key.toLowerCase() === wanted && Array.isArray(values) && values.length > 0) return values[0];
  }
  return null;
}

// The exact bytes Stripe signed.
function rawBodyOf(event) {
  return Buffer.from(event.body || '', event.isBase64Encoded ? 'base64' : 'utf8');
}

async function markPaid(supabase, session) {
  const { data: invoice, error } = await supabase
    .from('invoices').select('id, job_id, amount_cents, payment_status')
    .eq('stripe_checkout_session_id', session.id).maybeSingle();
  if (error) throw error;
  if (!invoice) {
    console.log(`STRIPE WEBHOOK: no invoice for session=${tail6(session.id)}`);
    return 'no_invoice';
  }
  if (session.amount_total !== invoice.amount_cents) {
    console.log(`STRIPE WEBHOOK: AMOUNT MISMATCH invoice=${invoice.id} job=${invoice.job_id} sessionCents=${session.amount_total} invoiceCents=${invoice.amount_cents} — not marked paid`);
    return 'amount_mismatch';
  }
  if (invoice.payment_status === 'paid') return 'already_paid';
  const paymentIntentId = typeof session.payment_intent === 'string'
    ? session.payment_intent
    : session.payment_intent?.id || null;
  const { error: updateErr } = await supabase
    .from('invoices').update({
      payment_status: 'paid',
      paid_at: new Date().toISOString(),
      stripe_payment_intent_id: paymentIntentId,
    })
    .eq('id', invoice.id)
    .neq('payment_status', 'paid');
  if (updateErr) throw updateErr;
  console.log(`STRIPE WEBHOOK: PAID invoice=${invoice.id} job=${invoice.job_id} amountCents=${invoice.amount_cents} pi=${tail6(paymentIntentId)}`);
  return 'paid';
}

async function markExpired(supabase, session) {
  const { data, error } = await supabase
    .from('invoices').update({ payment_status: 'unpaid' })
    .eq('stripe_checkout_session_id', session.id)
    .eq('payment_status', 'pending')
    .select('id');
  if (error) throw error;
  const reset = data && data.length > 0;
  console.log(`STRIPE WEBHOOK: session expired session=${tail6(session.id)} reset=${reset}${reset ? ` invoice=${data[0].id}` : ''}`);
  return reset ? 'reset_unpaid' : 'expired_ignored';
}

async function processEvent(supabase, stripeEvent) {
  const session = stripeEvent.data?.object || {};
  if (PAID_EVENTS.includes(stripeEvent.type)) {
    if (session.payment_status !== 'paid') {
      console.log(`STRIPE WEBHOOK: ${stripeEvent.type} not paid yet session=${tail6(session.id)}`);
      return 'not_paid';
    }
    return markPaid(supabase, session);
  }
  if (stripeEvent.type === 'checkout.session.expired') return markExpired(supabase, session);
  return 'ignored';
}

async function handle(event, deps) {
  let stripeEvent;
  try {
    const { stripe, webhookSecret } = await deps.getStripe();
    if (!webhookSecret) throw new Error('webhookSecret missing from the Stripe secret');
    const signature = headerValue(event, 'stripe-signature');
    if (!signature) return reply(400, { error: 'Missing signature' });
    try {
      stripeEvent = stripe.webhooks.constructEvent(rawBodyOf(event), signature, webhookSecret);
    } catch (err) {
      console.log('STRIPE WEBHOOK: bad signature');
      return reply(400, { error: 'Bad signature' });
    }
  } catch (err) {
    console.log(`STRIPE WEBHOOK: setup failed ${err.message}`);
    return reply(500, { error: 'Webhook not configured' });
  }

  let supabase;
  try {
    supabase = await deps.getSupabaseClient();
    const { error: dedupeErr } = await supabase.from('stripe_events').insert({ id: stripeEvent.id });
    if (dedupeErr) {
      if (dedupeErr.code === '23505') {
        console.log(`STRIPE WEBHOOK: duplicate event=${tail6(stripeEvent.id)} type=${stripeEvent.type}`);
        return reply(200, { received: true, duplicate: true });
      }
      throw dedupeErr;
    }
  } catch (err) {
    console.log(`STRIPE WEBHOOK: dedupe insert failed event=${tail6(stripeEvent.id)} ${err.message}`);
    return reply(500, { error: 'Database error' });
  }

  try {
    const outcome = await processEvent(supabase, stripeEvent);
    console.log(`STRIPE WEBHOOK: event=${tail6(stripeEvent.id)} type=${stripeEvent.type} outcome=${outcome}`);
    return reply(200, { received: true });
  } catch (err) {
    // Forget the event so Stripe's retry is processed, not skipped as a dupe.
    console.log(`STRIPE WEBHOOK: processing failed event=${tail6(stripeEvent.id)} type=${stripeEvent.type} ${err.message}`);
    try {
      await supabase.from('stripe_events').delete().eq('id', stripeEvent.id);
    } catch (_) { /* best effort; Stripe retries regardless */ }
    return reply(500, { error: 'Database error' });
  }
}

exports.handler = (event) => handle(event, { getSupabaseClient, getStripe });
exports._handle = handle;
exports._headerValue = headerValue;
