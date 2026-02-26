import { Blockchain, SandboxContract, TreasuryContract } from '@ton/sandbox';
import { Cell, toNano } from '@ton/core';
import { DerivativeCommit } from '../wrappers/DerivativeCommit';
import '@ton/test-utils';
import { compile } from '@ton/blueprint';

describe('DerivativeCommit', () => {
    let code: Cell;

    beforeAll(async () => {
        code = await compile('DerivativeCommit');
    });

    let blockchain: Blockchain;
    let deployer: SandboxContract<TreasuryContract>;
    let derivativeCommit: SandboxContract<DerivativeCommit>;

    beforeEach(async () => {
        blockchain = await Blockchain.create();

        derivativeCommit = blockchain.openContract(DerivativeCommit.createFromConfig({}, code));

        deployer = await blockchain.treasury('deployer');

        const deployResult = await derivativeCommit.sendDeploy(deployer.getSender(), toNano('0.05'));

        expect(deployResult.transactions).toHaveTransaction({
            from: deployer.address,
            to: derivativeCommit.address,
            deploy: true,
            success: true,
        });
    });

    it('should deploy', async () => {
        // the check is done inside beforeEach
        // blockchain and derivativeCommit are ready to use
    });
});
