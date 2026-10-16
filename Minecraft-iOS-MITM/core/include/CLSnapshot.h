#ifndef CL_SNAPSHOT_H
#define CL_SNAPSHOT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define CL_SNAPSHOT_SCHEMA_VERSION 1u
#define CL_SNAPSHOT_MAX_ENTITIES 4096u
#define CL_SNAPSHOT_MAX_ERRORS 128u
#define CL_SNAPSHOT_MAX_LIMITATIONS 64u
#define CL_SNAPSHOT_MAX_IDENTIFIER_LENGTH 128u
#define CL_SNAPSHOT_MAX_LABEL_LENGTH 256u

#define CL_ENTITY_REQUIRED_FIELDS \
    (CL_ENTITY_FIELD_IDENTITY | CL_ENTITY_FIELD_POSITION | CL_ENTITY_FIELD_BOUNDS)

typedef enum {
    CL_SNAPSHOT_SOURCE_UNKNOWN = 0,
    CL_SNAPSHOT_SOURCE_NATIVE_RUNTIME,
    CL_SNAPSHOT_SOURCE_PROTOCOL,
    CL_SNAPSHOT_SOURCE_OFFLINE_METADATA,
    CL_SNAPSHOT_SOURCE_SYNTHETIC
} CLSnapshotSource;

typedef enum {
    CL_SNAPSHOT_DATA_UNKNOWN = 0,
    CL_SNAPSHOT_DATA_LIVE,
    CL_SNAPSHOT_DATA_CACHED,
    CL_SNAPSHOT_DATA_HISTORICAL,
    CL_SNAPSHOT_DATA_OFFLINE,
    CL_SNAPSHOT_DATA_SYNTHETIC,
    CL_SNAPSHOT_DATA_PROTOCOL_DERIVED
} CLSnapshotDataKind;

typedef enum {
    CL_PROVIDER_UNAVAILABLE = 0,
    CL_PROVIDER_PARTIAL,
    CL_PROVIDER_READY,
    CL_PROVIDER_ERROR
} CLProviderStatus;

typedef enum {
    CL_CONFIDENCE_UNKNOWN = 0,
    CL_CONFIDENCE_LOW,
    CL_CONFIDENCE_MEDIUM,
    CL_CONFIDENCE_HIGH
} CLConfidence;

typedef enum {
    CL_CLOCK_UNKNOWN = 0,
    CL_CLOCK_MONOTONIC,
    CL_CLOCK_UNIX_EPOCH
} CLClockDomain;

typedef enum {
    CL_COORDINATE_SPACE_UNKNOWN = 0,
    CL_COORDINATE_SPACE_MINECRAFT_WORLD_BLOCKS,
    CL_COORDINATE_SPACE_PROVIDER_LOCAL
} CLCoordinateSpace;

typedef enum {
    CL_POSITION_ANCHOR_UNKNOWN = 0,
    CL_POSITION_ANCHOR_BOTTOM_CENTER,
    CL_POSITION_ANCHOR_CENTER
} CLPositionAnchor;

typedef enum {
    CL_ANGLE_UNIT_UNKNOWN = 0,
    CL_ANGLE_UNIT_DEGREES,
    CL_ANGLE_UNIT_RADIANS
} CLAngleUnit;

typedef enum {
    CL_SNAPSHOT_STATUS_UNKNOWN = 0,
    CL_SNAPSHOT_STATUS_VALID,
    CL_SNAPSHOT_STATUS_PARTIAL,
    CL_SNAPSHOT_STATUS_INVALID,
    CL_SNAPSHOT_STATUS_STALE,
    CL_SNAPSHOT_STATUS_UNAVAILABLE
} CLSnapshotStatus;

typedef enum {
    CL_ENTITY_VALIDITY_UNKNOWN = 0,
    CL_ENTITY_VALIDITY_UNVERIFIED,
    CL_ENTITY_VALIDITY_VALID,
    CL_ENTITY_VALIDITY_PARTIAL,
    CL_ENTITY_VALIDITY_STALE,
    CL_ENTITY_VALIDITY_REMOVED
} CLEntityValidity;

typedef enum {
    CL_ENTITY_FIELD_NONE = 0,
    CL_ENTITY_FIELD_IDENTITY = 1u << 0,
    CL_ENTITY_FIELD_POSITION = 1u << 1,
    CL_ENTITY_FIELD_BOUNDS = 1u << 2,
    CL_ENTITY_FIELD_RUNTIME_ID = 1u << 3,
    CL_ENTITY_FIELD_DISPLAY_NAME = 1u << 4,
    CL_ENTITY_FIELD_ROTATION = 1u << 5,
    CL_ENTITY_FIELD_VELOCITY = 1u << 6
} CLEntityField;

typedef struct {
    double x;
    double y;
    double z;
} CLVector3;

typedef struct {
    double width;
    double height;
} CLEntityBounds;

