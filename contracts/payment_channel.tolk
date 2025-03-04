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
  payment_conf#_  excess_fee:Coins
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
fun castTo_S2I(c: continuation): (slice -> int)
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

// init channel
// cooperative close
// cooperative commit
// uncooperative close
// challenge quarantined state
// finish uncooperative close

global inited: bool;
global balance_A: int;
global balance_B: int;
global key_A: int;
global key_B: int;
global channel_id: int;
global closure_config: tuple;
global commited_seqno_A: int;
global commited_seqno_B: int;
global quarantin: cell;
global payment_config: cell;
global unparsed_storage: slice;
global storage_parse_level: int;

const `error::already_inited` = 100;
const `error::not_authorized` = 101;
const `error::not_enough_money_for_init` = 102;
const `error::wrong_tag` = 104;
const `error::outdated_state` = 105;
const `error::quarantin_already_active` = 106;
const `error::no_quarantined_state` = 107;
const `error::seqno_regress` = 108;
const `error::quarantine_already_challenged` = 115;
const `error::unauthorized_challenge` = 109;
const `error::quarantin_not_finished` = 110;
const `error::too_late_for_quarantin_challenge` = 111;
const `error::too_late_to_settle_conditionals` = 112;
const `error::too_early_to_close` = 113;
const `error::wrong_channel_id` = 114;
const `error::incorrect_conditionals_proof` = 115;
const `error::incorrect_updated_proof` = 116;
const `error::not_inited` = 117;
const `error::not_enough_balance` = 118;


const `tag::init` = 0x696e6974;
const `tag::cooperative_close` = 0x436c6f73;
const `tag::cooperative_commit` = 0x43436d74;
const `tag::start_uncooperative_close` = 0x556e436c;
const `tag::challenge_state` = 0x43686751;
const `tag::settle_conditionals` = 0x436c436e;
const `tag::state` = 0x43685374;

const `storage::full` = 4;
const `storage::up_to_quarantin` = 3;
const `storage::up_to_closure_config` = 1;
const `storage::balances_and_keys` = 0;

const `op::top_up_balance` = "top_up_balance add_A:Coins add_B:Coins = InternalMsgBody"c;
const `op::init_channel` = "init_channel is_A:Bool signature:bits512 tag:# = tag 1768843636 channel_id:uint128 balance_A:Coins balance_B:Coins = InternalMsgBody"c;
const `op::cooperative_close` = "cooperative_close sig_A:^bits512 sig_B:^bits512 tag:# = tag 1131179891 channel_id:uint128 balance_A:Coins balance_B:Coins seqno_A:uint64 seqno_B:uint64 = InternalMsgBody"c;
const `op::cooperative_commit` = "cooperative_commit sig_A:^bits512 sig_B:^bits512 tag:# = tag 1128492404 channel_id:uint128 seqno_A:uint64 seqno_B:uint64 = InternalMsgBody"c;
const `op::start_uncooperative_close` = "start_uncooperative_close signed_by_A:Bool signature:bits512 tag:# = tag 1433289580 channel_id:uint128 sch_A:^SignedSemiChannel sch_B:^SignedSemiChannel = InternalMsgBody"c;
const `op::challenge_quarantined_state` = "challenge_quarantined_state challenged_by_A:Bool signature:bits512 tag:# = tag 1130915665 channel_id:uint128 sch_A:^SignedSemiChannel sch_B:^SignedSemiChannel = InternalMsgBody"c;
const `op::settle_conditionals` = "settle_conditionals from_A:Bool signature:bits512 tag:# = tag 1131168622 channel_id:uint128 conditionals_to_settle:HashmapE 32 Cell = InternalMsgBody"c;
const `op::finish_uncooperative_close` = "finish_uncooperative_close = InternalMsgBody"c;
const `op::channel_closed` = "channel_closed channel_id:uint128 = InternalMsgBody"c;
const `op::channel_withdraw` = "channel_withdraw channel_id:uint128 = InternalMsgBody"c;



