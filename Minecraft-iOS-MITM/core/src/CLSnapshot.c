#include "CLSnapshot.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define CL_KNOWN_ENTITY_FIELDS \
    (CL_ENTITY_FIELD_IDENTITY | CL_ENTITY_FIELD_POSITION | \
     CL_ENTITY_FIELD_BOUNDS | CL_ENTITY_FIELD_RUNTIME_ID | \
     CL_ENTITY_FIELD_DISPLAY_NAME | CL_ENTITY_FIELD_ROTATION | \
     CL_ENTITY_FIELD_VELOCITY)

static CLSnapshotValidation CLResult(CLSnapshotValidationStatus status,
                                     CLSnapshotValidationError error,
                                     size_t entity_index,
                                     size_t renderable_count,
                                     size_t valid_error_count,
                                     uint32_t available_fields,
                                     uint64_t age_ms) {
    CLSnapshotValidation result = {
        .status = status,
        .error = error,
        .entity_index = entity_index,
        .renderable_entity_count = renderable_count,
        .valid_error_count = valid_error_count,
        .available_fields = available_fields,
        .age_ms = age_ms
    };
    return result;
}

static bool CLHasText(const char *value) {
    return value != NULL && value[0] != '\0';
}

static size_t CLBoundedLength(const char *value, size_t limit) {
    size_t length = 0;
    while (length < limit && value[length] != '\0') {
        length++;
    }
    return length;
}

static bool CLStringIsValid(const char *value, size_t max_length) {
    return CLHasText(value) && CLBoundedLength(value, max_length + 1u) <= max_length;
}

static bool CLIdentifierIsValid(const char *value) {
    return CLStringIsValid(value, CL_SNAPSHOT_MAX_IDENTIFIER_LENGTH);
}

static bool CLConfidenceIsValid(CLConfidence confidence) {
    return confidence >= CL_CONFIDENCE_UNKNOWN &&
        confidence <= CL_CONFIDENCE_HIGH;
}

static bool CLOptionalStringIsValid(const char *value, size_t max_length) {
    return value == NULL ||
        CLBoundedLength(value, max_length + 1u) <= max_length;
}

static bool CLVectorIsFinite(CLVector3 vector) {
    return isfinite(vector.x) && isfinite(vector.y) && isfinite(vector.z);
}

static int CLCompareEntityIDs(const void *left, const void *right) {
    const char *const *left_id = left;
    const char *const *right_id = right;
    return strcmp(*left_id, *right_id);
}

static bool CLIsLiveDataKind(CLSnapshotDataKind kind) {
    return kind == CL_SNAPSHOT_DATA_LIVE ||
        kind == CL_SNAPSHOT_DATA_CACHED ||
        kind == CL_SNAPSHOT_DATA_PROTOCOL_DERIVED;
}

static bool CLSourceMatchesDataKind(CLSnapshotSource source,
                                    CLSnapshotDataKind kind) {
    if ((source == CL_SNAPSHOT_SOURCE_SYNTHETIC) !=
        (kind == CL_SNAPSHOT_DATA_SYNTHETIC)) {
        return false;
    }
    switch (source) {
        case CL_SNAPSHOT_SOURCE_NATIVE_RUNTIME:
            return kind == CL_SNAPSHOT_DATA_LIVE ||
                kind == CL_SNAPSHOT_DATA_CACHED ||
                kind == CL_SNAPSHOT_DATA_HISTORICAL;
        case CL_SNAPSHOT_SOURCE_PROTOCOL:
            return kind == CL_SNAPSHOT_DATA_PROTOCOL_DERIVED ||
                kind == CL_SNAPSHOT_DATA_CACHED ||
                kind == CL_SNAPSHOT_DATA_HISTORICAL;
        case CL_SNAPSHOT_SOURCE_OFFLINE_METADATA:
            return kind == CL_SNAPSHOT_DATA_OFFLINE ||
                kind == CL_SNAPSHOT_DATA_HISTORICAL;
        case CL_SNAPSHOT_SOURCE_SYNTHETIC:
            return kind == CL_SNAPSHOT_DATA_SYNTHETIC;
        case CL_SNAPSHOT_SOURCE_UNKNOWN:
            return false;
    }
    return false;
}

