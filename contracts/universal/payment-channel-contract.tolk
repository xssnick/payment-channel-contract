import "@stdlib/common"
import "@stdlib/gas-payments"
import "@stdlib/tvm-dicts"
import "@stdlib/tvm-lowlevel"
import "c5-register-validation"
import "storage"
import "messages"
import "../errors"
import "../utils"

type AllowedExtMessages =
    | ExternalSignedRequest
    | ExternalDoubleSignedRequest
    | CooperativeCommitMessage
    | CooperativeCloseMessage
    | StartUncooperativeCloseMessage
    | FinishUncooperativeCloseMessage
    | SettleConditionalsMessage
    | ProxySettleMessage
    | FinalizeSettleMessage;

type AllowedIntMessages =
    | ExecuteActionsMessage
    | CooperativeCommitMessage
    | CooperativeCloseMessage
    | StartUncooperativeCloseReplicateMessage
    | FinalizeSettleReplicateMessage
    | FinishUncooperativeCloseMessage
    | InitChannelMessage

fun onInternalMessage(in: InMessage) {
    var channel = Channel.parse(contract.getData());

    var msg = lazy AllowedIntMessages.fromSlice(in.body);

    match(msg) {
        InitChannelMessage => {
            return channel.initChannel(msg, in.senderAddress);
        }
        CooperativeCommitMessage => {
            return channel.cooperativeCommit(msg, in.senderAddress);
        }
        CooperativeCloseMessage => {
            return channel.cooperativeClose(msg, in.senderAddress);
        }
        StartUncooperativeCloseReplicateMessage => {
            return channel.startUncooperativeCloseReplica(msg, in.senderAddress);
        }
        ExecuteActionsMessage => {
            return channel.executeUncooperativeAction(msg, in.senderAddress);
        }
        FinalizeSettleReplicateMessage => {
            return channel.finalizeSettleReplica(msg, in.senderAddress);
        }
        FinishUncooperativeCloseMessage => {
            return channel.finishUncooperativeClose(in.senderAddress);
        }
        else => { }
    }
}

fun onExternalMessage(inMsgBody: slice) {
    var channel = Channel.parse(contract.getData());

    var msg = lazy AllowedExtMessages.fromSlice(inMsgBody);

    match(msg) {
        ExternalDoubleSignedRequest => {
            // double signed is accepted on alive channel
            assert (channel.inited && channel.quarantine == null) throw ERROR_NOT_AUTHORIZED;

            var hash = msg.signedBody.hash();
            assert(isSignatureValid(hash, msg.signatureA.beginParse(), channel.keyA) &&
            isSignatureValid(hash, msg.signatureB.beginParse(), channel.keyB)) throw ERROR_INVALID_SIGNATURE;

            return channel.doWalletTransaction(msg.signedBody);
        }
        ExternalSignedRequest => {
            // owner signed is accepted on inactive channel
            assert (!channel.inited) throw ERROR_NOT_AUTHORIZED;

            assert (isSignatureValid(msg.signedBody.hash(), msg.signature as slice, channel.isA ? channel.keyA : channel.keyB)) throw ERROR_INVALID_SIGNATURE;

            return channel.doWalletTransaction(msg.signedBody);
        }
        CooperativeCommitMessage => {
            return channel.cooperativeCommit(msg, createAddressNone());
        }
        CooperativeCloseMessage => {
            return channel.cooperativeClose(msg, createAddressNone());
        }
        StartUncooperativeCloseMessage => {
            return channel.startUncooperativeClose(msg);
        }
        SettleConditionalsMessage => {
            return channel.settleConditionals(msg);
        }
        FinalizeSettleMessage => {
            return channel.finalizeSettle(msg);
        }
        ProxySettleMessage => {
            return channel.proxyExecuteAction(msg);
        }
        FinishUncooperativeCloseMessage => {
            return channel.finishUncooperativeClose(createAddressNone());
        }
    }
}

