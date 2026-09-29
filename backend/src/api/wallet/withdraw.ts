import { NextRequest, NextResponse } from "next/server";
import {
  DefindexService,
  DefindexServiceError,
} from "@/lib/services/defindex_service";
import { getAuthPayload } from "@/lib/auth-session";
import { createProblemDetails } from "@/lib/api-utils";
import { StrKey } from "@stellar/stellar-sdk";

// Maximum value for signed 128-bit integer (Soroban/i128 limit)
const MAX_I128 = (1n << 127n) - 1n;

export async function POST(request: NextRequest) {
  try {
    // 1. Authenticate user
    const payload = await getAuthPayload(request);
    if (!payload) {
      return createProblemDetails(
        "about:blank",
        "Unauthorized",
        401,
        "Authentication required",
      );
    }

    // 2. Parse request body with stream limit check
    const limit = 10 * 1024; // 10KB limit
    let body: unknown = {};

    if (request.body) {
      try {
        const reader = request.body.getReader();
        const chunks: Uint8Array[] = [];
        let totalBytes = 0;

        while (true) {
          const { done, value } = await reader.read();
          if (done) {
            break;
          }
          if (value) {
            totalBytes += value.length;
            if (totalBytes > limit) {
              return createProblemDetails(
                "about:blank",
                "Payload Too Large",
                413,
                "Request body exceeds the maximum allowed size of 10KB.",
              );
            }
            chunks.push(value);
          }
        }

        const combined = new Uint8Array(totalBytes);
        let offset = 0;
        for (const chunk of chunks) {
          combined.set(chunk, offset);
          offset += chunk.length;
        }

        const text = new TextDecoder().decode(combined);
        if (text.trim()) {
          try {
            body = JSON.parse(text);
          } catch {
            return createProblemDetails(
              "about:blank",
              "Bad Request",
              400,
              "Invalid JSON payload",
            );
          }
        }
      } catch (streamError) {
        return createProblemDetails(
          "about:blank",
          "Bad Request",
          400,
          "Error reading request stream",
        );
      }
    }

    const { userAddress, amount } =
      body !== null && typeof body === "object" && !Array.isArray(body)
        ? (body as { userAddress?: unknown; amount?: unknown })
        : {};

    // 3. Validate userAddress
    if (typeof userAddress !== "string") {
      return createProblemDetails(
        "about:blank",
        "Bad Request",
        400,
        "userAddress is required and must be a string",
      );
    }

    const trimmedAddress = userAddress.trim();
    if (!trimmedAddress) {
      return createProblemDetails(
        "about:blank",
        "Bad Request",
        400,
        "userAddress is required and cannot be empty",
      );
    }

    if (!StrKey.isValidEd25519PublicKey(trimmedAddress)) {
      return createProblemDetails(
        "about:blank",
        "Bad Request",
        400,
        "Invalid Stellar public key format",
      );
    }

    // 4. Validate amount
    if (typeof amount !== "string") {
      return createProblemDetails(
        "about:blank",
        "Bad Request",
        400,
        "amount is required and must be a string representation of the withdrawal amount in smallest units",
      );
    }

    const trimmedAmount = amount.trim();
    if (!trimmedAmount) {
      return createProblemDetails(
        "about:blank",
        "Bad Request",
        400,
        "amount is required and cannot be empty",
      );
    }

    // Must be a positive integer (digits only)
    if (!/^\d+$/.test(trimmedAmount)) {
      return createProblemDetails(
        "about:blank",
        "Bad Request",
        400,
        "amount must be a valid positive integer in smallest units",
      );
    }

    let amountBigInt: bigint;
    try {
      amountBigInt = BigInt(trimmedAmount);
    } catch {
      return createProblemDetails(
        "about:blank",
        "Bad Request",
        400,
        "amount is malformed",
      );
    }

    if (amountBigInt <= 0n) {
      return createProblemDetails(
        "about:blank",
        "Bad Request",
        400,
        "amount must be greater than zero",
      );
    }

    if (amountBigInt > MAX_I128) {
      return createProblemDetails(
        "about:blank",
        "Bad Request",
        400,
        "amount is too large to be safely represented as a 128-bit signed integer",
      );
    }

    // 5. Invoke DeFindex parameter calculation
    const result = await DefindexService.calculateWithdrawalParams(
      trimmedAddress,
      trimmedAmount,
    );

    // 6. Return mapped response
    return NextResponse.json(
      {
        success: true,
        unsignedXdr: result.unsignedXdr,
        expectedUsdcAssets: result.expectedAssets,
        minimumOutputs: result.minAmountsOut,
        estimatedTransactionHash: result.txHash,
        sharesToBurn: result.sharesToBurn,
        sharePrice: result.sharePrice,
        userBalance: result.userBalance,
        totalManagedFunds: result.totalManagedFunds,
        totalSupply: result.totalSupply,
        contractId: result.contractId,
        userAddress: result.userAddress,
        amount: result.amount,
      },
      { status: 200 },
    );
  } catch (error) {
    console.error("[WALLET_WITHDRAW_ERROR]", error);
    if (error instanceof DefindexServiceError) {
      switch (error.kind) {
        case "configuration":
          return createProblemDetails(
            "about:blank",
            "Internal Server Error",
            500,
            "The DeFindex vault is not configured correctly",
          );
        case "upstream":
          return createProblemDetails(
            "about:blank",
            "Bad Gateway",
            502,
            "The DeFindex vault could not be reached or simulated at this time",
          );
        case "validation":
        default:
          return createProblemDetails(
            "about:blank",
            "Bad Request",
            400,
            error.message,
          );
      }
    }
    return createProblemDetails(
      "about:blank",
      "Internal Server Error",
      500,
      "Failed to calculate withdrawal parameters",
    );
  }
}
