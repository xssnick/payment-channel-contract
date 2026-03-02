import "@stdlib/tvm-dicts"
import "../contracts/fees"
import "../contracts/messages"
import "../contracts/utils"

fun main() {
}

struct FeeActionInput {
    amount: coins
    commited: coins
    commitSeqno: uint64
}

/*
fun cond(input: slice, fee: int, capacity: int, prepaid: int, deadline: int, key: int) {
			var sign: slice = input.loadBits(512);
			assert(isSliceSignatureValid(input, sign, key) & (deadline >= now()), 24);

			var amount: int = input.loadCoins();
			assert((amount <= capacity) & (prepaid <= amount), 26);
			return (amount - prepaid) + fee;
		}
 */

@method_id(42)
fun conditional_channel(targetActionsInput: dict, condInput: slice, sender: address, actionHash: int, fee: int, capacity: int, prepaid: int, deadline: int, key: int): dict {
    var (actInput, ok) = targetActionsInput.uDictGet(256, actionHash);
    if (actInput == null || !ok) {
        // we must always have action to execute condition
        return targetActionsInput;
    }

    var sign: slice = condInput.loadBits(512);
    assert(isSliceSignatureValid(condInput, sign, key) & (deadline >= blockchain.now())) throw 24;
    var amount: int = condInput.loadCoins();
    assert((amount <= capacity) & (prepaid <= amount)) throw 26;

    var v = actInput.loadAny<FeeActionInput>();
    v.amount += (amount - prepaid) + fee;

    targetActionsInput.uDictSet(256, actionHash, v.toCell().beginParse());

    return targetActionsInput;
}

@method_id(43)
fun action_ton(commitSeqno: int, actOur: slice, actTheir: slice?, isExecutedAtA: bool, addressA: address, addressB: address): void {
    var our = actOur.loadAny<FeeActionInput>();
    var their = FeeActionInput{amount: 0, commited: 0, commitSeqno: 0};
    if (actTheir != null) {
        their = actTheir.loadAny<FeeActionInput>();
    }

    // commit seqno for both states must be in sync, so we can check only one
    if (commitSeqno >= our.commitSeqno) {
        our.amount -= our.commited;
        their.amount -= their.commited;
    }

    var amt = our.amount - their.amount;
    if (amt <= 0) {
        return;
    }

    createMessage({
        bounce: false,
        dest: isExecutedAtA ? addressB : addressA,
        value: amt,
        body: beginCell().storeUint(0,32),
    }).send(SEND_MODE_REGULAR | SEND_MODE_IGNORE_ERRORS);
}

@method_id(44)
fun action_jettons(commitSeqno: int, actOur: slice, actTheir: slice?, isExecutedAtA: bool, addressA: address, addressB: address, jettonRoot: address, jettonWalletA: address, jettonWalletB: address): void {
    var our = actOur.loadAny<FeeActionInput>();
    var their = FeeActionInput{amount: 0, commited: 0, commitSeqno: 0};
    if (actTheir != null) {
        their = actTheir.loadAny<FeeActionInput>();
    }

    // commit seqno for both states must be in sync, so we can check only one
    if (commitSeqno >= our.commitSeqno) {
        our.amount -= our.commited;
        their.amount -= their.commited;
    }

    var amt = our.amount - their.amount;
    if (amt <= 0) {
        return;
    }

    createMessage({
        bounce: false,
        dest: isExecutedAtA ? jettonWalletA : jettonWalletB,
        value: ton("0.05"),
        body: AskToTransfer {
            queryId: 0,
            jettonAmount: amt,
            customPayload: null,
            transferRecipient: isExecutedAtA ? addressB : addressA,
            sendExcessesTo: contract.getAddress(),
            forwardTonAmount: 1,
            forwardPayload: beginCell().storeUint(0,32)
        }
    }).send(SEND_MODE_REGULAR | SEND_MODE_IGNORE_ERRORS);
}

@method_id(45)
fun action_ec(commitSeqno: int, actOur: slice, actTheir: slice?, isExecutedAtA: bool, addressA: address, addressB: address, ecId: int): void {
    var our = actOur.loadAny<FeeActionInput>();
    var their = FeeActionInput{amount: 0, commited: 0, commitSeqno: 0};
    if (actTheir != null) {
        their = actTheir.loadAny<FeeActionInput>();
    }

    // commit seqno for both states must be in sync, so we can check only one
    if (commitSeqno >= our.commitSeqno) {
        our.amount -= our.commited;
        their.amount -= their.commited;
    }

    var amt = our.amount - their.amount;
    if (amt <= 0) {
        return;
    }

    var currenciesToSend: dict = createEmptyDict();
    currenciesToSend.uDictSetBuilder(32, ecId, beginCell().storeVarUInt32(amt));

    return createMessage({
        bounce: false,
        dest: isExecutedAtA ? addressB : addressA,
        value: (FEE_EC_PAYOUT, currenciesToSend),
        body: beginCell().storeUint(0,32),
    }).send(SEND_MODE_REGULAR | SEND_MODE_IGNORE_ERRORS);
}

struct DerivativeResolve {
    id: uint256
    amount: coins
    at: uint32
}

