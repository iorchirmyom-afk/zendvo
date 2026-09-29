// DeFindex Service
// Instantiates the official DeFindex server SDK and a Soroban RPC client to
// query vault parameters, estimate yield rates (APY), and build unsigned
// smart-contract invocations. Deposit parameter calculation queries vault
// state over RPC for metadata; its final simulated XDR comes from the SDK.
//
// Environment variables:
// - DEFINDEX_VAULT_CONTRACT_ID: address (C...) of the DeFindex vault contract
// - DEFINDEX_API_KEY: optional API key for the DeFindex server SDK
// - DEFINDEX_API_URL: optional DeFindex API base URL
// - SOROBAN_RPC_URL: Soroban RPC endpoint (defaults to Soroban testnet)
// - STELLAR_NETWORK_PASSPHRASE: network passphrase (defaults to testnet)
import {
  DefindexSDK,
  SupportedNetworks,
  type DepositParams as DefindexSdkDepositParams,
  type VaultApyResponse,
  type VaultInfoResponse,
  type VaultTransactionResponse,
  type WithdrawParams as DefindexSdkWithdrawParams,
} from "@defindex/sdk";
import {
  Account,
  Address,
  Contract,
  Networks,
  rpc,
  SorobanDataBuilder,
  StrKey,
  TransactionBuilder,
  nativeToScVal,
  scValToNative,
  xdr,
} from "@stellar/stellar-sdk";
import { eq, sql } from "drizzle-orm";
import { db } from "../db";
import { savingsHistory, users } from "../db/schema";

/** Configured DeFindex SDK instance plus the Soroban RPC client it talks to. */
export interface DefindexClient {
  sdk: DefindexSDK;
  server: rpc.Server;
  rpcUrl: string;
  networkPassphrase: string;
  network: SupportedNetworks;
}

/** Estimated vault yield returned by the DeFindex SDK. */
export interface VaultApyEstimate {
  apy: number;
  contractId: string;
  networkPassphrase: string;
  rpcUrl: string;
}

/** Unsigned vault invocation produced by the DeFindex SDK. */
export interface VaultInvocation {
  unsignedXdr: string;
  functionName: string;
  contractId: string;
  networkPassphrase: string;
  rpcUrl: string;
}

/** Details about the yield / APY estimate for a vault position. */
export interface APYInfo {
  /**
   * Annualized yield rate as a float (e.g. 0.0825 for 8.25%),
   * or `null` if insufficient historical data exists to calculate a meaningful APY.
   */
  rate: number | null;
  /** Formatted APY percentage string (e.g. "8.25%" or "N/A"). */
  formatted: string;
  /** True if this APY is an estimate calculated from historical share price changes. */
  isEstimated: boolean;
  /** Description of the methodology used to derive or evaluate the APY. */
  methodology: string;
  /** Optional realized yield in USDC over the elapsed period if calculated against a user deposit. */
  realizedYieldUsdc?: string | null;
}

/** Historical share price snapshot used to calculate realized yield / APY. */
export interface HistoricalSharePriceSnapshot {
  /** Timestamp in seconds (Unix epoch), ISO date string, or Date of historical snapshot. */
  timestamp: number | string | Date;
  /** Historical share price (scaled by 10^7, as a string or bigint). */
  sharePrice: string | bigint;
}

/** Options for querying a vault position / balance. */
export interface GetVaultBalanceOptions {
  /** Override default vault contract ID. */
  vaultContractId?: string;
  /** Override default RPC URL. */
  rpcUrl?: string;
  /** Override default network passphrase. */
  networkPassphrase?: string;
  /** Bypass in-memory cache and perform a fresh RPC query. */
  skipCache?: boolean;
  /** Cache TTL in milliseconds for this request (default: 10,000ms / 10s). */
  ttlMs?: number;
  /** Historical share price snapshot for APY calculation. */
  historicalSnapshot?: HistoricalSharePriceSnapshot;
}

/** Results of a DeFindex vault balance / position query. */
export interface VaultBalance {
  /** Stellar address of the user. */
  userAddress: string;
  /** DeFindex vault contract ID. */
  contractId: string;
  /** User's raw vault share balance in smallest units (i128, 7 decimals). */
  rawUserBalance: string;
  /** User's normalized vault share balance (decimal string, e.g. "5000.0000000"). */
  userBalance: string;
  /** Current share price scaled by 10^7 (matches USDC / share precision). */
  rawSharePrice: string;
  /** Current share price normalized (decimal string, e.g. "1.0000000"). */
  sharePrice: string;
  /** User's underlying USDC-equivalent position in smallest units (i128, 7 decimals). */
  rawUnderlyingUsdc: string;
  /** User's underlying USDC-equivalent position normalized (decimal string, e.g. "500.0000000"). */
  underlyingUsdc: string;
  /** Total vault share supply in smallest units (i128). */
  rawTotalSupply: string;
  /** Total USDC managed by the vault in smallest units (i128). */
  rawTotalManagedFunds: string;
  /** Soroban RPC endpoint used. */
  rpcUrl: string;
  /** Yield / APY estimation details. */
  apy: APYInfo;
  /** ISO timestamp when the position was fetched. */
  fetchedAt: string;
}

/** Alias for VaultBalance for callers using position terminology. */
export type VaultPosition = VaultBalance;

/** Results of a DeFindex deposit parameter calculation. */
export interface DepositParams {
  userAddress: string;
  amount: string;
  estimatedShares: string;
  sharePrice: string;
  userBalance: string;
  totalManagedFunds: string;
  totalSupply: string;
  contractId: string;
  networkPassphrase: string;
  rpcUrl: string;
  unsignedXdr: string;
  txHash: string;
}

