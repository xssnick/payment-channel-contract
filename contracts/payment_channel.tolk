import "@stdlib/common.tolk"
import "@stdlib/gas-payments"
import "@stdlib/tvm-dicts"
import "@stdlib/tvm-lowlevel"
import "types.tolk"

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
    channel.verifyMessageType(mutate msg, TAG_INIT_CHANNEL);

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

    channel.verifyMessageType(mutate msg, TAG_COOPERATIVE_CLOSE);

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

    channel.verifyMessageType(mutate msg, TAG_COOPERATIVE_COMMIT);

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
        var qua = Quarantine.parse(channel.quarantine);
        if ((newSeqnoA > qua.stateA.seqno) | (newSeqnoB > qua.stateB.seqno)) {
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

@inline_ref
fun startUncooperativeClose(channel: Channel, msg: slice) {
    assert(channel.quarantine == null) throw ERROR_QUARANTINE_ALREADY_ACTIVE;
    var signedByA: bool = msg.loadBool();
    var signature: slice = msg.loadBits(512);
    assert(isSignatureValid(msg.hash(), signature, signedByA ? channel.keyA : channel.keyB)) throw ERROR_NOT_AUTHORIZED;

    channel.verifyMessageType(mutate msg, TAG_START_UNCOOPERATIVE_CLOSE);

    var a = Semichannel.parse(msg.loadRef(), channel.id, channel.keyA);
    var b = Semichannel.parse(msg.loadRef(), channel.id, channel.keyB);

    channel.verifyStates(a, b);

    var qua = Quarantine{
        stateA: a.data,
        stateB: b.data,
        startedAt: blockchain.now(),
        committedbyA: signedByA,
        challenged: false,
    };

    channel.quarantine = qua.serialize();
    return contract.setData(channel.serialize());
}

@inline_ref
fun challengeQuarantinedState(channel: Channel, msg: slice) {
    assert(channel.quarantine != null) throw ERROR_NO_QUARANTINED_STATE;

    // Start with the same checks
    var challengedByA: bool = msg.loadBool();
    var signature: slice = msg.loadBits(512);
    assert(isSignatureValid(msg.hash(), signature, challengedByA ? channel.keyA : channel.keyB)) throw ERROR_NOT_AUTHORIZED;

    channel.verifyMessageType(mutate msg, TAG_CHALLENGE_QUARANTINEED_STATE);

    var a = Semichannel.parse(msg.loadRef(), channel.id, channel.keyA);
    var b = Semichannel.parse(msg.loadRef(), channel.id, channel.keyB);

    channel.verifyStates(a, b);

    var qua = Quarantine.parse(channel.quarantine);

    assert(qua.startedAt + channel.closureConfig.quarantineDuration > blockchain.now()) throw ERROR_TOO_LATE_FOR_QUARANTINE_CHALLENGE;
    assert(!qua.challenged) throw ERROR_QUARANTINEE_ALREADY_CHALLENGED;

    // misbehvaior is when party which committed outdated state
    // or regenerate latest state with lower sent
    var misbehaviorDetected: bool = false;
    if (qua.committedbyA) {
        misbehaviorDetected = (a.data.seqno > qua.stateA.seqno) | (a.data.sent > qua.stateA.sent);
        qua.stateA = a.data;
    } else {
        misbehaviorDetected = (b.data.seqno > qua.stateB.seqno) | (b.data.sent > qua.stateB.sent);
        qua.stateB = b.data;
    }
    // only counterparty can report misbehavior
    assert(qua.committedbyA != challengedByA) throw ERROR_UNAUTHORIZED_CHALLENGE;

    if (misbehaviorDetected) {
        if (qua.committedbyA) {
            qua.stateA.sent += channel.closureConfig.fine;
        } else {
            qua.stateB.sent += channel.closureConfig.fine;
        }
    }

    qua.challenged = true;
    qua.committedbyA = challengedByA;
    channel.quarantine = qua.serialize();

    return contract.setData(channel.serialize());
}

@inline_ref
fun settleConditionals(channel: Channel, msg: slice) {
    assert(channel.quarantine != null) throw ERROR_NO_QUARANTINED_STATE;

    var fromA: int = msg.loadInt(1);
    var signature: slice = msg.loadBits(512);
    assert(isSignatureValid(msg.hash(), signature, fromA ? channel.keyA : channel.keyB)) throw ERROR_NOT_AUTHORIZED;

    channel.verifyMessageType(mutate msg, TAG_SETTLE_CONDITIONALS);

    var conditionalsToSettle: dict = msg.loadDict();
    var conditionalsProof: cell = msg.loadRef();

    var qua = Quarantine.parse(channel.quarantine);

    var quarantineeFinished: int = qua.startedAt + channel.closureConfig.quarantineDuration;
    assert(quarantineeFinished < blockchain.now()) throw ERROR_QUARANTINE_NOT_FINISHED;
    assert(quarantineeFinished + channel.closureConfig.closeDuration > blockchain.now()) throw ERROR_TOO_LATE_TO_SETTLE_CONDITIONALS;

    var targetState = fromA ? qua.stateB : qua.stateA;

    var (csProof: slice, special: int) = conditionalsProof.beginParseSpecial();
    assert(special) throw ERROR_INCORRECT_CONDITIONALS_PROOF;
    assert(csProof.loadUint(8) == 3) throw ERROR_INCORRECT_CONDITIONALS_PROOF;
    assert(csProof.preloadUint(256) == targetState.conditionalsHash) throw ERROR_INCORRECT_CONDITIONALS_PROOF;

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
            targetState.sent += executableCondition(input!);
        }
    } while (more);

    targetState.conditionalsHash = proofHash(target);
    if (fromA) {
        qua.stateB = targetState;
    } else {
        qua.stateA = targetState;
    }

    channel.quarantine = qua.serialize();
    return contract.setData(channel.serialize());
}

