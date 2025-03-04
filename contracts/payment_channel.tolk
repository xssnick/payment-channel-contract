import "@stdlib/gas-payments"
import "@stdlib/tvm-dicts"
import "@stdlib/tvm-lowlevel"

/*
  cp#_ amount:Coins condition:Cell = ConditionalPayment;
  sc_body#_ seqno:uint64 sent:Coins conditionals_hash:uint256     ;;:(HashmapE 32 ConditionalPayment)
            = SemiChannelBody; // 64+132+256 = 452
  semichannel_state#43685374 channel_id:uint128 data:SemiChannelBody counterparty_data:(Maybe ^SemiChannelBody)
                        = SemiChannel; // 32 + 128 + 452 + 1 = 613
  signed_schs#_ signature:bits512 state:^SemiChannel = SignedSemiChannel; // 512 = 512
  quarantined_state#_ state_A:^SemiChannelBody state_B:^SemiChannelBody
                     quarantine_starts:uint32
                     state_commited_by_A:Bool
                     state_challenged:Bool
                     = QuarantinedState; // 32 + 1 + 1 = 34
  conf#_ quarantin_duration:uint32
         misbehavior_fine:Coins
         conditional_close_duration:uint32 = ClosingConfig; // 32 + 132 + 32 = 196
  payment_conf#_  storage_fee:Coins
                  dest_A:MsgAddress
                  dest_B:MsgAddress = PaymentConfig;
  channel_state#_ inited:Bool
                  balance_A:Coins balance_B:Coins
                  key_A:uint256 key_B:uint256
                  channel_id:uint128
                  config:^ClosingConfig
                  commited_seqno_A:uint32 commited_seqno_B:uint32
                  quarantin:(Maybe ^QuarantinedState)
                  payments:^PaymentConfig = Storage;
                  // 1 + 132 + 132 + 256 + 256 + 128 + 32 + 32 + 1 = 970
*/

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
fun tTriple<X, Y, Z>(x: X, y: Y, z: Z): tuple
asm "TRIPLE";

@pure
fun emptySlice(): slice
asm "b{} PUSHSLICE";

@pure
fun proofHash(c: cell): int
asm "0 CHASHI";

global ctxInited: bool;
global ctxBalanceA: int;
global ctxBalanceB: int;
global ctxKeyA: int;
global ctxKeyB: int;
global ctxChannelId: int;
global ctxClosureConfig: tuple;
global ctxCommitedSeqnoA: int;
global ctxCommitedSeqnoB: int;
global ctxQuarantine: cell;

global ctxPaymentConfigRef: cell;
global ctxPaymentConfigAddressA: slice;
global ctxPaymentConfigAddressB: slice;
global ctxPaymentConfigStorageFee: int;

global ctxUnparsedStorage: slice;
global ctxStorageParseLevel: int;

const ERROR_ALREADY_INITED = 100;
const ERROR_NOT_AUTHORIZED = 101;
const ERROR_NOT_ENOUGH_MONEY_FOR_INIT = 102;
const ERROR_WRONG_TAG = 104;
const ERROR_OUTDATED_STATE = 105;
const ERROR_QUARANTINE_ALREADY_ACTIVE = 106;
const ERROR_NO_QUARANTINED_STATE = 107;
const ERROR_SEQNO_REGRESS = 108;
const ERROR_QUARANTINEE_ALREADY_CHALLENGED = 115;
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

const TAG_INIT = 0x696e6974;
const TAG_COOPERATIVE_CLOSE = 0x436c6f73;
const TAG_COOPERATIVE_COMMIT = 0x43436d74;
const TAG_START_UNCOOPERATIVE_CLOSE = 0x556e436c;
const TAG_CHALLENGE_STATE = 0x43686751;
const TAG_SETTLE_CONDITIONALS = 0x436c436e;
const TAG_STATE = 0x43685374;

const STORAGE_FULL = 4;
const STORAGE_UP_TO_QUARANTINE = 3;
const STORAGE_UP_TO_CLOSURE_CONFIG = 1;
const STORAGE_BALANCES_AND_KEYS = 0;

