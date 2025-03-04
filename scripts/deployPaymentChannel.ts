import { toNano } from '@ton/core';
import { PaymentChannel } from '../wrappers/PaymentChannel';
import { compile, NetworkProvider } from '@ton/blueprint';

export async function run(provider: NetworkProvider) {
    const paymentChannel = provider.open(PaymentChannel.createFromConfig({}, await compile('PaymentChannel')));

    await paymentChannel.sendDeploy(provider.sender(), toNano('0.05'));

    await provider.waitForDeploy(paymentChannel.address);

    // run methods on `paymentChannel`
}
