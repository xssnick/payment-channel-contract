import { Address, beginCell, Cell, Contract, contractAddress, ContractProvider, Sender, SendMode } from '@ton/core';

export type ConditionalUniversalConfig = {};

export function conditionalUniversalConfigToCell(config: ConditionalUniversalConfig): Cell {
    return beginCell().endCell();
}

export class ConditionalUniversal implements Contract {
    constructor(readonly address: Address, readonly init?: { code: Cell; data: Cell }) {}

    static createFromAddress(address: Address) {
        return new ConditionalUniversal(address);
    }

    static createFromConfig(config: ConditionalUniversalConfig, code: Cell, workchain = 0) {
        const data = conditionalUniversalConfigToCell(config);
        const init = { code, data };
        return new ConditionalUniversal(contractAddress(workchain, init), init);
    }

    async sendDeploy(provider: ContractProvider, via: Sender, value: bigint) {
        await provider.internal(via, {
            value,
            sendMode: SendMode.PAY_GAS_SEPARATELY,
            body: beginCell().endCell(),
        });
    }
}
