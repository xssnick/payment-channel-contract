import type { Config } from 'jest';

const config: Config = {
    preset: 'ts-jest',
    testEnvironment: 'node',
    testTimeout: 30000,
    testPathIgnorePatterns: ['/node_modules/', '/dist/'],
};

export default config;
