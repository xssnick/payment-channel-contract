import "@stdlib/common.tolk"
import "@stdlib/gas-payments"
import "@stdlib/tvm-dicts"
import "@stdlib/tvm-lowlevel"

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

struct ClosureConfig {
    quarantineDuration: int;
    fine: int;
    closeDuration: int;

    ref: cell;
}

struct PaymentConfig {
    storageFee: int;
    addressA: slice;
    addressB: slice;
    currencyType: int;
    ecId: int;
    jettonRoot: slice;
    jettonWallet: slice;

    ref: cell;
}

struct Balance {
    depositA: int;
    depositB: int;
    withdrawA: int;
    withdrawB: int;
    sentA: int;
    sentB: int;
}

struct Channel {
    inited: bool;
    balance: Balance;
    keyA: int;
    keyB: int;
    id: int;
    closureConfig: ClosureConfig;
    commitedSeqnoA: int;
    commitedSeqnoB: int;

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

fun topUpBalance(channel: Channel, amount: int, msg: slice) {
    assert(channel.inited) throw ERROR_NOT_INITED;
    // we allow topup only when there is no disput
    assert(channel.quarantine == null) throw ERROR_QUARANTINE_ALREADY_ACTIVE;

    var isA: bool = msg.loadBool();
    if (isA) {
        channel.balance.depositA += amount;
    } else {
        channel.balance.depositB += amount;
    }

    return contract.setData(channel.serialize());
}

fun initChannel(channel: Channel, msg: slice) {
    assert(!channel.inited) throw ERROR_ALREADY_INITED;

    var isA: int = msg.loadInt(1);
    var signature: slice = msg.loadBits(512);
    assert(isSignatureValid(msg.hash(), signature, isA ? channel.keyA : channel.keyB)) throw ERROR_NOT_AUTHORIZED;
    assert(msg.loadUint(32) == TAG_INIT_CHANNEL) throw ERROR_WRONG_TAG;
    assert(channel.id == msg.loadUint(128)) throw ERROR_WRONG_CHANNEL_ID;

    // must be 0, we handle adjustments in topup and withdraw
    assert((channel.balance.sentA | channel.balance.sentB | 
            channel.balance.depositA | channel.balance.depositB |
            channel.balance.withdrawA | channel.balance.withdrawB) == 0) throw ERROR_INCORRECT_INITIAL_BALANCE;

    var storageMin: int = FEE_MIN_BALANCE;
    if (channel.paymentConfig.currencyType == CURRENCY_TYPE_JETTON) {
        // must keep fee for final withdrawal
        storageMin += (FEE_JETTON_PAYOUT * 2) + FEE_JETTON_WALLET_PROVIDE;
        if (addressIsNone(channel.paymentConfig.jettonWallet)) {
            // request our wallet address from jetton master
            requestJettonWallet(channel);
        }
    } else if (channel.paymentConfig.currencyType == CURRENCY_TYPE_EC) {
        storageMin += FEE_EC_PAYOUT * 2;
    }

    assert((channel.paymentConfig.storageFee > storageMin) &
        (contract.getOriginalBalance() >= channel.paymentConfig.storageFee)) throw ERROR_NOT_ENOUGH_MONEY_FOR_INIT_STORAGE;

    channel.inited = true;
    return contract.setData(channel.serialize());
}

@inline_ref
fun sendPayout(channel: Channel, sAddr: slice, amount: int, channelId: int, op: int, flags: int) {
    if (channel.paymentConfig.currencyType == CURRENCY_TYPE_TON) {
        sendPayoutTon(sAddr, amount, channelId, op, flags);
    } else if (channel.paymentConfig.currencyType == CURRENCY_TYPE_JETTON) {
        sendPayoutJetton(channel.paymentConfig.jettonWallet, sAddr, amount, channelId, op, flags);
    } else if (channel.paymentConfig.currencyType == CURRENCY_TYPE_EC) {
        sendPayoutEC(channel.paymentConfig.ecId, sAddr, amount, channelId, op, flags);
    }
}

@inline
fun sendPayoutTon(sAddr: slice, amount: int, channelId: int, op: int, flags: int) {
    sendMessage(
        beginCell()
            .storeUint(NON_BOUNCEABLE, 6)
            .storeSlice(sAddr)
            .storeCoins(amount)
            .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1 + 1)
            .storeMessageOp(op)
            .storeUint(channelId, 128)
        .endCell(),
        flags
    );
}

