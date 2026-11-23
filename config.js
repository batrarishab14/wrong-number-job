// Live stats. Leave both empty and the game still works, just without live stats.
// Fill them in from Supabase: Project Settings -> API Keys (see README, "Turn on live stats").
window.WNJ_CONFIG = {
  supabaseUrl: "",      // e.g. "https://abcdefghijklmnop.supabase.co"
  publishableKey: ""    // e.g. "sb_publishable_..." (safe to publish; the database only lets it add events)
};