fun loadClosureConfig(mutate self: slice): void {
    var conf: slice = self.loadRef().beginParse();
    closure_config = tTriple(conf.loadUint(32), conf.loadCoins(), conf.loadUint(32));
    return;
}

@inline
fun `closure_config::quarantin_duration`(): int {
    return closure_config.tupleFirst();
}
@inline
fun `closure_config::misbehavior_fine`(): int {
    return closure_config.2;
}
@inline
fun `closure_config::conditional_close_duration`(): int {
    return closure_config.3;
}

fun storeClosureConfig(b: builder): builder {
    return b.storeRef(beginCell()
        .storeUint(`closure_config::quarantin_duration`(), 32)
        .storeCoins(`closure_config::misbehavior_fine`())
        .storeUint(`closure_config::conditional_close_duration`(), 32)
        .endCell()
    );
}

fun loadStorage(level: int) {
    storage_parse_level = level;
    var cs: slice = getContractData().beginParse();
    inited = cs.loadInt(1) == 1;
    balance_A = cs.loadCoins();
    balance_B = cs.loadCoins();
    key_A = cs.loadUint(256);
    key_B = cs.loadUint(256);
    channel_id = cs.loadUint(128);
    cs.loadClosureConfig();
    if(level >= `storage::up_to_quarantin`) {
        commited_seqno_A = cs.loadUint(32);
        commited_seqno_B = cs.loadUint(32);
        quarantin = cs.loadMaybeRef();
    }
    if(level >= `storage::full`) {
        payment_config = cs.loadRef();
    }
    unparsed_storage = cs;
}

fun saveStorage() {
    var level: int = storage_parse_level;
    var storage: builder = beginCell();
    storage = storage.storeBool(inited)
        .storeCoins(balance_A)
        .storeCoins(balance_B)
        .storeUint(key_A, 256)
        .storeUint(key_B, 256)
        .storeUint(channel_id, 128)
        .storeClosureConfig();
    if(level >= `storage::up_to_quarantin`) {
        storage = storage.storeUint(commited_seqno_A, 32)
            .storeUint(commited_seqno_B, 32)
            .storeMaybeRef(quarantin);
    }
    if(level >= `storage::full`){
        storage = storage.storeRef(payment_config);
    } else {
        storage = storage.storeSlice(unparsed_storage);
    }
    setContractData(storage.endCell());
}

// top_up_balance is_A:Bool amount:Coins = InternalMsgBody;
fun topUpBalance(amount: int, msg: slice) {
    loadStorage(`storage::balances_and_keys`);
    assert(inited) throw `error::not_inited`;

    var is_A: bool = msg.loadBool();
    if (is_A) {
        assert(balance_A <= amount) throw `error::not_enough_money_for_init`;
        balance_A += msg.loadCoins();
    } else {
        assert(balance_B <= amount) throw `error::not_enough_money_for_init`;
        balance_B += msg.loadCoins();
    }

    return saveStorage();
}

// init_channel is_A:Bool signature:bits512 tag:# {tag = 0x696e6974} channel_id:uint128 balance_A:Coins balance_B:Coins = InternalMsgBody;
fun initChannel(contractBalance: int, msg: slice) {
    loadStorage(`storage::full`);
    assert(!inited) throw `error::already_inited`;
    var is_A: int = msg.loadInt(1);
    var signature: slice = msg.loadBits(512);
    assert(isSignatureValid(sliceHash(msg), signature, is_A ? key_A : key_B)) throw `error::not_authorized`;
    assert(msg.loadUint(32) == `tag::init`) throw `error::wrong_tag`;
    assert(channel_id == msg.loadUint(128)) throw `error::wrong_channel_id`;
    var setBalance_A: int = msg.loadCoins();
    var setBalance_B: int = msg.loadCoins();
    assert((setBalance_A >= balance_A) &
    (setBalance_B >= balance_B)) throw `error::not_enough_money_for_init`;
    balance_A = setBalance_A;
    balance_B = setBalance_B;
    var pcs: slice = payment_config.beginParse();
    var excessFee: int = pcs.loadCoins();
    assert(balance_A + balance_B + excessFee < contractBalance) throw `error::not_enough_money_for_init`;
    inited = true;
    return saveStorage();
}

