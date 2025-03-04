import { Address, beginCell, Cell, Contract, contractAddress, ContractProvider, Sender, SendMode } from '@ton/core';

export type PaymentChannelConfig = {};

export function paymentChannelConfigToCell(config: PaymentChannelConfig): Cell {
    return beginCell().endCell();
}

export class PaymentChannel implements Contract {
    constructor(readonly address: Address, readonly init?: { code: Cell; data: Cell }) {}

    static createFromAddress(address: Address) {
        return new PaymentChannel(address);
    }

    static createFromConfig(config: PaymentChannelConfig, code: Cell, workchain = 0) {
        const data = paymentChannelConfigToCell(config);
        const init = { code, data };
        return new PaymentChannel(contractAddress(workchain, init), init);
    }

    async sendDeploy(provider: ContractProvider, via: Sender, value: bigint) {
        await provider.internal(via, {
            value,
            sendMode: SendMode.PAY_GAS_SEPARATELY,
            body: beginCell().endCell(),
        });
    }
}
