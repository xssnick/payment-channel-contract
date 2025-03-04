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
  payment_conf#_  dest_A:MsgAddress
                  dest_B:MsgAddress
                  storage_fee:Coins = PaymentConfig;
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

global inited: bool;
global balanceA: int;
global balanceB: int;
global keyA: int;
global keyB: int;
global channelId: int;
global closureConfig: tuple;
global commitedSeqnoA: int;
global commitedSeqnoB: int;
global quarantine: cell;
global paymentConfig: cell;
global unparsedStorage: slice;
global storageParseLevel: int;

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
const OP_COOPERATIVE_COMMIT = "cooperative_commit sig_A:^bits512 sig_B:^bits512 tag:# = tag 1128492404 channel_id:uint128 seqno_A:uint64 seqno_B:uint64 = InternalMsgBody"c;
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
    closureConfig = tTriple(conf.loadUint(32), conf.loadCoins(), conf.loadUint(32));
    return;
}

@inline
fun closureConfigQuarantineDuration(): int {
    return closureConfig.tupleFirst();
}

@inline
fun closureConfigMisbehaviorFine(): int {
    return closureConfig.2;
}

@inline
fun closureConfigConditionalCloseDuration(): int {
    return closureConfig.3;
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
    storageParseLevel = level;
    var cs: slice = getContractData().beginParse();
    inited = cs.loadBool();
    balanceA = cs.loadCoins();
    balanceB = cs.loadCoins();
    keyA = cs.loadUint(256);
    keyB = cs.loadUint(256);
    channelId = cs.loadUint(128);
    cs.loadClosureConfig();
    if (level >= STORAGE_UP_TO_QUARANTINE) {
        commitedSeqnoA = cs.loadUint(32);
        commitedSeqnoB = cs.loadUint(32);
        quarantine = cs.loadMaybeRef();
    }
    if (level >= STORAGE_FULL) {
        paymentConfig = cs.loadRef();
    }
    unparsedStorage = cs;
}

fun saveStorage() {
    var level: int = storageParseLevel;
    var storage: builder = beginCell();
    storage = storage.storeBool(inited)
        .storeCoins(balanceA)
        .storeCoins(balanceB)
        .storeUint(keyA, 256)
        .storeUint(keyB, 256)
        .storeUint(channelId, 128)
        .storeClosureConfig();
    if (level >= STORAGE_UP_TO_QUARANTINE) {
        storage = storage.storeUint(commitedSeqnoA, 32)
            .storeUint(commitedSeqnoB, 32)
            .storeMaybeRef(quarantine);
    }
    if (level >= STORAGE_FULL) {
        storage = storage.storeRef(paymentConfig);
    } else {
        storage = storage.storeSlice(unparsedStorage);
    }
    setContractData(storage.endCell());
}

fun topUpBalance(amount: int, msg: slice) {
    loadStorage(STORAGE_FULL);
    assert(inited) throw ERROR_NOT_INITED;

    var isA: bool = msg.loadBool();
    if (isA) {
        assert(balanceA <= amount) throw ERROR_NOT_ENOUGH_MONEY_FOR_INIT;
        balanceA += msg.loadCoins();
    } else {
        assert(balanceB <= amount) throw ERROR_NOT_ENOUGH_MONEY_FOR_INIT;
        balanceB += msg.loadCoins();
    }

    return saveStorage();
}

fun initChannel(contractBalance: int, msg: slice) {
    loadStorage(STORAGE_FULL);
    assert(!inited) throw ERROR_ALREADY_INITED;

    var isA: int = msg.loadInt(1);
    var signature: slice = msg.loadBits(512);
    assert(isSignatureValid(sliceHash(msg), signature, isA ? keyA : keyB)) throw ERROR_NOT_AUTHORIZED;
    assert(msg.loadUint(32) == TAG_INIT) throw ERROR_WRONG_TAG;
    assert(channelId == msg.loadUint(128)) throw ERROR_WRONG_CHANNEL_ID;

    var setBalanceA: int = msg.loadCoins();
    var setBalanceB: int = msg.loadCoins();
    assert((setBalanceA >= balanceA) & (setBalanceB >= balanceB)) throw ERROR_NOT_ENOUGH_MONEY_FOR_INIT;

    balanceA = setBalanceA;
    balanceB = setBalanceB;

    var pcs: slice = paymentConfig.beginParse();
    pcs.loadAddress();
    pcs.loadAddress();
    var storageFee: int = pcs.loadCoins();
    assert(balanceA + balanceB + storageFee < contractBalance) throw ERROR_NOT_ENOUGH_MONEY_FOR_INIT;

    inited = true;
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
    var pcs: slice = paymentConfig.beginParse();
    var (addrA: slice, addrB: slice) = (pcs.loadAddress(), pcs.loadAddress());

    if (b > 0) {
        balanceB -= b;
        assert(balanceB >= 0, ERROR_NOT_ENOUGH_BALANCE);
        sendPayout(addrB, b, channelId, OP_CHANNEL_WITHDRAW, 2);
    }

    if (a > 0) {
        balanceA -= a;
        assert(balanceA >= 0, ERROR_NOT_ENOUGH_BALANCE);
        sendPayout(addrA, a, channelId, OP_CHANNEL_WITHDRAW, 2);
    }
}

