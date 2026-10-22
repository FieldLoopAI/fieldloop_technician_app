const { createClient } = require('@supabase/supabase-js');
const { getSecret } = require('./secrets');

let cachedClient = null;

async function getSupabaseClient() {
  if (cachedClient) return cachedClient;
  const credsRaw = await getSecret('fieldloop/supabase-service-credentials');
  const creds = JSON.parse(credsRaw);
  cachedClient = createClient(creds.SUPABASE_URL, creds.SUPABASE_SERVICE_KEY);
  return cachedClient;
}

module.exports = { getSupabaseClient };