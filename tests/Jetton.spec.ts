import { Blockchain, BlockchainSnapshot, SandboxContract, SendMessageResult, TreasuryContract } from '@ton/sandbox';
import { Address, beginCell, Cell, contractAddress, Dictionary, generateMerkleProof, SendMode, Slice, toNano, Transaction } from '@ton/core';
import { Balance, BalanceCommit, balanceToCell, CloseState, mapState, PaymentChannel, PaymentChannelConfig, paymentChannelConfigToCell, SemiChannel, SemiChannelBody, signSemiChannel } from '../wrappers/PaymentChannel';
import { JettonWallet } from '../wrappers/JettonWallet';
import { JettonMinter } from '../wrappers/JettonMinter';
import '@ton/test-utils';
import { compile } from '@ton/blueprint';
import { KeyPair, getSecureRandomBytes, keyPairFromSeed } from '@ton/crypto';
import { CodeSegmentSlice, getRandomInt, loadCodeDictionary, signCell, testJettonNotification, testJettonTransfer } from './utils';
import { Errors, Op } from '../wrappers/Constants';
import { Op as JettonOp } from '../wrappers/JettonConstants';
import { getMsgPrices, computedGeneric, computeMessageForwardFees } from './gasUtils';
import { findTransaction, findTransactionRequired } from '@ton/test-utils';

