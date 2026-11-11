// HTTP server for the chat widget. Same contract as Empower's Python agent:
// POST {prefix}/api/v1/chat with x-conversation-id, answered as a Server-Sent Events stream
// of status, token, message_end, agent_end, widget, pills, error and done events.
// Behind CloudFront the agent lives under /agent, so both /agent/... and /... are served.
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import * as Sentry from '@sentry/node';
import { runTurn } from './agent.ts';
import { getSession } from './session.ts';
import type { DemoHeaders } from './tools.ts';

const PORT = Number(process.env.PORT || 8000);

function header(req: IncomingMessage, name: string): string | undefined {
  const value = req.headers[name.toLowerCase()];
  const v = Array.isArray(value) ? value[0] : value;
  return v && v !== 'undefined' ? v : undefined;
}

async function readJson(req: IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');
  } catch {
    return {};
  }
}

function json(res: ServerResponse, status: number, body: unknown) {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
}

async function chat(req: IncomingMessage, res: ServerResponse, url: URL) {
  const conversationId = header(req, 'x-conversation-id');
  if (!conversationId) return json(res, 400, { detail: 'x-conversation-id is required' });
  const body = await readJson(req);
  const message = String(body.message ?? '').trim();
  if (!message) return json(res, 400, { detail: 'message is required' });

  // Tags every gen_ai span in this request, the automatic Bedrock ones included,
  // so Explore -> Agents groups the turns of one chat into one conversation.
  Sentry.setConversationId(conversationId);
  const headers: DemoHeaders = {};
  for (const name of ['se', 'customerType', 'email', 'cexp'] as const) {
    const value = header(req, name);
    if (value) headers[name] = value;
  }
  if (headers.se) Sentry.setTag('se', headers.se);
  if (headers.customerType) Sentry.setTag('customerType', headers.customerType);
  if (headers.cexp) Sentry.setTag('cexp', headers.cexp);
  const modelKey = url.searchParams.get('model') === 'haiku' ? 'haiku' : 'sonnet';
  Sentry.setTag('agent.model', modelKey);

  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive',
    'X-Accel-Buffering': 'no',
  });
  const emit = (event: string, data: Record<string, unknown>) => {
    if (!res.writableEnded) res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
  };
  // Keeps CloudFront and the load balancer from timing out a slow turn.
  const heartbeat = setInterval(() => !res.writableEnded && res.write(': ping\n\n'), 10_000);

  const session = getSession(conversationId);
  try {
    await runTurn(session, message, headers, modelKey, emit);
  } catch (error) {
    // Headers are already sent, so a failed turn is reported in-band.
    Sentry.captureException(error);
    const text = (error as Error)?.message ?? String(error);
    emit('widget', { type: 'error', data: { message: text } });
    emit('error', { code: 'turn_failed', message: text });
  } finally {
    clearInterval(heartbeat);
    emit('done', { conversation_id: conversationId });
    res.end();
  }
}

const server = createServer(async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  if (req.method === 'OPTIONS') return res.writeHead(204).end();

  const url = new URL(req.url ?? '/', 'http://localhost');
  const path = url.pathname.replace(/^\/agent(?=\/|$)/, '') || '/';
  try {
    if (req.method === 'GET' && (path === '/health' || path === '/api/v1/health')) {
      return json(res, 200, { status: 'healthy', agent_name: 'Shopping Agent', version: '1.0.0' });
    }
    if (req.method === 'POST' && path === '/api/v1/chat') return await chat(req, res, url);
    return json(res, 404, { detail: 'Not found' });
  } catch (error) {
    Sentry.captureException(error);
    if (!res.headersSent) json(res, 500, { detail: 'Internal error' });
    else res.end();
  }
});

server.listen(PORT, () => console.log(`agent listening on :${PORT}`));
