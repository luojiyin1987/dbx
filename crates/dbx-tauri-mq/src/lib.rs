mod commands;

macro_rules! define_registry {
    ($($command:ident),+ $(,)?) => {
        const COMMANDS: &[&str] = &[$(stringify!($command)),+];

        fn invoke_handler() -> impl Fn(tauri::ipc::Invoke<tauri::Wry>) -> bool + Send + Sync + 'static {
            tauri::generate_handler![$(commands::$command),+]
        }
    };
}

define_registry![
    mq_test_connection,
    mq_list_tenants,
    mq_get_tenant,
    mq_create_tenant,
    mq_update_tenant,
    mq_delete_tenant,
    mq_list_namespaces,
    mq_create_namespace,
    mq_delete_namespace,
    mq_get_namespace_policies,
    mq_list_topics,
    mq_list_topics_page,
    mq_create_topic,
    mq_delete_topic,
    mq_update_partitions,
    mq_get_topic_stats,
    mq_get_topic_internal_stats,
    mq_list_exchanges,
    mq_list_exchanges_page,
    mq_create_exchange,
    mq_delete_exchange,
    mq_list_bindings,
    mq_bind,
    mq_unbind,
    mq_list_subscriptions,
    mq_enrich_subscriptions,
    mq_get_kafka_consumer_group_snapshot,
    mq_create_subscription,
    mq_delete_subscription,
    mq_skip_messages,
    mq_reset_cursor,
    mq_clear_backlog,
    mq_get_consumer_group_config,
    mq_alter_consumer_group_config,
    mq_peek_messages,
    mq_expire_messages,
    mq_list_producers,
    mq_list_consumers,
    mq_unload_topic,
    mq_list_client_connections,
    mq_list_client_channels,
    mq_close_client_connection,
    mq_set_publish_rate,
    mq_set_dispatch_rate,
    mq_set_subscribe_rate,
    mq_set_backlog_quota,
    mq_set_retention,
    mq_get_effective_policies,
    mq_grant_permission,
    mq_revoke_permission,
    mq_list_permissions,
    mq_list_users,
    mq_create_user,
    mq_delete_user,
    mq_list_user_permissions,
    mq_grant_user_permission,
    mq_revoke_user_permission,
    mq_list_policies,
    mq_set_policy,
    mq_delete_policy,
    mq_get_overview,
    mq_list_nodes,
    mq_issue_token,
    mq_list_token_records,
    mq_get_backlog,
    mq_get_cluster_info,
    mq_get_topic_route,
    mq_alter_topic_config,
    mq_skip_topic_accumulation,
    mq_view_message,
    mq_query_messages_by_key,
    mq_query_messages_by_topic,
    mq_query_message_trace,
    mq_raw_request,
    mq_send_message,
];

pub fn handles(command: &str) -> bool {
    COMMANDS.contains(&command)
}

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