/** Results of a DeFindex withdrawal parameter calculation. */
export interface WithdrawalParams {
  /** Stellar address that owns the vault shares and signs the withdrawal. */
  userAddress: string;
  /** Requested USDC amount to withdraw, in smallest units (i128). */
  amount: string;
  /** Number of vault shares to burn to satisfy the requested amount. */
  sharesToBurn: string;
  /** Expected USDC assets received for the burned shares (same units as amount). */
  expectedAssets: string;
  /**
   * Per-asset minimum amounts passed to the vault `withdraw` invocation.
   * One entry per vault asset; index 0 is the primary (USDC) asset.
   */
  minAmountsOut: string[];
  /**
   * Current share price: total managed USDC divided by total share supply,
   * scaled by 10^7 (matches USDC / vault-share decimals).
   */
  sharePrice: string;
  /** User's vault share balance, in smallest share units (i128). */
  userBalance: string;
  /** Total USDC managed by the vault (idle + invested), smallest units. */
  totalManagedFunds: string;
  /** Total vault share supply, smallest share units. */
  totalSupply: string;
  /** Address of the DeFindex vault contract. */
  contractId: string;
  /** Network passphrase the unsigned XDR is bound to. */
  networkPassphrase: string;
  /** Soroban RPC endpoint used for the contract state queries. */
  rpcUrl: string;
  /** Base64-encoded unsigned withdrawal transaction XDR. */
  unsignedXdr: string;
  /** SHA-256 hash of the unsigned transaction envelope (hex). */
  txHash: string;
}

/** Classifies the source of a DeFindex error for API error mapping. */
export type DefindexServiceErrorKind =
  | "validation"
  | "configuration"
  | "upstream";

export class DefindexServiceError extends Error {
  constructor(
    message: string,
    public readonly kind: DefindexServiceErrorKind = "validation",
    public readonly cause?: Error,
  ) {
    super(message);
    this.name = "DefindexServiceError";
  }
}

/**
 * Formats a raw integer bigint into a decimal string without floating point loss.
 * E.g., formatUnits(12345678n, 7) => "1.2345678"
 */
export function formatUnits(value: bigint, decimals: number = 7): string {
  const isNegative = value < 0n;
  const abs = isNegative ? -value : value;
  const str = abs.toString().padStart(decimals + 1, "0");
  const integerPart = str.slice(0, str.length - decimals);
  const fractionalPart = str.slice(str.length - decimals);
  return `${isNegative ? "-" : ""}${integerPart}.${fractionalPart}`;
}

const USDC_DECIMALS = 7;
const MAX_I128 = (1n << 127n) - 1n;

/**
 * Converts a human-readable USDC amount to Soroban's 7-decimal integer
 * representation without ever passing through a JavaScript number.
 */
export function parseUsdcAmount(amount: string): bigint {
  const normalized = amount.trim();
  const match = /^(\d+)(?:\.(\d{1,7}))?$/.exec(normalized);
  if (!match) {
    throw new DefindexServiceError(
      `Invalid USDC amount "${amount}": expected a positive decimal amount with at most ${USDC_DECIMALS} decimal places`,
      "validation",
    );
  }

  const units = BigInt(match[1]) * 10n ** BigInt(USDC_DECIMALS) +
    BigInt((match[2] || "").padEnd(USDC_DECIMALS, "0") || "0");
  if (units <= 0n) {
    throw new DefindexServiceError(
      `Invalid USDC amount "${amount}": must be greater than zero`,
      "validation",
    );
  }
  if (units > MAX_I128) {
    throw new DefindexServiceError(
      `Invalid USDC amount "${amount}": exceeds the Soroban i128 range`,
      "validation",
    );
  }
  return units;
}

interface CacheEntry<T> {
  data: T;
  expiresAt: number;
}

class DefindexCache {
  private cache = new Map<string, CacheEntry<unknown>>();
  private pendingPromises = new Map<string, Promise<unknown>>();
  private defaultTtlMs = 10_000;

  get<T>(key: string): T | undefined {
    const entry = this.cache.get(key);
    if (!entry) return undefined;
    if (Date.now() > entry.expiresAt) {
      this.cache.delete(key);
      return undefined;
    }
    return entry.data as T;
  }

  set<T>(key: string, data: T, ttlMs?: number): void {
    const ttl = ttlMs ?? this.defaultTtlMs;
    this.cache.set(key, {
      data,
      expiresAt: Date.now() + ttl,
    });
  }

  async getOrFetch<T>(
    key: string,
    fetcher: () => Promise<T>,
    skipCache: boolean = false,
    ttlMs?: number,
  ): Promise<T> {
    if (!skipCache) {
      const cached = this.get<T>(key);
      if (cached !== undefined) {
        return cached;
      }
      const pending = this.pendingPromises.get(key);
      if (pending) {
        return pending as Promise<T>;
      }
    }

    const promise = (async () => {
      try {
        const data = await fetcher();
        if (!skipCache) {
          this.set(key, data, ttlMs);
        }
        return data;
      } finally {
        this.pendingPromises.delete(key);
      }
    })();

    this.pendingPromises.set(key, promise);
    return promise;
  }

  clear(): void {
    this.cache.clear();
    this.pendingPromises.clear();
  }
}

const defindexCacheSingleton = new DefindexCache();

function requireUserAddress(userAddress: string): void {
  if (!StrKey.isValidEd25519PublicKey(userAddress)) {
    throw new DefindexServiceError(
      `Invalid user address "${userAddress}": expected a valid Stellar G... public key`,
      "validation",
    );
  }
}

function requireVaultContractId(): string {
  const contractId = process.env.DEFINDEX_VAULT_CONTRACT_ID;
  if (!contractId || !StrKey.isValidContract(contractId)) {
    throw new DefindexServiceError(
      "DEFINDEX_VAULT_CONTRACT_ID is not configured: expected a valid Stellar C... contract address",
      "configuration",
    );
  }
  return contractId;
}

function parsePositiveAmounts(
  amounts: string[],
  kind: "deposit" | "withdrawal",
): number[] {
  if (!Array.isArray(amounts) || amounts.length === 0) {
    throw new DefindexServiceError(
      `Invalid ${kind} amounts: expected a non-empty array of positive integers in smallest units`,
      "validation",
    );
  }
  return amounts.map((amount) => {
    let amountN: bigint;
    try {
      amountN = BigInt(amount);
    } catch {
      throw new DefindexServiceError(
        `Invalid ${kind} amount "${amount}": must be a positive integer in smallest units`,
        "validation",
      );
    }
    if (amountN <= 0n) {
      throw new DefindexServiceError(
        `Invalid ${kind} amount "${amount}": must be greater than zero`,
        "validation",
      );
    }
    const asNumber = Number(amountN);
    if (!Number.isSafeInteger(asNumber)) {
      throw new DefindexServiceError(
        `Invalid ${kind} amount "${amount}": exceeds JavaScript safe integer range required by the DeFindex SDK`,
        "validation",
      );
    }
    return asNumber;
  });
}