@inline
fun sendPayoutEC(ecId: int, sAddr: slice, amount: int, channelId: int, op: int, flags: int) {
    var currenciesToSend: dict = createEmptyDict();
    currenciesToSend.uDictSetBuilder(32, ecId, beginCell().storeVarUInt32(amount));

    sendMessage(
        beginCell()
            .storeUint(NON_BOUNCEABLE, 6)
            .storeSlice(sAddr)
            .storeCoins(FEE_EC_PAYOUT)
            .storeDict(currenciesToSend)
            .storeUint(0, 4 + 4 + 64 + 32 + 1 + 1)
            .storeMessageOp(op)
            .storeUint(channelId, 128)
        .endCell(),
        flags
    );
}

@inline
fun sendPayoutJetton(wallet: slice, sAddr: slice, amount: int, channelId: int, op: int, flags: int) {
    /*
      transfer query_id:uint64 amount:(VarUInteger 16) destination:MsgAddress
               response_destination:MsgAddress custom_payload:(Maybe ^Cell)
               forward_ton_amount:(VarUInteger 16) forward_payload:(Either Cell ^Cell)
               = InternalMsgBody; 32 + 64 + 124 + 267 + 267 + 1 + 5  + 1
    */
    sendMessage(
        beginCell()
            .storeUint(NON_BOUNCEABLE, 6)
            .storeSlice(wallet)
            .storeCoins(FEE_JETTON_PAYOUT)
            .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1)
            .storeBool(true)
            .storeRef(beginCell()
                .storeMessageOp(OP_JETTON_TRANSFER)
                .storeMessageQueryId(0)
                .storeCoins(amount)
                .storeSlice(sAddr)
                .storeSlice(sAddr)
                .storeMaybeRef(null)
                .storeCoins(FEE_JETTON_FORWARD)
                .storeBool(true)
                .storeMessageOp(op)
                .storeUint(channelId, 128)
            .endCell())
        .endCell(),
        flags
    );
}

fun closeChannel(channel: Channel) {
    sendPayout(channel, channel.paymentConfig.addressB, channel.balance.calcB(), channel.id, OP_CHANNEL_CLOSED, SEND_MODE_IGNORE_ERRORS);
    // side A is considered to be deployer, so he will get rest contract's ton balance
    sendPayout(channel, channel.paymentConfig.addressA, channel.balance.calcA(), channel.id, OP_CHANNEL_CLOSED, SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);

    // while channel contract will be emptied it will survive for some time
    // by clearing storage we allow immediately reopen channel with the same configs
    channel.inited = false;
    channel.balance = Balance {
        depositA: 0,
        depositB: 0,
        withdrawA: 0,
        withdrawB: 0,
        sentA: 0,
        sentB: 0,
    };
    channel.quarantine = null;

    return contract.setData(channel.serialize());
}

@inline_ref
fun cooperativeClose(channel: Channel, msg: slice) {
    var sigA: slice = msg.loadRef().beginParse();
    var sigB: slice = msg.loadRef().beginParse();

    var hash: int = msg.hash();
    assert(msg.loadUint(32) == TAG_COOPERATIVE_CLOSE) throw ERROR_WRONG_TAG;
    assert(channel.id == msg.loadUint(128)) throw ERROR_WRONG_CHANNEL_ID;
    assert(isSignatureValid(hash, sigA, channel.keyA) &
        isSignatureValid(hash, sigB, channel.keyB)) throw ERROR_NOT_AUTHORIZED;

    var newSentA: int = msg.loadCoins();
    var newSentB: int = msg.loadCoins();

    // balance can be moved only from A to B
    // in case of topup after commit generation, commit will fail, to not loose balance
    var oldBalanceSum = channel.balance.calcA() + channel.balance.calcB();
    channel.balance.sentA = newSentA;
    channel.balance.sentB = newSentB;
    var newBalanceSum = channel.balance.calcA() + channel.balance.calcB();

    assert(oldBalanceSum == newBalanceSum) throw ERROR_INCORRECT_SUMMARIZED_BALANCE;

    var newSeqnoA: int = msg.loadUint(64);
    var newSeqnoB: int = msg.loadUint(64);
    assert((channel.commitedSeqnoA < newSeqnoA) &
        (channel.commitedSeqnoB < newSeqnoB)) throw ERROR_SEQNO_REGRESS;

    channel.commitedSeqnoA = newSeqnoA;
    channel.commitedSeqnoB = newSeqnoB;

    closeChannel(channel);
}

