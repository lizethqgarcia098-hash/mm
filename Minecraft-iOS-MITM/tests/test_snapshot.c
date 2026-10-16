#include "CLSnapshot.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>

#define COMPLETE_FIELDS \
    (CL_ENTITY_REQUIRED_FIELDS | CL_ENTITY_FIELD_RUNTIME_ID | \
     CL_ENTITY_FIELD_DISPLAY_NAME | CL_ENTITY_FIELD_ROTATION | \
     CL_ENTITY_FIELD_VELOCITY)

static const CLEntityRecord complete_entity = {
    .fields = COMPLETE_FIELDS,
    .entity_id = "entity-42",
    .runtime_id = "runtime-42",
    .type_id = "minecraft:cow",
    .display_name = "Cow",
    .position = {12.5, 64.0, -3.25},
    .bounds = {0.9, 1.3},
    .rotation = {0, 90, 0},
    .velocity = {0.1, 0, -0.2},
    .validity = CL_ENTITY_VALIDITY_VALID,
    .confidence = CL_CONFIDENCE_HIGH
};

static CLSnapshot snapshot_with(const CLEntityRecord *entities,
                                size_t entity_count,
                                CLSnapshotSource source,
                                CLSnapshotDataKind data_kind,
                                uint64_t timestamp_ms) {
    return (CLSnapshot) {
        .schema_version = CL_SNAPSHOT_SCHEMA_VERSION,
        .snapshot_id = "snapshot-1",
        .provider_id = "test-provider",
        .provider_version = "test-1",
        .minecraft_version = NULL,
        .minecraft_build = NULL,
        .protocol_version = NULL,
        .source = source,
        .data_kind = data_kind,
        .provider_status = CL_PROVIDER_READY,
        .status = CL_SNAPSHOT_STATUS_VALID,
        .confidence = CL_CONFIDENCE_HIGH,
        .clock_domain = CL_CLOCK_MONOTONIC,
        .coordinate_space = CL_COORDINATE_SPACE_MINECRAFT_WORLD_BLOCKS,
        .position_anchor = CL_POSITION_ANCHOR_BOTTOM_CENTER,
        .rotation_unit = CL_ANGLE_UNIT_DEGREES,
        .available_fields = COMPLETE_FIELDS,
        .captured_at_ms = timestamp_ms,
        .observed_at_ms = timestamp_ms,
        .max_age_ms = 500,
        .entities = entities,
        .entity_count = entity_count,
        .errors = NULL,
        .error_count = 0,
        .limitations = NULL,
        .limitation_count = 0
    };
}

static void test_full_native_snapshot_is_eligible(void) {
    const CLSnapshot snapshot = snapshot_with(
        &complete_entity, 1, CL_SNAPSHOT_SOURCE_NATIVE_RUNTIME,
        CL_SNAPSHOT_DATA_LIVE, 1000);
    const CLSnapshotValidation result =
        CLValidateSnapshot(&snapshot, 1100, 50, false);
    assert(result.status == CL_SNAPSHOT_VALIDATION_VALID);
    assert(result.error == CL_VALIDATE_ERROR_NONE);
    assert(result.renderable_entity_count == 1);
    assert(result.valid_error_count == 0);
    assert(result.available_fields == COMPLETE_FIELDS);
    assert(result.age_ms == 100);
}

static void test_full_protocol_snapshot_is_eligible_when_fresh(void) {
    const CLSnapshot snapshot = snapshot_with(
        &complete_entity, 1, CL_SNAPSHOT_SOURCE_PROTOCOL,
        CL_SNAPSHOT_DATA_PROTOCOL_DERIVED, 1000);
    const CLSnapshotValidation result =
        CLValidateSnapshot(&snapshot, 1100, 50, false);
    assert(result.status == CL_SNAPSHOT_VALIDATION_VALID);
    assert(result.renderable_entity_count == 1);
}

