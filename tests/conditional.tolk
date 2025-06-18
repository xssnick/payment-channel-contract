fun main() {
}

@method_id(42)
fun conditional_fee(data: slice) {
    var fee: int = 0;
    var deadline = data.loadUint(32);
    if(blockchain.now() > deadline) {
        fee = ton("0.01");
    }

    return fee;
}
