/*
 * The slice of the gateway the conversation type calls: the realm's two write verbs in
 * apis/chatwoot.json. ChatwootConversation names it as Entity's type argument.
 */
export interface ChatwootWriteGateway {
  chatwoot: {
    chatwootConversationAssign(args: { conversation_id: number; assignee_id?: number; team_id?: number }): Promise<unknown>;
    chatwootMessageCreate(args: { conversation_id: number; content: string; message_type: "outgoing"; private: boolean }): Promise<{ id: number }>;
  };
}

/** The conversation's Chatwoot id. The graph carries ids as strings; Chatwoot's are integers. */
export function chatwootId(id: unknown): number {
  const n = Number(id);
  if (!Number.isInteger(n) || n <= 0) throw new Error(`not a Chatwoot conversation id: '${String(id)}'`);
  return n;
}