const OP_TOP_UP_BALANCE = "top_up_balance add_A:Coins add_B:Coins = InternalMsgBody"c;
const OP_INIT_CHANNEL = "init_channel is_A:Bool signature:bits512 tag:# = tag 1768843636 channel_id:uint128 balance_A:Coins balance_B:Coins = InternalMsgBody"c;
const OP_COOPERATIVE_CLOSE = "cooperative_close sig_A:^bits512 sig_B:^bits512 tag:# = tag 1131179891 channel_id:uint128 balance_A:Coins balance_B:Coins seqno_A:uint64 seqno_B:uint64 = InternalMsgBody"c;
const OP_COOPERATIVE_COMMIT = "cooperative_commit sig_A:^bits512 sig_B:^bits512 tag:# = tag 1128492404 channel_id:uint128 seqno_A:uint64 seqno_B:uint64 withdraw_A:Coins withdraw_B:Coins = InternalMsgBody"c;
const OP_START_UNCOOPERATIVE_CLOSE = "start_uncooperative_close signed_by_A:Bool signature:bits512 tag:# = tag 1433289580 channel_id:uint128 sch_A:^SignedSemiChannel sch_B:^SignedSemiChannel = InternalMsgBody"c;
const OP_CHALLENGE_QUARANTINEED_STATE = "challenge_QUARANTINEed_state challenged_by_A:Bool signature:bits512 tag:# = tag 1130915665 channel_id:uint128 sch_A:^SignedSemiChannel sch_B:^SignedSemiChannel = InternalMsgBody"c;
const OP_SETTLE_CONDITIONALS = "settle_conditionals from_A:Bool signature:bits512 tag:# = tag 1131168622 channel_id:uint128 conditionals_to_settle:HashmapE 32 Cell = InternalMsgBody"c;
const OP_FINISH_UNCOOPERATIVE_CLOSE = "finish_uncooperative_close = InternalMsgBody"c;
const OP_CHANNEL_CLOSED = "channel_closed channel_id:uint128 = InternalMsgBody"c;
const OP_CHANNEL_WITHDRAW = "channel_withdraw channel_id:uint128 = InternalMsgBody"c;

const STATE_UNINITED = 0;
const STATE_OPEN = 1;
const STATE_CLOSURE_STARTED = 2;
const STATE_SETTLING_CONDITIONALS = 3;
const STATE_AWAITING_FINALIZATION = 4;

fun loadClosureConfig(mutate self: slice): void {
    var conf: slice = self.loadRef().beginParse();
    ctxClosureConfig = tTriple(conf.loadUint(32), conf.loadCoins(), conf.loadUint(32));
    return;
}

@inline
fun closureConfigQuarantineDuration(): int {
    return ctxClosureConfig.1;
}

@inline
fun closureConfigMisbehaviorFine(): int {
    return ctxClosureConfig.2;
}

@inline
fun closureConfigConditionalCloseDuration(): int {
    return ctxClosureConfig.3;
}

fun storeClosureConfig(b: builder): builder {
    return b.storeRef(
        beginCell()
            .storeUint(closureConfigQuarantineDuration(), 32)
            .storeCoins(closureConfigMisbehaviorFine())
            .storeUint(closureConfigConditionalCloseDuration(), 32)
            .endCell()
    );
}

fun loadStorage(level: int) {
    ctxStorageParseLevel = level;
    var cs: slice = getContractData().beginParse();
    ctxInited = cs.loadBool();
    ctxBalanceA = cs.loadCoins();
    ctxBalanceB = cs.loadCoins();
    ctxKeyA = cs.loadUint(256);
    ctxKeyB = cs.loadUint(256);
    ctxChannelId = cs.loadUint(128);
    cs.loadClosureConfig();
    if (level >= STORAGE_UP_TO_QUARANTINE) {
        ctxCommitedSeqnoA = cs.loadUint(32);
        ctxCommitedSeqnoB = cs.loadUint(32);
        ctxQuarantine = cs.loadMaybeRef();
    }
    if (level >= STORAGE_FULL) {
        ctxPaymentConfigRef = cs.loadRef();
        var pcs: slice = ctxPaymentConfigRef.beginParse();
        ctxPaymentConfigStorageFee = pcs.loadCoins();
        ctxPaymentConfigAddressA = pcs.loadAddress();
        ctxPaymentConfigAddressB = pcs.loadAddress();
    }
    ctxUnparsedStorage = cs;
}