@inline
fun Channel.initChannel(mutate self, msg: InitChannelMessage, sender: address) {
    assert(!self.inited) throw ERROR_ALREADY_INITED;

    var hash: int = msg.signedBody.hash();
    assert(isSignatureValid(hash, msg.signatureA.beginParse(), self.keyA) &&
    isSignatureValid(hash, msg.signatureB.beginParse(), self.keyB)) throw ERROR_NOT_AUTHORIZED;

    var sourceMsg = msg.toCell();

    msg.signedBody.verifyMessageType(TAG_INIT_CHANNEL, self.id);

    var body = msg.signedBody.loadAny<InitChannelBody>();
    assert (body.seqno >= self.commitedSeqno) throw ERROR_OUTDATED_STATE;

    var deploy = AutoDeployAddress{
        stateInit: {
            code: contract.getCode(),
            data: Channel{
                isA: !self.isA,
                inited: false,
                commitedSeqno: 0,
                walletSeqno: 0,
                keyA: self.keyA,
                keyB: self.keyB,
                id: self.id,
                closureConfig: self.closureConfig,
                partyAddress: createAddressNone(),
                quarantine: null
            }.toCell(),
        },
        /* toShard: {
             fixedPrefixLength: 8, // ok?
             closeTo: contract.getAddress(),
         }*/
    };

    self.partyAddress = address.fromValidBuilder(deploy.buildAddress());

    var cc = lazy self.closureConfig.load();
    reserveToncoinsOnBalance(cc.replicateAttachAmount, RESERVE_MODE_EXACT_AMOUNT);

    // init party
    if (sender != self.partyAddress) {
        createMessage({
            bounce: false,
            dest: deploy,
            value: cc.replicateAttachAmount * 2,
            body: sourceMsg,
        }).send(SEND_MODE_REGULAR);
    }

    if (sender != contract.getAddress()) {
        createMessage({
            bounce: false,
            dest: sender,
            value: 0,
            body: (OP_EXCESSES as uint32, 0 as uint64),
        }).send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS);
    }

    self.inited = true;
    return contract.setData(self.serialize());
}

@inline_ref
fun Channel.cooperativeCommit(mutate self, msg: CooperativeCommitMessage, sender: address) {
    assert(self.inited) throw ERROR_NOT_INITED;

    var hash: int = msg.signedBody.hash();

    var sourceMsg = msg.toCell();

    assert(isSignatureValid(hash, msg.signatureA.beginParse(), self.keyA) &&
    isSignatureValid(hash, msg.signatureB.beginParse(), self.keyB)) throw ERROR_NOT_AUTHORIZED;

    msg.signedBody.verifyMessageType(TAG_COOPERATIVE_COMMIT, self.id);

    var commitBody = msg.signedBody.loadAny<CooperativeCommitBody>();

    assert((commitBody.fromA == self.isA) || (commitBody.fromA != self.isA && !sender.isNone())) throw ERROR_NOT_AUTHORIZED;

    assert(commitBody.seqno > self.commitedSeqno) throw ERROR_SEQNO_REGRESS;

    if (self.quarantine != null) {
        var qua = lazy self.quarantine.load();
        if (qua.theirState == null) {
            self.quarantine = null;
        } else if (commitBody.seqno > qua.seqno)  {
            // quarantinened state is older than newly commited one, drop it
            self.quarantine = null;
        }
    }

    acceptExternalMessage();

    if (commitBody.action != null) {
        var actionBody = commitBody.action.load();

        var states = self.isA ? (actionBody.stateA, actionBody.stateB) : (actionBody.stateB, actionBody.stateA);

        // we care about [0] because it has amount to transfer from this contract,
        // and [1] just decreases it, but if other side has no this action we have no decrease.
        if (states.0 != null) {
            var executableAction = castToAction(transformSliceToContinuation(actionBody.code.beginParse()));

            // actions must not throw any errors
            executableAction(self.commitedSeqno, states.0.beginParse(), states.1 != null ? states.1.beginParse() : null, self.isA);
        }
    }

    self.commitedSeqno = commitBody.seqno;

    self.replicateStateIfNeeded(sender, sourceMsg);

    return contract.setData(self.serialize());
}

