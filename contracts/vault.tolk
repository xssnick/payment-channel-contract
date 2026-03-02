import "@stdlib/gas-payments"
import "errors"
import "universal/c5-register-validation"


struct Vault {
    id: uint128
    walletSeqno: uint32
    key: uint256
}

struct (0x31a4168c) ExternalSignedRequest {
    signature: bits512
    signedBody: RemainingBitsAndRefs
}
struct ExternalSignedSendBody {
    id: uint128
    validUntil: uint32
    seqno: uint32
    outActions: OutActionsCell?
}

struct (0x51a4168c) InternalSignedSenderRequest {
    signature: bits512
    message: cell
}

struct (0x71a4168c) PairToSign {
    sender: address
    receiver: address
}

type AllowedExtMessages =
    | ExternalSignedRequest;

type AllowedIntMessages =
    | InternalSignedSenderRequest;

fun onInternalMessage(in: InMessage) {
    var vault = Vault.fromCell(contract.getData());

    var msg = lazy AllowedIntMessages.fromSlice(in.body);

    match (msg) {
        InternalSignedSenderRequest => {
            var toSign = PairToSign{sender: in.senderAddress, receiver: contract.getAddress()}.toCell();
            assert (isSignatureValid(toSign.hash(), msg.signature as slice, vault.key)) throw ERROR_INVALID_SIGNATURE;

            sendRawMessage(msg.message,1);
            return;
        }
    }
}

fun onExternalMessage(inMsgBody: slice) {
    var vault = Vault.fromCell(contract.getData());

    var msg = lazy AllowedExtMessages.fromSlice(inMsgBody);

    match (msg) {
        ExternalSignedRequest => {
            assert (isSignatureValid(msg.signedBody.hash(), msg.signature as slice, vault.key)) throw ERROR_INVALID_SIGNATURE;

            var body = msg.signedBody.loadAny<ExternalSignedSendBody>();

            assert (body.id == vault.id) throw ERROR_WRONG_CHANNEL_ID;
            assert (body.seqno == vault.walletSeqno) throw ERROR_INVALID_SEQNO;
            assert (body.validUntil > blockchain.now()) throw ERROR_EXPIRED;

            acceptExternalMessage();

            vault.walletSeqno += 1;
            contract.setData(vault.toCell());
            commitContractDataAndActions();

            if (body.outActions != null) {
                setTvmRegisterC5(body.outActions.verifyC5Actions(createAddressNone()));
            }
            return;
        }
    }
}
