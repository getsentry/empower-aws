// The five shopping tools, backed by the store API (Empower's flask-otlp), plus view_cart.
// The coupon (410, SAVE20 is seeded expired) and the purchase (500, inventory check)
// fail by design. Tools report what the store said instead of throwing.
import type { Tool } from '@aws-sdk/client-bedrock-runtime';
import { addItems, DEFAULT_FORM, emptyCart, recordWidget, type Product, type Session } from './session.ts';

const STORE_URL = (process.env.STORE_URL || 'http://localhost:8080').replace(/\/$/, '');
const PRODUCT_FIELDS = ['id', 'title', 'description', 'price', 'img', 'imgcropped'] as const;

// Demo headers from the browser, passed on so the store's spans are tagged the same way.
export type DemoHeaders = Partial<Record<'se' | 'customerType' | 'email' | 'cexp', string>>;

export type ToolResult = { ok: boolean; payload: Record<string, unknown>; errorType?: string; errorMessage?: string };

function trim(product: Record<string, unknown>): Product {
  const out: Record<string, unknown> = {};
  for (const key of PRODUCT_FIELDS) if (key in product) out[key] = product[key];
  return out as Product;
}

async function store(method: 'GET' | 'POST', path: string, headers: DemoHeaders, body?: unknown) {
  const response = await fetch(`${STORE_URL}${path}`, {
    method,
    headers: { 'Content-Type': 'application/json', ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(60_000),
  });
  const text = await response.text();
  let json: unknown;
  try {
    json = text ? JSON.parse(text) : {};
  } catch {
    json = { text };
  }
  return { status: response.status, json };
}

async function allProducts(headers: DemoHeaders, slow = false): Promise<Record<string, unknown>[]> {
  const { status, json } = await store('GET', `/products${slow ? '?fetch_promotions=true' : ''}`, headers);
  if (status !== 200 || !Array.isArray(json)) throw new Error(`GET /products returned HTTP ${status}`);
  return json;
}

export const TOOL_SPECS: Tool[] = [
  {
    toolSpec: {
      name: 'search_products',
      description: 'Search the Empower Plant catalogue. "under $200" means max_price=200.',
      inputSchema: {
        json: {
          type: 'object',
          properties: {
            max_price: { type: 'number', description: 'Only products at or below this price, in dollars.' },
            query: { type: 'string', description: 'Optional text to match in titles and descriptions.' },
          },
        },
      },
    },
  },
  {
    toolSpec: {
      name: 'add_to_cart',
      description: 'Add products to the cart by id. "One of each" means quantity 1 of every product just shown.',
      inputSchema: {
        json: {
          type: 'object',
          properties: {
            items: {
              type: 'array',
              items: {
                type: 'object',
                properties: { product_id: { type: 'integer' }, qty: { type: 'integer' } },
                required: ['product_id'],
              },
            },
          },
          required: ['items'],
        },
      },
    },
  },
  {
    toolSpec: {
      name: 'view_cart',
      description: "Show what is in the customer's cart.",
      inputSchema: { json: { type: 'object', properties: {} } },
    },
  },
  {
    toolSpec: {
      name: 'start_checkout',
      description: 'Begin checkout and return the prefilled checkout form. Does not apply coupons or buy.',
      inputSchema: { json: { type: 'object', properties: {} } },
    },
  },
  {
    toolSpec: {
      name: 'apply_coupon',
      description: 'Apply a promo code to the order. The checkout form\'s code is SAVE20.',
      inputSchema: {
        json: { type: 'object', properties: { code: { type: 'string' } }, required: ['code'] },
      },
    },
  },
  {
    toolSpec: {
      name: 'purchase',
      description: 'Place the order for everything in the cart. Only when the customer explicitly asks to buy.',
      inputSchema: { json: { type: 'object', properties: {} } },
    },
  },
];

type Input = Record<string, any>;

export const TOOLS: Record<string, (s: Session, input: Input, h: DemoHeaders) => Promise<ToolResult>> = {
  async search_products(session, input, headers) {
    // The shared cexp schedule makes /products extremely slow in some windows, as on the site.
    const slow = (headers.cexp ?? '').includes('products_extremely_slow');
    let products = (await allProducts(headers, slow)).map(trim);
    if (typeof input.max_price === 'number') products = products.filter((p) => (p.price ?? 0) <= input.max_price);
    if (input.query) {
      const needle = String(input.query).toLowerCase();
      products = products.filter(
        (p) => p.title?.toLowerCase().includes(needle) || p.description?.toLowerCase().includes(needle),
      );
    }
    products = products.slice(0, 6);
    session.lastResults = products;
    const payload = { products, count: products.length };
    recordWidget(session, 'search_products', 'products', payload);
    return { ok: true, payload };
  },

  async add_to_cart(session, input, headers) {
    const requested = new Map<number, number>();
    for (const item of input.items ?? []) {
      const id = Number(item.product_id);
      requested.set(id, (requested.get(id) ?? 0) + Math.max(1, Number(item.qty ?? 1)));
    }
    const known = new Map(session.lastResults.map((p) => [p.id, p]));
    if ([...requested.keys()].some((id) => !known.has(id))) {
      for (const p of await allProducts(headers)) if (!known.has(p.id as number)) known.set(p.id as number, trim(p));
    }
    const found = [...requested.keys()].filter((id) => known.has(id));
    const quantities = new Map(found.map((id) => [id, requested.get(id)!]));
    addItems(session, found.map((id) => known.get(id)!), quantities);
    const payload = {
      cart: session.cart,
      added: found.map((id) => ({ product_id: id, qty: quantities.get(id) })),
      unknown_product_ids: [...requested.keys()].filter((id) => !known.has(id)),
    };
    recordWidget(session, 'add_to_cart', 'cart', payload);
    return { ok: true, payload };
  },

  async view_cart(session) {
    const payload = { cart: session.cart, promo: session.promo };
    recordWidget(session, 'view_cart', 'cart', payload);
    return { ok: true, payload };
  },

  async start_checkout(session) {
    if (!session.cart.items.length) {
      const payload = { error: 'The cart is empty; add something first.' };
      recordWidget(session, 'start_checkout', 'checkout', payload);
      return { ok: true, payload };
    }
    session.form ??= { ...DEFAULT_FORM };
    const payload = { cart: session.cart, form: session.form, promo: session.promo };
    recordWidget(session, 'start_checkout', 'checkout', payload);
    return { ok: true, payload };
  },

  async apply_coupon(session, input, headers) {
    const code = String(input.code ?? 'SAVE20').trim();
    const { status, json } = await store('POST', '/apply-promo-code', headers, { value: code });
    const body = (json ?? {}) as Record<string, any>;
    if (status === 200) {
      session.promo = body.promo_code ?? null;
      const payload = { ok: true, code, promo: session.promo };
      recordWidget(session, 'apply_coupon', 'promo', payload);
      return { ok: true, payload };
    }
    const error = (body.error ?? {}) as Record<string, string>;
    const payload = {
      ok: false,
      code,
      status,
      error_code: error.code ?? 'error',
      message: error.message ?? `Could not apply ${code} (HTTP ${status}).`,
    };
    recordWidget(session, 'apply_coupon', 'promo', payload);
    return {
      ok: false,
      payload,
      errorType: `apply_coupon.${payload.error_code}`,
      errorMessage: `${code} was rejected (HTTP ${status}): ${payload.message}`,
    };
  },

  async purchase(session, _input, headers) {
    if (!session.cart.items.length) {
      const payload = { ok: false, message: 'The cart is empty.' };
      recordWidget(session, 'purchase', 'confirmation', payload);
      return { ok: true, payload };
    }
    // A string, not a boolean: the store compares validate_inventory == "true".
    // checkout_success is the healthy window of the shared cexp schedule.
    const validate = (headers.cexp ?? '').includes('checkout_success') ? 'false' : 'true';
    const { status, json } = await store('POST', '/checkout?v2=true', headers, {
      cart: session.cart,
      form: session.form ?? DEFAULT_FORM,
      validate_inventory: validate,
    });
    if (status === 200) {
      const payload = {
        ok: true,
        status: (json as Record<string, unknown>)?.status ?? 'success',
        order_total: session.cart.total,
        item_count: Object.values(session.cart.quantities).reduce((a, b) => a + b, 0),
      };
      session.cart = emptyCart();
      session.promo = null;
      session.form = null;
      recordWidget(session, 'purchase', 'confirmation', payload);
      return { ok: true, payload };
    }
    const payload = { ok: false, status, message: `Checkout failed (HTTP ${status}).`, detail: json };
    recordWidget(session, 'purchase', 'confirmation', payload);
    return {
      ok: false,
      payload,
      errorType: `purchase.http_${status}`,
      errorMessage: `Checkout failed (HTTP ${status}): ${JSON.stringify(json).slice(0, 300)}`,
    };
  },
};
