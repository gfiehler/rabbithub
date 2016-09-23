-record(rabbithub_subscription, {resource, topic, callback}).
-record(consumer, {subscription, node}).
-record(rabbithub_lease, {subscription, lease_expiry_time_microsec, lease_seconds, ha_mode, max_tps, status, pseudo_queue}).
-record(rabbithub_subscription_pid, {consumer, pid, expiry_timer}).
-record(rabbithub_subscription_err, {subscription, error_count, first_error_time_microsec, last_error_time_microsec, last_error_msg}).
-record(rabbithub_batch, {subscription, lease_expiry_time_microsec, status}).