@inline_ref
fun Channel.cooperativeClose(mutate self, msg: CooperativeCloseMessage, sender: address) {
    assert(self.inited) throw ERROR_NOT_INITED;

    var hash: int = msg.signedBody.hash();

    var sourceMsg = msg.toCell();

    assert(isSignatureValid(hash, msg.signatureA.beginParse(), self.keyA) &&
    isSignatureValid(hash, msg.signatureB.beginParse(), self.keyB)) throw ERROR_NOT_AUTHORIZED;

    msg.signedBody.verifyMessageType(TAG_COOPERATIVE_CLOSE, self.id);

    var closeBody = msg.signedBody.loadAny<CooperativeCloseBody>();

    assert((closeBody.fromA == self.isA) || (closeBody.fromA != self.isA && !sender.isNone())) throw ERROR_NOT_AUTHORIZED;

    assert(closeBody.seqno > self.commitedSeqno) throw ERROR_SEQNO_REGRESS;

    self.commitedSeqno = closeBody.seqno;

    acceptExternalMessage();

    self.replicateStateIfNeeded(sender, sourceMsg);
    self.closeChannel();
}

@inline
fun Channel.startUncooperativeClose(mutate self, msg: StartUncooperativeCloseMessage) {
    assert (self.inited) throw ERROR_NOT_INITED;

    assert(isSignatureValid(msg.signedBody.hash(), msg.signature as slice, self.isA ? self.keyA : self.keyB)) throw ERROR_NOT_AUTHORIZED;

    msg.signedBody.verifyMessageType(TAG_START_UNCOOPERATIVE_CLOSE, self.id);

    var commitBody = msg.signedBody.loadAny<StartUncooperativeCloseBody>();

    var quaPrev: Quarantine? = null;
    if (self.quarantine != null) {
        quaPrev = self.quarantine.load();

        var closure = lazy self.closureConfig.load();

        var quarantineeFinished: int = quaPrev.startedAt + closure.quarantineDuration;
        assert(quarantineeFinished > blockchain.now()) throw ERROR_TOO_LATE_FOR_QUARANTINE_CHALLENGE;

        // owner can commit only once
        assert (!quaPrev.committedByOwner) throw ERROR_QUARANTINE_ALREADY_ACTIVE;

        // we already have quarantine, challenge cannot be without states
        assert (commitBody.state != null) throw ERROR_QUARANTINE_ALREADY_ACTIVE;
    }

    var qua = Quarantine{
        seqno: quaPrev != null ? quaPrev!.seqno : self.commitedSeqno,
        ourSettlementFinalized: false,
        actionsToExecuteHash: 0,
        theirState: quaPrev != null ? quaPrev!.theirState : null,
        startedAt: quaPrev != null ? quaPrev!.startedAt : blockchain.now(),
        committedByOwner: true,
    };

    // states could be null if there was no interraction between parties, then nothing to commit
    if (commitBody.state != null) {
        var state = StateBodySigned.unpackAndVerify(commitBody.state, self.id,  self.commitedSeqno, self.keyA, self.keyB);

        // if both sides will sign same seqno twice with diff hashes, it is their problem, it must be controlled offchain
        assert (qua.theirState == null || state.seqno > qua.seqno) throw ERROR_OUTDATED_STATE;

        qua.seqno = state.seqno;
        qua.theirState = self.isA ? state.B.load() : state.A.load();
    }

    acceptExternalMessage();

    self.replicateStateIfNeeded(createAddressNone(), StartUncooperativeCloseReplicateMessage{
        at: qua.startedAt,
        state: commitBody.state,
    });

    self.quarantine = qua.serialize();
    return contract.setData(self.serialize());
}

