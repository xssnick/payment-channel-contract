import "@stdlib/common.tolk"
import "@stdlib/gas-payments"
import "@stdlib/tvm-dicts"
import "@stdlib/tvm-lowlevel"

@pure
fun isUdictReplaceGet(dict: cell, keyLen: int, index: int, value: slice): (cell, slice, int)
asm(value index dict keyLen) "DICTUREPLACEGET" "NULLSWAPIFNOT";

@pure
fun beginParseSpecial(c: cell): (slice, int)
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
fun storeVarUInt32(b: builder, x: int): builder
asm "STVARUINT32";

@pure
fun loadVarUInt32(mutate self: slice): int
asm(-> 1 0) "LDVARUINT32";

global ctxInited: bool;
global ctxBalanceA: int;
global ctxBalanceB: int;
global ctxDepositA: int;
global ctxDepositB: int;
global ctxWithdrawA: int;
global ctxWithdrawB: int;
global ctxKeyA: int;
global ctxKeyB: int;
global ctxChannelId: int;
global ctxCommitedSeqnoA: int;
global ctxCommitedSeqnoB: int;
global ctxQuarantine: cell;

global ctxClosureConfigRef: cell;
global ctxClosureConfigQuarantineDuration: int;
global ctxClosureConfigCloseDuration: int;
global ctxClosureConfigFine: int;

global ctxPaymentConfigRef: cell;
global ctxPaymentConfigAddressA: slice;
global ctxPaymentConfigAddressB: slice;
global ctxPaymentConfigStorageFee: int;

global ctxCurrencyType: int;

global ctxECID: int;

global ctxJettonRoot: slice;
global ctxJettonWallet: slice;

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
const TAG_COOPERATIVE_CLOSE = 0x0802ada3;
const TAG_COOPERATIVE_COMMIT = 0x48baa61a;
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
fun loadClosureConfig(mutate self: slice): void {
    ctxClosureConfigRef = self.loadRef();
    var conf: slice = ctxClosureConfigRef.beginParse();
    ctxClosureConfigQuarantineDuration = conf.loadUint(32);
    ctxClosureConfigFine = conf.loadCoins();
    ctxClosureConfigCloseDuration = conf.loadUint(32);
}

@inline
fun loadPaymentConfig(mutate self: slice): void {
    ctxPaymentConfigRef = self.loadRef();
    var pcs: slice = ctxPaymentConfigRef.beginParse();
    ctxPaymentConfigStorageFee = pcs.loadCoins();
    ctxPaymentConfigAddressA = pcs.loadAddress();
    ctxPaymentConfigAddressB = pcs.loadAddress();
    var isCustomCurrency: bool = pcs.loadBool();
    if (isCustomCurrency) {
        var isJetton: bool = pcs.loadBool();
        if (isJetton) {
            var j: slice = pcs.loadRef().beginParse();
            ctxCurrencyType = CURRENCY_TYPE_JETTON;
            ctxJettonRoot = j.loadAddress();
            ctxJettonWallet = j.loadAddress();
        } else {
            ctxCurrencyType = CURRENCY_TYPE_EC;
            ctxECID = pcs.loadUint(32);
        }
    } else {
        ctxCurrencyType = CURRENCY_TYPE_TON;
    }
}

@inline
fun loadBalances(mutate self: slice): void {
    var cs = self.loadRef().beginParse();
    ctxDepositA = cs.loadCoins();
    ctxDepositB = cs.loadCoins();
    ctxWithdrawA = cs.loadCoins();
    ctxWithdrawB = cs.loadCoins();
    ctxBalanceA = cs.loadCoins();
    ctxBalanceB = cs.loadCoins();
}

@inline
fun balancesCell(): cell {
    return beginCell()
        .storeCoins(ctxDepositA)
        .storeCoins(ctxDepositB)
        .storeCoins(ctxWithdrawA)
        .storeCoins(ctxWithdrawB)
        .storeCoins(ctxBalanceA)
        .storeCoins(ctxBalanceB)
    .endCell();
}

