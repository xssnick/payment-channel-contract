import "@stdlib/common.tolk"
import "@stdlib/gas-payments"
import "@stdlib/tvm-dicts"
import "@stdlib/tvm-lowlevel"
import "types.tolk"

fun Channel.topUpBalance(mutate self, amount: int, msg: slice) {
    assert(self.inited) throw ERROR_NOT_INITED;
    // we allow topup only when there is no disput
    assert(self.quarantine == null) throw ERROR_QUARANTINE_ALREADY_ACTIVE;

    var isA: bool = msg.loadBool();
    if (isA) {
        self.balance.depositA += amount;
    } else {
        self.balance.depositB += amount;
    }

    contract.setData(self.serialize());
}

fun initChannel(channel: Channel, msg: slice) {
    assert(!channel.inited) throw ERROR_ALREADY_INITED;

    var isA: int = msg.loadInt(1);
    var signature: slice = msg.loadBits(512);
    assert(isSignatureValid(msg.hash(), signature, isA ? channel.keyA : channel.keyB)) throw ERROR_NOT_AUTHORIZED;
    msg.verifyMessageType(TAG_INIT_CHANNEL, channel.id);

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
fun sendPayout(config: PaymentConfig, sAddr: slice, amount: int, channelId: int, op: int, flags: int) {

    return match(config.currencyType) {
        CURRENCY_TYPE_TON => {
            sendPayoutTon(sAddr, amount, channelId, op, flags);
            return 0;
        }
        CURRENCY_TYPE_JETTON => {
            sendPayoutJetton(config.jettonWallet, sAddr, amount, channelId, op, flags);
            return FEE_JETTON_PAYOUT;
        }
        CURRENCY_TYPE_EC => {
            sendPayoutEC(config.ecId, sAddr, amount, channelId, op, flags);
            return FEE_EC_PAYOUT;
        }
        else => 0
    };
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
    if(amount > 0) {
        currenciesToSend.uDictSetBuilder(32, ecId, beginCell().storeVarUInt32(amount));
    }

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
                .storeBool(false)
                .storeMessageOp(op)
                .storeUint(channelId, 128)
            .endCell())
        .endCell(),
        flags
    );
}

fun Channel.closeChannel(mutate self) {
    sendPayout(self.paymentConfig, self.paymentConfig.addressB, self.balance.calcB(), self.id, OP_CHANNEL_CLOSED, SEND_MODE_IGNORE_ERRORS);
    // side A is considered to be deployer, so he will get rest contract's ton balance
    sendPayout(self.paymentConfig, self.paymentConfig.addressA, self.balance.calcA(), self.id, OP_CHANNEL_CLOSED, SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);

    // while self contract will be emptied it will survive for some time
    // by clearing storage we allow immediately reopen self with the same configs
    self.inited = false;
    self.balance = Balance {
        depositA: 0,
        depositB: 0,
        withdrawA: 0,
        withdrawB: 0,
        sentA: 0,
        sentB: 0,
    };
    self.quarantine = null;

    return contract.setData(self.serialize());
}

@inline_ref
fun Channel.cooperativeClose(mutate self, msg: slice) {
    var sigA: slice = msg.loadRef().beginParse();
    var sigB: slice = msg.loadRef().beginParse();
    var hash: int = msg.hash();

    msg.verifyMessageType(TAG_COOPERATIVE_CLOSE, self.id);

    assert(isSignatureValid(hash, sigA, self.keyA) &
        isSignatureValid(hash, sigB, self.keyB)) throw ERROR_NOT_AUTHORIZED;

    var newSentA: int = msg.loadCoins();
    var newSentB: int = msg.loadCoins();

    self.balance.sentA = newSentA;
    self.balance.sentB = newSentB;

    var newSeqnoA: int = msg.loadUint(64);
    var newSeqnoB: int = msg.loadUint(64);
    assert((self.commitedSeqnoA < newSeqnoA) &
        (self.commitedSeqnoB < newSeqnoB)) throw ERROR_SEQNO_REGRESS;

    self.commitedSeqnoA = newSeqnoA;
    self.commitedSeqnoB = newSeqnoB;

    self.closeChannel();
}

