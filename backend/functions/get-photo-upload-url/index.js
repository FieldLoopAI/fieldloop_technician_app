const { requireTechnician } = require('./shared/auth');
const { getSupabaseClient } = require('./shared/supabaseClient');
const { S3Client, PutObjectCommand } = require('@aws-sdk/client-s3');
const { getSignedUrl } = require('@aws-sdk/s3-request-presigner');

const s3 = new S3Client({});

exports.handler = async (event) => {
  try {
    const technician = await requireTechnician(event);
    const { jobId, fileName } = JSON.parse(event.body);

    const key = `${jobId}/${Date.now()}-${fileName}`;
    const command = new PutObjectCommand({
      Bucket: 'fieldloop-job-photos',
      Key: key,
      ContentType: 'image/jpeg',
    });

    const uploadUrl = await getSignedUrl(s3, command, { expiresIn: 300 });

    const supabase = await getSupabaseClient();
    await supabase.from('field_events').insert({
      job_id: jobId,
      technician_id: technician.id,
      event_type: 'photo',
      s3_object_key: key,
      metadata: { status: 'upload_pending' },
    });

    return {
      statusCode: 200,
      headers: { 'Access-Control-Allow-Origin': '*' },
      body: JSON.stringify({ uploadUrl, s3Key: key }),
    };
  } catch (err) {
    return {
      statusCode: err.message.includes('No technician') || err.message.includes('Invalid session') ? 403 : 400,
      headers: { 'Access-Control-Allow-Origin': '*' },
      body: JSON.stringify({ error: err.message }),
    };
  }
};