tolk 1.0

import "storage"
import "../errors"
import "c5-register-validation"

const OP_EXCESSES = 0xd53276db

// Message tags
const TAG_INIT_CHANNEL = 0x2aa93806
const TAG_COOPERATIVE_CLOSE = 0x3e72726c
const TAG_COOPERATIVE_COMMIT = 0xc2c8e579
const TAG_START_UNCOOPERATIVE_CLOSE = 0xa5af1d07
const TAG_SETTLE_CONDITIONALS = 0x8a3056b7
const TAG_FINALIZE_SETTLE = 0x1c1b99b8
const TAG_EXECUTE_ACTIONS = 0x1a0ab350
const TAG_MSG_EXTERNAL = 0x22d61a69


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
    seqnoA: uint64
    seqnoB: uint64
}

struct (0xe02310f7) CooperativeCommitMessage {
    signatureA: Cell<bits512>
    signatureB: Cell<bits512>
    signedBody: RemainingBitsAndRefs
}
struct CooperativeCommitBody {
    seqnoA: uint64
    seqnoB: uint64
}

struct (0x66b93f47) CooperativeCloseMessage {
    signatureA: Cell<bits512>
    signatureB: Cell<bits512>
    signedBody: RemainingBitsAndRefs
}
struct CooperativeCloseBody {
    seqnoA: uint64
    seqnoB: uint64
}

struct (0xbd1cdbdb) StartUncooperativeCloseMessage {
    signature: bits512
    signedBody: RemainingBitsAndRefs
}
struct (0x1764fcb2) StartUncooperativeCloseReplicateMessage {
    at: uint32
    body: StartUncooperativeCloseBody
}
struct StartUncooperativeCloseBody {
    states: StartUncooperativeCloseChannels?
}
struct StartUncooperativeCloseChannels {
    A: Cell<SemichannelSigned>
    B: Cell<SemichannelSigned>
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

struct (0x3fb3e346) ExecuteActionsMessage {
    signature: bits512
    signedBody: RemainingBitsAndRefs
}
struct ExecuteActionsBody {
    actions: dict
    actionsInputProof: cell
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