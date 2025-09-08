import { toNano } from '@ton/core';
import { PaymentChannelUniversal } from '../wrappers/PaymentChannelUniversal';
import { compile, NetworkProvider } from '@ton/blueprint';

export async function run(provider: NetworkProvider) {
    const paymentChannelUniversal = provider.open(PaymentChannelUniversal.createFromConfig({}, await compile('PaymentChannelUniversal')));

    await paymentChannelUniversal.sendDeploy(provider.sender(), toNano('0.05'));

    await provider.waitForDeploy(paymentChannelUniversal.address);

    // run methods on `paymentChannelUniversal`
}