static void test_partial_record_and_unknown_optional_fields_are_not_rendered(void) {
    CLEntityRecord partial = complete_entity;
    partial.fields = CL_ENTITY_FIELD_POSITION | CL_ENTITY_FIELD_BOUNDS;
    const CLSnapshot snapshot = snapshot_with(
        &partial, 1, CL_SNAPSHOT_SOURCE_NATIVE_RUNTIME,
        CL_SNAPSHOT_DATA_LIVE, 1000);
    const CLSnapshotValidation result =
        CLValidateSnapshot(&snapshot, 1100, 50, false);
    assert(result.status == CL_SNAPSHOT_VALIDATION_PARTIAL);
    assert(result.renderable_entity_count == 0);
}

static void test_unverified_record_is_not_rendered(void) {
    CLEntityRecord entity = complete_entity;
    entity.validity = CL_ENTITY_VALIDITY_UNVERIFIED;
    const CLSnapshot snapshot = snapshot_with(
        &entity, 1, CL_SNAPSHOT_SOURCE_NATIVE_RUNTIME,
        CL_SNAPSHOT_DATA_LIVE, 1000);
    const CLSnapshotValidation result =
        CLValidateSnapshot(&snapshot, 1100, 50, false);
    assert(result.status == CL_SNAPSHOT_VALIDATION_PARTIAL);
    assert(result.renderable_entity_count == 0);
}

static void test_partial_snapshot_can_contain_individually_valid_record(void) {
    CLSnapshot snapshot = snapshot_with(
        &complete_entity, 1, CL_SNAPSHOT_SOURCE_NATIVE_RUNTIME,
        CL_SNAPSHOT_DATA_LIVE, 1000);
    snapshot.status = CL_SNAPSHOT_STATUS_PARTIAL;
    snapshot.provider_status = CL_PROVIDER_PARTIAL;
    const CLSnapshotValidation result =
        CLValidateSnapshot(&snapshot, 1100, 50, false);
    assert(result.status == CL_SNAPSHOT_VALIDATION_PARTIAL);
    assert(result.renderable_entity_count == 1);
}

static void test_synthetic_source_requires_explicit_opt_in(void) {
    const CLSnapshot snapshot = snapshot_with(
        &complete_entity, 1, CL_SNAPSHOT_SOURCE_SYNTHETIC,
        CL_SNAPSHOT_DATA_SYNTHETIC, 1000);
    const CLSnapshotValidation disabled =
        CLValidateSnapshot(&snapshot, 1100, 50, false);
    assert(disabled.status == CL_SNAPSHOT_VALIDATION_SYNTHETIC_DISABLED);
    assert(disabled.renderable_entity_count == 0);

    const CLSnapshotValidation enabled =
        CLValidateSnapshot(&snapshot, 1100, 50, true);
    assert(enabled.status == CL_SNAPSHOT_VALIDATION_VALID);
    assert(enabled.renderable_entity_count == 1);
}

static void test_offline_and_historical_data_are_never_rendered(void) {
    CLSnapshot snapshot = snapshot_with(
        &complete_entity, 1, CL_SNAPSHOT_SOURCE_OFFLINE_METADATA,
        CL_SNAPSHOT_DATA_OFFLINE, 1000);
    CLSnapshotValidation result =
        CLValidateSnapshot(&snapshot, 1100, 50, false);
    assert(result.status == CL_SNAPSHOT_VALIDATION_VALID);
    assert(result.renderable_entity_count == 0);

    snapshot = snapshot_with(
        &complete_entity, 1, CL_SNAPSHOT_SOURCE_NATIVE_RUNTIME,
        CL_SNAPSHOT_DATA_HISTORICAL, 1000);
    result = CLValidateSnapshot(&snapshot, 1100, 50, false);
    assert(result.status == CL_SNAPSHOT_VALIDATION_VALID);
    assert(result.renderable_entity_count == 0);

    snapshot = snapshot_with(
        &complete_entity, 1, CL_SNAPSHOT_SOURCE_OFFLINE_METADATA,
        CL_SNAPSHOT_DATA_LIVE, 1000);
    result = CLValidateSnapshot(&snapshot, 1100, 50, false);
    assert(result.status == CL_SNAPSHOT_VALIDATION_INVALID);
    assert(result.error == CL_VALIDATE_ERROR_DATA_KIND);
}

