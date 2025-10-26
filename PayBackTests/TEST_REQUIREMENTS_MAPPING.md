# Test Requirements Mapping

This document maps test files and test methods to their corresponding requirements from `.kiro/specs/unit-testing/requirements.md`.

## Requirements Coverage Matrix

### R1: Expense Splitting Logic

**Test File**: `BusinessLogic/ExpenseSplittingTests.swift`

- `test_equalSplit_twoMembers_eachGetsHalf()` - Equal split validation
- `test_equalSplit_threeMembers_eachGetsThird()` - Equal split validation
- `test_unevenSplit_10DividedBy3_distributesRemainder()` - Rounding logic
- `test_unevenSplit_100DividedBy7_distributesRemainder()` - Rounding logic
- All tests in "Basic Split Tests" section

### R2: Settlement and Debt Tracking

**Test File**: `BusinessLogic/SettlementLogicTests.swift`

- `test_markSplitAsSettled_updatesIsSettledFlag()` - Settlement status updates
- `test_allSplitsSettled_allSettled_returnsTrue()` - Expense settlement validation
- `test_unsettledSplits_filtersCorrectly()` - Unsettled split filtering
- `test_isSettled_forMember_returnsCorrectStatus()` - Member-specific settlement status
- `test_split_forMember_returnsCorrectSplit()` - Split retrieval

### R3: Phone Number and Email Formatting

**Test Files**: 
- `Services/Auth/PhoneNumberFormatterTests.swift`
- `Services/Auth/EmailValidatorTests.swift`

Phone Number Tests:
- `test_stripNonDigits_removesAllNonNumeric()` - Non-digit removal
- `test_forDisplay_usNumbers_formatsCorrectly()` - US number formatting
- `test_forDisplay_internationalNumbers_formatsWithPlus()` - International formatting
- `test_forStorage_producesE164Format()` - E.164 format validation

Email Tests:
- `test_isValid_validEmails_returnsTrue()` - Valid email validation
- `test_isValid_invalidEmails_returnsFalse()` - Invalid email detection
- `test_normalized_trimsAndLowercases()` - Email normalization

### R4: Account Linking Feature

**Test File**: `Models/LinkingModelsTests.swift`

- `test_linkRequest_initialization_setsAllFields()` - LinkRequest initialization
- `test_linkRequestStatus_transitions_areValid()` - Status transitions
- `test_inviteToken_expiration_setsCorrectly()` - Token expiration
- `test_inviteToken_claim_populatesFields()` - Token claim state
- `test_linkingError_descriptions_areProvided()` - Error messages

### R5: Link State Reconciliation

**Test File**: `Services/LinkStateReconciliationTests.swift`

- `test_reconcile_matchingLocalAndRemote_noChanges()` - Matching data reconciliation
- `test_reconcile_conflictingData_remoteTakesPrecedence()` - Conflict resolution
- `test_reconcile_remoteOnly_addsToLocal()` - Adding remote friends
- `test_validateLinkCompletion_correctFlags()` - Link completion validation
- `test_shouldReconcile_respectsMinimumInterval()` - Interval checking

### R6: Retry Policy Logic

**Test File**: `Services/RetryPolicyTests.swift`

- `test_execute_successOnFirstAttempt_noRetries()` - No retry on success
- `test_execute_retryableError_retriesWithDelay()` - Retry on failure
- `test_execute_allAttemptsFail_throwsLastError()` - Exhausted retries
- `test_execute_nonRetryableError_noRetry()` - Non-retryable errors
- `test_calculateDelay_exponentialBackoff()` - Backoff calculation

### R7: Domain Model Behavior

**Test File**: `Models/DomainModelsTests.swift`

- `test_groupMember_equality_sameId_areEqual()` - Member equality
- `test_groupMember_equality_differentIds_areNotEqual()` - Member inequality
- `test_groupMember_hashing_sameId_sameHash()` - Hash consistency
- `test_spendingGroup_initialization_defaultValues()` - Default values
- `test_expense_allSplitsSettled_computedProperty()` - Computed properties

### R8: Smart Icon Selection

**Test File**: `Services/SmartIconTests.swift`

