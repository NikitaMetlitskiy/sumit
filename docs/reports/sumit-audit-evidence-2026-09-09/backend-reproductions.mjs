// Read-only audit harness: executes repository modules with fake external dependencies.
// No network requests, credentials, or dependency installation.
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { SourceTextModule, SyntheticModule } from 'node:vm';
import assert from 'node:assert/strict';

const root = process.cwd();
async function moduleAt(relative, mocks) {
  const module = new SourceTextModule(await readFile(resolve(root, relative), 'utf8'));
  await module.link(async (name) => {
    assert.ok(name in mocks, `Unexpected import ${name}`);
    const exports = mocks[name];
    return new SyntheticModule(Object.keys(exports), function () {
      for (const [key, value] of Object.entries(exports)) this.setExport(key, value);
    });
  });
  await module.evaluate();
  return module.namespace;
}
function response() {
  return { statusCode: null, body: null, status(n) { this.statusCode = n; return this; }, json(body) { this.body = body; return this; } };
}
class HttpError extends Error {
  constructor(status, code, message) { super(message); this.status = status; this.code = code; }
}
const auth = { HttpError, requireUser: async () => ({userId:'audit-user'}), sendError: (res, e) => res.status(e.status || 500).json({error:e.code}) };
let forwarded;
const parse = await moduleAt('Backend/vercel-project/api/parse.js', {
  './_lib/auth.js': auth,
  './_lib/usage.js': {enforceRateLimit: async () => ({tier:'basic',used:0}), incrementParseCount: async () => {}},
  './_lib/openai.js': {parseText: async (params) => {forwarded=params; return {amount:12,currency:'USD'};}}
});
const r=response();
await parse.default({method:'POST',body:{text:'12 USD coffee',model:'gpt-4o',wallets:'x'.repeat(10000)}},r);
assert.equal(forwarded.model,'gpt-4o');
assert.equal(forwarded.walletNames.length,10000);
console.log('REPRODUCED: Basic user can forward Pro model; wallet context exceeds 500 characters.');

process.env.PAYWALL_ENABLED='true';
const profile = {subscription_tier:'basic',monthly_parse_count:0,parse_count_reset_at:new Date().toISOString(),subscription_expires_at:'2000-01-01T00:00:00Z'};
const usage = await moduleAt('Backend/vercel-project/api/_lib/usage.js', {
  './auth.js': {HttpError},
  './supabase.js': {supabaseAdmin: () => ({from:() => ({select:() => ({eq:()=>({single: async()=>({data:profile,error:null})})})}),rpc:async()=>({error:null})})}
});
assert.equal((await usage.enforceRateLimit('audit-user')).tier,'basic');
console.log('REPRODUCED: Expired subscription is accepted when stored tier is Basic.');
profile.monthly_parse_count=99;
await Promise.all([usage.enforceRateLimit('audit-user'),usage.enforceRateLimit('audit-user')]);
console.log('REPRODUCED: Two concurrent requests pass with one quota slot remaining (no reservation).');

process.env.OPENAI_API_KEY='audit-placeholder-not-a-key';
let prompt;
class FakeOpenAI { chat={completions:{create:async params=> {prompt=params;return {choices:[{message:{content:'{"amount":-20,"currency":"INVALID","type":"nonsense"}'}}]};}}}; }
const ai = await moduleAt('Backend/vercel-project/api/_lib/openai.js', {'openai':{default:FakeOpenAI}});
const parsed = await ai.parseText({text:'yesterday coffee',model:'gpt-4o-mini'});
assert.equal(parsed.amount,-20);
assert.equal(parsed.currency,'INVALID');
assert.equal(prompt.messages.length,2);
assert.ok(!prompt.messages[0].content.includes(new Date().toISOString().slice(0,10)));
console.log('REPRODUCED: Invalid transaction JSON passes server parsing; current date/timezone is not supplied.');

const notifications=await moduleAt('Backend/vercel-project/api/storekit/notifications.js',{});
const n=response();
await notifications.default({method:'POST',body:{signedPayload:'not-a-signature'}},n);
assert.equal(n.statusCode,200);
console.log('REPRODUCED: Notification stub acknowledges an unsigned arbitrary payload.');

const health=await moduleAt('Backend/vercel-project/api/health.js',{});
delete process.env.OPENAI_API_KEY;
delete process.env.SUPABASE_URL;
const h=response(); health.default({method:'GET'},h);
assert.equal(h.statusCode,200);assert.equal(h.body.ok,true);assert.equal(h.body.env.openai,false);
console.log('REPRODUCED: Health returns HTTP 200 and ok=true with required configuration missing.');
