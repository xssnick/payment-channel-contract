import { toNano } from '@ton/core';
import { DerivativeCommit } from '../wrappers/DerivativeCommit';
import { compile, NetworkProvider } from '@ton/blueprint';

export async function run(provider: NetworkProvider) {
    const derivativeCommit = provider.open(DerivativeCommit.createFromConfig({}, await compile('DerivativeCommit')));

    await derivativeCommit.sendDeploy(provider.sender(), toNano('0.05'));

    await provider.waitForDeploy(derivativeCommit.address);

    // run methods on `derivativeCommit`
}
