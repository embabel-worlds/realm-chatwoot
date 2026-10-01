import { describe, it, expect, vi } from "vitest";
import { entityForTest, mockGateway } from "@embabel/runtime-types";
import { ChatwootConversation } from "../src/api/conversation";
import type { ChatwootWriteGateway } from "../src/api/chatwoot";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function conversation(chatwoot: Record<string, (args: any) => any>) {
  return entityForTest(ChatwootConversation, { id: "2241", subject: "Export fails" }, mockGateway<ChatwootWriteGateway>({ chatwoot }));
}

describe("ChatwootConversation", () => {
  it("assigns to an agent or a team, and unassigns with 0", async () => {
    const chatwootConversationAssign = vi.fn(async () => ({}));
    const c = conversation({ chatwootConversationAssign });
    await c.assign({ agentId: 1 });
    await c.assign({ teamId: 3 });
    await c.unassign();
    expect(chatwootConversationAssign.mock.calls).toEqual([
      [{ conversation_id: 2241, assignee_id: 1 }],
      [{ conversation_id: 2241, team_id: 3 }],
      [{ conversation_id: 2241, assignee_id: 0 }],
    ]);
    await expect(c.assign({})).rejects.toThrow(/agentId or a teamId/);
  });

  it("keeps a note internal, and only reply reaches the customer", async () => {
    const chatwootMessageCreate = vi.fn(async () => ({ id: 88 }));
    const c = conversation({ chatwootMessageCreate });
    expect(await c.addNote("Customer is on the enterprise plan")).toBe(88);
    await c.reply("We have reproduced it and are on it.");
    expect(chatwootMessageCreate.mock.calls).toEqual([
      [{ conversation_id: 2241, content: "Customer is on the enterprise plan", message_type: "outgoing", private: true }],
      [{ conversation_id: 2241, content: "We have reproduced it and are on it.", message_type: "outgoing", private: false }],
    ]);
  });

  it("sends nothing empty, and nothing to an id that is not Chatwoot's", async () => {
    await expect(conversation({ chatwootMessageCreate: vi.fn() }).addNote("  ")).rejects.toThrow(/some text/);
    const bad = entityForTest(ChatwootConversation, { id: "globex.io" }, mockGateway<ChatwootWriteGateway>({ chatwoot: {} }));
    await expect(bad.reply("hi")).rejects.toThrow(/not a Chatwoot conversation id/);
  });
});
