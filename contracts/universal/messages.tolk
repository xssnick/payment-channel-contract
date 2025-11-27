tolk 1.0

import "storage"
import "../errors"
import "c5-register-validation"

const OP_EXCESSES = 0xd53276db

// Message tags
const TAG_INIT_CHANNEL = 0x6a78d1a8
const TAG_COOPERATIVE_CLOSE = 0x51a6fa08
const TAG_COOPERATIVE_COMMIT = 0x9bc30c12
const TAG_START_UNCOOPERATIVE_CLOSE = 0x9a50b6bc
const TAG_SETTLE_CONDITIONALS = 0x8a3056b7
const TAG_FINALIZE_SETTLE = 0x1c1b99b8
const TAG_EXECUTE_ACTIONS = 0x2fa8f89c
const TAG_MSG_EXTERNAL = 0x22d61a69
const TAG_MSG_PROXY = 0x3e6c2d61


struct ChannelMessageId {
    tag: uint32
    id: uint128
}

struct (0xa19eda8c) InitChannelMessage {
    signatureA: Cell<bits512>
    signatureB: Cell<bits512>
    signedBody: RemainingBitsAndRefs
}
struct InitChannelBody {
    seqno: uint64
}

struct (0xe02310f7) CooperativeCommitMessage {
    signatureA: Cell<bits512>
    signatureB: Cell<bits512>
    signedBody: RemainingBitsAndRefs
}
struct CooperativeCommitBody {
    seqno: uint64
    fromA: bool
    action: Cell<CooperativeCommitAction>?
}
struct CooperativeCommitAction {
    stateA: cell?
    stateB: cell?
    code: cell
}

struct (0x66b93f47) CooperativeCloseMessage {
    signatureA: Cell<bits512>
    signatureB: Cell<bits512>
    signedBody: RemainingBitsAndRefs
}
struct CooperativeCloseBody {
    seqno: uint64
    fromA: bool
}

struct (0xbd1cdbdb) StartUncooperativeCloseMessage {
    signature: bits512
    signedBody: RemainingBitsAndRefs
}
struct StartUncooperativeCloseBody {
    state: StateBodySigned?
}
struct (0x1764fcb2) StartUncooperativeCloseReplicateMessage {
    at: uint32
    state: StateBodySigned?
}

struct (0x25432a91) FinishUncooperativeCloseMessage {
    // Only OP tag
}

struct (0xb916bc7c) FinalizeSettleMessage {
    signature: bits512
    signedBody: RemainingBitsAndRefs
}
struct FinalizeSettleBody {
    walletSeqno: uint32
    actionsInputHash: uint256
}

struct (0x3fa349d0) FinalizeSettleReplicateMessage {
    actionsInputHash: uint256
}

struct (0x255e10b6) SettleConditionalsMessage {
    signature: bits512
    signedBody: RemainingBitsAndRefs
}
struct SettleConditionalsBody {
    walletSeqno: uint32
    toSettle: dict
    conditionalsProof: cell
    actionsInputProof: cell
}

struct (0x32b90c8a) ProxySettleMessage {
    signature: bits512
    signedBody: RemainingBitsAndRefs
}
struct ProxySettleMessageBody {
    walletSeqno: uint32
    msg: Cell<ExecuteActionsMessage>
}

struct (0x3fb3e346) ExecuteActionsMessage {
    signature: bits512
    signedBody: RemainingBitsAndRefs
}
struct ExecuteActionsBody {
    action: cell
    actionsOurInputProof: cell
    actionsTheirInputProof: cell?
}

struct (0x31a4168c) ExternalSignedRequest {
    signature: bits512
    signedBody: RemainingBitsAndRefs
}
struct (0xa887b8fb) ExternalDoubleSignedRequest {
    signatureA: Cell<bits512>
    signatureB: Cell<bits512>
    signedBody: RemainingBitsAndRefs
}
struct ExternalSignedBody {
    sideA: bool
    validUntil: uint32
    seqno: uint32
    outActions: OutActionsCell?
}

struct (0xd53276db) ExcessMessage { }

struct (0x00000000) CommentMessage {
    body: RemainingBitsAndRefs
}

struct (0x038d9e86) ConditionalsSettledEvent {
    updatedConditionalsHash: uint256
    updatedActionsHash: uint256
}