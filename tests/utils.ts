import { Address, beginCell, Cell, Dictionary, DictionaryValue, Slice, toNano } from "@ton/core";
import { sign } from "@ton/crypto";
export const randomAddress = (wc: number = 0) => {
    const buf = Buffer.alloc(32);
    for (let i = 0; i < buf.length; i++) {
        buf[i] = Math.floor(Math.random() * 256);
    }
    return new Address(wc, buf);
};

export const differentAddress = (old: Address) => {
    let newAddr: Address;
    do {
        newAddr = randomAddress(old.workChain);
    } while(newAddr.equals(old));

    return newAddr;
}

const getRandom = (min:number, max:number) => {
    return Math.random() * (max - min) + min;
}

export const getRandomInt = (min: number, max: number) => {
    return Math.round(getRandom(min, max));
}

export const getRandomTon = (min:number, max:number): bigint => {
    return toNano(getRandom(min, max).toFixed(9));
}

export const signCell = async (data: Cell, key: Buffer) => {
    return sign(data.hash(), key);
}

export const CodeSegmentSlice: () => DictionaryValue<Slice> = () => {
    return  {
        parse: (src) => {
            return src
        },
        serialize: (src, builder) => {
            builder.storeSlice(src)
        }
    }
};
export const CodeSegmentCell: () => DictionaryValue<Cell> = () => {
    return  {
        parse: (src) => {
            return beginCell().storeSlice(src).endCell();
        },
        serialize: (src, builder) => {
            builder.storeSlice(src.asSlice());
        }
    }
};

export const loadCodeDictionary = (data: Cell) => {
    return Dictionary.loadDirect(Dictionary.Keys.Uint(19), CodeSegmentSlice(), data.refs[0]);
}
