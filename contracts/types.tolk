@pure
fun cell.isUdictReplaceGet(self, keyLen: int, index: int, value: slice): (cell, slice, int)
    asm(value index self keyLen) "DICTUREPLACEGET" "NULLSWAPIFNOT";

@pure
fun cell.beginParseSpecial(self): (slice, int)
    asm "x{D739} s,";

@pure
fun castToS2I(c: continuation): (slice -> int)
    asm "NOP";

@pure
fun emptySlice(): slice
    asm "b{} PUSHSLICE";

@pure
fun proofHash(c: cell): int
    asm "0 CHASHI";

@pure
fun builder.storeVarUInt32(mutate self, x: int): self
    asm "STVARUINT32";

@pure
fun slice.loadVarUInt32(mutate self): int
    asm(-> 1 0) "LDVARUINT32";

struct Semichannel {
    data: SemichannelBody;
    counterpartyData: SemichannelBody;
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

    ref: cell;
}

struct PaymentConfig {
    storageFee: coins;
    addressA: slice;
    addressB: slice;
    currencyType: int;
    ecId: uint32;
    jettonRoot: slice;
    jettonWallet: slice;

    ref: cell;
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
    balance: Balance;
    keyA: uint256;
    keyB: uint256;
    id: uint128;
    closureConfig: ClosureConfig;
    commitedSeqnoA: uint64;
    commitedSeqnoB: uint64;

    quarantine: cell?;
    paymentConfig: PaymentConfig;
}

const ERROR_ALREADY_INITED = 100;
const ERROR_NOT_AUTHORIZED = 101;
const ERROR_INCORRECT_INITIAL_BALANCE = 102;
const ERROR_WRONG_TAG = 104;
const ERROR_OUTDATED_STATE = 105;
const ERROR_QUARANTINE_ALREADY_ACTIVE = 106;
const ERROR_NO_QUARANTINED_STATE = 107;
const ERROR_SEQNO_REGRESS = 108;
const ERROR_UNAUTHORIZED_CHALLENGE = 109;
const ERROR_QUARANTINE_NOT_FINISHED = 110;
const ERROR_TOO_LATE_FOR_QUARANTINE_CHALLENGE = 111;
const ERROR_TOO_LATE_TO_SETTLE_CONDITIONALS = 112;
const ERROR_TOO_EARLY_TO_CLOSE = 113;
const ERROR_WRONG_CHANNEL_ID = 114;
const ERROR_INCORRECT_CONDITIONALS_PROOF = 115;
const ERROR_INCORRECT_UPDATED_PROOF = 116;
const ERROR_NOT_INITED = 117;
const ERROR_NOT_ENOUGH_BALANCE = 118;
const ERROR_AMOUNT_NOT_COVERS_FEE = 119;
const ERROR_INVALID_CURRENCY_TYPE = 120;
const ERROR_INVALID_EC_ID = 121;
const ERROR_NOT_ENOUGH_CONTRACT_BALANCE = 122;
const ERROR_NOT_ENOUGH_MONEY_FOR_INIT_STORAGE = 123;
const ERROR_JETTON_WALLET_ALREADY_INSTALLED = 124;
const ERROR_QUARANTINEE_ALREADY_CHALLENGED = 125;
const ERROR_INCORRECT_SUMMARIZED_BALANCE = 126;
const ERROR_WITHDRAW_REGRESS = 127;

const STORAGE_FULL = 4;
const STORAGE_UP_TO_QUARANTINE = 3;
const STORAGE_UP_TO_CLOSURE_CONFIG = 1;
const STORAGE_BALANCES_AND_KEYS = 0;

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

const TAG_INIT_CHANNEL = 0x481ebc44;
const TAG_COOPERATIVE_CLOSE = 0x8243e9a3;
const TAG_COOPERATIVE_COMMIT = 0x4a390cac;
const TAG_START_UNCOOPERATIVE_CLOSE = 0x8c623692;
const TAG_CHALLENGE_QUARANTINEED_STATE = 0xb8a21379;
const TAG_SETTLE_CONDITIONALS = 0x14588aab;
const TAG_STATE = 0x43685374;

const STATE_UNINITED = 0;
const STATE_OPEN = 1;
const STATE_CLOSURE_STARTED = 2;
const STATE_SETTLING_CONDITIONALS = 3;
const STATE_AWAITING_FINALIZATION = 4;

const FEE_JETTON_ACCEPT  = 35000000; // 0.035
const FEE_JETTON_PAYOUT  = 80000000; // 0.08
const FEE_JETTON_FORWARD = 35000000; // 0.03
const FEE_EC_ACCEPT      = 25000000; // 0.025
const FEE_EC_PAYOUT      = 30000000; // 0.03
const FEE_TON_ACCEPT     = 30000000; // 0.03
const FEE_MIN_BALANCE    = 10000000; // 0.01
const FEE_COMMIT         = 30000000; // 0.03
const FEE_JETTON_WALLET_PROVIDE = 30000000; // 0.03

