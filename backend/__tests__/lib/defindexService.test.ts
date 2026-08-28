import {
  Address,
  Keypair,
  SorobanDataBuilder,
  StrKey,
  nativeToScVal,
  scValToNative,
  xdr,
} from "@stellar/stellar-sdk";
import {
  DefindexService,
  DefindexServiceError,
} from "../../src/lib/services/defindex_service";

jest.mock("@stellar/stellar-sdk", () => {
  const actual = jest.requireActual("@stellar/stellar-sdk");
  const mockSimulateTransaction = jest.fn();
  class MockServer {
    url: string;
    simulateTransaction = mockSimulateTransaction;

    constructor(url: string) {
      this.url = url;
    }
  }
  return {
    ...actual,
    rpc: {
      ...actual.rpc,
      Server: MockServer,
    },
    __mockSimulateTransaction: mockSimulateTransaction,
  };
});

const mockSimulateTransaction = (require("@stellar/stellar-sdk") as any)
  .__mockSimulateTransaction as jest.Mock;

// ── Fixtures ────────────────────────────────────────────────────────────────
const VAULT_CONTRACT_ID = StrKey.encodeContract(Buffer.alloc(32, 7));
const USER_ADDRESS = Keypair.random().publicKey();

// Vault state (single-asset USDC vault):
// - 1,000 USDC managed (10_000_000_000 units, 7 decimals)
// - 10,000 vault shares in circulation
// - user holds 5,000 shares
const BALANCE_OF = 5000n;
const TOTAL_SUPPLY = 10000n;
const TOTAL_MANAGED = 10_000_000_000n; // 1,000 USDC

// Requested withdrawal: 10 USDC (100_000_000 units)
const REQUESTED_AMOUNT = "100000000";
const EXPECTED_SHARES = 100n; // ceil(amount * supply / managed)
const EXPECTED_ASSETS = 100_000_000n; // floor(shares * managed / supply)
const EXPECTED_SHARE_PRICE = (TOTAL_MANAGED * 10n ** 7n) / TOTAL_SUPPLY; // scaled 1e7

function successResponse(
  retval: xdr.ScVal,
  auth: xdr.SorobanAuthorizationEntry[] = [],
) {
  return {
    id: "1",
    latestLedger: 123,
    events: [],
    _parsed: true,
    transactionData: new SorobanDataBuilder(),
    minResourceFee: "0",
    result: { auth, retval },
  };
}

function errorResponse(error: string) {
  return {
    id: "1",
    latestLedger: 123,
    events: [],
    _parsed: true,
    error,
  };
}

function managedFundsResponse(totalManaged: bigint = TOTAL_MANAGED) {
  const entry = (name: string, val: xdr.ScVal) =>
    new xdr.ScMapEntry({ key: xdr.ScVal.scvSymbol(name), val });
  const allocation = xdr.ScVal.scvMap([
    entry("asset", Address.fromString(USER_ADDRESS).toScVal()),
    entry("total_amount", nativeToScVal(totalManaged, { type: "i128" })),
    entry("idle_amount", nativeToScVal(0n, { type: "i128" })),
    entry("invested_amount", nativeToScVal(totalManaged, { type: "i128" })),
    entry("strategy_allocations", xdr.ScVal.scvVec([])),
  ]);
  return xdr.ScVal.scvVec([allocation]);
}

function invokedMethod(tx: any): string {
  return tx.operations[0].func.invokeContract().functionName().toString();
}

function hostFunctionOf(envelope: xdr.TransactionEnvelope): xdr.HostFunction {
  const op = envelope.v1().tx().operations()[0];
  return (op.body().value() as any).hostFunction() as xdr.HostFunction;
}

