import { Address, beginCell, Cell, Contract, contractAddress, ContractProvider, Dictionary, Sender, SendMode, Slice, toNano } from '@ton/core';
import { Op, Tags } from './Constants';
import { sign } from '@ton/crypto';
import { patchV5R1ActionsSendMode } from '@ton/ton/dist/wallets/WalletContractV5R1';

export type ClosureConfig =  {
    quarantineDuration: number;
    fine: bigint;
    closeDuration: number;
}

export type SemiChannelBody = {
    seqno: bigint;
    sent: bigint;
    conditionalsHash: Buffer
}

export type SemiChannel = {
    channelId: bigint,
    data: SemiChannelBody;
    counterpartyData?: SemiChannelBody;
}

export type Quarantine = {
    stateA: SemiChannelBody;
    stateB: SemiChannelBody;
    startedAt: number;
    committedbyA: boolean;
    challenged: boolean;
}

type PaymentConfigBase = {
    storageFee: bigint;
    addressA: Address;
    addressB: Address;
}

type PaymentConfigSimple = PaymentConfigBase & {
    customCurrency: false
}

type PaymentConfigCustomCurrencyJetton = PaymentConfigBase & {
    customCurrency: true;
    isJetton:true;
    jettonRoot: Address;
    jettonWallet: Address
};


type PaymentConfigCustomCurrencyExtra = PaymentConfigBase & {
    customCurrency: true;
    isJetton: false;
    extraId: number
}

export type PaymentConfig = PaymentConfigSimple | PaymentConfigCustomCurrencyJetton | PaymentConfigCustomCurrencyExtra;

export type Balance = {
    depositA: bigint;
    depositB: bigint;
    withdrawA: bigint;
    withdrawB: bigint;
    sentA: bigint;
    sentB: bigint;
}

export type BalanceCommit = {
    seqnoA: bigint,
    seqnoB: bigint,
    withdrawA: bigint;
    withdrawB: bigint;
    sentA: bigint;
    sentB: bigint;
}

export type SignedCommit = {
    commit: BalanceCommit | Cell,
    sigA: Buffer | Cell,
    sigB: Buffer | Cell
}

export type Channel = {
    inited: boolean;
    balance: Balance;
    keyA: bigint;
    keyB: bigint;
    id: bigint;
    closureConfig: ClosureConfig;
    commitedSeqnoA: bigint;
    commitedSeqnoB: bigint;

    quarantine?: Cell;
    paymentConfig: PaymentConfig;
}
export type PaymentChannelConfig = {
    keyA: Buffer;
    keyB: Buffer;
    id: bigint;
    closureConfig: ClosureConfig;
    quarantine?: Cell;
    paymentConfig: PaymentConfig;
};