@inline_ref
fun cooperativeCommit(channel: Channel, msg: slice) {
    var sigA: slice = msg.loadRef().beginParse();
    var sigB: slice = msg.loadRef().beginParse();

    var hash: int = msg.hash();
    assert(msg.loadUint(32) == TAG_COOPERATIVE_COMMIT) throw ERROR_WRONG_TAG;
    assert(channel.id == msg.loadUint(128)) throw ERROR_WRONG_CHANNEL_ID;
    assert(isSignatureValid(hash, sigA, channel.keyA) &
        isSignatureValid(hash, sigB, channel.keyB)) throw ERROR_NOT_AUTHORIZED;

    var newSentA: int = msg.loadCoins();
    var newSentB: int = msg.loadCoins();

    // balance can be moved only from A to B
    // in case of topup after commit generation, commit will fail, to not loose balance
    var oldBalanceSum = channel.balance.calcA() + channel.balance.calcB();
    channel.balance.sentA = newSentA;
    channel.balance.sentB = newSentB;
    var newBalanceSum = channel.balance.calcA() + channel.balance.calcB();

    assert(oldBalanceSum == newBalanceSum) throw ERROR_INCORRECT_SUMMARIZED_BALANCE;


    var newSeqnoA: int = msg.loadUint(64);
    var newSeqnoB: int = msg.loadUint(64);
    assert((channel.commitedSeqnoA < newSeqnoA) &
        (channel.commitedSeqnoB < newSeqnoB)) throw ERROR_SEQNO_REGRESS;

    channel.commitedSeqnoA = newSeqnoA;
    channel.commitedSeqnoB = newSeqnoB;

    if (channel.quarantine != null) {
        var storedStates: slice = channel.quarantine!.beginParse();
        var (storedSeqnoA: int, _: int) = (storedStates.loadUint(64), storedStates.loadCoins());
        storedStates.skipBits(1);
        var (storedSeqnoB: int, _: int) = (storedStates.loadUint(64), storedStates.loadCoins());
        if ((newSeqnoA > storedSeqnoA) | (newSeqnoB > storedSeqnoB)) {
            // quarantinened state is older than newly commited one, drop it
            channel.quarantine = null;
        }
    }

    var withdrawA: int = msg.loadCoins();
    var withdrawB: int = msg.loadCoins();

    if (channel.balance.withdrawB < withdrawB) {
        var amt = withdrawB - channel.balance.withdrawB;
        channel.balance.withdrawB = withdrawB;
        assert(channel.balance.calcB() >= 0) throw ERROR_NOT_ENOUGH_BALANCE;
        sendPayout(channel, channel.paymentConfig.addressB, amt, channel.id, OP_CHANNEL_WITHDRAW, 0);
    }

    if (channel.balance.withdrawA < withdrawA) {
        var amt = withdrawA - channel.balance.withdrawA;
        channel.balance.withdrawA = withdrawA;
        assert(channel.balance.calcA() >= 0) throw ERROR_NOT_ENOUGH_BALANCE;
        sendPayout(channel,channel.paymentConfig.addressA, amt, channel.id, OP_CHANNEL_WITHDRAW, 0);
    }

    return contract.setData(channel.serialize());
}

@inline
fun slice.parseSemichannelData(mutate self, id: int): (int, int, int) {
    assert(self.loadUint(32) == TAG_STATE) throw ERROR_WRONG_TAG;
    assert(id == self.loadUint(128)) throw ERROR_WRONG_CHANNEL_ID;
    return (self.loadUint(64), self.loadCoins(), self.loadUint(256));
}

@inline
fun slice.parseMaybeSemichannelBody(mutate self): (int, int, int) {
    var maybe: int = self.loadInt(1);
    if (!maybe) {
        return (-1, -1, -1);
    }
    var body: slice = self.loadRef().beginParse();
    return (body.loadUint(64), body.loadCoins(), body.loadUint(256));
}

