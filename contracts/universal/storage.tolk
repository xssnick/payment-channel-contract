import "../errors"

const TAG_STATE = 0x98b70b88
const SIZE_SIGNATURE = 512

struct Semichannel {
    data: SemichannelBody
    counterpartyData: Cell<SemichannelBody>
}
struct SemichannelPacked {
    tag: uint32
    id: uint128
    state: Semichannel
}

struct SemichannelSigned {
    signature: bits512
    channel: Cell<SemichannelPacked>
}

struct SemichannelBody {
    seqno: uint64
    conditionalsHash: uint256
    actionsInputHash: uint256
}

struct Quarantine {
    theirState: SemichannelBody?
    startedAt: uint32
    committedByOwner: bool
    ourSettlementFinalized: bool
    theirActionsToExecuteHash: uint256
}

struct ClosureConfig {
    quarantineDuration: uint32
    settlementDuration: uint32
    replicateAttachAmount: coins
}

struct Channel {
    isA: bool
    inited: bool
    commitedSeqnoA: uint64
    commitedSeqnoB: uint64
    walletSeqno: uint32

    keyA: uint256
    keyB: uint256
    id: uint128
    closureConfig: Cell<ClosureConfig>
    partyAddress: Cell<address>?

    quarantine: Cell<Quarantine>?
}

@inline
fun ClosureConfig.serialize(self): cell {
    return self.toCell();
}

@inline
fun PaymentConfig.serialize(self): cell {
    return self.toCell();
}

@inline
fun Balance.serialize(self): cell {
    return Balance.toCell(self);
}

@inline
fun Channel.parse(c: cell): Channel {
    return Channel.fromCell(c);
}

@inline_ref
fun Channel.serialize(self): cell {
    return self.toCell();
}

@inline_ref
fun Semichannel.parse(c: cell, id: uint128, key: uint256): Semichannel {
    var signedState = SemichannelSigned.fromCell(c);
    assert(isSignatureValid(signedState.channel.hash(), signedState.signature as slice, key)) throw ERROR_NOT_AUTHORIZED;
    var unpackedChannel = SemichannelPacked.fromCell(signedState.channel);

    assert(unpackedChannel.tag == TAG_STATE) throw ERROR_WRONG_TAG;
    assert(unpackedChannel.id  == id) throw ERROR_WRONG_CHANNEL_ID;

    return Semichannel{
        data: unpackedChannel.state.data,
        counterpartyData: unpackedChannel.state.counterpartyData,
    };
};


@inline_ref
fun Quarantine.serialize(self): Cell<Quarantine>{
    return self.toCell();
}

