// One chat turn: stream Claude on Bedrock, run at most one shopping tool, stream the reply.
// Bedrock calls get gen_ai.chat spans from @sentry/node automatically; the agent and
// tool spans below are what a customer calling Bedrock directly would add themselves.
import {
  BedrockRuntimeClient,
  ConverseStreamCommand,
  type ContentBlock,
  type ConverseStreamCommandOutput,
  type Message,
} from '@aws-sdk/client-bedrock-runtime';
import * as Sentry from '@sentry/node';
import { drainWidgets, trimHistory, type Session } from './session.ts';
import { TOOL_SPECS, TOOLS, type DemoHeaders } from './tools.ts';

const AGENT_NAME = 'Shopping Agent';

// Primary and fallback inference profiles. Bedrock occasionally returns
// ServiceUnavailableException; the agent retries, then switches profile.
const MODELS: Record<string, string[]> = {
  sonnet: [
    process.env.MODEL_ID || 'us.anthropic.claude-sonnet-5-5',
    process.env.FALLBACK_MODEL_ID || 'global.anthropic.claude-sonnet-5-5',
  ],
  haiku: [
    process.env.HAIKU_MODEL_ID || 'us.anthropic.claude-haiku-5-5',
    process.env.HAIKU_FALLBACK_MODEL_ID || 'global.anthropic.claude-haiku-5-5',
  ],
};
const FALLBACK_ERRORS = new Set([
  'ServiceUnavailableException',
  'ThrottlingException',
  'ModelNotReadyException',
  'AccessDeniedException',
]);
const PROMPT_CACHE = (process.env.PROMPT_CACHE ?? 'true') === 'true';

const client = new BedrockRuntimeClient({
  region: process.env.AWS_REGION || 'us-east-1',
  maxAttempts: 4,
  retryMode: 'adaptive',
});

const SYSTEM_PROMPT = `You are the Empower Plant shopping assistant, talking to a customer in the storefront's chat widget.

Use exactly ONE tool per customer message, then reply. Never chain actions:
- Finding products: search_products. "under $200" is max_price=200.
- add_to_cart takes product ids. "One of each" means quantity 1 of every product the customer was just shown.
- view_cart shows the cart. start_checkout returns the prefilled checkout form.
- apply_coupon only when the customer asks for a coupon; the checkout form's code is SAVE20.
- purchase only when the customer explicitly asks to buy, purchase or place the order.
Starting checkout is not applying a coupon, and neither one is buying.

Do not ask for confirmation before searching, adding to the cart or starting checkout.
If a tool fails, say so in one sentence and do not try another tool.
Keep replies to one short sentence. The chat shows products, the cart, the checkout form and errors as cards, so never list them or repeat prices.
Never ask for payment details; the checkout form is prefilled.`;

// Which badge the chat shows for each tool, matching Empower's agent ids.
const TOOL_AGENTS: Record<string, string> = {
  search_products: 'plant',
  add_to_cart: 'shopping',
  view_cart: 'shopping',
  start_checkout: 'shopping',
  apply_coupon: 'shopping',
  purchase: 'shopping',
};
const AGENTS: Record<string, string> = { manager: 'Manager Agent', plant: 'Plant Agent', shopping: 'Shopping Agent' };
const agentRef = (id = 'manager') => ({ id: AGENTS[id] ? id : 'manager', name: AGENTS[id] ?? AGENTS.manager });

const STATUS_LABELS: Record<string, string> = {
  search_products: 'Checking the catalogue…',
  add_to_cart: 'Updating your cart…',
  view_cart: 'Getting your cart…',
  start_checkout: 'Working on your order…',
  apply_coupon: 'Applying your coupon…',
  purchase: 'Placing your order…',
};

const PILLS_INITIAL = [{ id: 'chat-pill-show-products', label: 'Show me plants under $200' }];
const PILLS_CHECKOUT = [
  { id: 'chat-pill-apply-coupon', label: 'Apply Coupon' },
  { id: 'chat-pill-purchase', label: 'Purchase' },
];
const PILLS: Record<string, { id: string; label: string }[]> = {
  search_products: [{ id: 'chat-pill-add-all', label: 'Add one of each to the cart' }],
  add_to_cart: [{ id: 'chat-pill-checkout', label: 'Checkout' }],
  view_cart: [{ id: 'chat-pill-checkout', label: 'Checkout' }],
  start_checkout: PILLS_CHECKOUT,
  apply_coupon: PILLS_CHECKOUT,
  purchase: PILLS_INITIAL,
};

// The chat's buttons send these exact messages. For them the model is offered only that
// button's tool, so a demo step can't be skipped; it still makes the call and writes the
// arguments, so the Sentry data is real. Free text gets every tool. (Claude 5.5 on Bedrock
// rejects a forced toolChoice, so the tool list is narrowed instead.)
const BUTTON_TOOLS: Record<string, string> = {
  'show me plants under $200': 'search_products',
  'add one of each to the cart': 'add_to_cart',
  checkout: 'start_checkout',
  'apply coupon': 'apply_coupon',
  purchase: 'purchase',
};
const buttonTool = (message: string) => BUTTON_TOOLS[message.trim().toLowerCase()];

