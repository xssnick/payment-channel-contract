import { Blockchain, SandboxContract, TreasuryContract } from '@ton/sandbox';
import { Cell, toNano } from '@ton/core';
import { PaymentChannel } from '../wrappers/PaymentChannel';
import '@ton/test-utils';
import { compile } from '@ton/blueprint';

describe('PaymentChannel', () => {
    let code: Cell;

    beforeAll(async () => {
        code = await compile('PaymentChannel');
    });

    let blockchain: Blockchain;
    let deployer: SandboxContract<TreasuryContract>;
    let paymentChannel: SandboxContract<PaymentChannel>;

    beforeEach(async () => {
        blockchain = await Blockchain.create();

        paymentChannel = blockchain.openContract(PaymentChannel.createFromConfig({}, code));

        deployer = await blockchain.treasury('deployer');

        const deployResult = await paymentChannel.sendDeploy(deployer.getSender(), toNano('0.05'));

        expect(deployResult.transactions).toHaveTransaction({
            from: deployer.address,
            to: paymentChannel.address,
            deploy: true,
            success: true,
        });
    });

    it('should deploy', async () => {
        // the check is done inside beforeEach
        // blockchain and paymentChannel are ready to use
    });
});
