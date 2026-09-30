const { requireTechnician } = require('./shared/auth');
const { getSupabaseClient } = require('./shared/supabaseClient');
const { S3Client, GetObjectCommand } = require('@aws-sdk/client-s3');
const { getSignedUrl } = require('@aws-sdk/s3-request-presigner');

const s3 = new S3Client({});

exports.handler = async (event) => {
  try {
    await requireTechnician(event);
    const { jobId } = JSON.parse(event.body);
    const supabase = await getSupabaseClient();

    const { data: photos, error } = await supabase
      .from('field_events')
      .select('id, s3_object_key, event_ts, transcript')
      .eq('job_id', jobId)
      .eq('event_type', 'photo')
      .contains('metadata', { status: 'uploaded' })
      .order('event_ts', { ascending: true });
    if (error) throw error;

    const withUrls = await Promise.all(photos.map(async (p) => {
      const command = new GetObjectCommand({ Bucket: 'fieldloop-job-photos', Key: p.s3_object_key });
      const url = await getSignedUrl(s3, command, { expiresIn: 3600 });
      return { id: p.id, s3Key: p.s3_object_key, url, capturedAt: p.event_ts, transcript: p.transcript };
    }));

    return {
      statusCode: 200,
      headers: { 'Access-Control-Allow-Origin': '*' },
      body: JSON.stringify({ photos: withUrls }),
    };
  } catch (err) {
    return {
      statusCode: err.message.includes('technician') ? 403 : 400,
      headers: { 'Access-Control-Allow-Origin': '*' },
      body: JSON.stringify({ error: err.message }),
    };
  }
};