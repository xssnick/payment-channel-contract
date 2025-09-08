import { toNano } from '@ton/core';
import { ConditionalUniversal } from '../wrappers/ConditionalUniversal';
import { compile, NetworkProvider } from '@ton/blueprint';

export async function run(provider: NetworkProvider) {
    const conditionalUniversal = provider.open(ConditionalUniversal.createFromConfig({}, await compile('ConditionalUniversal')));

    await conditionalUniversal.sendDeploy(provider.sender(), toNano('0.05'));

    await provider.waitForDeploy(conditionalUniversal.address);

    // run methods on `conditionalUniversal`
}