export type Emit = (event: string, data: Record<string, unknown>) => void;

type StreamedMessage = { message: Message; stopReason?: string };

async function converseStream(
  modelId: string,
  messages: Message[],
  emit: Emit,
  onlyTool?: string,
): Promise<StreamedMessage> {
  const system = PROMPT_CACHE
    ? [{ text: SYSTEM_PROMPT }, { cachePoint: { type: 'default' as const } }]
    : [{ text: SYSTEM_PROMPT }];
  const tools = onlyTool
    ? TOOL_SPECS.filter((t) => t.toolSpec?.name === onlyTool)
    : PROMPT_CACHE
      ? [...TOOL_SPECS, { cachePoint: { type: 'default' as const } }]
      : TOOL_SPECS;
  const response: ConverseStreamCommandOutput = await client.send(
    new ConverseStreamCommand({
      modelId,
      system,
      messages,
      toolConfig: { tools },
      inferenceConfig: { maxTokens: 1024 },
    }),
  );

  const content: ContentBlock[] = [];
  let text = '';
  let tool: { toolUseId: string; name: string; input: string } | null = null;
  let stopReason: string | undefined;
  const flushText = () => {
    if (text) {
      content.push({ text });
      emit('message_end', { agent: agentRef() });
      text = '';
    }
  };

  for await (const event of response.stream ?? []) {
    if (event.contentBlockStart?.start?.toolUse) {
      flushText();
      const t = event.contentBlockStart.start.toolUse;
      tool = { toolUseId: t.toolUseId!, name: t.name!, input: '' };
    } else if (event.contentBlockDelta?.delta?.text) {
      text += event.contentBlockDelta.delta.text;
      emit('token', { text: event.contentBlockDelta.delta.text });
    } else if (event.contentBlockDelta?.delta?.toolUse) {
      if (tool) tool.input += event.contentBlockDelta.delta.toolUse.input ?? '';
    } else if (event.contentBlockStop) {
      if (tool) {
        let input = {};
        try {
          input = tool.input ? JSON.parse(tool.input) : {};
        } catch {
          input = {};
        }
        content.push({ toolUse: { toolUseId: tool.toolUseId, name: tool.name, input } });
        tool = null;
      }
    } else if (event.messageStop) {
      stopReason = event.messageStop.stopReason;
    }
  }
  flushText();
  return { message: { role: 'assistant', content }, stopReason };
}

// Try the model's profiles in order; switch only on errors a retry won't fix in time.
async function converseWithFallback(
  models: string[],
  messages: Message[],
  emit: Emit,
  onlyTool?: string,
): Promise<StreamedMessage> {
  let lastError: unknown;
  for (const [i, modelId] of models.entries()) {
    try {
      return await converseStream(modelId, messages, emit, onlyTool);
    } catch (error) {
      lastError = error;
      const name = (error as Error)?.name;
      if (!FALLBACK_ERRORS.has(name) || i === models.length - 1) throw error;
      Sentry.logger.warn(`Bedrock ${name} on ${modelId}; falling back to ${models[i + 1]}`, {
        'gen_ai.request.model': modelId,
        'error.type': name,
      });
    }
  }
  throw lastError;
}

async function runTool(session: Session, block: NonNullable<ContentBlock['toolUse']>, headers: DemoHeaders) {
  const name = block.name ?? 'unknown';
  return Sentry.startSpan(
    {
      name: `execute_tool ${name}`,
      op: 'gen_ai.execute_tool',
      attributes: {
        'gen_ai.operation.name': 'execute_tool',
        'gen_ai.tool.name': name,
        'gen_ai.tool.type': 'function',
        'gen_ai.agent.name': AGENT_NAME,
        'gen_ai.tool.call.arguments': JSON.stringify(block.input ?? {}),
      },
    },
    async (span) => {
      const impl = TOOLS[name];
      if (!impl) {
        span.setStatus({ code: 2, message: 'unknown_tool' });
        return { ok: false, payload: { error: `Unknown tool ${name}` } };
      }
      try {
        const result = await impl(session, (block.input ?? {}) as Record<string, unknown>, headers);
        span.setAttribute('gen_ai.tool.call.result', JSON.stringify(result.payload).slice(0, 2000));
        if (!result.ok) {
          // A handled failure: the tool returned the store's error instead of throwing.
          // Marking the span is what puts it in Explore -> Agents' tool errors.
          span.setStatus({ code: 2, message: 'internal_error' });
          span.setAttribute('error.type', result.errorType ?? 'tool_error');
          Sentry.logger.warn(result.errorMessage ?? `${name} failed`, { 'gen_ai.tool.name': name });
        } else {
          Sentry.logger.info(`${name} succeeded`, { 'gen_ai.tool.name': name });
        }
        return result;
      } catch (error) {
        span.setStatus({ code: 2, message: 'internal_error' });
        span.setAttribute('error.type', (error as Error).name);
        Sentry.captureException(error);
        return { ok: false, payload: { error: (error as Error).message } };
      }
    },
  );
}

