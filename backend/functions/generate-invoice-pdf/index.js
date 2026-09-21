const { requireTechnician } = require('./shared/auth');
const { getSupabaseClient } = require('./shared/supabaseClient');
const { S3Client, PutObjectCommand, GetObjectCommand } = require('@aws-sdk/client-s3');
const { getSignedUrl } = require('@aws-sdk/s3-request-presigner');
const PDFDocument = require('pdfkit');

const s3 = new S3Client({});
const TEAL = '#0F9D58';
const NAVY = '#1F2A44';
const LIGHT_TEAL = '#EAF6EE';

exports.handler = async (event) => {
  try {
    const technician = await requireTechnician(event);
    const { jobId } = JSON.parse(event.body);
    const supabase = await getSupabaseClient();

    const { data: job } = await supabase
      .from('jobs').select('*, customers(*)').eq('id', jobId).single();

    // Defensive backstop: if this job still has an open visit (arrived
    // but never departed), close it now so billable_hours reflects real
    // time even if invoice generation happens before Job Complete.
    const { data: lastArriveEvent } = await supabase
      .from('field_events')
      .select('id, event_ts')
      .eq('job_id', jobId)
      .eq('event_type', 'gps_arrive')
      .order('event_ts', { ascending: false })
      .limit(1)
      .maybeSingle();

    if (lastArriveEvent) {
      const { data: laterDepart } = await supabase
        .from('field_events')
        .select('id')
        .eq('job_id', jobId)
        .eq('event_type', 'gps_depart')
        .gt('event_ts', lastArriveEvent.event_ts)
        .limit(1);

      if (!laterDepart || laterDepart.length === 0) {
        await supabase.from('field_events').insert({
          job_id: jobId,
          technician_id: technician.id,
          event_type: 'gps_depart',
          event_ts: new Date().toISOString(),
          metadata: { source: 'invoice_generation_auto_close' },
        });

        const { data: allEvents } = await supabase
          .from('field_events')
          .select('event_type, event_ts')
          .eq('job_id', jobId)
          .in('event_type', ['gps_arrive', 'gps_depart'])
          .order('event_ts', { ascending: true });

        let totalMs = 0, lastArrive = null;
        (allEvents || []).forEach(e => {
          if (e.event_type === 'gps_arrive') lastArrive = new Date(e.event_ts);
          if (e.event_type === 'gps_depart' && lastArrive) {
            totalMs += new Date(e.event_ts) - lastArrive;
            lastArrive = null;
          }
        });
        const recomputedHours = Math.round((totalMs / 3600000) * 100) / 100;
        await supabase.from('jobs').update({ billable_hours: recomputedHours }).eq('id', jobId);
        job.billable_hours = recomputedHours;
      }
    }

    const { data: contractor } = await supabase
      .from('contractors').select('*, contractor_compliance(*)').eq('id', job.contractor_id).single();

    const { data: contractorFinancials } = await supabase
      .from('contractor_financials').select('platform_fee_rate').eq('contractor_id', job.contractor_id).single();
    const { data: estimates } = await supabase
      .from('job_estimates').select('*').eq('job_id', jobId).order('created_at', { ascending: false }).limit(1);
    const estimate = estimates[0];
    if (!estimate) throw new Error('No estimate found for this job');
    const { data: changeOrders } = await supabase.from('change_orders').select('*').eq('job_id', jobId);
    const approved = (changeOrders || []).filter(c => c.status === 'approved' && !c.voided_at);
    const voided = (changeOrders || []).filter(c => c.voided_at);

    const approvedTotal = approved.reduce((s, c) => s + Number(c.additional_amount), 0);
    const grossTotal = Number(estimate.total_amount) + approvedTotal;
    const feeRate = Number(contractorFinancials.platform_fee_rate) || 0.02;
    const feeAmount = Math.round(grossTotal * feeRate * 100) / 100;

    const customer = job.customers;

    const doc = new PDFDocument({ margin: 50, size: 'A4' });
    const chunks = [];
    doc.on('data', c => chunks.push(c));
    const done = new Promise(r => doc.on('end', r));

    // Header
    doc.fontSize(20).fillColor(NAVY).font('Helvetica-Bold').text(contractor.legal_name);

    const licenseText = contractor.contractor_compliance?.primary_license_number
      ? `General Contractor  ·  License #${contractor.contractor_compliance.primary_license_number}`
      : 'General Contractor';
    doc.fontSize(10).fillColor('#555').font('Helvetica').text(licenseText);

    const addressParts = [contractor.physical_street, contractor.physical_city, contractor.physical_state].filter(Boolean);
    if (addressParts.length > 0) {
      doc.fontSize(10).fillColor('#555').font('Helvetica').text(addressParts.join(', '));
    }

    doc.fontSize(22).fillColor(TEAL).font('Helvetica-Bold').text('INVOICE', 400, 50, { align: 'right' });
    doc.fontSize(9).fillColor('#555').font('Helvetica')
      .text(`Invoice Date: ${new Date().toLocaleDateString('en-US', { month: 'long', day: 'numeric', year: 'numeric' })}`, { align: 'right' });
    doc.moveDown(2);
    doc.strokeColor(TEAL).lineWidth(2).moveTo(50, doc.y).lineTo(545, doc.y).stroke();
    doc.moveDown();

    // Bill to / Job info
    const topY = doc.y;
    doc.fontSize(9).fillColor(TEAL).font('Helvetica-Bold').text('BILL TO', 50, topY);
    doc.fontSize(11).fillColor(NAVY).font('Helvetica-Bold').text(customer.household_name, 50, topY + 15);
    doc.fontSize(9).fillColor('#333').font('Helvetica').text(job.service_address, 50, topY + 30, { width: 240 });

    doc.fontSize(9).fillColor(TEAL).font('Helvetica-Bold').text('JOB INFORMATION', 320, topY);
    doc.fontSize(9).fillColor('#333').font('Helvetica')
      .text(`Job Site: ${job.service_address}`, 320, topY + 15, { width: 220 })
      .text(`Description: ${job.description || 'N/A'}`, 320, doc.y, { width: 220 });
    doc.moveDown(3);

    // Line items table
    let y = doc.y + 10;
    doc.rect(50, y, 495, 20).fill(NAVY);
    doc.fontSize(9).fillColor('#fff').font('Helvetica-Bold')
      .text('DESCRIPTION', 58, y + 6).text('AMOUNT', 480, y + 6, { width: 60, align: 'right' });
    y += 20;

    estimate.line_items.forEach((item, i) => {
      doc.rect(50, y, 495, 20).fill(i % 2 === 0 ? LIGHT_TEAL : '#fff');
      doc.fontSize(9).fillColor('#222').font('Helvetica')
        .text(item.description, 58, y + 6, { width: 400 })
        .text(`$${Number(item.amount).toFixed(2)}`, 480, y + 6, { width: 60, align: 'right' });
      y += 20;
    });

    if (approved.length > 0) {
      doc.rect(50, y, 495, 18).fill(TEAL);
      doc.fontSize(9).fillColor('#fff').font('Helvetica-Bold').text('APPROVED CHANGE ORDERS', 58, y + 5);
      y += 18;
      approved.forEach((c, i) => {
        doc.rect(50, y, 495, 20).fill(i % 2 === 0 ? LIGHT_TEAL : '#fff');
        doc.fontSize(9).fillColor('#222').font('Helvetica')
          .text(c.description, 58, y + 6, { width: 400 })
          .text(`$${Number(c.additional_amount).toFixed(2)}`, 480, y + 6, { width: 60, align: 'right' });
        y += 20;
      });
    }
    y += 10;

    if (voided.length > 0) {
      doc.fontSize(9).fillColor('#999').font('Helvetica-Oblique').text('VOIDED (NOT INCLUDED)', 50, y);
      y += 14;
      voided.forEach(c => {
        doc.fontSize(9).fillColor('#999').font('Helvetica-Oblique')
          .text(`${c.description} — $${Number(c.additional_amount).toFixed(2)} (voided: ${c.void_reason})`, 58, y, { width: 480 });
        y += 16;
      });
      y += 10;
    }

    // Total bar — customer PDF NEVER shows the platform fee
    doc.rect(320, y, 225, 32).fill(TEAL);
    doc.fontSize(13).fillColor('#fff').font('Helvetica-Bold')
      .text('TOTAL DUE', 330, y + 9)
      .text(`$${grossTotal.toFixed(2)}`, 400, y + 9, { width: 135, align: 'right' });

    // Time on site — hours only, never a dollar amount on the customer PDF
    if (job.billable_hours) {
      doc.fontSize(8).fillColor('#999').font('Helvetica-Oblique')
        .text(`Time on site: ${Number(job.billable_hours).toFixed(2)} hours`, 50, y + 45);
    }

    doc.end();
    await done;
    const pdfBuffer = Buffer.concat(chunks);

    const key = `${jobId}/invoice-${Date.now()}.pdf`;
    await s3.send(new PutObjectCommand({ Bucket: 'fieldloop-job-docs', Key: key, Body: pdfBuffer, ContentType: 'application/pdf' }));
    const pdfUrl = await getSignedUrl(s3, new GetObjectCommand({ Bucket: 'fieldloop-job-docs', Key: key }), { expiresIn: 604800 });

    const { data: invoice, error: insertErr } = await supabase.from('invoices').insert({
      job_id: jobId,
      technician_id: technician.id,
      invoice_number: `INV-${Date.now().toString().slice(-8)}`,
      subtotal: grossTotal,
      tax: 0,
      total: grossTotal,
      platform_fee: feeAmount,
      platform_fee_rate: feeRate,
      net_to_contractor: grossTotal - feeAmount,
      estimate_total: estimate.total_amount,
      approved_change_orders_total: approvedTotal,
      billable_hours: job.billable_hours,
      status: 'draft',
    }).select().single();
    if (insertErr) throw insertErr;

    return { statusCode: 200, headers: { 'Access-Control-Allow-Origin': '*' }, body: JSON.stringify({ invoice, pdfUrl }) };
  } catch (err) {
    return { statusCode: 400, headers: { 'Access-Control-Allow-Origin': '*' }, body: JSON.stringify({ error: err.message }) };
  }
};