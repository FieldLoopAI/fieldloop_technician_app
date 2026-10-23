const { requireTechnician } = require('./shared/auth');
const { getSupabaseClient } = require('./shared/supabaseClient');
const { getStripe } = require('./shared/stripeClient');
const {
  httpError, toCents, requireFeeRate, feeCentsFor, storedFeeMatches, assertJobOwner, tail6,
  parseFeePct, surchargeTotalCents,
} = require('./shared/payment_math');

// Build 185 payment routes (one Lambda, dispatched by method + path):
//   POST /invoices/checkout        -> create (or reuse) a Stripe Checkout session
//   GET  /invoices/payment-status  -> latest invoice's payment state for a job
//   GET  /stripe/return            -> static "return to the app" page (no auth)
// Only the stripe-webhook Lambda marks an invoice paid.

const DEFAULT_RETURN_BASE = 'https://tqb5mpwlpf.execute-api.us-east-1.amazonaws.com/dev/stripe/return';
// Stripe requires expires_at at least 30 minutes after creation; the extra
// minute keeps request latency from pushing it under that floor.
const CHECKOUT_TTL_SECONDS = 30 * 60 + 60;

const JSON_HEADERS = { 'Access-Control-Allow-Origin': '*', 'Content-Type': 'application/json' };

function json(statusCode, body) {
  return { statusCode, headers: JSON_HEADERS, body: JSON.stringify(body) };
}

// HTTP API payload v2 (requestContext.http.method + routeKey/rawPath) or
// v1 (httpMethod + resource/path). The stage prefix (/dev) is ignored by
// matching on the path's ending.
function routeOf(event) {
  const method = (event.requestContext?.http?.method || event.httpMethod || '').toUpperCase();
  const routeKey = event.routeKey || event.requestContext?.routeKey || '';
  const path = (routeKey.includes(' ') ? routeKey.split(' ')[1] : '') || event.resource || event.rawPath || event.path || '';
  return { method, path };
}

const RETURN_PATH = '/stripe/return';

// The return page URL, from STRIPE_RETURN_BASE (or the default). Accepts the
// API stage base (".../dev") or the full page (".../dev/stripe/return"),
// with or without a trailing slash: "/stripe/return" is appended when it's
// missing. Any query string on the base is kept; a fragment is dropped. An
// unparseable value falls back to the default.
function returnBase(configured = process.env.STRIPE_RETURN_BASE) {
  let url;
  try {
    url = new URL(String(configured || DEFAULT_RETURN_BASE).trim());
  } catch (_) {
    console.log('CHECKOUT: STRIPE_RETURN_BASE is not a valid URL — using the default');
    url = new URL(DEFAULT_RETURN_BASE);
  }
  let path = url.pathname.replace(/\/+$/, '');
  if (!path.endsWith(RETURN_PATH)) path += RETURN_PATH;
  url.pathname = path;
  url.hash = '';
  return url;
}

// success_url / cancel_url: the return page with ?status=<status>.
function returnUrl(status, configured) {
  const url = returnBase(configured);
  url.searchParams.set('status', status);
  return url.toString();
}

// Card-fee surcharge: on only when STRIPE_PASS_FEE is exactly "true"; then
// the customer also pays STRIPE_FEE_PCT (default 0.029) + STRIPE_FEE_FIXED_CENTS
// (default 30) as a separate Checkout line. null = off (today's behavior).
function passFeeConfig(env = process.env) {
  if (env.STRIPE_PASS_FEE !== 'true') return null;
  const pct = parseFeePct(env.STRIPE_FEE_PCT ?? '0.029');
  const rawFixed = env.STRIPE_FEE_FIXED_CENTS ?? '30';
  const fixedCents = /^\d+$/.test(String(rawFixed).trim()) ? Number(String(rawFixed).trim()) : NaN;
  if (!pct || !Number.isSafeInteger(fixedCents)) {
    throw httpError(500, 'Card processing fee is not configured correctly');
  }
  return { pct, fixedCents };
}

function returnPage() {
  return {
    statusCode: 200,
    headers: { 'Content-Type': 'text/html; charset=utf-8' },
    body: `<html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
      <body style="font-family:sans-serif;text-align:center;padding:40px;">
        <h2>Thank you. You can return to the FieldLoop app.</h2>
      </body></html>`,
  };
}

