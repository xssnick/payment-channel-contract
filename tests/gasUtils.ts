import { beginCell, Cell, Dictionary, Message, Slice, Transaction } from '@ton/core';

type MsgPrices = ReturnType<typeof configParseMsgPrices>;
export const configParseMsgPrices = (sc: Slice) => {
    let magic = sc.loadUint(8);

    if(magic != 0xea) {
        throw Error("Invalid message prices magic number!");
    }
    return {
        lumpPrice:sc.loadUintBig(64),
        bitPrice: sc.loadUintBig(64),
        cellPrice: sc.loadUintBig(64),
        ihrPriceFactor: sc.loadUintBig(32),
        firstFrac: sc.loadUintBig(16),
        nextFrac:  sc.loadUintBig(16)
    };
}
export const getMsgPrices = (configRaw: Cell, workchain: 0 | -1 ) => {

    const config = configRaw.beginParse().loadDictDirect(Dictionary.Keys.Int(32), Dictionary.Values.Cell());

    const prices = config.get(25 + workchain);

    if(prices === undefined) {
        throw Error("No prices defined in config");
    }

    return configParseMsgPrices(prices.beginParse());
}

export const computedGeneric = (trans: Transaction) => {
        if(trans.description.type !== "generic")
            throw("Expected generic transaction");
        if(trans.description.computePhase.type !== "vm")
            throw("Compute phase expected")
        return trans.description.computePhase;
    };

function shr16ceil(src: bigint) {
    let rem = src % BigInt(65536);
    let res = src / 65536n; // >> BigInt(16);
    if (rem != BigInt(0)) {
        res += BigInt(1);
    }
    return res;
}
export class StorageStats {
    bits: bigint;
    cells: bigint;

    constructor(bits?: number | bigint, cells?: number | bigint) {
        this.bits  = bits  !== undefined ? BigInt(bits)  : 0n;
        this.cells = cells !== undefined ? BigInt(cells) : 0n;
    }
    add(...stats: StorageStats[]) {
        let cells = this.cells, bits = this.bits;
        for (let stat of stats) {
            bits  += stat.bits;
            cells += stat.cells;
        }
        return new StorageStats(bits, cells);
    }
    sub(...stats: StorageStats[]) {
        let cells = this.cells, bits = this.bits;
        for (let stat of stats) {
            bits  -= stat.bits;
            cells -= stat.cells;
        }
        return new StorageStats(bits, cells);
    }
    addBits(bits: number | bigint) {
        return new StorageStats(this.bits + BigInt(bits), this.cells);
    }
    subBits(bits: number | bigint) {
        return new StorageStats(this.bits - BigInt(bits), this.cells);
    }
    addCells(cells: number | bigint) {
        return new StorageStats(this.bits, this.cells + BigInt(cells));
    }
    subCells(cells: number | bigint) {
        return new StorageStats(this.bits, this.cells - BigInt(cells));
    }

    toString() : string {
        return JSON.stringify({
            bits: this.bits.toString(),
            cells: this.cells.toString()
        });
    }
}

export function collectCellStats(cell: Cell, visited:Array<string>, skipRoot: boolean = false): StorageStats {
    let bits  = skipRoot ? 0n : BigInt(cell.bits.length);
    let cells = skipRoot ? 0n : 1n;
    let hash = cell.hash().toString();
    if (visited.includes(hash)) {
        // We should not account for current cell data if visited
        return new StorageStats();
    }
    else {
        visited.push(hash);
    }
    for (let ref of cell.refs) {
        let r = collectCellStats(ref, visited);
        cells += r.cells;
        bits += r.bits;
    }
    return new StorageStats(bits, cells);
}

export function computeDefaultForwardFee(msgPrices: MsgPrices) {
    return msgPrices.lumpPrice - ((msgPrices.lumpPrice * msgPrices.firstFrac) >> BigInt(16));
}

export function computeCellForwardFees(msgPrices: MsgPrices, msg: Cell) {
    let storageStats = collectCellStats(msg, [], true);
    return computeFwdFees(msgPrices, storageStats.cells, storageStats.bits);
}
export function computeFwdFees(msgPrices: MsgPrices, cells: bigint, bits: bigint) {
    return msgPrices.lumpPrice + (shr16ceil((msgPrices.bitPrice * bits)
         + (msgPrices.cellPrice * cells))
    );
}

export function computeFwdFeesVerbose(msgPrices: MsgPrices, cells: bigint | number, bits: bigint | number) {
    const fees = computeFwdFees(msgPrices, BigInt(cells), BigInt(bits));

    const res = (fees * msgPrices.firstFrac) >> 16n;
    return {
        total: fees,
        res,
        remaining: fees - res
    }
}
export function computeMessageForwardFees(msgPrices: MsgPrices, msg: Message)  {
    // let msg = loadMessageRelaxed(cell.beginParse());
    let storageStats = new StorageStats();

    if( msg.info.type !== "internal") {
        throw Error("Helper intended for internal messages");
    }
    const defaultFwd = computeDefaultForwardFee(msgPrices);
    // If message forward fee matches default than msg cell is flat
    if(msg.info.forwardFee == defaultFwd) {
        return {fees: { total: msgPrices.lumpPrice, res : defaultFwd, remaining: defaultFwd, }, stats: storageStats};
    }
    let visited : Array<string> = [];
    // Init
    if (msg.init) {
        let addBits  = 5n; // Minimal additional bits
        let refCount = 0;
        if(msg.init.splitDepth) {
            addBits += 5n;
        }
        if(msg.init.libraries) {
            refCount++;
            storageStats = storageStats.add(collectCellStats(beginCell().storeDictDirect(msg.init.libraries).endCell(), visited, true));
        }
        if(msg.init.code) {
            refCount++;
            storageStats = storageStats.add(collectCellStats(msg.init.code, visited))
        }
        if(msg.init.data) {
            refCount++;
            storageStats = storageStats.add(collectCellStats(msg.init.data, visited));
        }
        if(refCount >= 2) { //https://github.com/ton-blockchain/ton/blob/51baec48a02e5ba0106b0565410d2c2fd4665157/crypto/block/transaction.cpp#L2079
            storageStats.cells++;
            storageStats.bits += addBits;
        }
    }
    const lumpBits  = BigInt(msg.body.bits.length);
    const bodyStats = collectCellStats(msg.body,visited, true);
    storageStats = storageStats.add(bodyStats);

    // NOTE: Extra currencies are ignored for now
    let fees = computeFwdFeesVerbose(msgPrices, BigInt(storageStats.cells), BigInt(storageStats.bits));
    // Meeh
    if(fees.remaining < msg.info.forwardFee) {
        // console.log(`Remaining ${fees.remaining} < ${msg.info.forwardFee} lump bits:${lumpBits}`);
        storageStats = storageStats.addCells(1).addBits(lumpBits);
        fees = computeFwdFeesVerbose(msgPrices, storageStats.cells, storageStats.bits);
    }
    if(fees.remaining != msg.info.forwardFee) {
        console.log("Result fees:", fees);
        console.log(msg);
        console.log(fees.remaining);
        throw(new Error("Something went wrong in fee calcuation!"));
    }
    return {fees, stats: storageStats};
}