type ChannelData = Awaited<ReturnType<SandboxContract<PaymentChannel>['getChannelData']>>;
describe('PaymentChannel', () => {
    let blockchain: Blockchain;

    let channelCode: Cell;
    let walletCode: Cell;
    let minterCode: Cell;

    let msgPrices: ReturnType<typeof getMsgPrices>;
    let tonChannelConfig: PaymentChannelConfig;

    let tonChannel: SandboxContract<PaymentChannel>;
    let jettonMinter: SandboxContract<JettonMinter>;
    let walletA: SandboxContract<TreasuryContract>;
    let walletB: SandboxContract<TreasuryContract>;
    let conditionals: Dictionary<bigint, Slice>;
    let conditionalsHash: Buffer;
    let conditionalsProof: Cell;

    let quarantineStartedA: BlockchainSnapshot;
    let quarantineStartedB: BlockchainSnapshot;

    let quarantineChallengedA: BlockchainSnapshot;
    let quarantineChallengedB: BlockchainSnapshot;

    let keysA: KeyPair
    let keysB: KeyPair

    let feeJettonAccept = toNano('0.035');
    let feeJettonPayout = toNano('0.08');
    let commitFee = toNano('0.03');
    let feeMinBalance = toNano('0.01') + feeJettonPayout * 2n + toNano('0.03');

    let channelClosedPayload: Cell;

    let userJetton: (address: Address) => Promise<SandboxContract<JettonWallet>>;
    let assertJettonNotification: (txs: Transaction[], to: Address, from: Address, amount: bigint, payload: Cell | null) => Promise<void>;

    let channelWalletAddr: Address;

    let calcSends = (data: ChannelData) => {
        let sentA = data.balance.balanceA - (data.balance.depositA - data.balance.withdrawA);
        let sentB = data.balance.balanceB - (data.balance.depositB - data.balance.withdrawB);
        // If balance less than depo - withdraw, means there was transfer from balance
        if(sentA < 0n) {
            sentA = -sentA;
            sentB = 0n;
        } else if(sentB < 0n) {
            sentB = -sentB;
            sentA = 0n;
        }

        return {
            sentA,
            sentB
        }
    }

    let assertChannelClosed = (data: ChannelData, seqnoA: bigint, seqnoB: bigint) => {
        expect(mapState(data.state)).toEqual("uninited");
        expect(data.balance).toEqual({
            balanceA: 0n,
            balanceB: 0n,
            depositA: 0n,
            depositB: 0n,
            withdrawA: 0n,
            withdrawB: 0n
        });
        expect(data.seqnoA).toEqual(seqnoA);
        expect(data.seqnoB).toEqual(seqnoB);
    }

    beforeAll(async () => {
        blockchain = await Blockchain.create();

        blockchain.now = 1000;

        channelCode = await compile('PaymentChannel');

        const jwallet_code_raw = await compile('JettonWallet');

        minterCode  = await compile('JettonMinter');
        //jwallet_code is library
        const _libs = Dictionary.empty(Dictionary.Keys.BigUint(256), Dictionary.Values.Cell());
        _libs.set(BigInt(`0x${jwallet_code_raw.hash().toString('hex')}`), jwallet_code_raw);
        const libs = beginCell().storeDictDirect(_libs).endCell();
        blockchain.libs = libs;
        let lib_prep = beginCell().storeUint(2,8).storeBuffer(jwallet_code_raw.hash()).endCell();
        walletCode = new Cell({ exotic:true, bits: lib_prep.bits, refs:lib_prep.refs});

        const codeDict = loadCodeDictionary(await compile('Conditional'));
        conditionals   = Dictionary.empty(Dictionary.Keys.BigUint(32), CodeSegmentSlice());
        const conditional = codeDict.get(42)!;
        expect(conditional).not.toBeUndefined();
        conditionals.set(0n, conditional);
        conditionalsHash  = beginCell().storeDictDirect(conditionals).endCell().hash();
        conditionalsProof = generateMerkleProof(conditionals, conditionals.keys(), Dictionary.Keys.BigUint(32));


        msgPrices = getMsgPrices(blockchain.config, 0);

        walletA = await blockchain.treasury('Wallet A');
        walletB = await blockchain.treasury('Wallet B');

        keysA = keyPairFromSeed(await getSecureRandomBytes(32));
        keysB = keyPairFromSeed(await getSecureRandomBytes(32));

        jettonMinter = blockchain.openContract(
            JettonMinter.createFromConfig({
                jetton_content: {uri: 'https://localhost/my_jetton.json'},
                admin: walletA.address,
                wallet_code: walletCode
            }, minterCode)
        );

        const minterDeploy = await jettonMinter.sendDeploy(walletA.getSender(), toNano('1'));

        expect(minterDeploy.transactions).toHaveTransaction({
            on: jettonMinter.address,
            from: walletA.address,
            deploy: true,
            aborted: false
        });
        userJetton = async (address:Address) => blockchain.openContract(
                          JettonWallet.createFromAddress(
                            await jettonMinter.getWalletAddress(address)
                          )
                     );
        assertJettonNotification = async (txs, to, from, amount, payload) => {
            const toJetton  = await userJetton(to);
            expect(txs).toHaveTransaction({
                on: to,
                from: toJetton.address,
                op: JettonOp.transfer_notification,
                body: b => testJettonNotification(b!, {
                    amount,
                    from,
                    payload
                })
            });
        }

        const jettonA = await userJetton(walletA.address);
        const jettonB = await userJetton(walletB.address);

        let mintRes = await jettonMinter.sendMint(
            walletA.getSender(),
            walletA.address,
            toNano('100000'),
        );

        expect(mintRes.transactions).toHaveTransaction({
            on: jettonA.address,
            from: jettonMinter.address,
            op: JettonOp.internal_transfer,
            aborted: false
        });

        mintRes = await jettonMinter.sendMint(
            walletA.getSender(),
            walletB.address,
            toNano('100000'),
        );
        expect(mintRes.transactions).toHaveTransaction({
            on: jettonB.address,
            from: jettonMinter.address,
            op: JettonOp.internal_transfer,
            aborted: false
        });

        tonChannelConfig = {
            id: 42n,
            keyA: keysA.publicKey,
            keyB: keysB.publicKey,
            paymentConfig: {
                storageFee: toNano('0.3'),
                customCurrency: true,
                isJetton: true,
                jettonRoot: jettonMinter.address,
                addressA: walletA.address,
                addressB: walletB.address,
            },
            closureConfig: {
                closeDuration: 3600,
                fine: toNano('1'),
                quarantineDuration: 3600
            }
        };

        channelClosedPayload = beginCell()
                                .storeUint(Op.OP_CHANNEL_CLOSED, 32)
                                .storeUint(tonChannelConfig.id, 128)
                               .endCell();

        tonChannel = blockchain.openContract(PaymentChannel.createFromConfig(tonChannelConfig, channelCode));

        channelWalletAddr = await jettonMinter.getWalletAddress(tonChannel.address);
    });

    it('should not allow to deploy with value below min storage fee', async () => {
        const prevState = blockchain.snapshot();
        const msgValue = tonChannelConfig.paymentConfig.storageFee - 1n;
        let deployRes = await tonChannel.sendDeploy(walletA.getSender(), true, keysA.secretKey, msgValue);

        expect(deployRes.transactions).toHaveTransaction({
            on: tonChannel.address,
            value: msgValue,
            aborted: true,
            deploy: true,
            exitCode: Errors.ERROR_NOT_ENOUGH_MONEY_FOR_INIT_STORAGE
        });

        expect(await tonChannel.getChannelState()).toEqual("uninited");

        deployRes = await tonChannel.sendDeploy(walletA.getSender(), true, keysA.secretKey, msgValue + 1n);
        expect(deployRes.transactions).toHaveTransaction({
            on: tonChannel.address,
            value: msgValue + 1n,
            aborted: false,
        });

        expect(await tonChannel.getChannelState()).toEqual("open");

        await blockchain.loadFrom(prevState);
    });

    it('should not allow to deploy with configured storage fee <= hardcoded minimum', async () => {
        const prevState = blockchain.snapshot();
        let newConfig: PaymentChannelConfig = {...tonChannelConfig, paymentConfig: {...tonChannelConfig.paymentConfig, storageFee: feeMinBalance}};

        let newChannel = blockchain.openContract(
            PaymentChannel.createFromConfig(newConfig, channelCode)
        );
        const msgValue = feeMinBalance;
        let deployRes = await newChannel.sendDeploy(walletA.getSender(), true, keysA.secretKey, msgValue);

        expect(deployRes.transactions).toHaveTransaction({
            on: newChannel.address,
            value: msgValue,
            aborted: true,
            deploy: true,
            exitCode: Errors.ERROR_NOT_ENOUGH_MONEY_FOR_INIT_STORAGE
        });

        expect(await newChannel.getChannelState()).toEqual("uninited");

        deployRes = await newChannel.sendDeploy(walletA.getSender(), true, keysA.secretKey, msgValue + 1n);
        expect(deployRes.transactions).toHaveTransaction({
            on: newChannel.address,
            value: msgValue + 1n,
            aborted: true,
            exitCode: Errors.ERROR_NOT_ENOUGH_MONEY_FOR_INIT_STORAGE
        });

        // Gotta increase config min balance above absolute minimum
        newConfig.paymentConfig = {...newConfig.paymentConfig, storageFee: feeMinBalance + 1n};
        newChannel = blockchain.openContract(
            PaymentChannel.createFromConfig(newConfig, channelCode)
        );

        deployRes = await newChannel.sendDeploy(walletA.getSender(), true, keysA.secretKey, msgValue + 1n);
        expect(deployRes.transactions).toHaveTransaction({
            on: newChannel.address,
            value: msgValue + 1n,
            aborted: false
        });

        expect(await newChannel.getChannelState()).toEqual("open");

        await blockchain.loadFrom(prevState);
    });

    it('should not be able to deploy channel with non-empty balance', async () => {
        const prevState = blockchain.snapshot();

        const initialConfig = paymentChannelConfigToCell(tonChannelConfig);

        const emptyBalance: Balance = {
            depositA: 0n,
            depositB: 0n,
            withdrawA: 0n,
            withdrawB: 0n,
            sentA: 0n,
            sentB: 0n
        };

        const rndVal = BigInt(getRandomInt(1, 1000)) * toNano('0.001');

        const withDepositA  = {...emptyBalance, depositA: rndVal};
        const withDepositB  = {...emptyBalance, depositB: rndVal};
        const withWithdrawA = {...emptyBalance, withdrawA: rndVal};
        const withWithdrawB = {...emptyBalance, withdrawB: rndVal};
        const withSentA = {...emptyBalance, sentA: rndVal};
        const withSentB = {...emptyBalance, sentB: rndVal};

        const withAll: Balance = {
            depositA: rndVal,
            depositB: rndVal,
            withdrawA: rndVal,
            withdrawB: rndVal,
            sentA: rndVal,
            sentB: rndVal
        };

        let testCases = [
            withDepositA,
            withDepositB,
            withWithdrawA,
            withWithdrawB,
            withSentA,
            withSentB,
            withAll
        ];

        for(let testCase of testCases) {
            const balanceCell = balanceToCell(testCase);
            const newRefs = [balanceCell, ...initialConfig.refs.slice(1)];

            const newConfig = new Cell({bits: initialConfig.bits, refs: newRefs});
            const initMsg   = PaymentChannel.channelInitMessage(true, keysA.secretKey, tonChannelConfig.id);

            const newChannelAddr = contractAddress(0, {
                data: newConfig,
                code: channelCode
            });

            const res = await walletA.send({
                to: newChannelAddr,
                value: toNano('1'),
                body: initMsg,
                init: {
                    data: newConfig,
                    code: channelCode
                }
            });

            expect(res.transactions).toHaveTransaction({
                on: newChannelAddr,
                aborted: true,
                exitCode: Errors.ERROR_INCORRECT_INITIAL_BALANCE
            });
        }

        await blockchain.loadFrom(prevState);
    });

    it('should deploy', async () => {
        const deployRes = await tonChannel.sendDeploy(walletA.getSender(), true, keysA.secretKey, toNano('1'));

        expect(deployRes.transactions).toHaveTransaction({
            on: tonChannel.address,
            value: toNano('1'),
            aborted: false,
            deploy: true
        });
        // Check channel wallet init chain
        expect(deployRes.transactions).toHaveTransaction({
            on: jettonMinter.address,
            from: tonChannel.address,
            op: JettonOp.provide_wallet_address,
            aborted: false,
            outMessagesCount: 1
        });
        // Make sure provide wallet ended successfully
        expect(deployRes.transactions).toHaveTransaction({
            on: tonChannel.address,
            from: jettonMinter.address,
            op: JettonOp.take_wallet_address,
            body: beginCell()
                    .storeUint(JettonOp.take_wallet_address, 32)
                    .storeUint(0n, 64)
                    .storeAddress(channelWalletAddr)
                    .storeBit(false)
                  .endCell(),
            aborted: false
        });

        const chData = await tonChannel.getChannelData();

        expect(chData.id).toBe(42n);

        expect(chData.seqnoA).toBe(0n);
        expect(chData.seqnoB).toBe(0n);

        expect(chData.keys.keyA.equals(keysA.publicKey)).toBe(true);
        expect(chData.keys.keyB.equals(keysB.publicKey)).toBe(true);

        // There is not indication of channel type in getter resp
        expect(chData.paymentConfig.storageFee).toEqual(tonChannelConfig.paymentConfig.storageFee);
        expect(chData.paymentConfig.customCurrency).toBe(false);
        expect(chData.paymentConfig.addressA).toEqualAddress(walletA.address);
        expect(chData.paymentConfig.addressB).toEqualAddress(walletB.address);

        expect(chData.closureConfig.closeDuration).toEqual(3600);
        expect(chData.closureConfig.quarantineDuration).toEqual(3600);
        expect(chData.closureConfig.fine).toEqual(toNano('1'));

        expect(chData.balance.withdrawA).toBe(0n);
        expect(chData.balance.withdrawB).toBe(0n);
        expect(chData.balance.depositA).toBe(0n);
        expect(chData.balance.depositB).toBe(0n);
        expect(chData.balance.balanceA).toBe(0n);
        expect(chData.balance.balanceB).toBe(0n);

        const smc = await blockchain.getContract(tonChannel.address);
        // Expect only storage fee to be left
        expect(smc.balance).toBeGreaterThanOrEqual(tonChannelConfig.paymentConfig.storageFee);
    });

    it('should top up', async () => {
        let dataBefore = await tonChannel.getChannelData();

        const channelJetton = await userJetton(tonChannel.address);
        let balanceBefore = await channelJetton.getJettonBalance();
        const jettonA = await userJetton(walletA.address);

        let depoAmount = BigInt(getRandomInt(10, 100)) * toNano('0.01');
        const smc = await blockchain.getContract(tonChannel.address);
        let res   = await jettonA.sendTransfer(walletA.getSender(),
                                       toNano('0.05') + feeJettonAccept,
                                       depoAmount,
                                       tonChannel.address,
                                       walletA.address,
                                       null,
                                       feeJettonAccept,
                                       PaymentChannel.topUpMessage(true));

        // This could only happen if whole jetton chain executed
        expect(res.transactions).toHaveTransaction({
            on: tonChannel.address,
            from: channelWalletAddr,
            op: JettonOp.transfer_notification,
        });

        let dataAfter = await tonChannel.getChannelData();

        expect(dataAfter.balance.depositA).toEqual(dataBefore.balance.depositA + depoAmount);
        expect(dataAfter.balance.depositB).toEqual(dataBefore.balance.depositB);

        expect(dataAfter.balance.balanceA).toEqual(dataBefore.balance.balanceA + depoAmount);
        expect(dataAfter.balance.balanceB).toEqual(dataBefore.balance.balanceB);

        expect(smc.balance).toEqual(tonChannelConfig.paymentConfig.storageFee);

        // Check that it didn't sent jettons back and such
        expect(await channelJetton.getJettonBalance()).toEqual(balanceBefore + depoAmount);

        // I know, i know, but it reads better
        balanceBefore += depoAmount;

        dataBefore = dataAfter;

        depoAmount = BigInt(getRandomInt(10, 100)) * toNano('0.01');

        const jettonB = await userJetton(walletB.address);
        res = await jettonB.sendTransfer(walletB.getSender(),
                                       toNano('0.05') + feeJettonAccept,
                                       depoAmount,
                                       tonChannel.address,
                                       walletB.address,
                                       null,
                                       feeJettonAccept,
                                       PaymentChannel.topUpMessage(false));

        expect(res.transactions).toHaveTransaction({
            on: tonChannel.address,
            from: channelWalletAddr,
            op: JettonOp.transfer_notification,
            aborted: false
        });

        dataAfter = await tonChannel.getChannelData();
        expect(dataAfter.balance.depositB).toEqual(dataBefore.balance.depositB + depoAmount);
        expect(dataAfter.balance.depositA).toEqual(dataBefore.balance.depositA);
        expect(dataAfter.balance.balanceA).toEqual(dataBefore.balance.balanceA);
        expect(dataAfter.balance.balanceB).toEqual(dataBefore.balance.balanceB + depoAmount);
        expect(await channelJetton.getJettonBalance()).toEqual(balanceBefore + depoAmount);

        expect(smc.balance).toEqual(tonChannelConfig.paymentConfig.storageFee);
    });
    it('should only accept top up from own jetton wallet', async () => {

        let depoAmount = BigInt(getRandomInt(10, 100)) * toNano('0.01');
        let msgValue   = BigInt(getRandomInt(5, 10)) * toNano('0.01');

        const dataBefore = await tonChannel.getChannelData();

        for (let testWallet of [walletA, walletB]) {
            const isA = testWallet === walletA;
            const notificationMessage = beginCell()
             .storeUint(JettonOp.transfer_notification, 32)
             .storeUint(0, 64)
             .storeCoins(depoAmount)
             .storeAddress(testWallet.address)
             .storeBit(false)
             .storeSlice(PaymentChannel.topUpMessage(isA).asSlice())
            .endCell();

            // Sending directly from wallet
            const res = await testWallet.send({
                to: tonChannel.address,
                value: msgValue,
                body: notificationMessage,
                sendMode: SendMode.PAY_GAS_SEPARATELY | SendMode.IGNORE_ERRORS
            });

            const topUpTx = res.transactions[1];

            const dataAfter = await tonChannel.getChannelData();

            if(isA) {
                expect(dataAfter.balance.depositA).toEqual(dataBefore.balance.depositA);
                expect(dataAfter.balance.balanceA).toEqual(dataBefore.balance.balanceA);
            } else {
                expect(dataAfter.balance.depositB).toEqual(dataBefore.balance.depositB);
                expect(dataAfter.balance.balanceB).toEqual(dataBefore.balance.balanceB);
            }
            expect(res.transactions).toHaveTransaction({
                on: tonChannel.address,
                from: testWallet.address,
                op: JettonOp.transfer_notification,
                value: msgValue,
                outMessagesCount: 1
            });

            const fwdFees = computeMessageForwardFees(msgPrices, topUpTx.outMessages.get(0)!);

            // Expect return attempt
            expect(res.transactions).toHaveTransaction({
                on: testWallet.address,
                from: tonChannel.address,
                op: JettonOp.transfer,
                // Make sure it returns value in mode 64 and won't burn balance
                value: msgValue - computedGeneric(topUpTx).gasFees - fwdFees.fees.total,
                body: b => testJettonTransfer(b!, {
                    to: testWallet.address,
                    amount: depoAmount,
                    forward_payload: null
                })
            });
        }
    });

    it('should not be able to re-deploy', async () => {
            const initMsg   = PaymentChannel.channelInitMessage(true, keysA.secretKey, tonChannelConfig.id);

            const res = await walletA.send({
                to: tonChannel.address,
                value: toNano('1'),
                body: initMsg,
                init: {
                    data: paymentChannelConfigToCell(tonChannelConfig),
                    code: channelCode
                }
            });

            expect(res.transactions).toHaveTransaction({
                on: tonChannel.address,
                aborted: true,
                exitCode: Errors.ERROR_ALREADY_INITED
            });
    });

    it('should reject top up below minimal fee', async () => {

        const depoAmount = BigInt(getRandomInt(1, 100_000));
        for(let testWallet of [walletA, walletB]) {

            const isA = testWallet === walletA;
            const testJetton = await userJetton(testWallet.address);
            const res = await testJetton.sendTransfer(testWallet.getSender(),
                                       toNano('0.05') + feeJettonAccept,
                                       depoAmount,
                                       tonChannel.address,
                                       walletB.address,
                                       null,
                                       feeJettonAccept - 1n,
                                       PaymentChannel.topUpMessage(isA));


            // const res = await tonChannel.sendTopUp(testWallet.getSender(), testWallet === walletA, depoAmount);
            expect(res.transactions).toHaveTransaction({
                on: tonChannel.address,
                op: JettonOp.transfer_notification,
                aborted: false,
                outMessagesCount: 1
            });
            // Expect send back

            await assertJettonNotification(
                res.transactions,
                testWallet.address,
                tonChannel.address,
                depoAmount,
                null
            );

        }
    });

    it.skip('should not accept top up from A as B', async () => {
        let depoAmount = BigInt(getRandomInt(3, 100)) * toNano('0.01');

        for(let testWallet of [walletA, walletB]) {
            // Invert isA flag
            const res = await tonChannel.sendTopUp(testWallet.getSender(), testWallet !== walletA, depoAmount);
            expect(res.transactions).toHaveTransaction({
                on: tonChannel.address,
                op: Op.OP_TOP_UP_BALANCE,
                aborted: true,
            });
        }
    });

    it('should allow to withdraw and send via cooperative commit', async () => {
        let dataBefore = await tonChannel.getChannelData();

        const msgValue  = commitFee + feeJettonPayout * 2n;
        // const msgValue  = toNano('1');

        const withdrawA = dataBefore.balance.depositA / BigInt(getRandomInt(10, 100));
        const withdrawB = dataBefore.balance.depositB / BigInt(getRandomInt(10, 100));

        let sentA = dataBefore.balance.depositA / BigInt(getRandomInt(10, 100));
        let sentB = dataBefore.balance.depositB / BigInt(getRandomInt(10, 100));

        if(sentA > sentB) {
            sentA -= sentB;
            sentB = 0n;
        } else {
            sentB -= sentA;
            sentA = 0n;
        }

        const sendsBefore = calcSends(dataBefore);
        const justWithdraw: BalanceCommit = {
            withdrawA,
            withdrawB,
            seqnoA: dataBefore.seqnoA + 1n,
            seqnoB: dataBefore.seqnoB + 1n,
            sentA: sendsBefore.sentA,
            sentB: sendsBefore.sentB
        }

        const withdrawAndSend: BalanceCommit = {
            withdrawA: withdrawA * 2n,
            withdrawB: withdrawB * 2n,
            seqnoA: dataBefore.seqnoA + 2n,
            seqnoB: dataBefore.seqnoB + 2n,
            sentA: sentA,
            sentB: sentB
        };

        sentA += BigInt(getRandomInt(1, 100_000));
        sentB += BigInt(getRandomInt(1, 100_000));

        // Meh
        if(sentA > sentB) {
            sentA -= sentB;
            sentB = 0n;
        } else {
            sentB -= sentA;
            sentA = 0n;
        }

        const noWithdraw: BalanceCommit = {
            // Same withdraw
            withdrawA: withdrawA * 2n,
            withdrawB: withdrawB * 2n,
            seqnoA: dataBefore.seqnoA + 3n,
            seqnoB: dataBefore.seqnoB + 3n,
            sentA,
            sentB
        };


        const withdrawPayload = beginCell()
                                 .storeUint(Op.OP_CHANNEL_WITHDRAW, 32)
                                 .storeUint(tonChannelConfig.id, 128)
                                .endCell();

        const smc = await blockchain.getContract(tonChannel.address);

        for(let balanceCommit of [justWithdraw, withdrawAndSend, noWithdraw]) {
            const commitBody = PaymentChannel.cooperativeCommitBody(balanceCommit, tonChannelConfig.id);
            const sigA = await signCell(commitBody, keysA.secretKey);
            const sigB = await signCell(commitBody, keysB.secretKey);

            const res = await tonChannel.sendCooperativeCommit(walletA.getSender(), {
                commit: balanceCommit,
                sigA,
                sigB
            }, msgValue);

            expect(res.transactions).toHaveTransaction({
                on: tonChannel.address,
                from: walletA.address,
                op: Op.OP_COOPERATIVE_COMMIT,
                aborted: false
            });

            if(dataBefore.balance.withdrawA < balanceCommit.withdrawA) {
                const expAmount = balanceCommit.withdrawA - dataBefore.balance.withdrawA;
                await assertJettonNotification(res.transactions,
                                               walletA.address,
                                               tonChannel.address,
                                               expAmount,
                                               withdrawPayload);
            }
            if(dataBefore.balance.withdrawB < balanceCommit.withdrawB) {
                const expAmount = balanceCommit.withdrawB - dataBefore.balance.withdrawB;
                await assertJettonNotification(res.transactions,
                                               walletB.address,
                                               tonChannel.address,
                                               expAmount,
                                               withdrawPayload);

            }

            const dataAfter = await tonChannel.getChannelData();

            expect(dataAfter.seqnoA).toEqual(dataBefore.seqnoA + 1n)
            expect(dataAfter.seqnoB).toEqual(dataBefore.seqnoB + 1n);

            expect(dataAfter.balance.withdrawA).toEqual(balanceCommit.withdrawA);
            expect(dataAfter.balance.withdrawB).toEqual(balanceCommit.withdrawB);

            expect(dataAfter.balance.balanceA).toEqual(dataBefore.balance.depositA - balanceCommit.withdrawA - balanceCommit.sentA + balanceCommit.sentB);
            expect(dataAfter.balance.balanceB).toEqual(dataBefore.balance.depositB - balanceCommit.withdrawB - balanceCommit.sentB + balanceCommit.sentA);

            dataBefore = dataAfter;
            expect(smc.balance).toEqual(tonChannelConfig.paymentConfig.storageFee);
        }
    });
    it('should not allow cooperative commits with invalid signatures', async () => {
        let dataBefore = await tonChannel.getChannelData();
        const {sentA, sentB} = calcSends(dataBefore);

        const testCommit: BalanceCommit = {
            withdrawA: dataBefore.balance.withdrawA + 1n,
            withdrawB: dataBefore.balance.withdrawB + 1n,
            seqnoA: dataBefore.seqnoA + 1n,
            seqnoB: dataBefore.seqnoB + 1n,
            sentA,
            sentB
        };

        const commitBody = PaymentChannel.cooperativeCommitBody(testCommit, tonChannelConfig.id);

        // Just switch key pairs
        const sigA = await signCell(commitBody, keysB.secretKey);
        const sigB = await signCell(commitBody, keysA.secretKey);

        const res = await tonChannel.sendCooperativeCommit(walletA.getSender(), {
            commit: testCommit,
            sigA,
            sigB
        });

        expect(res.transactions).toHaveTransaction({
            on: tonChannel.address,
            from: walletA.address,
            op: Op.OP_COOPERATIVE_COMMIT,
            aborted: true,
            exitCode: Errors.ERROR_NOT_AUTHORIZED
        });
    });
    it('should not allow to withdraw more than on a balance', async () => {
        let dataBefore = await tonChannel.getChannelData();
        let msgValue   = commitFee + feeJettonPayout;

        const {sentA, sentB} = calcSends(dataBefore);


        const excessiveWithdrawA: BalanceCommit = {
            withdrawA: dataBefore.balance.withdrawA + dataBefore.balance.balanceA + 1n,
            withdrawB: dataBefore.balance.withdrawB,
            seqnoA: dataBefore.seqnoA + 1n,
            seqnoB: dataBefore.seqnoB + 1n,
            sentA,
            sentB,
        };
        const excessiveWithdrawB: BalanceCommit = {
            withdrawA: dataBefore.balance.withdrawA,
            withdrawB: dataBefore.balance.withdrawB + dataBefore.balance.balanceB + 1n,
            seqnoA: dataBefore.seqnoA + 2n,
            seqnoB: dataBefore.seqnoB + 2n,
            sentA,
            sentB
        };

        for(let balanceCommit of [excessiveWithdrawA, excessiveWithdrawB]) {
            const commitBody = PaymentChannel.cooperativeCommitBody(balanceCommit, tonChannelConfig.id);
            const sigA = await signCell(commitBody, keysA.secretKey);
            const sigB = await signCell(commitBody, keysB.secretKey);

            const res = await tonChannel.sendCooperativeCommit(walletA.getSender(), {
                commit: balanceCommit,
                sigA,
                sigB
            }, msgValue);
            expect(res.transactions).toHaveTransaction({
                on: tonChannel.address,
                from: walletA.address,
                op: Op.OP_COOPERATIVE_COMMIT,
                aborted: true,
                exitCode: Errors.ERROR_NOT_ENOUGH_BALANCE
            });
        }
    });
    it('should not allow cooperative commit with lower withdraw than before', async () => {
        let dataBefore = await tonChannel.getChannelData();
        const {sentA, sentB} = calcSends(dataBefore);

        const balanceCommit: BalanceCommit = {
            withdrawA: dataBefore.balance.withdrawA,
            withdrawB: dataBefore.balance.withdrawB,
            seqnoA: dataBefore.seqnoA + 1n,
            seqnoB: dataBefore.seqnoB + 1n,
            sentA,
            sentB
        };

        const belowA = dataBefore.balance.withdrawA - 1n;
        const belowB = dataBefore.balance.withdrawB - 1n;

        const withdrawAbelow: BalanceCommit = {...balanceCommit, withdrawA: belowA};
        const withdrawBbelow: BalanceCommit = {...balanceCommit, withdrawB: belowB};

        const bothBelow: BalanceCommit = {...balanceCommit, withdrawA: belowA, withdrawB: belowB};


        for(let testWallet of [walletA, walletB]) {
            for(let testCommit of [withdrawAbelow, withdrawBbelow, bothBelow]) {
                const commitBody = PaymentChannel.cooperativeCommitBody(testCommit, tonChannelConfig.id);

                const sigA = await signCell(commitBody, keysA.secretKey);
                const sigB = await signCell(commitBody, keysB.secretKey);

                const res = await tonChannel.sendCooperativeCommit(testWallet.getSender(), {
                    commit: testCommit,
                    sigA,
                    sigB
                });
                expect(res.transactions).toHaveTransaction({
                    on: tonChannel.address,
                    op: Op.OP_COOPERATIVE_COMMIT,
                    aborted: true,
                    exitCode: Errors.ERROR_WITHDRAW_REGRESS
                });
            }
        }

    });
    it('should not allow to send more than on party balance', async () => {
        let dataBefore = await tonChannel.getChannelData();
        const {sentA, sentB} = calcSends(dataBefore);

        const excessiveSentA: BalanceCommit = {
            withdrawA: dataBefore.balance.withdrawA,
            withdrawB: dataBefore.balance.withdrawB,
            seqnoA: dataBefore.seqnoA + 1n,
            seqnoB: dataBefore.seqnoB + 1n,
            sentA: sentA + dataBefore.balance.balanceA + 1n,
            sentB: 0n
        };
        const excessiveSentB: BalanceCommit = {
            withdrawA: dataBefore.balance.withdrawA,
            withdrawB: dataBefore.balance.withdrawB,
            seqnoA: dataBefore.seqnoA + 1n,
            seqnoB: dataBefore.seqnoB + 1n,
            sentA: 0n,
            sentB: sentB + dataBefore.balance.balanceB + 1n
        };
        for(let balanceCommit of [excessiveSentA, excessiveSentB]) {
            const commitBody = PaymentChannel.cooperativeCommitBody(balanceCommit, tonChannelConfig.id);
            const sigA = await signCell(commitBody, keysA.secretKey);
            const sigB = await signCell(commitBody, keysB.secretKey);

            const res = await tonChannel.sendCooperativeCommit(walletA.getSender(), {
                commit: balanceCommit,
                sigA,
                sigB
            });
            expect(res.transactions).toHaveTransaction({
                on: tonChannel.address,
                from: walletA.address,
                op: Op.OP_COOPERATIVE_COMMIT,
                aborted: true,
                exitCode: Errors.ERROR_NOT_ENOUGH_BALANCE
            });
        }
    });
    it('should not accept cooperative commit for different channelId', async () => {
        const dataBefore = await tonChannel.getChannelData();
        const {sentA, sentB} = calcSends(dataBefore);

        const msgValue = toNano('0.05');
        const balanceCommit: BalanceCommit = {
            sentA,
            sentB,
            // Just increment both, withc is perfectly ok
            seqnoA: dataBefore.seqnoA + 1n,
            seqnoB: dataBefore.seqnoB + 1n,
            withdrawA: dataBefore.balance.withdrawA,
            withdrawB: dataBefore.balance.withdrawB
        };
        const maxVal = Number(tonChannelConfig.id);
        const curId = tonChannelConfig.id;
        for(let testWallet of [walletA, walletB]) {
            for(let testId of [curId - 1n, curId + 1n, curId + BigInt(getRandomInt(2, maxVal)), curId - BigInt(getRandomInt(2, maxVal))]) {
                const commitBody = PaymentChannel.cooperativeCommitBody(balanceCommit, testId);
                const sigA = await signCell(commitBody, keysA.secretKey);
                const sigB = await signCell(commitBody, keysB.secretKey);

                const res = await tonChannel.sendCooperativeCommit(testWallet.getSender(), {commit: commitBody, sigA, sigB}, msgValue);
                expect(res.transactions).toHaveTransaction({
                    on: tonChannel.address,
                    op: Op.OP_COOPERATIVE_COMMIT,
                    aborted: true,
                    exitCode: Errors.ERROR_WRONG_CHANNEL_ID
                });
            }
        }
    });
    it('should reject cooperative commit with value below commit fee', async () => {
        const dataBefore = await tonChannel.getChannelData();
        const {sentA, sentB} = calcSends(dataBefore);

        const justSeqno: BalanceCommit = {
            withdrawA: dataBefore.balance.withdrawA,
            withdrawB: dataBefore.balance.withdrawB,
            seqnoA: dataBefore.seqnoA + 1n,
            seqnoB: dataBefore.seqnoB + 1n,
            sentA,
            sentB
        };
        const singleWithdrawA: BalanceCommit = {
            ...justSeqno,
            withdrawA: dataBefore.balance.withdrawA + 1n
        }
        const singleWithdrawB: BalanceCommit = {
            ...justSeqno,
            withdrawB: dataBefore.balance.withdrawB + 1n
        }
        const withdrawBoth: BalanceCommit = {
            ...justSeqno,
            withdrawA: dataBefore.balance.withdrawA + 1n,
            withdrawB: dataBefore.balance.withdrawB + 1n,
        }


        let testCases: {
            value: bigint,
            data: BalanceCommit
        }[] = [
            {
                value: commitFee,
                data: justSeqno
            },
            {
                value: commitFee + feeJettonPayout,
                data: singleWithdrawA
            },
            {
                value: commitFee + feeJettonPayout,
                data: singleWithdrawB
            },
            {
                value: commitFee + feeJettonPayout * 2n,
                data: withdrawBoth
            }
        ];

        const prevState = blockchain.snapshot();

        for(let testCase of testCases) {
            const commitBody = PaymentChannel.cooperativeCommitBody(testCase.data, tonChannelConfig.id);
            const sigA = await signCell(commitBody, keysA.secretKey);
            const sigB = await signCell(commitBody, keysB.secretKey);

            for(let testWallet of [walletA, walletB]) {
                let res = await tonChannel.sendCooperativeCommit(testWallet.getSender(), {
                    commit: commitBody,
                    sigA,
                    sigB
                }, testCase.value - 1n);

                expect(res.transactions).toHaveTransaction({
                    on: tonChannel.address,
                    from: testWallet.address,
                    op: Op.OP_COOPERATIVE_COMMIT,
                    aborted: true,
                    exitCode: Errors.ERROR_AMOUNT_NOT_COVERS_FEE
                });

                res = await tonChannel.sendCooperativeCommit(testWallet.getSender(), {
                    commit: commitBody,
                    sigA,
                    sigB
                }, testCase.value);

                expect(res.transactions).toHaveTransaction({
                    on: tonChannel.address,
                    from: testWallet.address,
                    op: Op.OP_COOPERATIVE_COMMIT,
                    aborted: false,
                });

                await blockchain.loadFrom(prevState);
            }
        }
    });
    it('should not accept cooperative commit signed body for cooperative close', async () => {
        // Since coop commit message is exdended coop close message
        // coop commit can be successfully parsed as commit close
        // Thus we expect tag to be checked

        const dataBefore = await tonChannel.getChannelData();
        const {sentA, sentB} = calcSends(dataBefore);

        const closeBody = PaymentChannel.cooperativeCommitBody({
            seqnoA: dataBefore.seqnoA + 1n,
            seqnoB: dataBefore.seqnoB + 1n,
            sentA,
            sentB,
            withdrawA: dataBefore.balance.withdrawA,
            withdrawB: dataBefore.balance.withdrawB
        }, tonChannelConfig.id);

        const sigA = await signCell(closeBody, keysA.secretKey);
        const sigB = await signCell(closeBody, keysB.secretKey);

        for(let testWallet of [walletA, walletB]) {
            const res = await tonChannel.sendCooperativeClose(testWallet.getSender(), {state: closeBody, sigA, sigB});

            expect(res.transactions).toHaveTransaction({
                on: tonChannel.address,
                op: Op.OP_COOPERATIVE_CLOSE,
                aborted: true,
                exitCode: Errors.ERROR_WRONG_TAG
            });
        }
    });
    it('should reject cooperativeClose on different channelId', async  () => {
        const dataBefore = await tonChannel.getChannelData();
        const {sentA, sentB} = calcSends(dataBefore);

        const origId = tonChannelConfig.id;

        const oneBelow = origId - 1n
        const rndBelow = origId - BigInt(getRandomInt(2, Number(origId - 1n)));

        const oneAbove = origId + 1n
        const rndAbove = origId + BigInt(getRandomInt(2, Number(origId)));

        const closeState: CloseState = {
            seqnoA: dataBefore.seqnoA,
            seqnoB: dataBefore.seqnoB,
            sentA,
            sentB
        };


        for(let testWallet of [walletA, walletB]) {
            for(let testId of [oneBelow, oneAbove, rndBelow, rndAbove]) {
                const closeBody = PaymentChannel.cooperativeCloseBody(closeState, testId);

                const sigA = await signCell(closeBody, keysA.secretKey);
                const sigB = await signCell(closeBody, keysB.secretKey);

                const res = await tonChannel.sendCooperativeClose(testWallet.getSender(), {state: closeBody, sigA, sigB});

                expect(res.transactions).toHaveTransaction({
                    on: tonChannel.address,
                    op: Op.OP_COOPERATIVE_CLOSE,
                    aborted: true,
                    exitCode: Errors.ERROR_WRONG_CHANNEL_ID
                });
            }
        }
    });
    it('both seqno should be incremented on cooperativeClose', async () => {
        const dataBefore = await tonChannel.getChannelData();
        const {sentA, sentB} = calcSends(dataBefore);

        const origSeqno = {seqnoA: dataBefore.seqnoA, seqnoB: dataBefore.seqnoB};
        const Alower = {seqnoA: dataBefore.seqnoA -1n, seqnoB: dataBefore.seqnoB};
        const Blower = {seqnoA: dataBefore.seqnoA, seqnoB: dataBefore.seqnoB - 1n};
        const onlyA  = {seqnoA: dataBefore.seqnoA + 1n, seqnoB: dataBefore.seqnoB}
        const onlyB  = {seqnoA: dataBefore.seqnoA, seqnoB: dataBefore.seqnoB + 1n}

        for(let testWallet of [walletA, walletB]) {
            for(let testSeqno of [origSeqno, Alower, Blower, onlyA, onlyB]) {
                const closeState: CloseState = {
                    seqnoA: testSeqno.seqnoA,
                    seqnoB: testSeqno.seqnoB,
                    sentA,
                    sentB
                };

                const closeBody = PaymentChannel.cooperativeCloseBody(closeState, tonChannelConfig.id);
                const sigA = await signCell(closeBody, keysA.secretKey);
                const sigB = await signCell(closeBody, keysB.secretKey);

                const res = await tonChannel.sendCooperativeClose(testWallet.getSender(), {state: closeBody, sigA, sigB});

                expect(res.transactions).toHaveTransaction({
                    on: tonChannel.address,
                    op: Op.OP_COOPERATIVE_CLOSE,
                    aborted: true,
                    exitCode: Errors.ERROR_SEQNO_REGRESS
                });
            }
        }
    });
    it('should reject cooperative close with invalid signature', async () => {
        const dataBefore = await tonChannel.getChannelData();
        const {sentA, sentB} = calcSends(dataBefore);

        const closeState: CloseState = {
            seqnoA: dataBefore.seqnoA + 1n,
            seqnoB: dataBefore.seqnoB + 1n,
            sentA,
            sentB
        }

        const closeBody = PaymentChannel.cooperativeCloseBody(closeState, tonChannelConfig.id);
        const sigA = await signCell(closeBody, keysA.secretKey);
        const sigB = await signCell(closeBody, keysB.secretKey);

        for(let testWallet of [walletA, walletB]) {
            // Just swith the signatures around
            const res = await tonChannel.sendCooperativeClose(testWallet.getSender(), {state: closeState, sigA: sigB, sigB: sigA});

            expect(res.transactions).toHaveTransaction({
                on: tonChannel.address,
                op: Op.OP_COOPERATIVE_CLOSE,
                aborted: true,
                exitCode: Errors.ERROR_NOT_AUTHORIZED
            });
        }
    });
    it('should be able to close channel cooperatively', async () => {
        const prevState  = blockchain.snapshot();

        const dataBefore = await tonChannel.getChannelData();
        const {sentA, sentB} = calcSends(dataBefore);

        const msgValue = toNano('0.05');

        const addSentA = BigInt(getRandomInt(1, 100_000));
        const addSentB = BigInt(getRandomInt(1, 100_000));

        const delta = addSentA - addSentB;

        let expectedA = dataBefore.balance.balanceA;
        let expectedB = dataBefore.balance.balanceB;

        expectedA -= delta;
        expectedB += delta;

        const closeState: CloseState = {
            seqnoA: dataBefore.seqnoA + 1n,
            seqnoB: dataBefore.seqnoB + 1n,
            sentA: sentA + addSentA,
            sentB: sentB + addSentB
        }

        const closeBody = PaymentChannel.cooperativeCloseBody(closeState, tonChannelConfig.id);

        const sigA = await signCell(closeBody, keysA.secretKey);
        const sigB = await signCell(closeBody, keysB.secretKey);

        const jettonA = await userJetton(walletA.address);
        const jettonB = await userJetton(walletB.address);

        const smc = await blockchain.getContract(tonChannel.address);
        for(let testWallet of [walletA, walletB]) {
            try {

                const balanceBeforeA = await jettonA.getJettonBalance();
                const balanceBeforeB = await jettonB.getJettonBalance();

                const res = await tonChannel.sendCooperativeClose(testWallet.getSender(), {state: closeState, sigA, sigB}, msgValue);
                expect(res.transactions).toHaveTransaction({
                    on: tonChannel.address,
                    op: Op.OP_COOPERATIVE_CLOSE,
                    aborted: false,
                    outMessagesCount: 2
                });
                expect(res.transactions).toHaveTransaction({
                    on: jettonA.address,
                    op: JettonOp.internal_transfer,
                    aborted: false
                });
                expect(res.transactions).toHaveTransaction({
                    on: jettonB.address,
                    op: JettonOp.internal_transfer,
                    aborted: false
                });
                // Fixating notification logic
                await assertJettonNotification(res.transactions, walletA.address, tonChannel.address, expectedA, channelClosedPayload);
                await assertJettonNotification(res.transactions, walletB.address, tonChannel.address, expectedB, channelClosedPayload);

                // Expect balance leftowers to go to A through excess
                expect(res.transactions).toHaveTransaction({
                    on: walletA.address,
                    op: JettonOp.excesses
                });

                // Check that jetton balance increased accordingly
                expect(await jettonA.getJettonBalance()).toEqual(balanceBeforeA + expectedA)
                expect(await jettonB.getJettonBalance()).toEqual(balanceBeforeB + expectedB)
                const dataAfter = await tonChannel.getChannelData();

                expect(smc.balance).toBe(0n);
                assertChannelClosed(dataAfter, closeState.seqnoA, closeState.seqnoB);
            } finally {
                await blockchain.loadFrom(prevState);
            }
        }
    });
    it('should be able to start uncooperative close', async () => {

        const prevState   = blockchain.snapshot();

        const stateBefore = await tonChannel.getChannelData();
        const {sentA, sentB} = calcSends(stateBefore);

        expect(stateBefore.quarantine).toBeNull();

        // Let's imagine  that right after cooperative commit,
        // counterparty went offline, and never came back
        // The other party should have boths signed SemiChannel states at this point

        const stateA = signSemiChannel({
            channelId: tonChannelConfig.id,
            data: {
                sent: sentA,
                seqno: stateBefore.seqnoA,
                conditionalsHash
            },
            // If commited seqno > 0 counterparty data should be present???
            counterpartyData: {
                sent: sentB,
                seqno: stateBefore.seqnoB,
                conditionalsHash
            }
        }, keysA.secretKey);
        const stateB = signSemiChannel({
            channelId: tonChannelConfig.id,
            data: {
                sent: sentB,
                seqno: stateBefore.seqnoB,
                conditionalsHash
            },
            counterpartyData: {
                sent: sentA,
                seqno: stateBefore.seqnoA,
                conditionalsHash
            }
        }, keysB.secretKey)

        for(let testWallet of [walletA, walletB]) {
            const isA = testWallet === walletA;
            let walletKey = isA ? keysA.secretKey : keysB.secretKey;

            const res = await tonChannel.sendStartUncoopClose(testWallet.getSender(), {
                isA,
                stateA,
                stateB,
                key: walletKey
            });

            const startTx = findTransactionRequired(res.transactions,({
                on: tonChannel.address,
                op: Op.OP_START_UNCOOPERATIVE_CLOSE,
                aborted: false
            }));

            const dataAfter = await tonChannel.getChannelData();
            expect(dataAfter.quarantine).not.toBeNull();
            const quarantine = dataAfter.quarantine!;
            expect(quarantine.startedAt).toEqual(startTx.now);
            expect(quarantine.challenged).toBe(false);
            expect(quarantine.committedbyA).toBe(isA);

            if(isA) {
                quarantineStartedA = blockchain.snapshot();
            } else {
                quarantineStartedB = blockchain.snapshot();
            }
            await blockchain.loadFrom(prevState);
        }
    });
    it('should not accept uncooperative close with invalid signature', async () => {
        const stateBefore = await tonChannel.getChannelData();
        const {sentA, sentB} = calcSends(stateBefore);

        expect(stateBefore.quarantine).toBeNull();

        const stateBodyA: SemiChannelBody = {
            sent: sentA,
            seqno: stateBefore.seqnoA,
            conditionalsHash
        };

        const stateBodyB: SemiChannelBody = {
            sent: sentB,
            seqno: stateBefore.seqnoB,
            conditionalsHash
        }

        const stateA = signSemiChannel({
            channelId: tonChannelConfig.id,
            data: stateBodyA,
            counterpartyData: stateBodyB
        }, keysA.secretKey);

        const invalidStateA = signSemiChannel({
            channelId: tonChannelConfig.id,
            data: stateBodyA,
            counterpartyData: stateBodyB
            // Different key
        }, keysB.secretKey);


        const stateB = signSemiChannel({
            channelId: tonChannelConfig.id,
            data: stateBodyB,
            counterpartyData: stateBodyA
        }, keysB.secretKey);

        const invalidStateB = signSemiChannel({
            channelId: tonChannelConfig.id,
            data: stateBodyB,
            counterpartyData: stateBodyA
        }, keysA.secretKey);

        const invalidKey = async(wallet: SandboxContract<TreasuryContract>, isA: boolean) => {
            const randomKp = keyPairFromSeed(await getSecureRandomBytes(32));
            return await tonChannel.sendStartUncoopClose(wallet.getSender(), {
                isA,
                stateA,
                stateB,
                key: randomKp.secretKey
            });
        };
        const invalidA = async(wallet: SandboxContract<TreasuryContract>, isA: boolean) => {
            const key = isA ? keysA.secretKey : keysB.secretKey;

            return await tonChannel.sendStartUncoopClose(wallet.getSender(), {
                isA,
                stateA: invalidStateA,
                stateB,
                key
            });
        }
        const invalidB = async(wallet: SandboxContract<TreasuryContract>, isA: boolean) => {
            const key = isA ? keysA.secretKey : keysB.secretKey;

            return await tonChannel.sendStartUncoopClose(wallet.getSender(), {
                isA,
                stateA,
                stateB: invalidStateB,
                key
            });
        }

        for(let testWallet of [walletA, walletB]) {
            const isA = testWallet === walletA;

            for(let testCase of [invalidKey, invalidA, invalidB]) {
                const res = await testCase(testWallet, isA);
                expect(res.transactions).toHaveTransaction({
                    on: tonChannel.address,
                    op: Op.OP_START_UNCOOPERATIVE_CLOSE,
                    aborted: true,
                    exitCode: Errors.ERROR_NOT_AUTHORIZED
                });
            }
        }
    });
    it('should not accept uncooperative close for different channelId', async () => {
        const stateBefore = await tonChannel.getChannelData();
        const {sentA, sentB} = calcSends(stateBefore);

        expect(stateBefore.quarantine).toBeNull();

        const stateBodyA: SemiChannelBody = {
            sent: sentA,
            seqno: stateBefore.seqnoA,
            conditionalsHash
        };

        const stateBodyB: SemiChannelBody = {
            sent: sentB,
            seqno: stateBefore.seqnoB,
            conditionalsHash
        };
        const stateA: SemiChannel = {
            channelId: tonChannelConfig.id,
            data: stateBodyA,
            counterpartyData: stateBodyB
        }


        const stateB: SemiChannel = {
            channelId: tonChannelConfig.id,
            data: stateBodyB,
            counterpartyData: stateBodyA
        };

        for(let testWallet of [walletA, walletB]) {
            const isA = testWallet === walletA;
            const key = isA ? keysA.secretKey : keysB.secretKey;

            let i = 0;
            for(let channelId of [tonChannelConfig.id + 1n, tonChannelConfig.id - 1n]) {
                let signedA: Cell;
                let signedB: Cell;

                if(i++ % 2 == 0) {
                    signedA = signSemiChannel({...stateA, channelId: channelId}, keysA.secretKey);
                    signedB = signSemiChannel(stateB, keysB.secretKey);
                } else {
                    signedA = signSemiChannel(stateA, keysA.secretKey);
                    signedB = signSemiChannel({...stateB, channelId: channelId}, keysB.secretKey);
                }
                const res = await tonChannel.sendStartUncoopClose(testWallet.getSender(), {
                    isA,
                    stateA: signedA,
                    stateB: signedB,
                    key
                });

                expect(res.transactions).toHaveTransaction({
                    on: tonChannel.address,
                    op: Op.OP_START_UNCOOPERATIVE_CLOSE,
                    aborted: true,
                    exitCode: Errors.ERROR_WRONG_CHANNEL_ID
                });
            }
        }
    });
    it('should not accept outdated states for uncooperative close', async () => {
        const stateBefore = await tonChannel.getChannelData();
        const {sentA, sentB} = calcSends(stateBefore);

        expect(stateBefore.quarantine).toBeNull();

        const stateBodyA: SemiChannelBody = {
            sent: sentA,
            seqno: stateBefore.seqnoA,
            conditionalsHash
        };

        const stateBodyB: SemiChannelBody = {
            sent: sentB,
            seqno: stateBefore.seqnoB,
            conditionalsHash
        }

        const stateB = signSemiChannel({
            channelId: tonChannelConfig.id,
            data: stateBodyB,
            counterpartyData: stateBodyA
        }, keysB.secretKey);


        const stateA = signSemiChannel({
            channelId: tonChannelConfig.id,
            data: stateBodyA,
            counterpartyData: stateBodyB
        }, keysA.secretKey);


        const invalidSeqnoA = signSemiChannel({
            channelId: tonChannelConfig.id,
            data: {...stateBodyA, seqno: stateBefore.seqnoA - 1n},
            counterpartyData: stateBodyB
        }, keysA.secretKey);

        const invalidSeqnoB = signSemiChannel({
            channelId: tonChannelConfig.id,
            data: {...stateBodyB, seqno: stateBefore.seqnoB - 1n},
            counterpartyData: stateBodyA
        }, keysB.secretKey);

        const invalidCounterpartySeqnoA = signSemiChannel({
            channelId: tonChannelConfig.id,
            data: {...stateBodyA, seqno: stateBefore.seqnoA - 1n},
            counterpartyData: {...stateBodyB, seqno: stateBefore.seqnoB - 1n}
        }, keysA.secretKey);

        const invalidCounterpartySeqnoB = signSemiChannel({
            channelId: tonChannelConfig.id,
            data: stateBodyB,
            counterpartyData: {...stateBodyA, seqno: stateBefore.seqnoA - 1n}
        }, keysB.secretKey);


        const counterpartySeqnoGreaterA = signSemiChannel({
            channelId: tonChannelConfig.id,
            data: stateBodyA,
            counterpartyData: {...stateBodyB, seqno: stateBodyA.seqno + 1n}
        }, keysA.secretKey);

        const counterpartySeqnoGreaterB = signSemiChannel({
            channelId: tonChannelConfig.id,
            data: stateBodyB,
            counterpartyData: {...stateBodyA, seqno: stateBodyB.seqno + 1n}
        }, keysB.secretKey);

        const counterpartySentGreaterA = signSemiChannel({
            channelId: tonChannelConfig.id,
            data: stateBodyA,
            counterpartyData: {...stateBodyB, seqno: stateBodyA.sent + 1n}
        }, keysA.secretKey);

        const counterpartySentGreaterB = signSemiChannel({
            channelId: tonChannelConfig.id,
            data: stateBodyB,
            counterpartyData: {...stateBodyA, seqno: stateBodyB.sent + 1n}
        }, keysB.secretKey);


        const testCases = [
            invalidSeqnoA,
            invalidSeqnoB,
            invalidCounterpartySeqnoA,
            invalidCounterpartySeqnoB,
            counterpartySeqnoGreaterA,
            counterpartySeqnoGreaterB,
            counterpartySentGreaterA,
            counterpartySentGreaterB,
            counterpartySentGreaterA,
            counterpartySentGreaterB
        ];

        for(let testWallet of [walletA, walletB]) {
            const isA = testWallet === walletA;
            const key = isA ? keysA.secretKey : keysB.secretKey;
            let i = 0;
            for(let testCase of testCases) {
                let signedA: Cell;
                let signedB: Cell;

                if(i++ % 2 == 0) {
                    signedA = testCase;
                    signedB = stateB;
                } else {
                    signedA = stateA;
                    signedB = testCase;
                }
                const res = await tonChannel.sendStartUncoopClose(testWallet.getSender(), {
                    isA,
                    stateA: signedA,
                    stateB: signedB,
                    key
                });

                expect(res.transactions).toHaveTransaction({
                    on: tonChannel.address,
                    op: Op.OP_START_UNCOOPERATIVE_CLOSE,
                    aborted: true,
                    exitCode: Errors.ERROR_OUTDATED_STATE
                });
            }
        }
    });

    it('should accept signed state without counterparty data', async () => {
        const prevState   = blockchain.snapshot();
        const stateBefore = await tonChannel.getChannelData();
        const {sentA, sentB} = calcSends(stateBefore);

        expect(stateBefore.quarantine).toBeNull();

        const stateBodyA: SemiChannelBody = {
            sent: sentA,
            seqno: stateBefore.seqnoA,
            conditionalsHash
        };

        const stateBodyB: SemiChannelBody = {
            sent: sentB,
            seqno: stateBefore.seqnoB,
            conditionalsHash
        };
        const stateB = signSemiChannel({
            channelId: tonChannelConfig.id,
            data: stateBodyB,
        }, keysB.secretKey);


        const stateA = signSemiChannel({
            channelId: tonChannelConfig.id,
            data: stateBodyA,
        }, keysA.secretKey);


        for(let testWallet of [walletA, walletB]) {
            const isA = testWallet === walletA;
            const key = isA ? keysA.secretKey : keysB.secretKey;

            const res = await tonChannel.sendStartUncoopClose(testWallet.getSender(), {
                isA,
                stateA,
                stateB,
                key
            });
            const startTx = findTransactionRequired(res.transactions, {
                on: tonChannel.address,
                op: Op.OP_START_UNCOOPERATIVE_CLOSE,
                aborted: false
            });

            const dataAfter = await tonChannel.getChannelData();
            expect(dataAfter.quarantine).not.toBeNull();
            const quarantine = dataAfter.quarantine!;
            expect(quarantine.startedAt).toEqual(startTx.now);
            expect(quarantine.challenged).toBe(false);
            expect(quarantine.committedbyA).toBe(isA);

            await blockchain.loadFrom(prevState);
        }
    });
    it('should be able to challenge quarantine', async () => {
        const prevState   = blockchain.snapshot();

        try {
            for(let testState of [quarantineStartedA, quarantineStartedB]) {
                await blockchain.loadFrom(testState);

                const dataBefore = await tonChannel.getChannelData();

                expect(dataBefore.quarantine).not.toBeNull();
                const quarantineBefore = dataBefore.quarantine!;

                const prevA: SemiChannel = {
                    channelId: tonChannelConfig.id,
                    data: quarantineBefore.stateA
                };
                const prevB: SemiChannel = {
                    channelId: tonChannelConfig.id,
                    data: quarantineBefore.stateB
                };

                const aNextSeqno: SemiChannel = {
                    channelId: tonChannelConfig.id,
                    data: {...quarantineBefore.stateA, seqno: quarantineBefore.stateA.seqno + BigInt(getRandomInt(1, 100))},
                };
                const aMoreSent: SemiChannel  = {
                    channelId: tonChannelConfig.id,
                    data: {...quarantineBefore.stateA, sent: quarantineBefore.stateA.sent + BigInt(getRandomInt(1, 100))},
                };

                const bNextSeqno: SemiChannel = {
                    channelId: tonChannelConfig.id,
                    data: {...quarantineBefore.stateB, seqno: quarantineBefore.stateB.seqno + BigInt(getRandomInt(1, 100))}
                };
                const bMoreSent : SemiChannel = {
                    channelId: tonChannelConfig.id,
                    data: {...quarantineBefore.stateB, sent: quarantineBefore.stateB.sent + BigInt(getRandomInt(1, 100))},
                };

                // I'm aware there are more permutations
                let setA = [[aNextSeqno, prevB], [aMoreSent, prevB], [aNextSeqno, bNextSeqno]];
                let setB = [[prevA, bNextSeqno], [prevB, bMoreSent], [aNextSeqno, bNextSeqno]];

                const isA = testState === quarantineStartedB;

                let testSet: SemiChannel[][];
                let testWallet: SandboxContract<TreasuryContract>;
                let signKey: Buffer;

                if(isA) {
                    // A challenges B state
                    testSet = setB;
                    testWallet = walletA;
                    signKey = keysA.secretKey;
                } else {
                    // B challenges A state
                    testSet = setA;
                    testWallet = walletB;
                    signKey = keysB.secretKey;
                }

                for(let testCase of testSet) {
                    const stateA = signSemiChannel(testCase[0], keysA.secretKey);
                    const stateB = signSemiChannel(testCase[1], keysB.secretKey);

                    const res = await tonChannel.sendChallengeQuarantine(testWallet.getSender(), {
                        isA,
                        stateA,
                        stateB,
                        key: signKey
                    });

                    expect(res.transactions).toHaveTransaction({
                        on: tonChannel.address,
                        from: testWallet.address,
                        op: Op.OP_CHALLENGE_QUARANTINEED_STATE,
                        aborted: false
                    });

                    const dataAfter = await tonChannel.getChannelData();
                    expect(dataAfter.quarantine).not.toBeNull();
                    expect(dataAfter.quarantine!.challenged).toBe(true);

                    if(isA) {
                        expect(dataAfter.quarantine!.stateB).toEqual({...testCase[1].data, sent: testCase[1].data.sent + tonChannelConfig.closureConfig.fine});
                        expect(dataAfter.quarantine!.stateA).toEqual(quarantineBefore.stateA);
                        quarantineChallengedA = blockchain.snapshot();
                    } else {
                        expect(dataAfter.quarantine!.stateA).toEqual({...testCase[0].data, sent: testCase[0].data.sent + tonChannelConfig.closureConfig.fine});
                        expect(dataAfter.quarantine!.stateB).toEqual(quarantineBefore.stateB);
                        quarantineChallengedB = blockchain.snapshot();
                    }

                    await blockchain.loadFrom(testState);
                }
            }
        } finally {
            await blockchain.loadFrom(prevState);
        }
    });
    it('only counterparty should be able to challenge quarantine', async () => {
        const prevState = blockchain.snapshot();

        for(let testState of [quarantineStartedA, quarantineStartedB]) {
            await blockchain.loadFrom(testState);
            const dataBefore = await tonChannel.getChannelData();

            expect(dataBefore.quarantine).not.toBeNull();
            const quarantineBefore = dataBefore.quarantine!;

            const prevA: SemiChannel = {
                channelId: tonChannelConfig.id,
                data: quarantineBefore.stateA
            };
            const prevB: SemiChannel = {
                channelId: tonChannelConfig.id,
                data: quarantineBefore.stateB
            };

            const aNextSeqno: SemiChannel = {
                channelId: tonChannelConfig.id,
                data: {...quarantineBefore.stateA, seqno: quarantineBefore.stateA.seqno + BigInt(getRandomInt(1, 100))},
            };
            const bNextSeqno: SemiChannel = {
                channelId: tonChannelConfig.id,
                data: {...quarantineBefore.stateB, seqno: quarantineBefore.stateB.seqno + BigInt(getRandomInt(1, 100))}
            };

            // Opposite of what would be correct
            const isA = testState === quarantineStartedA;

            let testCase: {
                stateA: Cell,
                stateB: Cell
            };
            let testWallet: SandboxContract<TreasuryContract>;
            let signKey: Buffer;

            if(isA) {
                testCase = {
                    stateA: signSemiChannel(prevA, keysA.secretKey),
                    stateB: signSemiChannel(bNextSeqno, keysB.secretKey)
                };
                testWallet = walletA;
                signKey = keysA.secretKey;
            } else {
                testCase = {
                    stateA: signSemiChannel(aNextSeqno, keysA.secretKey),
                    stateB: signSemiChannel(prevB, keysB.secretKey)
                };

                testWallet = walletB;
                signKey = keysB.secretKey;
            }

            const res = await tonChannel.sendChallengeQuarantine(testWallet.getSender(), {
                isA,
                stateA: testCase.stateA,
                stateB: testCase.stateB,
                key: signKey,
            });

            expect(res.transactions).toHaveTransaction({
                on: tonChannel.address,
                from: testWallet.address,
                op: Op.OP_CHALLENGE_QUARANTINEED_STATE,
                aborted: true,
                exitCode: Errors.ERROR_UNAUTHORIZED_CHALLENGE
            });
        }

        await blockchain.loadFrom(prevState);
    });
    it('should check message signature for quarantine challenge', async () => {
        const prevState = blockchain.snapshot();

        for(let testState of [quarantineStartedA, quarantineStartedB]) {
            await blockchain.loadFrom(testState);
            const dataBefore = await tonChannel.getChannelData();

            expect(dataBefore.quarantine).not.toBeNull();
            const quarantineBefore = dataBefore.quarantine!;

            const prevA: SemiChannel = {
                channelId: tonChannelConfig.id,
                data: quarantineBefore.stateA
            };
            const prevB: SemiChannel = {
                channelId: tonChannelConfig.id,
                data: quarantineBefore.stateB
            };

            const aNextSeqno: SemiChannel = {
                channelId: tonChannelConfig.id,
                data: {...quarantineBefore.stateA, seqno: quarantineBefore.stateA.seqno + BigInt(getRandomInt(1, 100))},
            };
            const bNextSeqno: SemiChannel = {
                channelId: tonChannelConfig.id,
                data: {...quarantineBefore.stateB, seqno: quarantineBefore.stateB.seqno + BigInt(getRandomInt(1, 100))}
            };

            const isA = testState === quarantineStartedB;

            let testCase: {
                stateA: Cell,
                stateB: Cell
            };
            let testWallet: SandboxContract<TreasuryContract>;
            let signKey: Buffer;

            if(isA) {
                testCase = {
                    stateA: signSemiChannel(prevA, keysA.secretKey),
                    stateB: signSemiChannel(bNextSeqno, keysB.secretKey)
                };
                testWallet = walletA;
                // Key B for A
                signKey = keysB.secretKey;
            } else {
                testCase = {
                    stateA: signSemiChannel(aNextSeqno, keysA.secretKey),
                    stateB: signSemiChannel(prevB, keysB.secretKey)
                };

                testWallet = walletB;
                // Key A for B
                signKey = keysA.secretKey;
            }

            const res = await tonChannel.sendChallengeQuarantine(testWallet.getSender(), {
                isA,
                stateA: testCase.stateA,
                stateB: testCase.stateB,
                key: signKey,
            });

            expect(res.transactions).toHaveTransaction({
                on: tonChannel.address,
                from: testWallet.address,
                op: Op.OP_CHALLENGE_QUARANTINEED_STATE,
                aborted: true,
                exitCode: Errors.ERROR_NOT_AUTHORIZED
            });
        }

        await blockchain.loadFrom(prevState);
    });
    it('should check state signature for quarantine callenge', async () => {
        const prevState = blockchain.snapshot();

        for(let testState of [quarantineStartedA, quarantineStartedB]) {
            await blockchain.loadFrom(testState);
            const dataBefore = await tonChannel.getChannelData();

            expect(dataBefore.quarantine).not.toBeNull();
            const quarantineBefore = dataBefore.quarantine!;

            const prevA: SemiChannel = {
                channelId: tonChannelConfig.id,
                data: quarantineBefore.stateA
            };
            const prevB: SemiChannel = {
                channelId: tonChannelConfig.id,
                data: quarantineBefore.stateB
            };

            const aNextSeqno: SemiChannel = {
                channelId: tonChannelConfig.id,
                data: {...quarantineBefore.stateA, seqno: quarantineBefore.stateA.seqno + BigInt(getRandomInt(1, 100))},
            };
            const bNextSeqno: SemiChannel = {
                channelId: tonChannelConfig.id,
                data: {...quarantineBefore.stateB, seqno: quarantineBefore.stateB.seqno + BigInt(getRandomInt(1, 100))}
            };

            const isA = testState === quarantineStartedB;

            let testCase: {
                stateA: Cell,
                stateB: Cell
            };
            let testWallet: SandboxContract<TreasuryContract>;
            let signKey: Buffer;

            if(isA) {
                testCase = {
                    stateA: signSemiChannel(prevA, keysA.secretKey),
                    // State B signed with key A
                    stateB: signSemiChannel(bNextSeqno, keysA.secretKey)
                };
                testWallet = walletA;
                signKey = keysA.secretKey;
            } else {
                testCase = {
                    // State a signed with key B
                    stateA: signSemiChannel(aNextSeqno, keysB.secretKey),
                    stateB: signSemiChannel(prevB, keysB.secretKey)
                };

                testWallet = walletB;
                signKey = keysB.secretKey;
            }

            const res = await tonChannel.sendChallengeQuarantine(testWallet.getSender(), {
                isA,
                stateA: testCase.stateA,
                stateB: testCase.stateB,
                key: signKey,
            });

            expect(res.transactions).toHaveTransaction({
                on: tonChannel.address,
                from: testWallet.address,
                op: Op.OP_CHALLENGE_QUARANTINEED_STATE,
                aborted: true,
                exitCode: Errors.ERROR_NOT_AUTHORIZED
            });
        }

        await blockchain.loadFrom(prevState);

    });
    it('should check for channelId for quarantine challenge', async () => {
        const origId = tonChannelConfig.id;

        const oneBelow = origId - 1n
        const rndBelow = origId - BigInt(getRandomInt(2, Number(origId - 1n)));

        const oneAbove = origId + 1n
        const rndAbove = origId + BigInt(getRandomInt(2, Number(origId)));

        const prevState = blockchain.snapshot();

        for(let testState of [quarantineStartedA, quarantineStartedB]) {
            await blockchain.loadFrom(testState);
            const dataBefore = await tonChannel.getChannelData();

            expect(dataBefore.quarantine).not.toBeNull();
            const quarantineBefore = dataBefore.quarantine!;

            const prevA = signSemiChannel({
                channelId: tonChannelConfig.id,
                data: quarantineBefore.stateA
            }, keysA.secretKey);

            const prevB = signSemiChannel({
                channelId: tonChannelConfig.id,
                data: quarantineBefore.stateB
            }, keysB.secretKey);

            const aNextSeqno: SemiChannel = {
                channelId: tonChannelConfig.id,
                data: {...quarantineBefore.stateA, seqno: quarantineBefore.stateA.seqno + BigInt(getRandomInt(1, 100))},
            };
            const bNextSeqno: SemiChannel = {
                channelId: tonChannelConfig.id,
                data: {...quarantineBefore.stateB, seqno: quarantineBefore.stateB.seqno + BigInt(getRandomInt(1, 100))}
            };

            const isA = testState === quarantineStartedB;

            let testCases: {
                stateA: Cell,
                stateB: Cell,
                channelId: bigint;
            }[];           let testWallet: SandboxContract<TreasuryContract>;
            let signKey: Buffer;

            for(let testId of [oneBelow, oneAbove, rndAbove, rndBelow]) {
                const invalidStateA = signSemiChannel({...aNextSeqno, channelId: testId}, keysA.secretKey);
                const invalidStateB = signSemiChannel({...bNextSeqno, channelId: testId}, keysB.secretKey);

                if(isA) {
                    testCases = [
                        // Correct challenge state, but invalid id
                        {
                            channelId: testId,
                            stateA: prevA,
                            stateB: signSemiChannel(bNextSeqno, keysB.secretKey)
                        },
                        // Oposite valid id in message, but invalid chanel id in state
                        {
                            channelId: origId,
                            stateA: prevA,
                            stateB: invalidStateB
                        }
                    ];
                    testWallet = walletA;
                    signKey = keysA.secretKey;
                } else {
                    testCases = [
                        {
                            channelId: testId,
                            stateA: signSemiChannel(aNextSeqno, keysA.secretKey),
                            stateB: prevB
                        },
                        {
                            channelId: origId,
                            stateA: invalidStateA,
                            stateB: prevB
                        }
                    ];

                    testWallet = walletB;
                    signKey = keysB.secretKey;
                }


                for(let testCase of testCases) {
                    const res = await tonChannel.sendChallengeQuarantine(testWallet.getSender(), {
                        isA,
                        stateA: testCase.stateA,
                        stateB: testCase.stateB,
                        key: signKey,
                    }, testCase.channelId);

                    expect(res.transactions).toHaveTransaction({
                        on: tonChannel.address,
                        from: testWallet.address,
                        op: Op.OP_CHALLENGE_QUARANTINEED_STATE,
                        aborted: true,
                        exitCode: Errors.ERROR_WRONG_CHANNEL_ID
                    });
                }
            }
        }

        await blockchain.loadFrom(prevState);
    });
    it('should reject startUncooperativeClose for challenge quarantine message', async () => {
        const prevState = blockchain.snapshot();

        for(let testState of [quarantineStartedA, quarantineStartedB]) {
            await blockchain.loadFrom(testState);
            const dataBefore = await tonChannel.getChannelData();

            expect(dataBefore.quarantine).not.toBeNull();
            const quarantineBefore = dataBefore.quarantine!;


            const isA = testState == quarantineStartedB;
            const testWallet = isA ? walletA : walletB;

            const prevA = signSemiChannel({
                channelId: tonChannelConfig.id,
                data: quarantineBefore.stateA
            }, keysA.secretKey);

            const prevB = signSemiChannel({
                channelId: tonChannelConfig.id,
                data: quarantineBefore.stateB
            }, keysB.secretKey);

            const aNextSeqno = signSemiChannel({
                channelId: tonChannelConfig.id,
                data: {...quarantineBefore.stateA, seqno: quarantineBefore.stateA.seqno + BigInt(getRandomInt(1, 100))},
            }, keysA.secretKey);
            const bNextSeqno = signSemiChannel({
                channelId: tonChannelConfig.id,
                data: {...quarantineBefore.stateB, seqno: quarantineBefore.stateB.seqno + BigInt(getRandomInt(1, 100))}
            }, keysB.secretKey);

            let startUncoopMessage: Cell;

            if(isA) {
                startUncoopMessage = PaymentChannel.uncooperativeCloseMessage(isA, prevA, bNextSeqno, keysA.secretKey, tonChannelConfig.id);
            } else {
                startUncoopMessage = PaymentChannel.uncooperativeCloseMessage(isA, aNextSeqno, prevB, keysB.secretKey, tonChannelConfig.id);
            }

            // Now gotta switch the OP

            const msgPayload = beginCell().storeUint(Op.OP_CHALLENGE_QUARANTINEED_STATE, 32)
                                          .storeSlice(
                                              startUncoopMessage.asSlice().skip(32)
                                          ).endCell();
            const res = await testWallet.send({
                to: tonChannel.address,
                body: msgPayload,
                value: toNano('1'),
            });

            expect(res.transactions).toHaveTransaction({
                on: tonChannel.address,
                from: testWallet.address,
                op: Op.OP_CHALLENGE_QUARANTINEED_STATE,
                aborted: true,
                exitCode: Errors.ERROR_WRONG_TAG
            });
        }
        await blockchain.loadFrom(prevState);

    });
    it('should not accept outdated states for quarantine challenge', async () => {
        const stateBefore = await tonChannel.getChannelData();
        const {sentA, sentB} = calcSends(stateBefore);

        expect(stateBefore.quarantine).toBeNull();

        const stateBodyA: SemiChannelBody = {
            sent: sentA,
            seqno: stateBefore.seqnoA,
            conditionalsHash
        };

        const stateBodyB: SemiChannelBody = {
            sent: sentB,
            seqno: stateBefore.seqnoB,
            conditionalsHash
        }

        const stateB = signSemiChannel({
            channelId: tonChannelConfig.id,
            data: stateBodyB,
            counterpartyData: stateBodyA
        }, keysB.secretKey);


        const stateA = signSemiChannel({
            channelId: tonChannelConfig.id,
            data: stateBodyA,
            counterpartyData: stateBodyB
        }, keysA.secretKey);


        const invalidSeqnoA = signSemiChannel({
            channelId: tonChannelConfig.id,
            data: {...stateBodyA, seqno: stateBefore.seqnoA - 1n},
            counterpartyData: stateBodyB
        }, keysA.secretKey);

        const invalidSeqnoB = signSemiChannel({
            channelId: tonChannelConfig.id,
            data: {...stateBodyB, seqno: stateBefore.seqnoB - 1n},
            counterpartyData: stateBodyA
        }, keysB.secretKey);

        const invalidCounterpartySeqnoA = signSemiChannel({
            channelId: tonChannelConfig.id,
            data: {...stateBodyA, seqno: stateBefore.seqnoA - 1n},
            counterpartyData: {...stateBodyB, seqno: stateBefore.seqnoB - 1n}
        }, keysA.secretKey);

        const invalidCounterpartySeqnoB = signSemiChannel({
            channelId: tonChannelConfig.id,
            data: stateBodyB,
            counterpartyData: {...stateBodyA, seqno: stateBefore.seqnoA - 1n}
        }, keysB.secretKey);


        const counterpartySeqnoGreaterA = signSemiChannel({
            channelId: tonChannelConfig.id,
            data: stateBodyA,
            counterpartyData: {...stateBodyB, seqno: stateBodyA.seqno + 1n}
        }, keysA.secretKey);

        const counterpartySeqnoGreaterB = signSemiChannel({
            channelId: tonChannelConfig.id,
            data: stateBodyB,
            counterpartyData: {...stateBodyA, seqno: stateBodyB.seqno + 1n}
        }, keysB.secretKey);

        const counterpartySentGreaterA = signSemiChannel({
            channelId: tonChannelConfig.id,
            data: stateBodyA,
            counterpartyData: {...stateBodyB, seqno: stateBodyA.sent + 1n}
        }, keysA.secretKey);

        const counterpartySentGreaterB = signSemiChannel({
            channelId: tonChannelConfig.id,
            data: stateBodyB,
            counterpartyData: {...stateBodyA, seqno: stateBodyB.sent + 1n}
        }, keysB.secretKey);


        const testCases = [
            invalidSeqnoA,
            invalidSeqnoB,
            invalidCounterpartySeqnoA,
            invalidCounterpartySeqnoB,
            counterpartySeqnoGreaterA,
            counterpartySeqnoGreaterB,
            counterpartySentGreaterA,
            counterpartySentGreaterB,
            counterpartySentGreaterA,
            counterpartySentGreaterB
        ];

        for(let testState of [quarantineStartedA, quarantineStartedB]) {
            let testWallet: SandboxContract<TreasuryContract>;
            let key: Buffer;

            await blockchain.loadFrom(testState);

            const isA = testState === quarantineStartedB;

            if(isA) {
                testWallet = walletA;
                key = keysA.secretKey;
            } else {
                testWallet = walletB;
                key = keysB.secretKey;
            }


            let i = 0;
            for(let testCase of testCases) {
                let signedA: Cell;
                let signedB: Cell;

                if(i++ % 2 == 0) {
                    signedA = testCase;
                    signedB = stateB;
                } else {
                    signedA = stateA;
                    signedB = testCase;
                }
                const res = await tonChannel.sendChallengeQuarantine(testWallet.getSender(), {
                    isA,
                    stateA: signedA,
                    stateB: signedB,
                    key
                });

                expect(res.transactions).toHaveTransaction({
                    on: tonChannel.address,
                    op: Op.OP_CHALLENGE_QUARANTINEED_STATE,
                    aborted: true,
                    exitCode: Errors.ERROR_OUTDATED_STATE
                });
            }
        }
    });
    it('should reject challenge for already challenged quarantine', async () => {
        for(let testState of [quarantineChallengedA, quarantineChallengedB]) {
            await blockchain.loadFrom(testState);
            const dataBefore = await tonChannel.getChannelData();
            expect(dataBefore.quarantine).not.toBeNull();

            const quarantineBefore = dataBefore.quarantine!;

            let testWallet: SandboxContract<TreasuryContract>;
            let key: Buffer;

            const isA = quarantineBefore.committedbyA;

            const prevA = signSemiChannel({
                channelId: tonChannelConfig.id,
                data: quarantineBefore.stateA
            }, keysA.secretKey);

            const prevB = signSemiChannel({
                channelId: tonChannelConfig.id,
                data: quarantineBefore.stateB
            }, keysB.secretKey);

            const aNextSeqno = signSemiChannel({
                channelId: tonChannelConfig.id,
                data: {...quarantineBefore.stateA, seqno: quarantineBefore.stateA.seqno + BigInt(getRandomInt(1, 100))},
            }, keysA.secretKey);
            const bNextSeqno = signSemiChannel({
                channelId: tonChannelConfig.id,
                data: {...quarantineBefore.stateB, seqno: quarantineBefore.stateB.seqno + BigInt(getRandomInt(1, 100))}
            }, keysB.secretKey);


            let testCase :{
                stateA: Cell,
                stateB: Cell
            };
            if(isA) {
                testWallet = walletA;
                key = keysA.secretKey;
                testCase = {
                    stateA: prevA,
                    stateB: bNextSeqno
                };
            } else {
                testWallet = walletB;
                key = keysB.secretKey;
                testCase = {
                    stateA: aNextSeqno,
                    stateB: prevB
                };
            }

            const res = await tonChannel.sendChallengeQuarantine(testWallet.getSender(), {
                isA,
                stateA: testCase.stateA,
                stateB: testCase.stateB,
                key
            });

            expect(res.transactions).toHaveTransaction({
                on: tonChannel.address,
                from: testWallet.address,
                op: Op.OP_CHALLENGE_QUARANTINEED_STATE,
                aborted: true,
                exitCode: Errors.ERROR_QUARANTINEE_ALREADY_CHALLENGED
            });
        }
    });
    it('should not be able to challenge quarantine after quarantine expiration', async () => {

        for(let testState of [quarantineStartedA, quarantineStartedB]) {
            await blockchain.loadFrom(testState);
            const dataBefore = await tonChannel.getChannelData();
            expect(dataBefore.quarantine).not.toBeNull();

            const quarantineBefore = dataBefore.quarantine!;

            let testWallet: SandboxContract<TreasuryContract>;
            let key: Buffer;

            blockchain.now = quarantineBefore.startedAt + tonChannelConfig.closureConfig.quarantineDuration + 1;
            const isA = quarantineBefore.committedbyA;

            const prevA = signSemiChannel({
                channelId: tonChannelConfig.id,
                data: quarantineBefore.stateA
            }, keysA.secretKey);

            const prevB = signSemiChannel({
                channelId: tonChannelConfig.id,
                data: quarantineBefore.stateB
            }, keysB.secretKey);

            const aNextSeqno = signSemiChannel({
                channelId: tonChannelConfig.id,
                data: {...quarantineBefore.stateA, seqno: quarantineBefore.stateA.seqno + BigInt(getRandomInt(1, 100))},
            }, keysA.secretKey);
            const bNextSeqno = signSemiChannel({
                channelId: tonChannelConfig.id,
                data: {...quarantineBefore.stateB, seqno: quarantineBefore.stateB.seqno + BigInt(getRandomInt(1, 100))}
            }, keysB.secretKey);


            let testCase :{
                stateA: Cell,
                stateB: Cell
            };
            if(isA) {
                testWallet = walletA;
                key = keysA.secretKey;
                testCase = {
                    stateA: prevA,
                    stateB: bNextSeqno
                };
            } else {
                testWallet = walletB;
                key = keysB.secretKey;
                testCase = {
                    stateA: aNextSeqno,
                    stateB: prevB
                };
            }

            const res = await tonChannel.sendChallengeQuarantine(testWallet.getSender(), {
                isA,
                stateA: testCase.stateA,
                stateB: testCase.stateB,
                key
            });

            expect(res.transactions).toHaveTransaction({
                on: tonChannel.address,
                from: testWallet.address,
                op: Op.OP_CHALLENGE_QUARANTINEED_STATE,
                aborted: true,
                exitCode: Errors.ERROR_TOO_LATE_FOR_QUARANTINE_CHALLENGE
            });
        }
    });

    it('should not be able to close before quarantine expire + closeDuration', async () => {
        const prevState = blockchain.snapshot();

        const tillClose = tonChannelConfig.closureConfig.quarantineDuration + tonChannelConfig.closureConfig.closeDuration;
        for(let testState of [quarantineStartedA, quarantineStartedB]) {
            for(let waitSome of [0, tillClose - getRandomInt(1, 1000), tillClose]) {
                await blockchain.loadFrom(testState);
                const stateBefore = await tonChannel.getChannelData();
                expect(stateBefore.quarantine).not.toBeNull();

                blockchain.now = stateBefore.quarantine!.startedAt + waitSome;

                // Anybody can close after quarantine
                const res = await tonChannel.sendFinishUncoopClose(walletA.getSender());

                expect(res.transactions).toHaveTransaction({
                    on: tonChannel.address,
                    op: Op.OP_FINISH_UNCOOPERATIVE_CLOSE,
                    aborted: true,
                    exitCode: Errors.ERROR_TOO_EARLY_TO_CLOSE
                });
            }
        }
        await blockchain.loadFrom(prevState);
    });

    it('should be able to close after quarantine + closeDuration', async () => {
        const prevState = blockchain.snapshot();

        for(let testState of [quarantineStartedA, quarantineStartedB]) {
            await blockchain.loadFrom(testState);
            const stateBefore = await tonChannel.getChannelData();
            expect(stateBefore.quarantine).not.toBeNull();

            blockchain.now = stateBefore.quarantine!.startedAt + tonChannelConfig.closureConfig.quarantineDuration + tonChannelConfig.closureConfig.closeDuration + 1;

            const res = await tonChannel.sendFinishUncoopClose(walletA.getSender());
            expect(res.transactions).toHaveTransaction({
                on: tonChannel.address,
                op: Op.OP_FINISH_UNCOOPERATIVE_CLOSE,
                aborted: false
            });
            await assertJettonNotification(
                res.transactions,
                walletB.address,
                tonChannel.address,
                stateBefore.balance.balanceB,
                channelClosedPayload
            );
            await assertJettonNotification(
                res.transactions,
                walletA.address,
                tonChannel.address,
                stateBefore.balance.balanceA,
                channelClosedPayload
            );

            // Expect balance leftowers to go to A through excess
            expect(res.transactions).toHaveTransaction({
                on: walletA.address,
                op: JettonOp.excesses
            });

            expect((await blockchain.getContract(tonChannel.address)).balance).toBe(0n);
            const dataAfter = await tonChannel.getChannelData();
            assertChannelClosed(dataAfter, stateBefore.seqnoA + 1n, stateBefore.seqnoB + 1n);
        }
        await blockchain.loadFrom(prevState);
    });
    it('should be able to close quarantine with either side fined above balance value', async () => {
        const prevState = blockchain.snapshot();

        const msgValue  = toNano('0.05');

        for(let testState of [quarantineChallengedA, quarantineChallengedB]) {
            await blockchain.loadFrom(testState);
            const stateBefore = await tonChannel.getChannelData();


            expect(stateBefore.quarantine).not.toBeNull();
            const quarantineBefore = stateBefore.quarantine!;

            const isB = testState === quarantineChallengedB;

            blockchain.now = quarantineBefore.startedAt + tonChannelConfig.closureConfig.quarantineDuration + tonChannelConfig.closureConfig.closeDuration + 1;

            const res = await tonChannel.sendFinishUncoopClose(walletA.getSender(), msgValue);

            const closeTx = findTransactionRequired(res.transactions, {
                on: tonChannel.address,
                op: Op.OP_FINISH_UNCOOPERATIVE_CLOSE,
                aborted: false,
                outMessagesCount: 2
            });

            if(closeTx.description.type !== 'generic') {
                throw new Error("No way");
            }

            // In case either side exceeds it's balance (via fines), all awailable
            // balance should go to oposite side.
            const expValue = stateBefore.balance.balanceA + stateBefore.balance.balanceB;
            // All the balance accounted should go to B
            if(isB) {
                expect(quarantineBefore.stateA.sent).toBeGreaterThan(stateBefore.balance.balanceA);
                await assertJettonNotification(
                    res.transactions,
                    walletB.address,
                    tonChannel.address,
                    expValue,
                    channelClosedPayload
                );

            } else {
                expect(quarantineBefore.stateB.sent).toBeGreaterThan(stateBefore.balance.balanceB);
                await assertJettonNotification(
                    res.transactions,
                    walletA.address,
                    tonChannel.address,
                    expValue,
                    channelClosedPayload
                );
            }
            // Either way TON excess goes to A
            expect(res.transactions).toHaveTransaction({
                on: walletA.address,
                op: JettonOp.excesses
            });


        }

        await blockchain.loadFrom(prevState);
    });
    it('should not allow to settle conditionals before quarantine end', async () => {
        let toSettle = Dictionary.empty(Dictionary.Keys.Uint(32), Dictionary.Values.BigUint(32));
        for(let testState of [quarantineStartedA, quarantineStartedB]) {
            for(let testWallet of [walletA, walletB]) {
                await blockchain.loadFrom(testState);
                const stateBefore = await tonChannel.getChannelData();
                const conditionalDeadline = stateBefore.quarantine!.startedAt + tonChannelConfig.closureConfig.quarantineDuration;
                // console.log("Before:", stateBefore.quarantine);
                expect(stateBefore.quarantine).not.toBeNull();

                toSettle.set(0, BigInt(conditionalDeadline));
                blockchain.now = conditionalDeadline;
                const isA = testWallet === walletA;

                const res = await tonChannel.sendSettleConditionals(testWallet.getSender(), {
                    isA,
                    toSettle,
                    proof: conditionalsProof,
                    key: isA ? keysA.secretKey : keysB.secretKey
                });

                expect(res.transactions).toHaveTransaction({
                    on: tonChannel.address,
                    op: Op.OP_SETTLE_CONDITIONALS,
                    aborted: true,
                    exitCode: Errors.ERROR_QUARANTINE_NOT_FINISHED
                });
            }
        }
    });
    it('should not allow to settle conditionals once closure duration expired', async () => {
        let toSettle = Dictionary.empty(Dictionary.Keys.Uint(32), Dictionary.Values.BigUint(32));
        for(let testState of [quarantineStartedA, quarantineStartedB]) {
            for(let testWallet of [walletA, walletB]) {
                await blockchain.loadFrom(testState);
                const stateBefore = await tonChannel.getChannelData();
                const conditionalDeadline = stateBefore.quarantine!.startedAt + tonChannelConfig.closureConfig.quarantineDuration + tonChannelConfig.closureConfig.closeDuration;
                // console.log("Before:", stateBefore.quarantine);
                expect(stateBefore.quarantine).not.toBeNull();

                toSettle.set(0, BigInt(conditionalDeadline));
                blockchain.now = conditionalDeadline;
                const isA = testWallet === walletA;

                const res = await tonChannel.sendSettleConditionals(testWallet.getSender(), {
                    isA,
                    toSettle,
                    proof: conditionalsProof,
                    key: isA ? keysA.secretKey : keysB.secretKey
                });

                expect(res.transactions).toHaveTransaction({
                    on: tonChannel.address,
                    op: Op.OP_SETTLE_CONDITIONALS,
                    aborted: true,
                    exitCode: Errors.ERROR_TOO_LATE_TO_SETTLE_CONDITIONALS
                });
            }
        }

    });
    it('should be able to settle conditionals after quarantine end', async () => {
        // For simplicity we use single conditional for both sides
        // Which practically doesn't make much sense
        // In reality, parties may have different conditionals
        // Our conditional adds 0.01 ton if onchain now() > deadline number in slice

        const prevState = blockchain.snapshot();

        let toSettle = Dictionary.empty(Dictionary.Keys.Uint(32), Dictionary.Values.BigUint(32));
        for(let testState of [quarantineStartedA, quarantineStartedB]) {
            for(let testWallet of [walletA, walletB]) {
                await blockchain.loadFrom(testState);
                const stateBefore = await tonChannel.getChannelData();
                // console.log("Before:", stateBefore.quarantine);
                expect(stateBefore.quarantine).not.toBeNull();
                const conditionalDeadline = stateBefore.quarantine!.startedAt + tonChannelConfig.closureConfig.quarantineDuration + 1337;

                toSettle.set(0, BigInt(conditionalDeadline));
                blockchain.now = conditionalDeadline + 1;
                const isA = testWallet === walletA;

                const res = await tonChannel.sendSettleConditionals(testWallet.getSender(), {
                    isA,
                    toSettle,
                    proof: conditionalsProof,
                    key: isA ? keysA.secretKey : keysB.secretKey
                });

                expect(res.transactions).toHaveTransaction({
                    on: tonChannel.address,
                    op: Op.OP_SETTLE_CONDITIONALS,
                    aborted: false
                });

                const stateAfter = await tonChannel.getChannelData();
                // console.log("After:", stateAfter.quarantine);
                if(isA) {
                    expect(stateAfter.quarantine!.stateB.sent).toEqual(stateBefore.quarantine!.stateB.sent + toNano('0.01'));
                } else {
                    expect(stateAfter.quarantine!.stateA.sent).toEqual(stateBefore.quarantine!.stateA.sent + toNano('0.01'));
                }
            }
        }

        await blockchain.loadFrom(prevState);
    });
    it('should properly check for conditionals proof', async () => {
        let toSettle = Dictionary.empty(Dictionary.Keys.Uint(32), Dictionary.Values.BigUint(32));
        let newConditionals   = Dictionary.empty(Dictionary.Keys.BigUint(32), CodeSegmentSlice());
        const testVal = beginCell().storeStringRefTail("Hop hey!").endCell().beginParse();
        newConditionals.set(0n, conditionals.get(0n)!);
        newConditionals.set(42n, testVal);

        const newProof = newConditionals.generateMerkleProof(newConditionals.keys());
        const testUpdate = conditionals.generateMerkleUpdate(0n, testVal);
        const mockProof = beginCell().storeUint(3, 8).storeBuffer(conditionalsHash, 32).storeRef(beginCell().storeDictDirect(newConditionals).endCell()).endCell();

        for(let testState of [quarantineStartedA, quarantineStartedB]) {
            for(let testWallet of [walletA, walletB]) {
                await blockchain.loadFrom(testState);
                for(let testProof of [newProof, testUpdate, mockProof]) {
                    const stateBefore = await tonChannel.getChannelData();
                    // console.log("Before:", stateBefore.quarantine);
                    expect(stateBefore.quarantine).not.toBeNull();
                    const conditionalDeadline = stateBefore.quarantine!.startedAt + tonChannelConfig.closureConfig.quarantineDuration + 1337;

                    toSettle.set(0, BigInt(conditionalDeadline));
                    blockchain.now = conditionalDeadline + 1;
                    const isA = testWallet === walletA;

                    const res = await tonChannel.sendSettleConditionals(testWallet.getSender(), {
                        isA,
                        toSettle,
                        proof: testProof,
                        key: isA ? keysA.secretKey : keysB.secretKey
                    });

                    expect(res.transactions).toHaveTransaction({
                        on: tonChannel.address,
                        op: Op.OP_SETTLE_CONDITIONALS,
                        aborted: true,
                        exitCode: Errors.ERROR_INCORRECT_CONDITIONALS_PROOF
                    });
                }
            }
        }

    });
});