@inline_ref
fun Channel.cooperativeCommit(mutate self, msg: slice, msgValue: int) {
    var sigA: slice = msg.loadRef().beginParse();
    var sigB: slice = msg.loadRef().beginParse();
    var hash: int = msg.hash();

    msg.verifyMessageType(TAG_COOPERATIVE_COMMIT, self.id);

    assert(isSignatureValid(hash, sigA, self.keyA) &
        isSignatureValid(hash, sigB, self.keyB)) throw ERROR_NOT_AUTHORIZED;

    var newSentA: int = msg.loadCoins();
    var newSentB: int = msg.loadCoins();

    self.balance.sentA = newSentA;
    self.balance.sentB = newSentB;

    var newSeqnoA: int = msg.loadUint(64);
    var newSeqnoB: int = msg.loadUint(64);
    assert((self.commitedSeqnoA < newSeqnoA) &
        (self.commitedSeqnoB < newSeqnoB)) throw ERROR_SEQNO_REGRESS;

    self.commitedSeqnoA = newSeqnoA;
    self.commitedSeqnoB = newSeqnoB;

    if (self.quarantine != null) {
        var qua = Quarantine.parse(self.quarantine);
        if ((newSeqnoA > qua.stateA.seqno) | (newSeqnoB > qua.stateB.seqno)) {
            // quarantinened state is older than newly commited one, drop it
            self.quarantine = null;
        }
    }

    var withdrawA: int = msg.loadCoins();
    var withdrawB: int = msg.loadCoins();


    var withdrawAmount = withdrawB - self.balance.withdrawB;
    assert(withdrawAmount >= 0) throw ERROR_WITHDRAW_REGRESS;
    if (withdrawAmount > 0) {
        self.balance.withdrawB = withdrawB;
        msgValue -= sendPayout(self.paymentConfig, self.paymentConfig.addressB, withdrawAmount, self.id, OP_CHANNEL_WITHDRAW, 0);
    }

    withdrawAmount = withdrawA - self.balance.withdrawA;
    assert(withdrawAmount >= 0) throw ERROR_WITHDRAW_REGRESS;
    if (withdrawAmount > 0) {
        self.balance.withdrawA = withdrawA;
        msgValue -= sendPayout(self.paymentConfig,self.paymentConfig.addressA, withdrawAmount, self.id, OP_CHANNEL_WITHDRAW, 0);
    }

    assert(msgValue >= 0) throw ERROR_AMOUNT_NOT_COVERS_FEE;
    assert(self.balance.calcA() >= 0 && self.balance.calcB() >= 0) throw ERROR_NOT_ENOUGH_BALANCE;

    contract.setData(self.serialize());
}