@method_id(46)
fun conditional_derivative(targetActionsInput: dict, condInput: slice, sender: address, actionHash: int, id: uint256, maxAmount: coins, fee: coins, isInitiator: bool, details: cell, expectedSender: address): dict {
    if (sender != expectedSender) {
        throw 201;
    }

    var input = condInput.loadAny<DerivativeResolve>();
    if (input.id != id) {
        throw 202;
    }

    if (maxAmount != 0 && input.amount > maxAmount) {
        // hard cap of liquidation
        input.amount = maxAmount;
    }

    var (actInput, _) = targetActionsInput.uDictGet(256, actionHash);
    if (actInput == null) {
        // we must always have action to execute condition
        throw 203;
    }

    var v = actInput.loadAny<FeeActionInput>();

    if (isInitiator) {
        v.amount += input.amount + fee;
    } else if (fee < input.amount) {
        v.amount += input.amount - fee;
    }

    targetActionsInput.uDictSet(256, actionHash, v.toCell().beginParse());

    return targetActionsInput;
}

struct VaultData {
    target: address
    address: address
    signature: Cell<bits512>
}

struct (0x51a4168c) InternalSignedSenderRequest {
    signature: bits512
    message: cell
}

@method_id(50)
fun action_ton_vault(commitSeqno: int, actOur: slice, actTheir: slice?, isExecutedAtA: bool, vaultA: cell?, vaultB: cell?): void {
    var our = actOur.loadAny<FeeActionInput>();
    var their = FeeActionInput{amount: 0, commited: 0, commitSeqno: 0};
    if (actTheir != null) {
        their = actTheir.loadAny<FeeActionInput>();
    }

    // commit seqno for both states must be in sync, so we can check only one
    if (commitSeqno >= our.commitSeqno) {
        our.amount -= our.commited;
        their.amount -= their.commited;
    }

    var amt = our.amount - their.amount;
    if (amt <= 0) {
        return;
    }

    var vault: VaultData;
    if (vaultA != null && isExecutedAtA) {
        vault = VaultData.fromCell(vaultA);
    } else if (vaultB != null && !isExecutedAtA) {
        vault = VaultData.fromCell(vaultB);
    } else {
        throw 300;
    }

    createMessage({
        bounce: false,
        dest: vault.address,
        value: ton("0.015"),
        body: InternalSignedSenderRequest{
            signature: vault.signature.load(),
            message: createMessage({
                bounce: false,
                dest: vault.target,
                value: amt,
                body: beginCell().storeUint(0,32),
            }).toCell(),
        },
    }).send(SEND_MODE_REGULAR | SEND_MODE_IGNORE_ERRORS);
}

@method_id(51)
fun action_ec_vault(commitSeqno: int, actOur: slice, actTheir: slice?, isExecutedAtA: bool, vaultA: cell?, vaultB: cell?, ecId: int): void {
    var our = actOur.loadAny<FeeActionInput>();
    var their = FeeActionInput{amount: 0, commited: 0, commitSeqno: 0};
    if (actTheir != null) {
        their = actTheir.loadAny<FeeActionInput>();
    }

    // commit seqno for both states must be in sync, so we can check only one
    if (commitSeqno >= our.commitSeqno) {
        our.amount -= our.commited;
        their.amount -= their.commited;
    }

    var amt = our.amount - their.amount;
    if (amt <= 0) {
        return;
    }

    var vault: VaultData;
    if (vaultA != null && isExecutedAtA) {
        vault = VaultData.fromCell(vaultA);
    } else if (vaultB != null && !isExecutedAtA) {
        vault = VaultData.fromCell(vaultB);
    } else {
        throw 300;
    }

    var currenciesToSend: dict = createEmptyDict();
    currenciesToSend.uDictSetBuilder(32, ecId, beginCell().storeVarUInt32(amt));

    createMessage({
        bounce: false,
        dest: vault.address,
        value: FEE_EC_PAYOUT,
        body: InternalSignedSenderRequest{
            signature: vault.signature.load(),
            message: createMessage({
                bounce: false,
                dest: vault.target,
                value: (FEE_EC_PAYOUT, currenciesToSend),
                body: beginCell().storeUint(0,32),
            }).toCell(),
        },
    }).send(SEND_MODE_REGULAR | SEND_MODE_IGNORE_ERRORS);
}


@method_id(52)
fun action_jetton_vault(commitSeqno: int, actOur: slice, actTheir: slice?, isExecutedAtA: bool, vaultA: cell?, vaultB: cell?, jettonRoot: address, jettonWalletA: address, jettonWalletB: address): void {
    var our = actOur.loadAny<FeeActionInput>();
    var their = FeeActionInput{amount: 0, commited: 0, commitSeqno: 0};
    if (actTheir != null) {
        their = actTheir.loadAny<FeeActionInput>();
    }

    // commit seqno for both states must be in sync, so we can check only one
    if (commitSeqno >= our.commitSeqno) {
        our.amount -= our.commited;
        their.amount -= their.commited;
    }

    var amt = our.amount - their.amount;
    if (amt <= 0) {
        return;
    }

    var vault: VaultData;
    if (vaultA != null && isExecutedAtA) {
        vault = VaultData.fromCell(vaultA);
    } else if (vaultB != null && !isExecutedAtA) {
        vault = VaultData.fromCell(vaultB);
    } else {
        throw 300;
    }

    createMessage({
        bounce: false,
        dest: vault.address,
        value: ton("0.04"),
        body: InternalSignedSenderRequest{
            signature: vault.signature.load(),
            message: createMessage({
                bounce: false,
                dest: isExecutedAtA ? jettonWalletA : jettonWalletB,
                value: ton("0.05"),
                body: AskToTransfer {
                    queryId: 0,
                    jettonAmount: amt,
                    customPayload: null,
                    transferRecipient: vault.target,
                    sendExcessesTo: vault.address,
                    forwardTonAmount: 1,
                    forwardPayload: beginCell().storeUint(0,32)
                },
            }).toCell(),
        },
    }).send(SEND_MODE_REGULAR | SEND_MODE_IGNORE_ERRORS);
}