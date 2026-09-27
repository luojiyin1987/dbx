#[cfg(feature = "mq-admin")]
mod commands;

pub fn handles(command: &str) -> bool {
    command.starts_with("mq_")
}

#[cfg(feature = "mq-admin")]
pub fn invoke_handler() -> impl Fn(tauri::ipc::Invoke<tauri::Wry>) -> bool + Send + Sync + 'static {
    tauri::generate_handler![
        commands::mq_test_connection,
        commands::mq_list_tenants,
        commands::mq_get_tenant,
        commands::mq_create_tenant,
        commands::mq_update_tenant,
        commands::mq_delete_tenant,
        commands::mq_list_namespaces,
        commands::mq_create_namespace,
        commands::mq_delete_namespace,
        commands::mq_get_namespace_policies,
        commands::mq_list_topics,
        commands::mq_list_topics_page,
        commands::mq_create_topic,
        commands::mq_delete_topic,
        commands::mq_update_partitions,
        commands::mq_get_topic_stats,
        commands::mq_get_topic_internal_stats,
        commands::mq_list_exchanges,
        commands::mq_list_exchanges_page,
        commands::mq_create_exchange,
        commands::mq_delete_exchange,
        commands::mq_list_bindings,
        commands::mq_bind,
        commands::mq_unbind,
        commands::mq_list_subscriptions,
        commands::mq_enrich_subscriptions,
        commands::mq_get_kafka_consumer_group_snapshot,
        commands::mq_create_subscription,
        commands::mq_delete_subscription,
        commands::mq_skip_messages,
        commands::mq_reset_cursor,
        commands::mq_clear_backlog,
        commands::mq_get_consumer_group_config,
        commands::mq_alter_consumer_group_config,
        commands::mq_peek_messages,
        commands::mq_expire_messages,
        commands::mq_list_producers,
        commands::mq_list_consumers,
        commands::mq_unload_topic,
        commands::mq_list_client_connections,
        commands::mq_list_client_channels,
        commands::mq_close_client_connection,
        commands::mq_set_publish_rate,
        commands::mq_set_dispatch_rate,
        commands::mq_set_subscribe_rate,
        commands::mq_set_backlog_quota,
        commands::mq_set_retention,
        commands::mq_get_effective_policies,
        commands::mq_grant_permission,
        commands::mq_revoke_permission,
        commands::mq_list_permissions,
        commands::mq_list_users,
        commands::mq_create_user,
        commands::mq_delete_user,
        commands::mq_list_user_permissions,
        commands::mq_grant_user_permission,
        commands::mq_revoke_user_permission,
        commands::mq_list_policies,
        commands::mq_set_policy,
        commands::mq_delete_policy,
        commands::mq_get_overview,
        commands::mq_list_nodes,
        commands::mq_issue_token,
        commands::mq_list_token_records,
        commands::mq_get_backlog,
        commands::mq_get_cluster_info,
        commands::mq_get_topic_route,
        commands::mq_alter_topic_config,
        commands::mq_skip_topic_accumulation,
        commands::mq_view_message,
        commands::mq_query_messages_by_key,
        commands::mq_query_messages_by_topic,
        commands::mq_query_message_trace,
        commands::mq_raw_request,
        commands::mq_send_message,
    ]
}

#[cfg(feature = "mq-admin")]
pub fn route(
    main_handler: impl Fn(tauri::ipc::Invoke<tauri::Wry>) -> bool + Send + Sync + 'static,
) -> impl Fn(tauri::ipc::Invoke<tauri::Wry>) -> bool + Send + Sync + 'static {
    let mq_handler = invoke_handler();
    move |invoke| {
        if handles(invoke.message.command()) {
            mq_handler(invoke)
        } else {
            main_handler(invoke)
        }
    }
}

#[cfg(not(feature = "mq-admin"))]
pub fn route(
    main_handler: impl Fn(tauri::ipc::Invoke<tauri::Wry>) -> bool + Send + Sync + 'static,
) -> impl Fn(tauri::ipc::Invoke<tauri::Wry>) -> bool + Send + Sync + 'static {
    main_handler
}

#[cfg(test)]
mod tests {
    use super::handles;

    #[test]
    fn handles_only_mq_commands() {
        assert!(handles("mq_test_connection"));
        assert!(!handles("mqtt_publish"));
        assert!(!handles("load_connections"));
    }
}