fun loadStorage() {
    var cs: slice = getContractData().beginParse();
    ctxInited = cs.loadBool();
    cs.loadBalances();

    ctxKeyA = cs.loadUint(256);
    ctxKeyB = cs.loadUint(256);
    ctxChannelId = cs.loadUint(128);
    cs.loadClosureConfig();

    ctxCommitedSeqnoA = cs.loadUint(32);
    ctxCommitedSeqnoB = cs.loadUint(32);
    ctxQuarantine = cs.loadMaybeRef();

    cs.loadPaymentConfig();
}

fun saveStorage() {
    setContractData(beginCell()
        .storeBool(ctxInited)
        .storeRef(balancesCell())
        .storeUint(ctxKeyA, 256)
        .storeUint(ctxKeyB, 256)
        .storeUint(ctxChannelId, 128)
        .storeRef(ctxClosureConfigRef)
        .storeUint(ctxCommitedSeqnoA, 32)
        .storeUint(ctxCommitedSeqnoB, 32)
        .storeMaybeRef(ctxQuarantine)
        .storeRef(ctxPaymentConfigRef)
    .endCell());
}

fun topUpBalance(amount: int, msg: slice) {
    assert(ctxInited) throw ERROR_NOT_INITED;
    // we allow topup only when there is no disput
    assert(ctxQuarantine == null) throw ERROR_QUARANTINE_ALREADY_ACTIVE;

    var isA: bool = msg.loadBool();
    if (isA) {
        ctxDepositA += amount;
        ctxBalanceA += amount;
    } else {
        ctxDepositB += amount;
        ctxBalanceB += amount;
    }

    return saveStorage();
}

fun initChannel(msg: slice) {
    assert(!ctxInited) throw ERROR_ALREADY_INITED;

    var isA: int = msg.loadInt(1);
    var signature: slice = msg.loadBits(512);
    assert(isSignatureValid(sliceHash(msg), signature, isA ? ctxKeyA : ctxKeyB)) throw ERROR_NOT_AUTHORIZED;
    assert(msg.loadUint(32) == TAG_INIT_CHANNEL) throw ERROR_WRONG_TAG;
    assert(ctxChannelId == msg.loadUint(128)) throw ERROR_WRONG_CHANNEL_ID;

    // must be 0, we handle adjustments in topup and withdraw
    assert((ctxBalanceA | ctxBalanceB | ctxDepositA | ctxDepositB | ctxWithdrawA | ctxWithdrawB) == 0) throw ERROR_INCORRECT_INITIAL_BALANCE;

    var storageMin: int = FEE_MIN_BALANCE;
    if (ctxCurrencyType == CURRENCY_TYPE_JETTON) {
        // must keep fee for final withdrawal
        storageMin += (FEE_JETTON_PAYOUT * 2) + FEE_JETTON_WALLET_PROVIDE;
        if (ctxJettonWallet.addressIsNone()) {
            // request our wallet address from jetton master
            requestJettonWallet();
        }
    } else if (ctxCurrencyType == CURRENCY_TYPE_EC) {
        storageMin += FEE_EC_PAYOUT * 2;
    }

    assert((ctxPaymentConfigStorageFee > storageMin) &
        (getMyOriginalBalance() >= ctxPaymentConfigStorageFee)) throw ERROR_NOT_ENOUGH_MONEY_FOR_INIT_STORAGE;

    ctxInited = true;
    return saveStorage();
}

