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

function unescapeCSV(value) {
    let result = value;
    if (result.startsWith('"') && result.endsWith('"') && result.length >= 2) {
        result = result.substring(1, result.length - 1);
    }
    return result.replace(/""/g, '"');
}

function analyzeCSV(filePath) {
    if (!fs.existsSync(filePath)) {
        console.error(`File not found: ${filePath}`);
        process.exit(1);
    }

    const content = fs.readFileSync(filePath, 'utf8');
    const lines = content.split(/\r?\n/);

    const data = {
        exportedAt: null,
        accountEmail: null,
        currentUserId: null,
        currentUserName: null,
        version: "unknown",
        sections: {
            FRIENDS: [],
            GROUPS: [],
            GROUP_MEMBERS: [],
            EXPENSES: [],
            EXPENSE_INVOLVED_MEMBERS: [],
            EXPENSE_SPLITS: [],
            EXPENSE_SUBEXPENSES: [],
            PARTICIPANT_NAMES: []
        },
        errors: []
    };

    let currentSection = null;

    if (content.includes("===PAYBACK_EXPORT===")) {
        data.version = "V2 (Default)";
    } else if (content.includes("===PAYBACK_EXPORT_V1===")) {
        data.version = "V1 (Legacy)";
    }

    if (!content.includes("===END_PAYBACK_EXPORT===")) {
        data.errors.push("Missing end marker: ===END_PAYBACK_EXPORT===");
    }

    for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed || trimmed.startsWith("#")) continue;

        if (trimmed.startsWith("[") && trimmed.endsWith("]")) {
            currentSection = trimmed.substring(1, trimmed.length - 1);
            continue;
        }

        if (trimmed.startsWith("EXPORTED_AT:")) {
            data.exportedAt = trimmed.substring("EXPORTED_AT:".length).trim();
            continue;
        }
        if (trimmed.startsWith("ACCOUNT_EMAIL:")) {
            data.accountEmail = trimmed.substring("ACCOUNT_EMAIL:".length).trim();
            continue;
        }
        if (trimmed.startsWith("CURRENT_USER_ID:")) {
            data.currentUserId = trimmed.substring("CURRENT_USER_ID:".length).trim();
            continue;
        }
        if (trimmed.startsWith("CURRENT_USER_NAME:")) {
            data.currentUserName = unescapeCSV(trimmed.substring("CURRENT_USER_NAME:".length).trim());
            continue;
        }

        if (currentSection && data.sections[currentSection] !== undefined) {
            const fields = parseCSVLine(trimmed);
            data.sections[currentSection].push(fields);
        }
    }

    console.log(`\nAnalysis for: ${path.basename(filePath)}`);
    console.log(`Format Version: ${data.version}`);
    console.log(`Exported At: ${data.exportedAt || 'N/A'}`);
    console.log(`Account: ${data.accountEmail || 'N/A'}`);
    console.log(`Current User: ${data.currentUserName || 'N/A'} (${data.currentUserId || 'N/A'})\n`);

    console.log("Section Counts:");
    Object.keys(data.sections).forEach(section => {
        console.log(`- ${section}: ${data.sections[section].length}`);
    });
    console.log("");

    const groupIds = new Set(data.sections.GROUPS.map(g => g[0]));
    const expenseIds = new Set(data.sections.EXPENSES.map(e => e[0]));
    
    const groupToMembers = {};
    data.sections.GROUP_MEMBERS.forEach((m, idx) => {
        const gId = m[0];
        const mId = m[1];
        if (!groupIds.has(gId)) {
            data.errors.push(`GROUP_MEMBERS[${idx}]: Orphaned group reference ${gId}`);
        }
        if (!groupToMembers[gId]) groupToMembers[gId] = new Set();
        groupToMembers[gId].add(mId);
        
        if (m.length < 3) {
            data.errors.push(`GROUP_MEMBERS[${idx}]: Column count mismatch (expected >=3, got ${m.length})`);
        }
    });

    data.sections.EXPENSES.forEach((e, idx) => {
        const gId = e[1];
        const paidById = e[5];

        if (!groupIds.has(gId)) {
            data.errors.push(`EXPENSES[${idx}]: Orphaned group reference ${gId}`);
        }
        if (groupToMembers[gId] && !groupToMembers[gId].has(paidById)) {
            data.errors.push(`EXPENSES[${idx}]: Payer ${paidById} not in group ${gId}`);
        }
        if (e.length !== 8) {
            data.errors.push(`EXPENSES[${idx}]: Column count mismatch (expected 8, got ${e.length})`);
        }
    });

    data.sections.EXPENSE_INVOLVED_MEMBERS.forEach((im, idx) => {
        const eId = im[0];
        if (!expenseIds.has(eId)) {
            data.errors.push(`EXPENSE_INVOLVED_MEMBERS[${idx}]: Orphaned expense reference ${eId}`);
        }
        if (im.length !== 2) {
            data.errors.push(`EXPENSE_INVOLVED_MEMBERS[${idx}]: Column count mismatch (expected 2, got ${im.length})`);
        }
    });

    data.sections.EXPENSE_SPLITS.forEach((s, idx) => {
        const eId = s[0];
        if (!expenseIds.has(eId)) {
            data.errors.push(`EXPENSE_SPLITS[${idx}]: Orphaned expense reference ${eId}`);
        }
        if (s.length !== 5) {
            data.errors.push(`EXPENSE_SPLITS[${idx}]: Column count mismatch (expected 5, got ${s.length})`);
        }
    });

    data.sections.FRIENDS.forEach((f, idx) => {
        if (f.length < 6) {
            data.errors.push(`FRIENDS[${idx}]: Column count mismatch (expected >=6, got ${f.length})`);
        }
        const status = f[8];
        if (status && !['friend', 'peer'].includes(status.toLowerCase())) {
            data.errors.push(`FRIENDS[${idx}]: Invalid status '${status}' (expected 'friend' or 'peer')`);
        }
    });

    if (data.errors.length > 0) {
        console.log("Validation Errors:");
        data.errors.forEach(err => {
            console.log(`[!] ${err}`);
        });
    } else {
        console.log("No schema or referential integrity errors found.");
    }
}

const args = process.argv.slice(2);
if (args.length === 0) {
    console.log("Usage: node scripts/analyze_csv.js <path-to-csv>");
} else {
    analyzeCSV(args[0]);
}