@inline_ref
fun startUncooperativeClose(channel: Channel, msg: slice) {
    assert(channel.quarantine == null) throw ERROR_QUARANTINE_ALREADY_ACTIVE;
    var signedByA: int = msg.loadInt(1);
    var signature: slice = msg.loadBits(512);
    assert(isSignatureValid(msg.hash(), signature, signedByA ? channel.keyA : channel.keyB)) throw ERROR_NOT_AUTHORIZED;
    assert(msg.loadUint(32) == TAG_START_UNCOOPERATIVE_CLOSE) throw ERROR_WRONG_TAG;
    assert(channel.id == msg.loadUint(128)) throw ERROR_WRONG_CHANNEL_ID;

    var semiChannelA: slice = msg.loadRef().beginParse();
    var signatureA: slice = semiChannelA.loadBits(512);
    var semiChannelStateA: cell = semiChannelA.preloadRef();
    assert(isSignatureValid(semiChannelStateA.hash(), signatureA, channel.keyA)) throw ERROR_NOT_AUTHORIZED;
    var stateA: slice = semiChannelStateA.beginParse();

    var semiChannelB: slice = msg.loadRef().beginParse();
    var signatureB: slice = semiChannelB.loadBits(512);
    var semiChannelStateB: cell = semiChannelB.preloadRef();
    assert(isSignatureValid(semiChannelStateB.hash(), signatureB, channel.keyB)) throw ERROR_NOT_AUTHORIZED;
    var stateB: slice = semiChannelStateB.beginParse();

    var (seqnoA: int, sentA: int, conditionalsHashA: int) = stateA.parseSemichannelData(channel.id);
    var (seqnoBRefA: int, sentBRefA: int, _) = stateA.parseMaybeSemichannelBody();

    var (seqnoB: int, sentB: int, conditionalsHashB: int) = stateB.parseSemichannelData(channel.id);
    var (seqnoARefB: int, sentARefB: int, _) = stateB.parseMaybeSemichannelBody();

    assert((seqnoA >= channel.commitedSeqnoA) &
        (seqnoB >= channel.commitedSeqnoB) &
        (seqnoB >= seqnoBRefA) &
        (seqnoA >= seqnoARefB) &
        (sentB >= sentBRefA) &
        (sentA >= sentARefB)) throw ERROR_OUTDATED_STATE;

    channel.quarantine = beginCell()
        .storeUint(seqnoA, 64)
        .storeCoins(sentA)
        .storeUint(conditionalsHashA, 256)
        .storeUint(seqnoB, 64)
        .storeCoins(sentB)
        .storeUint(conditionalsHashB, 256)
        .storeUint(blockchain.now(), 32)
        .storeInt(signedByA, 1)
        .storeBool(false)
        .endCell();

    return contract.setData(channel.serialize());
}