function toVaultInvocation(
  response: VaultTransactionResponse,
  fallbackFunctionName: string,
  contractId: string,
  client: DefindexClient,
): VaultInvocation {
  if (!response.xdr || !response.xdr.trim()) {
    throw new DefindexServiceError(
      `DeFindex SDK returned no transaction XDR for ${fallbackFunctionName} on vault ${contractId}`,
      "upstream",
    );
  }
  if (fallbackFunctionName === "deposit" && response.simulationResponse == null) {
    throw new DefindexServiceError(
      `DeFindex SDK returned no simulation response for deposit on vault ${contractId}`,
      "upstream",
    );
  }
  return {
    unsignedXdr: response.xdr,
    functionName: response.functionName || fallbackFunctionName,
    contractId,
    networkPassphrase: client.networkPassphrase,
    rpcUrl: client.rpcUrl,
  };
}

function wrapSdkError(prefix: string, error: unknown): DefindexServiceError {
  if (error instanceof DefindexServiceError) {
    return error;
  }
  const err = error instanceof Error ? error : new Error(String(error));
  return new DefindexServiceError(`${prefix}: ${err.message}`, "upstream", err);
}

async function queryVault(
  server: rpc.Server,
  contractId: string,
  method: string,
  args: xdr.ScVal[],
  source: string,
  networkPassphrase: string,
): Promise<xdr.ScVal> {
  const contract = new Contract(contractId);
  const sourceAccount = new Account(source, "0");
  const tx = new TransactionBuilder(sourceAccount, {
    fee: "100",
    networkPassphrase,
  })
    .addOperation(contract.call(method, ...args))
    .setTimeout(30)
    .build();

  const simulation = await server.simulateTransaction(tx);
  const simulationError =
    simulation && "error" in simulation
      ? (simulation as rpc.Api.SimulateTransactionErrorResponse).error
      : undefined;
  if (
    !simulation ||
    "error" in simulation ||
    !simulation.result ||
    simulation.result.retval === undefined
  ) {
    throw new DefindexServiceError(
      `Failed to query ${method} on vault ${contractId}${
        simulationError ? `: ${simulationError}` : ""
      }`,
      "upstream",
    );
  }
  return simulation.result.retval;
}

export class DefindexService {
  /**
   * Queries a user's DeFindex vault position on Soroban, including user share balance,
   * share price, underlying USDC balance, and APY/yield estimate.
   *
   * Utilizes a short-lived in-memory cache to deduplicate repeated RPC calls.
   *
   * @param userAddress Stellar G... public key of the user.
   * @param vaultContractId Optional contract address (defaults to DEFINDEX_VAULT_CONTRACT_ID env var).
   * @param options Additional query options (caching, RPC URL, historical snapshot for APY).
   */
  static async getVaultBalance(
    userAddress: string,
    vaultContractId?: string,
    options?: GetVaultBalanceOptions,
  ): Promise<VaultBalance> {
    const contractId =
      vaultContractId || options?.vaultContractId || process.env.DEFINDEX_VAULT_CONTRACT_ID;
    const rpcUrl =
      options?.rpcUrl || process.env.SOROBAN_RPC_URL || "https://soroban-testnet.stellar.org";
    const networkPassphrase =
      options?.networkPassphrase || process.env.STELLAR_NETWORK_PASSPHRASE || Networks.TESTNET;

    if (!StrKey.isValidEd25519PublicKey(userAddress)) {
      throw new DefindexServiceError(
        `Invalid user address "${userAddress}": expected a valid Stellar G... public key`,
        "validation",
      );
    }

    if (!contractId || !StrKey.isValidContract(contractId)) {
      throw new DefindexServiceError(
        "DEFINDEX_VAULT_CONTRACT_ID is not configured: expected a valid Stellar C... contract address",
        "configuration",
      );
    }

    const snapKey = options?.historicalSnapshot
      ? `:${options.historicalSnapshot.timestamp}:${options.historicalSnapshot.sharePrice}`
      : "";
    const cacheKey = `${contractId}:${userAddress}:${rpcUrl}:${networkPassphrase}${snapKey}`;

    return defindexCacheSingleton.getOrFetch(
      cacheKey,
      async () => {
        const server = new rpc.Server(rpcUrl);

        try {
          const userAddressScVal = Address.fromString(userAddress).toScVal();

          const userBalanceRaw = BigInt(
            scValToNative(
              await queryVault(
                server,
                contractId,
                "balance_of",
                [userAddressScVal],
                userAddress,
                networkPassphrase,
              ),
            ) as bigint,
          );

          const totalSupplyRaw = BigInt(
            scValToNative(
              await queryVault(
                server,
                contractId,
                "total_supply",
                [],
                userAddress,
                networkPassphrase,
              ),
            ) as bigint,
          );

          const managedFunds = scValToNative(
            await queryVault(
              server,
              contractId,
              "fetch_total_managed_funds",
              [],
              userAddress,
              networkPassphrase,
            ),
          ) as Array<{
            asset: string;
            total_amount: bigint;
            idle_amount: bigint;
            invested_amount: bigint;
            strategy_allocations: unknown[];
          }>;

          if (managedFunds.length === 0) {
            throw new DefindexServiceError(
              `Vault ${contractId} reports no managed assets; cannot calculate vault balance`,
              "upstream",
            );
          }

          const totalManagedFundsRaw = managedFunds.reduce(
            (sum, asset) => sum + BigInt(asset.total_amount),
            0n,
          );

          if (totalSupplyRaw <= 0n && totalManagedFundsRaw > 0n) {
            throw new DefindexServiceError(
              `Vault ${contractId} manages ${totalManagedFundsRaw} units but has no shares in circulation; cannot calculate position`,
              "upstream",
            );
          }

          if (totalManagedFundsRaw <= 0n && totalSupplyRaw > 0n) {
            throw new DefindexServiceError(
              `Vault ${contractId} has shares in circulation but manages no USDC funds; cannot calculate position`,
              "upstream",
            );
          }

          let sharePriceRaw: bigint;
          let underlyingUsdcRaw: bigint;

          if (totalSupplyRaw <= 0n) {
            sharePriceRaw = 10n ** 7n;
            underlyingUsdcRaw = userBalanceRaw;
          } else {
            sharePriceRaw = (totalManagedFundsRaw * 10n ** 7n) / totalSupplyRaw;
            underlyingUsdcRaw = (userBalanceRaw * totalManagedFundsRaw) / totalSupplyRaw;
          }

          let apy: APYInfo = {
            rate: null,
            formatted: "N/A",
            isEstimated: false,
            methodology:
              "Historical vault performance data is insufficient or unavailable to calculate a meaningful APY.",
          };

          if (options?.historicalSnapshot) {
            const snap = options.historicalSnapshot;
            const pastTime =
              typeof snap.timestamp === "number"
                ? snap.timestamp
                : snap.timestamp instanceof Date
                ? Math.floor(snap.timestamp.getTime() / 1000)
                : Math.floor(new Date(snap.timestamp).getTime() / 1000);
            const currentTime = Math.floor(Date.now() / 1000);
            const elapsedSeconds = currentTime - pastTime;

            const pastSharePriceRaw = BigInt(snap.sharePrice);

            if (
              elapsedSeconds >= 3600 &&
              pastSharePriceRaw > 0n &&
              sharePriceRaw >= pastSharePriceRaw
            ) {
              const ratio = Number(sharePriceRaw) / Number(pastSharePriceRaw);
              const years = elapsedSeconds / (365.25 * 86400);
              const annualizedRate = Math.pow(ratio, 1 / years) - 1;

              if (Number.isFinite(annualizedRate) && annualizedRate >= 0) {
                const percentageStr = (annualizedRate * 100).toFixed(2) + "%";
                apy = {
                  rate: annualizedRate,
                  formatted: percentageStr,
                  isEstimated: true,
                  methodology: `Annualized return derived from historical share price increase over ${Math.round(
                    elapsedSeconds / 3600,
                  )} hours.`,
                };
              }
            }
          }

          return {
            userAddress,
            contractId,
            rawUserBalance: userBalanceRaw.toString(),
            userBalance: formatUnits(userBalanceRaw, 7),
            rawSharePrice: sharePriceRaw.toString(),
            sharePrice: formatUnits(sharePriceRaw, 7),
            rawUnderlyingUsdc: underlyingUsdcRaw.toString(),
            underlyingUsdc: formatUnits(underlyingUsdcRaw, 7),
            rawTotalSupply: totalSupplyRaw.toString(),
            rawTotalManagedFunds: totalManagedFundsRaw.toString(),
            rpcUrl,
            apy,
            fetchedAt: new Date().toISOString(),
          };
        } catch (error) {
          if (error instanceof DefindexServiceError) {
            throw error;
          }
          const err = error instanceof Error ? error : new Error(String(error));
          throw new DefindexServiceError(
            `Failed to query DeFindex vault balance for ${userAddress}: ${err.message}`,
            "upstream",
            err,
          );
        }
      },
      options?.skipCache,
      options?.ttlMs,
    );
  }

