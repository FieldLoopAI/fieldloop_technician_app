const { requireTechnician } = require('./shared/auth');
const { getSupabaseClient } = require('./shared/supabaseClient');

exports.handler = async (event) => {
  try {
    const technician = await requireTechnician(event);
    const { jobId } = JSON.parse(event.body);
    const supabase = await getSupabaseClient();

        const { data: job, error: jobErr } = await supabase
          .from('jobs').select('*').eq('id', jobId).single();
        if (jobErr) throw jobErr;

            const { data: contractorFinancials, error: contractorErr } = await supabase
              .from('contractor_financials').select('platform_fee_rate').eq('contractor_id', job.contractor_id).single();
            if (contractorErr) throw contractorErr;

    const { data: technicianRate } = await supabase
      .from('technicians').select('hourly_rate').eq('id', technician.id).single();

    const { data: estimates } = await supabase
      .from('job_estimates').select('*')
      .eq('job_id', jobId).order('created_at', { ascending: false }).limit(1);
    const estimate = estimates?.[0];
    if (!estimate) throw new Error('No estimate found for this job');

    const { data: changeOrders } = await supabase
      .from('change_orders').select('*').eq('job_id', jobId);

    const approved = (changeOrders || []).filter(c => c.status === 'approved' && !c.voided_at);
    const pending = (changeOrders || []).filter(c => c.status === 'pending');
    const voided = (changeOrders || []).filter(c => c.voided_at);
    const declined = (changeOrders || []).filter(c => c.status === 'declined');

    // Manual invoice line items (fees/discounts) — see
    // supabase/migrations/20260924000000_invoice_adjustments.sql.
    const { data: adjustments } = await supabase
      .from('invoice_adjustments').select('*').eq('job_id', jobId).order('created_at', { ascending: true });
    const adjustmentsTotal = (adjustments || []).reduce((sum, a) => sum + Number(a.amount), 0);

    const approvedTotal = approved.reduce((sum, c) => sum + Number(c.additional_amount), 0);
    const grossTotal = Number(estimate.total_amount) + approvedTotal + adjustmentsTotal;
            const feeRate = Number(contractorFinancials.platform_fee_rate) || 0.02;
    const feeAmount = Math.round(grossTotal * feeRate * 100) / 100;
    const netToContractor = Math.round((grossTotal - feeAmount) * 100) / 100;

    return {
      statusCode: 200,
      headers: { 'Access-Control-Allow-Origin': '*' },
      body: JSON.stringify({
        estimate,
        approvedChangeOrders: approved,
        pendingChangeOrders: pending,
        voidedChangeOrders: voided,
        declinedChangeOrders: declined,
        adjustments: adjustments || [],
        adjustmentsTotal,
        estimateApproved: estimate.status === 'approved',
        grossTotal,
        feeRate,
        feeAmount,
        netToContractor,
        billableHours: job.billable_hours,
        technicianHourlyRate: technicianRate?.hourly_rate || null,
        referenceLaborValue: (job.billable_hours && technicianRate?.hourly_rate)
          ? Math.round(job.billable_hours * technicianRate.hourly_rate * 100) / 100
          : null,
      }),
    };
  } catch (err) {
    return { statusCode: 400, headers: { 'Access-Control-Allow-Origin': '*' }, body: JSON.stringify({ error: err.message }) };
  }
};