fun sendPayout(sAddr: slice, amount: int, channelId: int, op: int, flags: int) {
    sendMessage(beginCell()
        // see "Message X" description in crypto/block/block.tlb
        // or https://ton.org/docs/#/smart-contracts/messages?id=sending-messages
        .storeUint(0x10, 6)                          // 0x10 = 0b010000 = {0, 1, 0 , 0, 00}
        // First 0 means int_msg_info$0 tag
        // 1 0 0 are flags (ihr_disabled, bounce, bounced)
        // 00 is a source address addr_none$00 tag,
        // correct value added automatically
        .storeSlice(sAddr)                          // destination address
        .storeCoins(amount)                          // stake value
        .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1 + 1)   // 1 zero bit means there is no other:ExtraCurrencyCollection
        // 4 + 4 zero bits for empty ihr_fee:Grams and fwd_fee:Grams,
        // correct values added automatically
        // 64 + 32 zero bits for created_lt:uint64 and created_at:uint32,
        // correct values added automatically, see "CommonMsgInfo" description
        // 1 zero bit means there is no StateInit structure
        // 1 zero bit means the message body is represented
        // in this cell, not in reference
        // The following bits are the message body
        .storeUint(op, 32)
        .storeUint(channelId, 128)
        .endCell(), flags);
}

fun withdraw(a: int, b: int) {
    var pcs: slice = payment_config.beginParse();
    var excessFee: int = pcs.loadCoins();
    var (addr_A: slice, addr_B: slice) = (pcs.loadAddress(), pcs.loadAddress());

    if (b > 0) {
        balance_B -= b;
        assert(balance_B >= 0, `error::not_enough_balance`);
        sendPayout(addr_B, b, channel_id, `op::channel_withdraw`, 2);
    }

    if (a > 0) {
        balance_A -= a;
        assert(balance_A >= 0, `error::not_enough_balance`);
        sendPayout(addr_A, a, channel_id, `op::channel_withdraw`, 2);
    }
}


fun closeChannel() {
    var pcs: slice = payment_config.beginParse();
    var excessFee: int = pcs.loadCoins();
    var (addr_A: slice, addr_B: slice) = (pcs.loadAddress(), pcs.loadAddress());
    var totalContractBalance: int = getMyOriginalBalance();
    var mode_B: int = 2;  // in case balance_B less than forward fees
    if(balance_B > totalContractBalance) {
        mode_B = 128;
    }
    sendPayout(addr_B, balance_B, channel_id, `op::channel_closed`, mode_B);
    sendPayout(addr_A, balance_A, channel_id, `op::channel_closed`, 2 + 128);

    // while channel contract will be emptied it will survive for some time
    // by clearing storage we allow immediately reopen channel with the same configs
    inited = false;
    balance_A = 0;
    balance_B = 0;
    quarantin = null;
    saveStorage();
}

// cooperative_close sig_A:^bits512 sig_B:^bits512 tag:# {tag = 0x436c6f73} channel_id:uint128 balance_A:Coins balance_B:Coins seqno_A:uint64 seqno_B:uint64 = InternalMsgBody;
fun cooperativeClose(msg: slice) {
    loadStorage(`storage::full`);
    var sig_A: slice = msg.loadRef().beginParse();
    var sig_B: slice = msg.loadRef().beginParse();
    var hash: int = sliceHash(msg);
    assert(msg.loadUint(32) == `tag::cooperative_close`) throw `error::wrong_tag`;
    assert(channel_id == msg.loadUint(128)) throw `error::wrong_channel_id`;
    assert(isSignatureValid(hash, sig_A, key_A) &
    isSignatureValid(hash, sig_B, key_B)) throw `error::not_authorized`;
    balance_A = msg.loadCoins();
    balance_B = msg.loadCoins();
    var newSeqno_A: int = msg.loadUint(64);
    var newSeqno_B: int = msg.loadUint(64);
    assert((commited_seqno_A < newSeqno_A) &
    (commited_seqno_B < newSeqno_B)) throw `error::seqno_regress`;
    commited_seqno_A = newSeqno_A;
    commited_seqno_B = newSeqno_B;
    acceptExternalMessage();
    closeChannel();
}