  /** Alias for getVaultBalance for callers using position terminology. */
  static async getVaultPosition(
    userAddress: string,
    vaultContractId?: string,
    options?: GetVaultBalanceOptions,
  ): Promise<VaultBalance> {
    return DefindexService.getVaultBalance(userAddress, vaultContractId, options);
  }

  /** Clears the internal RPC response cache (useful for testing and manual invalidation). */
  static clearCache(): void {
    defindexCacheSingleton.clear();
  }

  /**
   * Resolves RPC URL, network passphrase, and DeFindex network from env.
   */
  static resolveConfig(): {
    rpcUrl: string;
    networkPassphrase: string;
    network: SupportedNetworks;
  } {
    const rpcUrl =
      process.env.SOROBAN_RPC_URL || "https://soroban-testnet.stellar.org";
    const networkPassphrase =
      process.env.STELLAR_NETWORK_PASSPHRASE || Networks.TESTNET;
    const network =
      networkPassphrase === Networks.PUBLIC
        ? SupportedNetworks.MAINNET
        : SupportedNetworks.TESTNET;
    return { rpcUrl, networkPassphrase, network };
  }

  /**
   * Instantiates the DeFindex server SDK and a Soroban RPC client, configured
   * with the RPC URL and network passphrase. Constructor failures (invalid
   * RPC URL, SDK init errors) are wrapped as `DefindexServiceError`.
   */
  static createClient(): DefindexClient {
    const { rpcUrl, networkPassphrase, network } = DefindexService.resolveConfig();
    try {
      const server = new rpc.Server(rpcUrl);
      const sdk = new DefindexSDK({
        apiKey: process.env.DEFINDEX_API_KEY,
        baseUrl: process.env.DEFINDEX_API_URL,
        timeout: 30_000,
        defaultNetwork: network,
      });
      return { sdk, server, rpcUrl, networkPassphrase, network };
    } catch (error) {
      const err = error instanceof Error ? error : new Error(String(error));
      throw new DefindexServiceError(
        `Failed to initialize DeFindex SDK for RPC ${rpcUrl}: ${err.message}`,
        "upstream",
        err,
      );
    }
  }

  /**
   * Creates the SDK client and verifies Soroban RPC connectivity. RPC
   * transport failures are wrapped as `kind: "upstream"` errors.
   */
  static async initialize(): Promise<DefindexClient> {
    const client = DefindexService.createClient();
    try {
      await client.server.getHealth();
    } catch (error) {
      if (error instanceof DefindexServiceError) {
        throw error;
      }
      const err = error instanceof Error ? error : new Error(String(error));
      throw new DefindexServiceError(
        `Failed to connect to Soroban RPC at ${client.rpcUrl}: ${err.message}`,
        "upstream",
        err,
      );
    }
    return client;
  }

  /**
   * Queries vault metadata, managed funds, fees, and reported APY via the
   * DeFindex server SDK.
   */
  static async queryVaultInfo(
    vaultAddress?: string,
  ): Promise<VaultInfoResponse> {
    const contractId = vaultAddress || requireVaultContractId();
    const client = await DefindexService.initialize();
    try {
      return await client.sdk.getVaultInfo(contractId, client.network);
    } catch (error) {
      throw wrapSdkError(
        `Failed to query vault info for ${contractId}`,
        error,
      );
    }
  }

