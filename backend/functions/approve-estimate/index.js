const { getSupabaseClient } = require('./shared/supabaseClient');

// The customer's estimate page, reached from the SMS link
// (/estimates/{id}/view). Public: the estimate UUID is the only key, so:
//  - only a 'sent', not-voided estimate can be answered; anything else gets
//    an "already answered" / "not available" page and is never changed;
//  - ?decision=approve|decline (the existing link and buttons) only shows a
//    confirmation page; the status changes on the confirmed request
//    (&confirm=1, submitted by that page's form), so link previews and
//    scanners that follow links cannot approve;
//  - the update is conditional on status 'sent' and its result is checked:
//    an error or zero changed rows never shows "Approved";
//  - every value put in the HTML is escaped.

// raise exception text from reject_write_when_payment_locked
// (supabase/migrations/20261023_payment_freeze.sql).
const PAYMENT_LOCKED = 'Payment started - invoice is locked';

const BUTTON = 'display:inline-block;color:white;padding:15px 30px;margin:10px;text-decoration:none;'
  + 'border-radius:8px;border:0;font-size:16px;cursor:pointer;';

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, c => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
  ));
}

function money(value) {
  const n = Number(value);
  return `$${(Number.isFinite(n) ? n : 0).toFixed(2)}`;
}

function page(statusCode, title, inner) {
  return {
    statusCode,
    headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' },
    body: `<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">`
      + `<meta name="robots" content="noindex"><title>${escapeHtml(title)}</title></head>`
      + `<body style="font-family:sans-serif;text-align:center;padding:40px;max-width:500px;margin:0 auto;">`
      + `${inner}</body></html>`,
  };
}

function itemsTable(estimate) {
  const items = Array.isArray(estimate.line_items) ? estimate.line_items : [];
  const rows = items.map(i =>
    `<tr><td style="padding:8px;text-align:left;">${escapeHtml(i?.description)}</td>`
    + `<td style="padding:8px;text-align:right;">${escapeHtml(money(i?.amount))}</td></tr>`
  ).join('');
  return `<table style="width:100%;border-collapse:collapse;">${rows}</table>`
    + `<p style="font-size:24px;font-weight:bold;margin-top:20px;">Total: ${escapeHtml(money(estimate.total_amount))}</p>`;
}

const notFound = () => page(404, 'Not found', '<h1>Not found</h1>');

const failed = () => page(500, 'Something went wrong',
  "<h2>We couldn't record your answer</h2><p>Please try the link again, or contact your technician.</p>");

// Not 'sent' (or voided): show why, change nothing.
function notAnswerable(estimate) {
  if (estimate.voided_at) {
    return page(409, 'Estimate not available',
      '<h2>This estimate is no longer available</h2><p>Please contact your technician for an updated estimate.</p>');
  }
  if (estimate.status === 'approved' || estimate.status === 'declined') {
    const answer = estimate.status === 'approved' ? 'approved' : 'declined';
    return page(409, 'Already answered',
      `<h2>This estimate was already answered</h2><p>It was ${answer}. No changes were made.</p>${itemsTable(estimate)}`);
  }
  return page(409, 'Estimate not available',
    '<h2>This estimate is not available</h2><p>Please contact your technician.</p>');
}

function viewPage(estimate) {
  return page(200, 'Your Estimate', `<h2>Your Estimate</h2>${itemsTable(estimate)}`
    + `<a href="?decision=approve" style="${BUTTON}background:green;">Approve</a>`
    + `<a href="?decision=decline" style="${BUTTON}background:#999;">Decline</a>`);
}

// A form (not a link) submits the answer, so a crawler that follows every
// link on the page still never confirms.
function confirmPage(estimate, decision) {
  const approve = decision === 'approve';
  return page(200, approve ? 'Approve estimate?' : 'Decline estimate?',
    `<h2>${approve ? 'Approve' : 'Decline'} this estimate of ${escapeHtml(money(estimate.total_amount))}?</h2>`
    + itemsTable(estimate)
    + '<form method="get" action="" style="display:inline;">'
    + `<input type="hidden" name="decision" value="${approve ? 'approve' : 'decline'}">`
    + '<input type="hidden" name="confirm" value="1">'
    + `<button type="submit" style="${BUTTON}background:${approve ? 'green' : '#999'};">`
    + `${approve ? 'Yes, approve' : 'Yes, decline'}</button></form>`
    + '<p><a href="?">Go back</a></p>');
}

function isPaymentLocked(error) {
  return String(error?.message ?? '').includes(PAYMENT_LOCKED);
}

exports.handler = async (event) => {
  try {
    const estimateId = event.pathParameters?.id;
    const query = event.queryStringParameters || {};
    const decision = query.decision === 'approve' || query.decision === 'decline' ? query.decision : null;
    if (!estimateId) return notFound();
    const supabase = await getSupabaseClient();

    const { data: estimate, error: fetchErr } = await supabase
      .from('job_estimates').select('*').eq('id', estimateId).single();
    if (fetchErr || !estimate) return notFound();

    if (estimate.status !== 'sent' || estimate.voided_at) return notAnswerable(estimate);
    if (!decision) return viewPage(estimate);
    if (query.confirm !== '1') return confirmPage(estimate, decision);

    const { data: updated, error: updateErr } = await supabase
      .from('job_estimates')
      .update({ status: decision === 'approve' ? 'approved' : 'declined' })
      .eq('id', estimateId)
      .eq('status', 'sent')
      .is('voided_at', null)
      .select();
    if (updateErr) {
      console.error('approve-estimate update failed:', updateErr.message);
      if (isPaymentLocked(updateErr)) {
        return page(409, 'Already being paid',
          '<h2>This job is already being paid; contact your technician</h2><p>No changes were made.</p>');
      }
      return failed();
    }
    if (!Array.isArray(updated) || updated.length === 0) {
      // Answered (or voided) between the read above and this update.
      return page(409, 'Already answered',
        '<h2>This estimate was already answered or is no longer available</h2><p>No changes were made.</p>');
    }

    return page(200, decision === 'approve' ? 'Approved' : 'Declined',
      `<h2>${decision === 'approve' ? 'Approved ✓' : 'Declined'}</h2>`
      + `<p>Total: ${escapeHtml(money(estimate.total_amount))}</p>`);
  } catch (err) {
    console.error('approve-estimate failed:', err.message);
    return failed();
  }
};