static void test_fresh_cached_data_may_be_eligible(void) {
    const CLSnapshot snapshot = snapshot_with(
        &complete_entity, 1, CL_SNAPSHOT_SOURCE_NATIVE_RUNTIME,
        CL_SNAPSHOT_DATA_CACHED, 1000);
    const CLSnapshotValidation result =
        CLValidateSnapshot(&snapshot, 1100, 50, false);
    assert(result.status == CL_SNAPSHOT_VALIDATION_VALID);
    assert(result.renderable_entity_count == 1);
}

static void test_stale_age_and_explicit_stale_status_are_rejected(void) {
    CLSnapshot snapshot = snapshot_with(
        &complete_entity, 1, CL_SNAPSHOT_SOURCE_PROTOCOL,
        CL_SNAPSHOT_DATA_PROTOCOL_DERIVED, 1000);
    CLSnapshotValidation result =
        CLValidateSnapshot(&snapshot, 1501, 50, false);
    assert(result.status == CL_SNAPSHOT_VALIDATION_STALE);
    assert(result.error == CL_VALIDATE_ERROR_STALE);
    assert(result.age_ms == 501);

    snapshot.max_age_ms = 0;
    snapshot.status = CL_SNAPSHOT_STATUS_STALE;
    result = CLValidateSnapshot(&snapshot, 1100, 50, false);
    assert(result.status == CL_SNAPSHOT_VALIDATION_STALE);
}

static void test_capture_and_observed_future_timestamps_are_bounded(void) {
    CLSnapshot snapshot = snapshot_with(
        &complete_entity, 1, CL_SNAPSHOT_SOURCE_PROTOCOL,
        CL_SNAPSHOT_DATA_PROTOCOL_DERIVED, 1100);
    CLSnapshotValidation result =
        CLValidateSnapshot(&snapshot, 1100, 0, false);
    assert(result.status == CL_SNAPSHOT_VALIDATION_VALID);

    snapshot.captured_at_ms = 1200;
    snapshot.observed_at_ms = 1200;
    result = CLValidateSnapshot(&snapshot, 1100, 99, false);
    assert(result.status == CL_SNAPSHOT_VALIDATION_INVALID);
    assert(result.error == CL_VALIDATE_ERROR_FUTURE_TIMESTAMP);

    snapshot.captured_at_ms = 1100;
    snapshot.observed_at_ms = 1200;
    result = CLValidateSnapshot(&snapshot, 1100, 99, false);
    assert(result.status == CL_SNAPSHOT_VALIDATION_INVALID);
    assert(result.error == CL_VALIDATE_ERROR_FUTURE_TIMESTAMP);
}

static void test_duplicate_entity_identity_is_rejected(void) {
    const CLEntityRecord entities[2] = {complete_entity, complete_entity};
    const CLSnapshot snapshot = snapshot_with(
        entities, 2, CL_SNAPSHOT_SOURCE_NATIVE_RUNTIME,
        CL_SNAPSHOT_DATA_LIVE, 1000);
    const CLSnapshotValidation result =
        CLValidateSnapshot(&snapshot, 1100, 50, false);
    assert(result.status == CL_SNAPSHOT_VALIDATION_INVALID);
    assert(result.error == CL_VALIDATE_ERROR_DUPLICATE_ENTITY_ID);
}