@inline
fun Channel.startUncooperativeCloseReplica(mutate self, msg: StartUncooperativeCloseReplicateMessage, sender: address) {
    assert (self.inited) throw ERROR_NOT_INITED;
    assert (self.partyAddress == sender) throw ERROR_NOT_AUTHORIZED;

    var startedAt = msg.at;
    var closeState = msg.state;

    var quaPrev: Quarantine? = null;
    if (self.quarantine != null) {
        quaPrev = self.quarantine.load();

        var closure = lazy self.closureConfig.load();

        var quarantineeFinished: int = quaPrev.startedAt + closure.quarantineDuration;
        // for the replica it can happen that challenge will not be accepted on contract,
        // but this is responsibility of the party to use the latest state at the earliest.
        // It is also recommended to deploy both contracts to same shard, using channel id variation
        assert(quarantineeFinished > blockchain.now()) throw ERROR_TOO_LATE_FOR_QUARANTINE_CHALLENGE;

        // we already have quarantine, challenge cannot be without states
        assert (closeState != null) throw ERROR_QUARANTINE_ALREADY_ACTIVE;

        // use the earliest time
        if (quaPrev.startedAt < startedAt) {
            startedAt = quaPrev.startedAt;
        }
    }

    var qua = Quarantine{
        seqno: quaPrev != null ? quaPrev!.seqno : self.commitedSeqno,
        ourSettlementFinalized: false,
        actionsToExecuteHash: 0,
        theirState: quaPrev != null ? quaPrev!.theirState : null,
        startedAt: startedAt,
        committedByOwner: quaPrev != null ? quaPrev!.committedByOwner : false,
    };

    // states could be null if there was no interraction between parties, then nothing to commit
    if (closeState != null) {
        var state = StateBodySigned.unpackAndVerify(closeState, self.id,  self.commitedSeqno, self.keyA, self.keyB);

        // if both sides will sign same seqno twice with diff hashes, it is their problem, it must be controlled offchain
        assert (qua.theirState == null || state.seqno > qua.seqno) throw ERROR_OUTDATED_STATE;

        qua.seqno = state.seqno;
        qua.theirState = self.isA ? state.B.load() : state.A.load();
    }

    createMessage({
        bounce: false,
        dest: sender,
        value: 0,
        body: (OP_EXCESSES as uint32, 0 as uint64),
    }).send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS);

    self.quarantine = qua.serialize();
    return contract.setData(self.serialize());
}

@inline_ref
fun Channel.replicateStateIfNeeded<T>(self, sender: address, msg: T): bool {
    if (sender != self.partyAddress) {
        var cc = lazy self.closureConfig.load();
        // we should replicate our state to another contract
        createMessage({
            bounce: true,
            dest: self.partyAddress,
            value: cc.replicateAttachAmount,
            body: msg
        }).send(SEND_MODE_REGULAR);
        return true;
    } else {
        // return excess to party
        createMessage({
            bounce: false,
            dest: self.partyAddress,
            value: 0,
            body: (OP_EXCESSES as uint32, 0 as uint64),
        }).send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS);
    }
    return false;
}

@inline
fun Channel.closeChannel(mutate self) {
    self.inited = false;
    if (self.quarantine != null) {
        var qua = lazy self.quarantine.load();
        self.commitedSeqno = qua.seqno;

        self.quarantine = null;
    }
    self.commitedSeqno += 1;

    return contract.setData(self.serialize());
}

@inline_ref
fun slice.verifyMessageType(mutate self, tag: uint32, id: int): void {
    var messageId = self.loadAny<ChannelMessageId>();
    assert(messageId.tag == tag) throw ERROR_WRONG_TAG;
    assert(messageId.id == id) throw ERROR_WRONG_CHANNEL_ID;
}

fun Channel.doWalletTransaction(mutate self, signedBody: RemainingBitsAndRefs) {
    signedBody.verifyMessageType(TAG_MSG_EXTERNAL, self.id);

    var body = signedBody.loadAny<ExternalSignedBody>();

    assert (body.sideA == self.isA) throw ERROR_INVALID_SIDE;
    assert (body.seqno == self.walletSeqno) throw ERROR_INVALID_SEQNO;
    assert (body.validUntil > blockchain.now()) throw ERROR_EXPIRED;

    acceptExternalMessage();

    self.walletSeqno += 1;
    contract.setData(self.serialize());
    commitContractDataAndActions();

    if (body.outActions != null) {
        setTvmRegisterC5(body.outActions.verifyC5Actions(self.partyAddress));
    }
}