const CURRENCY_TYPE_TON = 0;
const CURRENCY_TYPE_EC = 1;
const CURRENCY_TYPE_JETTON = 2;

@inline
fun ClosureConfig.parse(c: cell): ClosureConfig {
    var cs: slice = c.beginParse();

    return ClosureConfig{
        quarantineDuration: cs.loadUint(32),
        fine: cs.loadCoins(),
        closeDuration: cs.loadUint(32),
        ref: c,
    }
}

@inline
fun ClosureConfig.serialize(self): cell {
    return self.ref;
}

@inline
fun PaymentConfig.parse(c: cell): PaymentConfig {
    var cs: slice = c.beginParse();

    var conf: PaymentConfig = {
        storageFee: cs.loadCoins(),
        addressA: cs.loadAddress(),
        addressB: cs.loadAddress(),
        currencyType: CURRENCY_TYPE_TON,
        ecId: 0,
        jettonWallet: createAddressNone(),
        jettonRoot: createAddressNone(),
        ref: c,
    };

    var isCustomCurrency: bool = cs.loadBool();
    if (isCustomCurrency) {
        var isJetton: bool = cs.loadBool();
        if (isJetton) {
            var j: slice = cs.loadRef().beginParse();
            conf.currencyType = CURRENCY_TYPE_JETTON;
            conf.jettonRoot = j.loadAddress();
            conf.jettonWallet = j.loadAddress();
        } else {
            conf.currencyType = CURRENCY_TYPE_EC;
            conf.ecId = cs.loadUint(32);
        }
    }

    return conf;
}

@inline
fun PaymentConfig.serialize(self): cell {
    return self.ref;
}

@inline
fun PaymentConfig.update(mutate self) {
    self.ref = beginCell()
        .storeCoins(self.storageFee)
        .storeSlice(self.addressA)
        .storeSlice(self.addressB)
        .storeUint(3, 2) // jetton type
        .storeRef(beginCell()
        .storeSlice(self.jettonRoot)
        .storeSlice(self.jettonWallet)
        .endCell())
        .endCell();
}

@inline
fun Balance.parse(c: cell): Balance {
    var cs: slice = c.beginParse();

    return Balance {
        depositA: cs.loadCoins(),
        depositB: cs.loadCoins(),
        withdrawA: cs.loadCoins(),
        withdrawB: cs.loadCoins(),
        sentA: cs.loadCoins(),
        sentB: cs.loadCoins(),
    }
}

@inline
fun Balance.serialize(self): cell {
    return beginCell()
        .storeCoins(self.depositA)
        .storeCoins(self.depositB)
        .storeCoins(self.withdrawA)
        .storeCoins(self.withdrawB)
        .storeCoins(self.sentA)
        .storeCoins(self.sentB)
        .endCell();
}

@inline
fun Channel.parse(c: cell): Channel {
    var cs: slice = c.beginParse();

    return Channel {
        inited: cs.loadBool(),
        balance: Balance.parse(cs.loadRef()),
        keyA: cs.loadUint(256),
        keyB: cs.loadUint(256),
        id: cs.loadUint(128),
        closureConfig: ClosureConfig.parse(cs.loadRef()),
        commitedSeqnoA: cs.loadUint(32),
        commitedSeqnoB: cs.loadUint(32),
        quarantine: cs.loadMaybeRef(),
        paymentConfig: PaymentConfig.parse(cs.loadRef()),
    }
}

@inline_ref
fun Channel.serialize(self): cell {
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
}

@inline_ref
fun Semichannel.parse(c: cell, id: uint128, key: uint256): Semichannel {
    var cs: slice = c.beginParse();
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
    var cs: slice = c.beginParse();
    return Quarantine{
        stateA: cs.loadSemichannelBody(),
        stateB: cs.loadSemichannelBody(),
        startedAt: cs.loadUint(32),
        committedbyA: cs.loadBool(),
        challenged: cs.loadBool(),
    };
}

@inline_ref
fun Quarantine.serialize(self): cell {
    return beginCell()
        .storeSemichannelBody(self.stateA)
        .storeSemichannelBody(self.stateB)
        .storeUint(self.startedAt, 32)
        .storeBool(self.committedbyA)
        .storeBool(self.challenged)
        .endCell();
}

@inline
fun slice.loadSemichannelBody(mutate self): SemichannelBody {
    return SemichannelBody{
        seqno: self.loadUint(64),
        sent: self.loadCoins(),
        conditionalsHash: self.loadUint(256),
    };
}

@inline
fun builder.storeSemichannelBody(mutate self, body: SemichannelBody): self {
    return self.storeUint(body.seqno, 64).
        storeCoins(body.sent).
        storeUint(body.conditionalsHash, 256);
}