@inline_ref
fun finishUncooperativeClose(channel: Channel) {
    assert(channel.quarantine != null) throw ERROR_NO_QUARANTINED_STATE;

    var qua = Quarantine.parse(channel.quarantine);

    assert(qua.startedAt +
        channel.closureConfig.quarantineDuration +
        channel.closureConfig.closeDuration < blockchain.now()) throw ERROR_TOO_EARLY_TO_CLOSE;

    channel.balance.sentB += qua.stateB.sent;
    channel.balance.sentA += qua.stateA.sent;

    var balanceB = channel.balance.calcB();
    var balanceA = channel.balance.calcA();

    if (balanceB < 0) {
        channel.balance.sentA -= balanceB;
    }
    if (balanceA < 0) {
        channel.balance.sentB -= balanceA;
    }

    channel.commitedSeqnoA = qua.stateA.seqno + 1;
    channel.commitedSeqnoB = qua.stateB.seqno + 1;
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
fun Channel.verifyStates(self, a: Semichannel, b: Semichannel): void {
    assert((a.data.seqno >= self.commitedSeqnoA) &
        (b.data.seqno >= self.commitedSeqnoB) &
        (b.data.seqno >= a.counterpartyData.seqno) &
        (a.data.seqno >= b.counterpartyData.seqno) &
        (b.data.seqno >= a.counterpartyData.sent) &
        (a.data.sent >= b.counterpartyData.sent) &
        (a.counterpartyData.seqno >= self.commitedSeqnoB) &
        (b.counterpartyData.seqno >= self.commitedSeqnoA)) throw ERROR_OUTDATED_STATE;
}

@inline_ref
fun Channel.verifyMessageType(self, mutate msg: slice, tag: uint32): void {
    assert(msg.loadUint(32) == tag) throw ERROR_WRONG_TAG;
    assert(self.id == msg.loadUint(128)) throw ERROR_WRONG_CHANNEL_ID;
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

    var qua = Quarantine.parse(channel.quarantine);

    if (qua.startedAt + channel.closureConfig.quarantineDuration > blockchain.now()) {
        return STATE_CLOSURE_STARTED;
    }

    if (qua.startedAt +
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
