const { getSupabaseClient } = require('./supabaseClient');

async function requireTechnician(event) {
  const authHeader = event.headers.Authorization || event.headers.authorization;
  if (!authHeader) throw new Error('No authorization header');
  const token = authHeader.replace('Bearer ', '');

  const supabase = await getSupabaseClient();
  const { data: userData, error: authError } = await supabase.auth.getUser(token);
  if (authError || !userData?.user) throw new Error('Invalid session');

  const { data: technician, error: techError } = await supabase
    .from('technicians')
    .select('id, contractor_id, full_name')
    .eq('auth_user_id', userData.user.id)
    .single();
  if (techError || !technician) throw new Error('No technician record for this session');

  return technician;
}

module.exports = { requireTechnician };