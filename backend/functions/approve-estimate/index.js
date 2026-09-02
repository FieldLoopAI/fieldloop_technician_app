const { getSupabaseClient } = require('./shared/supabaseClient');

exports.handler = async (event) => {
  try {
    const estimateId = event.pathParameters?.id;
    const decision = event.queryStringParameters?.decision;
    const supabase = await getSupabaseClient();

    const { data: estimate, error: fetchErr } = await supabase
      .from('job_estimates').select('*').eq('id', estimateId).single();
    if (fetchErr || !estimate) {
      return { statusCode: 404, headers: { 'Content-Type': 'text/html' }, body: '<h1>Not found</h1>' };
    }

    if (decision === 'approve' || decision === 'decline') {
      await supabase.from('job_estimates').update({
        status: decision === 'approve' ? 'approved' : 'declined',
      }).eq('id', estimateId);

      return {
        statusCode: 200,
        headers: { 'Content-Type': 'text/html' },
        body: `<html><body style="font-family:sans-serif;text-align:center;padding:40px;">
          <h2>${decision === 'approve' ? 'Approved ✓' : 'Declined'}</h2>
          <p>Total: $${estimate.total_amount}</p>
        </body></html>`,
      };
    }

    const itemsHtml = estimate.line_items.map(i =>
      `<tr><td style="padding:8px;text-align:left;">${i.description}</td><td style="padding:8px;text-align:right;">$${i.amount}</td></tr>`
    ).join('');

    return {
      statusCode: 200,
      headers: { 'Content-Type': 'text/html' },
      body: `<html><body style="font-family:sans-serif;text-align:center;padding:40px;max-width:500px;margin:0 auto;">
        <h2>Your Estimate</h2>
        <table style="width:100%;border-collapse:collapse;">${itemsHtml}</table>
        <p style="font-size:24px;font-weight:bold;margin-top:20px;">Total: $${estimate.total_amount}</p>
        <a href="?decision=approve" style="display:inline-block;background:green;color:white;padding:15px 30px;margin:10px;text-decoration:none;border-radius:8px;">Approve</a>
        <a href="?decision=decline" style="display:inline-block;background:#999;color:white;padding:15px 30px;margin:10px;text-decoration:none;border-radius:8px;">Decline</a>
      </body></html>`,
    };
  } catch (err) {
    return { statusCode: 400, headers: { 'Content-Type': 'text/html' }, body: `<h1>Error</h1><p>${err.message}</p>` };
  }
};