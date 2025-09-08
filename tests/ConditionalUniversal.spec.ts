import { Blockchain, SandboxContract, TreasuryContract } from '@ton/sandbox';
import { Cell, toNano } from '@ton/core';
import { ConditionalUniversal } from '../wrappers/ConditionalUniversal';
import '@ton/test-utils';
import { compile } from '@ton/blueprint';

describe('ConditionalUniversal', () => {
    let code: Cell;

    beforeAll(async () => {
        code = await compile('ConditionalUniversal');
    });

    let blockchain: Blockchain;
    let deployer: SandboxContract<TreasuryContract>;
    let conditionalUniversal: SandboxContract<ConditionalUniversal>;

    beforeEach(async () => {
        blockchain = await Blockchain.create();

        conditionalUniversal = blockchain.openContract(ConditionalUniversal.createFromConfig({}, code));

        deployer = await blockchain.treasury('deployer');

        const deployResult = await conditionalUniversal.sendDeploy(deployer.getSender(), toNano('0.05'));

        expect(deployResult.transactions).toHaveTransaction({
            from: deployer.address,
            to: conditionalUniversal.address,
            deploy: true,
            success: true,
        });
    });

    it('should deploy', async () => {
        // the check is done inside beforeEach
        // blockchain and conditionalUniversal are ready to use
    });
});
