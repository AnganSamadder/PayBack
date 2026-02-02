const fs = require('fs');
const path = require('path');

function parseCSVLine(line) {
    const fields = [];
    let currentField = "";
    let inQuotes = false;
    
    for (let i = 0; i < line.length; i++) {
        const char = line[i];
        
        if (char === '"') {
            if (inQuotes) {
                if (i + 1 < line.length && line[i + 1] === '"') {
                    currentField += '"';
                    i++;
                } else {
                    inQuotes = false;
                }
            } else {
                inQuotes = true;
            }
        } else if (char === ',' && !inQuotes) {
            fields.push(currentField);
            currentField = "";
        } else {
            currentField += char;
        }
    }
    
    fields.push(currentField);
    return fields;
}

function parseCSV(filePath) {
    if (!fs.existsSync(filePath)) {
        console.error(`CSV file not found: ${filePath}`);
        process.exit(1);
    }
    const content = fs.readFileSync(filePath, 'utf8');
    const lines = content.split(/\r?\n/);
    const sections = {
        GROUPS: [],
        EXPENSES: []
    };
    let currentSection = null;

    for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed || trimmed.startsWith("#") || trimmed.startsWith("===")) continue;

        if (trimmed.startsWith("[") && trimmed.endsWith("]")) {
            currentSection = trimmed.substring(1, trimmed.length - 1);
            continue;
        }

        if (currentSection && sections[currentSection] !== undefined) {
            const fields = parseCSVLine(trimmed);
            sections[currentSection].push(fields);
        }
    }
    return sections;
}

function normalizeConvexJson(data) {
    if (Array.isArray(data)) return data;
    if (data && typeof data === 'object' && Array.isArray(data.value)) return data.value;
    return [];
}

function main() {
    const args = process.argv.slice(2);
    if (args.length < 3) {
        console.log("Usage: node scripts/compare_csv_convex.js <csv> <groups.json> <expenses.json>");
        console.log("\nThis tool compares a PayBack CSV export with Convex JSON dumps to ensure data parity.");
        console.log("\nExample dump commands:");
        console.log("  npx convex run groups:list > groups.json");
        console.log("  npx convex run expenses:list > expenses.json");
        console.log("\nExample comparison:");
        console.log("  node scripts/compare_csv_convex.js export.csv groups.json expenses.json");
        process.exit(1);
    }

    const [csvPath, groupsJsonPath, expensesJsonPath] = args;

    const csvData = parseCSV(csvPath);
    const csvGroupIds = new Set(csvData.GROUPS.map(g => g[0]));
    const csvExpenseIds = new Set(csvData.EXPENSES.map(e => e[0]));

    let convexGroupsRaw, convexExpensesRaw;
    try {
        convexGroupsRaw = JSON.parse(fs.readFileSync(groupsJsonPath, 'utf8'));
        convexExpensesRaw = JSON.parse(fs.readFileSync(expensesJsonPath, 'utf8'));
    } catch (e) {
        console.error(`Error parsing JSON dumps: ${e.message}`);
        process.exit(1);
    }

    const convexGroups = normalizeConvexJson(convexGroupsRaw);
    const convexExpenses = normalizeConvexJson(convexExpensesRaw);

    const convexGroupIds = new Set(convexGroups.map(g => g._id || g.id));
    const convexExpenseIds = new Set(convexExpenses.map(e => e._id || e.id));

    const results = {
        groups: {
            missingInConvex: [...csvGroupIds].filter(id => !convexGroupIds.has(id)).sort(),
            extraInConvex: [...convexGroupIds].filter(id => !csvGroupIds.has(id)).sort(),
            countCSV: csvGroupIds.size,
            countConvex: convexGroupIds.size
        },
        expenses: {
            missingInConvex: [...csvExpenseIds].filter(id => !convexExpenseIds.has(id)).sort(),
            extraInConvex: [...convexExpenseIds].filter(id => !csvExpenseIds.has(id)).sort(),
            countCSV: csvExpenseIds.size,
            countConvex: convexExpenseIds.size
        }
    };

    const passed = results.groups.missingInConvex.length === 0 && 
                   results.groups.extraInConvex.length === 0 &&
                   results.expenses.missingInConvex.length === 0 &&
                   results.expenses.extraInConvex.length === 0;

    const summary = [
        "=== CSV vs Convex Comparison ===",
        `Date: ${new Date().toISOString()}`,
        `CSV: ${path.basename(csvPath)}`,
        `Status: ${passed ? "PASS ✅" : "FAIL ❌"}`,
        "",
        "Groups:",
        `  CSV Count:    ${results.groups.countCSV}`,
        `  Convex Count: ${results.groups.countConvex}`,
        `  Missing:      ${results.groups.missingInConvex.length}`,
        `  Extra:        ${results.groups.extraInConvex.length}`,
        "",
        "Expenses:",
        `  CSV Count:    ${results.expenses.countCSV}`,
        `  Convex Count: ${results.expenses.countConvex}`,
        `  Missing:      ${results.expenses.missingInConvex.length}`,
        `  Extra:        ${results.expenses.extraInConvex.length}`
    ];

    if (!passed) {
        summary.push("\nDetailed Discrepancies:");
        if (results.groups.missingInConvex.length > 0) {
            summary.push(`  Missing Group IDs (in CSV but not Convex): ${results.groups.missingInConvex.slice(0, 10).join(", ")}${results.groups.missingInConvex.length > 10 ? "..." : ""}`);
        }
        if (results.groups.extraInConvex.length > 0) {
            summary.push(`  Extra Group IDs (in Convex but not CSV):   ${results.groups.extraInConvex.slice(0, 10).join(", ")}${results.groups.extraInConvex.length > 10 ? "..." : ""}`);
        }
        if (results.expenses.missingInConvex.length > 0) {
            summary.push(`  Missing Expense IDs (in CSV but not Convex): ${results.expenses.missingInConvex.slice(0, 10).join(", ")}${results.expenses.missingInConvex.length > 10 ? "..." : ""}`);
        }
        if (results.expenses.extraInConvex.length > 0) {
            summary.push(`  Extra Expense IDs (in Convex but not CSV):   ${results.expenses.extraInConvex.slice(0, 10).join(", ")}${results.expenses.extraInConvex.length > 10 ? "..." : ""}`);
        }
    }

    const summaryStr = summary.join("\n");
    console.log("\n" + summaryStr + "\n");

    const learningsPath = path.join('.sisyphus', 'notepads', 'csv-import-fix', 'learnings.md');
    const learningsDir = path.dirname(learningsPath);
    
    if (!fs.existsSync(learningsDir)) {
        fs.mkdirSync(learningsDir, { recursive: true });
    }

    const appendContent = `\n## CSV vs Convex Comparison [${new Date().toISOString()}]\n\n\`\`\`text\n${summaryStr}\n\`\`\`\n`;
    fs.appendFileSync(learningsPath, appendContent);

    process.exit(passed ? 0 : 1);
}

main();