  /**
   * Estimates the vault's current yield rate (APY) via the DeFindex SDK.
   */
  static async estimateApy(vaultAddress?: string): Promise<VaultApyEstimate> {
    const contractId = vaultAddress || requireVaultContractId();
    const client = await DefindexService.initialize();
    try {
      const apy: VaultApyResponse = await client.sdk.getVaultAPY(
        contractId,
        client.network,
      );
      return {
        apy: apy.apy,
        contractId,
        networkPassphrase: client.networkPassphrase,
        rpcUrl: client.rpcUrl,
      };
    } catch (error) {
      throw wrapSdkError(
        `Failed to estimate APY for vault ${contractId}`,
        error,
      );
    }
  }

  /**
   * Builds an unsigned deposit invocation through the DeFindex SDK.
   *
   * @param userAddress Stellar G... address that signs the deposit.
   * @param amounts Per-asset deposit amounts in smallest units.
   */
  static async buildDepositInvocation(
    userAddress: string,
    amounts: string[],
    options: { invest?: boolean; slippageBps?: number; vaultAddress?: string } = {},
  ): Promise<VaultInvocation> {
    requireUserAddress(userAddress);
    const parsedAmounts = parsePositiveAmounts(
      amounts,
      "deposit",
    );
    const contractId =
      options.vaultAddress || requireVaultContractId();
    const client = await DefindexService.initialize();

    const depositData: DefindexSdkDepositParams = {
      caller: userAddress,
      amounts: parsedAmounts,
      invest: options.invest ?? true,
      slippageBps: options.slippageBps,
    };

    try {
      const response: VaultTransactionResponse = await client.sdk.depositToVault(
        contractId,
        depositData,
        client.network,
      );
      return toVaultInvocation(
        response,
        "deposit",
        contractId,
        client,
      );
    } catch (error) {
      throw wrapSdkError(
        `Failed to build DeFindex deposit invocation for ${userAddress}`,
        error,
      );
    }
  }

  /**
   * Builds an unsigned withdraw invocation through the DeFindex SDK.
   *
   * @param userAddress Stellar G... address that owns the vault shares.
   * @param amounts Per-asset withdrawal amounts in smallest units.
   */
  static async buildWithdrawInvocation(
    userAddress: string,
    amounts: string[],
    options: { slippageBps?: number; vaultAddress?: string } = {},
  ): Promise<VaultInvocation> {
    requireUserAddress(userAddress);
    const parsedAmounts = parsePositiveAmounts(
      amounts,
      "withdrawal",
    );
    const contractId =
      options.vaultAddress || requireVaultContractId();
    const client = await DefindexService.initialize();

    const withdrawData: DefindexSdkWithdrawParams = {
      caller: userAddress,
      amounts: parsedAmounts,
      slippageBps: options.slippageBps,
    };

    try {
      const response: VaultTransactionResponse =
        await client.sdk.withdrawFromVault(
          contractId,
          withdrawData,
          client.network,
        );
      return toVaultInvocation(
        response,
        "withdraw",
        contractId,
        client,
      );
    } catch (error) {
      throw wrapSdkError(
        `Failed to build DeFindex withdraw invocation for ${userAddress}`,
        error,
      );
    }
  }