- `test_icon_transportationKeywords_returnsCarIcon()` - Transportation icons
- `test_icon_accommodationKeywords_returnsBedIcon()` - Accommodation icons
- `test_icon_foodKeywords_returnsFoodIcon()` - Food icons
- `test_icon_unknownCategory_returnsDefaultIcon()` - Default icon
- `test_icon_caseInsensitive_matches()` - Case-insensitive matching

### R10: Currency and Date Handling

**Test Files**:
- `BusinessLogic/RoundingTests.swift`
- `TimeBased/TimeBasedLogicTests.swift`

Currency Tests:
- `test_rounding_twoDecimals_roundsCorrectly()` - Two decimal rounding
- `test_expiration_expiredToken_identifiesCorrectly()` - Expiration logic

Date Tests:
- `test_timeInterval_calculation_accurate()` - Time interval calculations
- `test_dateComparison_timezones_worksCorrectly()` - Timezone handling

### R11: Edge Cases in Monetary Calculations

**Test File**: `BusinessLogic/ExpenseSplittingTests.swift`

- `test_negativeAmount_twoMembers_eachGetsNegativeHalf()` - Negative amounts (refunds)
- `test_zeroAmount_splits_allZero()` - Zero amount handling
- `test_verySmallAmount_lessThanMembers_distributesCorrectly()` - Very small amounts
- `test_veryLargeAmount_noOverflow()` - Very large amounts
- `test_unevenSplit_distributesRemainder()` - Rounding distribution

### R12: Mathematical Invariants

**Test File**: `PropertyBased/SplitInvariantsTests.swift`

- `test_conservationProperty_100RandomCases_sumEqualsTotal()` - Conservation of money
- `test_determinism_sameInputsProduceIdenticalOutputs()` - Determinism
- `test_permutationInvariance_memberOrder_doesNotAffectAmounts()` - Permutation invariance
- `test_idempotency_serializeDeserialize_identicalResults()` - Idempotency
- `test_fairness_roundingDistribution_minimized()` - Fair rounding

### R13: Data Persistence and Decoder Robustness

**Test File**: `Serialization/CodableTests.swift`

- `test_decode_extraFields_succeeds()` - Extra fields handling
- `test_decode_missingOptionalFields_usesDefaults()` - Missing optional fields
- `test_decode_unknownEnumCase_handlesGracefully()` - Unknown enum cases
- `test_roundTrip_allModels_dataPreserved()` - Round-trip encoding
- `test_decode_malformedData_throwsError()` - Malformed data handling

### R14: Account Linking Security

**Test File**: `Validation/AccountLinkingSecurityTests.swift`

- `test_inviteToken_cannotBeClaimedTwice()` - Double claim prevention
- `test_inviteToken_expired_failsWithTokenExpired()` - Expired token handling
- `test_selfLinking_fails_withSelfLinkingNotAllowed()` - Self-linking prevention
- `test_memberAlreadyLinked_fails_withMemberAlreadyLinked()` - Already linked member
- `test_accountAlreadyLinked_fails_withAccountAlreadyLinked()` - Already linked account

### R15: Concurrent Operations

**Test File**: `Concurrency/ActorIsolationTests.swift`

- `test_linkStateReconciliation_concurrentReconcile_stateRemainsConsistent()` - Concurrent reconciliation
- `test_linkRequest_concurrentCreation_duplicateDetection()` - Concurrent creation
- `test_reconciliation_duringModification_noCorruption()` - Concurrent modification
- `test_failureRecording_concurrent_correctCounts()` - Concurrent failure recording
- `test_retryOperation_idempotent_noDuplicates()` - Idempotent operations

### R17: Error Handling

**Test Files**:
- `ErrorHandling/NetworkErrorTests.swift`
- `ErrorHandling/BusinessLogicErrorTests.swift`

- `test_linkingError_errorDescription_clearMessage()` - Clear error messages
- `test_linkingError_recoverySuggestion_actionableGuidance()` - Recovery suggestions
- `test_networkError_classification_correct()` - Error classification
- `test_validationError_indicatesField()` - Field-specific errors
- `test_errorMessage_noSensitiveInfo()` - No PII in errors

### R18: Property-Based Tests

**Test File**: `PropertyBased/SplitInvariantsTests.swift`

- `test_conservationProperty_100RandomCases_sumEqualsTotal()` - Conservation across random inputs
- `test_permutationInvariance_randomOrderings()` - Permutation invariance
- `test_edgeCases_randomGeneration()` - Edge case handling
- `test_nonNegativity_positiveExpenses()` - Non-negativity property
- `test_fairness_largeGroups()` - Fairness across group sizes