async function loadOwnedJob(supabase, jobId, technician) {
  if (!jobId) throw httpError(400, 'jobId is required');
  const { data: job, error } = await supabase
    .from('jobs').select('id, job_id_public, contractor_id, lead_technician_id').eq('id', jobId).maybeSingle();
  if (error) throw error;
  assertJobOwner(job, technician);
  return job;
}

async function latestInvoiceFor(supabase, jobId) {
  const { data, error } = await supabase
    .from('invoices').select('*')
    .eq('job_id', jobId)
    .order('created_at', { ascending: false })
    .limit(1);
  if (error) throw error;
  return (data || [])[0] || null;
}

async function createCheckout(event, deps) {
  const technician = await deps.requireTechnician(event);
  const { invoiceId } = JSON.parse(event.body || '{}');
  if (!invoiceId) throw httpError(400, 'invoiceId is required');
  const passFee = passFeeConfig();
  const supabase = await deps.getSupabaseClient();

  const { data: invoice, error: invoiceErr } = await supabase
    .from('invoices').select('*').eq('id', invoiceId).maybeSingle();
  if (invoiceErr) throw invoiceErr;
  if (!invoice) throw httpError(404, 'Invoice not found');
  const job = await loadOwnedJob(supabase, invoice.job_id, technician);

  const latest = await latestInvoiceFor(supabase, job.id);
  if (!latest || latest.id !== invoice.id) {
    throw httpError(409, 'A newer invoice exists for this job — collect payment on that one');
  }
  if (invoice.payment_status === 'paid') throw httpError(409, 'This invoice is already paid');

  const { stripe } = await deps.getStripe();

  if (invoice.payment_status === 'pending' && invoice.stripe_checkout_session_id) {
    const existing = await stripe.checkout.sessions.retrieve(invoice.stripe_checkout_session_id);
    if (existing.status === 'open' && existing.url) {
      console.log(`CHECKOUT: reuse open session invoice=${invoice.id} job=${job.id} session=${tail6(existing.id)}`);
      return json(200, {
        url: existing.url,
        sessionId: existing.id,
        amountCents: invoice.amount_cents,
        feeCents: invoice.application_fee_cents,
        ...(passFee ? {
          processingFeeCents: invoice.processing_fee_cents ?? null,
          chargeTotalCents: invoice.charge_total_cents ?? null,
        } : {}),
      });
    }
    if (existing.status === 'complete') {
      // Paid at Stripe, webhook not processed yet: never open a second charge.
      console.log(`CHECKOUT: session already complete invoice=${invoice.id} session=${tail6(existing.id)}`);
      throw httpError(409, 'Payment is already complete — waiting for confirmation');
    }
    console.log(`CHECKOUT: session expired, creating a new one invoice=${invoice.id} session=${tail6(existing.id)}`);
  }

  // Amount from the stored invoice row only — never recomputed from estimates.
  const totalCents = toCents(invoice.total);
  if (totalCents <= 0) throw httpError(409, 'Invoice total must be greater than zero');
  const feeRate = requireFeeRate(invoice.platform_fee_rate);
  if (!storedFeeMatches(totalCents, invoice.platform_fee, feeRate)) {
    console.log(`CHECKOUT: fee mismatch invoice=${invoice.id} storedFeeCents=${toCents(invoice.platform_fee)} expectedFeeCents=${feeCentsFor(totalCents, feeRate)}`);
    throw httpError(409, 'The stored platform fee does not match the fee rate — regenerate the invoice');
  }
  const feeCents = toCents(invoice.platform_fee);

  const { data: financials, error: finErr } = await supabase
    .from('contractor_financials').select('stripe_account_id').eq('contractor_id', job.contractor_id).maybeSingle();
  if (finErr) throw finErr;
  const destination = financials?.stripe_account_id;
  if (!destination) throw httpError(409, 'This contractor has no Stripe account connected');

  const lineItems = [{
    price_data: {
      currency: 'usd',
      unit_amount: totalCents,
      product_data: { name: `Invoice ${invoice.invoice_number} - ${job.job_id_public}` },
    },
    quantity: 1,
  }];
  let applicationFeeCents = feeCents;
  let surcharge = null;
  if (passFee) {
    // The customer pays Stripe's fee on top; the platform keeps feeCents
    // after Stripe takes its fee from the application fee.
    const chargeTotalCents = surchargeTotalCents(totalCents, passFee.pct, passFee.fixedCents);
    const processingFeeCents = chargeTotalCents - totalCents;
    if (processingFeeCents > 0) {
      lineItems.push({
        price_data: { currency: 'usd', unit_amount: processingFeeCents, product_data: { name: 'Card processing fee' } },
        quantity: 1,
      });
    }
    applicationFeeCents = processingFeeCents + feeCents;
    surcharge = { processingFeeCents, chargeTotalCents };
    console.log(`CHECKOUT: card processing fee passed to the customer invoice=${invoice.id}`);
  }

  const attempt = Number(invoice.checkout_attempts) || 0;
  const base = returnBase();
  console.log(`CHECKOUT: returnUrl=${base.host}${base.pathname}`);
  const session = await stripe.checkout.sessions.create({
    // No payment_method_types: API 2026-09-30.endive rejects it; payment
    // methods come from the Stripe Dashboard settings (card only).
    mode: 'payment',
    line_items: lineItems,
    payment_intent_data: {
      application_fee_amount: applicationFeeCents,
      transfer_data: { destination },
      metadata: { invoice_id: invoice.id, job_id: job.id },
    },
    metadata: { invoice_id: invoice.id, job_id: job.id },
    client_reference_id: invoice.id,
    expires_at: Math.floor(Date.now() / 1000) + CHECKOUT_TTL_SECONDS,
    success_url: returnUrl('success'),
    cancel_url: returnUrl('cancel'),
  }, { idempotencyKey: `invoice_${invoice.id}_${attempt}` });

  const { data: updated, error: updateErr } = await supabase
    .from('invoices').update({
      payment_status: 'pending',
      payment_initiated_at: new Date().toISOString(),
      stripe_checkout_session_id: session.id,
      amount_cents: totalCents,
      application_fee_cents: feeCents,
      checkout_attempts: attempt + 1,
      ...(surcharge ? {
        processing_fee_cents: surcharge.processingFeeCents,
        charge_total_cents: surcharge.chargeTotalCents,
      } : {}),
    })
    .eq('id', invoice.id)
    .neq('payment_status', 'paid')
    .select('id');
  if (updateErr) throw updateErr;
  if (!updated || updated.length === 0) throw httpError(409, 'This invoice is already paid');

  console.log(`CHECKOUT: created invoice=${invoice.id} job=${job.id} amountCents=${totalCents} feeCents=${feeCents} attempt=${attempt} session=${tail6(session.id)} destination=${tail6(destination)}`);
  return json(200, {
    url: session.url, sessionId: session.id, amountCents: totalCents, feeCents,
    ...(surcharge ? { processingFeeCents: surcharge.processingFeeCents, chargeTotalCents: surcharge.chargeTotalCents } : {}),
  });
}