function paymentConfigToCell(config: PaymentConfig) {
    const bs = beginCell().storeCoins(config.storageFee)
            .storeAddress(config.addressA)
            .storeAddress(config.addressB)
            .storeBit(config.customCurrency);

    if(config.customCurrency) {

        bs.storeBit(config.isJetton);

        if(config.isJetton) {
            bs.storeAddress(config.jettonRoot).storeAddress(config.jettonWallet);
        } else {
            bs.storeUint(config.extraId, 32);
        }
    }

    return bs.endCell();
}
export function parseSemiChannelBody(body: Cell | Slice): SemiChannelBody {
    const ds = body instanceof Cell ? body.beginParse() : body;
    return {
        seqno: ds.loadUintBig(64),
        sent: ds.loadCoins(),
        conditionalsHash: ds.loadBuffer(32)
    }
}
export function serializeSemiChannelBody(body: SemiChannelBody) {
    return beginCell()
            .storeUint(body.seqno, 64)
            .storeCoins(body.sent)
            .storeBuffer(body.conditionalsHash, 32)
          .endCell();
}
export function signSemiChannel(channel: SemiChannel, key: Buffer) {
    const semiChannel = beginCell()
                         .storeUint(Tags.TAG_STATE, 32)
                         .storeUint(channel.channelId, 128)
                         .storeSlice(serializeSemiChannelBody(channel.data).asSlice())
                         .storeMaybeRef(channel.counterpartyData ? serializeSemiChannelBody(channel.counterpartyData) : null)
                        .endCell();

    const sig = sign(semiChannel.hash(), key);

    return beginCell().storeBuffer(sig).storeRef(semiChannel).endCell();
}
export function parseSemiChannel(data: Cell | Slice): SemiChannel {
    const ds = data instanceof Cell ? data.beginParse() : data;
    const tag = ds.loadUint(32);
    if(tag !== Tags.TAG_STATE) {
        throw new TypeError("Invalid SemiChannel tag!");
    }
    const channelId = ds.loadUintBig(128)
    const myData = parseSemiChannelBody(ds);
    const counterpartyCell = ds.loadMaybeRef();

    return {
        channelId: channelId,
        data: myData,
        counterpartyData: counterpartyCell ? parseSemiChannelBody(counterpartyCell) : undefined
    }
}
export function parseQuarantine(data: Cell | Slice): Quarantine {
    const ds = data instanceof Cell ? data.beginParse() : data;

    return {
      stateA: parseSemiChannelBody(ds),
      stateB: parseSemiChannelBody(ds),
      startedAt: ds.loadUint(32),
      committedbyA: ds.loadBit(),
      challenged: ds.loadBit()
    }
}
function parseClosureCoinfg(config: Cell | Slice) : ClosureConfig {
    const ds = config instanceof Cell ? config.beginParse() : config;

    return {
        quarantineDuration: ds.loadUint(32),
        fine: ds.loadCoins(),
        closeDuration: ds.loadUint(32)
    }
}
function closureConfigToCell(config: ClosureConfig) {
    return beginCell()
            .storeUint(config.quarantineDuration, 32)
            .storeCoins(config.fine)
            .storeUint(config.closeDuration, 32)
           .endCell();
}
function balnceToCell(balance: Balance) {
    return beginCell()
            .storeCoins(balance.depositA)
            .storeCoins(balance.depositB)
            .storeCoins(balance.withdrawA)
            .storeCoins(balance.withdrawB)
            .storeCoins(balance.sentA)
            .storeCoins(balance.sentB)
          .endCell();
}

function emptyBalanceCell() {
    return balnceToCell({
        depositA: 0n,
        depositB: 0n,
        withdrawA: 0n,
        withdrawB: 0n,
        sentA: 0n,
        sentB: 0n
    });
}

export function paymentChannelConfigToCell(config: PaymentChannelConfig): Cell {
    return beginCell()
            .storeBit(false) // inited
            .storeRef(emptyBalanceCell())
            .storeBuffer(config.keyA, 32)
            .storeBuffer(config.keyB, 32)
            .storeUint(config.id, 128)
            .storeRef(closureConfigToCell(config.closureConfig))
            .storeUint(0, 32) // commitedSeqNoA
            .storeUint(0, 32) // commitedSeqNoB
            .storeMaybeRef(null) // No quarantine
            .storeRef(paymentConfigToCell(config.paymentConfig))
        .endCell();
}

export class PaymentChannel implements Contract {
    channelId: bigint | undefined;

    constructor(readonly address: Address, readonly init?: { code: Cell; data: Cell }, channelId?: bigint) {
        if(channelId) {
            this.channelId = channelId;
        }
    }
    setChannelId(channelId: bigint) {
        this.channelId = channelId;
    }

    static createFromAddress(address: Address, channelId: bigint) {
        return new PaymentChannel(address, undefined, channelId);
    }

    static createFromConfig(config: PaymentChannelConfig, code: Cell, workchain = 0) {
        const data = paymentChannelConfigToCell(config);
        const init = { code, data };
        return new PaymentChannel(contractAddress(workchain, init), init, config.id);
    }