### R20: Performance Tests

**Test Files**:
- `Performance/SplitCalculationPerformanceTests.swift`
- `Performance/ReconciliationPerformanceTests.swift`
- `Performance/FilteringPerformanceTests.swift`
- `Performance/MemoryUsageTests.swift`

- `test_splitCalculation_100Members_completesInTime()` - Split calculation performance
- `test_reconciliation_500Friends_completesInTime()` - Reconciliation performance
- `test_filtering_1000Expenses_completesInTime()` - Filtering performance
- `test_memoryUsage_largeStructures_reasonable()` - Memory usage

### R21: Currency Minor Units

**Test File**: `BusinessLogic/RoundingTests.swift`

- `test_rounding_zeroDecimals_JPY()` - Zero decimal currencies
- `test_rounding_threeDecimals_KWD()` - Three decimal currencies
- `test_rounding_twoDecimals_USD()` - Two decimal currencies
- `test_currencyFixture_loading_allCurrencies()` - Fixture loading
- `test_floatingPoint_vs_decimal_drift()` - Numeric safety

### R23: Cancellation and Timeouts

**Test File**: `Concurrency/AsyncCancellationTests.swift`

- `test_retryOperation_cancelled_noAdditionalAttempts()` - Cancellation handling
- `test_retryOperation_timeout_enforcedPerAttempt()` - Timeout enforcement
- `test_exponentialBackoff_withJitter_boundedDelay()` - Jitter calculation
- `test_longRunningRetry_cancelled_propagatesImmediately()` - Immediate cancellation

### R24: PII Redaction

**Test File**: `Validation/PIIRedactionTests.swift`

- `test_logging_email_redacted()` - Email redaction
- `test_logging_phoneNumber_redacted()` - Phone number redaction
- `test_logging_token_redacted()` - Token redaction
- `test_errorMessage_noPII()` - No PII in errors
- `test_debugVsRelease_consistentRedaction()` - Debug/release parity

### R25: Serialization Compatibility

**Test File**: `Serialization/GoldenFixtureTests.swift`

- `test_decode_v1Expense_succeeds()` - V1 expense format
- `test_decode_v1Group_succeeds()` - V1 group format
- `test_unknownEnumCase_mapsToDefault()` - Unknown enum handling
- `test_currentEncoder_compatibleFormat()` - Current format compatibility
- `test_intentionalBreakingChange_detected()` - Breaking change detection

### R26: Test Infrastructure

**Test Files**: All test files

- Fixed random seeds in property-based tests
- Code coverage measurement in CI
- Performance metrics with XCTClockMetric
- Memory metrics with XCTMemoryMetric
- Test organization and documentation

### R29: Internationalization

**Test Files**:
- `Services/Auth/PhoneNumberFormatterTests.swift`
- `Services/Auth/EmailValidatorTests.swift`

- `test_email_internationalCharacters_valid()` - International email addresses
- `test_phoneNumber_E164Format_consistent()` - E.164 format
- `test_phoneNumber_localeFormatting_applied()` - Locale-specific formatting

### R30: Smart Icon Robustness

**Test File**: `Services/SmartIconTests.swift`

- `test_icon_pluralForms_matches()` - Plural keyword matching
- `test_icon_multipleCategories_deterministicTieBreak()` - Tie-breaking
- `test_icon_emptyDescription_returnsDefault()` - Empty description handling

### R31: Model Equality and Hashing

**Test File**: `Models/DomainModelsTests.swift`

- `test_groupMember_dictionaryKey_lookupWorks()` - Dictionary key usage
- `test_spendingGroup_set_uniqueness()` - Set uniqueness
- `test_expense_equality_valueNotReference()` - Value-based equality
- `test_hashing_optionalFields_consistent()` - Optional field hashing

### R34: Input Validation

**Test File**: `Validation/InputValidationTests.swift`

- `test_validation_negativeAmount_rejected()` - Negative amount validation
- `test_validation_emptyDescription_rejected()` - Empty description validation
- `test_validation_longName_truncated()` - Long name handling
- `test_validation_sqlInjection_safelyHandled()` - SQL injection prevention
- `test_validation_phoneFormat_rejected()` - Phone format validation