  /**
   * Calculates the Soroban parameters required to withdraw `amount` of USDC
   * from the DeFindex vault on behalf of `userAddress` and returns an
   * unsigned withdrawal transaction XDR.
   *
   * It queries the vault contract through Soroban RPC for:
   * - the user's vault share balance (`balance_of`)
   * - the total vault share supply (`total_supply`)
   * - the total managed USDC funds (`fetch_total_managed_funds`)
   *
   * and uses those values to derive the share price, the shares to burn
   * (rounded up so the user receives at least `amount`), the expected USDC
   * payout, and the per-asset minimum amounts. The unsigned transaction is
   * simulated against the RPC so the returned XDR carries the necessary
   * Soroban contract footprint, resource estimates, and (unsigned)
   * authorization entries the user's wallet must sign before submission.
   *
   * @param userAddress Stellar G... address that owns the vault shares.
   * @param amount USDC amount to withdraw, in smallest units (i128, 7 decimals).
   */
  static async calculateWithdrawalParams(
    userAddress: string,
    amount: string,
  ): Promise<WithdrawalParams> {
    requireUserAddress(userAddress);

    let amountN: bigint;
    try {
      amountN = BigInt(amount);
    } catch {
      throw new DefindexServiceError(
        `Invalid withdrawal amount "${amount}": must be a positive integer in smallest units`,
        "validation",
      );
    }
    if (amountN <= 0n) {
      throw new DefindexServiceError(
        `Invalid withdrawal amount "${amount}": must be greater than zero`,
        "validation",
      );
    }

    const contractId = requireVaultContractId();
    const { server, rpcUrl, networkPassphrase } = DefindexService.createClient();

    try {
      // ── Query vault state via Soroban RPC ────────────────────────────────
      const userAddressScVal = Address.fromString(userAddress).toScVal();

      const userBalance = BigInt(
        scValToNative(
          await queryVault(
            server,
            contractId,
            "balance_of",
            [userAddressScVal],
            userAddress,
            networkPassphrase,
          ),
        ) as bigint,
      );

      const totalSupply = BigInt(
        scValToNative(
          await queryVault(
            server,
            contractId,
            "total_supply",
            [],
            userAddress,
            networkPassphrase,
          ),
        ) as bigint,
      );

      const managedFunds = scValToNative(
        await queryVault(
          server,
          contractId,
          "fetch_total_managed_funds",
          [],
          userAddress,
          networkPassphrase,
        ),
      ) as Array<{
        asset: string;
        total_amount: bigint;
        idle_amount: bigint;
        invested_amount: bigint;
        strategy_allocations: unknown[];
      }>;

      if (managedFunds.length === 0) {
        throw new DefindexServiceError(
          `Vault ${contractId} reports no managed assets; cannot calculate withdrawal parameters`,
          "upstream",
        );
      }

      const totalManagedFunds = managedFunds.reduce(
        (sum, asset) => sum + BigInt(asset.total_amount),
        0n,
      );

      if (totalSupply <= 0n) {
        throw new DefindexServiceError(
          `Vault ${contractId} has no shares in circulation; cannot calculate a share price`,
          "upstream",
        );
      }
      if (totalManagedFunds <= 0n) {
        throw new DefindexServiceError(
          `Vault ${contractId} manages no USDC funds; nothing to withdraw`,
          "upstream",
        );
      }

      // ── Derive withdrawal parameters ─────────────────────────────────────
      // Share price = total managed USDC / total share supply, scaled to
      // 7 decimals to match the vault share / USDC precision.
      const sharePrice = (totalManagedFunds * 10n ** 7n) / totalSupply;

      // Max USDC the user can withdraw given their share balance.
      const maxWithdrawable =
        (userBalance * totalManagedFunds) / totalSupply;
      if (amountN > maxWithdrawable) {
        throw new DefindexServiceError(
          `Insufficient vault balance: user ${userAddress} can withdraw at most ${maxWithdrawable} units but ${amountN} was requested`,
          "validation",
        );
      }

      // Round shares up so the user receives at least the requested amount.
      const sharesToBurn =
        (amountN * totalSupply + totalManagedFunds - 1n) / totalManagedFunds;

      if (sharesToBurn > userBalance) {
        throw new DefindexServiceError(
          `Insufficient vault shares: ${sharesToBurn} shares required but user holds ${userBalance}`,
          "validation",
        );
      }

      // Per-asset expected payout mirrors the vault contract's own formula:
      // asset.total_amount * shares / total_shares_supply (floor).
      const minAmountsOut = managedFunds.map((asset) =>
        ((BigInt(asset.total_amount) * sharesToBurn) / totalSupply).toString(),
      );
      const expectedAssets = minAmountsOut[0];

      // ── Build the unsigned withdrawal transaction XDR ────────────────────
      const contract = new Contract(contractId);
      const withdrawOp = contract.call(
        "withdraw",
        nativeToScVal(sharesToBurn, { type: "i128" }),
        nativeToScVal(minAmountsOut.map((min) => BigInt(min)), {
          type: "i128",
        }),
        Address.fromString(userAddress).toScVal(),
      );

      const sourceAccount = new Account(userAddress, "0");
      const tx = new TransactionBuilder(sourceAccount, {
        fee: "100",
        networkPassphrase,
      })
        .addOperation(withdrawOp)
        .setTimeout(30)
        .setSorobanData(new SorobanDataBuilder().build())
        .build();

      // Simulate against the RPC so the unsigned XDR carries the necessary
      // Soroban contract footprint, resource estimates, and the authorization
      // entries the user's wallet must sign.
      let finalTx = tx;
      try {
        const simulation = await server.simulateTransaction(tx);
        if (simulation && !("error" in simulation) && simulation.transactionData) {
          finalTx = rpc.assembleTransaction(tx, simulation).build();
        } else {
          const simulationError = (simulation as rpc.Api.SimulateTransactionErrorResponse)
            ?.error || "Unknown simulation failure (missing transactionData)";
          throw new DefindexServiceError(
            `Withdrawal simulation failed for vault ${contractId}: ${simulationError}`,
            "upstream",
          );
        }
      } catch (error) {
        if (error instanceof DefindexServiceError) {
          throw error;
        }
        const err = error instanceof Error ? error : new Error(String(error));
        throw new DefindexServiceError(
          `Withdrawal simulation failed for vault ${contractId}: ${err.message}`,
          "upstream",
          err,
        );
      }

      return {
        userAddress,
        amount: amountN.toString(),
        sharesToBurn: sharesToBurn.toString(),
        expectedAssets,
        minAmountsOut,
        sharePrice: sharePrice.toString(),
        userBalance: userBalance.toString(),
        totalManagedFunds: totalManagedFunds.toString(),
        totalSupply: totalSupply.toString(),
        contractId,
        networkPassphrase,
        rpcUrl,
        unsignedXdr: finalTx.toXDR(),
        txHash: finalTx.hash().toString("hex"),
      };
    } catch (error) {
      if (error instanceof DefindexServiceError) {
        throw error;
      }
      const err = error instanceof Error ? error : new Error(String(error));
      throw new DefindexServiceError(
        `Failed to calculate DeFindex withdrawal parameters for ${userAddress}: ${err.message}`,
        "upstream",
        err,
      );
    }
  }

  /**
   * Builds a fully simulated, resource-fee assembled DeFindex deposit XDR
   * from a human-readable USDC amount (for example, "50.00").
   *
   * The returned `amount` remains the 7-decimal smallest-unit value for
   * backwards compatibility with existing clients.
   */
  static async buildDeFindexDepositXdr(
    userAddress: string,
    amount: string,
  ): Promise<DepositParams> {
    return DefindexService.calculateDepositParams(
      userAddress,
      parseUsdcAmount(amount).toString(),
    );
  }