@inline_ref
fun challengeQuarantinedState(channel: Channel, msg: slice) {
    assert(channel.quarantine != null) throw ERROR_NO_QUARANTINED_STATE;

    // Start with the same checks
    var challengedByA: int = msg.loadInt(1);
    var signature: slice = msg.loadBits(512);
    assert(isSignatureValid(msg.hash(), signature, challengedByA ? channel.keyA : channel.keyB)) throw ERROR_NOT_AUTHORIZED;
    assert(msg.loadUint(32) == TAG_CHALLENGE_QUARANTINEED_STATE) throw ERROR_WRONG_TAG;
    assert(channel.id == msg.loadUint(128)) throw ERROR_WRONG_CHANNEL_ID;

    var semiChannelA: slice = msg.loadRef().beginParse();
    var signatureA: slice = semiChannelA.loadBits(512);
    var semiChannelStateA: cell = semiChannelA.preloadRef();
    assert(isSignatureValid(semiChannelStateA.hash(), signatureA, channel.keyA)) throw ERROR_NOT_AUTHORIZED;
    var stateA: slice = semiChannelStateA.beginParse();

    var semiChannelB: slice = msg.loadRef().beginParse();
    var signatureB: slice = semiChannelB.loadBits(512);
    var semiChannelStateB: cell = semiChannelB.preloadRef();
    assert(isSignatureValid(semiChannelStateB.hash(), signatureB, channel.keyB)) throw ERROR_NOT_AUTHORIZED;
    var stateB: slice = semiChannelStateB.beginParse();

    var (seqnoA: int, sentA: int, conditionalsHashA: int) = stateA.parseSemichannelData(channel.id);
    var (seqnoBRefA: int, sentBRefA: int, _) = stateA.parseMaybeSemichannelBody();

    var (seqnoB: int, sentB: int, conditionalsHashB: int) = stateB.parseSemichannelData(channel.id);
    var (seqnoARefB: int, sentARefB: int, _) = stateB.parseMaybeSemichannelBody();

    assert((seqnoB >= seqnoBRefA) &
        (seqnoA >= seqnoARefB) &
        (seqnoB >= channel.commitedSeqnoB) &
        (seqnoA >= channel.commitedSeqnoA) &
        (sentB >= sentBRefA) &
        (sentA >= sentARefB)) throw ERROR_OUTDATED_STATE;

    if (seqnoBRefA > 0) {
        assert((seqnoBRefA >= channel.commitedSeqnoB)) throw ERROR_OUTDATED_STATE;
    }
    if (seqnoARefB > 0) {
        assert((seqnoARefB >= channel.commitedSeqnoA)) throw ERROR_OUTDATED_STATE;
    }

    var storedStates: slice = channel.quarantine!.beginParse();
    var (storedSeqnoA: int, storedSentA: int) = (storedStates.loadUint(64), storedStates.loadCoins());
    var storedConditionalsHashA: int = storedStates.loadUint(256);

    var (storedSeqnoB: int, storedSentB: int) = (storedStates.loadUint(64), storedStates.loadCoins());
    var storedConditionalsHashB: int = storedStates.loadUint(256);

    var quarantineeStarted: int = storedStates.loadUint(32);
    assert(quarantineeStarted + channel.closureConfig.quarantineDuration > blockchain.now()) throw ERROR_TOO_LATE_FOR_QUARANTINE_CHALLENGE;

    var prevSignedByA: int = storedStates.loadInt(1);
    var quarantineeChallenged: int = storedStates.loadInt(1);
    assert(~ quarantineeChallenged) throw ERROR_QUARANTINEE_ALREADY_CHALLENGED;

    // misbehvaior is when party which committed outdated state
    // or regenerate latest state with lower sent
    var misbehaviorDetected: bool = false;
    if (prevSignedByA) {
        misbehaviorDetected = (seqnoA > storedSeqnoA) | (sentA > storedSentA);
        storedSeqnoA = seqnoA;
        storedSentA = sentA;
        storedConditionalsHashA = conditionalsHashA;
    } else {
        misbehaviorDetected = (seqnoB > storedSeqnoB) | (sentB > storedSentB);
        storedSeqnoB = seqnoB;
        storedSentB = sentB;
        storedConditionalsHashB = conditionalsHashB;
    }
    // only counterparty can report misbehavior
    assert(prevSignedByA != challengedByA) throw ERROR_UNAUTHORIZED_CHALLENGE;

    if (misbehaviorDetected) {
        // add fine to sent
        if (prevSignedByA) {
            storedSentA += channel.closureConfig.fine;
        } else {
            storedSentB += channel.closureConfig.fine;
        }
    }

    channel.quarantine = beginCell()
        .storeUint(storedSeqnoA, 64)
        .storeCoins(storedSentA)
        .storeUint(storedConditionalsHashA, 256)
        .storeUint(storedSeqnoB, 64)
        .storeCoins(storedSentB)
        .storeUint(storedConditionalsHashB, 256)
        .storeUint(quarantineeStarted, 32)
        .storeInt(challengedByA, 1)
        .storeBool(true)
        .endCell();

    return contract.setData(channel.serialize());
}