typedef enum {
    CL_ERROR_NONE = 0,
    CL_ERROR_PROVIDER_UNAVAILABLE,
    CL_ERROR_PROVIDER_FAILURE,
    CL_ERROR_UNSUPPORTED_BUILD,
    CL_ERROR_UNSUPPORTED_PROTOCOL,
    CL_ERROR_MALFORMED_INPUT,
    CL_ERROR_CLOCK_UNAVAILABLE,
    CL_ERROR_INCOMPLETE_RECORD,
    CL_ERROR_STALE_DATA,
    CL_ERROR_ENTITY_REMOVED,
    CL_ERROR_UNKNOWN
} CLSnapshotErrorCode;

typedef enum {
    CL_ERROR_SEVERITY_INFO = 0,
    CL_ERROR_SEVERITY_WARNING,
    CL_ERROR_SEVERITY_ERROR
} CLSnapshotErrorSeverity;

typedef struct {
    CLSnapshotErrorCode code;
    CLSnapshotErrorSeverity severity;
    size_t entity_index;
    const char *message;
} CLSnapshotError;

typedef struct {
    uint32_t fields;
    const char *entity_id;
    const char *runtime_id;
    const char *type_id;
    const char *display_name;
    CLVector3 position;
    CLEntityBounds bounds;
    CLVector3 rotation;
    CLVector3 velocity;
    CLEntityValidity validity;
    CLConfidence confidence;
} CLEntityRecord;

typedef struct {
    uint32_t schema_version;
    const char *snapshot_id;
    const char *provider_id;
    const char *provider_version;
    const char *minecraft_version;
    const char *minecraft_build;
    const char *protocol_version;
    CLSnapshotSource source;
    CLSnapshotDataKind data_kind;
    CLProviderStatus provider_status;
    CLSnapshotStatus status;
    CLConfidence confidence;
    CLClockDomain clock_domain;
    CLCoordinateSpace coordinate_space;
    CLPositionAnchor position_anchor;
    CLAngleUnit rotation_unit;
    uint32_t available_fields;
    uint64_t captured_at_ms;
    uint64_t observed_at_ms;
    uint64_t max_age_ms;
    const CLEntityRecord *entities;
    size_t entity_count;
    const CLSnapshotError *errors;
    size_t error_count;
    const char *const *limitations;
    size_t limitation_count;
} CLSnapshot;

typedef enum {
    CL_SNAPSHOT_VALIDATION_VALID = 0,
    CL_SNAPSHOT_VALIDATION_PARTIAL,
    CL_SNAPSHOT_VALIDATION_INVALID,
    CL_SNAPSHOT_VALIDATION_STALE,
    CL_SNAPSHOT_VALIDATION_SYNTHETIC_DISABLED,
    CL_SNAPSHOT_VALIDATION_UNAVAILABLE
} CLSnapshotValidationStatus;

typedef enum {
    CL_VALIDATE_ERROR_NONE = 0,
    CL_VALIDATE_ERROR_MISSING_REQUIRED_VALUE,
    CL_VALIDATE_ERROR_SCHEMA_VERSION,
    CL_VALIDATE_ERROR_SOURCE,
    CL_VALIDATE_ERROR_DATA_KIND,
    CL_VALIDATE_ERROR_PROVIDER_STATUS,
    CL_VALIDATE_ERROR_PROVIDER_UNAVAILABLE,
    CL_VALIDATE_ERROR_PROVIDER_FAILURE,
    CL_VALIDATE_ERROR_SNAPSHOT_STATUS,
    CL_VALIDATE_ERROR_FUTURE_TIMESTAMP,
    CL_VALIDATE_ERROR_STALE,
    CL_VALIDATE_ERROR_ENTITY_LIMIT,
    CL_VALIDATE_ERROR_ERROR_LIMIT,
    CL_VALIDATE_ERROR_LIMITATION_LIMIT,
    CL_VALIDATE_ERROR_MISSING_ENTITY_ARRAY,
    CL_VALIDATE_ERROR_MISSING_ERROR_ARRAY,
    CL_VALIDATE_ERROR_MISSING_LIMITATION_ARRAY,
    CL_VALIDATE_ERROR_UNKNOWN_FIELD,
    CL_VALIDATE_ERROR_INVALID_IDENTITY,
    CL_VALIDATE_ERROR_DUPLICATE_ENTITY_ID,
    CL_VALIDATE_ERROR_NONFINITE_POSITION,
    CL_VALIDATE_ERROR_INVALID_BOUNDS,
    CL_VALIDATE_ERROR_NONFINITE_ROTATION,
    CL_VALIDATE_ERROR_NONFINITE_VELOCITY,
    CL_VALIDATE_ERROR_INVALID_VALIDITY,
    CL_VALIDATE_ERROR_INVALID_CONFIDENCE,
    CL_VALIDATE_ERROR_INVALID_ERROR_RECORD,
    CL_VALIDATE_ERROR_OUT_OF_MEMORY
} CLSnapshotValidationError;

typedef struct {
    CLSnapshotValidationStatus status;
    CLSnapshotValidationError error;
    size_t entity_index;
    size_t renderable_entity_count;
    size_t valid_error_count;
    uint32_t available_fields;
    uint64_t age_ms;
} CLSnapshotValidation;

CLSnapshotValidation CLValidateSnapshot(
    const CLSnapshot *snapshot,
    uint64_t now_ms,
    uint64_t allowed_future_skew_ms,
    bool allow_synthetic);

#endif
