import { NextRequest } from "next/server";
import { POST } from "@/api/wallet/withdraw";
import { getAuthPayload } from "@/lib/auth-session";
import { DefindexService, DefindexServiceError } from "@/lib/services/defindex_service";

const VALID_STELLAR_ADDRESS = "GDWF77422SKLZTBQT77BQEQLCIQY6PFTFZX5OFJTLAFFWJ2PK5WBOZAN";
const INVALID_STELLAR_ADDRESS = "not-a-valid-address";

jest.mock("@defindex/sdk", () => ({
  DefindexSDK: jest.fn().mockImplementation(() => ({
    getVaultInfo: jest.fn(),
    getVaultAPY: jest.fn(),
    depositToVault: jest.fn(),
    withdrawFromVault: jest.fn(),
  })),
  SupportedNetworks: { TESTNET: "testnet", MAINNET: "mainnet" },
}));

jest.mock("@/lib/auth-session", () => ({
  getAuthPayload: jest.fn(),
}));

jest.mock("@stellar/stellar-sdk", () => {
  const actual = jest.requireActual("@stellar/stellar-sdk");
  return {
    ...actual,
    StrKey: {
      isValidEd25519PublicKey: jest.fn((key: string) => {
        return typeof key === "string" && key.startsWith("G") && key.length === 56;
      }),
    },
  };
});

jest.mock("@/lib/services/defindex_service", () => {
  const actual = jest.requireActual("@/lib/services/defindex_service");
  return {
    ...actual,
    DefindexService: {
      calculateWithdrawalParams: jest.fn(),
    },
  };
});

const mockGetAuthPayload = getAuthPayload as jest.Mock;
const mockCalculateWithdrawalParams = (
  DefindexService as jest.Mocked<typeof DefindexService>
).calculateWithdrawalParams as jest.Mock;

const MOCK_RESULT = {
  userAddress: VALID_STELLAR_ADDRESS,
  amount: "100000000",
  sharesToBurn: "100",
  expectedAssets: "98000000",
  minAmountsOut: ["98000000", "0"],
  sharePrice: "10000000",
  userBalance: "200000000",
  totalManagedFunds: "10000000000",
  totalSupply: "10000",
  contractId: "CAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABBBBA",
  networkPassphrase: "Test SDF Network ; September 2015",
  rpcUrl: "https://fake-rpc.example.com",
  unsignedXdr: "AAAAAgAAAAD9t89zRQAJbT2b1B9B",
  txHash: "a".repeat(64),
};