  /**
   * Legacy smallest-unit deposit builder. New callers should use
   * buildDeFindexDepositXdr with a human-readable USDC amount instead.
   */
  static async calculateDepositParams(
    userAddress: string,
    amount: string,
  ): Promise<DepositParams> {
    requireUserAddress(userAddress);

    let amountN: bigint;
    try {
      amountN = BigInt(amount);
    } catch {
      throw new DefindexServiceError(
        `Invalid deposit amount "${amount}": must be a positive integer in smallest units`,
        "validation",
      );
    }
    if (amountN <= 0n) {
      throw new DefindexServiceError(
        `Invalid deposit amount "${amount}": must be greater than zero`,
        "validation",
      );
    }
    if (amountN > BigInt(Number.MAX_SAFE_INTEGER)) {
      throw new DefindexServiceError(
        `Invalid deposit amount "${amount}": exceeds JavaScript safe integer range required by the DeFindex SDK`,
        "validation",
      );
    }

    const contractId = requireVaultContractId();
    const client = DefindexService.createClient();
    const { server, rpcUrl, networkPassphrase } = client;

    try {
      const totalSupply = BigInt(
        scValToNative(
          await queryVault(
            server,
            contractId,
            "total_supply",
            [],
            userAddress,
            networkPassphrase,
          ),
        ) as bigint,
      );

      const managedFunds = scValToNative(
        await queryVault(
          server,
          contractId,
          "fetch_total_managed_funds",
          [],
          userAddress,
          networkPassphrase,
        ),
      ) as Array<{
        asset: string;
        total_amount: bigint;
        idle_amount: bigint;
        invested_amount: bigint;
        strategy_allocations: unknown[];
      }>;

      if (managedFunds.length === 0) {
        throw new DefindexServiceError(
          `Vault ${contractId} reports no managed assets; cannot calculate deposit parameters`,
          "upstream",
        );
      }

      const totalManagedFunds = managedFunds.reduce(
        (sum, asset) => sum + BigInt(asset.total_amount),
        0n,
      );

      // A vault with no shares and no managed funds reports an inconsistent
      // state; only a genuinely new vault (both zero) uses the 1:1 fallback.
      if (totalSupply <= 0n && totalManagedFunds > 0n) {
        throw new DefindexServiceError(
          `Vault ${contractId} manages ${totalManagedFunds} units but has no shares in circulation; cannot calculate deposit parameters`,
          "upstream",
        );
      }
      if (totalManagedFunds <= 0n && totalSupply > 0n) {
        throw new DefindexServiceError(
          `Vault ${contractId} has shares in circulation but manages no USDC funds; cannot calculate deposit parameters`,
          "upstream",
        );
      }

      let sharePrice: bigint;
      let estimatedShares: bigint;

      if (totalSupply <= 0n) {
        sharePrice = 10n ** 7n;
        estimatedShares = amountN;
      } else {
        sharePrice = (totalManagedFunds * 10n ** 7n) / totalSupply;
        estimatedShares =
          (amountN * totalSupply) / totalManagedFunds;
      }

      const userBalance = BigInt(
        scValToNative(
          await queryVault(
            server,
            contractId,
            "balance_of",
            [Address.fromString(userAddress).toScVal()],
            userAddress,
            networkPassphrase,
          ),
        ) as bigint,
      );

      let sdkResponse: VaultTransactionResponse;
      try {
        sdkResponse = await client.sdk.depositToVault(
          contractId,
          {
            amounts: [Number(amountN)],
            caller: userAddress,
            invest: true,
          },
          client.network,
        );
      } catch (error) {
        if (error instanceof DefindexServiceError) {
          throw error;
        }
        const err = error instanceof Error ? error : new Error(String(error));
        throw new DefindexServiceError(
          `Failed to build simulated DeFindex deposit for vault ${contractId}: ${err.message}`,
          "upstream",
          err,
        );
      }

      if (!sdkResponse.xdr || !sdkResponse.xdr.trim()) {
        throw new DefindexServiceError(
          `DeFindex SDK returned no transaction XDR for deposit on vault ${contractId}`,
          "upstream",
        );
      }
      if (sdkResponse.simulationResponse == null) {
        throw new DefindexServiceError(
          `DeFindex SDK returned no simulation response for deposit on vault ${contractId}`,
          "upstream",
        );
      }

      let sdkTransaction;
      try {
        sdkTransaction = TransactionBuilder.fromXDR(
          sdkResponse.xdr,
          networkPassphrase,
        );
      } catch (error) {
        const err = error instanceof Error ? error : new Error(String(error));
        throw new DefindexServiceError(
          `DeFindex SDK returned invalid transaction XDR for deposit on vault ${contractId}: ${err.message}`,
          "upstream",
          err,
        );
      }

      return {
        userAddress,
        amount: amountN.toString(),
        estimatedShares: estimatedShares.toString(),
        sharePrice: sharePrice.toString(),
        userBalance: userBalance.toString(),
        totalManagedFunds: totalManagedFunds.toString(),
        totalSupply: totalSupply.toString(),
        contractId,
        networkPassphrase,
        rpcUrl,
        unsignedXdr: sdkResponse.xdr,
        txHash: sdkTransaction.hash().toString("hex"),
      };
    } catch (error) {
      if (error instanceof DefindexServiceError) {
        throw error;
      }
      const err = error instanceof Error ? error : new Error(String(error));
      throw new DefindexServiceError(
        `Failed to calculate DeFindex deposit parameters for ${userAddress}: ${err.message}`,
        "upstream",
        err,
      );
    }
  }

  /**
   * Persists a confirmed savings transfer atomically.
   *
   * All database writes run inside a single `db.transaction()` block:
   * 1. Lock the user's ledger row (`SELECT ... FOR UPDATE`) so concurrent
   *    savings writes for the same user are serialized.
   * 2. Conflict check — an existing `savings_history` row with the same
   *    `transaction_hash` is returned idempotently; a hash owned by another
   *    user aborts the transaction.
   * 3. Insert the `savings_history` entry with status `completed`.
   * 4. Update the cached `users.savings_balance` / `users.savings_status`.
   *
   * Throwing anywhere inside the callback rolls everything back, so the
   * local database can never diverge from the Stellar blockchain with a
   * partial write or a race-condition double-apply.
   */
  static async recordSuccessfulSavingsTransaction(
    input: RecordSavingsTransactionInput,
  ): Promise<RecordedSavingsTransaction> {
    const amount = Number(input.amount);
    const transactionHash = input.transactionHash?.trim();
    const vaultContractId =
      input.vaultContractId?.trim() || process.env.DEFINDEX_VAULT_CONTRACT_ID;
    if (!input.userId) {
      throw new DefindexServiceError("userId is required", "validation");
    }
    if (input.type !== "deposit" && input.type !== "withdrawal") {
      throw new DefindexServiceError("Invalid savings transaction type", "validation");
    }
    if (!Number.isFinite(amount) || amount <= 0) {
      throw new DefindexServiceError(
        "Savings amount must be greater than zero",
        "validation",
      );
    }
    if (!vaultContractId) {
      throw new DefindexServiceError(
        "Vault contract id is required to record a savings transaction",
        "validation",
      );
    }
    if (!transactionHash || !/^[a-fA-F0-9]{64}$/.test(transactionHash)) {
      throw new DefindexServiceError(
        "Valid 64-character blockchain transaction hash is required",
        "validation",
      );
    }
    const currency = input.currency?.trim().toUpperCase() || "USDC";

    try {
      return await db.transaction(async (tx) => {
        // 1. Lock the user's ledger row.
        const [lockedUser] = await tx
          .select()
          .from(users)
          .where(eq(users.id, input.userId))
          .for("update");
        if (!lockedUser) {
          throw new Error("User not found");
        }

        // 2. Conflict detection — idempotent replay.
        const existing = await tx.query.savingsHistory.findFirst({
          where: eq(savingsHistory.transactionHash, transactionHash),
        });
        if (existing) {
          if (existing.userId !== input.userId) {
            throw new Error("Transaction hash already claimed by another user");
          }
          return {
            transaction: existing,
            savingsBalance: lockedUser.savingsBalance,
          };
        }

        // 3. Withdrawals must not overdraw the cached ledger balance.
        if (
          input.type === "withdrawal" &&
          Number(lockedUser.savingsBalance || 0) < amount
        ) {
          throw new Error("Insufficient savings balance");
        }

        // 4. Insert the history entry.
        const [inserted] = await tx
          .insert(savingsHistory)
          .values({
            userId: input.userId,
            vaultContractId,
            type: input.type,
            status: "completed",
            amount,
            currency,
            transactionHash,
            sharesToBurn: input.sharesToBurn ?? null,
            sharePrice: input.sharePrice ?? null,
            sharesBalance: input.sharesBalance ?? null,
          })
          .returning();
        if (!inserted) {
          throw new Error("Failed to insert savings history entry");
        }

        // 5. Update the cached savings balance atomically.
        const [updatedUser] = await tx
          .update(users)
          .set({
            savingsBalance:
              input.type === "deposit"
                ? sql`${users.savingsBalance} + ${amount}`
                : sql`${users.savingsBalance} - ${amount}`,
            savingsStatus: "active",
            updatedAt: new Date(),
          })
          .where(eq(users.id, input.userId))
          .returning({ savingsBalance: users.savingsBalance });
        if (!updatedUser) {
          throw new Error("Failed to update savings balance");
        }

        return {
          transaction: inserted,
          savingsBalance: updatedUser.savingsBalance,
        };
      });
    } catch (error) {
      if (error instanceof DefindexServiceError) {
        throw error;
      }
      const err = error instanceof Error ? error : new Error(String(error));
      throw new DefindexServiceError(
        `Failed to record savings ${input.type} for user ${input.userId}: ${err.message}`,
        "upstream",
        err,
      );
    }
  }