static void test_nonfinite_values_and_invalid_bounds_are_rejected(void) {
    CLEntityRecord entity = complete_entity;
    CLSnapshot snapshot = snapshot_with(
        &entity, 1, CL_SNAPSHOT_SOURCE_NATIVE_RUNTIME,
        CL_SNAPSHOT_DATA_LIVE, 1000);

    entity.position.y = NAN;
    CLSnapshotValidation result =
        CLValidateSnapshot(&snapshot, 1100, 50, false);
    assert(result.error == CL_VALIDATE_ERROR_NONFINITE_POSITION);

    entity = complete_entity;
    entity.bounds.width = 0;
    result = CLValidateSnapshot(&snapshot, 1100, 50, false);
    assert(result.error == CL_VALIDATE_ERROR_INVALID_BOUNDS);

    entity = complete_entity;
    entity.rotation.x = INFINITY;
    result = CLValidateSnapshot(&snapshot, 1100, 50, false);
    assert(result.error == CL_VALIDATE_ERROR_NONFINITE_ROTATION);

    entity = complete_entity;
    entity.velocity.z = NAN;
    result = CLValidateSnapshot(&snapshot, 1100, 50, false);
    assert(result.error == CL_VALIDATE_ERROR_NONFINITE_VELOCITY);
}

static void test_entity_field_coverage_must_match_record_fields(void) {
    CLSnapshot snapshot = snapshot_with(
        &complete_entity, 1, CL_SNAPSHOT_SOURCE_NATIVE_RUNTIME,
        CL_SNAPSHOT_DATA_LIVE, 1000);
    snapshot.available_fields &= ~CL_ENTITY_FIELD_VELOCITY;
    const CLSnapshotValidation result =
        CLValidateSnapshot(&snapshot, 1100, 50, false);
    assert(result.status == CL_SNAPSHOT_VALIDATION_INVALID);
    assert(result.error == CL_VALIDATE_ERROR_UNKNOWN_FIELD);
}

static void test_removed_entity_is_not_rendered(void) {
    CLEntityRecord entity = complete_entity;
    entity.validity = CL_ENTITY_VALIDITY_REMOVED;
    const CLSnapshot snapshot = snapshot_with(
        &entity, 1, CL_SNAPSHOT_SOURCE_NATIVE_RUNTIME,
        CL_SNAPSHOT_DATA_LIVE, 1000);
    const CLSnapshotValidation result =
        CLValidateSnapshot(&snapshot, 1100, 50, false);
    assert(result.status == CL_SNAPSHOT_VALIDATION_PARTIAL);
    assert(result.renderable_entity_count == 0);
}

static void test_unknown_or_local_coordinates_are_not_rendered(void) {
    CLSnapshot snapshot = snapshot_with(
        &complete_entity, 1, CL_SNAPSHOT_SOURCE_NATIVE_RUNTIME,
        CL_SNAPSHOT_DATA_LIVE, 1000);
    snapshot.coordinate_space = CL_COORDINATE_SPACE_UNKNOWN;
    CLSnapshotValidation result =
        CLValidateSnapshot(&snapshot, 1100, 50, false);
    assert(result.status == CL_SNAPSHOT_VALIDATION_PARTIAL);
    assert(result.renderable_entity_count == 0);

    snapshot.coordinate_space = CL_COORDINATE_SPACE_PROVIDER_LOCAL;
    result = CLValidateSnapshot(&snapshot, 1100, 50, false);
    assert(result.status == CL_SNAPSHOT_VALIDATION_PARTIAL);
    assert(result.renderable_entity_count == 0);
}

static void test_unknown_position_anchor_prevents_render_eligibility(void) {
    CLSnapshot snapshot = snapshot_with(
        &complete_entity, 1, CL_SNAPSHOT_SOURCE_NATIVE_RUNTIME,
        CL_SNAPSHOT_DATA_LIVE, 1000);
    snapshot.position_anchor = CL_POSITION_ANCHOR_UNKNOWN;
    const CLSnapshotValidation result =
        CLValidateSnapshot(&snapshot, 1100, 50, false);
    assert(result.status == CL_SNAPSHOT_VALIDATION_PARTIAL);
    assert(result.renderable_entity_count == 0);
}