// cooperative_commit sig_A:^bits512 sig_B:^bits512 tag:# {tag = 0x43436d74} channel_id:uint128 seqno_A:uint64 seqno_B:uint64 withdraw_A:Coins withdraw_B:Coins = InternalMsgBody;
fun cooperativeCommit(msg: slice) {
    loadStorage(`storage::up_to_quarantin`);
    var sig_A: slice = msg.loadRef().beginParse();
    var sig_B: slice = msg.loadRef().beginParse();
    var hash: int = sliceHash(msg);
    assert(msg.loadUint(32) == `tag::cooperative_commit`) throw `error::wrong_tag`;
    assert(channel_id == msg.loadUint(128)) throw `error::wrong_channel_id`;
    assert(isSignatureValid(hash, sig_A, key_A) &
    isSignatureValid(hash, sig_B, key_B)) throw `error::not_authorized`;

    var newSeqno_A: int = msg.loadUint(64);
    var newSeqno_B: int = msg.loadUint(64);
    assert((commited_seqno_A < newSeqno_A) &
    (commited_seqno_B < newSeqno_B)) throw `error::seqno_regress`;
    commited_seqno_A = newSeqno_A;
    commited_seqno_B = newSeqno_B;

    if (!(quarantin == null)) {
        var storedStates: slice = quarantin.beginParse();
        var (storedSeqno_A: int, storedSent_A: int) = (storedStates.loadUint(64), storedStates.loadCoins());
        storedStates.skipBits(1);
        var (storedSeqno_B: int, storedSent_B: int) = (storedStates.loadUint(64), storedStates.loadCoins());
        if((newSeqno_A > storedSeqno_A) | (newSeqno_B > storedSeqno_B)) {
            // quarantinned state is older than newly commited one, drop it
            quarantin = null;
        }
    }

    var withdraw_A: int = msg.loadCoins();
    var withdraw_B: int = msg.loadCoins();

    acceptExternalMessage();

    if ((withdraw_A | withdraw_B) > 0) {
        withdraw(withdraw_A, withdraw_B);
    }

    saveStorage();
}


