import "errors.tolk"

const TAG_STATE = 0x43685374;

struct Semichannel {
    data: SemichannelBody;
    counterpartyData: SemichannelBody;
}
struct SemichannelPacked {
    tag: uint32;
    channelId: uint128;
    state: Semichannel;
}

struct SemichannelSigned {
    signature: bits512;
    channel: Cell<SemichannelPacked>;
}

struct SemichannelBody {
    seqno: uint64;
    sent: coins;
    conditionalsHash: uint256;
}

struct Quarantine {
    stateA: SemichannelBody;
    stateB: SemichannelBody;
    startedAt: uint32;
    committedbyA: bool;
    challenged: bool;
}

struct ClosureConfig {
    quarantineDuration: uint32;
    fine: coins;
    closeDuration: uint32;
}

struct PaymentConfigJetton {
    jettonRoot: address;
    jettonWallet: address;
}
struct PaymentConfigExtra {
    ecId: uint32;
}

type CustomCurrency = PaymentConfigExtra | Cell<PaymentConfigJetton>;

struct PaymentConfig {
    storageFee: coins;
    addressA: address;
    addressB: address;
    customCurrency: CustomCurrency? 
}

struct Balance {
    depositA: coins;
    depositB: coins;
    withdrawA: coins;
    withdrawB: coins;
    sentA: coins;
    sentB: coins;
}

struct Channel {
    inited: bool;
    balance: Cell<Balance>;
    keyA: uint256;
    keyB: uint256;
    id: uint128;
    closureConfig: Cell<ClosureConfig>;
    commitedSeqnoA: uint64;
    commitedSeqnoB: uint64;

    quarantine: cell?;
    paymentConfig: Cell<PaymentConfig>;
}

@inline
fun ClosureConfig.parse(c: cell): ClosureConfig {
    return ClosureConfig.fromCell(c);
}

@inline
fun ClosureConfig.serialize(self): cell {
    return self.toCell();
}

@inline
fun PaymentConfig.parse(c: cell): PaymentConfig {
    return PaymentConfig.fromCell(c);
}

@inline
fun PaymentConfig.serialize(self): cell {
    return self.toCell();
}

/*
@inline
fun PaymentConfig.update(mutate self) {
    self.ref = beginCell()
        .storeCoins(self.storageFee)
        .storeAddress(self.addressA)
        .storeAddress(self.addressB)
        .storeUint(3, 2) // jetton type
        .storeRef(beginCell()
        .storeAddress(self.jettonRoot)
        .storeAddress(self.jettonWallet)
        .endCell())
        .endCell();
}
*/

@inline
fun Balance.parse(c: cell): Balance {
    return Balance.fromCell(c);
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
    /*
    return beginCell()
        .storeBool(self.inited)
        .storeRef(self.balance.serialize())
        .storeUint(self.keyA, 256)
        .storeUint(self.keyB, 256)
        .storeUint(self.id, 128)
        .storeRef(self.closureConfig.serialize())
        .storeUint(self.commitedSeqnoA, 32)
        .storeUint(self.commitedSeqnoB, 32)
        .storeMaybeRef(self.quarantine)
        .storeRef(self.paymentConfig.serialize())
        .endCell();
    */
}

@inline_ref
fun Semichannel.parse(c: cell, id: uint128, key: uint256): Semichannel {
    var cs = c.beginParse();
    // var signedState = SemichannelSigned.fromCell(c);
    var signature: slice = cs.loadBits(512);
    var semiChannelState: cell = cs.preloadRef();
    assert(isSignatureValid(semiChannelState.hash(), signature, key)) throw ERROR_NOT_AUTHORIZED;
    cs = semiChannelState.beginParse();

    assert(cs.loadUint(32) == TAG_STATE) throw ERROR_WRONG_TAG;
    assert(id == cs.loadUint(128)) throw ERROR_WRONG_CHANNEL_ID;

    var data = cs.loadSemichannelBody();

    var counterpartyData = SemichannelBody{
        seqno: 0,
        sent: 0,
        conditionalsHash: 0,
    };

    var cnpData = cs.loadMaybeRef();
    if (cnpData != null) {
        counterpartyData = cnpData.beginParse().loadSemichannelBody();
    }

    return Semichannel{
        data: data,
        counterpartyData: counterpartyData,
    };
};

@inline_ref
fun Quarantine.parse(c: cell): Quarantine {
    return Quarantine.fromCell(c);
}

@inline_ref
fun Quarantine.serialize(self): cell {
    return self.toCell();
}

@inline
fun slice.loadSemichannelBody(mutate self): SemichannelBody {
    return SemichannelBody.fromSlice(self);
}

@inline
fun builder.storeSemichannelBody(mutate self, body: SemichannelBody): self {
    return self.storeAny(body);
}