static void test_errors_are_preserved_and_checked(void) {
    const CLSnapshotError warnings[2] = {
        {
            .code = CL_ERROR_STALE_DATA,
            .severity = CL_ERROR_SEVERITY_WARNING,
            .entity_index = 0,
            .message = "one record is cached"
        },
        {
            .code = CL_ERROR_PROVIDER_FAILURE,
            .severity = CL_ERROR_SEVERITY_ERROR,
            .entity_index = SIZE_MAX,
            .message = NULL
        }
    };
    CLSnapshot snapshot = snapshot_with(
        &complete_entity, 1, CL_SNAPSHOT_SOURCE_NATIVE_RUNTIME,
        CL_SNAPSHOT_DATA_LIVE, 1000);
    snapshot.errors = warnings;
    snapshot.error_count = 2;
    const CLSnapshotValidation result =
        CLValidateSnapshot(&snapshot, 1100, 50, false);
    assert(result.status == CL_SNAPSHOT_VALIDATION_PARTIAL);
    assert(result.valid_error_count == 2);
    assert(result.renderable_entity_count == 1);

    CLSnapshotError malformed = {
        .code = CL_ERROR_NONE,
        .severity = CL_ERROR_SEVERITY_ERROR,
        .entity_index = 0,
        .message = NULL
    };
    snapshot.errors = &malformed;
    snapshot.error_count = 1;
    const CLSnapshotValidation invalid =
        CLValidateSnapshot(&snapshot, 1100, 50, false);
    assert(invalid.status == CL_SNAPSHOT_VALIDATION_INVALID);
    assert(invalid.error == CL_VALIDATE_ERROR_INVALID_ERROR_RECORD);
}

static void test_unavailable_provider_is_distinct_from_invalid_data(void) {
    CLSnapshot snapshot = snapshot_with(
        &complete_entity, 1, CL_SNAPSHOT_SOURCE_NATIVE_RUNTIME,
        CL_SNAPSHOT_DATA_LIVE, 1000);
    snapshot.provider_status = CL_PROVIDER_UNAVAILABLE;
    CLSnapshotValidation result =
        CLValidateSnapshot(&snapshot, 1100, 50, false);
    assert(result.status == CL_SNAPSHOT_VALIDATION_UNAVAILABLE);
    assert(result.error == CL_VALIDATE_ERROR_PROVIDER_UNAVAILABLE);

    CLSnapshot unavailable = {
        .status = CL_SNAPSHOT_STATUS_UNAVAILABLE,
        .provider_status = CL_PROVIDER_UNAVAILABLE
    };
    result = CLValidateSnapshot(&unavailable, 1100, 50, false);
    assert(result.status == CL_SNAPSHOT_VALIDATION_UNAVAILABLE);
    assert(result.error == CL_VALIDATE_ERROR_PROVIDER_UNAVAILABLE);

    snapshot.provider_status = CL_PROVIDER_READY;
    snapshot.status = CL_SNAPSHOT_STATUS_INVALID;
    result = CLValidateSnapshot(&snapshot, 1100, 50, false);
    assert(result.status == CL_SNAPSHOT_VALIDATION_INVALID);

    snapshot.status = CL_SNAPSHOT_STATUS_VALID;
    snapshot.provider_status = CL_PROVIDER_ERROR;
    result = CLValidateSnapshot(&snapshot, 1100, 50, false);
    assert(result.status == CL_SNAPSHOT_VALIDATION_INVALID);
    assert(result.error == CL_VALIDATE_ERROR_PROVIDER_FAILURE);
}

static void test_limitations_are_bounded_and_preserved_by_the_contract(void) {
    const char *const limitations[] = {
        "entity identity source has not been device-verified",
        "camera matrix is unavailable"
    };
    CLSnapshot snapshot = snapshot_with(
        &complete_entity, 1, CL_SNAPSHOT_SOURCE_NATIVE_RUNTIME,
        CL_SNAPSHOT_DATA_LIVE, 1000);
    snapshot.limitations = limitations;
    snapshot.limitation_count = 2;
    CLSnapshotValidation result =
        CLValidateSnapshot(&snapshot, 1100, 50, false);
    assert(result.status == CL_SNAPSHOT_VALIDATION_VALID);

    snapshot.limitation_count = CL_SNAPSHOT_MAX_LIMITATIONS + 1u;
    result = CLValidateSnapshot(&snapshot, 1100, 50, false);
    assert(result.status == CL_SNAPSHOT_VALIDATION_INVALID);
    assert(result.error == CL_VALIDATE_ERROR_LIMITATION_LIMIT);
}

