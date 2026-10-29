#!/usr/bin/env node
// The browser's half of the chat, for the e2e.
//
//   chat-client.mjs <app-dir> <supabase-url> <anon-key> <action> [args…]
//
//   signup <email> <password>                    pages/index.js's "Sign up"
//   signin <email> <password>                    its "Login"
//   channels <email> <password>                  lib/Store.js fetchChannels
//   messages <email> <password> <channel>        fetchMessages (with each author)
//   post <email> <password> <channel> <text>     addMessage
//   delete-message <email> <password> <id>       deleteMessage
//   add-channel <email> <password> <slug>        addChannel
//   delete-channel <email> <password> <id>       deleteChannel
//   anon <table>                                 a read with the bare publishable key
//
// The pages render in the browser and their JavaScript, which this suite does
// not drive, calls supabase-js. So this makes the same calls with the same
// arguments as lib/Store.js and pages/_app.js do, from the product's OWN
// installed @supabase/supabase-js (resolved from <app-dir>, the staged job
// tree), signed in first as the given user — and decodes the access token the
// way _app.js does, so `userRole` is the `user_role` claim the access-token
// hook added.
//
// Prints one JSON object: { ok, userRole, code, message, rows }.
import { createRequire } from "node:module";
import * as path from "node:path";

const [appDir, url, key, action, ...args] = process.argv.slice(2);
const require = createRequire(path.join(path.resolve(appDir), "package.json"));
const { createClient } = require("@supabase/supabase-js");

const supabase = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });

function claimsOf(token) {
  const body = token.split(".")[1];
  return JSON.parse(Buffer.from(body, "base64url").toString("utf8"));
}

async function signIn(email, password) {
  const { data, error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) throw Object.assign(new Error(error.message), { code: error.code ?? String(error.status) });
  return data.session;
}

const out = { ok: true };
try {
  if (action === "signup" || action === "signin") {
    const [email, password] = args;
    const { data, error } =
      action === "signup"
        ? await supabase.auth.signUp({ email, password })
        : await supabase.auth.signInWithPassword({ email, password });
    if (error) throw Object.assign(new Error(error.message), { code: error.code ?? String(error.status) });
    out.user = data.user?.id ?? null;
    out.userRole = data.session ? (claimsOf(data.session.access_token).user_role ?? null) : null;
  } else if (action === "anon") {
    const { data, error } = await supabase.from(args[0]).select("*");
    if (error) throw Object.assign(new Error(error.message), { code: error.code });
    out.rows = data;
  } else {
    const [email, password, ...rest] = args;
    const session = await signIn(email, password);
    out.user = session.user.id;
    out.userRole = claimsOf(session.access_token).user_role ?? null;
    let res;
    if (action === "channels") res = await supabase.from("channels").select("*");
    else if (action === "messages")
      res = await supabase
        .from("messages")
        .select(`*, author:user_id(*)`)
        .eq("channel_id", rest[0])
        .order("inserted_at", { ascending: true });
    else if (action === "post")
      res = await supabase.from("messages").insert([{ message: rest[1], channel_id: rest[0], user_id: session.user.id }]).select();
    else if (action === "delete-message") res = await supabase.from("messages").delete().match({ id: rest[0] });
    else if (action === "add-channel")
      res = await supabase.from("channels").insert([{ slug: rest[0], created_by: session.user.id }]).select();
    else if (action === "delete-channel") res = await supabase.from("channels").delete().match({ id: rest[0] });
    else throw new Error(`unknown action ${action}`);
    if (res.error) throw Object.assign(new Error(res.error.message), { code: res.error.code });
    out.rows = res.data;
  }
} catch (error) {
  out.ok = false;
  out.code = error.code ?? null;
  out.message = error.message;
}
process.stdout.write(JSON.stringify(out) + "\n");
