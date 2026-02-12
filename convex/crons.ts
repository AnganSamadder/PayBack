import { cronJobs } from "convex/server";
import { internal } from "./_generated/api";

const crons = cronJobs();

crons.cron(
  "janitor cleanup orphans",
  "*/5 * * * *",
  internal.janitor.cleanupOrphans,
  {}
);

export default crons;