fun closeChannel() {
    var pcs: slice = paymentConfig.beginParse();
    var (addrA: slice, addrB: slice) = (pcs.loadAddress(), pcs.loadAddress());
    var totalContractBalance: int = getMyOriginalBalance();
    var modeB: int = 2;  // in case balanceB less than forward fees
    if (balanceB > totalContractBalance) {
        modeB = 128;
    }
    sendPayout(addrB, balanceB, channelId, OP_CHANNEL_CLOSED, modeB);
    sendPayout(addrA, balanceA, channelId, OP_CHANNEL_CLOSED, 2 + 128);

    // while channel contract will be emptied it will survive for some time
    // by clearing storage we allow immediately reopen channel with the same configs
    inited = false;
    balanceA = 0;
    balanceB = 0;
    quarantine = null;
    saveStorage();
}

fun cooperativeClose(msg: slice) {
    loadStorage(STORAGE_FULL);

    var sigA: slice = msg.loadRef().beginParse();
    var sigB: slice = msg.loadRef().beginParse();

    var hash: int = sliceHash(msg);
    assert(msg.loadUint(32) == TAG_COOPERATIVE_CLOSE) throw ERROR_WRONG_TAG;
    assert(channelId == msg.loadUint(128)) throw ERROR_WRONG_CHANNEL_ID;
    assert(isSignatureValid(hash, sigA, keyA) &
        isSignatureValid(hash, sigB, keyB)) throw ERROR_NOT_AUTHORIZED;

    balanceA = msg.loadCoins();
    balanceB = msg.loadCoins();

    var newSeqnoA: int = msg.loadUint(64);
    var newSeqnoB: int = msg.loadUint(64);
    assert((commitedSeqnoA < newSeqnoA) &
        (commitedSeqnoB < newSeqnoB)) throw ERROR_SEQNO_REGRESS;

    commitedSeqnoA = newSeqnoA;
    commitedSeqnoB = newSeqnoB;

    acceptExternalMessage();
    closeChannel();
}