fun saveStorage() {
    var level: int = ctxStorageParseLevel;
    var storage: builder = beginCell();
    storage = storage.storeBool(ctxInited)
        .storeCoins(ctxBalanceA)
        .storeCoins(ctxBalanceB)
        .storeUint(ctxKeyA, 256)
        .storeUint(ctxKeyB, 256)
        .storeUint(ctxChannelId, 128)
        .storeClosureConfig();
    if (level >= STORAGE_UP_TO_QUARANTINE) {
        storage = storage.storeUint(ctxCommitedSeqnoA, 32)
            .storeUint(ctxCommitedSeqnoB, 32)
            .storeMaybeRef(ctxQuarantine);
    }
    if (level >= STORAGE_FULL) {
        storage = storage.storeRef(ctxPaymentConfigRef);
    } else {
        storage = storage.storeSlice(ctxUnparsedStorage);
    }
    setContractData(storage.endCell());
}

fun topUpBalance(amount: int, msg: slice) {
    loadStorage(STORAGE_FULL);
    assert(ctxInited) throw ERROR_NOT_INITED;

    var isA: bool = msg.loadBool();
    if (isA) {
        assert(ctxBalanceA <= amount) throw ERROR_NOT_ENOUGH_MONEY_FOR_INIT;
        ctxBalanceA += msg.loadCoins();
    } else {
        assert(ctxBalanceB <= amount) throw ERROR_NOT_ENOUGH_MONEY_FOR_INIT;
        ctxBalanceB += msg.loadCoins();
    }

    return saveStorage();
}

fun initChannel(contractBalance: int, msg: slice) {
    loadStorage(STORAGE_FULL);
    assert(!ctxInited) throw ERROR_ALREADY_INITED;

    var isA: int = msg.loadInt(1);
    var signature: slice = msg.loadBits(512);
    assert(isSignatureValid(sliceHash(msg), signature, isA ? ctxKeyA : ctxKeyB)) throw ERROR_NOT_AUTHORIZED;
    assert(msg.loadUint(32) == TAG_INIT) throw ERROR_WRONG_TAG;
    assert(ctxChannelId == msg.loadUint(128)) throw ERROR_WRONG_CHANNEL_ID;

    var setBalanceA: int = msg.loadCoins();
    var setBalanceB: int = msg.loadCoins();
    assert((setBalanceA >= ctxBalanceA) & (setBalanceB >= ctxBalanceB)) throw ERROR_NOT_ENOUGH_MONEY_FOR_INIT;

    ctxBalanceA = setBalanceA;
    ctxBalanceB = setBalanceB;

    assert(ctxBalanceA + ctxBalanceB + ctxPaymentConfigStorageFee < contractBalance) throw ERROR_NOT_ENOUGH_MONEY_FOR_INIT;

    ctxInited = true;
    return saveStorage();
}

fun sendPayout(sAddr: slice, amount: int, channelId: int, op: int, flags: int) {
    sendMessage(
        beginCell()
            .storeUint(0x10, 6)                  // 0x10 = 0b010000 = {0, 1, 0, 0, 00}
            .storeSlice(sAddr)                   // destination address
            .storeCoins(amount)                  // stake value
            .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1 + 1)   // no extra currency collection
            .storeUint(op, 32)                   // operation type
            .storeUint(channelId, 128)           // channel ID
            .endCell(),
        flags
    );
}

fun withdraw(a: int, b: int) {
    if (b > 0) {
        ctxBalanceB -= b;
        assert(ctxBalanceB >= 0, ERROR_NOT_ENOUGH_BALANCE);
        sendPayout(ctxPaymentConfigAddressB, b, ctxChannelId, OP_CHANNEL_WITHDRAW, 2);
    }

    if (a > 0) {
        ctxBalanceA -= a;
        assert(ctxBalanceA >= 0, ERROR_NOT_ENOUGH_BALANCE);
        sendPayout(ctxPaymentConfigAddressA, a, ctxChannelId, OP_CHANNEL_WITHDRAW, 2);
    }
}