static bool CLIsOverlaySource(CLSnapshotSource source,
                              CLSnapshotDataKind data_kind,
                              CLCoordinateSpace coordinate_space,
                              CLPositionAnchor position_anchor,
                              bool allow_synthetic) {
    if (coordinate_space != CL_COORDINATE_SPACE_MINECRAFT_WORLD_BLOCKS) {
        return false;
    }
    if (position_anchor == CL_POSITION_ANCHOR_UNKNOWN) {
        return false;
    }
    if (source == CL_SNAPSHOT_SOURCE_SYNTHETIC) {
        return allow_synthetic && data_kind == CL_SNAPSHOT_DATA_SYNTHETIC;
    }
    if (!CLIsLiveDataKind(data_kind)) {
        return false;
    }
    return source == CL_SNAPSHOT_SOURCE_NATIVE_RUNTIME ||
        source == CL_SNAPSHOT_SOURCE_PROTOCOL;
}

static bool CLIsValidErrorRecord(const CLSnapshotError *error,
                                size_t entity_count) {
    if (error->code <= CL_ERROR_NONE || error->code > CL_ERROR_UNKNOWN ||
        error->severity < CL_ERROR_SEVERITY_INFO ||
        error->severity > CL_ERROR_SEVERITY_ERROR) {
        return false;
    }
    if (error->entity_index != SIZE_MAX && error->entity_index >= entity_count) {
        return false;
    }
    return error->message == NULL ||
        CLBoundedLength(error->message, CL_SNAPSHOT_MAX_LABEL_LENGTH + 1u) <=
            CL_SNAPSHOT_MAX_LABEL_LENGTH;
}

