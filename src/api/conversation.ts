import { Entity } from "@embabel/runtime-types";
import { chatwootId, type ChatwootWriteGateway } from "./chatwoot";

/** Who a conversation goes to: an agent, a team, or both. */
export interface Assignee {
  agentId?: number;
  teamId?: number;
}

/**
 * A support conversation in Chatwoot, with what the team can do to it once found.
 *
 * Writing to the customer and writing for the team are different methods, not a flag: `addNote`
 * is only ever seen by agents, and `reply` is the one call that reaches the customer.
 */
export class ChatwootConversation extends Entity<ChatwootWriteGateway> {
  subject?: string;
  status?: string;

  /** Put the conversation in an agent's or a team's queue. The customer is not told. */
  async assign(to: Assignee): Promise<void> {
    if (to.agentId === undefined && to.teamId === undefined) throw new Error("assign needs an agentId or a teamId");
    await this.gateway.chatwoot.chatwootConversationAssign({
      conversation_id: chatwootId(this.id),
      ...(to.agentId !== undefined ? { assignee_id: to.agentId } : {}),
      ...(to.teamId !== undefined ? { team_id: to.teamId } : {}),
    });
  }

  /** Take the conversation out of whoever's queue it is in. */
  async unassign(): Promise<void> {
    await this.gateway.chatwoot.chatwootConversationAssign({ conversation_id: chatwootId(this.id), assignee_id: 0 });
  }

  /** Add an internal note to the conversation. Only agents see it; the customer never does. */
  async addNote(text: string): Promise<number> {
    return this.post(text, true);
  }

  /** Reply to the customer, on the conversation's channel. Once delivered it cannot be recalled. */
  async reply(text: string): Promise<number> {
    return this.post(text, false);
  }

  private async post(text: string, internal: boolean): Promise<number> {
    if (!text.trim()) throw new Error("a message needs some text");
    const message = await this.gateway.chatwoot.chatwootMessageCreate({
      conversation_id: chatwootId(this.id), content: text, message_type: "outgoing", private: internal,
    });
    return message.id;
  }
}