fun closeChannel() {
    var totalContractBalance: int = getMyOriginalBalance();
    var modeB: int = 2;  // in case balanceB less than forward fees
    if (ctxBalanceB > totalContractBalance) {
        modeB = 128;
    }
    sendPayout(ctxPaymentConfigAddressB, ctxBalanceB, ctxChannelId, OP_CHANNEL_CLOSED, modeB);
    sendPayout(ctxPaymentConfigAddressA, ctxBalanceA, ctxChannelId, OP_CHANNEL_CLOSED, 2 + 128);

    // while channel contract will be emptied it will survive for some time
    // by clearing storage we allow immediately reopen channel with the same configs
    ctxInited = false;
    ctxBalanceA = 0;
    ctxBalanceB = 0;
    ctxQuarantine = null;
    saveStorage();
}

fun cooperativeClose(msg: slice) {
    loadStorage(STORAGE_FULL);

    var sigA: slice = msg.loadRef().beginParse();
    var sigB: slice = msg.loadRef().beginParse();

    var hash: int = sliceHash(msg);
    assert(msg.loadUint(32) == TAG_COOPERATIVE_CLOSE) throw ERROR_WRONG_TAG;
    assert(ctxChannelId == msg.loadUint(128)) throw ERROR_WRONG_CHANNEL_ID;
    assert(isSignatureValid(hash, sigA, ctxKeyA) &
        isSignatureValid(hash, sigB, ctxKeyB)) throw ERROR_NOT_AUTHORIZED;

    ctxBalanceA = msg.loadCoins();
    ctxBalanceB = msg.loadCoins();

    var newSeqnoA: int = msg.loadUint(64);
    var newSeqnoB: int = msg.loadUint(64);
    assert((ctxCommitedSeqnoA < newSeqnoA) &
        (ctxCommitedSeqnoB < newSeqnoB)) throw ERROR_SEQNO_REGRESS;

    ctxCommitedSeqnoA = newSeqnoA;
    ctxCommitedSeqnoB = newSeqnoB;

    acceptExternalMessage();
    closeChannel();
}

