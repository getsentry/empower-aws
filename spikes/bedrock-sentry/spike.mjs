// One shopping-agent run against real Bedrock, traced by Sentry.
// Checks for the November 10 gate:
//   - Converse and ConverseStream calls get automatic gen_ai spans (model, tokens, finish reason).
//   - Manual agent and tool spans show up in Explore -> Agents, with a failing tool.
//   - The tool's exception becomes an issue linked to the same trace, with logs in the trace.
import { randomUUID } from 'node:crypto';
import * as Sentry from '@sentry/node';
import {
  BedrockRuntimeClient,
  ConverseCommand,
  ConverseStreamCommand,
} from '@aws-sdk/client-bedrock-runtime';

const modelId = process.env.MODEL_ID || 'us.anthropic.claude-sonnet-5-5';
// Bedrock occasionally returns ServiceUnavailableException under load; retry with backoff.
const client = new BedrockRuntimeClient({
  region: process.env.AWS_REGION || 'us-east-1',
  maxAttempts: 6,
  retryMode: 'adaptive',
});

const PRODUCTS = [
  { id: 3, title: 'Plant Mood Monitor', price: 130 },
  { id: 4, title: 'Botana Voice', price: 175 },
  { id: 5, title: 'Plant Stroller', price: 340 },
];

const tools = {
  async search_products({ max_price }) {
    return { products: PRODUCTS.filter((p) => p.price <= (max_price ?? Infinity)) };
  },
  async purchase({ product_id }) {
    // Same failure the Empower backend raises on checkout.
    throw new Error(`Error validating enough inventory for product ${product_id}`);
  },
};

const toolConfig = {
  tools: [
    {
      toolSpec: {
        name: 'search_products',
        description: 'Search the Empower Plant catalog. Returns products at or under max_price.',
        inputSchema: {
          json: {
            type: 'object',
            properties: { max_price: { type: 'number', description: 'Maximum price in USD' } },
          },
        },
      },
    },
    {
      toolSpec: {
        name: 'purchase',
        description: 'Buy one product by its id.',
        inputSchema: {
          json: {
            type: 'object',
            properties: { product_id: { type: 'number' } },
            required: ['product_id'],
          },
        },
      },
    },
  ],
};

const system = [
  {
    text:
      'You are the Empower Plant shopping assistant. Use the tools to find and buy products. ' +
      'If a tool fails, tell the customer briefly and stop.',
  },
];

async function runTool({ toolUseId, name, input }) {
  return Sentry.startSpan(
    {
      name: `execute_tool ${name}`,
      op: 'gen_ai.execute_tool',
      attributes: {
        'gen_ai.operation.name': 'execute_tool',
        'gen_ai.tool.name': name,
        'gen_ai.tool.type': 'function',
        'gen_ai.tool.call.arguments': JSON.stringify(input ?? {}),
      },
    },
    async (span) => {
      Sentry.logger.info(`Running tool ${name}`, { tool: name });
      try {
        const result = await tools[name](input ?? {});
        span.setAttribute('gen_ai.tool.call.result', JSON.stringify(result));
        return { toolResult: { toolUseId, content: [{ json: result }], status: 'success' } };
      } catch (error) {
        span.setStatus({ code: 2, message: 'internal_error' });
        span.setAttribute('gen_ai.tool.call.result', error.message);
        Sentry.logger.error(`Tool ${name} failed: ${error.message}`, { tool: name });
        Sentry.captureException(error);
        return { toolResult: { toolUseId, content: [{ text: error.message }], status: 'error' } };
      }
    },
  );
}

const prompt = 'Find me a plant under $200 and buy the cheapest one.';
const summary = { modelId, modelCalls: 0, toolCalls: [], streamedText: '' };

// Tags every gen_ai span in this run, including the automatic Bedrock ones,
// so Explore -> Agents can group them into one conversation.
Sentry.setConversationId(randomUUID());

let failed = false;
try {
  await Sentry.startSpan(
    {
      name: 'invoke_agent empower-shop',
      op: 'gen_ai.invoke_agent',
      attributes: {
        'gen_ai.operation.name': 'invoke_agent',
        'gen_ai.agent.name': 'empower-shop',
        'gen_ai.request.model': modelId,
          'gen_ai.input.messages': JSON.stringify([
          { role: 'user', parts: [{ type: 'text', content: prompt }] },
        ]),
      },
    },
    async (agentSpan) => {
      summary.traceId = agentSpan.spanContext().traceId;
      const messages = [{ role: 'user', content: [{ text: prompt }] }];

      // Tool loop with Converse.
      for (let turn = 0; turn < 6; turn++) {
        const res = await client.send(
          new ConverseCommand({ modelId, system, messages, toolConfig, inferenceConfig: { maxTokens: 512 } }),
        );
        summary.modelCalls++;
        messages.push(res.output.message);
        if (res.stopReason !== 'tool_use') break;

        const results = [];
        for (const block of res.output.message.content) {
          if (!block.toolUse) continue;
          summary.toolCalls.push(block.toolUse.name);
          results.push(await runTool(block.toolUse));
        }
        messages.push({ role: 'user', content: results });
      }

      // One streamed reply, to check ConverseStream spans close with tokens.
      const lastRole = messages[messages.length - 1].role;
      const followUp = 'In one sentence, tell me what happened with my order.';
      if (lastRole === 'user') messages[messages.length - 1].content.push({ text: followUp });
      else messages.push({ role: 'user', content: [{ text: followUp }] });

      const stream = await client.send(
        new ConverseStreamCommand({ modelId, system, messages, toolConfig, inferenceConfig: { maxTokens: 256 } }),
      );
      summary.modelCalls++;
      for await (const event of stream.stream) {
        summary.streamedText += event.contentBlockDelta?.delta?.text ?? '';
      }

      agentSpan.setAttribute(
        'gen_ai.output.messages',
        JSON.stringify([{ role: 'assistant', parts: [{ type: 'text', content: summary.streamedText }] }]),
      );
    },
  );
} catch (error) {
  // Report the failure before exiting, so a broken run still shows up in Sentry.
  failed = true;
  console.error(error);
  Sentry.captureException(error);
}

await Sentry.flush(10000);
console.log(JSON.stringify(summary, null, 2));
if (failed) process.exit(1);
if (!summary.toolCalls.includes('search_products')) {
  console.error('The model never called search_products; the run did not exercise the tool loop.');
  process.exit(1);
}
