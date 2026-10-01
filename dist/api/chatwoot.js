"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.chatwootId = chatwootId;
/** The conversation's Chatwoot id. The graph carries ids as strings; Chatwoot's are integers. */
function chatwootId(id) {
    const n = Number(id);
    if (!Number.isInteger(n) || n <= 0)
        throw new Error(`not a Chatwoot conversation id: '${String(id)}'`);
    return n;
}
