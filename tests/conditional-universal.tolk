import "@stdlib/tvm-dicts"

fun main() {
}

struct FeeActionInput {
    amount: coins
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
fun conditional_ton(targetActionsInput: dict, condInput: slice, actionHash: int, fee: int, capacity: int, prepaid: int, deadline: int, key: int): dict {
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
fun action_coins(actOur: slice, actTheir: slice, isA: bool, addressA: address, addressB: address, body: cell): void {
    var our = actOur.loadAny<FeeActionInput>();
    var their = actTheir.loadAny<FeeActionInput>();
    var amt = our.amount - their.amount;

    if (amt <= 0) {
        return;
    }

    createMessage({
        bounce: false,
        dest: isA ? addressA : addressB,
        value: amt,
        body: body,
    }).send(SEND_MODE_REGULAR | SEND_MODE_IGNORE_ERRORS);
}
