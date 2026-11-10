// Capacity vs permissions check: call each inference profile N times with no retries
// and record every outcome, error type, HTTP status and AWS request ID.
import { BedrockRuntimeClient, ConverseCommand } from '@aws-sdk/client-bedrock-runtime';

const profiles = (process.env.PROBE_MODELS ||
  'us.anthropic.claude-sonnet-5-5,global.anthropic.claude-sonnet-5-5').split(',');
const n = Number(process.env.PROBE_CALLS || 10);
const client = new BedrockRuntimeClient({ region: process.env.AWS_REGION || 'us-east-1', maxAttempts: 1 });

const rows = [];
for (let i = 0; i < n; i++) {
  for (const modelId of profiles) {
    const started = Date.now();
    try {
      const res = await client.send(new ConverseCommand({
        modelId,
        messages: [{ role: 'user', content: [{ text: 'Reply with OK' }] }],
        inferenceConfig: { maxTokens: 5 },
      }));
      rows.push({ modelId, i, ok: true, status: res.$metadata.httpStatusCode, requestId: res.$metadata.requestId, ms: Date.now() - started });
    } catch (e) {
      rows.push({ modelId, i, ok: false, error: e.name, status: e.$metadata?.httpStatusCode, requestId: e.$metadata?.requestId, ms: Date.now() - started, message: String(e.message).slice(0, 160) });
    }
    await new Promise((r) => setTimeout(r, 1000));
  }
}
for (const r of rows) console.log(JSON.stringify(r));
for (const modelId of profiles) {
  const mine = rows.filter((r) => r.modelId === modelId);
  const errors = {};
  for (const r of mine.filter((r) => !r.ok)) errors[r.error] = (errors[r.error] || 0) + 1;
  console.log(`SUMMARY ${modelId}: ${mine.filter((r) => r.ok).length}/${mine.length} ok, errors ${JSON.stringify(errors)}`);
}