@inline
fun Channel.settleConditionals(mutate self, msg: SettleConditionalsMessage) {
    assert(self.inited) throw ERROR_NOT_INITED;

    assert(self.quarantine != null) throw ERROR_NO_QUARANTINED_STATE;

    assert(isSignatureValid(msg.signedBody.hash(), msg.signature as slice, self.isA ? self.keyA : self.keyB)) throw ERROR_NOT_AUTHORIZED;

    msg.signedBody.verifyMessageType(TAG_SETTLE_CONDITIONALS, self.id);

    var conditionals = msg.signedBody.loadAny<SettleConditionalsBody>();
    assert (conditionals.walletSeqno == self.walletSeqno) throw ERROR_INVALID_SEQNO;

    var qua = lazy self.quarantine.load();
    var closure = lazy self.closureConfig.load();

    var quarantineeFinished: int = qua.startedAt + closure.quarantineDuration;
    assert (quarantineeFinished < blockchain.now()) throw ERROR_QUARANTINE_NOT_FINISHED;
    assert ((quarantineeFinished + closure.settlementDuration > blockchain.now()) && !qua.ourSettlementFinalized) throw ERROR_TOO_LATE_TO_SETTLE_CONDITIONALS;
    assert (qua.theirState != null) throw ERROR_NOTHING_TO_SETTLE;

    var targetConditionals: cell = parseProof(conditionals.conditionalsProof, qua.theirState.conditionalsHash);
    var targetActionsInput: cell = parseProof(conditionals.actionsInputProof, qua.theirState.actionsInputHash);

    acceptExternalMessage();

    // we use seqno to not repeat if exception thrown
    self.walletSeqno += 1;
    contract.setData(self.serialize());
    commitContractDataAndActions();

    var more: bool = true;
    do {
        var (cid: int?, input: slice?, more redef) = conditionals.toSettle.uDictDeleteFirstAndGet(256);
        if (more) {
            var empty: slice = createEmptySlice();
            var (targetConditionals redef, condition: slice, ok: int) = targetConditionals.isUdictReplaceGet(256, cid!, empty);
            assert(ok && !condition.isEmpty()) throw ERROR_INCORRECT_CONDITIONALS_PROOF;

            var executableCondition = castToCondition(transformSliceToContinuation(condition));
            // NOTE! It seems dangerous to run unknown code and it really is!
            // However, runned code is signed by one party and executed by another
            // That way both party authorized it.
            // Obviously, B should not sign incorrect code which (for instance) sends all money to A
            // The same way A should not run incorrect code which sends all money to B.
            targetActionsInput = executableCondition(targetActionsInput, input!);
        }
    } while (more);

    qua.theirState.conditionalsHash = proofHash(targetConditionals);
    qua.theirState.actionsInputHash = proofHash(targetActionsInput);

    createExternalLogMessage({
        dest: createAddressNone(),
        body: ConditionalsSettledEvent {
            updatedConditionalsHash: qua.theirState.conditionalsHash,
            updatedActionsHash: qua.theirState.actionsInputHash,
        }
    }).send(SEND_MODE_REGULAR);

    self.quarantine = qua.serialize();
    return contract.setData(self.serialize());
}

@inline
fun Channel.finalizeSettle(mutate self, msg: FinalizeSettleMessage) {
    assert(self.inited) throw ERROR_NOT_INITED;

    assert(self.quarantine != null) throw ERROR_NO_QUARANTINED_STATE;

    assert(isSignatureValid(msg.signedBody.hash(), msg.signature as slice, self.isA ? self.keyA : self.keyB)) throw ERROR_NOT_AUTHORIZED;
    msg.signedBody.verifyMessageType(TAG_FINALIZE_SETTLE, self.id);

    var body = msg.signedBody.loadAny<FinalizeSettleBody>();
    assert (body.walletSeqno == self.walletSeqno) throw ERROR_INVALID_SEQNO;

    var qua = lazy self.quarantine.load();
    var closure = lazy self.closureConfig.load();

    var quarantineeFinished: int = qua.startedAt + closure.quarantineDuration;
    assert (quarantineeFinished < blockchain.now()) throw ERROR_QUARANTINE_NOT_FINISHED;
    assert ((quarantineeFinished + closure.settlementDuration > blockchain.now()) && !qua.ourSettlementFinalized) throw ERROR_TOO_LATE_TO_SETTLE_CONDITIONALS;

    assert (qua.theirState != null) throw ERROR_NOTHING_TO_SETTLE;
    assert (body.actionsInputHash == qua.theirState.actionsInputHash) throw ERROR_OUTDATED_STATE;
    assert (!qua.ourSettlementFinalized) throw ERROR_ALREADY_INITED;

    acceptExternalMessage();

    self.replicateStateIfNeeded(createAddressNone(), FinalizeSettleReplicateMessage{
        // we are sending their finalized actions hash to their contract, to exectute actions on it
        actionsInputHash: qua.theirState.actionsInputHash
    });

    qua.ourSettlementFinalized = true;
    self.walletSeqno += 1;
    self.quarantine = qua.serialize();
    return contract.setData(self.serialize());
}

