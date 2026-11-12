// In-memory chat sessions, keyed by the x-conversation-id header the chat widget sends.
// One ECS task runs the agent, so there is no cross-instance state to share.
import type { Message } from '@aws-sdk/client-bedrock-runtime';

export type Product = {
  id: number;
  title?: string;
  description?: string;
  price?: number;
  img?: string;
  imgcropped?: string;
};

export type Cart = {
  items: Product[];
  quantities: Record<string, number>;
  total: number;
};

export type Widget = { type: string; tool: string; data: unknown };

// Same defaults as Empower's CheckoutForm.jsx, so both checkouts send the same form.
export const DEFAULT_FORM: Record<string, string> = {
  email: 'plant.lover@example.com',
  subscribe: '',
  firstName: 'Jane',
  lastName: 'Greenthumb',
  address: '123 Main Street',
  city: 'San Francisco',
  country: 'United States of America',
  state: 'CA',
  zipCode: '94122',
  promoCode: 'SAVE20',
};

export type Session = {
  conversationId: string;
  history: Message[];
  cart: Cart;
  lastResults: Product[];
  promo: unknown;
  form: Record<string, string> | null;
  lastTool: string | null;
  pendingWidgets: Widget[];
  lastSeen: number;
};

const TTL_MS = 30 * 60 * 1000;
const sessions = new Map<string, Session>();

export const emptyCart = (): Cart => ({ items: [], quantities: {}, total: 0 });

export function getSession(conversationId: string): Session {
  const now = Date.now();
  for (const [id, s] of sessions) if (now - s.lastSeen > TTL_MS) sessions.delete(id);
  let session = sessions.get(conversationId);
  if (!session) {
    session = {
      conversationId,
      history: [],
      cart: emptyCart(),
      lastResults: [],
      promo: null,
      form: null,
      lastTool: null,
      pendingWidgets: [],
      lastSeen: now,
    };
    sessions.set(conversationId, session);
  }
  session.lastSeen = now;
  return session;
}

export function recordWidget(session: Session, tool: string, type: string, data: unknown): void {
  session.lastTool = tool;
  session.pendingWidgets.push({ type, tool, data });
}

export function drainWidgets(session: Session): Widget[] {
  const widgets = session.pendingWidgets;
  session.pendingWidgets = [];
  return widgets;
}

export function addItems(session: Session, products: Product[], quantities: Map<number, number>): void {
  const known = new Set(session.cart.items.map((p) => p.id));
  for (const p of products) {
    if (!known.has(p.id)) {
      session.cart.items.push(p);
      known.add(p.id);
    }
  }
  for (const [id, qty] of quantities) {
    const key = String(id);
    session.cart.quantities[key] = (session.cart.quantities[key] ?? 0) + qty;
  }
  let total = 0;
  for (const p of session.cart.items) total += (p.price ?? 0) * (session.cart.quantities[String(p.id)] ?? 0);
  session.cart.total = Math.round(total * 100) / 100;
}

// Older tool results are collapsed to a note so each turn doesn't resend the whole
// conversation's JSON. The toolUse/toolResult pairs stay, as Bedrock requires.
export function trimHistory(history: Message[]): Message[] {
  let seen = 0;
  for (let i = history.length - 1; i >= 0; i--) {
    for (const block of history[i].content ?? []) {
      if (!block.toolResult) continue;
      seen++;
      if (seen > 1) {
        const text = JSON.stringify(block.toolResult.content ?? []);
        if (text.length > 1500) {
          block.toolResult.content = [
            { text: `${text.slice(0, 1500)}… (shortened; the customer already saw this result)` },
          ];
        }
      }
    }
  }
  return history;
}