fun cooperativeCommit(msg: slice) {
    loadStorage(STORAGE_UP_TO_QUARANTINE);

    var sigA: slice = msg.loadRef().beginParse();
    var sigB: slice = msg.loadRef().beginParse();

    var hash: int = sliceHash(msg);
    assert(msg.loadUint(32) == TAG_COOPERATIVE_COMMIT) throw ERROR_WRONG_TAG;
    assert(channelId == msg.loadUint(128)) throw ERROR_WRONG_CHANNEL_ID;
    assert(isSignatureValid(hash, sigA, keyA) &
        isSignatureValid(hash, sigB, keyB)) throw ERROR_NOT_AUTHORIZED;

    var newSeqnoA: int = msg.loadUint(64);
    var newSeqnoB: int = msg.loadUint(64);
    assert((commitedSeqnoA < newSeqnoA) &
        (commitedSeqnoB < newSeqnoB)) throw ERROR_SEQNO_REGRESS;

    commitedSeqnoA = newSeqnoA;
    commitedSeqnoB = newSeqnoB;

    if (quarantine != null) {
        var storedStates: slice = quarantine.beginParse();
        var (storedSeqnoA: int, storedSentA: int) = (storedStates.loadUint(64), storedStates.loadCoins());
        storedStates.skipBits(1);
        var (storedSeqnoB: int, storedSentB: int) = (storedStates.loadUint(64), storedStates.loadCoins());
        if ((newSeqnoA > storedSeqnoA) | (newSeqnoB > storedSeqnoB)) {
            // quarantinened state is older than newly commited one, drop it
            quarantine = null;
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
    assert(channelId == self.loadUint(128)) throw ERROR_WRONG_CHANNEL_ID;
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

    assert(quarantine == null) throw ERROR_QUARANTINE_ALREADY_ACTIVE;
    var signedByA: int = msg.loadInt(1);
    var signature: slice = msg.loadBits(512);
    assert(isSignatureValid(sliceHash(msg), signature, signedByA ? keyA : keyB)) throw ERROR_NOT_AUTHORIZED;
    assert(msg.loadUint(32) == TAG_START_UNCOOPERATIVE_CLOSE) throw ERROR_WRONG_TAG;
    assert(channelId == msg.loadUint(128)) throw ERROR_WRONG_CHANNEL_ID;

    var semiChannelA: slice = msg.loadRef().beginParse();
    var signatureA: slice = semiChannelA.loadBits(512);
    var semiChannelStateA: cell = semiChannelA.preloadRef();
    assert(isSignatureValid(cellHash(semiChannelStateA), signatureA, keyA)) throw ERROR_NOT_AUTHORIZED;
    var stateA: slice = semiChannelStateA.beginParse();

    var semiChannelB: slice = msg.loadRef().beginParse();
    var signatureB: slice = semiChannelB.loadBits(512);
    var semiChannelStateB: cell = semiChannelB.preloadRef();
    assert(isSignatureValid(cellHash(semiChannelStateB), signatureB, keyB)) throw ERROR_NOT_AUTHORIZED;
    var stateB: slice = semiChannelStateB.beginParse();

    var (seqnoA: int, sentA: int, conditionalsHashA: int) = stateA.parseSemichannelData();
    var (seqnoBRefA: int, sentBRefA: int, _) = stateA.parseMaybeSemichannelBody();

    var (seqnoB: int, sentB: int, conditionalsHashB: int) = stateB.parseSemichannelData();
    var (seqnoARefB: int, sentARefB: int, _) = stateB.parseMaybeSemichannelBody();

    assert((seqnoA >= commitedSeqnoA) &
        (seqnoB >= commitedSeqnoB) &
        (seqnoB >= seqnoBRefA) &
        (seqnoA >= seqnoARefB) &
        (sentB >= sentBRefA) &
        (sentA >= sentARefB)) throw ERROR_OUTDATED_STATE;

    quarantine = beginCell()
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
    assert(quarantine != null) throw ERROR_NO_QUARANTINED_STATE;

    // Start with the same checks
    var challengedByA: int = msg.loadInt(1);
    var signature: slice = msg.loadBits(512);
    assert(isSignatureValid(sliceHash(msg), signature, challengedByA ? keyA : keyB)) throw ERROR_NOT_AUTHORIZED;
    assert(msg.loadUint(32) == TAG_CHALLENGE_STATE) throw ERROR_WRONG_TAG;
    assert(channelId == msg.loadUint(128)) throw ERROR_WRONG_CHANNEL_ID;

    var semiChannelA: slice = msg.loadRef().beginParse();
    var signatureA: slice = semiChannelA.loadBits(512);
    var semiChannelStateA: cell = semiChannelA.preloadRef();
    assert(isSignatureValid(cellHash(semiChannelStateA), signatureA, keyA)) throw ERROR_NOT_AUTHORIZED;
    var stateA: slice = semiChannelStateA.beginParse();

    var semiChannelB: slice = msg.loadRef().beginParse();
    var signatureB: slice = semiChannelB.loadBits(512);
    var semiChannelStateB: cell = semiChannelB.preloadRef();
    assert(isSignatureValid(cellHash(semiChannelStateB), signatureB, keyB)) throw ERROR_NOT_AUTHORIZED;
    var stateB: slice = semiChannelStateB.beginParse();

    var (seqnoA: int, sentA: int, conditionalsHashA: int) = stateA.parseSemichannelData();
    var (seqnoBRefA: int, sentBRefA: int, _) = stateA.parseMaybeSemichannelBody();

    var (seqnoB: int, sentB: int, conditionalsHashB: int) = stateB.parseSemichannelData();
    var (seqnoARefB: int, sentARefB: int, _) = stateB.parseMaybeSemichannelBody();

    assert((seqnoB >= seqnoBRefA) &
        (seqnoA >= seqnoARefB) &
        (seqnoB >= commitedSeqnoB) &
        (seqnoA >= commitedSeqnoA) &
        (sentB >= sentBRefA) &
        (sentA >= sentARefB)) throw ERROR_OUTDATED_STATE;

    if (seqnoBRefA > 0) {
        assert((seqnoBRefA >= commitedSeqnoB)) throw ERROR_OUTDATED_STATE;
    }
    if (seqnoARefB > 0) {
        assert((seqnoARefB >= commitedSeqnoA)) throw ERROR_OUTDATED_STATE;
    }

    var storedStates: slice = quarantine.beginParse();
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

    quarantine = beginCell()
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

    assert(quarantine != null) throw ERROR_NO_QUARANTINED_STATE;

    var fromA: int = msg.loadInt(1);
    var signature: slice = msg.loadBits(512);
    assert(isSignatureValid(sliceHash(msg), signature, fromA ? keyA : keyB)) throw ERROR_NOT_AUTHORIZED;
    assert(msg.loadUint(32) == TAG_SETTLE_CONDITIONALS) throw ERROR_WRONG_TAG;
    assert(channelId == msg.loadUint(128)) throw ERROR_WRONG_CHANNEL_ID;

    var conditionalsToSettle: cell = msg.loadDict();
    var conditionalsProof: cell = msg.loadRef();

    var storedStates: slice = quarantine.beginParse();
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

    quarantine = beginCell()
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

    assert(quarantine != null) throw ERROR_NO_QUARANTINED_STATE;

    var storedStates: slice = quarantine.beginParse();
    var (seqnoA: int, sentA: int, conditionalsHashA: int) =
    (storedStates.loadUint(64), storedStates.loadCoins(), storedStates.loadUint(256));
    var (seqnoB: int, sentB: int, conditionalsHashB: int) =
    (storedStates.loadUint(64), storedStates.loadCoins(), storedStates.loadUint(256));

    var quarantineeStarted: int = storedStates.loadUint(32);
    assert(quarantineeStarted +
    closureConfigQuarantineDuration() +
    closureConfigConditionalCloseDuration() < now()) throw ERROR_TOO_EARLY_TO_CLOSE;

    acceptExternalMessage();

    balanceA = balanceA + sentB - sentA;
    balanceB = balanceB + sentA - sentB;
    if (balanceB < 0) {
        balanceA += balanceB;
        balanceB = 0;
    }
    if (balanceA < 0) {
        balanceB += balanceA;
        balanceB = 0;
    }

    commitedSeqnoA = seqnoA + 1;
    commitedSeqnoB = seqnoB + 1;
    closeChannel();
}

fun recvAny(contractBalance: int, msg: slice) {
    // Note, operators of channels are always off-chain parties, not contracts
    // thus no responses and query_ids
    var op: int = msg.loadUint(32);
    if (op == OP_TOP_UP_BALANCE) {
        return topUpBalance(contractBalance, msg);
    } else if (op == OP_INIT_CHANNEL) {
        return initChannel(contractBalance, msg);
    } else if (op == OP_COOPERATIVE_CLOSE) {
        return cooperativeClose(msg);
    } else if (op == OP_COOPERATIVE_COMMIT) {
        return cooperativeCommit(msg);
    } else if (op == OP_START_UNCOOPERATIVE_CLOSE) {
        return startUncooperativeClose(msg);
    } else if (op == OP_CHALLENGE_QUARANTINEED_STATE) {
        return challengeQuarantinedState(msg);
    } else if (op == OP_SETTLE_CONDITIONALS) {
        return settleConditionals(msg);
    } else if (op == OP_FINISH_UNCOOPERATIVE_CLOSE) {
        return finishUncooperativeClose();
    }
    throw 0xffff;
}

fun onInternalMessage(contractBalance: int, _: int, _: cell, inMsg: slice) {
    return recvAny(contractBalance, inMsg);
}

fun onExternalMessage(contractBalance: int, _: int, _: cell, inMsg: slice) {
    // Note, only cooperative_close and cooperative_commit
    // will be accepted
    return recvAny(contractBalance, inMsg);
}

get getChannelState(): int {
    loadStorage(STORAGE_FULL);

    if (!inited) {
        return STATE_UNINITED;
    }
    if ((quarantine == null)) {
        return STATE_OPEN;
    }

    var storedStates: slice = quarantine.beginParse();
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

    var pcs: slice = paymentConfig.beginParse();
    var (addrA: slice, addrB: slice) = (pcs.loadAddress(), pcs.loadAddress());
    var storageFee: int = pcs.loadCoins();

    return (getChannelState(),
        [balanceA, balanceB],
        [keyA, keyB],
        channelId,
        closureConfig,
        [commitedSeqnoA, commitedSeqnoB],
        quarantine,
        [storageFee, addrA, addrB]);
}
