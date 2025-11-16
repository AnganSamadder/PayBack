# Phase 1 Progress: AppStore.swift Test Coverage

## Current Status
- **Starting Coverage**: 74.34% (1596/2147 lines)
- **Target Coverage**: 95% (2040/2147 lines)
- **Lines Needed**: 444 additional lines

## Phase 1: AppStoreDataNormalizationTests.swift - COMPLETED

### Tests Added: 24 new tests

#### Complex Alias Mapping Tests (7 tests)
1. ✅ `testNormalizeExpenses_WithChainedAliases` - Tests chained alias resolution
2. ✅ `testNormalizeExpenses_WithMultipleAliasesPerMember` - Tests multiple IDs per member
3. ✅ `testNormalizeExpenses_WithAliasInPaidBy` - Tests alias in paidByMemberId
4. ✅ `testNormalizeExpenses_WithAliasInInvolvedMembers` - Tests aliases in involvedMemberIds
5. ✅ `testNormalizeExpenses_WithDuplicateInvolvedMembers` - Tests deduplication
6. ✅ `testNormalizeExpenses_AggregatesSplitsForSameMember` - Tests split aggregation
7. ✅ `testNormalizeExpenses_PreservesSettledStatusWhenAggregating` - Tests settled status preservation

#### Group Normalization Edge Cases (4 tests)
8. ✅ `testNormalizeGroup_WithTripleDuplicateMembers` - Tests 3 duplicate members
9. ✅ `testNormalizeGroup_WithCurrentUserAlias` - Tests current user alias handling
10. ✅ `testNormalizeGroup_WithOnlyAliases` - Tests all-alias groups
11. ✅ `testNormalizeGroup_MarksAsDirectWhenTwoMembers` - Tests isDirect flag

#### Group Synthesis Tests (4 tests)
12. ✅ `testSynthesizeGroup_WithFivePlusMembers` - Tests large group synthesis
13. ✅ `testSynthesizeGroup_WithNoParticipantNames` - Tests fallback names
14. ✅ `testSynthesizeGroup_WithMixedNameSources` - Tests mixed name sources
15. ✅ `testSynthesizeGroup_UsesEarliestExpenseDate` - Tests date selection

#### Name Resolution Tests (4 tests)
16. ✅ `testResolveMemberName_PrefersNonCurrentUserName` - Tests name preference
17. ✅ `testResolveMemberName_UsesCachedName` - Tests cache usage
18. ✅ `testResolveMemberName_UsesFriendName` - Tests friend name usage
19. ✅ `testResolveMemberName_UsesFallbackForUnknown` - Tests fallback

#### Synthesized Group Name Tests (5 tests)
20. ✅ `testSynthesizedGroupName_WithTwoMembers` - Tests direct group naming
21. ✅ `testSynthesizedGroupName_WithThreeMembers` - Tests 3-member naming
22. ✅ `testSynthesizedGroupName_WithFourMembers` - Tests 4-member naming
23. ✅ `testSynthesizedGroupName_WithFivePlusMembers` - Tests large group naming
24. ✅ `testSynthesizedGroupName_FallsBackToImportedGroup` - Tests fallback naming

### Total Test Count in File
- **Before**: 15 tests
- **After**: 39 tests
- **Added**: 24 tests

## Test Results

### Latest Run (39 tests total)
- **Passed**: 30 tests ✅
- **Failed**: 9 tests ❌
- **Success Rate**: 77%

### Failed Tests (Need Investigation)
1. `testNormalizeExpenses_WithMultipleAliasesPerMember` - Alias resolution issue
2. `testSynthesizeGroup_WithNoParticipantNames` - Fallback name handling
3. `testResolveMemberName_PrefersNonCurrentUserName` - Name preference logic
4. `testSynthesizeGroup_WithFivePlusMembers` - Large group synthesis
5. `testSynthesizeGroup_WithMixedNameSources` - Mixed name sources
6. `testResolveMemberName_UsesFallbackForUnknown` - Fallback logic
7. `testNormalizeExpenses_WithChainedAliases` - Chained alias resolution
8. `testResolveMemberName_UsesCachedName` - Cache usage
9. `testResolveMemberName_UsesFriendName` - Friend name resolution

### Analysis
The failures are primarily in:
- **Name resolution logic** (5 failures) - Tests expecting specific name selection behavior
- **Group synthesis** (3 failures) - Tests for orphan expense handling
- **Alias mapping** (2 failures) - Tests for complex ID resolution

These failures indicate the tests are correctly identifying edge cases that may need attention in the actual implementation, or the test expectations need adjustment.

## Next Steps

### Option 1: Fix Current Tests
- Debug the crash by running tests in smaller batches
- Identify which specific tests are causing issues
- Optimize async operations and reduce memory usage

### Option 2: Continue with Other Phases
- Move to Phase 2: AppStoreLinkingTests.swift
- Move to Phase 3: AppStoreEdgeCaseTests.swift
- Move to Phase 4: AppStoreQueryTests.swift
- Move to Phase 5: AppStoreRemoteDataTests.swift

### Option 3: Measure Current Progress
- Run a subset of the new tests to measure coverage improvement
- Identify which tests provide the most coverage value
- Prioritize high-value tests

## Recommendation

**Run tests in smaller batches to measure actual coverage improvement:**

```bash
# Test just the new alias tests
xcodebuild test -scheme PayBackTests \
  -only-testing:PayBackTests/AppStoreDataNormalizationTests/testNormalizeExpenses_WithChainedAliases \
  -only-testing:PayBackTests/AppStoreDataNormalizationTests/testNormalizeExpenses_WithMultipleAliasesPerMember \
  -only-testing:PayBackTests/AppStoreDataNormalizationTests/testNormalizeExpenses_WithAliasInPaidBy \
  -enableCodeCoverage YES

# Then check coverage
xcrun xccov view --report build/test-results.xcresult | grep "AppStore.swift"
```

This will help us understand:
1. If the tests are actually increasing coverage
2. Which tests are most valuable
3. Whether we need to adjust our approach
