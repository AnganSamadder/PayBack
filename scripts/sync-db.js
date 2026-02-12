const fs = require("fs");
const path = require("path");
const { Client } = require("pg");

async function sync() {
  console.log("🔄 Syncing Supabase database...");

  // 1. Get Project Ref (optional if DB_HOST is set)
  let projectRef = "unknown";
  try {
    const refPath = path.join(__dirname, "../supabase/.temp/project-ref");
    projectRef = fs.readFileSync(refPath, "utf8").trim();
  } catch (e) {
    // Ignore if explicit host is provided
  }

  // 2. Read Schema File
  const schemaPath = path.join(__dirname, "../supabase/schema.sql");
  if (!fs.existsSync(schemaPath)) {
    console.error(`❌ Schema file not found: ${schemaPath}`);
    process.exit(1);
  }
  const schemaSql = fs.readFileSync(schemaPath, "utf8");

  // 3. Connect to DB
  const dbPassword = process.env.DB_PASSWORD;
  if (!dbPassword) {
    console.error("❌ DB_PASSWORD environment variable is required.");
    process.exit(1);
  }

  // Determine Connection Params (ENV Override > Defaults)
  const host = process.env.DB_HOST || `db.${projectRef}.supabase.co`;
  const port = parseInt(process.env.DB_PORT || "5432");
  const user = process.env.DB_USER || "postgres";
  const database = process.env.DB_NAME || "postgres";

  const client = new Client({
    host,
    port,
    database,
    user,
    password: dbPassword,
    ssl: { rejectUnauthorized: false }
  });

  try {
    console.log(`🚀 Connecting to ${host}:${port} as ${user}...`);
    await client.connect();

    console.log("📝 Executing schema.sql...");
    await client.query(schemaSql);

    console.log("✅ Database sync complete!");
  } catch (err) {
    console.error("❌ Error executing schema:", err.message);

    if (err.message.includes("ECONNREFUSED")) {
      console.error(
        "\n💡 Tip: Connection refused. Usually due to IPv6-only database blocked by local network."
      );
      console.error("   FIX: Add DB_HOST=<pooler_url> to your scripts/.env file.");
    } else if (
      err.message.includes("password authentication failed") ||
      err.message.includes("no such user")
    ) {
      console.error("\n💡 Tip: Authentication failed.");
      console.error("   FIX: Verify DB_USER and DB_PASSWORD in scripts/.env");
      if (host.includes("pooler")) {
        console.error("   NOTE: Pooler username format is usually [db_user].[project_ref]");
      }
    }
    process.exit(1);
  } finally {
    await client.end();
  }
}

sync();
