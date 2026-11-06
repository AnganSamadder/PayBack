/* eslint-disable */
/**
 * Generated `api` utility.
 *
 * THIS CODE IS AUTOMATICALLY GENERATED.
 *
 * To regenerate, run `npx convex dev`.
 * @module
 */

import type {
  ApiFromModules,
  FilterApi,
  FunctionReference,
} from "convex/server";
import type * as admin from "../admin.js";
import type * as aliases from "../aliases.js";
import type * as authEnvironment from "../authEnvironment.js";
import type * as bulkImport from "../bulkImport.js";
import type * as cleanup from "../cleanup.js";
import type * as cleanupEmailMaterialization from "../cleanupEmailMaterialization.js";
import type * as crons from "../crons.js";
import type * as debug from "../debug.js";
import type * as directLedger from "../directLedger.js";
import type * as expenseWrites from "../expenseWrites.js";
import type * as expenses from "../expenses.js";
import type * as financialContract from "../financialContract.js";
import type * as fix_alias from "../fix_alias.js";
import type * as friendLinkProvenance from "../friendLinkProvenance.js";
import type * as friend_requests from "../friend_requests.js";
import type * as friends from "../friends.js";
import type * as groupVisibility from "../groupVisibility.js";
import type * as groups from "../groups.js";
import type * as helpers from "../helpers.js";
import type * as identity from "../identity.js";
import type * as identityOperations from "../identityOperations.js";
import type * as inviteTokens from "../inviteTokens.js";
import type * as janitor from "../janitor.js";
import type * as linkRequests from "../linkRequests.js";
import type * as maintenance from "../maintenance.js";
import type * as memberReferences from "../memberReferences.js";
import type * as migrations from "../migrations.js";
import type * as migrations_backfill_ids from "../migrations/backfill_ids.js";
import type * as migrations_groupVisibility from "../migrations/groupVisibility.js";
import type * as migrations_userExpenseRefs from "../migrations/userExpenseRefs.js";
import type * as moneyValidation from "../moneyValidation.js";
import type * as orphanCleanup from "../orphanCleanup.js";
import type * as rateLimit from "../rateLimit.js";
import type * as syncState from "../syncState.js";
import type * as tests from "../tests.js";
import type * as users from "../users.js";
import type * as utils from "../utils.js";

/**
 * A utility for referencing Convex functions in your app's API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = api.myModule.myFunction;
 * ```
 */
declare const fullApi: ApiFromModules<{
  admin: typeof admin;
  aliases: typeof aliases;
  authEnvironment: typeof authEnvironment;
  bulkImport: typeof bulkImport;
  cleanup: typeof cleanup;
  cleanupEmailMaterialization: typeof cleanupEmailMaterialization;
  crons: typeof crons;
  debug: typeof debug;
  directLedger: typeof directLedger;
  expenseWrites: typeof expenseWrites;
  expenses: typeof expenses;
  financialContract: typeof financialContract;
  fix_alias: typeof fix_alias;
  friendLinkProvenance: typeof friendLinkProvenance;
  friend_requests: typeof friend_requests;
  friends: typeof friends;
  groupVisibility: typeof groupVisibility;
  groups: typeof groups;
  helpers: typeof helpers;
  identity: typeof identity;
  identityOperations: typeof identityOperations;
  inviteTokens: typeof inviteTokens;
  janitor: typeof janitor;
  linkRequests: typeof linkRequests;
  maintenance: typeof maintenance;
  memberReferences: typeof memberReferences;
  migrations: typeof migrations;
  "migrations/backfill_ids": typeof migrations_backfill_ids;
  "migrations/groupVisibility": typeof migrations_groupVisibility;
  "migrations/userExpenseRefs": typeof migrations_userExpenseRefs;
  moneyValidation: typeof moneyValidation;
  orphanCleanup: typeof orphanCleanup;
  rateLimit: typeof rateLimit;
  syncState: typeof syncState;
  tests: typeof tests;
  users: typeof users;
  utils: typeof utils;
}>;
export declare const api: FilterApi<
  typeof fullApi,
  FunctionReference<any, "public">
>;
export declare const internal: FilterApi<
  typeof fullApi,
  FunctionReference<any, "internal">
>;