@inline_ref
fun startUncooperativeClose(channel: Channel, msg: slice) {
    assert(channel.quarantine == null) throw ERROR_QUARANTINE_ALREADY_ACTIVE;
    var signedByA: bool = msg.loadBool();
    var signature: slice = msg.loadBits(512);
    assert(isSignatureValid(msg.hash(), signature, signedByA ? channel.keyA : channel.keyB)) throw ERROR_NOT_AUTHORIZED;

    msg.verifyMessageType(TAG_START_UNCOOPERATIVE_CLOSE, channel.id);

    var a = Semichannel.parse(msg.loadRef(), channel.id, channel.keyA);
    var b = Semichannel.parse(msg.loadRef(), channel.id, channel.keyB);

    verifyStates(channel.commitedSeqnoA, channel.commitedSeqnoB,a, b);

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

    msg.verifyMessageType(TAG_CHALLENGE_QUARANTINEED_STATE, channel.id);

    var a = Semichannel.parse(msg.loadRef(), channel.id, channel.keyA);
    var b = Semichannel.parse(msg.loadRef(), channel.id, channel.keyB);

    verifyStates(channel.commitedSeqnoA, channel.commitedSeqnoB, a, b);

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

    msg.verifyMessageType(TAG_SETTLE_CONDITIONALS, channel.id);

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
fun Channel.finishUncooperativeClose(mutate self) {
    assert(self.quarantine != null) throw ERROR_NO_QUARANTINED_STATE;

    var qua = Quarantine.parse(self.quarantine);

    assert(qua.startedAt +
        self.closureConfig.quarantineDuration +
        self.closureConfig.closeDuration < blockchain.now()) throw ERROR_TOO_EARLY_TO_CLOSE;

    self.balance.sentB = qua.stateB.sent;
    self.balance.sentA = qua.stateA.sent;

    var balanceB = self.balance.calcB();
    var balanceA = self.balance.calcA();

    if (balanceB < 0) {
        self.balance.sentA -= balanceB;
    }
    if (balanceA < 0) {
        self.balance.sentB -= balanceA;
    }

    self.commitedSeqnoA = qua.stateA.seqno + 1;
    self.commitedSeqnoB = qua.stateB.seqno + 1;
    self.closeChannel();
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
            var (v: slice?, ok: bool) = ec.uDictDeleteAndGet(32, channel.paymentConfig.ecId);
            // If dictionary contains more than one EC - reject
            assert(ok && ec == null) throw ERROR_INVALID_EC_ID;

            var ecAmount: int = v!.loadVarUInt32();
            channel.topUpBalance(ecAmount, inMsg);
        } else {
            assert(amount >= FEE_TON_ACCEPT) throw ERROR_AMOUNT_NOT_COVERS_FEE;
            channel.topUpBalance(amount - FEE_TON_ACCEPT, inMsg);
        }
    } else if (op == OP_JETTON_TRANSFER_NOTIFICATION) {
        // return because custom excess handled inside
        return acceptJettons(channel, sender, amount, inMsg);
    } else if (op == OP_JETTON_TAKE_WALLET_ADDRESS) {
        // no excess
        return assignJettonWallet(channel, sender, inMsg);
    } else if (op == OP_COOPERATIVE_COMMIT) {
        channel.cooperativeCommit(inMsg, amount - FEE_COMMIT);
    } else if (op == OP_INIT_CHANNEL) {
        initChannel(channel, inMsg);
    } else if (op == OP_COOPERATIVE_CLOSE) {
        // excess hadled in channelClose()
        return channel.cooperativeClose(inMsg);
    } else if (op == OP_START_UNCOOPERATIVE_CLOSE) {
        startUncooperativeClose(channel, inMsg);
    } else if (op == OP_CHALLENGE_QUARANTINEED_STATE) {
        challengeQuarantinedState(channel, inMsg);
    } else if (op == OP_SETTLE_CONDITIONALS) {
        settleConditionals(channel, inMsg);
    } else if (op == OP_FINISH_UNCOOPERATIVE_CLOSE) {
        // excess hadled in channelClose()
        return channel.finishUncooperativeClose();
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
            channel.topUpBalance(jettonAmount, forwardPayload);
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
    reserveToncoinsOnBalance(reserve, RESERVE_MODE_AT_MOST);

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
fun verifyStates(commitedSeqnoA: int, commitedSeqnoB: int, a: Semichannel, b: Semichannel): void {
    assert((a.data.seqno >= commitedSeqnoA) &
        (b.data.seqno >= commitedSeqnoB) &
        (b.data.seqno >= a.counterpartyData.seqno) &
        (a.data.seqno >= b.counterpartyData.seqno) &
        (b.data.sent >= a.counterpartyData.sent) &
        (a.data.sent >= b.counterpartyData.sent)) throw ERROR_OUTDATED_STATE;

        if(a.counterpartyData.seqno > 0) {
            assert(a.counterpartyData.seqno >= commitedSeqnoB) throw ERROR_OUTDATED_STATE;
        }
        if(b.counterpartyData.seqno > 0) {
            assert(b.counterpartyData.seqno >= commitedSeqnoA) throw ERROR_OUTDATED_STATE;
        }
}

@inline_ref
fun slice.verifyMessageType(mutate self, tag: uint32, id: int): void {
    assert(self.loadUint(32) == tag) throw ERROR_WRONG_TAG;
    assert(id == self.loadUint(128)) throw ERROR_WRONG_CHANNEL_ID;
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
