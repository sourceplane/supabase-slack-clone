import { beforeEach, describe, expect, it, vi } from "vitest";

// lib/Store.js is upstream's data layer, unchanged: every read and write the
// chat makes goes from the browser straight to the project's Data API through
// supabase-js. These pin the queries it sends — the tables, the filters, the
// author join and the order — against a recording stand-in for the client.
type Call = { table: string; ops: [string, unknown[]][] };
const calls: Call[] = [];

function builder(table: string) {
  const call: Call = { table, ops: [] };
  calls.push(call);
  const result = { data: [{ id: 1, table }], error: null };
  const b: Record<string, unknown> = {};
  for (const op of ["select", "insert", "delete", "eq", "order", "match"]) {
    b[op] = (...args: unknown[]) => {
      call.ops.push([op, args]);
      return b;
    };
  }
  b.then = (resolve: (v: unknown) => unknown) => resolve(result);
  return b;
}

vi.mock("@supabase/supabase-js", () => ({
  createClient: vi.fn((url: string, key: string) => ({ url, key, from: (t: string) => builder(t) })),
}));

beforeEach(() => {
  calls.length = 0;
  vi.resetModules();
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://ref.supabase.co");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "sb_publishable_test");
});

describe("lib/Store.js (upstream's data layer)", () => {
  it("builds its client from the two inlined NEXT_PUBLIC_ values", async () => {
    const { supabase } = (await import("@/lib/Store.js")) as unknown as { supabase: { url: string; key: string } };
    expect(supabase.url).toBe("https://ref.supabase.co");
    expect(supabase.key).toBe("sb_publishable_test");
  });

  it("reads a channel's messages with their authors, oldest first", async () => {
    const store = await import("@/lib/Store.js");
    const got = await store.fetchMessages(7, undefined as never);
    expect(got).toEqual([{ id: 1, table: "messages" }]);
    expect(calls).toEqual([
      {
        table: "messages",
        ops: [
          ["select", ["*, author:user_id(*)"]],
          ["eq", ["channel_id", 7]],
          ["order", ["inserted_at", { ascending: true }]],
        ],
      },
    ]);
  });

  it("writes a message and a channel as the signed-in user, and deletes by id", async () => {
    const store = await import("@/lib/Store.js");
    // Upstream's JSDoc calls the user id a number; it is the auth user's UUID.
    await store.addMessage("hi", 2, "u-1" as never);
    await store.addChannel("general", "u-1" as never);
    await store.deleteMessage(9);
    await store.deleteChannel(3);
    expect(calls).toEqual([
      { table: "messages", ops: [["insert", [[{ message: "hi", channel_id: 2, user_id: "u-1" }]]], ["select", []]] },
      { table: "channels", ops: [["insert", [[{ slug: "general", created_by: "u-1" }]]], ["select", []]] },
      { table: "messages", ops: [["delete", []], ["match", [{ id: 9 }]]] },
      { table: "channels", ops: [["delete", []], ["match", [{ id: 3 }]]] },
    ]);
  });

  it("hands what it read to a state setter", async () => {
    const store = await import("@/lib/Store.js");
    const set = vi.fn();
    await store.fetchChannels(set);
    expect(set).toHaveBeenCalledWith([{ id: 1, table: "channels" }]);
    expect(calls[0]).toEqual({ table: "channels", ops: [["select", ["*"]]] });
  });
});
