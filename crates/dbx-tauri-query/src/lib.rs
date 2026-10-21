mod commands;

macro_rules! define_registry {
    ($($(#[$meta:meta])* $command:ident),+ $(,)?) => {
        const COMMANDS: &[&str] = &[$($(#[$meta])* stringify!($command)),+];

        pub fn invoke_handler() -> impl Fn(tauri::ipc::Invoke<tauri::Wry>) -> bool + Send + Sync + 'static {
            tauri::generate_handler![$($(#[$meta])* commands::$command),+]
        }
    };
}

define_registry![
    execute_query,
    execute_conditional_update,
    execute_multi,
    cancel_query,
    cancel_conditional_update,
    close_query_session,
    read_large_value_chunk,
    release_large_value,
    download_large_value,
    export_snapshot_result,
    close_client_connection_session,
    execute_batch,
    execute_script,
    execute_in_transaction,
    execute_script_with_2pc,
    begin_manual_transaction,
    execute_in_manual_transaction,
    commit_manual_transaction,
    rollback_manual_transaction,
    analyze_sql_references,
    find_statement_at_cursor,
    prepare_query_pagination_execution_plan,
    build_sorted_query_sql,
    build_explain_sql,
    get_explain_info,
    get_plugin_plan_capabilities,
    get_plugin_estimated_plan,
    query_plugin_data,
    get_plugin_data_grants,
    set_plugin_data_grant,
    build_create_user_sql,
    build_dropped_file_preview_sql,
    build_table_select_sql,
    build_database_search_sql,
    build_database_search_columns_sql,
    build_database_search_probe_sql,
    build_database_structure_search_sql,
    supports_database_structure_search,
    build_search_result_where,
    build_rename_object_sql,
    build_rename_database_sql,
    build_rename_database_preflight_sql,
    build_create_database_sql,
    #[cfg(feature = "duckdb-sidecar")]
    build_duckdb_attach_database_sql,
    build_sqlite_attach_database_sql,
    build_drop_object_sql,
    build_drop_table_sql,
    build_drop_table_child_object_sql,
    build_empty_table_sql,
    build_truncate_table_sql,
    build_vacuum_table_sql,
    build_mysql_auto_increment_sql,
    build_drop_database_sql,
    build_create_schema_sql,
    build_update_database_properties_sql,
    build_drop_schema_sql,
    build_duplicate_table_structure_sql,
    build_copy_table_data_sql,
    build_executable_object_source_statements,
    validate_oracle_executable_object_source,
    fingerprint_oracle_routine_object_source,
    build_executable_object_source_sql,
    build_editable_object_source,
    build_routine_rename_object_source_statements,
    rewrite_oracle_routine_references,
    rewrite_oracle_table_references,
    parse_oracle_object_name,
    build_oracle_view_rename_source,
    review_oracle_view_rename_source,
    build_view_ddl_sql,
    build_table_structure_change_sql,
    build_table_owner_change_sql,
    preview_sqlite_table_structure_change,
    apply_sqlite_table_structure_change,
    build_create_table_sql,
    build_create_partitioned_table_sql,
    build_table_partition_operation_sql,
    build_single_column_alter_sql,
    analyze_editable_query_editability,
    prepare_data_grid_save,
    extract_data_grid_selection,
    build_data_grid_copy_update_statements,
    build_data_grid_copy_insert_statement,
    build_dml_change_preview_sql,
    build_data_grid_context_filter_condition,
    build_data_grid_column_value_filter_condition,
    build_data_grid_column_values_filter_condition,
    build_data_grid_column_distinct_values_sql,
    build_data_grid_count_sql,
    build_data_grid_conditional_update_sql,
    build_hive_table_properties_sql,
    build_export_insert_statements,
    build_export_sql_insert,
    build_database_sql_export,
];

pub fn handles(command: &str) -> bool {
    COMMANDS.contains(&command)
}

pub fn route(
    main_handler: impl Fn(tauri::ipc::Invoke<tauri::Wry>) -> bool + Send + Sync + 'static,
) -> impl Fn(tauri::ipc::Invoke<tauri::Wry>) -> bool + Send + Sync + 'static {
    let query_handler = invoke_handler();
    move |invoke| {
        if handles(invoke.message.command()) {
            query_handler(invoke)
        } else {
            main_handler(invoke)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{handles, COMMANDS};

    #[test]
    fn handles_only_query_commands() {
        assert_eq!(COMMANDS.len(), if cfg!(feature = "duckdb-sidecar") { 94 } else { 93 });
        assert!(handles("execute_query"));
        assert!(handles("build_database_sql_export"));
        assert_eq!(handles("build_duckdb_attach_database_sql"), cfg!(feature = "duckdb-sidecar"));
        assert!(!handles("load_connections"));
    }
}