### R35: Async/Await Concurrency

**Test Files**:
- `Concurrency/ActorIsolationTests.swift`
- `Concurrency/AsyncCancellationTests.swift`
- `Concurrency/ErrorPropagationTests.swift`

- `test_actor_accessSerialized()` - Actor isolation
- `test_async_concurrentOperations_consistent()` - Concurrent operations
- `test_async_cancellation_detected()` - Cancellation detection
- `test_async_errorPropagation_correct()` - Error propagation

### R36: Deterministic Rounding

**Test File**: `BusinessLogic/ExpenseSplittingTests.swift`

- `test_remainderDistribution_ascendingUUIDOrder()` - UUID-based distribution
- `test_determinism_sameInputsProduceIdenticalOutputs()` - Cross-device consistency
- `test_crossDevice_identicalResults()` - Device consistency
- `test_recalculation_afterSync_consistent()` - Sync consistency

### R37: Token Security

**Test File**: `Validation/AccountLinkingSecurityTests.swift`

- `test_token_minimumEntropy_enforced()` - Token entropy
- `test_token_insufficientLength_rejected()` - Token length validation
- `test_token_invalidCharacters_rejected()` - Character set validation
- `test_token_reuse_rejected()` - Token reuse prevention

### R38: Injectable Dependencies

**Test Files**: All test files using MockClock

- `test_expiration_withMockClock()` - Stubbed clock usage
- `test_formatting_withMockLocale()` - Stubbed locale usage
- `test_dateCalculation_withMockTimezone()` - Stubbed timezone usage
- `test_clockAdvance_triggersExpiration()` - Clock advancement

### R40: Sanitizers and Race Detection

**CI Configuration**: `.github/workflows/ci.yml`

- Thread Sanitizer enabled in CI matrix
- Address Sanitizer enabled in CI matrix
- No data races detected in concurrent tests
- No memory leaks detected

## Test File Organization

### Models/
- `DomainModelsTests.swift` - R2, R7, R31
- `LinkingModelsTests.swift` - R4

### Services/
- `Auth/PhoneNumberFormatterTests.swift` - R3, R29
- `Auth/EmailValidatorTests.swift` - R3, R29
- `LinkStateReconciliationTests.swift` - R5
- `RetryPolicyTests.swift` - R6, R23
- `SmartIconTests.swift` - R8, R30

### BusinessLogic/
- `ExpenseSplittingTests.swift` - R1, R11, R12, R36
- `SettlementLogicTests.swift` - R2
- `RoundingTests.swift` - R10, R21

### Serialization/
- `CodableTests.swift` - R13
- `GoldenFixtureTests.swift` - R25

### PropertyBased/
- `SplitInvariantsTests.swift` - R12, R18

### Performance/
- `SplitCalculationPerformanceTests.swift` - R20
- `ReconciliationPerformanceTests.swift` - R20
- `FilteringPerformanceTests.swift` - R20
- `MemoryUsageTests.swift` - R20

### Concurrency/
- `ActorIsolationTests.swift` - R15, R35, R40
- `AsyncCancellationTests.swift` - R23, R35
- `ErrorPropagationTests.swift` - R35

### Validation/
- `InputValidationTests.swift` - R34
- `PIIRedactionTests.swift` - R24
- `AccountLinkingSecurityTests.swift` - R14, R37

### ErrorHandling/
- `NetworkErrorTests.swift` - R17
- `BusinessLogicErrorTests.swift` - R17

### TimeBased/
- `TimeBasedLogicTests.swift` - R10, R38

### Helpers/
- `TestHelpers.swift` - R26, R38
- `MockClock.swift` - R38

### Mocks/
- `MockClock.swift` - R38
- `MockClockTests.swift` - R26

## Coverage Summary

All 41 requirements have corresponding test coverage. The test suite provides comprehensive validation of:

- ✅ Core business logic (expense splitting, settlement)
- ✅ Domain models and linking models
- ✅ Service layer (reconciliation, retry, formatters)
- ✅ Mathematical invariants (conservation, determinism, fairness)
- ✅ Data persistence and backward compatibility
- ✅ Concurrency and actor isolation
- ✅ Security (token validation, PII redaction)
- ✅ Performance benchmarks
- ✅ Error handling and validation

For detailed requirement descriptions, see `.kiro/specs/unit-testing/requirements.md`.