fun cooperativeCommit(msg: slice) {
    loadStorage(STORAGE_UP_TO_QUARANTINE);

    var sigA: slice = msg.loadRef().beginParse();
    var sigB: slice = msg.loadRef().beginParse();

    var hash: int = sliceHash(msg);
    assert(msg.loadUint(32) == TAG_COOPERATIVE_COMMIT) throw ERROR_WRONG_TAG;
    assert(ctxChannelId == msg.loadUint(128)) throw ERROR_WRONG_CHANNEL_ID;
    assert(isSignatureValid(hash, sigA, ctxKeyA) &
        isSignatureValid(hash, sigB, ctxKeyB)) throw ERROR_NOT_AUTHORIZED;

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

    acceptExternalMessage();

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

fun startUncooperativeClose(msg: slice) {
    loadStorage(STORAGE_UP_TO_QUARANTINE);

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

    acceptExternalMessage();
    saveStorage();
}

fun challengeQuarantinedState(msg: slice) {
    loadStorage(STORAGE_UP_TO_QUARANTINE);
    assert(ctxQuarantine != null) throw ERROR_NO_QUARANTINED_STATE;

    // Start with the same checks
    var challengedByA: int = msg.loadInt(1);
    var signature: slice = msg.loadBits(512);
    assert(isSignatureValid(sliceHash(msg), signature, challengedByA ? ctxKeyA : ctxKeyB)) throw ERROR_NOT_AUTHORIZED;
    assert(msg.loadUint(32) == TAG_CHALLENGE_STATE) throw ERROR_WRONG_TAG;
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
    assert(quarantineeStarted + closureConfigQuarantineDuration() > now()) throw ERROR_TOO_LATE_FOR_QUARANTINE_CHALLENGE;

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
            storedSentA += closureConfigMisbehaviorFine();
        } else {
            storedSentB += closureConfigMisbehaviorFine();
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

fun settleConditionals(msg: slice) {
    loadStorage(STORAGE_UP_TO_QUARANTINE);

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
    var quarantineeFinished: int = quarantineeStarted + closureConfigQuarantineDuration();
    assert(quarantineeFinished < now()) throw ERROR_QUARANTINE_NOT_FINISHED;
    assert(quarantineeFinished + closureConfigConditionalCloseDuration() > now()) throw ERROR_TOO_LATE_TO_SETTLE_CONDITIONALS;

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

fun finishUncooperativeClose() {
    loadStorage(STORAGE_FULL);

    assert(ctxQuarantine != null) throw ERROR_NO_QUARANTINED_STATE;

    var storedStates: slice = ctxQuarantine.beginParse();
    var (seqnoA: int, sentA: int, _: int) =
        (storedStates.loadUint(64), storedStates.loadCoins(), storedStates.loadUint(256));
    var (seqnoB: int, sentB: int, _: int) =
        (storedStates.loadUint(64), storedStates.loadCoins(), storedStates.loadUint(256));

    var quarantineeStarted: int = storedStates.loadUint(32);
    assert(quarantineeStarted +
        closureConfigQuarantineDuration() +
        closureConfigConditionalCloseDuration() < now()) throw ERROR_TOO_EARLY_TO_CLOSE;

    acceptExternalMessage();

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

fun onInternalMessage(contractBalance: int, amount: int, _: cell, inMsg: slice) {
    // Note, operators of channels are always off-chain parties, not contracts
    // thus no responses and query_ids
    var op: int = inMsg.loadUint(32);
    if (op == OP_TOP_UP_BALANCE) {
        return topUpBalance(amount, inMsg);
    } else if (op == OP_COOPERATIVE_COMMIT) {
        return cooperativeCommit(inMsg);
    } else if (op == OP_INIT_CHANNEL) {
        return initChannel(contractBalance, inMsg);
    } else if (op == OP_COOPERATIVE_CLOSE) {
        return cooperativeClose(inMsg);
    } else if (op == OP_START_UNCOOPERATIVE_CLOSE) {
        return startUncooperativeClose(inMsg);
    } else if (op == OP_CHALLENGE_QUARANTINEED_STATE) {
        return challengeQuarantinedState(inMsg);
    } else if (op == OP_SETTLE_CONDITIONALS) {
        return settleConditionals(inMsg);
    } else if (op == OP_FINISH_UNCOOPERATIVE_CLOSE) {
        return finishUncooperativeClose();
    }
    throw 0xffff;
}

fun onExternalMessage(_: int, _: int, _: cell, inMsg: slice) {
    // Note, only cooperative_close and cooperative_commit
    // will be accepted
    var op: int = inMsg.loadUint(32);
    if (op == OP_COOPERATIVE_CLOSE) {
        return cooperativeClose(inMsg);
    } else if (op == OP_COOPERATIVE_COMMIT) {
        return cooperativeCommit(inMsg);
    }
    throw 0xffff;
}

get getChannelState(): int {
    loadStorage(STORAGE_FULL);

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
    if (quarantineeStarted + closureConfigQuarantineDuration() > now()) {
        return STATE_CLOSURE_STARTED;
    }

    if (quarantineeStarted +
    closureConfigQuarantineDuration() +
    closureConfigConditionalCloseDuration() > now()) {
        return STATE_SETTLING_CONDITIONALS;
    }

    return STATE_AWAITING_FINALIZATION;
}

get getChannelData() {
    loadStorage(STORAGE_FULL);

    return (getChannelState(),
        [ctxBalanceA, ctxBalanceB],
        [ctxKeyA, ctxKeyB],
        ctxChannelId,
        ctxClosureConfig,
        [ctxCommitedSeqnoA, ctxCommitedSeqnoB],
        ctxQuarantine,
        [ctxPaymentConfigStorageFee, ctxPaymentConfigAddressA, ctxPaymentConfigAddressB]);
}