@inline_ref
fun sendPayout(sAddr: slice, amount: int, channelId: int, op: int, flags: int) {
    if (ctxCurrencyType == CURRENCY_TYPE_TON) {
        sendPayoutTon(sAddr, amount, channelId, op, flags);
    } else if (ctxCurrencyType == CURRENCY_TYPE_JETTON) {
        sendPayoutJetton(sAddr, amount, channelId, op, flags);
    } else if (ctxCurrencyType == CURRENCY_TYPE_EC) {
        sendPayoutEC(sAddr, amount, channelId, op, flags);
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
fun sendPayoutEC(sAddr: slice, amount: int, channelId: int, op: int, flags: int) {
    var currenciesToSend: cell = createEmptyDict();
    currenciesToSend.uDictSetBuilder(32, ctxECID, beginCell().storeVarUInt32(amount));

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
fun sendPayoutJetton(sAddr: slice, amount: int, channelId: int, op: int, flags: int) {
    /*
      transfer query_id:uint64 amount:(VarUInteger 16) destination:MsgAddress
               response_destination:MsgAddress custom_payload:(Maybe ^Cell)
               forward_ton_amount:(VarUInteger 16) forward_payload:(Either Cell ^Cell)
               = InternalMsgBody; 32 + 64 + 124 + 267 + 267 + 1 + 5  + 1
    */
    sendMessage(
        beginCell()
            .storeUint(NON_BOUNCEABLE, 6)
            .storeSlice(ctxJettonWallet)
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

@inline
fun withdraw(a: int, b: int) {
    if (b > 0) {
        ctxBalanceB -= b;
        ctxWithdrawB += b;
        assert(ctxBalanceB >= 0) throw ERROR_NOT_ENOUGH_BALANCE;
        sendPayout(ctxPaymentConfigAddressB, b, ctxChannelId, OP_CHANNEL_WITHDRAW, 0);
    }

    if (a > 0) {
        ctxBalanceA -= a;
        ctxWithdrawA += a;
        assert(ctxBalanceA >= 0) throw ERROR_NOT_ENOUGH_BALANCE;
        sendPayout(ctxPaymentConfigAddressA, a, ctxChannelId, OP_CHANNEL_WITHDRAW, 0);
    }
}

fun closeChannel() {
    sendPayout(ctxPaymentConfigAddressB, ctxBalanceB, ctxChannelId, OP_CHANNEL_CLOSED, SEND_MODE_IGNORE_ERRORS);
    // side A is considered to be deployer, so he will get rest contract's ton balance
    sendPayout(ctxPaymentConfigAddressA, ctxBalanceA, ctxChannelId, OP_CHANNEL_CLOSED, SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);

    // while channel contract will be emptied it will survive for some time
    // by clearing storage we allow immediately reopen channel with the same configs
    ctxInited = false;
    ctxBalanceA = 0;
    ctxBalanceB = 0;
    ctxDepositA = 0;
    ctxDepositB = 0;
    ctxWithdrawA = 0;
    ctxWithdrawB = 0;
    ctxQuarantine = null;
    saveStorage();
}

@inline_ref
fun cooperativeClose(msg: slice) {
    var sigA: slice = msg.loadRef().beginParse();
    var sigB: slice = msg.loadRef().beginParse();

    var hash: int = sliceHash(msg);
    assert(msg.loadUint(32) == TAG_COOPERATIVE_CLOSE) throw ERROR_WRONG_TAG;
    assert(ctxChannelId == msg.loadUint(128)) throw ERROR_WRONG_CHANNEL_ID;
    assert(isSignatureValid(hash, sigA, ctxKeyA) &
        isSignatureValid(hash, sigB, ctxKeyB)) throw ERROR_NOT_AUTHORIZED;

    var newBalanceA: int = msg.loadCoins();
    var newBalanceB: int = msg.loadCoins();

    // balance can be moved only from A to B
    // in case of topup after commit generation, commit will fail, to not loose balance
    assert((newBalanceA + newBalanceB) == (ctxBalanceA + ctxBalanceB)) throw ERROR_INCORRECT_SUMMARIZED_BALANCE;

    ctxBalanceA = newBalanceA;
    ctxBalanceB = newBalanceB;

    var newSeqnoA: int = msg.loadUint(64);
    var newSeqnoB: int = msg.loadUint(64);
    assert((ctxCommitedSeqnoA < newSeqnoA) &
        (ctxCommitedSeqnoB < newSeqnoB)) throw ERROR_SEQNO_REGRESS;

    ctxCommitedSeqnoA = newSeqnoA;
    ctxCommitedSeqnoB = newSeqnoB;

    closeChannel();
}

@inline_ref
fun cooperativeCommit(msg: slice) {
    var sigA: slice = msg.loadRef().beginParse();
    var sigB: slice = msg.loadRef().beginParse();

    var hash: int = sliceHash(msg);
    assert(msg.loadUint(32) == TAG_COOPERATIVE_COMMIT) throw ERROR_WRONG_TAG;
    assert(ctxChannelId == msg.loadUint(128)) throw ERROR_WRONG_CHANNEL_ID;
    assert(isSignatureValid(hash, sigA, ctxKeyA) &
        isSignatureValid(hash, sigB, ctxKeyB)) throw ERROR_NOT_AUTHORIZED;

    var newBalanceA: int = msg.loadCoins();
    var newBalanceB: int = msg.loadCoins();

    // balance can be moved only from A to B
    // in case of topup after commit generation, commit will fail, to not loose balance
    assert((newBalanceA + newBalanceB) == (ctxBalanceA + ctxBalanceB)) throw ERROR_INCORRECT_SUMMARIZED_BALANCE;

    ctxBalanceA = newBalanceA;
    ctxBalanceB = newBalanceB;

    var newSeqnoA: int = msg.loadUint(64);
    var newSeqnoB: int = msg.loadUint(64);
    assert((ctxCommitedSeqnoA < newSeqnoA) &
        (ctxCommitedSeqnoB < newSeqnoB)) throw ERROR_SEQNO_REGRESS;

    ctxCommitedSeqnoA = newSeqnoA;
    ctxCommitedSeqnoB = newSeqnoB;

    if (ctxQuarantine != null) {
        var storedStates: slice = ctxQuarantine.beginParse();
        var (storedSeqnoA: int, _: int) = (storedStates.loadUint(64), storedStates.loadCoins());
        storedStates.skipBits(1);
        var (storedSeqnoB: int, _: int) = (storedStates.loadUint(64), storedStates.loadCoins());
        if ((newSeqnoA > storedSeqnoA) | (newSeqnoB > storedSeqnoB)) {
            // quarantinened state is older than newly commited one, drop it
            ctxQuarantine = null;
        }
    }

    var withdrawA: int = msg.loadCoins();
    var withdrawB: int = msg.loadCoins();

    if ((withdrawA | withdrawB) > 0) {
        withdraw(withdrawA, withdrawB);
    }

    saveStorage();
}

@inline
fun parseSemichannelData(mutate self: slice): (int, int, int) {
    assert(self.loadUint(32) == TAG_STATE) throw ERROR_WRONG_TAG;
    assert(ctxChannelId == self.loadUint(128)) throw ERROR_WRONG_CHANNEL_ID;
    return (self.loadUint(64), self.loadCoins(), self.loadUint(256));
}

@inline
fun parseMaybeSemichannelBody(mutate self: slice): (int, int, int) {
    var maybe: int = self.loadInt(1);
    if (!maybe) {
        return (-1, -1, -1);
    }
    var body: slice = self.loadRef().beginParse();
    return (body.loadUint(64), body.loadCoins(), body.loadUint(256));
}

@inline_ref
fun startUncooperativeClose(msg: slice) {
    assert(ctxQuarantine == null) throw ERROR_QUARANTINE_ALREADY_ACTIVE;
    var signedByA: int = msg.loadInt(1);
    var signature: slice = msg.loadBits(512);
    assert(isSignatureValid(sliceHash(msg), signature, signedByA ? ctxKeyA : ctxKeyB)) throw ERROR_NOT_AUTHORIZED;
    assert(msg.loadUint(32) == TAG_START_UNCOOPERATIVE_CLOSE) throw ERROR_WRONG_TAG;
    assert(ctxChannelId == msg.loadUint(128)) throw ERROR_WRONG_CHANNEL_ID;

    var semiChannelA: slice = msg.loadRef().beginParse();
    var signatureA: slice = semiChannelA.loadBits(512);
    var semiChannelStateA: cell = semiChannelA.preloadRef();
    assert(isSignatureValid(cellHash(semiChannelStateA), signatureA, ctxKeyA)) throw ERROR_NOT_AUTHORIZED;
    var stateA: slice = semiChannelStateA.beginParse();

    var semiChannelB: slice = msg.loadRef().beginParse();
    var signatureB: slice = semiChannelB.loadBits(512);
    var semiChannelStateB: cell = semiChannelB.preloadRef();
    assert(isSignatureValid(cellHash(semiChannelStateB), signatureB, ctxKeyB)) throw ERROR_NOT_AUTHORIZED;
    var stateB: slice = semiChannelStateB.beginParse();

    var (seqnoA: int, sentA: int, conditionalsHashA: int) = stateA.parseSemichannelData();
    var (seqnoBRefA: int, sentBRefA: int, _) = stateA.parseMaybeSemichannelBody();

    var (seqnoB: int, sentB: int, conditionalsHashB: int) = stateB.parseSemichannelData();
    var (seqnoARefB: int, sentARefB: int, _) = stateB.parseMaybeSemichannelBody();

    assert((seqnoA >= ctxCommitedSeqnoA) &
        (seqnoB >= ctxCommitedSeqnoB) &
        (seqnoB >= seqnoBRefA) &
        (seqnoA >= seqnoARefB) &
        (sentB >= sentBRefA) &
        (sentA >= sentARefB)) throw ERROR_OUTDATED_STATE;

    ctxQuarantine = beginCell()
        .storeUint(seqnoA, 64)
        .storeCoins(sentA)
        .storeUint(conditionalsHashA, 256)
        .storeUint(seqnoB, 64)
        .storeCoins(sentB)
        .storeUint(conditionalsHashB, 256)
        .storeUint(now(), 32)
        .storeInt(signedByA, 1)
        .storeBool(false)
        .endCell();

    saveStorage();
}

@inline_ref
fun challengeQuarantinedState(msg: slice) {
    assert(ctxQuarantine != null) throw ERROR_NO_QUARANTINED_STATE;

    // Start with the same checks
    var challengedByA: int = msg.loadInt(1);
    var signature: slice = msg.loadBits(512);
    assert(isSignatureValid(sliceHash(msg), signature, challengedByA ? ctxKeyA : ctxKeyB)) throw ERROR_NOT_AUTHORIZED;
    assert(msg.loadUint(32) == TAG_CHALLENGE_QUARANTINEED_STATE) throw ERROR_WRONG_TAG;
    assert(ctxChannelId == msg.loadUint(128)) throw ERROR_WRONG_CHANNEL_ID;

    var semiChannelA: slice = msg.loadRef().beginParse();
    var signatureA: slice = semiChannelA.loadBits(512);
    var semiChannelStateA: cell = semiChannelA.preloadRef();
    assert(isSignatureValid(cellHash(semiChannelStateA), signatureA, ctxKeyA)) throw ERROR_NOT_AUTHORIZED;
    var stateA: slice = semiChannelStateA.beginParse();

    var semiChannelB: slice = msg.loadRef().beginParse();
    var signatureB: slice = semiChannelB.loadBits(512);
    var semiChannelStateB: cell = semiChannelB.preloadRef();
    assert(isSignatureValid(cellHash(semiChannelStateB), signatureB, ctxKeyB)) throw ERROR_NOT_AUTHORIZED;
    var stateB: slice = semiChannelStateB.beginParse();

    var (seqnoA: int, sentA: int, conditionalsHashA: int) = stateA.parseSemichannelData();
    var (seqnoBRefA: int, sentBRefA: int, _) = stateA.parseMaybeSemichannelBody();

    var (seqnoB: int, sentB: int, conditionalsHashB: int) = stateB.parseSemichannelData();
    var (seqnoARefB: int, sentARefB: int, _) = stateB.parseMaybeSemichannelBody();

    assert((seqnoB >= seqnoBRefA) &
        (seqnoA >= seqnoARefB) &
        (seqnoB >= ctxCommitedSeqnoB) &
        (seqnoA >= ctxCommitedSeqnoA) &
        (sentB >= sentBRefA) &
        (sentA >= sentARefB)) throw ERROR_OUTDATED_STATE;

    if (seqnoBRefA > 0) {
        assert((seqnoBRefA >= ctxCommitedSeqnoB)) throw ERROR_OUTDATED_STATE;
    }
    if (seqnoARefB > 0) {
        assert((seqnoARefB >= ctxCommitedSeqnoA)) throw ERROR_OUTDATED_STATE;
    }

    var storedStates: slice = ctxQuarantine.beginParse();
    var (storedSeqnoA: int, storedSentA: int) = (storedStates.loadUint(64), storedStates.loadCoins());
    var storedConditionalsHashA: int = storedStates.loadUint(256);

    var (storedSeqnoB: int, storedSentB: int) = (storedStates.loadUint(64), storedStates.loadCoins());
    var storedConditionalsHashB: int = storedStates.loadUint(256);

    var quarantineeStarted: int = storedStates.loadUint(32);
    assert(quarantineeStarted + ctxClosureConfigQuarantineDuration > now()) throw ERROR_TOO_LATE_FOR_QUARANTINE_CHALLENGE;

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
            storedSentA += ctxClosureConfigFine;
        } else {
            storedSentB += ctxClosureConfigFine;
        }
    }

    ctxQuarantine = beginCell()
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
    saveStorage();
}

@inline_ref
fun settleConditionals(msg: slice) {
    assert(ctxQuarantine != null) throw ERROR_NO_QUARANTINED_STATE;

    var fromA: int = msg.loadInt(1);
    var signature: slice = msg.loadBits(512);
    assert(isSignatureValid(sliceHash(msg), signature, fromA ? ctxKeyA : ctxKeyB)) throw ERROR_NOT_AUTHORIZED;
    assert(msg.loadUint(32) == TAG_SETTLE_CONDITIONALS) throw ERROR_WRONG_TAG;
    assert(ctxChannelId == msg.loadUint(128)) throw ERROR_WRONG_CHANNEL_ID;

    var conditionalsToSettle: cell = msg.loadDict();
    var conditionalsProof: cell = msg.loadRef();

    var storedStates: slice = ctxQuarantine.beginParse();
    var (seqnoA: int, sentA: int, conditionalsHashA: int) =
        (storedStates.loadUint(64), storedStates.loadCoins(), storedStates.loadUint(256));

    var (seqnoB: int, sentB: int, conditionalsHashB: int) =
        (storedStates.loadUint(64), storedStates.loadCoins(), storedStates.loadUint(256));

    var quarantineeStarted: int = storedStates.loadUint(32);
    var quarantineeFinished: int = quarantineeStarted + ctxClosureConfigQuarantineDuration;
    assert(quarantineeFinished < now()) throw ERROR_QUARANTINE_NOT_FINISHED;
    assert(quarantineeFinished + ctxClosureConfigCloseDuration > now()) throw ERROR_TOO_LATE_TO_SETTLE_CONDITIONALS;

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
        var (cid: int, input: slice, more redef) = conditionalsToSettle.uDictDeleteFirstAndGet(32);
        if (more) {
            var empty: slice = emptySlice();
            var (target redef, condition: slice, ok: int) = target.isUdictReplaceGet(32, cid, empty);
            assert(ok) throw ERROR_INCORRECT_CONDITIONALS_PROOF;
            var executableCondition = castToS2I(condition.transformSliceToContinuation());
            // NOTE! It seems dangerous to run unknown code and it really is!
            // However, runned code is signed by one party and executed by another
            // That way both party authorized it.
            // Obviously, B should not sign incorrect code which (for instance) sends all money to A
            // The same way A should not run incorrect code which sends all money to B.
            targetSent += executableCondition(input);
        }
    } while (more);

    if (fromA) {
        (conditionalsHashB, sentB) = (proofHash(target), targetSent);
    } else {
        (conditionalsHashA, sentA) = (proofHash(target), targetSent);
    }

    ctxQuarantine = beginCell()
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
    saveStorage();
}

@inline_ref
fun finishUncooperativeClose() {
    assert(ctxQuarantine != null) throw ERROR_NO_QUARANTINED_STATE;

    var storedStates: slice = ctxQuarantine.beginParse();
    var (seqnoA: int, sentA: int, _: int) =
        (storedStates.loadUint(64), storedStates.loadCoins(), storedStates.loadUint(256));
    var (seqnoB: int, sentB: int, _: int) =
        (storedStates.loadUint(64), storedStates.loadCoins(), storedStates.loadUint(256));

    var quarantineeStarted: int = storedStates.loadUint(32);
    assert(quarantineeStarted +
        ctxClosureConfigQuarantineDuration +
        ctxClosureConfigCloseDuration < now()) throw ERROR_TOO_EARLY_TO_CLOSE;

    ctxBalanceA = ctxBalanceA + sentB - sentA;
    ctxBalanceB = ctxBalanceB + sentA - sentB;
    if (ctxBalanceB < 0) {
        ctxBalanceA += ctxBalanceB;
        ctxBalanceB = 0;
    }
    if (ctxBalanceA < 0) {
        ctxBalanceB += ctxBalanceA;
        ctxBalanceB = 0;
    }

    ctxCommitedSeqnoA = seqnoA + 1;
    ctxCommitedSeqnoB = seqnoB + 1;
    closeChannel();
}

fun onInternalMessage(_: int, amount: int, inMsgFull: cell, inMsg: slice) {
    loadStorage();

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
        if (ctxCurrencyType == CURRENCY_TYPE_EC) {
            assert(amount >= FEE_EC_ACCEPT) throw ERROR_AMOUNT_NOT_COVERS_FEE;

            var ec: cell = cs.loadDict();
            var (v: slice, ok: bool) = ec.uDictGet(32, ctxECID);
            assert(ok) throw ERROR_INVALID_EC_ID;

            var ecAmount: int = v.loadVarUInt32();
            topUpBalance(ecAmount, inMsg);
        } else {
            assert(amount >= FEE_TON_ACCEPT) throw ERROR_AMOUNT_NOT_COVERS_FEE;

            topUpBalance(amount - FEE_TON_ACCEPT, inMsg);
        }
    } else if (op == OP_JETTON_TRANSFER_NOTIFICATION) {
        // return because custom excess handled inside
        return acceptJettons(sender, amount, inMsg);
    } else if (op == OP_JETTON_TAKE_WALLET_ADDRESS) {
        // no excess
        return assignJettonWallet(sender, inMsg);
    } else if (op == OP_COOPERATIVE_COMMIT) {
        cooperativeCommit(inMsg);
    } else if (op == OP_INIT_CHANNEL) {
        initChannel(inMsg);
    } else if (op == OP_COOPERATIVE_CLOSE) {
        // excess hadled in channelClose()
        return cooperativeClose(inMsg);
    } else if (op == OP_START_UNCOOPERATIVE_CLOSE) {
        startUncooperativeClose(inMsg);
    } else if (op == OP_CHALLENGE_QUARANTINEED_STATE) {
        challengeQuarantinedState(inMsg);
    } else if (op == OP_SETTLE_CONDITIONALS) {
        settleConditionals(inMsg);
    } else if (op == OP_FINISH_UNCOOPERATIVE_CLOSE) {
        // excess hadled in channelClose()
        return finishUncooperativeClose();
    } else {
        throw 0xffff;
    }

    sendExcess(sender);
}

@inline_ref
fun acceptJettons(sender: slice, tonAmount: int, payload: slice) {
    /* TEP-74
      transfer_notification#7362d09c query_id:uint64 amount:(VarUInteger 16)
                                     sender:MsgAddress forward_payload:(Either Cell ^Cell)
                                     = InternalMsgBody;
    */
    assert(ctxCurrencyType == CURRENCY_TYPE_JETTON) throw ERROR_INVALID_CURRENCY_TYPE;

    payload.skipBits(64);
    var jettonAmount: int = payload.loadCoins();

    var jettonSender: slice = payload.loadAddress();
    var eitherForwardPayload: bool = payload.loadBool();
    var forwardPayload: slice = eitherForwardPayload ? payload.loadRef().beginParse() : payload;

    if ((tonAmount < FEE_JETTON_ACCEPT) | (!isSliceBitsEqual(ctxJettonWallet, sender))) {
        return sendJettonsBack(jettonSender, jettonAmount, sender);
    }

    try {
        var innerOp: int = forwardPayload.loadInt(32);
        if (innerOp == OP_TOP_UP_BALANCE) {
            topUpBalance(jettonAmount, forwardPayload);
            return sendExcess(jettonSender);
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
            .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1 + 1)
                .storeMessageOp(OP_JETTON_TRANSFER)
                .storeMessageQueryId(0)
                .storeCoins(amount)
                .storeSlice(dest)
                .storeSlice(dest)
                .storeMaybeRef(null)
                .storeCoins(1)
                .storeBool(false)
            .endCell(),
        SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS
    );
}

@inline_ref
fun sendExcess(dest: slice) {
    var ecDict: cell = createEmptyDict();
    var reserve: int = ctxPaymentConfigStorageFee;
    if (ctxCurrencyType == CURRENCY_TYPE_TON) {
        reserve += ctxBalanceA + ctxBalanceB;
    } else if ((ctxCurrencyType == CURRENCY_TYPE_EC) & ((ctxBalanceA + ctxBalanceB) > 0)) {
        ecDict.uDictSetBuilder(32, ctxECID, beginCell().storeVarUInt32(ctxBalanceA + ctxBalanceB));
    }
    reserveExtraCurrenciesOnBalance(reserve, ecDict, 0);

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
fun assignJettonWallet(sender: slice, payload: slice) {
    /* TEP-89
      take_wallet_address#d1735400 query_id:uint64 wallet_address:MsgAddress
                                   owner_address:(Maybe ^MsgAddress)
                                   = InternalMsgBody;
    */
    payload.skipBits(64);

    assert(ctxJettonWallet.addressIsNone()) throw ERROR_JETTON_WALLET_ALREADY_INSTALLED;
    assert(isSliceBitsEqual(ctxJettonRoot, sender)) throw ERROR_NOT_AUTHORIZED;

    ctxJettonWallet = payload.loadAddress();

    ctxPaymentConfigRef = beginCell()
        .storeCoins(ctxPaymentConfigStorageFee)
        .storeSlice(ctxPaymentConfigAddressA)
        .storeSlice(ctxPaymentConfigAddressB)
        .storeUint(3, 2) // jetton type
        .storeRef(beginCell()
            .storeSlice(ctxJettonRoot)
            .storeSlice(ctxJettonWallet)
        .endCell())
    .endCell();

    saveStorage();
}

@inline_ref
fun requestJettonWallet() {
    /* TEP-89
      provide_wallet_address#2c76b973 query_id:uint64 owner_address:MsgAddress
                                      include_address:Bool
                                      = InternalMsgBody;
    */
    sendMessage(beginCell()
        .storeUint(NON_BOUNCEABLE, 6)
        .storeSlice(ctxJettonRoot)
        .storeCoins(FEE_JETTON_WALLET_PROVIDE)
        .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1 + 1)
        .storeMessageOp(OP_JETTON_PROVIDE_WALLET_ADDRESS)
        .storeMessageQueryId(0)
        .storeSlice(getMyAddress())
        .storeBool(false)
    .endCell(), 0);
    return;
}

get getChannelState(): int {
    loadStorage();

    if (!ctxInited) {
        return STATE_UNINITED;
    }
    if ((ctxQuarantine == null)) {
        return STATE_OPEN;
    }

    var storedStates: slice = ctxQuarantine.beginParse();
    storedStates.skipBits(64);
    storedStates.loadCoins();
    storedStates.skipBits(1 + 64);
    storedStates.loadCoins();
    storedStates.skipBits(1);

    var quarantineeStarted: int = storedStates.loadUint(32);
    if (quarantineeStarted + ctxClosureConfigQuarantineDuration > now()) {
        return STATE_CLOSURE_STARTED;
    }

    if (quarantineeStarted +
        ctxClosureConfigQuarantineDuration +
        ctxClosureConfigCloseDuration > now()) {
        return STATE_SETTLING_CONDITIONALS;
    }

    return STATE_AWAITING_FINALIZATION;
}

get getChannelData() {
    loadStorage();

    return (getChannelState(),
        [ctxBalanceA, ctxBalanceB, ctxDepositA, ctxDepositB, ctxWithdrawA, ctxWithdrawB],
        [ctxKeyA, ctxKeyB],
        ctxChannelId,
        ctxClosureConfigRef,
        [ctxCommitedSeqnoA, ctxCommitedSeqnoB],
        ctxQuarantine,
        [ctxPaymentConfigStorageFee, ctxPaymentConfigAddressA, ctxPaymentConfigAddressB]);
}