@inline
fun Channel.finalizeSettleReplica(mutate self, msg: FinalizeSettleReplicateMessage, sender: address) {
    assert(self.inited) throw ERROR_NOT_INITED;
    assert (self.quarantine != null) throw ERROR_NO_QUARANTINED_STATE;
    assert (sender == self.partyAddress) throw ERROR_NOT_AUTHORIZED;

    var qua = lazy self.quarantine.load();
    var closure = lazy self.closureConfig.load();

    var quarantineeFinished: int = qua.startedAt + closure.quarantineDuration;
    assert(quarantineeFinished < blockchain.now()) throw ERROR_QUARANTINE_NOT_FINISHED;
    assert((quarantineeFinished + closure.settlementDuration > blockchain.now())) throw ERROR_TOO_LATE_TO_SETTLE_CONDITIONALS;

    assert(qua.actionsToExecuteHash == 0) throw ERROR_TOO_LATE_TO_SETTLE_CONDITIONALS;

    createMessage({
        bounce: false,
        dest: sender,
        value: 0,
        body: (OP_EXCESSES as uint32, 0 as uint64),
    }).send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS);

    qua.actionsToExecuteHash = msg.actionsInputHash;
    self.quarantine = qua.serialize();
    return contract.setData(self.serialize());
}

@inline
fun Channel.proxyExecuteAction(mutate self, msg: ProxySettleMessage) {
    assert(self.inited) throw ERROR_NOT_INITED;
    assert (self.quarantine != null) throw ERROR_NO_QUARANTINED_STATE;

    var qua = lazy self.quarantine.load();
    var closure = lazy self.closureConfig.load();

    assert(qua.startedAt + closure.quarantineDuration + closure.settlementDuration < blockchain.now()) throw ERROR_TOO_EARLY_TO_EXECUTE_ACTION;

    assert(isSignatureValid(msg.signedBody.hash(), msg.signature as slice, self.isA ? self.keyA : self.keyB)) throw ERROR_NOT_AUTHORIZED;

    msg.signedBody.verifyMessageType(TAG_MSG_PROXY, self.id);
    var body = msg.signedBody.loadAny<ProxySettleMessageBody>();

    assert (contract.getOriginalBalance() > closure.replicateAttachAmount * 2) throw ERROR_NOT_ENOUGH_BALANCE;
    assert (body.walletSeqno == self.walletSeqno) throw ERROR_INVALID_SEQNO;

    var inner = body.msg.load({assertEndAfterReading: true});

    acceptExternalMessage();

    self.walletSeqno += 1;
    contract.setData(self.serialize());
    commitContractDataAndActions();

    // send execute action to party as internal
    createMessage({
        bounce: true,
        dest: self.partyAddress,
        value: closure.replicateAttachAmount,
        body: inner,
    }).send(SEND_MODE_REGULAR);
}