describe("DefindexService.calculateWithdrawalParams", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    process.env.DEFINDEX_VAULT_CONTRACT_ID = VAULT_CONTRACT_ID;
    process.env.SOROBAN_RPC_URL = "https://fake-rpc.example.com";
    delete process.env.STELLAR_NETWORK_PASSPHRASE;

    mockSimulateTransaction.mockImplementation(async (tx: any) => {
      switch (invokedMethod(tx)) {
        case "balance_of":
          return successResponse(nativeToScVal(BALANCE_OF, { type: "i128" }));
        case "total_supply":
          return successResponse(nativeToScVal(TOTAL_SUPPLY, { type: "i128" }));
        case "fetch_total_managed_funds":
          return successResponse(managedFundsResponse());
        case "withdraw":
          return successResponse(
            nativeToScVal([EXPECTED_ASSETS], { type: "i128" }),
          );
        default:
          throw new Error(`Unexpected contract method ${invokedMethod(tx)}`);
      }
    });
  });

  afterEach(() => {
    delete process.env.DEFINDEX_VAULT_CONTRACT_ID;
    delete process.env.SOROBAN_RPC_URL;
  });

  it("computes withdrawal parameters and returns an unsigned withdrawal XDR", async () => {
    const result = await DefindexService.calculateWithdrawalParams(
      USER_ADDRESS,
      REQUESTED_AMOUNT,
    );

    expect(result.userAddress).toBe(USER_ADDRESS);
    expect(result.amount).toBe(REQUESTED_AMOUNT);
    expect(result.sharesToBurn).toBe(EXPECTED_SHARES.toString());
    expect(result.expectedAssets).toBe(EXPECTED_ASSETS.toString());
    expect(result.minAmountsOut).toEqual([EXPECTED_ASSETS.toString()]);
    expect(result.sharePrice).toBe(EXPECTED_SHARE_PRICE.toString());
    expect(result.userBalance).toBe(BALANCE_OF.toString());
    expect(result.totalManagedFunds).toBe(TOTAL_MANAGED.toString());
    expect(result.totalSupply).toBe(TOTAL_SUPPLY.toString());
    expect(result.contractId).toBe(VAULT_CONTRACT_ID);
    expect(result.rpcUrl).toBe("https://fake-rpc.example.com");
    expect(result.unsignedXdr).toBeTruthy();
    expect(result.txHash).toMatch(/^[0-9a-f]{64}$/);
  });

  it("builds a withdraw invocation with the correct Soroban arguments", async () => {
    const result = await DefindexService.calculateWithdrawalParams(
      USER_ADDRESS,
      REQUESTED_AMOUNT,
    );

    const envelope = xdr.TransactionEnvelope.fromXDR(
      result.unsignedXdr,
      "base64",
    );
    const hostFunction = hostFunctionOf(envelope);
    const contractArgs = hostFunction.invokeContract();

    expect(contractArgs.functionName().toString()).toBe("withdraw");
    expect(
      StrKey.encodeContract(
        contractArgs.contractAddress().contractId() as unknown as Buffer,
      ),
    ).toBe(VAULT_CONTRACT_ID);

    const args = contractArgs.args();
    expect(args).toHaveLength(3);

    // 1. withdraw_shares: i128
    expect(args[0].switch().name).toBe("scvI128");
    expect(scValToNative(args[0])).toBe(EXPECTED_SHARES);

    // 2. min_amounts_out: Vec<i128> with one entry per vault asset
    expect(args[1].switch().name).toBe("scvVec");
    expect(scValToNative(args[1])).toEqual([EXPECTED_ASSETS]);

    // 3. from: Address
    expect(scValToNative(args[2])).toBe(USER_ADDRESS);
  });

  it("queries balance_of, total_supply and managed funds over Soroban RPC and simulates the withdrawal", async () => {
    await DefindexService.calculateWithdrawalParams(
      USER_ADDRESS,
      REQUESTED_AMOUNT,
    );

    const simulatedMethods = mockSimulateTransaction.mock.calls.map(([tx]) =>
      invokedMethod(tx),
    );
    expect(simulatedMethods).toEqual([
      "balance_of",
      "total_supply",
      "fetch_total_managed_funds",
      "withdraw",
    ]);
  });

  it("rounds shares up so the user receives at least the requested amount", async () => {
    // Managed funds that make the share price uneven: 999 USDC over 10,000
    // shares. Withdrawing 100_000_000 units needs ceil(1e8 * 1e4 / 9.99e9)
    // = 101 shares, which pays out floor(101 * 9.99e9 / 1e4) = 100_899_000
    // units (>= requested).
    const unevenManaged = 9_990_000_000n;
    mockSimulateTransaction.mockImplementation(async (tx: any) => {
      switch (invokedMethod(tx)) {
        case "balance_of":
          return successResponse(nativeToScVal(1000n, { type: "i128" }));
        case "total_supply":
          return successResponse(nativeToScVal(TOTAL_SUPPLY, { type: "i128" }));
        case "fetch_total_managed_funds":
          return successResponse(managedFundsResponse(unevenManaged));
        case "withdraw":
          return successResponse(
            nativeToScVal([100_899_000n], { type: "i128" }),
          );
        default:
          throw new Error(`Unexpected contract method ${invokedMethod(tx)}`);
      }
    });

    const result = await DefindexService.calculateWithdrawalParams(
      USER_ADDRESS,
      REQUESTED_AMOUNT,
    );

    expect(result.sharesToBurn).toBe("101");
    expect(result.expectedAssets).toBe("100899000");
    expect(BigInt(result.expectedAssets)).toBeGreaterThanOrEqual(
      BigInt(REQUESTED_AMOUNT),
    );
  });

  it("throws when the requested amount exceeds the user's vault balance", async () => {
    // User holds 5,000 shares of 10,000 total; max withdrawable is
    // floor(5000 * 10_000_000_000 / 10000) = 5_000_000_000 units (500 USDC).
    await expect(
      DefindexService.calculateWithdrawalParams(USER_ADDRESS, "6000000000"),
    ).rejects.toThrow(DefindexServiceError);
    await expect(
      DefindexService.calculateWithdrawalParams(USER_ADDRESS, "6000000000"),
    ).rejects.toThrow(/Insufficient vault balance/);
  });

  it("throws for invalid amounts", async () => {
    for (const amount of ["0", "-5", "abc", "1.5", ""]) {
      await expect(
        DefindexService.calculateWithdrawalParams(USER_ADDRESS, amount),
      ).rejects.toThrow(/Invalid withdrawal amount/);
    }
  });

  it("throws for an invalid user address", async () => {
    await expect(
      DefindexService.calculateWithdrawalParams("not-a-stellar-address", "100"),
    ).rejects.toThrow(/Invalid user address/);
  });

  it("throws when the DeFindex vault contract id is not configured", async () => {
    delete process.env.DEFINDEX_VAULT_CONTRACT_ID;
    await expect(
      DefindexService.calculateWithdrawalParams(USER_ADDRESS, REQUESTED_AMOUNT),
    ).rejects.toThrow(/DEFINDEX_VAULT_CONTRACT_ID/);
  });

  it("throws when a contract query fails on the RPC", async () => {
    mockSimulateTransaction.mockImplementation(async (tx: any) => {
      if (invokedMethod(tx) === "balance_of") {
        return errorResponse("HostError: contract invocation failed");
      }
      throw new Error(`Unexpected contract method ${invokedMethod(tx)}`);
    });

    await expect(
      DefindexService.calculateWithdrawalParams(USER_ADDRESS, REQUESTED_AMOUNT),
    ).rejects.toThrow(/Failed to query balance_of/);
  });

  it("throws when the withdrawal simulation reports an error", async () => {
    mockSimulateTransaction.mockImplementation(async (tx: any) => {
      switch (invokedMethod(tx)) {
        case "balance_of":
          return successResponse(nativeToScVal(BALANCE_OF, { type: "i128" }));
        case "total_supply":
          return successResponse(nativeToScVal(TOTAL_SUPPLY, { type: "i128" }));
        case "fetch_total_managed_funds":
          return successResponse(managedFundsResponse());
        case "withdraw":
          return errorResponse("HostError: vault paused");
        default:
          throw new Error(`Unexpected contract method ${invokedMethod(tx)}`);
      }
    });

    await expect(
      DefindexService.calculateWithdrawalParams(USER_ADDRESS, REQUESTED_AMOUNT),
    ).rejects.toThrow(/Withdrawal simulation failed/);
  });

  it("falls back to the un-simulated XDR when the RPC is unreachable", async () => {
    mockSimulateTransaction.mockImplementation(async (tx: any) => {
      if (invokedMethod(tx) === "withdraw") {
        throw new Error("network down");
      }
      switch (invokedMethod(tx)) {
        case "balance_of":
          return successResponse(nativeToScVal(BALANCE_OF, { type: "i128" }));
        case "total_supply":
          return successResponse(nativeToScVal(TOTAL_SUPPLY, { type: "i128" }));
        case "fetch_total_managed_funds":
          return successResponse(managedFundsResponse());
        default:
          throw new Error(`Unexpected contract method ${invokedMethod(tx)}`);
      }
    });

    const result = await DefindexService.calculateWithdrawalParams(
      USER_ADDRESS,
      REQUESTED_AMOUNT,
    );

    // Parameters are still computed and a decodable unsigned XDR is returned.
    expect(result.sharesToBurn).toBe(EXPECTED_SHARES.toString());
    const envelope = xdr.TransactionEnvelope.fromXDR(
      result.unsignedXdr,
      "base64",
    );
    expect(hostFunctionOf(envelope).invokeContract().functionName().toString()).toBe(
      "withdraw",
    );
  });

  it("wraps unexpected errors in DefindexServiceError", async () => {
    mockSimulateTransaction.mockRejectedValue(new Error("rpc exploded"));

    await expect(
      DefindexService.calculateWithdrawalParams(USER_ADDRESS, REQUESTED_AMOUNT),
    ).rejects.toThrow(DefindexServiceError);
  });
});

