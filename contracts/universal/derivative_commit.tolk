import "@stdlib/tvm-dicts"
import "messages"
import "../errors"

struct Config {
    oracleKey: uint256
    quarantineDuration: uint32
    acceptionWindow: uint32
    addressA: address
    addressB: address
}

struct Storage {
    key: uint256
    config: Cell<Config>

    amount: coins
    leverage: uint16
    isLong: bool

    entryPrice: coins
    entryAt: uint32
    createdAt: uint32

    exitAt: uint32
    exitPrice: coins
    isLiquidated: bool

    quarantineTill: uint32
}

struct DerivativeResolve {
    key: uint256
    amount: coins
    at: uint32
}

struct (0x0f8a7ea5) ProxySettle {
    toA: bool
    msg: Cell<SettleConditionalsMessage>
}

struct (0x0f8a7ea6) Commit {
    entry: Cell<Price>
    exit: Cell<Price>
}
struct Price {
    signature: bits512
    signedBody: RemainingBitsAndRefs
}
struct (0x11223344) PriceProof {
    at: uint32
    price: coins
}

type AllowedMessages =
    | ProxySettle
    | Commit;

fun onInternalMessage(in: InMessage) {
    var data = lazy Storage.fromCell(contract.getData());
    var cfg = lazy Config.fromCell(data.config);

    var msg = lazy AllowedMessages.fromSlice(in.body);
    match(msg) {
        Commit => {
            var inEntry = msg.entry.load();
            var inExit  = msg.exit.load();

            assert(isSignatureValid(inEntry.signedBody.hash(), inEntry.signature as slice, cfg.oracleKey)) throw ERROR_NOT_AUTHORIZED;
            assert(isSignatureValid(inExit.signedBody.hash(), inExit.signature as slice, cfg.oracleKey)) throw ERROR_NOT_AUTHORIZED;
            var proofOpen = inEntry.signedBody.loadAny<PriceProof>();
            var proofClose = inExit.signedBody.loadAny<PriceProof>();

            var isFirstCommit = data.exitAt == 0;

            assert (proofOpen.at >= data.createdAt) throw ERROR_OUTDATED_STATE;
            assert (proofClose.at >= data.createdAt) throw ERROR_OUTDATED_STATE;
            assert (proofClose.at >= proofOpen.at) throw ERROR_OUTDATED_STATE;

            assert (data.entryAt == 0 || data.entryAt >= proofOpen.at) throw ERROR_OUTDATED_STATE;

            assert (!data.isLiquidated && (isFirstCommit || proofClose.at <= data.exitAt || proofOpen.at <= data.entryAt)) throw ERROR_OUTDATED_STATE;
            assert (abs(proofClose.at - blockchain.now()) <= cfg.acceptionWindow) throw ERROR_OUTDATED_STATE;

            // if entry time was incorect, we allow to change close time too

            data.entryAt = proofOpen.at;
            data.exitAt = proofClose.at;
            data.exitPrice = proofClose.price;

            var pnl = data.calculatePnL();
            data.isLiquidated = (pnl < 0) && (abs(pnl) >= data.amount);

            assert (isFirstCommit || data.isLiquidated) throw ERROR_ALREADY_INITED;

            data.quarantineTill = blockchain.now() + cfg.quarantineDuration;
            contract.setData(data.toCell());
        }
        ProxySettle => {
            assert(data.isLiquidated || (data.exitAt > 0 && data.quarantineTill < blockchain.now())) throw ERROR_TOO_EARLY_TO_EXECUTE_ACTION;

            var dest = cfg.addressA;
            var pnl = data.calculatePnL();
            if (!msg.toA) {
                pnl = -pnl;
                dest = cfg.addressB;
            }

            assert (pnl >= 0) throw ERROR_NOT_ENOUGH_BALANCE;

            var settle = msg.msg.load();
            var _ = settle.signedBody.loadAny<ChannelMessageId>();

            var body = settle.signedBody.loadAny<SettleConditionalsBody>();

            assert (body.expectedSender == contract.getAddress()) throw ERROR_NOT_AUTHORIZED;
            var (_, resolve, ok) = body.toSettle.uDictDeleteFirstAndGet(256);
            assert (resolve != null && ok) throw ERROR_NOTHING_TO_SETTLE;

            // should have only one key to settle, to avoid potential hacks
            assert (body.toSettle.dictIsEmpty()) throw ERROR_INVALID_MESSAGE_OPERATION;

            var res = resolve.loadAny<DerivativeResolve>();
            assert (res.key == data.key && res.amount == pnl && res.at == data.exitAt) throw ERROR_OUTDATED_STATE;

            createMessage({
                bounce: false,
                dest: dest,
                value: 0,
                body: msg.msg
            }).send(128);
        }
    }
}

fun Storage.calculatePnL(self): int {
    if (self.isLiquidated) {
        return -self.amount;
    }

    var priceDelta: int = 0;

    if (self.isLong) {
        priceDelta = self.exitPrice - self.entryPrice;
    } else {
        priceDelta = self.entryPrice - self.exitPrice;
    }

    // PnL = (Collateral * Leverage * PriceDelta) / EntryPrice
    val positionSize = ((self.amount * self.leverage) as int);
    val pnl = mulDivFloor(positionSize, priceDelta, (self.entryPrice as int));

    return pnl;
}

get fun pnl(): (int, bool) {
    var data = lazy Storage.fromCell(contract.getData());
    return (data.calculatePnL(), data.isLiquidated);
}