async function paymentStatus(event, deps) {
  const technician = await deps.requireTechnician(event);
  const jobId = event.queryStringParameters?.jobId;
  const supabase = await deps.getSupabaseClient();
  const job = await loadOwnedJob(supabase, jobId, technician);
  const invoice = await latestInvoiceFor(supabase, job.id);
  return json(200, {
    invoice: invoice
      ? {
        id: invoice.id,
        invoice_number: invoice.invoice_number,
        payment_status: invoice.payment_status,
        paid_at: invoice.paid_at ?? null,
        total: invoice.total,
        ...(process.env.STRIPE_PASS_FEE === 'true' ? {
          processing_fee_cents: invoice.processing_fee_cents ?? null,
          charge_total_cents: invoice.charge_total_cents ?? null,
        } : {}),
      }
      : null,
  });
}

async function handle(event, deps) {
  const { method, path } = routeOf(event);
  try {
    if (method === 'GET' && path.endsWith('/stripe/return')) return returnPage();
    if (method === 'POST' && path.endsWith('/invoices/checkout')) return await createCheckout(event, deps);
    if (method === 'GET' && path.endsWith('/invoices/payment-status')) return await paymentStatus(event, deps);
    return json(404, { error: 'Not found' });
  } catch (err) {
    console.log(`INVOICE PAYMENT ERROR: ${method} ${path} status=${err.statusCode || 400} ${err.message}`);
    return json(err.statusCode || 400, { error: err.message });
  }
}

exports.handler = (event) => handle(event, { requireTechnician, getSupabaseClient, getStripe });
exports._handle = handle;
exports._routeOf = routeOf;
exports._returnUrl = returnUrl;
exports._passFeeConfig = passFeeConfig;