@inline_ref
fun settleConditionals(channel: Channel, msg: slice) {
    assert(channel.quarantine != null) throw ERROR_NO_QUARANTINED_STATE;

    var fromA: int = msg.loadInt(1);
    var signature: slice = msg.loadBits(512);
    assert(isSignatureValid(msg.hash(), signature, fromA ? channel.keyA : channel.keyB)) throw ERROR_NOT_AUTHORIZED;
    assert(msg.loadUint(32) == TAG_SETTLE_CONDITIONALS) throw ERROR_WRONG_TAG;
    assert(channel.id == msg.loadUint(128)) throw ERROR_WRONG_CHANNEL_ID;

    var conditionalsToSettle: dict = msg.loadDict();
    var conditionalsProof: cell = msg.loadRef();

    var storedStates: slice = channel.quarantine!.beginParse();
    var (seqnoA: int, sentA: int, conditionalsHashA: int) =
        (storedStates.loadUint(64), storedStates.loadCoins(), storedStates.loadUint(256));

    var (seqnoB: int, sentB: int, conditionalsHashB: int) =
        (storedStates.loadUint(64), storedStates.loadCoins(), storedStates.loadUint(256));

    var quarantineeStarted: int = storedStates.loadUint(32);
    var quarantineeFinished: int = quarantineeStarted + channel.closureConfig.quarantineDuration;
    assert(quarantineeFinished < blockchain.now()) throw ERROR_QUARANTINE_NOT_FINISHED;
    assert(quarantineeFinished + channel.closureConfig.closeDuration > blockchain.now()) throw ERROR_TOO_LATE_TO_SETTLE_CONDITIONALS;

    var stateCommitedByA: int = storedStates.loadInt(1);
    var challenged: int = storedStates.loadInt(1);
    var (targetHash: int, targetSent: int) = (conditionalsHashA, sentA);
    if (fromA) {
        (targetHash, targetSent) = (conditionalsHashB, sentB);
    }

    var (csProof: slice, special: int) = conditionalsProof.beginParseSpecial();
    assert(special) throw ERROR_INCORRECT_CONDITIONALS_PROOF;
    assert(csProof.loadUint(8) == 3) throw ERROR_INCORRECT_CONDITIONALS_PROOF;
    assert(csProof.preloadUint(256) == targetHash) throw ERROR_INCORRECT_CONDITIONALS_PROOF;

    var target: cell = csProof.preloadRef();
    var more: bool = true;
    do {
        var (cid: int?, input: slice?, more redef) = conditionalsToSettle.uDictDeleteFirstAndGet(32);
        if (more) {
            var empty: slice = emptySlice();
            var (target redef, condition: slice, ok: int) = target.isUdictReplaceGet(32, cid!, empty);
            assert(ok) throw ERROR_INCORRECT_CONDITIONALS_PROOF;
            var executableCondition = castToS2I(transformSliceToContinuation(condition));
            // NOTE! It seems dangerous to run unknown code and it really is!
            // However, runned code is signed by one party and executed by another
            // That way both party authorized it.
            // Obviously, B should not sign incorrect code which (for instance) sends all money to A
            // The same way A should not run incorrect code which sends all money to B.
            targetSent += executableCondition(input!);
        }
    } while (more);

    if (fromA) {
        (conditionalsHashB, sentB) = (proofHash(target), targetSent);
    } else {
        (conditionalsHashA, sentA) = (proofHash(target), targetSent);
    }

    channel.quarantine = beginCell()
        .storeUint(seqnoA, 64)
        .storeCoins(sentA)
        .storeUint(conditionalsHashA, 256)
        .storeUint(seqnoB, 64)
        .storeCoins(sentB)
        .storeUint(conditionalsHashB, 256)
        .storeUint(quarantineeStarted, 32)
        .storeInt(stateCommitedByA, 1)
        .storeInt(challenged, 1)
        .endCell();
    return contract.setData(channel.serialize());
}

@inline_ref
fun finishUncooperativeClose(channel: Channel) {
    assert(channel.quarantine != null) throw ERROR_NO_QUARANTINED_STATE;

    var storedStates: slice = channel.quarantine!.beginParse();
    var (seqnoA: int, sentA: int, _: int) =
        (storedStates.loadUint(64), storedStates.loadCoins(), storedStates.loadUint(256));
    var (seqnoB: int, sentB: int, _: int) =
        (storedStates.loadUint(64), storedStates.loadCoins(), storedStates.loadUint(256));

    var quarantineeStarted: int = storedStates.loadUint(32);
    assert(quarantineeStarted +
        channel.closureConfig.quarantineDuration +
        channel.closureConfig.closeDuration < blockchain.now()) throw ERROR_TOO_EARLY_TO_CLOSE;

    channel.balance.sentB += sentB;
    channel.balance.sentA += sentA;

    var balanceB = channel.balance.calcB();
    var balanceA = channel.balance.calcA();

    if (balanceB < 0) {
        channel.balance.sentA -= balanceB;
    }
    if (balanceA < 0) {
        channel.balance.sentB -= balanceA;
    }

    channel.commitedSeqnoA = seqnoA + 1;
    channel.commitedSeqnoB = seqnoB + 1;
    closeChannel(channel);
}