export async function runTurn(
  session: Session,
  userMessage: string,
  headers: DemoHeaders,
  modelKey: string,
  emit: Emit,
): Promise<void> {
  const models = MODELS[modelKey] ?? MODELS.sonnet;
  session.pendingWidgets = [];

  await Sentry.startSpan(
    {
      name: `invoke_agent ${AGENT_NAME}`,
      op: 'gen_ai.invoke_agent',
      attributes: {
        'gen_ai.operation.name': 'invoke_agent',
        'gen_ai.agent.name': AGENT_NAME,
        'gen_ai.request.model': models[0],
        'gen_ai.input.messages': JSON.stringify([
          { role: 'user', parts: [{ type: 'text', content: userMessage }] },
        ]),
      },
    },
    async (agentSpan) => {
      const messages: Message[] = [...session.history, { role: 'user', content: [{ text: userMessage }] }];
      let reply = '';
      const capture: Emit = (event, data) => {
        if (event === 'token') reply += String(data.text ?? '');
        emit(event, data);
      };

      // First call: the model picks a tool (or just answers). A button offers only its tool,
      // and gets one retry if the model still doesn't call it.
      const onlyTool = buttonTool(userMessage);
      if (onlyTool) agentSpan.setAttribute('empower.button_tool', onlyTool);
      const toolUsesOf = (m: StreamedMessage) => (m.message.content ?? []).filter((b) => b.toolUse).map((b) => b.toolUse!);
      let first = await converseWithFallback(models, messages, capture, onlyTool);
      if (onlyTool && !toolUsesOf(first).length) {
        Sentry.logger.warn(`Model skipped the ${onlyTool} button; retrying`, {
          'gen_ai.response.finish_reasons': first.stopReason ?? 'unknown',
        });
        reply = '';
        first = await converseWithFallback(models, messages, capture, onlyTool);
      }
      agentSpan.setAttribute('empower.first_stop_reason', first.stopReason ?? 'unknown');
      messages.push(first.message);
      const toolUses = toolUsesOf(first);

      if (toolUses.length) {
        // One action per message, as in Empower: run the first tool, skip any others.
        const [chosen, ...skipped] = toolUses;
        const name = chosen.name ?? 'unknown';
        emit('status', { tool: name, label: STATUS_LABELS[name] ?? 'Working…', agent: agentRef(TOOL_AGENTS[name]) });
        const result = await runTool(session, chosen, headers);
        for (const widget of drainWidgets(session)) {
          emit('widget', { ...widget, agent: agentRef(TOOL_AGENTS[widget.tool]) });
        }
        emit('agent_end', { tool: name, agent: agentRef(TOOL_AGENTS[name]), ran: true });

        messages.push({
          role: 'user',
          content: [
            {
              toolResult: {
                toolUseId: chosen.toolUseId,
                content: [{ json: result.payload }],
                status: result.ok ? 'success' : 'error',
              },
            },
            ...skipped.map((t) => ({
              toolResult: {
                toolUseId: t.toolUseId,
                content: [{ text: 'Skipped: only one action runs per customer message.' }],
                status: 'error' as const,
              },
            })),
          ],
        });

        // Second call: the reply. If the model reaches for another tool, it doesn't run.
        const second = await converseWithFallback(models, messages, capture);
        const textOnly = (second.message.content ?? []).filter((b) => b.text);
        if (!textOnly.length) {
          const fallback = result.ok ? 'Done.' : 'Sorry, that didn\'t work.';
          capture('token', { text: fallback });
          capture('message_end', { agent: agentRef() });
          textOnly.push({ text: fallback });
        }
        messages.push({ role: 'assistant', content: textOnly });
      } else if (!reply.trim()) {
        // No tool and no text (seen with Haiku): never leave the customer with an empty reply.
        Sentry.logger.warn('Model returned neither text nor a tool call', {
          'gen_ai.response.finish_reasons': first.stopReason ?? 'unknown',
        });
        const fallback = 'Sorry, I didn\'t catch that. Could you say it another way?';
        capture('token', { text: fallback });
        capture('message_end', { agent: agentRef() });
        messages.pop();
        messages.push({ role: 'assistant', content: [{ text: fallback }] });
      }

      session.history = trimHistory(messages);
      agentSpan.setAttribute(
        'gen_ai.output.messages',
        JSON.stringify([{ role: 'assistant', parts: [{ type: 'text', content: reply }] }]),
      );
    },
  );

  emit('pills', { pills: PILLS[session.lastTool ?? ''] ?? PILLS_INITIAL });
}
