import { Blockchain, SandboxContract, TreasuryContract } from '@ton/sandbox';
import { Cell, toNano } from '@ton/core';
import { PaymentChannelUniversal } from '../wrappers/PaymentChannelUniversal';
import '@ton/test-utils';
import { compile } from '@ton/blueprint';

describe('PaymentChannelUniversal', () => {
    let code: Cell;

    beforeAll(async () => {
        code = await compile('PaymentChannelUniversal');
    });

    let blockchain: Blockchain;
    let deployer: SandboxContract<TreasuryContract>;
    let paymentChannelUniversal: SandboxContract<PaymentChannelUniversal>;

    beforeEach(async () => {
        blockchain = await Blockchain.create();

        paymentChannelUniversal = blockchain.openContract(PaymentChannelUniversal.createFromConfig({}, code));

        deployer = await blockchain.treasury('deployer');

        const deployResult = await paymentChannelUniversal.sendDeploy(deployer.getSender(), toNano('0.05'));

        expect(deployResult.transactions).toHaveTransaction({
            from: deployer.address,
            to: paymentChannelUniversal.address,
            deploy: true,
            success: true,
        });
    });

    it('should deploy', async () => {
        // the check is done inside beforeEach
        // blockchain and paymentChannelUniversal are ready to use
    });
});
