const { requireTechnician } = require('./shared/auth');
const { getSupabaseClient } = require('./shared/supabaseClient');
const { S3Client, PutObjectCommand, GetObjectCommand } = require('@aws-sdk/client-s3');
const { getSignedUrl } = require('@aws-sdk/s3-request-presigner');
const PDFDocument = require('pdfkit');

const s3 = new S3Client({});

exports.handler = async (event) => {
  try {
    await requireTechnician(event);
    const { estimateId } = JSON.parse(event.body);
    const supabase = await getSupabaseClient();

    const { data: estimate, error } = await supabase
      .from('job_estimates')
      .select('*, jobs(*, customers(*), contractors(*, contractor_compliance(*)))')
      .eq('id', estimateId).single();
    if (error) throw error;

    const contractor = estimate.jobs.contractors;
    const customer = estimate.jobs.customers;

    const doc = new PDFDocument({ margin: 50 });
    const chunks = [];
    doc.on('data', (c) => chunks.push(c));
    const pdfDone = new Promise((resolve) => doc.on('end', resolve));

    doc.fontSize(18).text(contractor.legal_name, { bold: true });
    doc.fontSize(10).text(`License #${contractor.contractor_compliance?.primary_license_number || 'N/A'}`);
    doc.text(`${contractor.physical_street}, ${contractor.physical_city}, ${contractor.physical_state}`);
    doc.moveDown();
    doc.fontSize(14).text('ESTIMATE', { align: 'right' });
    doc.moveDown();
    doc.fontSize(11).text(`Prepared for: ${customer.household_name}`);
    doc.text(`Job site: ${estimate.jobs.service_address}`);
    doc.moveDown();

    estimate.line_items.forEach(item => {
      doc.text(`${item.description}`, { continued: true });
      doc.text(`$${item.amount.toFixed(2)}`, { align: 'right' });
    });
    doc.moveDown();
    doc.fontSize(13).text(`TOTAL: $${estimate.total_amount.toFixed(2)}`, { align: 'right' });

    doc.end();
    await pdfDone;
    const pdfBuffer = Buffer.concat(chunks);

    const key = `${estimate.job_id}/estimate-${estimateId}.pdf`;
    await s3.send(new PutObjectCommand({ Bucket: 'fieldloop-job-docs', Key: key, Body: pdfBuffer, ContentType: 'application/pdf' }));
    const viewUrl = await getSignedUrl(s3, new GetObjectCommand({ Bucket: 'fieldloop-job-docs', Key: key }), { expiresIn: 604800 });

    return { statusCode: 200, headers: { 'Access-Control-Allow-Origin': '*' }, body: JSON.stringify({ pdfUrl: viewUrl, s3Key: key }) };
  } catch (err) {
    return { statusCode: 400, headers: { 'Access-Control-Allow-Origin': '*' }, body: JSON.stringify({ error: err.message }) };
  }
};