  /** Convenience wrapper for recording a confirmed savings deposit. */
  static async recordSavingsDeposit(
    input: Omit<RecordSavingsTransactionInput, "type">,
  ): Promise<RecordedSavingsTransaction> {
    return DefindexService.recordSuccessfulSavingsTransaction({
      ...input,
      type: "deposit",
    });
  }

  /** Convenience wrapper for recording a confirmed savings withdrawal. */
  static async recordSavingsWithdrawal(
    input: Omit<RecordSavingsTransactionInput, "type">,
  ): Promise<RecordedSavingsTransaction> {
    return DefindexService.recordSuccessfulSavingsTransaction({
      ...input,
      type: "withdrawal",
    });
  }

  /**
   * Records a failed savings transfer without mutating the cached balance.
   * Still executed inside `db.transaction()` with the user row locked so the
   * failure marker cannot interleave with a concurrent success; any error
   * rolls the block back.
   */
  static async recordFailedSavingsTransaction(input: {
    userId: string;
    type: "deposit" | "withdrawal";
    amount: number;
    vaultContractId?: string;
    transactionHash?: string | null;
    currency?: string;
    errorMessage: string;
  }): Promise<{ transaction: typeof savingsHistory.$inferSelect }> {
    const amount = Number(input.amount);
    const vaultContractId =
      input.vaultContractId?.trim() || process.env.DEFINDEX_VAULT_CONTRACT_ID;
    const transactionHash = input.transactionHash?.trim() || null;
    if (!input.userId) {
      throw new DefindexServiceError("userId is required", "validation");
    }
    if (input.type !== "deposit" && input.type !== "withdrawal") {
      throw new DefindexServiceError("Invalid savings transaction type", "validation");
    }
    if (!Number.isFinite(amount) || amount <= 0) {
      throw new DefindexServiceError(
        "Savings amount must be greater than zero",
        "validation",
      );
    }
    if (!vaultContractId) {
      throw new DefindexServiceError(
        "Vault contract id is required to record a savings transaction",
        "validation",
      );
    }
    if (!input.errorMessage?.trim()) {
      throw new DefindexServiceError("Error message is required", "validation");
    }
    if (transactionHash && !/^[a-fA-F0-9]{64}$/.test(transactionHash)) {
      throw new DefindexServiceError(
        "Transaction hash must be a 64-character hex string",
        "validation",
      );
    }
    const currency = input.currency?.trim().toUpperCase() || "USDC";

    try {
      return await db.transaction(async (tx) => {
        const [lockedUser] = await tx
          .select()
          .from(users)
          .where(eq(users.id, input.userId))
          .for("update");
        if (!lockedUser) {
          throw new Error("User not found");
        }

        if (transactionHash) {
          const existing = await tx.query.savingsHistory.findFirst({
            where: eq(savingsHistory.transactionHash, transactionHash),
          });
          if (existing) {
            if (existing.userId !== input.userId) {
              throw new Error("Transaction hash already claimed by another user");
            }
            return { transaction: existing };
          }
        }

        const [inserted] = await tx
          .insert(savingsHistory)
          .values({
            userId: input.userId,
            vaultContractId,
            type: input.type,
            status: "failed",
            amount,
            currency,
            transactionHash,
            errorMessage: input.errorMessage.trim(),
          })
          .returning();
        if (!inserted) {
          throw new Error("Failed to insert savings history entry");
        }
        return { transaction: inserted };
      });
    } catch (error) {
      if (error instanceof DefindexServiceError) {
        throw error;
      }
      const err = error instanceof Error ? error : new Error(String(error));
      throw new DefindexServiceError(
        `Failed to record failed savings ${input.type} for user ${input.userId}: ${err.message}`,
        "upstream",
        err,
      );
    }
  }
}

/** Input for persisting a confirmed savings deposit/withdrawal. */
export interface RecordSavingsTransactionInput {
  userId: string;
  type: "deposit" | "withdrawal";
  amount: number;
  vaultContractId?: string;
  transactionHash: string;
  currency?: string;
  sharesToBurn?: number | null;
  sharePrice?: number | null;
  sharesBalance?: number | null;
}

/** Result of a transactional savings write. */
export interface RecordedSavingsTransaction {
  transaction: typeof savingsHistory.$inferSelect;
  savingsBalance: number;
}

/** Convenience export for callers that consume this service as functions. */
export async function buildDeFindexDepositXdr(
  userAddress: string,
  amount: string,
): Promise<DepositParams> {
  return DefindexService.buildDeFindexDepositXdr(userAddress, amount);
}
