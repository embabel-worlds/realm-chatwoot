"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.ChatwootConversation = void 0;
const runtime_types_1 = require("@embabel/runtime-types");
const chatwoot_1 = require("./chatwoot");
/**
 * A support conversation in Chatwoot, with what the team can do to it once found.
 *
 * Writing to the customer and writing for the team are different methods, not a flag: `addNote`
 * is only ever seen by agents, and `reply` is the one call that reaches the customer.
 */
class ChatwootConversation extends runtime_types_1.Entity {
    subject;
    status;
    /** Put the conversation in an agent's or a team's queue. The customer is not told. */
    async assign(to) {
        if (to.agentId === undefined && to.teamId === undefined)
            throw new Error("assign needs an agentId or a teamId");
        await this.gateway.chatwoot.chatwootConversationAssign({
            conversation_id: (0, chatwoot_1.chatwootId)(this.id),
            ...(to.agentId !== undefined ? { assignee_id: to.agentId } : {}),
            ...(to.teamId !== undefined ? { team_id: to.teamId } : {}),
        });
    }
    /** Take the conversation out of whoever's queue it is in. */
    async unassign() {
        await this.gateway.chatwoot.chatwootConversationAssign({ conversation_id: (0, chatwoot_1.chatwootId)(this.id), assignee_id: 0 });
    }
    /** Add an internal note to the conversation. Only agents see it; the customer never does. */
    async addNote(text) {
        return this.post(text, true);
    }
    /** Reply to the customer, on the conversation's channel. Once delivered it cannot be recalled. */
    async reply(text) {
        return this.post(text, false);
    }
    async post(text, internal) {
        if (!text.trim())
            throw new Error("a message needs some text");
        const message = await this.gateway.chatwoot.chatwootMessageCreate({
            conversation_id: (0, chatwoot_1.chatwootId)(this.id), content: text, message_type: "outgoing", private: internal,
        });
        return message.id;
    }
}
exports.ChatwootConversation = ChatwootConversation;
