-- Diagnostic Queries for MetaSync CPU Issue
-- Run these to confirm MetaSync is causing the problem

-- 1. Check Action Scheduler queue size
SELECT COUNT(*) as pending_actions 
FROM wp_actionscheduler_actions 
WHERE status = 'pending';

-- 2. Check for failed/stuck actions
SELECT status, COUNT(*) as count 
FROM wp_actionscheduler_actions 
WHERE hook LIKE '%metasync%' 
GROUP BY status;

-- 3. Check for stuck claims (should be 0)
SELECT COUNT(*) as stuck_claims
FROM wp_actionscheduler_claims 
WHERE claim_date_gmt < DATE_SUB(NOW(), INTERVAL 5 MINUTE);

-- 4. Check OTTO cache entries (indicates API call volume)
SELECT COUNT(*) as otto_cache_entries
FROM wp_options 
WHERE option_name LIKE '_transient_otto_api_%';
