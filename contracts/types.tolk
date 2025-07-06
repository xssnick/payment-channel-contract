import "errors.tolk"
import "messages.tolk"

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

const STORAGE_FULL = 4;
const STORAGE_UP_TO_QUARANTINE = 3;
const STORAGE_UP_TO_CLOSURE_CONFIG = 1;
const STORAGE_BALANCES_AND_KEYS = 0;

const STATE_UNINITED = 0;
const STATE_OPEN = 1;
const STATE_CLOSURE_STARTED = 2;
const STATE_SETTLING_CONDITIONALS = 3;
const STATE_AWAITING_FINALIZATION = 4;

const FEE_JETTON_ACCEPT  = ton("0.035"); // 0.035
const FEE_JETTON_PAYOUT  = ton("0.08"); // 0.08
const FEE_JETTON_FORWARD = ton("0.03"); // 0.03
const FEE_EC_ACCEPT      = ton("0.025"); // 0.025
const FEE_EC_PAYOUT      = ton("0.03"); // 0.03
const FEE_TON_ACCEPT     = ton("0.03"); // 0.03
const FEE_MIN_BALANCE    = ton("0.01"); // 0.01
const FEE_COMMIT         = ton("0.03"); // 0.03
const FEE_JETTON_WALLET_PROVIDE = ton("0.03"); // 0.03

const CURRENCY_TYPE_TON = 0;
const CURRENCY_TYPE_EC = 1;
const CURRENCY_TYPE_JETTON = 2;