    static channelInitMessage(isA: boolean, secretKey: Buffer, channelId: bigint) {
        const msgBody = beginCell().storeUint(Tags.TAG_INIT_CHANNEL, 32).storeUint(channelId, 128).endCell();
        return beginCell()
                .storeUint(Op.OP_INIT_CHANNEL, 32)
                .storeBit(isA)
                .storeBuffer(sign(msgBody.hash(), secretKey))
                .storeSlice(msgBody.asSlice())
               .endCell();
    }
    async sendDeploy(provider: ContractProvider, via: Sender, isA: boolean, secretKey: Buffer, value: bigint, channelId?: bigint) {
        const curId = channelId ?? this.channelId;
        if(!curId) {
            throw new Error("Channel id is required");
        }
        await provider.internal(via, {
            value,
            sendMode: SendMode.PAY_GAS_SEPARATELY,
            body: PaymentChannel.channelInitMessage(isA, secretKey, curId)
        });
    }

    async sendTopUp(provider: ContractProvider, via: Sender, isA: boolean, value: bigint) {
        await provider.internal(via, {
            value,
            sendMode: SendMode.PAY_GAS_SEPARATELY,
            body: beginCell().storeUint(Op.OP_TOP_UP_BALANCE, 32).storeBit(isA).endCell()
        });
    }

    static cooperativeCommitBody(commit: BalanceCommit, channelId: bigint) {
        return beginCell()
                   .storeUint(Tags.TAG_COOPERATIVE_COMMIT, 32)
                   .storeUint(channelId, 128)
                   .storeCoins(commit.sentA)
                   .storeCoins(commit.sentB)
                   .storeUint(commit.seqnoA, 64)
                   .storeUint(commit.seqnoB, 64)
                   .storeCoins(commit.withdrawA)
                   .storeCoins(commit.withdrawB)
               .endCell();
    }

    static cooperativeCommitMessage(commit: SignedCommit, channelId: bigint) {
        const msgBody = commit.commit instanceof Cell ? commit.commit : PaymentChannel.cooperativeCommitBody(commit.commit, channelId);

        const sigACell = Buffer.isBuffer(commit.sigA) ? beginCell().storeBuffer(commit.sigA).endCell() : commit.sigA;
        const sigBCell = Buffer.isBuffer(commit.sigB) ? beginCell().storeBuffer(commit.sigB).endCell() : commit.sigB;

        return beginCell()
                .storeUint(Op.OP_COOPERATIVE_COMMIT, 32)
                .storeSlice(msgBody.asSlice())
                .storeRef(sigACell)
                .storeRef(sigBCell)
               .endCell();
    }
    async sendCooperativeCommit(provider: ContractProvider, via: Sender, commit: SignedCommit, value: bigint = toNano('0.05'), channelId?: bigint) {
        const curId = channelId ?? this.channelId;
        if(!curId) {
            throw new Error("Channel id is required");
        }

        await provider.internal(via, {
            value,
            sendMode: SendMode.PAY_GAS_SEPARATELY,
            body: PaymentChannel.cooperativeCommitMessage(commit, curId)
        });
    }

    static uncooperativeCloseMessage(isA: boolean, signedStateA: Cell, signedStateB: Cell, key: Buffer, channelId: bigint) {
        const msgBody = beginCell()
                        .storeUint(Tags.TAG_START_UNCOOPERATIVE_CLOSE, 32)
                        .storeUint(channelId, 128)
                        .storeRef(signedStateA)
                        .storeRef(signedStateB)
                       .endCell();

        return beginCell().storeUint(Op.OP_START_UNCOOPERATIVE_CLOSE, 32)
                          .storeBit(isA)
                          .storeBuffer(sign(msgBody.hash(), key))
                          .storeSlice(msgBody.asSlice())
               .endCell();
    }

