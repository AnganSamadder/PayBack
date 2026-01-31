/* eslint-disable */
/**
 * Generated `api` utility.
 *
 * THIS CODE IS AUTOMATICALLY GENERATED.
 *
 * To regenerate, run `npx convex dev`.
 * @module
 */

import type * as admin from "../admin.js";
import type * as aliases from "../aliases.js";
import type * as cleanup from "../cleanup.js";
import type * as crons from "../crons.js";
import type * as debug from "../debug.js";
import type * as expenses from "../expenses.js";
import type * as fix_alias from "../fix_alias.js";
import type * as friend_requests from "../friend_requests.js";
import type * as friends from "../friends.js";
import type * as groups from "../groups.js";
import type * as helpers from "../helpers.js";
import type * as inviteTokens from "../inviteTokens.js";
import type * as janitor from "../janitor.js";
import type * as linkRequests from "../linkRequests.js";
import type * as maintenance from "../maintenance.js";
import type * as migrations from "../migrations.js";
import type * as migrations_backfill_ids from "../migrations/backfill_ids.js";
import type * as rateLimit from "../rateLimit.js";
import type * as users from "../users.js";
import type * as utils from "../utils.js";

import type {
  ApiFromModules,
  FilterApi,
  FunctionReference,
} from "convex/server";

declare const fullApi: ApiFromModules<{
  admin: typeof admin;
  aliases: typeof aliases;
  cleanup: typeof cleanup;
  crons: typeof crons;
  debug: typeof debug;
  expenses: typeof expenses;
  fix_alias: typeof fix_alias;
  friend_requests: typeof friend_requests;
  friends: typeof friends;
  groups: typeof groups;
  helpers: typeof helpers;
  inviteTokens: typeof inviteTokens;
  janitor: typeof janitor;
  linkRequests: typeof linkRequests;
  maintenance: typeof maintenance;
  migrations: typeof migrations;
  "migrations/backfill_ids": typeof migrations_backfill_ids;
  rateLimit: typeof rateLimit;
  users: typeof users;
  utils: typeof utils;
}>;

/**
 * A utility for referencing Convex functions in your app's public API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = api.myModule.myFunction;
 * ```
 */
export declare const api: FilterApi<
  typeof fullApi,
  FunctionReference<any, "public">
>;

/**
 * A utility for referencing Convex functions in your app's internal API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = internal.myModule.myFunction;
 * ```
 */
export declare const internal: FilterApi<
  typeof fullApi,
  FunctionReference<any, "internal">
>;

export declare const components: {};
