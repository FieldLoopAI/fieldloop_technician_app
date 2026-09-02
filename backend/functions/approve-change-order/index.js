const { getSupabaseClient } = require('./shared/supabaseClient');

exports.handler = async (event) => {
  try {
    const changeOrderId = event.pathParameters?.id || JSON.parse(event.body || '{}').id;
    const decision = event.queryStringParameters?.decision; // 'approve' or 'decline'
    const supabase = await getSupabaseClient();

    const { data: changeOrder, error: fetchErr } = await supabase
      .from('change_orders').select('*').eq('id', changeOrderId).single();
    if (fetchErr || !changeOrder) {
      return { statusCode: 404, headers: { 'Content-Type': 'text/html' }, body: '<h1>Not found</h1>' };
    }

    if (decision === 'approve' || decision === 'decline') {
      await supabase.from('change_orders').update({
        status: decision === 'approve' ? 'approved' : 'declined',
        approved_at: decision === 'approve' ? new Date().toISOString() : null,
      }).eq('id', changeOrderId);

      return {
        statusCode: 200,
        headers: { 'Content-Type': 'text/html' },
        body: `<html><body style="font-family:sans-serif;text-align:center;padding:40px;">
          <h2>${decision === 'approve' ? 'Approved ✓' : 'Declined'}</h2>
          <p>${changeOrder.description}</p><p>$${changeOrder.additional_amount}</p>
        </body></html>`,
      };
    }

    // No decision yet — show the approve/decline buttons
    return {
      statusCode: 200,
      headers: { 'Content-Type': 'text/html' },
      body: `<html><body style="font-family:sans-serif;text-align:center;padding:40px;">
        <h2>Change Order Approval</h2>
        <p>${changeOrder.description}</p>
        <p style="font-size:24px;">$${changeOrder.additional_amount}</p>
        <a href="?decision=approve" style="display:inline-block;background:green;color:white;padding:15px 30px;margin:10px;text-decoration:none;border-radius:8px;">Approve</a>
        <a href="?decision=decline" style="display:inline-block;background:#999;color:white;padding:15px 30px;margin:10px;text-decoration:none;border-radius:8px;">Decline</a>
      </body></html>`,
    };
  } catch (err) {
    return { statusCode: 400, headers: { 'Content-Type': 'text/html' }, body: `<h1>Error</h1><p>${err.message}</p>` };
  }
};