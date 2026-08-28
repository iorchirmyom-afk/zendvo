import { NextRequest } from "next/server";
import { POST } from "@/api/wallet/deposit";
import { getAuthPayload } from "@/lib/auth-session";
import { DefindexService, DefindexServiceError } from "@/lib/services/defindex_service";

const VALID_STELLAR_ADDRESS = "GDWF77422SKLZTBQT77BQEQLCIQY6PFTFZX5OFJTLAFFWJ2PK5WBOZAN";

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

jest.mock("@/lib/db", () => {
  const selectWhere = jest.fn();
  return {
    db: {
      select: jest.fn(() => ({
        from: jest.fn(() => ({
          where: selectWhere,
        })),
      })),
    },
    __mocks: { selectWhere },
  };
});

jest.mock("@/lib/services/defindex_service", () => {
  const actual = jest.requireActual("@/lib/services/defindex_service");
  return {
    ...actual,
    DefindexService: {
      calculateDepositParams: jest.fn(),
    },
  };
});

const mockGetAuthPayload = getAuthPayload as jest.Mock;
const mockCalculateDepositParams = (
  DefindexService as jest.Mocked<typeof DefindexService>
).calculateDepositParams as jest.Mock;
const { __mocks } = require("@/lib/db");

const MOCK_RESULT = {
  userAddress: VALID_STELLAR_ADDRESS,
  amount: "100000000",
  estimatedShares: "100",
  sharePrice: "10000000",
  userBalance: "0",
  totalManagedFunds: "10000000000",
  totalSupply: "10000",
  contractId: "CAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABBBBA",
  networkPassphrase: "Test SDF Network ; September 2015",
  rpcUrl: "https://fake-rpc.example.com",
  unsignedXdr: "AAAAAgAAAAD9t89zRQAJbT2b1B9B",
  txHash: "a".repeat(64),
};

function makeRequest(body?: Record<string, unknown>) {
  return new NextRequest("http://localhost/api/wallet/deposit", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: "Bearer token",
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
}

describe("POST /api/wallet/deposit", () => {
  beforeEach(() => {
    jest.clearAllMocks();
  });

  it("returns 401 when no auth token is provided", async () => {
    mockGetAuthPayload.mockResolvedValue(null);

    const res = await POST(makeRequest({ amount: "100000000" }));
    const body = await res.json();

    expect(res.status).toBe(401);
    expect(body.title).toBe("Unauthorized");
  });

  it("returns 400 when amount is missing", async () => {
    mockGetAuthPayload.mockResolvedValue({ userId: "user-1" });

    const res = await POST(makeRequest({}));
    const body = await res.json();

    expect(res.status).toBe(400);
    expect(body.title).toBe("Bad Request");
    expect(body.detail).toContain("amount is required");
  });

  it("returns 400 when amount is not a string", async () => {
    mockGetAuthPayload.mockResolvedValue({ userId: "user-1" });

    const res = await POST(makeRequest({ amount: 12345 }));
    const body = await res.json();

    expect(res.status).toBe(400);
    expect(body.title).toBe("Bad Request");
  });

  it("returns 400 when the user has no registered Stellar address", async () => {
    mockGetAuthPayload.mockResolvedValue({ userId: "user-1" });
    __mocks.selectWhere.mockResolvedValueOnce([
      { stellarAddress: null },
    ]);

    const res = await POST(makeRequest({ amount: "100000000" }));
    const body = await res.json();

    expect(res.status).toBe(400);
    expect(body.detail).toContain("No Stellar address registered");
  });

  it("returns 200 with the deposit parameters and unsigned XDR", async () => {
    mockGetAuthPayload.mockResolvedValue({ userId: "user-1" });
    __mocks.selectWhere.mockResolvedValueOnce([
      { stellarAddress: VALID_STELLAR_ADDRESS },
    ]);
    mockCalculateDepositParams.mockResolvedValueOnce(MOCK_RESULT);

    const res = await POST(makeRequest({ amount: "100000000" }));
    const body = await res.json();

    expect(res.status).toBe(200);
    expect(body.success).toBe(true);
    expect(body.unsignedXdr).toBe(MOCK_RESULT.unsignedXdr);
    expect(body.estimatedShares).toBe("100");
    expect(body.txHash).toMatch(/^[0-9a-f]{64}$/);
    expect(mockCalculateDepositParams).toHaveBeenCalledWith(
      VALID_STELLAR_ADDRESS,
      "100000000",
    );
  });

  it("returns 400 with a helpful detail when the service reports a validation error", async () => {
    mockGetAuthPayload.mockResolvedValue({ userId: "user-1" });
    __mocks.selectWhere.mockResolvedValueOnce([
      { stellarAddress: VALID_STELLAR_ADDRESS },
    ]);
    mockCalculateDepositParams.mockRejectedValueOnce(
      new DefindexServiceError(
        "Invalid deposit amount \"-5\": must be greater than zero",
        "validation",
      ),
    );

    const res = await POST(makeRequest({ amount: "-5" }));
    const body = await res.json();

    expect(res.status).toBe(400);
    expect(body.title).toBe("Bad Request");
    expect(body.detail).toContain("Invalid deposit amount");
  });

  it("returns 500 without exposing internals when the service reports a configuration error", async () => {
    mockGetAuthPayload.mockResolvedValue({ userId: "user-1" });
    __mocks.selectWhere.mockResolvedValueOnce([
      { stellarAddress: VALID_STELLAR_ADDRESS },
    ]);
    mockCalculateDepositParams.mockRejectedValueOnce(
      new DefindexServiceError(
        "DEFINDEX_VAULT_CONTRACT_ID is not configured",
        "configuration",
      ),
    );

    const res = await POST(makeRequest({ amount: "100000000" }));
    const body = await res.json();

    expect(res.status).toBe(500);
    expect(body.title).toBe("Internal Server Error");
    expect(body.detail).not.toContain("DEFINDEX_VAULT_CONTRACT_ID");
  });

  it("returns 502 with a generic detail when the service reports an upstream failure", async () => {
    mockGetAuthPayload.mockResolvedValue({ userId: "user-1" });
    __mocks.selectWhere.mockResolvedValueOnce([
      { stellarAddress: VALID_STELLAR_ADDRESS },
    ]);
    mockCalculateDepositParams.mockRejectedValueOnce(
      new DefindexServiceError(
        "Failed to query total_supply on vault: HostError: contract invocation failed",
        "upstream",
      ),
    );

    const res = await POST(makeRequest({ amount: "100000000" }));
    const body = await res.json();

    expect(res.status).toBe(502);
    expect(body.title).toBe("Bad Gateway");
    expect(body.detail).not.toContain("HostError");
  });

  it("returns 500 on unexpected errors", async () => {
    mockGetAuthPayload.mockResolvedValue({ userId: "user-1" });
    __mocks.selectWhere.mockRejectedValueOnce(new Error("DB connection error"));

    const res = await POST(makeRequest({ amount: "100000000" }));
    const body = await res.json();

    expect(res.status).toBe(500);
    expect(body.title).toBe("Internal Server Error");
  });

  it("returns 400 when the request body is not valid JSON", async () => {
    mockGetAuthPayload.mockResolvedValue({ userId: "user-6" });

    const req = new NextRequest("http://localhost/api/wallet/deposit", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: "Bearer token",
      },
      body: "not-json",
    });
    const res = await POST(req);
    const body = await res.json();

    expect(res.status).toBe(400);
    expect(body.title).toBe("Bad Request");
  });
});