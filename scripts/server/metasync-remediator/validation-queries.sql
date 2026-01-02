-- Validation Queries
-- Run these after implementing fixes to verify they're working

-- Should return < 500
SELECT COUNT(*) FROM wp_actionscheduler_actions WHERE status = 'pending';

-- Should return 0
SELECT COUNT(*) FROM wp_actionscheduler_claims 
WHERE claim_date_gmt < DATE_SUB(NOW(), INTERVAL 5 MINUTE);

-- Should return reasonable number (< 1000)
SELECT COUNT(*) FROM wp_options 
WHERE option_name LIKE '_transient_otto_api_%';