function makeRequest(body?: Record<string, unknown>) {
  return new NextRequest("http://localhost/api/wallet/withdraw", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: "Bearer token",
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
}

describe("POST /api/wallet/withdraw", () => {
  beforeEach(() => {
    jest.clearAllMocks();
  });

  it("returns 401 when no auth token is provided", async () => {
    mockGetAuthPayload.mockResolvedValue(null);

    const res = await POST(makeRequest({ userAddress: VALID_STELLAR_ADDRESS, amount: "100000000" }));
    const body = await res.json();

    expect(res.status).toBe(401);
    expect(body.title).toBe("Unauthorized");
  });

  // --- userAddress Validation Tests ---

  it("returns 400 when userAddress is missing", async () => {
    mockGetAuthPayload.mockResolvedValue({ userId: "user-1" });

    const res = await POST(makeRequest({ amount: "100000000" }));
    const body = await res.json();

    expect(res.status).toBe(400);
    expect(body.title).toBe("Bad Request");
    expect(body.detail).toContain("userAddress is required");
  });

  it("returns 400 when userAddress is not a string", async () => {
    mockGetAuthPayload.mockResolvedValue({ userId: "user-1" });

    const res = await POST(makeRequest({ userAddress: 12345, amount: "100000000" }));
    const body = await res.json();

    expect(res.status).toBe(400);
    expect(body.title).toBe("Bad Request");
    expect(body.detail).toContain("userAddress is required and must be a string");
  });

  it("returns 400 when userAddress is empty", async () => {
    mockGetAuthPayload.mockResolvedValue({ userId: "user-1" });

    const res = await POST(makeRequest({ userAddress: "   ", amount: "100000000" }));
    const body = await res.json();

    expect(res.status).toBe(400);
    expect(body.title).toBe("Bad Request");
    expect(body.detail).toContain("cannot be empty");
  });

  it("returns 400 when userAddress format is invalid", async () => {
    mockGetAuthPayload.mockResolvedValue({ userId: "user-1" });

    const res = await POST(makeRequest({ userAddress: INVALID_STELLAR_ADDRESS, amount: "100000000" }));
    const body = await res.json();

    expect(res.status).toBe(400);
    expect(body.title).toBe("Bad Request");
    expect(body.detail).toContain("Invalid Stellar public key format");
  });

  // --- amount Validation Tests ---

  it("returns 400 when amount is missing", async () => {
    mockGetAuthPayload.mockResolvedValue({ userId: "user-1" });

    const res = await POST(makeRequest({ userAddress: VALID_STELLAR_ADDRESS }));
    const body = await res.json();

    expect(res.status).toBe(400);
    expect(body.title).toBe("Bad Request");
    expect(body.detail).toContain("amount is required");
  });

  it("returns 400 when amount is not a string", async () => {
    mockGetAuthPayload.mockResolvedValue({ userId: "user-1" });

    const res = await POST(makeRequest({ userAddress: VALID_STELLAR_ADDRESS, amount: 100000 }));
    const body = await res.json();

    expect(res.status).toBe(400);
    expect(body.title).toBe("Bad Request");
    expect(body.detail).toContain("amount is required and must be a string");
  });

  it("returns 400 when amount is empty", async () => {
    mockGetAuthPayload.mockResolvedValue({ userId: "user-1" });

    const res = await POST(makeRequest({ userAddress: VALID_STELLAR_ADDRESS, amount: "  " }));
    const body = await res.json();

    expect(res.status).toBe(400);
    expect(body.title).toBe("Bad Request");
    expect(body.detail).toContain("cannot be empty");
  });

  it("returns 400 when amount contains non-digits", async () => {
    mockGetAuthPayload.mockResolvedValue({ userId: "user-1" });

    const res = await POST(makeRequest({ userAddress: VALID_STELLAR_ADDRESS, amount: "123.45" }));
    const body = await res.json();

    expect(res.status).toBe(400);
    expect(body.title).toBe("Bad Request");
    expect(body.detail).toContain("amount must be a valid positive integer");
  });

  it("returns 400 when amount is zero", async () => {
    mockGetAuthPayload.mockResolvedValue({ userId: "user-1" });

    const res = await POST(makeRequest({ userAddress: VALID_STELLAR_ADDRESS, amount: "0" }));
    const body = await res.json();

    expect(res.status).toBe(400);
    expect(body.title).toBe("Bad Request");
    expect(body.detail).toContain("amount must be greater than zero");
  });

  it("returns 400 when amount exceeds MAX_I128 limit", async () => {
    mockGetAuthPayload.mockResolvedValue({ userId: "user-1" });

    // 2^127
    const hugeAmount = (1n << 127n).toString();
    const res = await POST(makeRequest({ userAddress: VALID_STELLAR_ADDRESS, amount: hugeAmount }));
    const body = await res.json();

    expect(res.status).toBe(400);
    expect(body.title).toBe("Bad Request");
    expect(body.detail).toContain("amount is too large");
  });

  // --- Success Flow Tests ---

  it("returns 200 with withdrawal parameters mapped to request requirements", async () => {
    mockGetAuthPayload.mockResolvedValue({ userId: "user-1" });
    mockCalculateWithdrawalParams.mockResolvedValueOnce(MOCK_RESULT);

    const res = await POST(makeRequest({ userAddress: VALID_STELLAR_ADDRESS, amount: "100000000" }));
    const body = await res.json();

    expect(res.status).toBe(200);
    expect(body.success).toBe(true);
    expect(body.unsignedXdr).toBe(MOCK_RESULT.unsignedXdr);
    expect(body.expectedUsdcAssets).toBe(MOCK_RESULT.expectedAssets);
    expect(body.minimumOutputs).toEqual(MOCK_RESULT.minAmountsOut);
    expect(body.estimatedTransactionHash).toBe(MOCK_RESULT.txHash);
    expect(body.sharesToBurn).toBe(MOCK_RESULT.sharesToBurn);
    expect(body.sharePrice).toBe(MOCK_RESULT.sharePrice);

    expect(mockCalculateWithdrawalParams).toHaveBeenCalledWith(
      VALID_STELLAR_ADDRESS,
      "100000000",
    );
  });

  // --- Service Error Mapping Tests ---

  it("returns 400 when service throws validation error", async () => {
    mockGetAuthPayload.mockResolvedValue({ userId: "user-1" });
    mockCalculateWithdrawalParams.mockRejectedValueOnce(
      new DefindexServiceError("Insufficient vault balance", "validation"),
    );

    const res = await POST(makeRequest({ userAddress: VALID_STELLAR_ADDRESS, amount: "100000000" }));
    const body = await res.json();

    expect(res.status).toBe(400);
    expect(body.title).toBe("Bad Request");
    expect(body.detail).toBe("Insufficient vault balance");
  });

  it("returns 500 when service throws configuration error", async () => {
    mockGetAuthPayload.mockResolvedValue({ userId: "user-1" });
    mockCalculateWithdrawalParams.mockRejectedValueOnce(
      new DefindexServiceError("DEFINDEX_VAULT_CONTRACT_ID is not configured", "configuration"),
    );

    const res = await POST(makeRequest({ userAddress: VALID_STELLAR_ADDRESS, amount: "100000000" }));
    const body = await res.json();

    expect(res.status).toBe(500);
    expect(body.title).toBe("Internal Server Error");
    expect(body.detail).not.toContain("DEFINDEX_VAULT_CONTRACT_ID");
    expect(body.detail).toBe("The DeFindex vault is not configured correctly");
  });

  it("returns 502 when service throws upstream failure", async () => {
    mockGetAuthPayload.mockResolvedValue({ userId: "user-1" });
    mockCalculateWithdrawalParams.mockRejectedValueOnce(
      new DefindexServiceError("Simulation failed", "upstream"),
    );

    const res = await POST(makeRequest({ userAddress: VALID_STELLAR_ADDRESS, amount: "100000000" }));
    const body = await res.json();

    expect(res.status).toBe(502);
    expect(body.title).toBe("Bad Gateway");
    expect(body.detail).toBe("The DeFindex vault could not be reached or simulated at this time");
  });

  it("returns 500 on unexpected errors", async () => {
    mockGetAuthPayload.mockResolvedValue({ userId: "user-1" });
    mockCalculateWithdrawalParams.mockRejectedValueOnce(new Error("unexpected error"));

    const res = await POST(makeRequest({ userAddress: VALID_STELLAR_ADDRESS, amount: "100000000" }));
    const body = await res.json();

    expect(res.status).toBe(500);
    expect(body.title).toBe("Internal Server Error");
    expect(body.detail).toBe("Failed to calculate withdrawal parameters");
  });

  it("returns 400 when the request body is not valid JSON", async () => {
    mockGetAuthPayload.mockResolvedValue({ userId: "user-1" });

    const req = new NextRequest("http://localhost/api/wallet/withdraw", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: "Bearer token",
      },
      body: "not-a-json-payload",
    });
    const res = await POST(req);
    const body = await res.json();

    expect(res.status).toBe(400);
    expect(body.title).toBe("Bad Request");
  });

  it("returns 413 when the request body stream exceeds the 10KB limit", async () => {
    mockGetAuthPayload.mockResolvedValue({ userId: "user-1" });

    // Construct a large body (> 10KB)
    const largeBody = {
      userAddress: VALID_STELLAR_ADDRESS,
      amount: "100000000",
      extraData: "a".repeat(11 * 1024), // 11KB of data
    };

    const res = await POST(makeRequest(largeBody));
    const body = await res.json();

    expect(res.status).toBe(413);
    expect(body.title).toBe("Payload Too Large");
    expect(body.detail).toContain("exceeds the maximum allowed size of 10KB");
  });

  it("returns 413 when a chunked stream without Content-Length exceeds the 10KB limit", async () => {
    mockGetAuthPayload.mockResolvedValue({ userId: "user-1" });

    // Simulate chunked streaming by passing a custom ReadableStream
    const controller = new ReadableStream({
      start(ctrl) {
        ctrl.enqueue(new TextEncoder().encode("a".repeat(11 * 1024)));
        ctrl.close();
      }
    });

    const req = new NextRequest("http://localhost/api/wallet/withdraw", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: "Bearer token",
      },
      // Pass the ReadableStream directly as body
      body: controller,
      // @ts-ignore
      duplex: "half",
    });

    const res = await POST(req);
    const body = await res.json();

    expect(res.status).toBe(413);
    expect(body.title).toBe("Payload Too Large");
    expect(body.detail).toContain("exceeds the maximum allowed size of 10KB");
  });
});
