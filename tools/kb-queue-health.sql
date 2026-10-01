-- Kill Bill queue-health probe (READ-ONLY).
--
-- Implements the metric Kill Bill's own Deployment Guide names as the canary:
--
--   "the bus_events table should almost always be empty and the notifications
--    table should never have any AVAILABLE entry with an effective date in the
--    past. Otherwise, in both cases, the system will be late (invoices not
--    generated, etc.). These two metrics should always be monitored in
--    production (potentially a paging event)."
--
-- Output format is deliberately `label<TAB>value` so tools/kb-regression.py can
-- consume it via --db-counts-file without the harness needing DB credentials.
--
-- Run it through whatever privileged path you already use, e.g.:
--   PW=$(grep DB_PASSWORD /opt/killbill/.db-credentials | cut -d= -f2)
--   docker exec killbill-db mariadb -u root -p"$PW" killbill -N < kb-queue-health.sql
--
-- Order of output matters: the harness parses by label, so keep labels stable.

SELECT 'bus_events.total', COUNT(*) FROM bus_events;
SELECT 'bus_events.available', COUNT(*) FROM bus_events WHERE processing_state = 'AVAILABLE';
SELECT 'bus_ext_events.total', COUNT(*) FROM bus_ext_events;
SELECT 'bus_ext_events.available', COUNT(*) FROM bus_ext_events WHERE processing_state = 'AVAILABLE';

-- THE critical one: must be 0. A non-zero value means Kill Bill is late.
SELECT 'notifications.past_due_available', COUNT(*)
  FROM notifications
 WHERE processing_state = 'AVAILABLE'
   AND effective_date < UTC_TIMESTAMP();

SELECT 'notifications.future_scheduled', COUNT(*)
  FROM notifications
 WHERE processing_state = 'AVAILABLE'
   AND effective_date >= UTC_TIMESTAMP();

-- Kill Bill's third checklist item (R7): "very few payment transactions (if any)
-- should be in an UNKNOWN state." A non-zero value is a manual-fix item via the
-- Payment Admin API. (Bug #179.)
SELECT 'payments.unknown', COUNT(*)
  FROM payments
 WHERE state_name = 'UNKNOWN';

-- Business state. Drift here across a maintenance window is the signal that
-- something ran that should not have (or did not run that should have).
SELECT 'state.tenants', COUNT(*) FROM tenants;
SELECT 'state.accounts', COUNT(*) FROM accounts;
SELECT 'state.invoices', COUNT(*) FROM invoices;
SELECT 'state.subscriptions', COUNT(*) FROM subscriptions;
SELECT 'state.payments', COUNT(*) FROM payments;
SELECT 'state.payment_methods', COUNT(*) FROM payment_methods;
SELECT 'state.blocking_states', COUNT(*) FROM blocking_states;
