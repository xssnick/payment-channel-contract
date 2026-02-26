import { Blockchain, SandboxContract, TreasuryContract } from '@ton/sandbox';
import { Cell, toNano } from '@ton/core';
import { Vault } from '../wrappers/Vault';
import '@ton/test-utils';
import { compile } from '@ton/blueprint';

describe('Vault', () => {
    let code: Cell;

    beforeAll(async () => {
        code = await compile('Vault');
    });

    let blockchain: Blockchain;
    let deployer: SandboxContract<TreasuryContract>;
    let vault: SandboxContract<Vault>;

    beforeEach(async () => {
        blockchain = await Blockchain.create();

        vault = blockchain.openContract(Vault.createFromConfig({}, code));

        deployer = await blockchain.treasury('deployer');

        const deployResult = await vault.sendDeploy(deployer.getSender(), toNano('0.05'));

        expect(deployResult.transactions).toHaveTransaction({
            from: deployer.address,
            to: vault.address,
            deploy: true,
            success: true,
        });
    });

    it('should deploy', async () => {
        // the check is done inside beforeEach
        // blockchain and vault are ready to use
    });
});