describe("DefindexService.calculateDepositParams", () => {
  const DEPOSIT_AMOUNT = "100000000"; // 10 USDC

  beforeEach(() => {
    jest.clearAllMocks();
    process.env.DEFINDEX_VAULT_CONTRACT_ID = VAULT_CONTRACT_ID;
    process.env.SOROBAN_RPC_URL = "https://fake-rpc.example.com";
    delete process.env.STELLAR_NETWORK_PASSPHRASE;

    mockSimulateTransaction.mockImplementation(async (tx: any) => {
      switch (invokedMethod(tx)) {
        case "total_supply":
          return successResponse(nativeToScVal(TOTAL_SUPPLY, { type: "i128" }));
        case "fetch_total_managed_funds":
          return successResponse(managedFundsResponse());
        case "balance_of":
          return successResponse(nativeToScVal(BALANCE_OF, { type: "i128" }));
        case "deposit":
          return successResponse(
            nativeToScVal(100n, { type: "i128" }),
          );
        default:
          throw new Error(`Unexpected contract method ${invokedMethod(tx)}`);
      }
    });
  });

  afterEach(() => {
    delete process.env.DEFINDEX_VAULT_CONTRACT_ID;
    delete process.env.SOROBAN_RPC_URL;
  });

  it("computes deposit parameters and returns an unsigned deposit XDR", async () => {
    const result = await DefindexService.calculateDepositParams(
      USER_ADDRESS,
      DEPOSIT_AMOUNT,
    );

    expect(result.userAddress).toBe(USER_ADDRESS);
    expect(result.amount).toBe(DEPOSIT_AMOUNT);
    // 100_000_000 units / ($1000 USDC over 10k shares => 0.0001 USDC/share)
    // estimatedShares = floor(amount * supply / managed)
    expect(result.estimatedShares).toBe("100");
    expect(result.sharePrice).toBe(EXPECTED_SHARE_PRICE.toString());
    expect(result.userBalance).toBe(BALANCE_OF.toString());
    expect(result.totalManagedFunds).toBe(TOTAL_MANAGED.toString());
    expect(result.totalSupply).toBe(TOTAL_SUPPLY.toString());
    expect(result.contractId).toBe(VAULT_CONTRACT_ID);
    expect(result.rpcUrl).toBe("https://fake-rpc.example.com");
    expect(result.unsignedXdr).toBeTruthy();
    expect(result.txHash).toMatch(/^[0-9a-f]{64}$/);
  });

  it("builds a deposit invocation with the correct Soroban arguments", async () => {
    const result = await DefindexService.calculateDepositParams(
      USER_ADDRESS,
      DEPOSIT_AMOUNT,
    );

    const envelope = xdr.TransactionEnvelope.fromXDR(
      result.unsignedXdr,
      "base64",
    );
    const hostFunction = hostFunctionOf(envelope);
    const contractArgs = hostFunction.invokeContract();

    expect(contractArgs.functionName().toString()).toBe("deposit");
    expect(
      StrKey.encodeContract(
        contractArgs.contractAddress().contractId() as unknown as Buffer,
      ),
    ).toBe(VAULT_CONTRACT_ID);

    const args = contractArgs.args();
    expect(args).toHaveLength(2);

    expect(args[0].switch().name).toBe("scvI128");
    expect(scValToNative(args[0])).toBe(BigInt(DEPOSIT_AMOUNT));
    expect(scValToNative(args[1])).toBe(USER_ADDRESS);
  });

  it("queries total_supply, managed funds and balance_of over Soroban RPC and simulates the deposit", async () => {
    await DefindexService.calculateDepositParams(USER_ADDRESS, DEPOSIT_AMOUNT);

    const simulatedMethods = mockSimulateTransaction.mock.calls.map(([tx]) =>
      invokedMethod(tx),
    );
    expect(simulatedMethods).toEqual([
      "total_supply",
      "fetch_total_managed_funds",
      "balance_of",
      "deposit",
    ]);
  });

  it("assumes a 1:1 share price when the vault is empty", async () => {
    mockSimulateTransaction.mockImplementation(async (tx: any) => {
      switch (invokedMethod(tx)) {
        case "total_supply":
          return successResponse(nativeToScVal(0n, { type: "i128" }));
        case "fetch_total_managed_funds":
          return successResponse(managedFundsResponse(0n));
        case "balance_of":
          return successResponse(nativeToScVal(0n, { type: "i128" }));
        case "deposit":
          return successResponse(
            nativeToScVal(BigInt(DEPOSIT_AMOUNT), { type: "i128" }),
          );
        default:
          throw new Error(`Unexpected contract method ${invokedMethod(tx)}`);
      }
    });

    const result = await DefindexService.calculateDepositParams(
      USER_ADDRESS,
      DEPOSIT_AMOUNT,
    );

    expect(result.sharePrice).toBe((10n ** 7n).toString());
    expect(result.estimatedShares).toBe(DEPOSIT_AMOUNT);
  });

  it("throws for invalid amounts", async () => {
    for (const amount of ["0", "-5", "abc", "1.5", ""]) {
      await expect(
        DefindexService.calculateDepositParams(USER_ADDRESS, amount),
      ).rejects.toThrow(/Invalid deposit amount/);
    }
  });

  it("throws for an invalid user address", async () => {
    await expect(
      DefindexService.calculateDepositParams("not-a-stellar-address", "100"),
    ).rejects.toThrow(/Invalid user address/);
  });

  it("throws when the DeFindex vault contract id is not configured", async () => {
    delete process.env.DEFINDEX_VAULT_CONTRACT_ID;
    await expect(
      DefindexService.calculateDepositParams(USER_ADDRESS, DEPOSIT_AMOUNT),
    ).rejects.toThrow(/DEFINDEX_VAULT_CONTRACT_ID/);
  });

  it("throws when a contract query fails on the RPC", async () => {
    mockSimulateTransaction.mockImplementation(async (tx: any) => {
      if (invokedMethod(tx) === "total_supply") {
        return errorResponse("HostError: contract invocation failed");
      }
      throw new Error(`Unexpected contract method ${invokedMethod(tx)}`);
    });

    await expect(
      DefindexService.calculateDepositParams(USER_ADDRESS, DEPOSIT_AMOUNT),
    ).rejects.toThrow(/Failed to query total_supply/);
  });

  it("throws when the deposit simulation reports an error", async () => {
    mockSimulateTransaction.mockImplementation(async (tx: any) => {
      switch (invokedMethod(tx)) {
        case "total_supply":
          return successResponse(nativeToScVal(TOTAL_SUPPLY, { type: "i128" }));
        case "fetch_total_managed_funds":
          return successResponse(managedFundsResponse());
        case "balance_of":
          return successResponse(nativeToScVal(BALANCE_OF, { type: "i128" }));
        case "deposit":
          return errorResponse("HostError: vault paused");
        default:
          throw new Error(`Unexpected contract method ${invokedMethod(tx)}`);
      }
    });

    await expect(
      DefindexService.calculateDepositParams(USER_ADDRESS, DEPOSIT_AMOUNT),
    ).rejects.toThrow(/Deposit simulation failed/);
  });

  it("falls back to the un-simulated XDR when the RPC is unreachable", async () => {
    mockSimulateTransaction.mockImplementation(async (tx: any) => {
      if (invokedMethod(tx) === "deposit") {
        throw new Error("network down");
      }
      switch (invokedMethod(tx)) {
        case "total_supply":
          return successResponse(nativeToScVal(TOTAL_SUPPLY, { type: "i128" }));
        case "fetch_total_managed_funds":
          return successResponse(managedFundsResponse());
        case "balance_of":
          return successResponse(nativeToScVal(BALANCE_OF, { type: "i128" }));
        default:
          throw new Error(`Unexpected contract method ${invokedMethod(tx)}`);
      }
    });

    const result = await DefindexService.calculateDepositParams(
      USER_ADDRESS,
      DEPOSIT_AMOUNT,
    );

    expect(result.estimatedShares).toBe("100");
    const envelope = xdr.TransactionEnvelope.fromXDR(
      result.unsignedXdr,
      "base64",
    );
    expect(hostFunctionOf(envelope).invokeContract().functionName().toString()).toBe(
      "deposit",
    );
  });

  it("wraps unexpected errors in DefindexServiceError", async () => {
    mockSimulateTransaction.mockRejectedValue(new Error("rpc exploded"));

    await expect(
      DefindexService.calculateDepositParams(USER_ADDRESS, DEPOSIT_AMOUNT),
    ).rejects.toThrow(DefindexServiceError);
  });

  it("throws when the vault has shares but no managed funds", async () => {
    mockSimulateTransaction.mockImplementation(async (tx: any) => {
      switch (invokedMethod(tx)) {
        case "total_supply":
          return successResponse(nativeToScVal(TOTAL_SUPPLY, { type: "i128" }));
        case "fetch_total_managed_funds":
          return successResponse(managedFundsResponse(0n));
        default:
          throw new Error(`Unexpected contract method ${invokedMethod(tx)}`);
      }
    });

    await expect(
      DefindexService.calculateDepositParams(USER_ADDRESS, DEPOSIT_AMOUNT),
    ).rejects.toThrow(
      /has shares in circulation but manages no USDC funds/,
    );
  });

  it("throws when the vault manages funds but has no shares", async () => {
    mockSimulateTransaction.mockImplementation(async (tx: any) => {
      switch (invokedMethod(tx)) {
        case "total_supply":
          return successResponse(nativeToScVal(0n, { type: "i128" }));
        case "fetch_total_managed_funds":
          return successResponse(managedFundsResponse());
        default:
          throw new Error(`Unexpected contract method ${invokedMethod(tx)}`);
      }
    });

    await expect(
      DefindexService.calculateDepositParams(USER_ADDRESS, DEPOSIT_AMOUNT),
    ).rejects.toThrow(
      /manages .* units but has no shares in circulation/,
    );
  });

  it("classifies validation errors as kind 'validation'", async () => {
    await expect(
      DefindexService.calculateDepositParams(USER_ADDRESS, "abc"),
    ).rejects.toMatchObject({ kind: "validation" });
  });

  it("classifies configuration errors as kind 'configuration'", async () => {
    delete process.env.DEFINDEX_VAULT_CONTRACT_ID;
    await expect(
      DefindexService.calculateDepositParams(USER_ADDRESS, DEPOSIT_AMOUNT),
    ).rejects.toMatchObject({ kind: "configuration" });
  });

  it("classifies RPC failures as kind 'upstream'", async () => {
    mockSimulateTransaction.mockRejectedValue(new Error("rpc exploded"));

    await expect(
      DefindexService.calculateDepositParams(USER_ADDRESS, DEPOSIT_AMOUNT),
    ).rejects.toMatchObject({ kind: "upstream" });
  });
});
