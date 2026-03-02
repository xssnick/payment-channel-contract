import "../errors"

struct StateSide {
    conditionalsHash: uint256
    actionsInputHash: uint256
}

struct (0x2f0638e4) StateBody {
    id: uint128
    seqno: uint64
    A: Cell<StateSide>
    B: Cell<StateSide>
}

struct StateBodySigned {
    signatureA: Cell<bits512>
    signatureB: Cell<bits512>
    state: RemainingBitsAndRefs
}

struct Quarantine {
    seqno: uint64
    theirState: StateSide?
    startedAt: uint32
    committedByOwner: bool
    ourSettlementFinalized: bool
    actionsToExecuteHash: uint256
}

struct ClosureConfig {
    quarantineDuration: uint32
    settlementDuration: uint32
    actionsDuration: uint32
    replicateAttachAmount: coins
}

struct Channel {
    isA: bool
    inited: bool
    commitedSeqno: uint64
    walletSeqno: uint32

    keyA: uint256
    keyB: uint256
    id: uint128
    closureConfig: Cell<ClosureConfig>
    partyAddress: address

    quarantine: Cell<Quarantine>?
}

@inline
fun Channel.parse(c: cell): Channel {
    return Channel.fromCell(c);
}

@inline_ref
fun Channel.serialize(self): cell {
    return self.toCell();
}

fun StateBodySigned.unpackAndVerify(self, id: uint128, seqno: uint64, keyA: uint256, keyB: uint256): StateBody {
    var hash = self.state.hash();
    assert(isSignatureValid(hash, self.signatureA.beginParse(), keyA)
        & isSignatureValid(hash, self.signatureB.beginParse(), keyB)) throw ERROR_NOT_AUTHORIZED;

    var res = StateBody.fromSlice(self.state);
    assert(res.id == id) throw ERROR_WRONG_CHANNEL_ID;
    assert(res.seqno >= seqno) throw ERROR_OUTDATED_STATE;
    
    return res;
}


@inline_ref
fun Quarantine.serialize(self): Cell<Quarantine>{
    return self.toCell();
}

const STATE_UNINITED = 0
const STATE_OPEN = 1
const STATE_CLOSURE_STARTED = 2
const STATE_SETTLING_CONDITIONALS = 3
const STATE_EXECUTING_ACTIONS = 4
const STATE_AWAITING_FINALIZATION = 5