// it must be executed on other side's contract via internal message, to not burn their ton for fee
@inline
fun Channel.executeUncooperativeAction(mutate self, msg: ExecuteActionsMessage, sender: address) {
    assert(self.inited) throw ERROR_NOT_INITED;
    assert(self.quarantine != null) throw ERROR_NO_QUARANTINED_STATE;

    assert(isSignatureValid(msg.signedBody.hash(), msg.signature as slice, self.isA ? self.keyB : self.keyA)) throw ERROR_NOT_AUTHORIZED;

    msg.signedBody.verifyMessageType(TAG_EXECUTE_ACTIONS, self.id);
    var body = msg.signedBody.loadAny<ExecuteActionsBody>();

    var qua = lazy self.quarantine.load();
    var closure = lazy self.closureConfig.load();

    assert(qua.startedAt + closure.quarantineDuration + closure.settlementDuration < blockchain.now()) throw ERROR_TOO_EARLY_TO_EXECUTE_ACTION;
    assert (qua.actionsToExecuteHash != 0) throw ERROR_NOTHING_TO_EXECUTE;
    assert (qua.theirState != null) throw ERROR_NOTHING_TO_SETTLE;

    var targetActionsOurInput: dict = parseProof(body.actionsOurInputProof, qua.actionsToExecuteHash);
    var targetActionsTheirInput: dict = createEmptyDict();
    if (body.actionsTheirInputProof != null) {
        targetActionsTheirInput = parseProof(body.actionsTheirInputProof, qua.theirState.actionsInputHash);
    }

    var key = body.action.hash();

    var empty: slice = createEmptySlice();
    var (targetActionsOurInput redef, inputOur: slice, okOur: int) = targetActionsOurInput.isUdictReplaceGet(256, key, empty);
    var (inputTheir: slice?, _) = targetActionsTheirInput.uDictGet(256, key);
    assert(okOur && !inputOur.isEmpty()) throw ERROR_INCORRECT_ACTION_INPUT;

    var executableAction = castToAction(transformSliceToContinuation(body.action.beginParse()));

    // actions must not throw any errors
    executableAction(self.commitedSeqno, inputOur!, inputTheir, self.isA);

    qua.actionsToExecuteHash = proofHash(targetActionsOurInput);

    createMessage({
        bounce: false,
        dest: sender,
        value: 0,
        body: (OP_EXCESSES as uint32, 0 as uint64),
    }).send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS);

    self.quarantine = qua.serialize();
    return contract.setData(self.serialize());
}

@inline
fun Channel.finishUncooperativeClose(mutate self, sender: address) {
    assert(self.inited) throw ERROR_NOT_INITED;
    assert(self.quarantine != null) throw ERROR_NO_QUARANTINED_STATE;

    var qua = lazy self.quarantine.load();
    var closure = lazy self.closureConfig.load();

    if (qua.theirState != null) {
        assert(qua.startedAt +
        closure.quarantineDuration +
        closure.settlementDuration +
        closure.actionsDuration < blockchain.now()) throw ERROR_TOO_EARLY_TO_CLOSE;
    } else {
        // when no states = nothing to settle and can close faster
        assert(qua.startedAt + closure.quarantineDuration < blockchain.now()) throw ERROR_TOO_EARLY_TO_CLOSE;
    }

    acceptExternalMessage();

    self.replicateStateIfNeeded(sender, FinishUncooperativeCloseMessage{});

    self.closeChannel();
}

@inline_ref
fun parseProof(proof: cell, hash: int): cell {
    var (csProof, special) = proof.beginParseSpecial();
    assert(special) throw ERROR_INCORRECT_CONDITIONALS_PROOF;
    assert(csProof.loadUint(8) == 3) throw ERROR_INCORRECT_CONDITIONALS_PROOF;
    assert(csProof.preloadUint(256) == hash) throw ERROR_INCORRECT_CONDITIONALS_PROOF;

    return csProof.preloadRef();
}

get fun get_channel_state(): int {
    var channel = Channel.parse(contract.getData());

    if (!channel.inited) {
        return STATE_UNINITED;
    }
    if (channel.quarantine == null) {
        return STATE_OPEN;
    }

    var qua = lazy channel.quarantine.load();
    var closure = lazy channel.closureConfig.load();

    if (qua.startedAt + closure.quarantineDuration > blockchain.now()) {
        return STATE_CLOSURE_STARTED;
    }

    if (qua.theirState != null) {
        if (qua.startedAt +
        closure.quarantineDuration +
        closure.settlementDuration > blockchain.now()) {
            return STATE_SETTLING_CONDITIONALS;
        }

        if (qua.startedAt +
        closure.quarantineDuration +
        closure.settlementDuration +
        closure.actionsDuration > blockchain.now()) {
            return STATE_EXECUTING_ACTIONS;
        }
    }

    return STATE_AWAITING_FINALIZATION;
}