    async sendStartUncoopClose(provider: ContractProvider, via: Sender, opts: {isA: boolean, stateA: Cell, stateB: Cell, key: Buffer}, channelId?: bigint, value: bigint = toNano('0.05')) {
        const curId = channelId ?? this.channelId;

        if(!curId) {
            throw new Error("Channel id is required");
        }

        await provider.internal(via, {
            value,
            sendMode: SendMode.PAY_GAS_SEPARATELY,
            body: PaymentChannel.uncooperativeCloseMessage(opts.isA, opts.stateA, opts.stateB, opts.key, curId)
        });

    }

    static finishUncoopCloseMessage() {
        return beginCell().storeUint(Op.OP_FINISH_UNCOOPERATIVE_CLOSE, 32).endCell();
    }

    async sendFinishUncoopClose(provider: ContractProvider, via: Sender, value: bigint = toNano('0.05')) {
        await provider.internal(via, {
            value,
            sendMode: SendMode.PAY_GAS_SEPARATELY,
            body: PaymentChannel.finishUncoopCloseMessage()
        });
    }

    static settleConditionalsMessage(isA: boolean, conditionalsToSettle: Dictionary<number, bigint>, conditionalsProof: Cell, key: Buffer, channelId: bigint) {
        const msgBody = beginCell()
                        .storeUint(Tags.TAG_SETTLE_CONDITIONALS, 32)
                        .storeUint(channelId, 128)
                        .storeDict(conditionalsToSettle)
                        .storeRef(conditionalsProof)
                       .endCell();

        return beginCell().storeUint(Op.OP_SETTLE_CONDITIONALS, 32)
                          .storeBit(isA)
                          .storeBuffer(sign(msgBody.hash(), key))
                          .storeSlice(msgBody.asSlice())
               .endCell();

    }

    async sendSettleConditionals(provider: ContractProvider,
                                 via: Sender,
                                 opts: {isA: boolean, toSettle: Dictionary<number, bigint>, proof: Cell, key: Buffer},
                                 value: bigint = toNano('0.05'), channelId?: bigint) {
        const curId = channelId ?? this.channelId;

        if(!curId) {
            throw new Error("Channel id is required");
        }

        await provider.internal(via, {
            value,
            sendMode: SendMode.PAY_GAS_SEPARATELY,
            body: PaymentChannel.settleConditionalsMessage(opts.isA, opts.toSettle, opts.proof, opts.key, curId)
        });
    }

    async getChannelState(provider: ContractProvider) {
        const { stack } = await provider.get('getChannelState', []);
        return stack.readNumber();
    }
    async getChannelData(provider: ContractProvider) {
        const { stack } = await provider.get('getChannelData', []);
        const state = stack.readNumber();
        const balanceTuple = stack.readTuple();
        const balance = {
            balanceA: balanceTuple.readBigNumber(),
            balanceB: balanceTuple.readBigNumber(),

            depositA: balanceTuple.readBigNumber(),
            depositB: balanceTuple.readBigNumber(),

            withdrawA: balanceTuple.readBigNumber(),
            withdrawB: balanceTuple.readBigNumber(),
        }

        const keysTuple = stack.readTuple();
        const id = stack.readBigNumber();

        const closureConfig = parseClosureCoinfg(stack.readCell());
        const seqnoTuple = stack.readTuple();
        const quarantine = stack.readCellOpt();

        const paymentTuple = stack.readTuple();
        const paymentConfig: PaymentConfig = {
            storageFee: paymentTuple.readBigNumber(),
            addressA: paymentTuple.readAddress(),
            addressB: paymentTuple.readAddress(),
            customCurrency: false
        }
        return {
            state,
            balance,
            keys: {
                keyA: Buffer.from(keysTuple.readBigNumber().toString(16).padStart(64, '0'), 'hex'),
                keyB: Buffer.from(keysTuple.readBigNumber().toString(16).padStart(64, '0'), 'hex'),
            },
            id,
            closureConfig,
            seqnoA: seqnoTuple.readBigNumber(),
            seqnoB: seqnoTuple.readBigNumber(),
            quarantine: quarantine ? parseQuarantine(quarantine) : null,
            paymentConfig
        }
    }
}
