const dns = require("dns").promises;
const fs = require("fs");
const path = require("path");

async function debug() {
  console.log("🔍 Running DNS Diagnostics...");

  // Get Ref
  let projectRef;
  try {
    projectRef = fs
      .readFileSync(path.join(__dirname, "../supabase/.temp/project-ref"), "utf8")
      .trim();
    console.log(`📦 Project Ref: ${projectRef}`);
  } catch (e) {
    console.error("❌ Could not read project ref");
    return;
  }

  const hosts = [`db.${projectRef}.supabase.co`, "aws-0-us-east-1.pooler.supabase.com"];

  for (const host of hosts) {
    console.log(`\nChecking host: ${host}`);

    // Check IPv4
    try {
      const ipv4 = await dns.resolve4(host);
      console.log(`  ✅ IPv4 (A): ${ipv4.join(", ")}`);
    } catch (e) {
      console.log(`  ❌ IPv4 (A): Not found (${e.code})`);
    }

    // Check IPv6
    try {
      const ipv6 = await dns.resolve6(host);
      console.log(`  ✅ IPv6 (AAAA): ${ipv6.join(", ")}`);
    } catch (e) {
      console.log(`  ❌ IPv6 (AAAA): Not found (${e.code})`);
    }
  }
}

debug();