fun onInternalMessage(_: int, amount: int, inMsgFull: cell, inMsg: slice) {
    var channel = Channel.parse(contract.getData());

    var cs: slice = inMsgFull.beginParse();
    var flags: int = cs.loadUint(4);
    if (flags & 1) {
        // bounced
        return;
    }
    var sender: slice = cs.loadAddress();

    // Note, operators of channels are always off-chain parties, not contracts
    // thus no responses and query_ids
    var op: int = inMsg.loadUint(32);
    if (op == OP_TOP_UP_BALANCE) {
        if (channel.paymentConfig.currencyType == CURRENCY_TYPE_EC) {
            assert(amount >= FEE_EC_ACCEPT) throw ERROR_AMOUNT_NOT_COVERS_FEE;

            var ec: dict = cs.loadDict();
            var (v: slice?, ok: bool) = ec.uDictGet(32, channel.paymentConfig.ecId);
            assert(ok) throw ERROR_INVALID_EC_ID;

            var ecAmount: int = v!.loadVarUInt32();
            topUpBalance(channel,ecAmount, inMsg);
        } else {
            assert(amount >= FEE_TON_ACCEPT) throw ERROR_AMOUNT_NOT_COVERS_FEE;

            topUpBalance(channel, amount - FEE_TON_ACCEPT, inMsg);
        }
    } else if (op == OP_JETTON_TRANSFER_NOTIFICATION) {
        // return because custom excess handled inside
        return acceptJettons(channel, sender, amount, inMsg);
    } else if (op == OP_JETTON_TAKE_WALLET_ADDRESS) {
        // no excess
        return assignJettonWallet(channel, sender, inMsg);
    } else if (op == OP_COOPERATIVE_COMMIT) {
        cooperativeCommit(channel, inMsg);
    } else if (op == OP_INIT_CHANNEL) {
        initChannel(channel, inMsg);
    } else if (op == OP_COOPERATIVE_CLOSE) {
        // excess hadled in channelClose()
        return cooperativeClose(channel, inMsg);
    } else if (op == OP_START_UNCOOPERATIVE_CLOSE) {
        startUncooperativeClose(channel, inMsg);
    } else if (op == OP_CHALLENGE_QUARANTINEED_STATE) {
        challengeQuarantinedState(channel, inMsg);
    } else if (op == OP_SETTLE_CONDITIONALS) {
        settleConditionals(channel, inMsg);
    } else if (op == OP_FINISH_UNCOOPERATIVE_CLOSE) {
        // excess hadled in channelClose()
        return finishUncooperativeClose(channel);
    } else {
        throw 0xffff;
    }

    sendExcess(channel, sender);
}

@inline_ref
fun acceptJettons(channel: Channel, sender: slice, tonAmount: int, payload: slice) {
    /* TEP-74
      transfer_notification#7362d09c query_id:uint64 amount:(VarUInteger 16)
                                     sender:MsgAddress forward_payload:(Either Cell ^Cell)
                                     = InternalMsgBody;
    */
    assert(channel.paymentConfig.currencyType == CURRENCY_TYPE_JETTON) throw ERROR_INVALID_CURRENCY_TYPE;

    payload.skipBits(64);
    var jettonAmount: int = payload.loadCoins();

    var jettonSender: slice = payload.loadAddress();
    var eitherForwardPayload: bool = payload.loadBool();
    var forwardPayload: slice = eitherForwardPayload ? payload.loadRef().beginParse() : payload;

    if ((tonAmount < FEE_JETTON_ACCEPT) | (!channel.paymentConfig.jettonWallet.bitsEqual(sender))) {
        return sendJettonsBack(jettonSender, jettonAmount, sender);
    }

    try {
        var innerOp: int = forwardPayload.loadInt(32);
        if (innerOp == OP_TOP_UP_BALANCE) {
            topUpBalance(channel, jettonAmount, forwardPayload);
            return sendExcess(channel,jettonSender);
        }
        throw 0xffff;
    } catch {
        sendJettonsBack(jettonSender, jettonAmount, sender);
    }
}

@inline_ref
fun sendJettonsBack(dest: slice, amount: int, jettonWallet: slice) {
    /*
      transfer query_id:uint64 amount:(VarUInteger 16) destination:MsgAddress
               response_destination:MsgAddress custom_payload:(Maybe ^Cell)
               forward_ton_amount:(VarUInteger 16) forward_payload:(Either Cell ^Cell)
               = InternalMsgBody; 32 + 64 + 124 + 267 + 267 + 1 + 5  + 1
    */
    sendMessage(
        beginCell()
            .storeUint(NON_BOUNCEABLE, 6)
            .storeSlice(jettonWallet)
            .storeCoins(0)
            .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1)
            .storeBool(true)
            .storeRef(beginCell()
                .storeMessageOp(OP_JETTON_TRANSFER)
                .storeMessageQueryId(0)
                .storeCoins(amount)
                .storeSlice(dest)
                .storeSlice(dest)
                .storeMaybeRef(null)
                .storeCoins(1)
                .storeBool(false)
            .endCell())
        .endCell(),
        SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS
    );
}

