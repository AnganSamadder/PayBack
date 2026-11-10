#!/bin/bash
# Compile the actual production import branch with a recording store/service and
# only the external ConvexEncodable protocol stubbed. No network or Xcode required.
set -euo pipefail
backup_repo_root="$(cd "$(dirname "$0")/.." && pwd)"
backup_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/payback-backup-test.XXXXXX")"
trap 'rm -rf "$backup_test_dir"' EXIT
cd "$backup_repo_root"
swiftc -emit-library -static -emit-module -module-name ConvexMobile \
  scripts/fixtures/backup-production/ConvexMobile.swift \
  -o "$backup_test_dir/libConvexMobile.a" \
  -emit-module-path "$backup_test_dir/ConvexMobile.swiftmodule"
swiftc -I "$backup_test_dir" -L "$backup_test_dir" -lConvexMobile -parse-as-library \
  apps/ios/PayBack/Sources/Models/DomainModels.swift \
  apps/ios/PayBack/Sources/Models/UserAccount.swift \
  apps/ios/PayBack/Sources/Services/Convex/BulkImportDTO.swift \
  apps/ios/PayBack/Sources/Services/Core/DataExportService.swift \
  apps/ios/PayBack/Sources/Services/Core/DataImportService.swift \
  scripts/fixtures/backup-production/Harness.swift \
  -o "$backup_test_dir/proof"
"$backup_test_dir/proof"
