import { toNano } from '@ton/core';
import { Vault } from '../wrappers/Vault';
import { compile, NetworkProvider } from '@ton/blueprint';

export async function run(provider: NetworkProvider) {
    const vault = provider.open(Vault.createFromConfig({}, await compile('Vault')));

    await vault.sendDeploy(provider.sender(), toNano('0.05'));

    await provider.waitForDeploy(vault.address);

    // run methods on `vault`
}
