import { Address, beginCell, Cell, Contract, contractAddress, ContractProvider, Sender, SendMode } from '@ton/core';

export type PaymentChannelUniversalConfig = {};

export function paymentChannelUniversalConfigToCell(config: PaymentChannelUniversalConfig): Cell {
    return beginCell().endCell();
}

export class PaymentChannelUniversal implements Contract {
    constructor(readonly address: Address, readonly init?: { code: Cell; data: Cell }) {}

    static createFromAddress(address: Address) {
        return new PaymentChannelUniversal(address);
    }

    static createFromConfig(config: PaymentChannelUniversalConfig, code: Cell, workchain = 0) {
        const data = paymentChannelUniversalConfigToCell(config);
        const init = { code, data };
        return new PaymentChannelUniversal(contractAddress(workchain, init), init);
    }

    async sendDeploy(provider: ContractProvider, via: Sender, value: bigint) {
        await provider.internal(via, {
            value,
            sendMode: SendMode.PAY_GAS_SEPARATELY,
            body: beginCell().endCell(),
        });
    }
}
