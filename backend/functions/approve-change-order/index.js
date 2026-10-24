const { getSupabaseClient } = require('./shared/supabaseClient');

// The customer's change-order page, reached from the SMS link
// (/change-orders/{id}/approve). Public: the change order UUID is the only
// key, so — same rules as approve-estimate:
//  - only a 'pending', not-voided change order can be answered; anything
//    else gets an "already answered" / "not available" page and is never
//    changed;
//  - ?decision=approve|decline (the existing link and buttons) only shows a
//    confirmation page; the status changes on the confirmed request
//    (&confirm=1, submitted by that page's form), so link previews and
//    scanners that follow links cannot approve;
//  - the update is conditional on status 'pending' and its result is
//    checked: an error or zero changed rows never shows "Approved";
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

function details(changeOrder) {
  return `<p>${escapeHtml(changeOrder.description)}</p>`
    + `<p style="font-size:24px;">${escapeHtml(money(changeOrder.additional_amount))}</p>`;
}

const notFound = () => page(404, 'Not found', '<h1>Not found</h1>');

const failed = () => page(500, 'Something went wrong',
  "<h2>We couldn't record your answer</h2><p>Please try the link again, or contact your technician.</p>");

// Not 'pending' (or voided): show why, change nothing.
function notAnswerable(changeOrder) {
  if (changeOrder.voided_at) {
    return page(409, 'Change order not available',
      '<h2>This change order is no longer available</h2><p>Please contact your technician.</p>');
  }
  if (changeOrder.status === 'approved' || changeOrder.status === 'declined') {
    return page(409, 'Already answered',
      '<h2>This change order was already answered</h2>'
      + `<p>It was ${changeOrder.status}. No changes were made.</p>${details(changeOrder)}`);
  }
  return page(409, 'Change order not available',
    '<h2>This change order is not available</h2><p>Please contact your technician.</p>');
}

function viewPage(changeOrder) {
  return page(200, 'Change Order Approval', `<h2>Change Order Approval</h2>${details(changeOrder)}`
    + `<a href="?decision=approve" style="${BUTTON}background:green;">Approve</a>`
    + `<a href="?decision=decline" style="${BUTTON}background:#999;">Decline</a>`);
}

// A form (not a link) submits the answer, so a crawler that follows every
// link on the page still never confirms.
function confirmPage(changeOrder, decision) {
  const approve = decision === 'approve';
  return page(200, approve ? 'Approve change order?' : 'Decline change order?',
    `<h2>${approve ? 'Approve' : 'Decline'} this change order of `
    + `${escapeHtml(money(changeOrder.additional_amount))}?</h2>`
    + `<p>${escapeHtml(changeOrder.description)}</p>`
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

function idFromBody(body) {
  try {
    return JSON.parse(body || '{}').id;
  } catch {
    return undefined;
  }
}

exports.handler = async (event) => {
  try {
    const changeOrderId = event.pathParameters?.id || idFromBody(event.body);
    const query = event.queryStringParameters || {};
    const decision = query.decision === 'approve' || query.decision === 'decline' ? query.decision : null;
    if (!changeOrderId) return notFound();
    const supabase = await getSupabaseClient();

    const { data: changeOrder, error: fetchErr } = await supabase
      .from('change_orders').select('*').eq('id', changeOrderId).single();
    if (fetchErr || !changeOrder) return notFound();

    if (changeOrder.status !== 'pending' || changeOrder.voided_at) return notAnswerable(changeOrder);
    if (!decision) return viewPage(changeOrder);
    if (query.confirm !== '1') return confirmPage(changeOrder, decision);

    const { data: updated, error: updateErr } = await supabase
      .from('change_orders')
      .update({
        status: decision === 'approve' ? 'approved' : 'declined',
        approved_at: decision === 'approve' ? new Date().toISOString() : null,
      })
      .eq('id', changeOrderId)
      .eq('status', 'pending')
      .is('voided_at', null)
      .select();
    if (updateErr) {
      console.error('approve-change-order update failed:', updateErr.message);
      if (isPaymentLocked(updateErr)) {
        return page(409, 'Already being paid',
          '<h2>This job is already being paid; contact your technician</h2><p>No changes were made.</p>');
      }
      return failed();
    }
    if (!Array.isArray(updated) || updated.length === 0) {
      // Answered (or voided) between the read above and this update.
      return page(409, 'Already answered',
        '<h2>This change order was already answered or is no longer available</h2><p>No changes were made.</p>');
    }

    return page(200, decision === 'approve' ? 'Approved' : 'Declined',
      `<h2>${decision === 'approve' ? 'Approved ✓' : 'Declined'}</h2>${details(changeOrder)}`);
  } catch (err) {
    console.error('approve-change-order failed:', err.message);
    return failed();
  }
};
