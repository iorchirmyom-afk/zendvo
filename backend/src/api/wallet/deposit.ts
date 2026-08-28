import { NextRequest, NextResponse } from "next/server";
import {
  DefindexService,
  DefindexServiceError,
} from "@/lib/services/defindex_service";
import { getAuthPayload } from "@/lib/auth-session";
import { createProblemDetails } from "@/lib/api-utils";
import { db } from "@/lib/db";
import { users } from "@/lib/db/schema";
import { eq } from "drizzle-orm";

export async function POST(request: NextRequest) {
  try {
    const payload = await getAuthPayload(request);
    if (!payload) {
      return createProblemDetails(
        "about:blank",
        "Unauthorized",
        401,
        "Authentication required",
      );
    }

    const { userId } = payload;

    let body: unknown;
    try {
      body = await request.json();
    } catch {
      body = {};
    }

    const { amount } =
      body !== null && typeof body === "object" && !Array.isArray(body)
        ? (body as { amount?: unknown })
        : {};

    if (typeof amount !== "string" || !amount.trim()) {
      return createProblemDetails(
        "about:blank",
        "Bad Request",
        400,
        "amount is required and must be a string of the deposit amount in smallest units",
      );
    }

    const [user] = await db
      .select({ stellarAddress: users.stellarAddress })
      .from(users)
      .where(eq(users.id, userId));

    if (!user?.stellarAddress) {
      return createProblemDetails(
        "about:blank",
        "Bad Request",
        400,
        "No Stellar address registered for this account",
      );
    }

    const result = await DefindexService.calculateDepositParams(
      user.stellarAddress,
      amount.trim(),
    );

    return NextResponse.json(
      { success: true, ...result },
      { status: 200 },
    );
  } catch (error) {
    console.error("[WALLET_DEPOSIT_ERROR]", error);
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
            "The DeFindex vault could not be reached at this time",
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
      "Failed to calculate deposit parameters",
    );
  }
}