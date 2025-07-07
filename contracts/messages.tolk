const OP_TOP_UP_BALANCE = 0x593e3893;
const OP_INIT_CHANNEL = 0x79ae99b5;
const OP_COOPERATIVE_CLOSE = 0xd2b1eeeb;
const OP_COOPERATIVE_COMMIT = 0x076bfdf1;
const OP_START_UNCOOPERATIVE_CLOSE = 0x8175e15d;
const OP_CHALLENGE_QUARANTINEED_STATE = 0x9a77c0db;
const OP_SETTLE_CONDITIONALS = 0x56c39b4c;
const OP_FINISH_UNCOOPERATIVE_CLOSE = 0x25432a91;
const OP_CHANNEL_CLOSED = 0xdddc88ba;
const OP_CHANNEL_WITHDRAW = 0xa32f0b3c;
const OP_JETTON_TRANSFER = 0xf8a7ea5;
const OP_JETTON_TAKE_WALLET_ADDRESS = 0xd1735400;
const OP_JETTON_PROVIDE_WALLET_ADDRESS = 0x2c76b973;
const OP_JETTON_TRANSFER_NOTIFICATION = 0x7362d09c;
const OP_EXCESSES = 0xd53276db;

// Message tags
const TAG_INIT_CHANNEL = 0x481ebc44;
const TAG_COOPERATIVE_CLOSE = 0x8243e9a3;
const TAG_COOPERATIVE_COMMIT = 0x4a390cac;
const TAG_START_UNCOOPERATIVE_CLOSE = 0x8c623692;
const TAG_CHALLENGE_QUARANTINEED_STATE = 0xb8a21379;
const TAG_SETTLE_CONDITIONALS = 0x14588aab;


type ForwardPayloadRemainder = RemainingBitsAndRefs;

struct (0xa32f0b3c) WithdrawNotification {
	channelId: uint128
}

struct (0xdddc88ba) ChannelClosedNotification {
	channelId: uint128
}

type PayoutMessage = WithdrawNotification | ChannelClosedNotification;

struct (0x0f8a7ea5) AskToTransfer {
    queryId: uint64,
    jettonAmount: coins,
    transferRecipient: address,
    sendExcessesTo: address,
    customPayload: cell?,
    forwardTonAmount: coins,
    forwardPayload: builder | cell
}

struct (0x7362d09c) JettonTransferNotification {
    queryId: uint64,
    jettonAmount: coins,
    jettonSender: address,
    forwardPayload: ForwardPayloadRemainder
}

struct (0x2c76b973) ProvideWalletAddress {
    queryId: uint64;
    ownerAddress: address;
    include_address: bool
}

/* TEP-89
  take_wallet_address#d1735400 query_id:uint64 wallet_address:MsgAddress
                               owner_address:(Maybe ^MsgAddress)
                               = InternalMsgBody;
*/

struct (0xd1735400) TakeWalletAddressMessage {
    queryId: uint64;
    wallet_address: address;
    // Don't care about the rest of the message
    rest: RemainingBitsAndRefs;
}

struct ChannelMessageId {
    tag: uint32;
    id: uint128;
}

struct (0x79ae99b5) InitChannelMessage {
    isA: bool;
    signature: bits512;
    signedBody: RemainingBitsAndRefs;
}
struct (0x593e3893) TopUpMessage {
    isA: bool
}

struct (0x076bfdf1) CooperativeCommitMessage {
    signatureA: cell;
    signatureB: cell;
    signedBody: RemainingBitsAndRefs;
}

struct (0xd2b1eeeb) CooperativeCloseMessage {
    signatureA: cell;
    signatureB: cell;
    signedBody: RemainingBitsAndRefs;
}

struct (0x8175e15d) StartUncooperativeCloseMessage {
    signedByA: bool;
    signature: bits512;
    signedBody: RemainingBitsAndRefs;
}
struct (0x25432a91) FinishUncooperativeCloseMessage {
    // Only OP tag
}

struct (0x9a77c0db) ChallengeQuarantineMessage {
    challengedByA: bool;
    signature: bits512;
    signedBody: RemainingBitsAndRefs;
}

struct (0x56c39b4c) SettleConditionalsMessage {
    fromA: bool;
    signature: bits512;
    signedBody: RemainingBitsAndRefs;
}