// sc_body#_ seqno:uint64 sent:Coins conditionals_hash:uint256
//        = SemiChannelBody; // 64+132+256 = 452
// semichannel_state#43685374 channel_id:uint128 data:SemiChannelBody counterparty_data:(Maybe ^SemiChannelBody)
//        = SemiChannel; // 32 + 128 + 452 + 1 = 613
// (cs, (seqno, sent, condtionals))
@inline
fun parseSemichannelData(mutate self: slice): (int, int, int) {
    assert(self.loadUint(32) == `tag::state`) throw `error::wrong_tag`;
    assert(channel_id == self.loadUint(128)) throw `error::wrong_channel_id`;
    var res: (int, int, int) = (self.loadUint(64), self.loadCoins(), self.loadUint(256));
    return res;
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

// At this stage we only make basic checks and save proposed state
// This state will be quarantined for some time (set in channel config)
// during which it can be challenged by counterparty.
// We check the following:
//   a) semistates are signed by corresponding party
//   b) counterparty_state are in each semistate is not worse than other semistate
//
//  signed_schs#_ signature:bits512 state:^SemiChannel = SignedSemiChannel;
// start_uncooperative_close signed_by_A:Bool signature:bits512 tag:# {tag = 0x556e436c} channel_id:uint128
//                     sch_A:^SignedSemiChannel
//                     sch_B:^SignedSemiChannel = InternalMsgBody;
fun startUncooperativeClose(msg: slice) {
    loadStorage(`storage::up_to_quarantin`);

    assert((quarantin == null)) throw `error::quarantin_already_active`;
    var signedBy_A: int = msg.loadInt(1);
    var signature: slice = msg.loadBits(512);
    assert(isSignatureValid(sliceHash(msg), signature, signedBy_A ? key_A : key_B)) throw `error::not_authorized`;
    assert(msg.loadUint(32) == `tag::start_uncooperative_close`) throw `error::wrong_tag`;
    assert(channel_id == msg.loadUint(128)) throw `error::wrong_channel_id`;

    var semiChannel_A: slice = msg.loadRef().beginParse();
    var signature_A: slice = semiChannel_A.loadBits(512);
    var semiChannelState_A: cell = semiChannel_A.preloadRef();
    assert(isSignatureValid(cellHash(semiChannelState_A), signature_A, key_A)) throw `error::not_authorized`;
    var state_A: slice = semiChannelState_A.beginParse();

    var semiChannel_B: slice = msg.loadRef().beginParse();
    var signature_B: slice = semiChannel_B.loadBits(512);
    var semiChannelState_B: cell = semiChannel_B.preloadRef();
    assert(isSignatureValid(cellHash(semiChannelState_B), signature_B, key_B)) throw `error::not_authorized`;
    var state_B: slice = semiChannelState_B.beginParse();

    var (seqno_A: int, sent_A: int, conditionalsHash_A: int) = state_A.parseSemichannelData();
    var (seqno_BRef_A: int, sent_BRef_A: int, _) = state_A.parseMaybeSemichannelBody();

    var (seqno_B: int, sent_B: int, conditionalsHash_B: int) = state_B.parseSemichannelData();
    var (seqno_ARef_B: int, sent_ARef_B: int, _)= state_B.parseMaybeSemichannelBody();

    assert((seqno_A >= commited_seqno_A) &
    (seqno_B >= commited_seqno_B) &
    (seqno_B >= seqno_BRef_A) &
    (seqno_A >= seqno_ARef_B) &
    (sent_B >= sent_BRef_A) &
    (sent_A >= sent_ARef_B)) throw `error::outdated_state`;

    quarantin = beginCell()
        .storeUint(seqno_A, 64).storeCoins(sent_A).storeUint(conditionalsHash_A, 256)
        .storeUint(seqno_B, 64).storeCoins(sent_B).storeUint(conditionalsHash_B, 256)
        .storeUint(now(), 32)
        .storeInt(signedBy_A, 1)
        .storeBool(false)
        .endCell();

    acceptExternalMessage();
    saveStorage();
}

// Logic is close to that in uncooperative_close:
// we make the same checks and then that new proposed state
// contains higher seqnos than quarantined state
// In that case we fine previous commiter and set new state
//  challenge_quarantined_state#_
//                        challenged_by_A:Bool signature:bits512 tag:uint32 {tag = 0x43686751} channel_id:uint128
//                        sch_A:^SignedSemiChannel
//                        sch_B:^SignedSemiChannel = ChallengeState;
fun challengeQuarantinedState(msg: slice) {
    loadStorage(`storage::up_to_quarantin`);
    assert(quarantin != null) throw `error::no_quarantined_state`;

    // Start with the same checks
    var challengedBy_A: int = msg.loadInt(1);
    var signature: slice = msg.loadBits(512);
    assert(isSignatureValid(sliceHash(msg), signature, challengedBy_A ? key_A : key_B)) throw `error::not_authorized`;
    assert(msg.loadUint(32) == `tag::challenge_state`) throw `error::wrong_tag`;
    assert(channel_id == msg.loadUint(128)) throw `error::wrong_channel_id`;

    var semiChannel_A: slice = msg.loadRef().beginParse();
    var signature_A: slice = semiChannel_A.loadBits(512);
    var semiChannelState_A: cell = semiChannel_A.preloadRef();
    assert(isSignatureValid(cellHash(semiChannelState_A), signature_A, key_A)) throw `error::not_authorized`;
    var state_A: slice = semiChannelState_A.beginParse();

    var semiChannel_B: slice = msg.loadRef().beginParse();
    var signature_B: slice = semiChannel_B.loadBits(512);
    var semiChannelState_B: cell = semiChannel_B.preloadRef();
    assert(isSignatureValid(cellHash(semiChannelState_B), signature_B, key_B)) throw `error::not_authorized`;
    var state_B: slice = semiChannelState_B.beginParse();

    var (seqno_A: int, sent_A: int, conditionalsHash_A: int) = state_A.parseSemichannelData();
    var (seqno_BRef_A: int, sent_BRef_A: int, _) = state_A.parseMaybeSemichannelBody();

    var (seqno_B: int, sent_B: int, conditionalsHash_B: int) = state_B.parseSemichannelData();
    var (seqno_ARef_B: int, sent_ARef_B: int, _) = state_B.parseMaybeSemichannelBody();

    assert((seqno_B >= seqno_BRef_A) &
    (seqno_A >= seqno_ARef_B) &
    (seqno_B >= commited_seqno_B) &
    (seqno_A >= commited_seqno_A) &
    (sent_B >= sent_BRef_A) &
    (sent_A >= sent_ARef_B)) throw `error::outdated_state`;
    if(seqno_BRef_A > 0) {
        assert((seqno_BRef_A >= commited_seqno_B)) throw `error::outdated_state`;
    }
    if(seqno_ARef_B > 0) {
        assert((seqno_ARef_B >= commited_seqno_A)) throw `error::outdated_state`;
    }
    var storedStates: slice = quarantin.beginParse();
    var (storedSeqno_A: int, storedSent_A: int) = (storedStates.loadUint(64), storedStates.loadCoins());
    var storedConditionalsHash_A: int = storedStates.loadUint(256);

    var (storedSeqno_B: int, storedSent_B: int) = (storedStates.loadUint(64), storedStates.loadCoins());
    var storedConditionalsHash_B: int = storedStates.loadUint(256);

    var quarantineStarted: int = storedStates.loadUint(32);
    assert(quarantineStarted + `closure_config::quarantin_duration`() > now()) throw `error::too_late_for_quarantin_challenge`;

    var prevSignedBy_A: int = storedStates.loadInt(1);
    var quarantineChallenged: int = storedStates.loadInt(1);
    assert(~ quarantineChallenged) throw `error::quarantine_already_challenged`;

    // misbehvaior is when party which committed outdated state
    // or regenerate latest state with lower sent
    var misbehaviorDetected: bool = false;
    if(prevSignedBy_A) {
        misbehaviorDetected = (seqno_A > storedSeqno_A) | (sent_A > storedSent_A);
        storedSeqno_A = seqno_A;
        storedSent_A = sent_A;
        storedConditionalsHash_A = conditionalsHash_A;
    } else {
        misbehaviorDetected = (seqno_B > storedSeqno_B) | (sent_B > storedSent_B);
        storedSeqno_B = seqno_B;
        storedSent_B = sent_B;
        storedConditionalsHash_B = conditionalsHash_B;
    }
    // only counterparty can report misbehavior
    assert(prevSignedBy_A != challengedBy_A) throw `error::unauthorized_challenge`;

    if(misbehaviorDetected) {
        // add fine to sent
        if(prevSignedBy_A) {
            storedSent_A += `closure_config::misbehavior_fine`();
        } else {
            storedSent_B += `closure_config::misbehavior_fine`();
        }
    }

    quarantin = beginCell()
        .storeUint(storedSeqno_A, 64).storeCoins(storedSent_A).storeUint(storedConditionalsHash_A, 256)
        .storeUint(storedSeqno_B, 64).storeCoins(storedSent_B).storeUint(storedConditionalsHash_B, 256)
        .storeUint(quarantineStarted, 32)
        .storeInt(challengedBy_A, 1)
        .storeBool(true)
        .endCell();
    saveStorage();
}

// After state got out of quarantine we give some time to finish conditionals
// `A` has time to finish B's conditionals
// `B` has time to finish A's conditionals
//  settle_conditionals#_
//                        from_A:Bool signature:bits512 tag:uint32 {tag = 0x436c436e} channel_id:uint128
//                        conditionals_to_settle:(HashmapE 32 Cell) conditionals_proof:^Cell
//                        = FinishConditionals;
fun settleConditionals(msg: slice) {
    loadStorage(`storage::up_to_quarantin`);
    assert(quarantin != null) throw `error::no_quarantined_state`;
    var from_A: int = msg.loadInt(1);
    var signature: slice = msg.loadBits(512);
    assert(isSignatureValid(sliceHash(msg), signature, from_A ? key_A : key_B)) throw `error::not_authorized`;
    assert(msg.loadUint(32) == `tag::settle_conditionals`) throw `error::wrong_tag`;
    assert(channel_id == msg.loadUint(128)) throw `error::wrong_channel_id`;
    var conditionalsToSettle: cell = msg.loadDict();
    var conditionalsProof: cell = msg.loadRef();

    var storedStates: slice = quarantin.beginParse();
    var (seqno_A: int, sent_A: int, conditionalsHash_A: int) =
    (storedStates.loadUint(64), storedStates.loadCoins(), storedStates.loadUint(256));

    var (seqno_B: int, sent_B: int, conditionalsHash_B: int) =
    (storedStates.loadUint(64), storedStates.loadCoins(), storedStates.loadUint(256));

    var quarantineStarted: int = storedStates.loadUint(32);
    var quarantineFinished: int = quarantineStarted + `closure_config::quarantin_duration`();
    assert(quarantineFinished < now()) throw `error::quarantin_not_finished`;
    assert(quarantineFinished + `closure_config::conditional_close_duration`() > now()) throw `error::too_late_to_settle_conditionals`;

    var stateCommitedBy_A: int = storedStates.loadInt(1);
    var challenged: int = storedStates.loadInt(1);
    var (targetHash: int, targetSent: int) = (conditionalsHash_A, sent_A);
    if(from_A) {
        (targetHash, targetSent) = (conditionalsHash_B, sent_B);
    }

    var (csProof: slice, special: int) = conditionalsProof.beginParseSpecial();
    assert(!(~ special)) throw `error::incorrect_conditionals_proof`;
    assert(!(csProof.loadUint(8) != 3)) throw `error::incorrect_conditionals_proof`;
    assert(!(csProof.preloadUint(256) != targetHash)) throw `error::incorrect_conditionals_proof`;
    var target: cell = csProof.preloadRef();

    var continuee: bool = true;
    do {
        var (cid: int, input: slice, continuee redef) = conditionalsToSettle.uDictDeleteFirstAndGet(32);
        if(continuee) {
            var empty: slice = emptySlice();
            var (target redef, condition: slice, ok: int) = target.isUdictReplaceGet(32, cid, empty);
            assert(ok) throw `error::incorrect_conditionals_proof`;
            var executableCondition = castTo_S2I(condition.transformSliceToContinuation());
            // NOTE! It seems dangerous to run unknown code and it really is!
            // However, runned code is signed by one party and executed by another
            // That way both party authorized it.
            // Obviously, B should not sign incorrect code which (for instance) sends all money to A
            // The same way A should not run incorrect code which sends all money to B.
            targetSent += executableCondition(input);
        }
    } while (continuee);

    if(from_A) {
        (conditionalsHash_B, sent_B) = (proofHash(target), targetSent);
    } else {
        (conditionalsHash_A, sent_A) = (proofHash(target), targetSent);
    }

    quarantin = beginCell()
        .storeUint(seqno_A, 64).storeCoins(sent_A).storeUint(conditionalsHash_A, 256)
        .storeUint(seqno_B, 64).storeCoins(sent_B).storeUint(conditionalsHash_B, 256)
        .storeUint(quarantineStarted, 32)
        .storeInt(stateCommitedBy_A, 1)
        .storeInt(challenged, 1)
        .endCell();
    saveStorage();
}

fun finishUncooperativeClose() {
    loadStorage(`storage::full`);
    assert(quarantin != null) throw `error::no_quarantined_state`;
    var storedStates: slice = quarantin.beginParse();
    var (seqno_A: int, sent_A: int, conditionalsHash_A: int) =
    (storedStates.loadUint(64), storedStates.loadCoins(), storedStates.loadUint(256));
    var (seqno_B: int, sent_B: int, conditionalsHash_B: int) =
    (storedStates.loadUint(64), storedStates.loadCoins(), storedStates.loadUint(256));
    var quarantineStarted: int = storedStates.loadUint(32);
    assert(quarantineStarted +
    `closure_config::quarantin_duration`() +
    `closure_config::conditional_close_duration`() < now()) throw `error::too_early_to_close`;
    acceptExternalMessage();
    balance_A = balance_A + sent_B - sent_A;
    balance_B = balance_B + sent_A - sent_B;
    if(balance_B < 0) {
        balance_A += balance_B;
        balance_B = 0;
    }
    if(balance_A < 0) {
        balance_B += balance_A;
        balance_B = 0;
    }
    commited_seqno_A = seqno_A + 1;
    commited_seqno_B = seqno_B + 1;
    closeChannel();
}

fun recvAny(contractBalance: int, msg: slice) {
    // Note, operators of channels are always off-chain parties, not contracts
    // thus no responses and query_ids
    var op: int = msg.loadUint(32);
    if(op == `op::top_up_balance`) {
        return topUpBalance(contractBalance, msg);
    } else if(op == `op::init_channel`) {
        return initChannel(contractBalance, msg);
    } else if (op == `op::cooperative_close`){
        return cooperativeClose(msg);
    } else if (op == `op::cooperative_commit`){
        return cooperativeCommit(msg);
    } else if (op == `op::start_uncooperative_close`){
        return startUncooperativeClose(msg);
    } else if (op == `op::challenge_quarantined_state`){
        return challengeQuarantinedState(msg);
    } else if (op == `op::settle_conditionals`){
        return settleConditionals(msg);
    } else if (op == `op::finish_uncooperative_close`){
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

const `state::UNINITED` = 0;
const `state::OPEN` = 1;
const `state::CLOSURE_STARTED` = 2;
const `state::SETTLING_CONDITIONALS` = 3;
const `state::AWAITING_FINALIZATION` = 4;

get get_channel_state(): int {
    loadStorage(`storage::full`);
    if (! inited)  {
        return `state::UNINITED`;
    }
    if((quarantin == null)) {
        return `state::OPEN`;
    }
    var storedStates: slice = quarantin.beginParse();
    storedStates.skipBits(64);
    storedStates.loadCoins();
    storedStates.skipBits(1 + 64);
    storedStates.loadCoins();
    storedStates.skipBits(1);
    var quarantineStarted: int = storedStates.loadUint(32);
    if (quarantineStarted + `closure_config::quarantin_duration`() > now()) {
        return `state::CLOSURE_STARTED`;
    }
    if (quarantineStarted +
    `closure_config::quarantin_duration`() +
    `closure_config::conditional_close_duration`() > now()) {
        return `state::SETTLING_CONDITIONALS`;
    }
    return `state::AWAITING_FINALIZATION`;
}

get get_channel_data() {
    loadStorage(`storage::full`);
    var pcs: slice = payment_config.beginParse();
    var excessFee: int = pcs.loadCoins();
    var (addr_A: slice, addr_B: slice) = (pcs.loadAddress(), pcs.loadAddress());

    return (get_channel_state(),
        [balance_A, balance_B],
        [key_A, key_B],
        channel_id,
        closure_config,
        [commited_seqno_A, commited_seqno_B],
        quarantin,
        [excessFee, addr_A, addr_B]);
}
