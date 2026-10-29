module.exports = {
  testEnvironment: 'node',
  transform: { '^.+\\.tsx?$': ['ts-jest', { tsconfig: 'tsconfig.json' }] },
  testMatch: ['**/__tests__/**/*.test.ts'],
  clearMocks: true,
  collectCoverageFrom: ['src/services/**/*.ts'],
  coverageThreshold: {
    global: { branches: 90, functions: 95, lines: 95, statements: 95 },
  },
};