static void test_empty_snapshot_and_limits(void) {
    CLSnapshot snapshot = snapshot_with(
        NULL, 0, CL_SNAPSHOT_SOURCE_NATIVE_RUNTIME,
        CL_SNAPSHOT_DATA_LIVE, 1000);
    CLSnapshotValidation result =
        CLValidateSnapshot(&snapshot, 1100, 50, false);
    assert(result.status == CL_SNAPSHOT_VALIDATION_VALID);
    assert(result.renderable_entity_count == 0);

    snapshot.entity_count = CL_SNAPSHOT_MAX_ENTITIES + 1u;
    result = CLValidateSnapshot(&snapshot, 1100, 50, false);
    assert(result.error == CL_VALIDATE_ERROR_ENTITY_LIMIT);

    snapshot.entity_count = 0;
    snapshot.error_count = CL_SNAPSHOT_MAX_ERRORS + 1u;
    result = CLValidateSnapshot(&snapshot, 1100, 50, false);
    assert(result.error == CL_VALIDATE_ERROR_ERROR_LIMIT);
}

static void test_schema_source_clock_and_required_values_are_checked(void) {
    CLSnapshot snapshot = snapshot_with(
        &complete_entity, 1, CL_SNAPSHOT_SOURCE_NATIVE_RUNTIME,
        CL_SNAPSHOT_DATA_LIVE, 1000);
    snapshot.schema_version++;
    CLSnapshotValidation result =
        CLValidateSnapshot(&snapshot, 1100, 50, false);
    assert(result.error == CL_VALIDATE_ERROR_SCHEMA_VERSION);

    snapshot.schema_version = CL_SNAPSHOT_SCHEMA_VERSION;
    snapshot.clock_domain = CL_CLOCK_UNKNOWN;
    result = CLValidateSnapshot(&snapshot, 1100, 50, false);
    assert(result.error == CL_VALIDATE_ERROR_MISSING_REQUIRED_VALUE);

    snapshot.clock_domain = CL_CLOCK_MONOTONIC;
    snapshot.provider_id = "";
    result = CLValidateSnapshot(&snapshot, 1100, 50, false);
    assert(result.error == CL_VALIDATE_ERROR_MISSING_REQUIRED_VALUE);
}

int main(void) {
    test_full_native_snapshot_is_eligible();
    test_full_protocol_snapshot_is_eligible_when_fresh();
    test_partial_record_and_unknown_optional_fields_are_not_rendered();
    test_unverified_record_is_not_rendered();
    test_partial_snapshot_can_contain_individually_valid_record();
    test_synthetic_source_requires_explicit_opt_in();
    test_offline_and_historical_data_are_never_rendered();
    test_fresh_cached_data_may_be_eligible();
    test_stale_age_and_explicit_stale_status_are_rejected();
    test_capture_and_observed_future_timestamps_are_bounded();
    test_duplicate_entity_identity_is_rejected();
    test_nonfinite_values_and_invalid_bounds_are_rejected();
    test_entity_field_coverage_must_match_record_fields();
    test_removed_entity_is_not_rendered();
    test_unknown_or_local_coordinates_are_not_rendered();
    test_unknown_position_anchor_prevents_render_eligibility();
    test_errors_are_preserved_and_checked();
    test_unavailable_provider_is_distinct_from_invalid_data();
    test_limitations_are_bounded_and_preserved_by_the_contract();
    test_empty_snapshot_and_limits();
    test_schema_source_clock_and_required_values_are_checked();
    puts("full snapshot contract tests passed");
    return 0;
}