CLSnapshotValidation CLValidateSnapshot(const CLSnapshot *snapshot,
                                        uint64_t now_ms,
                                        uint64_t allowed_future_skew_ms,
                                        bool allow_synthetic) {
    if (snapshot == NULL) {
        return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                        CL_VALIDATE_ERROR_MISSING_REQUIRED_VALUE,
                        0, 0, 0, 0, 0);
    }
    if (snapshot->status <= CL_SNAPSHOT_STATUS_UNKNOWN ||
        snapshot->status > CL_SNAPSHOT_STATUS_UNAVAILABLE) {
        return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                        CL_VALIDATE_ERROR_SNAPSHOT_STATUS, 0, 0, 0, 0, 0);
    }
    if (snapshot->provider_status < CL_PROVIDER_UNAVAILABLE ||
        snapshot->provider_status > CL_PROVIDER_ERROR) {
        return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                        CL_VALIDATE_ERROR_PROVIDER_STATUS, 0, 0, 0, 0, 0);
    }
    if (snapshot->provider_status == CL_PROVIDER_ERROR) {
        return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                        CL_VALIDATE_ERROR_PROVIDER_FAILURE, 0, 0, 0, 0, 0);
    }
    if (snapshot->status == CL_SNAPSHOT_STATUS_UNAVAILABLE ||
        snapshot->provider_status == CL_PROVIDER_UNAVAILABLE) {
        return CLResult(CL_SNAPSHOT_VALIDATION_UNAVAILABLE,
                        CL_VALIDATE_ERROR_PROVIDER_UNAVAILABLE,
                        0, 0, 0, 0, 0);
    }
    if (!CLStringIsValid(snapshot->snapshot_id,
                         CL_SNAPSHOT_MAX_IDENTIFIER_LENGTH) ||
        !CLStringIsValid(snapshot->provider_id,
                         CL_SNAPSHOT_MAX_IDENTIFIER_LENGTH)) {
        return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                        CL_VALIDATE_ERROR_MISSING_REQUIRED_VALUE,
                        0, 0, 0, 0, 0);
    }
    if (snapshot->schema_version != CL_SNAPSHOT_SCHEMA_VERSION) {
        return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                        CL_VALIDATE_ERROR_SCHEMA_VERSION,
                        0, 0, 0, 0, 0);
    }
    if (snapshot->source <= CL_SNAPSHOT_SOURCE_UNKNOWN ||
        snapshot->source > CL_SNAPSHOT_SOURCE_SYNTHETIC) {
        return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                        CL_VALIDATE_ERROR_SOURCE, 0, 0, 0, 0, 0);
    }
    if (snapshot->data_kind <= CL_SNAPSHOT_DATA_UNKNOWN ||
        snapshot->data_kind > CL_SNAPSHOT_DATA_PROTOCOL_DERIVED) {
        return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                        CL_VALIDATE_ERROR_DATA_KIND, 0, 0, 0, 0, 0);
    }
    if (!CLSourceMatchesDataKind(snapshot->source, snapshot->data_kind)) {
        return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                        CL_VALIDATE_ERROR_DATA_KIND, 0, 0, 0, 0, 0);
    }
    if (!CLConfidenceIsValid(snapshot->confidence)) {
        return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                        CL_VALIDATE_ERROR_INVALID_CONFIDENCE,
                        0, 0, 0, 0, 0);
    }
    if (snapshot->clock_domain <= CL_CLOCK_UNKNOWN ||
        snapshot->clock_domain > CL_CLOCK_UNIX_EPOCH) {
        return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                        CL_VALIDATE_ERROR_MISSING_REQUIRED_VALUE,
                        0, 0, 0, 0, 0);
    }
    if (snapshot->coordinate_space < CL_COORDINATE_SPACE_UNKNOWN ||
        snapshot->coordinate_space > CL_COORDINATE_SPACE_PROVIDER_LOCAL ||
        snapshot->position_anchor < CL_POSITION_ANCHOR_UNKNOWN ||
        snapshot->position_anchor > CL_POSITION_ANCHOR_CENTER ||
        snapshot->rotation_unit < CL_ANGLE_UNIT_UNKNOWN ||
        snapshot->rotation_unit > CL_ANGLE_UNIT_RADIANS) {
        return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                        CL_VALIDATE_ERROR_MISSING_REQUIRED_VALUE,
                        0, 0, 0, 0, 0);
    }
    if (!CLOptionalStringIsValid(snapshot->provider_version,
                                 CL_SNAPSHOT_MAX_IDENTIFIER_LENGTH) ||
        !CLOptionalStringIsValid(snapshot->minecraft_version,
                                 CL_SNAPSHOT_MAX_IDENTIFIER_LENGTH) ||
        !CLOptionalStringIsValid(snapshot->minecraft_build,
                                 CL_SNAPSHOT_MAX_IDENTIFIER_LENGTH) ||
        !CLOptionalStringIsValid(snapshot->protocol_version,
                                 CL_SNAPSHOT_MAX_IDENTIFIER_LENGTH)) {
        return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                        CL_VALIDATE_ERROR_MISSING_REQUIRED_VALUE,
                        0, 0, 0, 0, 0);
    }
    if (snapshot->limitation_count > CL_SNAPSHOT_MAX_LIMITATIONS) {
        return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                        CL_VALIDATE_ERROR_LIMITATION_LIMIT,
                        0, 0, 0, snapshot->available_fields, 0);
    }
    if (snapshot->limitation_count > 0 && snapshot->limitations == NULL) {
        return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                        CL_VALIDATE_ERROR_MISSING_LIMITATION_ARRAY,
                        0, 0, 0, snapshot->available_fields, 0);
    }
    for (size_t index = 0; index < snapshot->limitation_count; index++) {
        if (snapshot->limitations[index] == NULL ||
            CLBoundedLength(snapshot->limitations[index],
                            CL_SNAPSHOT_MAX_LABEL_LENGTH + 1u) >
                CL_SNAPSHOT_MAX_LABEL_LENGTH) {
            return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                            CL_VALIDATE_ERROR_MISSING_REQUIRED_VALUE,
                            index, 0, 0, snapshot->available_fields, 0);
        }
    }
    if ((snapshot->available_fields & ~CL_KNOWN_ENTITY_FIELDS) != 0) {
        return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                        CL_VALIDATE_ERROR_UNKNOWN_FIELD,
                        0, 0, 0, snapshot->available_fields, 0);
    }
    if (snapshot->entity_count > CL_SNAPSHOT_MAX_ENTITIES) {
        return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                        CL_VALIDATE_ERROR_ENTITY_LIMIT,
                        0, 0, 0, snapshot->available_fields, 0);
    }
    if (snapshot->error_count > CL_SNAPSHOT_MAX_ERRORS) {
        return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                        CL_VALIDATE_ERROR_ERROR_LIMIT,
                        0, 0, 0, snapshot->available_fields, 0);
    }
    if (snapshot->entity_count > 0 && snapshot->entities == NULL) {
        return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                        CL_VALIDATE_ERROR_MISSING_ENTITY_ARRAY,
                        0, 0, 0, snapshot->available_fields, 0);
    }
    if (snapshot->error_count > 0 && snapshot->errors == NULL) {
        return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                        CL_VALIDATE_ERROR_MISSING_ERROR_ARRAY,
                        0, 0, 0, snapshot->available_fields, 0);
    }

    if (snapshot->captured_at_ms > now_ms &&
        snapshot->captured_at_ms - now_ms > allowed_future_skew_ms) {
        return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                        CL_VALIDATE_ERROR_FUTURE_TIMESTAMP,
                        0, 0, 0, snapshot->available_fields, 0);
    }
    if (snapshot->observed_at_ms > now_ms &&
        snapshot->observed_at_ms - now_ms > allowed_future_skew_ms) {
        return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                        CL_VALIDATE_ERROR_FUTURE_TIMESTAMP,
                        0, 0, 0, snapshot->available_fields, 0);
    }

    const uint64_t age_ms = snapshot->captured_at_ms > now_ms
        ? 0
        : now_ms - snapshot->captured_at_ms;
    if (snapshot->max_age_ms > 0 && age_ms > snapshot->max_age_ms) {
        return CLResult(CL_SNAPSHOT_VALIDATION_STALE,
                        CL_VALIDATE_ERROR_STALE,
                        0, 0, 0, snapshot->available_fields, age_ms);
    }
    if (snapshot->status == CL_SNAPSHOT_STATUS_STALE) {
        return CLResult(CL_SNAPSHOT_VALIDATION_STALE,
                        CL_VALIDATE_ERROR_STALE,
                        0, 0, 0, snapshot->available_fields, age_ms);
    }
    if (snapshot->status == CL_SNAPSHOT_STATUS_INVALID) {
        return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                        CL_VALIDATE_ERROR_SNAPSHOT_STATUS,
                        0, 0, 0, snapshot->available_fields, age_ms);
    }
    if (snapshot->source == CL_SNAPSHOT_SOURCE_SYNTHETIC &&
        (!allow_synthetic || snapshot->data_kind != CL_SNAPSHOT_DATA_SYNTHETIC)) {
        return CLResult(CL_SNAPSHOT_VALIDATION_SYNTHETIC_DISABLED,
                        CL_VALIDATE_ERROR_NONE,
                        0, 0, 0, snapshot->available_fields, age_ms);
    }

    bool partial = snapshot->status == CL_SNAPSHOT_STATUS_PARTIAL ||
        snapshot->provider_status == CL_PROVIDER_PARTIAL ||
        snapshot->confidence == CL_CONFIDENCE_UNKNOWN ||
        (snapshot->entity_count > 0 &&
         (snapshot->coordinate_space !=
              CL_COORDINATE_SPACE_MINECRAFT_WORLD_BLOCKS ||
          snapshot->position_anchor == CL_POSITION_ANCHOR_UNKNOWN));
    size_t renderable_count = 0;
    size_t valid_error_count = 0;
    size_t identity_count = 0;
    const char **entity_ids = snapshot->entity_count == 0
        ? NULL
        : malloc(snapshot->entity_count * sizeof(*entity_ids));
    if (snapshot->entity_count > 0 && entity_ids == NULL) {
        return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                        CL_VALIDATE_ERROR_OUT_OF_MEMORY,
                        0, 0, 0, snapshot->available_fields, age_ms);
    }

    for (size_t index = 0; index < snapshot->error_count; index++) {
        if (!CLIsValidErrorRecord(&snapshot->errors[index],
                                  snapshot->entity_count)) {
            free(entity_ids);
            return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                            CL_VALIDATE_ERROR_INVALID_ERROR_RECORD,
                            snapshot->errors[index].entity_index,
                            0, valid_error_count,
                            snapshot->available_fields, age_ms);
        }
        valid_error_count++;
        if (snapshot->errors[index].severity == CL_ERROR_SEVERITY_ERROR) {
            partial = true;
        }
    }

    const bool overlay_source = CLIsOverlaySource(
        snapshot->source, snapshot->data_kind, snapshot->coordinate_space,
        snapshot->position_anchor,
        allow_synthetic);
    for (size_t index = 0; index < snapshot->entity_count; index++) {
        const CLEntityRecord *entity = &snapshot->entities[index];
        if ((entity->fields & ~CL_KNOWN_ENTITY_FIELDS) != 0 ||
            (entity->fields & ~snapshot->available_fields) != 0) {
            free(entity_ids);
            return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                            CL_VALIDATE_ERROR_UNKNOWN_FIELD,
                            index, 0, valid_error_count,
                            snapshot->available_fields, age_ms);
        }
        if (!CLConfidenceIsValid(entity->confidence)) {
            free(entity_ids);
            return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                            CL_VALIDATE_ERROR_INVALID_CONFIDENCE,
                            index, 0, valid_error_count,
                            snapshot->available_fields, age_ms);
        }
        if (entity->validity < CL_ENTITY_VALIDITY_UNKNOWN ||
            entity->validity > CL_ENTITY_VALIDITY_REMOVED) {
            free(entity_ids);
            return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                            CL_VALIDATE_ERROR_INVALID_VALIDITY,
                            index, 0, valid_error_count,
                            snapshot->available_fields, age_ms);
        }

        if ((entity->fields & CL_ENTITY_FIELD_IDENTITY) != 0) {
            if (!CLIdentifierIsValid(entity->entity_id) ||
                !CLIdentifierIsValid(entity->type_id)) {
                free(entity_ids);
                return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                                CL_VALIDATE_ERROR_INVALID_IDENTITY,
                                index, 0, valid_error_count,
                                snapshot->available_fields, age_ms);
            }
            entity_ids[identity_count++] = entity->entity_id;
        } else {
            partial = true;
        }
        if ((entity->fields & CL_ENTITY_FIELD_RUNTIME_ID) != 0 &&
            !CLIdentifierIsValid(entity->runtime_id)) {
            free(entity_ids);
            return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                            CL_VALIDATE_ERROR_INVALID_IDENTITY,
                            index, 0, valid_error_count,
                            snapshot->available_fields, age_ms);
        }
        if ((entity->fields & CL_ENTITY_FIELD_DISPLAY_NAME) != 0 &&
            (!CLHasText(entity->display_name) ||
             CLBoundedLength(entity->display_name,
                             CL_SNAPSHOT_MAX_LABEL_LENGTH + 1u) >
                 CL_SNAPSHOT_MAX_LABEL_LENGTH)) {
            free(entity_ids);
            return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                            CL_VALIDATE_ERROR_INVALID_IDENTITY,
                            index, 0, valid_error_count,
                            snapshot->available_fields, age_ms);
        }

        if ((entity->fields & CL_ENTITY_FIELD_POSITION) != 0) {
            if (!CLVectorIsFinite(entity->position)) {
                free(entity_ids);
                return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                                CL_VALIDATE_ERROR_NONFINITE_POSITION,
                                index, 0, valid_error_count,
                                snapshot->available_fields, age_ms);
            }
        } else {
            partial = true;
        }
        if ((entity->fields & CL_ENTITY_FIELD_BOUNDS) != 0) {
            if (!isfinite(entity->bounds.width) ||
                !isfinite(entity->bounds.height) ||
                entity->bounds.width <= 0 || entity->bounds.height <= 0) {
                free(entity_ids);
                return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                                CL_VALIDATE_ERROR_INVALID_BOUNDS,
                                index, 0, valid_error_count,
                                snapshot->available_fields, age_ms);
            }
        } else {
            partial = true;
        }
        if ((entity->fields & CL_ENTITY_FIELD_ROTATION) != 0 &&
            !CLVectorIsFinite(entity->rotation)) {
            free(entity_ids);
            return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                            CL_VALIDATE_ERROR_NONFINITE_ROTATION,
                            index, 0, valid_error_count,
                            snapshot->available_fields, age_ms);
        }
        if ((entity->fields & CL_ENTITY_FIELD_ROTATION) != 0 &&
            snapshot->rotation_unit == CL_ANGLE_UNIT_UNKNOWN) {
            partial = true;
        }
        if ((entity->fields & CL_ENTITY_FIELD_VELOCITY) != 0 &&
            !CLVectorIsFinite(entity->velocity)) {
            free(entity_ids);
            return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                            CL_VALIDATE_ERROR_NONFINITE_VELOCITY,
                            index, 0, valid_error_count,
                            snapshot->available_fields, age_ms);
        }
        if (entity->validity != CL_ENTITY_VALIDITY_VALID ||
            entity->confidence == CL_CONFIDENCE_UNKNOWN) {
            partial = true;
        }

        if (overlay_source &&
            (entity->fields & CL_ENTITY_REQUIRED_FIELDS) ==
                CL_ENTITY_REQUIRED_FIELDS &&
            entity->validity == CL_ENTITY_VALIDITY_VALID &&
            entity->confidence != CL_CONFIDENCE_UNKNOWN) {
            renderable_count++;
        }
    }

    if (identity_count > 1) {
        qsort(entity_ids, identity_count, sizeof(*entity_ids),
              CLCompareEntityIDs);
        for (size_t index = 1; index < identity_count; index++) {
            if (strcmp(entity_ids[index - 1], entity_ids[index]) == 0) {
                free(entity_ids);
                return CLResult(CL_SNAPSHOT_VALIDATION_INVALID,
                                CL_VALIDATE_ERROR_DUPLICATE_ENTITY_ID,
                                index, 0, valid_error_count,
                                snapshot->available_fields, age_ms);
            }
        }
    }
    free(entity_ids);

    return CLResult(partial ? CL_SNAPSHOT_VALIDATION_PARTIAL
                            : CL_SNAPSHOT_VALIDATION_VALID,
                    CL_VALIDATE_ERROR_NONE,
                    0, renderable_count, valid_error_count,
                    snapshot->available_fields, age_ms);
}