@inline_ref
fun sendExcess(channel: Channel, dest: slice) {
    var reserve: int = channel.paymentConfig.storageFee;
    if (channel.paymentConfig.currencyType == CURRENCY_TYPE_TON) {
        reserve += channel.balance.calcA() + channel.balance.calcB();
    }
    reserveToncoinsOnBalance(reserve, 0);

   sendMessage(
        beginCell()
            .storeUint(NON_BOUNCEABLE, 6)
            .storeSlice(dest)
            .storeCoins(0)
            .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1 + 1)
            .storeMessageOp(OP_EXCESSES)
            .storeMessageQueryId(0)
        .endCell(),
       SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS
    );
}

@inline_ref
fun assignJettonWallet(channel: Channel, sender: slice, payload: slice) {
    /* TEP-89
      take_wallet_address#d1735400 query_id:uint64 wallet_address:MsgAddress
                                   owner_address:(Maybe ^MsgAddress)
                                   = InternalMsgBody;
    */
    payload.skipBits(64);

    assert(addressIsNone(channel.paymentConfig.jettonWallet)) throw ERROR_JETTON_WALLET_ALREADY_INSTALLED;
    assert(channel.paymentConfig.jettonRoot.bitsEqual(sender)) throw ERROR_NOT_AUTHORIZED;

    channel.paymentConfig.jettonWallet = payload.loadAddress();
    channel.paymentConfig.update();

    return contract.setData(channel.serialize());
}

@inline
fun Balance.calcA(self): int {
    return (self.depositA + self.sentB) - (self.sentA + self.withdrawA);
}

@inline
fun Balance.calcB(self): int {
    return (self.depositB + self.sentA) - (self.sentB + self.withdrawB);
}

@inline_ref
fun requestJettonWallet(channel: Channel) {
    /* TEP-89
      provide_wallet_address#2c76b973 query_id:uint64 owner_address:MsgAddress
                                      include_address:Bool
                                      = InternalMsgBody;
    */
    sendMessage(beginCell()
        .storeUint(NON_BOUNCEABLE, 6)
        .storeSlice(channel.paymentConfig.jettonRoot)
        .storeCoins(FEE_JETTON_WALLET_PROVIDE)
        .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1 + 1)
        .storeMessageOp(OP_JETTON_PROVIDE_WALLET_ADDRESS)
        .storeMessageQueryId(0)
        .storeSlice(contract.getAddress())
        .storeBool(false)
    .endCell(), 0);
    return;
}

get getChannelState(): int {
    var channel = Channel.parse(contract.getData());

    if (!channel.inited) {
        return STATE_UNINITED;
    }
    if (channel.quarantine == null) {
        return STATE_OPEN;
    }

    var storedStates: slice = channel.quarantine!.beginParse();
    storedStates.skipBits(64);
    storedStates.loadCoins();
    storedStates.skipBits(1 + 64);
    storedStates.loadCoins();
    storedStates.skipBits(1);

    var quarantineeStarted: int = storedStates.loadUint(32);
    if (quarantineeStarted + channel.closureConfig.quarantineDuration > blockchain.now()) {
        return STATE_CLOSURE_STARTED;
    }

    if (quarantineeStarted +
        channel.closureConfig.quarantineDuration +
        channel.closureConfig.closeDuration > blockchain.now()) {
        return STATE_SETTLING_CONDITIONALS;
    }
    
    return STATE_AWAITING_FINALIZATION;
}

get getChannelData() {
    var channel = Channel.parse(contract.getData());

    return (getChannelState(),
        [channel.balance.calcA(), channel.balance.calcB(), channel.balance.depositA, channel.balance.depositB, channel.balance.withdrawA, channel.balance.withdrawB],
        [channel.keyA, channel.keyB],
        channel.id,
        channel.closureConfig.ref,
        [channel.commitedSeqnoA, channel.commitedSeqnoB],
        channel.quarantine,
        [channel.paymentConfig.storageFee, channel.paymentConfig.addressA, channel.paymentConfig.addressB]);
}
