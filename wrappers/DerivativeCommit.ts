import { Address, beginCell, Cell, Contract, contractAddress, ContractProvider, Sender, SendMode } from '@ton/core';

export type DerivativeCommitConfig = {};

export function derivativeCommitConfigToCell(config: DerivativeCommitConfig): Cell {
    return beginCell().endCell();
}

export class DerivativeCommit implements Contract {
    constructor(readonly address: Address, readonly init?: { code: Cell; data: Cell }) {}

    static createFromAddress(address: Address) {
        return new DerivativeCommit(address);
    }

    static createFromConfig(config: DerivativeCommitConfig, code: Cell, workchain = 0) {
        const data = derivativeCommitConfigToCell(config);
        const init = { code, data };
        return new DerivativeCommit(contractAddress(workchain, init), init);
    }

    async sendDeploy(provider: ContractProvider, via: Sender, value: bigint) {
        await provider.internal(via, {
            value,
            sendMode: SendMode.PAY_GAS_SEPARATELY,
            body: beginCell().endCell(),
        });
    }
}
