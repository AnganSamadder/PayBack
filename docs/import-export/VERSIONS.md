# CSV Versioning and Schema

This document describes the CSV export variants and column schemas used by PayBack for data portability and backward compatibility.

## Header Markers

PayBack uses header markers to identify valid export files and determine their structure.

| Marker | Description |
| :--- | :--- |
| `===PAYBACK_EXPORT===` | Standard/Legacy marker. Used for current exports. |
| `===PAYBACK_EXPORT_V1===` | Explicit Version 1 marker (treated identically to legacy). |

The export process concludes with an `===END_PAYBACK_EXPORT===` marker.

## Section Ordering

While the parser is generally resilient to section order, the standard export order is:

1. Metadata (Headers)
2. `[FRIENDS]`
3. `[GROUPS]`
4. `[GROUP_MEMBERS]`
5. `[EXPENSES]`
6. `[EXPENSE_INVOLVED_MEMBERS]`
7. `[EXPENSE_SPLITS]`
8. `[EXPENSE_SUBEXPENSES]`
9. `[PARTICIPANT_NAMES]`

## Column Schemas

Columns prefixed with `#` in the export are headers. The parser relies on index-based access matching these schemas.

### Metadata Headers
- `EXPORTED_AT`: ISO8601 timestamp
- `ACCOUNT_EMAIL`: Source account email
- `CURRENT_USER_ID`: Source user UUID
- `CURRENT_USER_NAME`: Source user name

### [FRIENDS]
| Column | Type | Optional | Default / Note |
| :--- | :--- | :--- | :--- |
| `member_id` | UUID | No | |
| `name` | String | No | |
| `nickname` | String | Yes | Empty string |
| `has_linked_account` | Boolean | No | `false` |
| `linked_account_id` | String | Yes | Empty string |
| `linked_account_email` | String | Yes | Empty string |
| `profile_image_url` | String | Yes | Empty string |
| `profile_avatar_color` | String | Yes | Empty string (Hex code) |
| `status` | String | **Yes** | Defaults to `"friend"` |

### [GROUPS]
| Column | Type | Optional | Default / Note |
| :--- | :--- | :--- | :--- |
| `group_id` | UUID | No | |
| `name` | String | No | |
| `is_direct` | Boolean | No | |
| `is_debug` | Boolean | No | |
| `created_at` | ISO8601 | No | |
| `member_count` | Int | No | |

### [GROUP_MEMBERS]
| Column | Type | Optional | Default / Note |
| :--- | :--- | :--- | :--- |
| `group_id` | UUID | No | |
| `member_id` | UUID | No | |
| `member_name` | String | No | |
| `profile_image_url` | String | Yes | Empty string |
| `profile_avatar_color` | String | Yes | Empty string |

### [EXPENSES]
| Column | Type | Optional | Default / Note |
| :--- | :--- | :--- | :--- |
| `expense_id` | UUID | No | |
| `group_id` | UUID | No | |
| `description` | String | No | |
| `date` | ISO8601 | No | |
| `total_amount` | Decimal | No | |
| `paid_by_member_id` | UUID | No | |
| `is_settled` | Boolean | No | |
| `is_debug` | Boolean | No | |

### [EXPENSE_INVOLVED_MEMBERS]
| Column | Type | Note |
| :--- | :--- | :--- |
| `expense_id` | UUID | |
| `member_id` | UUID | |

### [EXPENSE_SPLITS]
| Column | Type | Note |
| :--- | :--- | :--- |
| `expense_id` | UUID | |
| `split_id` | UUID | |
| `member_id` | UUID | |
| `amount` | Decimal | |
| `is_settled` | Boolean | |

### [EXPENSE_SUBEXPENSES]
| Column | Type | Note |
| :--- | :--- | :--- |
| `expense_id` | UUID | |
| `subexpense_id` | UUID | |
| `amount` | Decimal | |

### [PARTICIPANT_NAMES]
| Column | Type | Note |
| :--- | :--- | :--- |
| `expense_id` | UUID | |
| `member_id` | UUID | |
| `display_name` | String | Cache of member name at time of expense |

## Backward Compatibility Considerations

1. **Missing Columns**: If a row has fewer columns than the current schema (common in older exports), the parser applies defaults (e.g., `status` defaulting to `"friend"`).
2. **Member Mapping**: During import, source `member_id` values are mapped to local UUIDs. The `CURRENT_USER_ID` is mapped to the active local user.
3. **Friend Promotion**: If an imported friend matches an existing contact by name but the existing contact is only a "peer" (found in groups but not in friend list), the import "promotes" them to `"friend"` status.
4. **Resilience**: Sections that are not recognized or are empty are skipped without failing the entire import.
